"""Đánh giá hiệu năng PDP.evaluate_access_dynamic() — đo thực tế trên PostgreSQL.

Phương pháp (theo tiểu luận 3.2.2):
- Gọi evaluate_access_dynamic (không ghi access_requests).
- Mỗi đợt: N yêu cầu ngẫu nhiên; lặp B đợt lấy trung bình các đợt.
- Ba kịch bản chỉ mục: none | btree | btree_partial.
"""

from __future__ import annotations

import os
import random
import time
from typing import Any

from database import DB_CONFIG, execute, get_connection, query_all, query_one

# Chỉ mục PDP/EAV theo tiểu luận (tên cố định để DROP/CREATE)
IDX_USER_ATTR_KEY = "idx_user_attrs_key"
IDX_USER_ATTR_VALID = "idx_user_attrs_valid"
IDX_POLICIES_ENABLED = "idx_policies_enabled"
IDX_POLICIES_PARTIAL = "idx_policies_enabled_partial"

SCENARIOS = ("none", "btree", "btree_partial")

THESIS_PRESETS: list[dict[str, Any]] = [
    {
        "id": "s50_1k",
        "label": "50 luật · 1.000 EAV",
        "rules": 50,
        "eav_rows": 1_000,
        "thesis_ms": {"none": 28, "btree": 12, "btree_partial": 6},
    },
    {
        "id": "s200_10k",
        "label": "200 luật · 10.000 EAV",
        "rules": 200,
        "eav_rows": 10_000,
        "thesis_ms": {"none": 96, "btree": 31, "btree_partial": 11},
    },
    {
        "id": "s500_50k",
        "label": "500 luật · 50.000 EAV",
        "rules": 500,
        "eav_rows": 50_000,
        "thesis_ms": {"none": 245, "btree": 74, "btree_partial": 22},
    },
    {
        "id": "s1k_100k",
        "label": "1.000 luật · 100.000 EAV",
        "rules": 1_000,
        "eav_rows": 100_000,
        "thesis_ms": {"none": 487, "btree": 138, "btree_partial": 34},
    },
    {
        "id": "s2k_500k",
        "label": "2.000 luật · 500.000 EAV",
        "rules": 2_000,
        "eav_rows": 500_000,
        "thesis_ms": {"none": 1120, "btree": 312, "btree_partial": 71},
    },
]

BENCH_POLICY_PREFIX = "PERF_BENCH_"
BENCH_ATTR_PREFIX = "perf_bench_"


def _default_batches() -> int:
    return max(1, min(10, int(os.getenv("ABAC_PERF_BATCHES", "5"))))


def _default_requests() -> int:
    return max(10, min(2000, int(os.getenv("ABAC_PERF_REQUESTS_PER_BATCH", "1000"))))


def get_db_readiness() -> dict[str, Any]:
    """Kiểm tra quyền DB của user app — hiển thị trên UI trước khi seed/run."""
    row = query_one(
        """
        SELECT
            current_user AS db_session_user,
            has_table_privilege(current_user, 'policies', 'INSERT') AS can_insert_policies,
            has_table_privilege(current_user, 'policies', 'DELETE') AS can_delete_policies,
            has_table_privilege(current_user, 'policy_conditions', 'INSERT') AS can_insert_conditions,
            has_table_privilege(current_user, 'user_attributes', 'INSERT') AS can_insert_eav,
            has_table_privilege(current_user, 'audit_logs', 'INSERT') AS can_insert_audit,
            has_function_privilege(
                current_user,
                'evaluate_access_dynamic(integer,integer,text,text,text,integer,text)',
                'EXECUTE'
            ) AS can_execute_pdp
        """
    )
    return {
        "configured_db_user": DB_CONFIG.get("user"),
        "session": row,
        "perf_index_functions_installed": _perf_index_helpers_available(),
        "ready_for_seed": bool(
            row
            and row.get("can_insert_policies")
            and row.get("can_insert_conditions")
            and row.get("can_insert_eav")
            and row.get("can_insert_audit")
        ),
        "ready_for_run": bool(
            row
            and row.get("can_execute_pdp")
            and (
                _perf_index_helpers_available()
                or row.get("can_insert_policies")  # owner có thể DDL trực tiếp
            )
        ),
    }


def get_status() -> dict[str, Any]:
    counts = query_one(
        """
        SELECT
            (SELECT COUNT(*)::BIGINT FROM policies WHERE is_enabled = TRUE) AS enabled_policies,
            (SELECT COUNT(*)::BIGINT FROM policies WHERE policy_name LIKE %s) AS bench_policies,
            (SELECT COUNT(*)::BIGINT FROM user_attributes) AS total_eav,
            (SELECT COUNT(*)::BIGINT FROM user_attributes WHERE attr_key LIKE %s) AS bench_eav,
            (SELECT COUNT(*)::BIGINT FROM users) AS users,
            (SELECT COUNT(*)::BIGINT FROM resources) AS resources
        """,
        (f"{BENCH_POLICY_PREFIX}%", f"{BENCH_ATTR_PREFIX}%"),
    )
    indexes = query_all(
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename IN ('user_attributes', 'policies')
          AND indexname = ANY(%s)
        ORDER BY indexname
        """,
        (
            [
                IDX_USER_ATTR_KEY,
                IDX_USER_ATTR_VALID,
                IDX_POLICIES_ENABLED,
                IDX_POLICIES_PARTIAL,
            ],
        ),
    )
    return {
        "counts": counts,
        "readiness": get_db_readiness(),
        "active_perf_indexes": [r["indexname"] for r in indexes],
        "defaults": {
            "batches": _default_batches(),
            "requests_per_batch": _default_requests(),
        },
        "presets": THESIS_PRESETS,
        "scenarios": [
            {
                "id": "none",
                "label": "Không index (PDP/EAV)",
                "description": "DROP idx_user_attrs_key, idx_user_attrs_valid, idx_policies_*",
            },
            {
                "id": "btree",
                "label": "B-Tree",
                "description": "B-Tree attr_key, (valid_from, valid_to); idx_policies(is_enabled, priority)",
            },
            {
                "id": "btree_partial",
                "label": "B-Tree + Partial",
                "description": "B-Tree EAV + partial index policies WHERE is_enabled = TRUE",
            },
        ],
    }


def _perf_index_helpers_available() -> bool:
    row = query_one(
        """
        SELECT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = 'perf_apply_index_scenario'
        ) AS ok
        """
    )
    return bool(row and row.get("ok"))


def apply_index_scenario(scenario: str) -> None:
    if scenario not in SCENARIOS:
        raise ValueError(f"scenario không hợp lệ: {scenario}")
    if _perf_index_helpers_available():
        query_one("SELECT perf_apply_index_scenario(%s) AS applied", (scenario,))
        return
    # Fallback: DDL trực tiếp (cần user DB là owner bảng)
    for name in (
        IDX_USER_ATTR_KEY,
        IDX_USER_ATTR_VALID,
        IDX_POLICIES_ENABLED,
        IDX_POLICIES_PARTIAL,
    ):
        execute(f"DROP INDEX IF EXISTS {name}")
    if scenario == "none":
        return
    execute(f"CREATE INDEX {IDX_USER_ATTR_KEY} ON user_attributes (attr_key)")
    execute(
        f"CREATE INDEX {IDX_USER_ATTR_VALID} ON user_attributes (valid_from, valid_to)"
    )
    if scenario == "btree":
        execute(
            f"CREATE INDEX {IDX_POLICIES_ENABLED} ON policies (is_enabled, priority DESC)"
        )
    elif scenario == "btree_partial":
        execute(
            f"CREATE INDEX {IDX_POLICIES_PARTIAL} ON policies (priority DESC) "
            "WHERE is_enabled = TRUE"
        )
    execute("ANALYZE user_attributes")
    execute("ANALYZE policies")
    execute("ANALYZE policy_conditions")


def restore_production_indexes() -> None:
    """Khôi phục chỉ mục như ABAC_System_Prototype.sql sau benchmark."""
    if _perf_index_helpers_available():
        query_one("SELECT perf_restore_production_indexes() AS applied")
        return
    apply_index_scenario("btree")
    execute(f"DROP INDEX IF EXISTS {IDX_POLICIES_PARTIAL}")


def cleanup_benchmark_seed() -> dict[str, int]:
    before = get_status()["counts"]
    execute(
        """
        DELETE FROM policy_conditions
        WHERE policy_id IN (
            SELECT policy_id FROM policies WHERE policy_name LIKE %s
        )
        """,
        (f"{BENCH_POLICY_PREFIX}%",),
    )
    execute("DELETE FROM policies WHERE policy_name LIKE %s", (f"{BENCH_POLICY_PREFIX}%",))
    execute(
        "DELETE FROM user_attributes WHERE attr_key LIKE %s",
        (f"{BENCH_ATTR_PREFIX}%",),
    )
    after = get_status()["counts"]
    return {
        "removed_policies": int(before.get("bench_policies") or 0),
        "removed_eav": int(before.get("bench_eav") or 0),
        "remaining_policies": int(after.get("enabled_policies") or 0),
        "remaining_eav": int(after.get("total_eav") or 0),
    }


def seed_benchmark_scale(rules: int, eav_rows: int) -> dict[str, Any]:
    """Sinh luật PERF_BENCH_* và dòng EAV perf_bench_* (không xóa dữ liệu gốc)."""
    rules = max(1, min(10_000, int(rules)))
    eav_rows = max(0, min(2_000_000, int(eav_rows)))

    bounds = query_one(
        """
        SELECT
            COALESCE(MIN(user_id), 1) AS min_uid,
            COALESCE(MAX(user_id), 1) AS max_uid,
            COUNT(*)::INT AS user_count
        FROM users
        """
    )
    if not bounds or bounds["user_count"] < 1:
        raise RuntimeError("Chưa có users — cần seed users trước khi chạy benchmark.")

    cleanup_benchmark_seed()
    t0 = time.perf_counter()

    # Policies + 2 điều kiện/luật (lookup attr_key EAV)
    execute(
        f"""
        INSERT INTO policies (
            policy_name, description, effect, priority,
            target_resource_type, target_action, is_enabled
        )
        SELECT
            '{BENCH_POLICY_PREFIX}' || gs::TEXT,
            'Benchmark policy row ' || gs::TEXT,
            CASE WHEN gs %% 5 = 0 THEN 'permit' ELSE 'deny' END,
            50000 + gs,
            '*',
            '*',
            TRUE
        FROM generate_series(1, %s) AS gs
        """,
        (rules,),
    )
    execute(
        f"""
        INSERT INTO policy_conditions (
            policy_id, attribute_type, attribute_key, operator, compare_value, value_type
        )
        SELECT
            p.policy_id,
            'subject',
            '{BENCH_ATTR_PREFIX}' || ((p.policy_id %% 50) + 1)::TEXT,
            'eq',
            'bench_value',
            'text'
        FROM policies p
        WHERE p.policy_name LIKE %s
        """,
        (f"{BENCH_POLICY_PREFIX}%",),
    )
    execute(
        f"""
        INSERT INTO policy_conditions (
            policy_id, attribute_type, attribute_key, operator, compare_value, value_type
        )
        SELECT
            p.policy_id,
            'environment',
            'device_trust',
            'in',
            'high,medium,low',
            'list'
        FROM policies p
        WHERE p.policy_name LIKE %s
        """,
        (f"{BENCH_POLICY_PREFIX}%",),
    )

    if eav_rows > 0:
        # Phân bổ user_id theo modulo (O(n)), tránh OFFSET từng dòng — 500k EAV seed nhanh hơn rất nhiều.
        execute(
            f"""
            WITH ranked_users AS (
                SELECT
                    user_id,
                    (row_number() OVER (ORDER BY user_id) - 1)::bigint AS idx
                FROM users
            ),
            user_count AS (
                SELECT GREATEST(COUNT(*)::bigint, 1) AS n FROM ranked_users
            )
            INSERT INTO user_attributes (user_id, attr_key, attr_value, valid_from, valid_to)
            SELECT
                ru.user_id,
                '{BENCH_ATTR_PREFIX}' || ((gs %% 50) + 1)::TEXT,
                'bench_value',
                TIMESTAMPTZ '2020-01-01' + (gs * INTERVAL '1 millisecond'),
                CASE WHEN gs %% 17 = 0 THEN TIMESTAMPTZ '2019-12-31' ELSE NULL END
            FROM generate_series(1, %s) AS gs
            CROSS JOIN user_count uc
            JOIN ranked_users ru ON ru.idx = (gs - 1) %% uc.n
            """,
            (eav_rows,),
        )

    execute("ANALYZE policies")
    execute("ANALYZE policy_conditions")
    execute("ANALYZE user_attributes")

    elapsed = round(time.perf_counter() - t0, 2)
    st = get_status()
    return {
        "seeded_rules": rules,
        "seeded_eav_rows": eav_rows,
        "elapsed_sec": elapsed,
        "counts": st["counts"],
    }


def _random_pairs(requests: int) -> list[tuple[int, int]]:
    """Lấy cặp user/resource ngẫu nhiên nhanh (không ORDER BY random() trên 250k dòng)."""
    rows = query_all(
        """
        WITH ub AS (
            SELECT MIN(user_id) AS min_id, MAX(user_id) AS max_id, COUNT(*)::bigint AS cnt
            FROM users
        ),
        rb AS (
            SELECT MIN(resource_id) AS min_id, MAX(resource_id) AS max_id, COUNT(*)::bigint AS cnt
            FROM resources
        ),
        picks AS (
            SELECT
                gs,
                (ub.min_id + floor(random() * GREATEST(ub.max_id - ub.min_id + 1, 1)))::int AS uid_guess,
                (rb.min_id + floor(random() * GREATEST(rb.max_id - rb.min_id + 1, 1)))::int AS rid_guess
            FROM generate_series(1, %s) AS gs
            CROSS JOIN ub
            CROSS JOIN rb
        )
        SELECT u.user_id, r.resource_id
        FROM picks p
        JOIN users u ON u.user_id = p.uid_guess
        JOIN resources r ON r.resource_id = p.rid_guess
        """,
        (requests,),
    )
    if len(rows) < max(1, requests // 2):
        raise RuntimeError(
            f"Không lấy đủ cặp user/resource ngẫu nhiên ({len(rows)}/{requests}). "
            "Kiểm tra dữ liệu users/resources."
        )
    return [(int(r["user_id"]), int(r["resource_id"])) for r in rows]


def _run_eval_batch(pairs: list[tuple[int, int]]) -> list[float]:
    """Trả về danh sách độ trễ PDP (ms) — ưu tiên evaluation_time_ms từ DB, fallback đo wall-clock."""
    times: list[float] = []
    sql = """
        SELECT evaluation_time_ms
        FROM evaluate_access_dynamic(
            %s, %s, 'read', 'medium', 'internal', %s, 'normal'
        )
        LIMIT 1
    """
    with get_connection() as conn:
        with conn.cursor() as cur:
            for uid, rid in pairs:
                hour = random.randint(0, 23)
                t0 = time.perf_counter()
                cur.execute(sql, (uid, rid, hour))
                row = cur.fetchone()
                wall_ms = (time.perf_counter() - t0) * 1000.0
                if row and row[0] is not None:
                    times.append(float(row[0]))
                elif wall_ms > 0:
                    times.append(round(wall_ms, 2))
    return times


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def run_preset_benchmark(
    preset_id: str,
    scenarios: list[str],
    *,
    batches: int | None = None,
    requests_per_batch: int | None = None,
) -> dict[str, Any]:
    preset = next((p for p in THESIS_PRESETS if p["id"] == preset_id), None)
    if not preset:
        raise ValueError(f"preset không tồn tại: {preset_id}")

    batches = batches or _default_batches()
    requests_per_batch = requests_per_batch or _default_requests()

    for sc in scenarios:
        if sc not in SCENARIOS:
            raise ValueError(f"scenario không hợp lệ: {sc}")

    st = get_status()
    enabled = int(st["counts"].get("enabled_policies") or 0)
    eav_total = int(st["counts"].get("total_eav") or 0)
    if enabled < preset["rules"]:
        raise RuntimeError(
            f"Cần ít nhất {preset['rules']} luật đang bật (hiện {enabled}). "
            "Chạy Seed quy mô trước."
        )
    if eav_total < preset["eav_rows"]:
        raise RuntimeError(
            f"Cần ít nhất {preset['eav_rows']} dòng user_attributes (hiện {eav_total}). "
            "Chạy Seed quy mô trước."
        )

    scenario_results: dict[str, Any] = {}
    t_all = time.perf_counter()

    try:
        for scenario in scenarios:
            apply_index_scenario(scenario)
            batch_avgs: list[float] = []
            batch_details: list[dict[str, Any]] = []

            for b in range(1, batches + 1):
                pairs = _random_pairs(requests_per_batch)
                t_batch = time.perf_counter()
                samples = _run_eval_batch(pairs)
                wall_ms = (time.perf_counter() - t_batch) * 1000.0
                avg_ms = round(_mean(samples), 2)
                batch_avgs.append(avg_ms)
                batch_details.append(
                    {
                        "batch": b,
                        "requests": len(pairs),
                        "samples": len(samples),
                        "avg_eval_ms": avg_ms,
                        "wall_ms": round(wall_ms, 1),
                    }
                )

            overall = round(_mean(batch_avgs), 2)
            thesis = preset["thesis_ms"].get(scenario)
            scenario_results[scenario] = {
                "avg_ms": overall,
                "batch_avgs_ms": batch_avgs,
                "batches": batch_details,
                "thesis_ms": thesis,
                "ratio_vs_thesis": (
                    round(overall / thesis, 2) if thesis and thesis > 0 else None
                ),
            }
    finally:
        restore_production_indexes()

    return {
        "preset": preset,
        "method": {
            "function": "evaluate_access_dynamic",
            "batches": batches,
            "requests_per_batch": requests_per_batch,
            "note": "Trung bình của trung bình từng đợt (pgbench-style).",
        },
        "scenarios": scenario_results,
        "elapsed_sec": round(time.perf_counter() - t_all, 2),
        "counts_at_run": st["counts"],
    }


def run_multi_benchmark(
    preset_ids: list[str],
    scenarios: list[str],
    *,
    batches: int | None = None,
    requests_per_batch: int | None = None,
) -> dict[str, Any]:
    results = []
    for pid in preset_ids:
        results.append(
            run_preset_benchmark(
                pid,
                scenarios,
                batches=batches,
                requests_per_batch=requests_per_batch,
            )
        )
    return {
        "runs": results,
        "scenarios": scenarios,
        "batches": batches or _default_batches(),
        "requests_per_batch": requests_per_batch or _default_requests(),
    }
