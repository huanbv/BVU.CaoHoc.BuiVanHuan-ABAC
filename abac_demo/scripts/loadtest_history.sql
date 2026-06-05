-- Lịch sử load test TPS/P95 (mục 3.2.3).
--   sudo -u postgres psql -d abac_demo -v ON_ERROR_STOP=1 -f scripts/loadtest_history.sql

CREATE TABLE IF NOT EXISTS loadtest_history (
    history_id SERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duration_sec INT NOT NULL,
    workers INT NOT NULL,
    note TEXT,
    payload JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_loadtest_history_created
    ON loadtest_history (created_at DESC);

GRANT SELECT, INSERT, DELETE ON loadtest_history TO abac_user;
GRANT USAGE, SELECT ON SEQUENCE loadtest_history_history_id_seq TO abac_user;
