-- ============================================================================
-- ABAC Demo — bulk seed ~500 000 rows (250k users + 250k resources)
-- Target: PostgreSQL 14+ (matches ABAC_System_Prototype.sql)
--
-- Prerequisites:
--   1) Đã import đầy đủ prototype (ít nhất có bảng agencies + users/resource seed nhỏ).
--   2) Backup DB trước: pg_dump …
--
-- Usage:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/bulk_seed_500k.sql
--
-- Mỗi khối chèn theo rang MAX(..)+1..MAX(..)+50000 (snapshot một lần / câu lệnh).
-- Chạy một lần ~500k tổng; chạy lại sẽ thêm tiếp 500k (trừ khi overlap email/name).
-- ============================================================================

\timing on

-- --- 250k USERS (5 x 50k) ---
INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department)
SELECT
    'Bulk User ' || s.n::text,
    'bu' || s.n::text || '@load.abac.test',
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['active', 'active', 'active', 'inactive', 'suspended']::text[])[1 + ((s.n::int - 1) % 5)],
    'Load CL' || (1 + ((s.n::int - 1) % 5))::text,
    'Dept ' || (1 + ((s.n::int - 1) % 30))::text
FROM generate_series(
    (SELECT COALESCE(MAX(user_id), 0) + 1 FROM users),
    (SELECT COALESCE(MAX(user_id), 0) + 50000 FROM users)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac;

INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department)
SELECT
    'Bulk User ' || s.n::text,
    'bu' || s.n::text || '@load.abac.test',
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['active', 'active', 'active', 'inactive', 'suspended']::text[])[1 + ((s.n::int - 1) % 5)],
    'Load CL' || (1 + ((s.n::int - 1) % 5))::text,
    'Dept ' || (1 + ((s.n::int - 1) % 30))::text
FROM generate_series(
    (SELECT COALESCE(MAX(user_id), 0) + 1 FROM users),
    (SELECT COALESCE(MAX(user_id), 0) + 50000 FROM users)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac;

INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department)
SELECT
    'Bulk User ' || s.n::text,
    'bu' || s.n::text || '@load.abac.test',
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['active', 'active', 'active', 'inactive', 'suspended']::text[])[1 + ((s.n::int - 1) % 5)],
    'Load CL' || (1 + ((s.n::int - 1) % 5))::text,
    'Dept ' || (1 + ((s.n::int - 1) % 30))::text
FROM generate_series(
    (SELECT COALESCE(MAX(user_id), 0) + 1 FROM users),
    (SELECT COALESCE(MAX(user_id), 0) + 50000 FROM users)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac;

INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department)
SELECT
    'Bulk User ' || s.n::text,
    'bu' || s.n::text || '@load.abac.test',
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['active', 'active', 'active', 'inactive', 'suspended']::text[])[1 + ((s.n::int - 1) % 5)],
    'Load CL' || (1 + ((s.n::int - 1) % 5))::text,
    'Dept ' || (1 + ((s.n::int - 1) % 30))::text
FROM generate_series(
    (SELECT COALESCE(MAX(user_id), 0) + 1 FROM users),
    (SELECT COALESCE(MAX(user_id), 0) + 50000 FROM users)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac;

INSERT INTO users (full_name, email, agency_code, clearance_level, employment_status, position, department)
SELECT
    'Bulk User ' || s.n::text,
    'bu' || s.n::text || '@load.abac.test',
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['active', 'active', 'active', 'inactive', 'suspended']::text[])[1 + ((s.n::int - 1) % 5)],
    'Load CL' || (1 + ((s.n::int - 1) % 5))::text,
    'Dept ' || (1 + ((s.n::int - 1) % 30))::text
FROM generate_series(
    (SELECT COALESCE(MAX(user_id), 0) + 1 FROM users),
    (SELECT COALESCE(MAX(user_id), 0) + 50000 FROM users)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac;

-- --- 250k RESOURCES (5 x 50k) ---
INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status)
SELECT
    'Bulk Record ' || s.n::text,
    rt.t[1 + ((s.n::int - 1) % 7)],
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['north', 'central', 'south']::text[])[1 + ((s.n::int - 1) % 3)],
    (ARRAY['active', 'archived', 'under_investigation']::text[])[1 + ((s.n::int - 1) % 3)]
FROM generate_series(
    (SELECT COALESCE(MAX(resource_id), 0) + 1 FROM resources),
    (SELECT COALESCE(MAX(resource_id), 0) + 50000 FROM resources)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac,
LATERAL (
    SELECT ARRAY['medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative']::text[] AS t
) rt;

INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status)
SELECT
    'Bulk Record ' || s.n::text,
    rt.t[1 + ((s.n::int - 1) % 7)],
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['north', 'central', 'south']::text[])[1 + ((s.n::int - 1) % 3)],
    (ARRAY['active', 'archived', 'under_investigation']::text[])[1 + ((s.n::int - 1) % 3)]
FROM generate_series(
    (SELECT COALESCE(MAX(resource_id), 0) + 1 FROM resources),
    (SELECT COALESCE(MAX(resource_id), 0) + 50000 FROM resources)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac,
LATERAL (
    SELECT ARRAY['medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative']::text[] AS t
) rt;

INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status)
SELECT
    'Bulk Record ' || s.n::text,
    rt.t[1 + ((s.n::int - 1) % 7)],
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['north', 'central', 'south']::text[])[1 + ((s.n::int - 1) % 3)],
    (ARRAY['active', 'archived', 'under_investigation']::text[])[1 + ((s.n::int - 1) % 3)]
FROM generate_series(
    (SELECT COALESCE(MAX(resource_id), 0) + 1 FROM resources),
    (SELECT COALESCE(MAX(resource_id), 0) + 50000 FROM resources)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac,
LATERAL (
    SELECT ARRAY['medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative']::text[] AS t
) rt;

INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status)
SELECT
    'Bulk Record ' || s.n::text,
    rt.t[1 + ((s.n::int - 1) % 7)],
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['north', 'central', 'south']::text[])[1 + ((s.n::int - 1) % 3)],
    (ARRAY['active', 'archived', 'under_investigation']::text[])[1 + ((s.n::int - 1) % 3)]
FROM generate_series(
    (SELECT COALESCE(MAX(resource_id), 0) + 1 FROM resources),
    (SELECT COALESCE(MAX(resource_id), 0) + 50000 FROM resources)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac,
LATERAL (
    SELECT ARRAY['medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative']::text[] AS t
) rt;

INSERT INTO resources (resource_name, resource_type, owner_agency, classification_level, managing_region, record_status)
SELECT
    'Bulk Record ' || s.n::text,
    rt.t[1 + ((s.n::int - 1) % 7)],
    (ac.codes)[1 + ((s.n::int - 1) % cardinality(ac.codes))]::varchar(10),
    1 + ((s.n::int - 1) % 5),
    (ARRAY['north', 'central', 'south']::text[])[1 + ((s.n::int - 1) % 3)],
    (ARRAY['active', 'archived', 'under_investigation']::text[])[1 + ((s.n::int - 1) % 3)]
FROM generate_series(
    (SELECT COALESCE(MAX(resource_id), 0) + 1 FROM resources),
    (SELECT COALESCE(MAX(resource_id), 0) + 50000 FROM resources)
) AS s(n),
LATERAL (
    SELECT array_agg(agency_code ORDER BY agency_code)::varchar(10)[] AS codes FROM agencies
) ac,
LATERAL (
    SELECT ARRAY['medical', 'judicial', 'financial', 'military', 'diplomatic', 'civil', 'administrative']::text[] AS t
) rt;

SELECT setval(
    pg_get_serial_sequence('users', 'user_id'),
    COALESCE((SELECT MAX(user_id) FROM users), 1)
);

SELECT setval(
    pg_get_serial_sequence('resources', 'resource_id'),
    COALESCE((SELECT MAX(resource_id) FROM resources), 1)
);

SELECT 'users' AS tbl, COUNT(*)::bigint AS n FROM users
UNION ALL
SELECT 'resources', COUNT(*)::bigint FROM resources;
