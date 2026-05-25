"""Bảo mật tầng HTTP khi không có đăng nhập người dùng.

- Khóa tùy chọn cho thao tác ghi (ABAC_ADMIN_TOKEN)
- Chuẩn hóa / kiểm tra payload PEP
- Tiêu đề an toàn, ẩn chi tiết lỗi API (tuỳ cấu hình)
"""

from __future__ import annotations

import os
import secrets
from typing import Any

from flask import Flask, jsonify, request

# Khóa dùng cho PUT bật/tắt chính sách (header, so khớp an toàn thời gian)
ADMIN_TOKEN = os.getenv("ABAC_ADMIN_TOKEN", "").strip()
ADMIN_HEADER = "X-Abac-Admin-Token"

ALLOWED_ACTIONS = frozenset({"read", "update", "delete", "export"})
ALLOWED_DEVICE_TRUST = frozenset({"high", "medium", "low"})
ALLOWED_NETWORK_ZONE = frozenset({"internal", "vpn", "external"})
ALLOWED_THREAT = frozenset({"normal", "elevated", "critical"})

_MAX_ID = int(os.getenv("ABAC_MAX_SUBJECT_OBJECT_ID", "100000000"))
_MAX_SEARCH_LEN = int(os.getenv("ABAC_MAX_SEARCH_LEN", "200"))


def admin_token_configured() -> bool:
    return bool(ADMIN_TOKEN)


def verify_admin_request():
    """Trả về None nếu được phép; ngược lại (body, status)."""
    if not ADMIN_TOKEN:
        return None
    provided = (request.headers.get(ADMIN_HEADER) or "").strip()
    auth = request.headers.get("Authorization") or ""
    if auth.lower().startswith("bearer "):
        provided = provided or auth[7:].strip()
    if not provided:
        return jsonify({"error": "Thiếu hoặc không đúng khóa quản trị."}), 401
    pa = provided.encode("utf-8")
    ta = ADMIN_TOKEN.encode("utf-8")
    if len(pa) != len(ta) or not secrets.compare_digest(pa, ta):
        return jsonify({"error": "Thiếu hoặc không đúng khóa quản trị."}), 401
    return None


def expose_error_detail(app: Flask) -> bool:
    if app.debug:
        return True
    return os.getenv("ABAC_DEBUG_ERRORS", "").lower() in ("1", "true", "yes")


def api_error_response(app: Flask, exc: BaseException, *, log_message: str) -> tuple[Any, int]:
    """JSON 500; chi tiết chỉ khi debug / ABAC_DEBUG_ERRORS."""
    app.logger.exception(log_message)
    if expose_error_detail(app):
        return jsonify({"error": str(exc), "type": type(exc).__name__}), 500
    return (
        jsonify(
            {
                "error": "Lỗi máy chủ. Chi tiết đã được ghi log.",
                "type": "InternalError",
            }
        ),
        500,
    )


def clamp_search_q(raw: str | None) -> tuple[str | None, tuple[Any, int] | None]:
    """Trả về (q_trimmed hoặc None, lỗi) nếu quá dài."""
    q = (raw or "").strip()
    if not q:
        return None, None
    if len(q) > _MAX_SEARCH_LEN:
        return (
            None,
            (
                jsonify(
                    {
                        "error": f"Tham số q quá dài (tối đa {_MAX_SEARCH_LEN} ký tự).",
                    }
                ),
                400,
            ),
        )
    return q, None


def validate_access_check_body(data: Any) -> tuple[dict[str, Any] | None, tuple[Any, int] | None]:
    """Trả về (payload chuẩn, None) hoặc (None, (jsonify, status))."""
    if not isinstance(data, dict):
        return None, (jsonify({"error": "Body phải là JSON object."}), 400)

    try:
        user_id = int(data.get("user_id", 0))
        resource_id = int(data.get("resource_id", 0))
    except (TypeError, ValueError):
        return None, (jsonify({"error": "user_id và resource_id phải là số nguyên."}), 400)

    if user_id < 1 or resource_id < 1 or user_id > _MAX_ID or resource_id > _MAX_ID:
        return None, (jsonify({"error": "user_id / resource_id không hợp lệ."}), 400)

    action = (data.get("action") or "read").strip().lower()
    if action not in ALLOWED_ACTIONS:
        return None, (jsonify({"error": f"action không hợp lệ (cho phép: {sorted(ALLOWED_ACTIONS)})."}), 400)

    device_trust = (data.get("device_trust") or "medium").strip().lower()
    network_zone = (data.get("network_zone") or "internal").strip().lower()
    threat_level = (data.get("threat_level") or "normal").strip().lower()

    if device_trust not in ALLOWED_DEVICE_TRUST:
        return None, (jsonify({"error": "device_trust không hợp lệ."}), 400)
    if network_zone not in ALLOWED_NETWORK_ZONE:
        return None, (jsonify({"error": "network_zone không hợp lệ."}), 400)
    if threat_level not in ALLOWED_THREAT:
        return None, (jsonify({"error": "threat_level không hợp lệ."}), 400)

    raw_hour = data.get("hour", 10)
    try:
        hour = int(raw_hour)
    except (TypeError, ValueError):
        return None, (jsonify({"error": "Giờ (hour) phải là số nguyên 0–23."}), 400)
    if hour < 0 or hour > 23:
        return None, (jsonify({"error": "hour phải trong khoảng 0–23."}), 400)

    return (
        {
            "user_id": user_id,
            "resource_id": resource_id,
            "action": action,
            "device_trust": device_trust,
            "network_zone": network_zone,
            "threat_level": threat_level,
            "hour": hour,
        },
        None,
    )


def trust_proxy_enabled() -> bool:
    return os.getenv("ABAC_TRUST_PROXY", "").lower() in ("1", "true", "yes")


def client_ip_for_rate_limit() -> str:
    if trust_proxy_enabled():
        fwd = request.headers.get("X-Forwarded-For", "")
        if fwd:
            return fwd.split(",")[0].strip() or request.remote_addr or "unknown"
    return request.remote_addr or "unknown"


def apply_security_headers(response):
    """Tiêu đề chống MIME sniffing, clickjacking, v.v."""
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault(
        "Permissions-Policy",
        "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()",
    )
    response.headers.setdefault("X-XSS-Protection", "0")
    # Giao diện dùng inline script/style — giới hạn nguồn tài nguyên
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
        "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; form-action 'self'",
    )
    return response
