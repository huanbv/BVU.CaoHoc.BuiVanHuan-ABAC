-- Gọi evaluate_access_dynamic() hàng loạt trong PostgreSQL (một round-trip / đợt).
-- Giảm overhead Python↔DB; tổng thời gian PDP vẫn phụ thuộc số lần đánh giá.
--
--   sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/perf_eval_batch.sql

CREATE OR REPLACE FUNCTION perf_avg_eval_batch(
    p_user_ids INT[],
    p_resource_ids INT[],
    p_hours INT[]
)
RETURNS TABLE (
    avg_ms NUMERIC,
    sample_count INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    i INT;
    n INT;
    t_ms NUMERIC;
    total NUMERIC := 0;
    cnt INT := 0;
BEGIN
    n := LEAST(
        COALESCE(array_length(p_user_ids, 1), 0),
        COALESCE(array_length(p_resource_ids, 1), 0),
        COALESCE(array_length(p_hours, 1), 0)
    );
    IF n < 1 THEN
        avg_ms := 0;
        sample_count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    FOR i IN 1..n LOOP
        SELECT r.evaluation_time_ms INTO t_ms
        FROM evaluate_access_dynamic(
            p_user_ids[i],
            p_resource_ids[i],
            'read',
            'medium',
            'internal',
            p_hours[i],
            'normal'
        ) AS r
        LIMIT 1;

        IF t_ms IS NOT NULL THEN
            total := total + t_ms;
            cnt := cnt + 1;
        END IF;
    END LOOP;

    avg_ms := CASE WHEN cnt > 0 THEN ROUND(total / cnt, 2) ELSE 0 END;
    sample_count := cnt;
    RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION perf_avg_eval_batch(INT[], INT[], INT[]) TO abac_user;
