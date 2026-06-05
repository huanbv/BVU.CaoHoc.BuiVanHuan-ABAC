#!/usr/bin/env python3
"""CLI load test TPS/P95 trên VPS (mục 3.2.3).

Ví dụ:
  cd /var/www/abac/abac_demo
  source venv/bin/activate
  set -a && source /etc/abac-app.env && set +a
  python scripts/run_loadtest_cli.py --duration 30 --workers 4
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from loadtest_bench import (  # noqa: E402
    LOADTEST_CONFIGS,
    run_multi_loadtest,
    save_loadtest_history,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="ABAC load test TPS/P95")
    parser.add_argument(
        "--configs",
        default="baseline,btree,partial,partition",
        help="Danh sách config_id, phân tách bằng dấu phẩy",
    )
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--note", default="")
    parser.add_argument("--save", action="store_true", help="Lưu vào loadtest_history")
    args = parser.parse_args()

    config_ids = [x.strip() for x in args.configs.split(",") if x.strip()]
    valid = {c["id"] for c in LOADTEST_CONFIGS}
    for cid in config_ids:
        if cid not in valid:
            print(f"config không hợp lệ: {cid}", file=sys.stderr)
            return 1

    result = run_multi_loadtest(
        config_ids,
        duration_sec=args.duration,
        workers=args.workers,
        warmup=args.warmup,
    )
    if args.save:
        try:
            hid = save_loadtest_history(result, note=args.note or None)
            result["history_id"] = hid
        except Exception as exc:
            result["history_save_error"] = str(exc)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
