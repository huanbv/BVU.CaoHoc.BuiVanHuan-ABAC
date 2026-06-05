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

-- Lịch sử benchmark (sau khi chạy perf_benchmark_history.sql)
GRANT SELECT, INSERT, DELETE ON perf_benchmark_history TO abac_user;
GRANT USAGE, SELECT ON SEQUENCE perf_benchmark_history_history_id_seq TO abac_user;

-- Batch PDP trong DB (sau perf_eval_batch.sql)
GRANT EXECUTE ON FUNCTION perf_avg_eval_batch(INT[], INT[], INT[]) TO abac_user;

-- Load test 3.2.3 (sau loadtest_functions.sql + loadtest_history.sql)
GRANT EXECUTE ON FUNCTION loadtest_drop_lt_indexes() TO abac_user;
GRANT EXECUTE ON FUNCTION loadtest_apply_config(TEXT) TO abac_user;
GRANT EXECUTE ON FUNCTION loadtest_restore_indexes() TO abac_user;
GRANT SELECT, INSERT, DELETE ON loadtest_history TO abac_user;
GRANT USAGE, SELECT ON SEQUENCE loadtest_history_history_id_seq TO abac_user;
