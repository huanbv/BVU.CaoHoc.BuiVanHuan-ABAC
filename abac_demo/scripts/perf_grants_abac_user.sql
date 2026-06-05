-- Chạy một lần (copy-paste, không cần -v app_user):
--   sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/perf_grants_abac_user.sql
--
-- Nếu DB_USER khác abac_user: sửa tên role bên dưới rồi chạy lại.

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO abac_user;
GRANT INSERT ON access_requests, access_decisions, audit_logs TO abac_user;
GRANT UPDATE, INSERT, DELETE ON policies TO abac_user;
GRANT INSERT, DELETE ON policy_conditions, user_attributes TO abac_user;

GRANT EXECUTE ON FUNCTION evaluate_access_dynamic(
    integer, integer, text, text, text, integer, text
) TO abac_user;

GRANT EXECUTE ON FUNCTION request_access(
    integer, integer, text, text, text, integer, inet, text
) TO abac_user;
