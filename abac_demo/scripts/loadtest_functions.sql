-- Cấu hình chỉ mục cho load test mục 3.2.3 (TPS / P95).
-- Chạy một lần:
--   sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/loadtest_functions.sql
--
-- App gọi: SELECT loadtest_apply_config('baseline'|'btree'|'partial'|'partition');

CREATE OR REPLACE FUNCTION loadtest_drop_lt_indexes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DROP INDEX IF EXISTS idx_lt_users_agency;
    DROP INDEX IF EXISTS idx_lt_user_attrs_key;
    DROP INDEX IF EXISTS idx_lt_user_attrs_valid;
    DROP INDEX IF EXISTS idx_lt_policies_enabled;
    DROP INDEX IF EXISTS idx_lt_policies_partial;
    DROP INDEX IF EXISTS idx_lt_access_requests_time;
    DROP INDEX IF EXISTS idx_lt_audit_logs_time;
END;
$$;

CREATE OR REPLACE FUNCTION loadtest_apply_config(p_config TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    p_config := lower(trim(p_config));

    PERFORM loadtest_drop_lt_indexes();

    IF p_config = 'baseline' THEN
        ANALYZE users;
        ANALYZE user_attributes;
        ANALYZE policies;
        ANALYZE policy_conditions;
        ANALYZE access_requests;
        RETURN 'baseline';
    END IF;

    IF p_config NOT IN ('btree', 'partial', 'partition') THEN
        RAISE EXCEPTION 'loadtest config không hợp lệ: %', p_config;
    END IF;

    -- + B-Tree (agency, attr_key, priority)
    CREATE INDEX idx_lt_users_agency ON users (agency_code);
    CREATE INDEX idx_lt_user_attrs_key ON user_attributes (attr_key);
    CREATE INDEX idx_lt_user_attrs_valid ON user_attributes (valid_from, valid_to);
    CREATE INDEX idx_lt_policies_enabled ON policies (is_enabled, priority DESC);

    IF p_config IN ('partial', 'partition') THEN
        DROP INDEX IF EXISTS idx_lt_policies_enabled;
        CREATE INDEX idx_lt_policies_partial ON policies (priority DESC)
            WHERE is_enabled = TRUE;
    END IF;

    IF p_config = 'partition' THEN
        -- Chỉ mục thời gian cho luồng audit (thay thế phân vùng đầy đủ trên demo single-node)
        CREATE INDEX idx_lt_access_requests_time ON access_requests (request_time DESC);
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = 'audit_logs'
        ) THEN
            IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'audit_logs' AND column_name = 'log_time'
            ) THEN
                EXECUTE 'CREATE INDEX idx_lt_audit_logs_time ON audit_logs (log_time DESC)';
            END IF;
        END IF;
    END IF;

    ANALYZE users;
    ANALYZE user_attributes;
    ANALYZE policies;
    ANALYZE policy_conditions;
    ANALYZE access_requests;

    RETURN p_config;
END;
$$;

CREATE OR REPLACE FUNCTION loadtest_restore_indexes()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM loadtest_drop_lt_indexes();
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'perf_restore_production_indexes'
    ) THEN
        PERFORM perf_restore_production_indexes();
    END IF;
    RETURN 'restored';
END;
$$;

GRANT EXECUTE ON FUNCTION loadtest_drop_lt_indexes() TO abac_user;
GRANT EXECUTE ON FUNCTION loadtest_apply_config(TEXT) TO abac_user;
GRANT EXECUTE ON FUNCTION loadtest_restore_indexes() TO abac_user;
