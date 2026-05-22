#!/usr/bin/env python3
"""
Plot DL/UL BLER vs cumulative number of first transmissions (not wall time).

Uses stats_timeseries.csv from run_experiment / sweep runs. Each point is one sampling
interval: x = cumulative dlsch/ulsch round-0 count at end of interval, y = BLER in that
interval (0 if no new TBs in interval).

Usage:
  python3 plot_bler_vs_tx.py DIR1 [DIR2 ...] [--labels L1 L2 ...] -o OUTDIR
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from parse_stats import (
    load_timeseries,
    compute_deltas,
    annotate_cumulative_tx,
)

COLORS = ["#D64045", "#E67E22", "#2E86AB", "#1B998B", "#6A4C93", "#C73E1D"]
MARKERS = ["o", "v", "s", "^", "D", "P"]


def infer_label(p: Path) -> str:
    return p.name


def plot_direction(ax, series, direction: str):
    key_bler = "dl_bler" if direction == "DL" else "ul_bler"
    key_tx = "dl_tx_cum" if direction == "DL" else "ul_tx_cum"
    key_rate = "dl_first_tx" if direction == "DL" else "ul_first_tx"
    for s in series:
        pts = s["deltas"]
        if not pts:
            continue
        x = [p[key_tx] for p in pts if p[key_rate] > 0]
        y = [p[key_bler] for p in pts if p[key_rate] > 0]
        if not x:
            continue
        ax.plot(
            x,
            y,
            color=s["color"],
            marker=s["marker"],
            markersize=4,
            linewidth=1.2,
            label=s["label"],
            alpha=0.9,
        )
    ax.set_xlabel("Cumulative number of first transmissions (TBs)")
    ax.set_ylabel(f"{direction} BLER (per sample interval)")
    ax.set_title(f"{direction} BLER vs cumulative transmissions")
    ax.set_ylim(-0.02, 1.05)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dirs", nargs="+", help="Result directories with stats_timeseries.csv")
    ap.add_argument("-o", "--output", type=Path, required=True, help="Output directory")
    ap.add_argument("--labels", nargs="*", default=None)
    args = ap.parse_args()

    dirs = [Path(d).resolve() for d in args.dirs]
    if args.labels and len(args.labels) != len(dirs):
        print("ERROR: --labels must match number of dirs", file=sys.stderr)
        return 2
    labels = args.labels or [infer_label(d) for d in dirs]

    series = []
    for i, d in enumerate(dirs):
        csv_path = d / "stats_timeseries.csv"
        if not csv_path.is_file():
            print(f"ERROR: missing {csv_path}", file=sys.stderr)
            return 1
        samples = load_timeseries(str(csv_path))
        deltas = annotate_cumulative_tx(compute_deltas(samples))
        series.append(
            {
                "label": labels[i],
                "deltas": deltas,
                "color": COLORS[i % len(COLORS)],
                "marker": MARKERS[i % len(MARKERS)],
            }
        )

    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)

    plt.rcParams.update(
        {
            "figure.figsize": (8, 5),
            "figure.dpi": 150,
            "font.size": 11,
            "font.family": "serif",
            "axes.grid": True,
        }
    )

    fig1, ax1 = plt.subplots()
    plot_direction(ax1, series, "DL")
    fig1.tight_layout()
    fig1.savefig(out / "dl_bler_vs_cumtx.png", bbox_inches="tight")
    fig1.savefig(out / "dl_bler_vs_cumtx.pdf", bbox_inches="tight")
    plt.close(fig1)

    fig2, ax2 = plt.subplots()
    plot_direction(ax2, series, "UL")
    fig2.tight_layout()
    fig2.savefig(out / "ul_bler_vs_cumtx.png", bbox_inches="tight")
    fig2.savefig(out / "ul_bler_vs_cumtx.pdf", bbox_inches="tight")
    plt.close(fig2)

    print(f"Saved plots to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
