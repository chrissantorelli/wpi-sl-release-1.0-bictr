#!/usr/bin/env python3
"""Live progress bar for parallel run_montecarlo.sh shards."""

from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

try:
    from tqdm import tqdm
except ImportError:
    tqdm = None  # type: ignore


def count_data_rows(csv_path: Path) -> int:
    if not csv_path.is_file():
        return 0
    try:
        with csv_path.open(newline="") as f:
            reader = csv.reader(f)
            next(reader, None)  # header
            return sum(1 for _ in reader)
    except OSError:
        return 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-root", required=True, help="Parallel run directory")
    ap.add_argument("--total-rows", type=int, required=True, help="Expected data rows (all workers)")
    ap.add_argument("--workers", type=int, required=True)
    ap.add_argument("--poll", type=float, default=2.0)
    ap.add_argument(
        "--desc",
        default="Monte Carlo sweep",
        help="tqdm description (default: Monte Carlo sweep)",
    )
    args = ap.parse_args()

    root = Path(args.run_root)
    shard_glob = sorted(root.glob("worker_*/montecarlo_results.csv"))

    if tqdm is None:
        print("Install tqdm for a progress bar: pip3 install tqdm", file=sys.stderr)

    last = -1
    bar = tqdm(total=args.total_rows, unit="trial", desc=args.desc) if tqdm else None

    while True:
        done = 0
        alive = 0
        for w in range(args.workers):
            flag = root / f"worker_{w}.done"
            if flag.is_file():
                alive += 1
            shard = root / f"worker_{w}" / "montecarlo_results.csv"
            done += count_data_rows(shard)

        if bar:
            bar.n = min(done, args.total_rows)
            bar.set_postfix(workers=f"{alive}/{args.workers}", refresh=False)
            bar.refresh()
        elif done != last:
            pct = 100.0 * done / args.total_rows if args.total_rows else 0.0
            print(
                f"\rProgress: {done}/{args.total_rows} trials ({pct:.1f}%) "
                f"workers finished {alive}/{args.workers}",
                end="",
                flush=True,
            )
            last = done

        if alive >= args.workers:
            if bar:
                bar.n = min(done, args.total_rows)
                bar.close()
            elif last >= 0:
                print()
            break

        time.sleep(args.poll)

    if not bar and last < 0:
        print(f"Done: {done}/{args.total_rows} trials")


if __name__ == "__main__":
    main()
