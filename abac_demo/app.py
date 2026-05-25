"""Flask ABAC Demo Application.

Provides REST API for demonstrating the ABAC access control system
for national sensitive data records.
"""

import math
import os
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from dotenv import load_dotenv

load_dotenv()

from flask import Flask, jsonify, render_template, request
from flask.json.provider import DefaultJSONProvider
from flask_limiter import Limiter
from werkzeug.middleware.proxy_fix import ProxyFix

from database import execute, query_all, query_one
from security import (
    admin_token_configured,
    api_error_response,
    apply_security_headers,
    client_ip_for_rate_limit,
    clamp_search_q,
    trust_proxy_enabled,
    validate_access_check_body,
    verify_admin_request,
)


class RobustJSONProvider(DefaultJSONProvider):
    """Serialize UUID/datetime/Decimal — common DB types that break default jsonify."""

    def default(self, o):
        if isinstance(o, UUID):
            return str(o)
        if isinstance(o, (datetime, date)):
            return o.isoformat()
        if isinstance(o, Decimal):
            return float(o)
        return super().default(o)


app = Flask(__name__)
app.json = RobustJSONProvider(app)

_max_body = int(os.getenv("ABAC_MAX_BODY_BYTES", "65536"))
app.config["MAX_CONTENT_LENGTH"] = _max_body

if trust_proxy_enabled():
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)

limiter = Limiter(
    app=app,
    key_func=client_ip_for_rate_limit,
    default_limits=[],
    storage_uri="memory://",
    headers_enabled=True,
)

with app.app_context():
    if not admin_token_configured():
        app.logger.warning(
            "ABAC_ADMIN_TOKEN chưa đặt: mọi client đều có thể bật/tắt chính sách. "
            "Trên môi trường công khai hãy đặt biến môi trường này."
        )

DEFAULT_PAGE_SIZE = 50
MAX_PAGE_SIZE = 200

# Thống kê audit/v_anomaly_detection cũ quét và GROUP BY cả bảng access_requests —
# với dữ liệu lớn gây timeout/500. Dùng tổng hợp nhẹ và cửa sổ thời gian.
_STATS_SINCE_DAYS = int(os.getenv("ABAC_STATS_SINCE_DAYS", "90"))
_STATS_ANOMALY_MIN_REQ = max(1, int(os.getenv("ABAC_STATS_ANOMALY_MIN_REQUESTS", "2")))
_STATS_ANOMALY_LIMIT = min(500, max(10, int(os.getenv("ABAC_STATS_ANOMALY_LIMIT", "150"))))


def _pagination_params():
    page = max(1, int(request.args.get("page", 1)))
    per_page = int(request.args.get("per_page", DEFAULT_PAGE_SIZE))
    per_page = min(max(1, per_page), MAX_PAGE_SIZE)
    offset = (page - 1) * per_page
    return page, per_page, offset


@app.after_request
def _security_headers(response):
    return apply_security_headers(response)


@app.errorhandler(413)
def _payload_too_large(_e):
    return jsonify({"error": "Payload quá lớn (giới hạn ABAC_MAX_BODY_BYTES)."}), 413


# ---------------------------------------------------------------------------
# WEB UI
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")


# ---------------------------------------------------------------------------
# API: Users (PIP)
# ---------------------------------------------------------------------------
@app.route("/api/users")
@limiter.limit("120 per minute")
def api_users():
    page, per_page, offset = _pagination_params()
    q_raw = request.args.get("q")
    q_bad = clamp_search_q(q_raw)
    if q_bad[1]:
        return q_bad[1]
    q = q_bad[0]
    like = f"%{q}%" if q else None

    if q:
        total = query_one(
            """SELECT COUNT(*) AS c FROM users u
               WHERE u.full_name ILIKE %s OR u.email ILIKE %s""",
            (like, like),
        )["c"]
        users = query_all(
            """
            SELECT u.*, a.agency_name,
                   COALESCE(
                       (SELECT json_agg(json_build_object('key', ua.attr_key, 'value', ua.attr_value,
                            'valid_from', ua.valid_from, 'valid_to', ua.valid_to))
                        FROM user_attributes ua
                        WHERE ua.user_id = u.user_id
                          AND ua.valid_from <= NOW()
                          AND (ua.valid_to IS NULL OR ua.valid_to > NOW())),
                       '[]'::json
                   ) AS attributes
            FROM users u
            JOIN agencies a ON a.agency_code = u.agency_code
            WHERE u.full_name ILIKE %s OR u.email ILIKE %s
            ORDER BY u.user_id
            LIMIT %s OFFSET %s
            """,
            (like, like, per_page, offset),
        )
    else:
        total = query_one("SELECT COUNT(*) AS c FROM users")["c"]
        users = query_all(
            """
            SELECT u.*, a.agency_name,
                   COALESCE(
                       (SELECT json_agg(json_build_object('key', ua.attr_key, 'value', ua.attr_value,
                            'valid_from', ua.valid_from, 'valid_to', ua.valid_to))
                        FROM user_attributes ua
                        WHERE ua.user_id = u.user_id
                          AND ua.valid_from <= NOW()
                          AND (ua.valid_to IS NULL OR ua.valid_to > NOW())),
                       '[]'::json
                   ) AS attributes
            FROM users u
            JOIN agencies a ON a.agency_code = u.agency_code
            ORDER BY u.user_id
            LIMIT %s OFFSET %s
            """,
            (per_page, offset),
        )

    pages = max(1, math.ceil(total / per_page)) if per_page else 1
    return jsonify(
        {
            "items": users,
            "total": total,
            "page": page,
            "per_page": per_page,
            "pages": pages,
        }
    )


# ---------------------------------------------------------------------------
# API: Resources (PIP)
# ---------------------------------------------------------------------------
@app.route("/api/resources")
@limiter.limit("120 per minute")
def api_resources():
    page, per_page, offset = _pagination_params()
    q_raw = request.args.get("q")
    q_bad = clamp_search_q(q_raw)
    if q_bad[1]:
        return q_bad[1]
    q = q_bad[0]
    like = f"%{q}%" if q else None

    if q:
        total = query_one(
            """SELECT COUNT(*) AS c FROM resources r
               WHERE r.resource_name ILIKE %s OR CAST(r.resource_id AS TEXT) = %s""",
            (like, q),
        )["c"]
        resources = query_all(
            """
            SELECT r.*, a.agency_name,
                   COALESCE(
                       (SELECT json_agg(json_build_object('key', ra.attr_key, 'value', ra.attr_value))
                        FROM resource_attributes ra WHERE ra.resource_id = r.resource_id),
                       '[]'::json
                   ) AS attributes
            FROM resources r
            JOIN agencies a ON a.agency_code = r.owner_agency
            WHERE r.resource_name ILIKE %s OR CAST(r.resource_id AS TEXT) = %s
            ORDER BY r.resource_id
            LIMIT %s OFFSET %s
            """,
            (like, q, per_page, offset),
        )
    else:
        total = query_one("SELECT COUNT(*) AS c FROM resources")["c"]
        resources = query_all(
            """
            SELECT r.*, a.agency_name,
                   COALESCE(
                       (SELECT json_agg(json_build_object('key', ra.attr_key, 'value', ra.attr_value))
                        FROM resource_attributes ra WHERE ra.resource_id = r.resource_id),
                       '[]'::json
                   ) AS attributes
            FROM resources r
            JOIN agencies a ON a.agency_code = r.owner_agency
            ORDER BY r.resource_id
            LIMIT %s OFFSET %s
            """,
            (per_page, offset),
        )

    pages = max(1, math.ceil(total / per_page)) if per_page else 1
    return jsonify(
        {
            "items": resources,
            "total": total,
            "page": page,
            "per_page": per_page,
            "pages": pages,
        }
    )


# ---------------------------------------------------------------------------
# API: Policies (PAP)
# ---------------------------------------------------------------------------
@app.route("/api/policies")
@limiter.limit("120 per minute")
def api_policies():
    policies = query_all("""
        SELECT p.*,
               COALESCE(
                   (SELECT json_agg(json_build_object(
                        'attribute_type', pc.attribute_type,
                        'attribute_key', pc.attribute_key,
                        'operator', pc.operator,
                        'compare_value', pc.compare_value,
                        'value_type', pc.value_type))
                    FROM policy_conditions pc WHERE pc.policy_id = p.policy_id),
                   '[]'::json
               ) AS conditions
        FROM policies p
        ORDER BY p.priority DESC
    """)
    return jsonify(policies)


@app.route("/api/policies/<int:policy_id>/toggle", methods=["PUT"])
@limiter.limit("30 per minute")
def api_toggle_policy(policy_id):
    auth_err = verify_admin_request()
    if auth_err is not None:
        return auth_err
    execute(
        "UPDATE policies SET is_enabled = NOT is_enabled WHERE policy_id = %s",
        (policy_id,),
    )
    policy = query_one("SELECT * FROM policies WHERE policy_id = %s", (policy_id,))
    return jsonify(policy)


# ---------------------------------------------------------------------------
# API: Access Check (PEP + PDP)
# ---------------------------------------------------------------------------
@app.route("/api/access/check", methods=["POST"])
@limiter.limit("50 per minute")
def api_access_check():
    try:
        data = request.get_json(force=True)
        norm, verr = validate_access_check_body(data)
        if verr is not None:
            return verr

        result = query_one(
            """SELECT * FROM request_access(
                %s, %s, %s, %s, %s, %s, %s, %s
            )""",
            (
                norm["user_id"],
                norm["resource_id"],
                norm["action"],
                norm["device_trust"],
                norm["network_zone"],
                norm["hour"],
                None,
                norm["threat_level"],
            ),
        )

        if not result:
            return jsonify({"error": "request_access không trả về kết quả"}), 500

        eval_ms_db = result.get("evaluation_time_ms")
        if eval_ms_db is not None:
            try:
                eval_ms_db = float(eval_ms_db)
            except (TypeError, ValueError):
                eval_ms_db = None

        return jsonify(
            {
                "decision": result.get("decision"),
                "reason": result.get("reason"),
                "matched_policy_id": result.get("matched_policy_id"),
                "evaluation_time_ms": eval_ms_db,
                "request_id": result.get("request_id"),
                "trace_id": str(result["trace_id"]) if result.get("trace_id") is not None else None,
            }
        )
    except Exception as exc:
        return api_error_response(app, exc, log_message="api_access_check failed")


# ---------------------------------------------------------------------------
# API: Audit Logs
# ---------------------------------------------------------------------------
@app.route("/api/audit/logs")
@limiter.limit("90 per minute")
def api_audit_logs():
    try:
        limit_raw = request.args.get("limit", 50)
        try:
            limit = min(int(limit_raw), 200)
        except (TypeError, ValueError):
            return jsonify({"error": "limit phải là số nguyên dương (tối đa 200)."}), 400
        if limit < 1:
            limit = 1

        logs = query_all(
            """
            SELECT
                r.request_id,
                r.trace_id,
                r.request_time,
                u.full_name AS user_name,
                u.agency_code,
                u.clearance_level AS user_clearance,
                res.resource_name,
                res.classification_level AS resource_classification,
                res.owner_agency,
                r.action,
                r.env_device_trust,
                r.env_network_zone,
                r.env_hour,
                r.env_threat_level,
                d.decision,
                d.reason,
                d.matched_policy_id,
                d.evaluation_time_ms,
                d.is_break_glass
            FROM access_requests r
            JOIN users u ON u.user_id = r.user_id
            JOIN resources res ON res.resource_id = r.resource_id
            JOIN access_decisions d ON d.request_id = r.request_id
            ORDER BY r.request_id DESC
            LIMIT %s
            """,
            (limit,),
        )
        return jsonify(logs)
    except Exception as exc:
        return api_error_response(app, exc, log_message="api_audit_logs failed")


@app.route("/api/audit/stats")
@limiter.limit("60 per minute")
def api_audit_stats():
    """Không đọc VIEW v_user_access_stats / v_anomaly — tránh full-scan khi có nhiều log."""
    try:
        # Một hàng tổng (UI cộng dồn total_requests / permit / deny như trước)
        user_agg = query_all(
            """
            SELECT
                NULL::INTEGER AS user_id,
                ''::TEXT AS full_name,
                ''::TEXT AS agency_code,
                COUNT(*)::BIGINT AS total_requests,
                COUNT(*) FILTER (WHERE decision = 'permit')::BIGINT AS permit_count,
                COUNT(*) FILTER (WHERE decision = 'deny')::BIGINT AS deny_count,
                ROUND(
                    100.0 * COUNT(*) FILTER (WHERE decision = 'deny')
                    / NULLIF(COUNT(*), 0),
                    1
                ) AS deny_rate_pct,
                AVG(evaluation_time_ms)::DOUBLE PRECISION AS avg_eval_ms
            FROM access_decisions
            """
        )

        policy_stats = query_all(
            """
            SELECT
                p.policy_id,
                p.policy_name,
                p.effect,
                p.priority,
                COALESCE(h.hit_count, 0)::BIGINT AS hit_count,
                p.is_enabled
            FROM policies p
            LEFT JOIN (
                SELECT matched_policy_id AS pid, COUNT(*) AS hit_count
                FROM access_decisions
                WHERE matched_policy_id IS NOT NULL
                GROUP BY matched_policy_id
            ) h ON h.pid = p.policy_id
            ORDER BY hit_count DESC NULLS LAST, p.policy_id
            """
        )

        if _STATS_SINCE_DAYS <= 0:
            time_filter = ""
            time_params = ()
        else:
            time_filter = "AND r.request_time >= NOW() - make_interval(days => %s)"
            time_params = (_STATS_SINCE_DAYS,)

        anomalies = query_all(
            f"""
            WITH per_user AS (
                SELECT
                    r.user_id,
                    COUNT(*) AS total_requests,
                    COUNT(*) FILTER (WHERE d.decision = 'deny') AS deny_count,
                    ROUND(
                        100.0 * COUNT(*) FILTER (WHERE d.decision = 'deny')
                        / NULLIF(COUNT(*), 0),
                        1
                    ) AS deny_rate_pct
                FROM access_requests r
                JOIN access_decisions d ON d.request_id = r.request_id
                WHERE 1=1
                {time_filter}
                GROUP BY r.user_id
                HAVING COUNT(*) >= %s
            )
            SELECT
                u.user_id,
                u.full_name,
                u.agency_code,
                p.total_requests,
                p.deny_count,
                p.deny_rate_pct,
                CASE
                    WHEN p.deny_rate_pct > 80 THEN 'HIGH RISK'
                    WHEN p.deny_rate_pct > 50 THEN 'MEDIUM RISK'
                    ELSE 'NORMAL'
                END AS risk_level
            FROM per_user p
            JOIN users u ON u.user_id = p.user_id
            ORDER BY p.deny_rate_pct DESC NULLS LAST, p.total_requests DESC
            LIMIT %s
            """,
            (*time_params, _STATS_ANOMALY_MIN_REQ, _STATS_ANOMALY_LIMIT),
        )

        return jsonify(
            {
                "user_stats": user_agg,
                "policy_stats": policy_stats,
                "anomalies": anomalies,
                "meta": {
                    "audit_anomaly_since_days": _STATS_SINCE_DAYS if _STATS_SINCE_DAYS > 0 else None,
                    "audit_anomaly_row_limit": _STATS_ANOMALY_LIMIT,
                },
            }
        )
    except Exception as exc:
        return api_error_response(app, exc, log_message="api_audit_stats failed")


# ---------------------------------------------------------------------------
# API: Agencies
# ---------------------------------------------------------------------------
@app.route("/api/agencies")
@limiter.limit("120 per minute")
def api_agencies():
    return jsonify(query_all("SELECT * FROM agencies ORDER BY agency_code"))


# ---------------------------------------------------------------------------
# RUN
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    debug_mode = os.getenv("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=5000, debug=debug_mode)
