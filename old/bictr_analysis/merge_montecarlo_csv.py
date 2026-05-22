#!/usr/bin/env python3
"""
Merge multiple montecarlo_results.csv files from parallel Monte Carlo shards.

plot_montecarlo.aggregate() pools all rows with the same (channel_type, mcs,
noise_power_dB), so independent shards (disjoint trial sets) can be combined
for presentation-quality statistics without re-running the simulator.

Usage:
  python3 merge_montecarlo_csv.py -o merged.csv shard1.csv shard2.csv ...
  python3 merge_montecarlo_csv.py -o merged/merged.csv montecarlo_results/*/*/montecarlo_results.csv

Trial indices need not be globally unique; pooling uses per-row tx/error counts.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        '-o', '--output', required=True,
        help='Output CSV path (directory must exist unless file in cwd)',
    )
    ap.add_argument(
        'inputs', nargs='+',
        help='Input montecarlo_results.csv paths',
    )
    args = ap.parse_args()

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames: list[str] | None = None
    n_in = 0
    n_rows = 0

    with out_path.open('w', newline='') as out_f:
        writer: csv.DictWriter | None = None

        for p in args.inputs:
            path = Path(p)
            if not path.is_file():
                print(f'WARNING: skip missing {path}', file=sys.stderr)
                continue
            with path.open(newline='') as in_f:
                r = csv.DictReader(in_f)
                if fieldnames is None:
                    fieldnames = r.fieldnames
                    if not fieldnames:
                        print(f'ERROR: no header in {path}', file=sys.stderr)
                        sys.exit(1)
                    writer = csv.DictWriter(out_f, fieldnames=fieldnames)
                    writer.writeheader()
                elif r.fieldnames != fieldnames:
                    print(
                        f'ERROR: header mismatch in {path}\n'
                        f'  expected {fieldnames}\n'
                        f'  got      {r.fieldnames}',
                        file=sys.stderr,
                    )
                    sys.exit(1)
                assert writer is not None
                for row in r:
                    writer.writerow(row)
                    n_rows += 1
            n_in += 1

    if n_in == 0 or writer is None:
        print('ERROR: no valid input files', file=sys.stderr)
        sys.exit(1)

    print(f'Merged {n_in} file(s), {n_rows} data rows → {out_path}')


if __name__ == '__main__':
    main()
