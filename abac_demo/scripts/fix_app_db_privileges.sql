-- =============================================================================
-- Cấp quyền PostgreSQL cho user mà Flask/Gunicorn dùng (DB_USER trong .env)
--
-- Lỗi thường gặp nếu chưa chạy script này:
--   permission denied for sequence access_requests_request_id_seq
--   (khi INSERT vào access_requests / access_decisions / audit_logs qua request_access)
--
-- Chạy với superuser (thường là postgres):
--   psql -U postgres -d abac_demo -v app_user=TEN_USER_APP -v ON_ERROR_STOP=1 \\
--        -f scripts/fix_app_db_privileges.sql
--
-- Thay TEN_USER_APP đúng với DB_USER của bạn (vd. abac_user, thinhgia, ...).
--
-- PostgreSQL 14+: nếu GRANT EXECUTE ON FUNCTION báo không tìm thấy, liệt kê chữ ký:
--   \df request_access
-- =============================================================================

-- SEQUENCE: cần USAGE + SELECT cho mọi cột SERIAL/BIGSERIAL khi INSERT
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";

-- Bảng PEP/PDP ghi khi kiểm tra truy cập
GRANT INSERT ON access_requests TO :"app_user";
GRANT INSERT ON access_decisions TO :"app_user";
GRANT INSERT ON audit_logs TO :"app_user";

-- Gọi hàm từ ứng dụng (chữ ký mặc định của prototype ABAC)
GRANT EXECUTE ON FUNCTION evaluate_access_dynamic(
    integer, integer, text, text, text, integer, text
) TO :"app_user";

GRANT EXECUTE ON FUNCTION request_access(
    integer, integer, text, text, text, integer, inet, text
) TO :"app_user";

-- (Tuỳ chọn) Bật/tắt chính sách từ UI
GRANT UPDATE ON policies TO :"app_user";

-- Benchmark PERF_BENCH: seed / cleanup luật + EAV
GRANT INSERT, DELETE ON policies TO :"app_user";
GRANT INSERT, DELETE ON policy_conditions TO :"app_user";
GRANT INSERT, DELETE ON user_attributes TO :"app_user";

-- Sau khi chạy scripts/perf_index_functions.sql, app_user gọi DDL index qua SECURITY DEFINER.
