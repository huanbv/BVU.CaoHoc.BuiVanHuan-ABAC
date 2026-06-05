-- Lịch sử chạy benchmark PDP — lưu trên PostgreSQL để so sánh nhiều lần đo.
--
-- Chạy một lần:
--   sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/perf_benchmark_history.sql
--
-- Nếu DB_USER khác abac_user: sửa GRANT bên dưới.

CREATE TABLE IF NOT EXISTS perf_benchmark_history (
    history_id SERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    batches INT NOT NULL,
    requests_per_batch INT NOT NULL,
    scenarios TEXT[] NOT NULL DEFAULT '{}',
    total_elapsed_sec NUMERIC(12, 2),
    note TEXT,
    payload JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_perf_benchmark_history_created
    ON perf_benchmark_history (created_at DESC);

GRANT SELECT, INSERT, DELETE ON perf_benchmark_history TO abac_user;
GRANT USAGE, SELECT ON SEQUENCE perf_benchmark_history_history_id_seq TO abac_user;
