"""Load test TPS / P95 — mục 3.2.3 tiểu luận.

Gọi request_access() (PEP + PDP + ghi access_requests/decisions) dưới tải đồng thời.
"""

from __future__ import annotations

import math
import os
import random
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from typing import Any

from psycopg2.extras import Json

from database import execute, get_connection, query_all, query_one

LOADTEST_CONFIGS: list[dict[str, Any]] = [
    {
        "id": "baseline",
        "label": "Baseline (không index)",
        "note": "Đo thực tế",
        "measured": True,
    },
    {
        "id": "btree",
        "label": "+ B-Tree (agency, attr_key, priority)",
        "note": "Đo thực tế",
        "measured": True,
    },
    {
        "id": "partial",
        "label": "+ Partial index is_enabled=true",
        "note": "Đo thực tế",
        "measured": True,
    },
    {
        "id": "partition",
        "label": "+ Chỉ mục thời gian audit (request_time / log_time)",
        "note": "Đo thực tế",
        "measured": True,
    },
]

CITUS_FORECAST: dict[str, Any] = {
    "id": "citus",
    "label": "+ Sharding 2 node (Citus) — dự báo",
    "note": "Ngoại suy từ [5]",
    "measured": False,
    "forecast": True,
    "tps": 4900,
    "p95_ms": 48,
}


def _default_duration() -> int:
    return max(10, min(120, int(os.getenv("ABAC_LOADTEST_DURATION_SEC", "30"))))


def _default_workers() -> int:
    return max(1, min(16, int(os.getenv("ABAC_LOADTEST_WORKERS", "4"))))


def _default_warmup() -> int:
    return max(0, min(200, int(os.getenv("ABAC_LOADTEST_WARMUP", "50"))))


def _loadtest_functions_available() -> bool:
    row = query_one(
        """
        SELECT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'loadtest_apply_config'
        ) AS ok
        """
    )
    return bool(row and row.get("ok"))


def history_table_ready() -> bool:
    row = query_one(
        """
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = 'loadtest_history'
        ) AS ok
        """
    )
    return bool(row and row.get("ok"))


def get_status() -> dict[str, Any]:
    counts = query_one(
        """
        SELECT
            (SELECT COUNT(*)::BIGINT FROM policies WHERE is_enabled = TRUE) AS enabled_policies,
            (SELECT COUNT(*)::BIGINT FROM users) AS users,
            (SELECT COUNT(*)::BIGINT FROM resources) AS resources,
            (SELECT COUNT(*)::BIGINT FROM access_requests) AS access_requests
        """
    )
    lt_indexes = query_all(
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public' AND indexname LIKE 'idx_lt_%'
        ORDER BY indexname
        """
    )
    return {
        "counts": counts,
        "loadtest_functions_available": _loadtest_functions_available(),
        "history_table_ready": history_table_ready(),
        "active_loadtest_indexes": [r["indexname"] for r in lt_indexes],
        "defaults": {
            "duration_sec": _default_duration(),
            "workers": _default_workers(),
            "warmup_requests": _default_warmup(),
        },
        "configs": LOADTEST_CONFIGS,
        "citus_forecast": CITUS_FORECAST,
    }


def apply_loadtest_config(config_id: str) -> None:
    if config_id not in {c["id"] for c in LOADTEST_CONFIGS}:
        raise ValueError(f"config không hợp lệ: {config_id}")
    if _loadtest_functions_available():
        query_one("SELECT loadtest_apply_config(%s) AS applied", (config_id,))
        return
    raise RuntimeError(
        "Chưa cài loadtest_apply_config — chạy scripts/loadtest_functions.sql"
    )


def restore_loadtest_indexes() -> None:
    if _loadtest_functions_available():
        query_one("SELECT loadtest_restore_indexes() AS applied")
        return
    query_one("SELECT loadtest_drop_lt_indexes()")


def _random_pairs(n: int) -> list[tuple[int, int]]:
    rows = query_all(
        """
        WITH ub AS (SELECT MIN(user_id) AS min_id, MAX(user_id) AS max_id FROM users),
        rb AS (SELECT MIN(resource_id) AS min_id, MAX(resource_id) AS max_id FROM resources),
        picks AS (
            SELECT
                (ub.min_id + floor(random() * GREATEST(ub.max_id - ub.min_id + 1, 1)))::int AS uid_guess,
                (rb.min_id + floor(random() * GREATEST(rb.max_id - rb.min_id + 1, 1)))::int AS rid_guess
            FROM generate_series(1, %s) gs
            CROSS JOIN ub CROSS JOIN rb
        )
        SELECT u.user_id, r.resource_id
        FROM picks p
        JOIN users u ON u.user_id = p.uid_guess
        JOIN resources r ON r.resource_id = p.rid_guess
        """,
        (n,),
    )
    return [(int(r["user_id"]), int(r["resource_id"])) for r in rows]


def _call_request_access(uid: int, rid: int) -> float:
    """Trả về latency ms (ưu tiên evaluation_time_ms từ DB)."""
    hour = random.randint(0, 23)
    sql = """
        SELECT evaluation_time_ms
        FROM request_access(
            %s, %s, 'read', 'medium', 'internal', %s, NULL, 'normal'
        )
        LIMIT 1
    """
    t0 = time.perf_counter()
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, (uid, rid, hour))
            row = cur.fetchone()
    wall_ms = (time.perf_counter() - t0) * 1000.0
    if row and row[0] is not None:
        return float(row[0])
    return round(wall_ms, 2)


def _percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = max(0, min(len(s) - 1, math.ceil((p / 100.0) * len(s)) - 1))
    return round(s[idx], 2)


def _run_load_phase(
    pairs: list[tuple[int, int]],
    *,
    duration_sec: int,
    workers: int,
) -> dict[str, Any]:
    if not pairs:
        raise RuntimeError("Không có cặp user/resource để load test.")

    latencies: list[float] = []
    errors = 0
    pair_cycle = pairs.copy()
    random.shuffle(pair_cycle)
    pair_idx = 0

    def next_pair() -> tuple[int, int]:
        nonlocal pair_idx
        p = pair_cycle[pair_idx % len(pair_cycle)]
        pair_idx += 1
        return p

    def worker_task() -> float | None:
        try:
            uid, rid = next_pair()
            return _call_request_access(uid, rid)
        except Exception:
            return None

    t0 = time.perf_counter()
    deadline = t0 + duration_sec
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending: set = set()
        while time.perf_counter() < deadline or pending:
            while len(pending) < workers and time.perf_counter() < deadline:
                pending.add(pool.submit(worker_task))
            if not pending:
                break
            done, pending = wait(pending, timeout=0.15, return_when=FIRST_COMPLETED)
            for fut in done:
                try:
                    result = fut.result()
                    if result is None:
                        errors += 1
                    else:
                        latencies.append(result)
                except Exception:
                    errors += 1

    elapsed = max(0.001, time.perf_counter() - t0)
    completed = len(latencies)
    tps = round(completed / elapsed, 1)
    return {
        "duration_sec": round(elapsed, 2),
        "workers": workers,
        "completed": completed,
        "errors": errors,
        "tps": tps,
        "avg_ms": round(sum(latencies) / completed, 2) if completed else 0,
        "p95_ms": _percentile(latencies, 95),
        "p50_ms": _percentile(latencies, 50),
        "min_ms": round(min(latencies), 2) if latencies else 0,
        "max_ms": round(max(latencies), 2) if latencies else 0,
    }


def run_config_benchmark(
    config_id: str,
    *,
    duration_sec: int | None = None,
    workers: int | None = None,
    warmup: int | None = None,
) -> dict[str, Any]:
    cfg = next((c for c in LOADTEST_CONFIGS if c["id"] == config_id), None)
    if not cfg:
        raise ValueError(f"config không tồn tại: {config_id}")

    duration_sec = duration_sec or _default_duration()
    workers = workers or _default_workers()
    warmup = warmup if warmup is not None else _default_warmup()

    t_all = time.perf_counter()
    apply_loadtest_config(config_id)

    pool_size = max(workers * 10, 100)
    pairs = _random_pairs(pool_size)

    for uid, rid in pairs[:warmup]:
        try:
            _call_request_access(uid, rid)
        except Exception:
            pass

    stats = _run_load_phase(pairs, duration_sec=duration_sec, workers=workers)
    return {
        "config": cfg,
        "stats": stats,
        "elapsed_sec": round(time.perf_counter() - t_all, 2),
    }


def run_multi_loadtest(
    config_ids: list[str],
    *,
    duration_sec: int | None = None,
    workers: int | None = None,
    warmup: int | None = None,
    include_citus_forecast: bool = True,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    try:
        for cid in config_ids:
            results.append(
                run_config_benchmark(
                    cid,
                    duration_sec=duration_sec,
                    workers=workers,
                    warmup=warmup,
                )
            )
    finally:
        try:
            restore_loadtest_indexes()
        except Exception:
            pass

    payload: dict[str, Any] = {
        "runs": results,
        "duration_sec": duration_sec or _default_duration(),
        "workers": workers or _default_workers(),
        "warmup": warmup if warmup is not None else _default_warmup(),
        "table_rows": _build_table_rows(results),
    }
    if include_citus_forecast:
        payload["forecast_row"] = {
            **CITUS_FORECAST,
            "tps": CITUS_FORECAST["tps"],
            "p95_ms": CITUS_FORECAST["p95_ms"],
        }
    return payload


def _build_table_rows(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for run in runs:
        cfg = run.get("config") or {}
        st = run.get("stats") or {}
        rows.append(
            {
                "config_id": cfg.get("id"),
                "label": cfg.get("label"),
                "note": cfg.get("note"),
                "tps": st.get("tps"),
                "p95_ms": st.get("p95_ms"),
                "avg_ms": st.get("avg_ms"),
                "completed": st.get("completed"),
            }
        )
    return rows


def save_loadtest_history(payload: dict[str, Any], note: str | None = None) -> int:
    if not history_table_ready():
        raise RuntimeError(
            "Chưa có bảng loadtest_history — chạy scripts/loadtest_history.sql"
        )
    row = query_one(
        """
        INSERT INTO loadtest_history (duration_sec, workers, note, payload)
        VALUES (%s, %s, %s, %s)
        RETURNING history_id
        """,
        (
            int(payload.get("duration_sec") or _default_duration()),
            int(payload.get("workers") or _default_workers()),
            (note or "").strip() or None,
            Json(payload),
        ),
    )
    return int(row["history_id"])


def list_loadtest_history(limit: int = 30) -> list[dict[str, Any]]:
    if not history_table_ready():
        return []
    limit = max(1, min(100, int(limit)))
    rows = query_all(
        """
        SELECT history_id, created_at, duration_sec, workers, note, payload
        FROM loadtest_history
        ORDER BY created_at DESC
        LIMIT %s
        """,
        (limit,),
    )
    out = []
    for r in rows:
        payload = r.get("payload") or {}
        created = r.get("created_at")
        out.append(
            {
                "history_id": r["history_id"],
                "created_at": created.isoformat() if hasattr(created, "isoformat") else created,
                "duration_sec": r["duration_sec"],
                "workers": r["workers"],
                "note": r.get("note"),
                "row_count": len(payload.get("table_rows") or []),
            }
        )
    return out


def get_loadtest_history(history_id: int) -> dict[str, Any] | None:
    if not history_table_ready():
        return None
    row = query_one(
        """
        SELECT history_id, created_at, duration_sec, workers, note, payload
        FROM loadtest_history WHERE history_id = %s
        """,
        (int(history_id),),
    )
    if not row:
        return None
    created = row.get("created_at")
    payload = row.get("payload") or {}
    return {
        "history_id": row["history_id"],
        "created_at": created.isoformat() if hasattr(created, "isoformat") else created,
        "duration_sec": row["duration_sec"],
        "workers": row["workers"],
        "note": row.get("note"),
        "payload": payload,
    }


def delete_loadtest_history(history_id: int) -> bool:
    if not history_table_ready():
        return False
    execute("DELETE FROM loadtest_history WHERE history_id = %s", (int(history_id),))
    return True
