#!/usr/bin/env python3
"""
Parse two nrMAC_stats snapshots (start, end) and emit a CSV fragment
with the delta BLER counters. Called once per Monte Carlo trial by
run_montecarlo.sh.

Usage:
  python3 parse_montecarlo_point.py <start_stats_file> <end_stats_file>

Prints one line to stdout:
  dl_first_tx,dl_errors,dl_bler,dl_harq,ul_first_tx,ul_errors,ul_bler
"""

import re
import sys


def extract(text: str) -> dict:
    d: dict = {}
    m = re.search(r'dlsch_rounds\s+([\d/]+)', text)
    if m:
        parts = m.group(1).split('/')
        d['dl_rounds'] = [int(x) for x in parts]
    else:
        d['dl_rounds'] = [0, 0, 0, 0]

    m = re.search(r'dlsch_errors\s+(\d+)', text)
    d['dl_errors'] = int(m.group(1)) if m else 0

    m = re.search(r'ulsch_rounds\s+([\d/]+)', text)
    if m:
        parts = m.group(1).split('/')
        d['ul_rounds'] = [int(x) for x in parts]
    else:
        d['ul_rounds'] = [0, 0, 0, 0]

    m = re.search(r'ulsch_errors\s+(\d+)', text)
    d['ul_errors'] = int(m.group(1)) if m else 0
    return d


def main():
    if len(sys.argv) != 3:
        print("0,0,0.0,0/0/0/0,0,0,0.0")
        sys.exit(0)

    with open(sys.argv[1]) as f:
        start = extract(f.read())
    with open(sys.argv[2]) as f:
        end = extract(f.read())

    dl_r0 = end['dl_rounds'][0] - start['dl_rounds'][0]
    dl_err = end['dl_errors'] - start['dl_errors']
    dl_bler = dl_err / dl_r0 if dl_r0 > 0 else 0.0

    dl_harq = '/'.join(
        str(end['dl_rounds'][i] - start['dl_rounds'][i])
        for i in range(min(len(end['dl_rounds']), len(start['dl_rounds'])))
    )

    ul_r0 = end['ul_rounds'][0] - start['ul_rounds'][0]
    ul_err = end['ul_errors'] - start['ul_errors']
    ul_bler = ul_err / ul_r0 if ul_r0 > 0 else 0.0

    print(f"{dl_r0},{dl_err},{dl_bler:.6f},{dl_harq},{ul_r0},{ul_err},{ul_bler:.6f}")


if __name__ == '__main__':
    main()
