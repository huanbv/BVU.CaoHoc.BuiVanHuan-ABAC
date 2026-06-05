-- =============================================================================
-- DDL chỉ mục benchmark — chạy bằng superuser (postgres), một lần trên VPS.
--
--   psql -U postgres -d abac_demo -v app_user=abac_user -v ON_ERROR_STOP=1 \
--        -f scripts/perf_index_functions.sql
--
-- App user (abac_user) gọi qua SELECT perf_apply_index_scenario('btree');
-- =============================================================================

CREATE OR REPLACE FUNCTION perf_apply_index_scenario(p_scenario TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    p_scenario := lower(trim(p_scenario));

    DROP INDEX IF EXISTS idx_user_attrs_key;
    DROP INDEX IF EXISTS idx_user_attrs_valid;
    DROP INDEX IF EXISTS idx_policies_enabled;
    DROP INDEX IF EXISTS idx_policies_enabled_partial;

    IF p_scenario = 'none' THEN
        ANALYZE user_attributes;
        ANALYZE policies;
        ANALYZE policy_conditions;
        RETURN 'none';
    END IF;

    IF p_scenario NOT IN ('btree', 'btree_partial') THEN
        RAISE EXCEPTION 'scenario không hợp lệ: %', p_scenario;
    END IF;

    CREATE INDEX idx_user_attrs_key ON user_attributes (attr_key);
    CREATE INDEX idx_user_attrs_valid ON user_attributes (valid_from, valid_to);

    IF p_scenario = 'btree' THEN
        CREATE INDEX idx_policies_enabled ON policies (is_enabled, priority DESC);
    ELSIF p_scenario = 'btree_partial' THEN
        CREATE INDEX idx_policies_enabled_partial ON policies (priority DESC)
            WHERE is_enabled = TRUE;
    END IF;

    ANALYZE user_attributes;
    ANALYZE policies;
    ANALYZE policy_conditions;
    RETURN p_scenario;
END;
$$;

CREATE OR REPLACE FUNCTION perf_restore_production_indexes()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM perf_apply_index_scenario('btree');
    DROP INDEX IF EXISTS idx_policies_enabled_partial;
    RETURN 'btree';
END;
$$;

GRANT EXECUTE ON FUNCTION perf_apply_index_scenario(TEXT) TO :"app_user";
GRANT EXECUTE ON FUNCTION perf_restore_production_indexes() TO :"app_user";
