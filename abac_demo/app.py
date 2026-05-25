"""Flask ABAC Demo Application.

Provides REST API for demonstrating the ABAC access control system
for national sensitive data records.
"""

import json
import math
import os
import time
from flask import Flask, request, jsonify, render_template
from database import query_all, query_one, execute
from abac_engine import evaluate_access

app = Flask(__name__)

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
    data = request.get_json(force=True)

    user_id = int(data.get("user_id", 0))
    resource_id = int(data.get("resource_id", 0))
    action = data.get("action", "read")
    env = {
        "device_trust": data.get("device_trust", "medium"),
        "network_zone": data.get("network_zone", "internal"),
        "hour": int(data.get("hour", 10)),
        "threat_level": data.get("threat_level", "normal"),
    }

    start = time.perf_counter()
    decision, reason, policy_id = evaluate_access(user_id, resource_id, action, env)
    elapsed_ms = round((time.perf_counter() - start) * 1000, 1)

    # Log to database via request_access function
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
            None,  # ip_address
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


# ---------------------------------------------------------------------------
# API: Audit Logs
# ---------------------------------------------------------------------------
@app.route("/api/audit/logs")
def api_audit_logs():
    limit = min(int(request.args.get("limit", 50)), 200)
    logs = query_all(
        """SELECT * FROM v_audit_trail ORDER BY request_id DESC LIMIT %s""",
        (limit,),
    )
    return jsonify(logs)


@app.route("/api/audit/stats")
def api_audit_stats():
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
