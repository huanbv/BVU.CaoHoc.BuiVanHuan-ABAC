"""Flask ABAC Demo Application.

Provides REST API for demonstrating the ABAC access control system
for national sensitive data records.
"""

import math
import os
import time
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from flask import Flask, request, jsonify, render_template
from flask.json.provider import DefaultJSONProvider

from database import execute, query_all, query_one
from abac_engine import evaluate_access


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

DEFAULT_PAGE_SIZE = 50
MAX_PAGE_SIZE = 200


def _pagination_params():
    page = max(1, int(request.args.get("page", 1)))
    per_page = int(request.args.get("per_page", DEFAULT_PAGE_SIZE))
    per_page = min(max(1, per_page), MAX_PAGE_SIZE)
    offset = (page - 1) * per_page
    return page, per_page, offset


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
def api_users():
    page, per_page, offset = _pagination_params()
    q = (request.args.get("q") or "").strip()
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
def api_resources():
    page, per_page, offset = _pagination_params()
    q = (request.args.get("q") or "").strip()
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
def api_toggle_policy(policy_id):
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
def api_access_check():
    try:
        data = request.get_json(force=True)

        user_id = int(data.get("user_id", 0))
        resource_id = int(data.get("resource_id", 0))
        action = data.get("action", "read") or "read"
        raw_hour = data.get("hour", 10)
        try:
            hour = int(raw_hour)
        except (TypeError, ValueError):
            return jsonify({"error": "Giờ (hour) phải là số nguyên 0–23"}), 400

        env = {
            "device_trust": data.get("device_trust") or "medium",
            "network_zone": data.get("network_zone") or "internal",
            "hour": hour,
            "threat_level": data.get("threat_level") or "normal",
        }

        start = time.perf_counter()
        decision, reason, policy_id = evaluate_access(user_id, resource_id, action, env)
        elapsed_ms = round((time.perf_counter() - start) * 1000, 1)

        # Log via DB PEP (ghi access_requests + evaluate_access_dynamic + audit)
        result = query_one(
            """SELECT * FROM request_access(
                %s, %s, %s, %s, %s, %s, %s, %s
            )""",
            (
                user_id,
                resource_id,
                action,
                env["device_trust"],
                env["network_zone"],
                env["hour"],
                None,
                env["threat_level"],
            ),
        )

        return jsonify(
            {
                "decision": decision,
                "reason": reason,
                "matched_policy_id": policy_id,
                "evaluation_time_ms": elapsed_ms,
                "request_id": result["request_id"] if result else None,
                "trace_id": str(result["trace_id"]) if result else None,
            }
        )
    except Exception as exc:
        app.logger.exception("api_access_check failed: %s", exc)
        return jsonify({"error": str(exc), "type": type(exc).__name__}), 500


# ---------------------------------------------------------------------------
# API: Audit Logs
# ---------------------------------------------------------------------------
@app.route("/api/audit/logs")
def api_audit_logs():
    try:
        limit = min(int(request.args.get("limit", 50)), 200)
        # Query trực tiếp (tránh VIEW có ORDER BY nội bộ gây kế hoạch chậm trên PostgreSQL một số bản).
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
        app.logger.exception("api_audit_logs failed: %s", exc)
        return jsonify({"error": str(exc), "type": type(exc).__name__}), 500


@app.route("/api/audit/stats")
def api_audit_stats():
    try:
        user_stats = query_all("SELECT * FROM v_user_access_stats")
        policy_stats = query_all("SELECT * FROM v_policy_hit_stats")
        anomalies = query_all("SELECT * FROM v_anomaly_detection")
        return jsonify(
            {
                "user_stats": user_stats,
                "policy_stats": policy_stats,
                "anomalies": anomalies,
            }
        )
    except Exception as exc:
        app.logger.exception("api_audit_stats failed: %s", exc)
        return jsonify({"error": str(exc), "type": type(exc).__name__}), 500


# ---------------------------------------------------------------------------
# API: Agencies
# ---------------------------------------------------------------------------
@app.route("/api/agencies")
def api_agencies():
    return jsonify(query_all("SELECT * FROM agencies ORDER BY agency_code"))


# ---------------------------------------------------------------------------
# RUN
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    debug_mode = os.getenv("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=5000, debug=debug_mode)
