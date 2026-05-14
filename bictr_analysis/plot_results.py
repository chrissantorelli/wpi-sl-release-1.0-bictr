#!/usr/bin/env python3
from __future__ import annotations

"""
Generate publication-quality BLER and HARQ visualizations from OAI experiment data.

Supports two or more result directories (e.g. BICTR fast, BICTR aggressive, AWGN).

Usage (two scenarios, legacy flags still work):
  python3 plot_results.py DIR_A DIR_B --label-a 'BICTR fast' --label-b 'AWGN' -o OUT/

Usage (three or more):
  python3 plot_results.py DIR1 DIR2 DIR3 --labels 'L1' 'L2' 'L3' -o OUT/
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

from parse_stats import load_timeseries, compute_deltas, compute_summary

# Default colors for first series (BICTR variants) then baseline-style
SERIES_COLORS = ["#D64045", "#E67E22", "#2E86AB", "#6A4C93", "#1B998B", "#C73E1D"]
SERIES_MARKERS = ["o", "v", "s", "^", "D", "P"]


def setup_style():
    plt.rcParams.update(
        {
            "figure.figsize": (8, 5),
            "figure.dpi": 150,
            "font.size": 11,
            "font.family": "serif",
            "axes.grid": True,
            "grid.alpha": 0.3,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "legend.framealpha": 0.9,
            "legend.edgecolor": "0.8",
        }
    )


def infer_label(result_dir: Path) -> str:
    name = result_dir.name.lower()
    if "awgn" in name:
        return "AWGN"
    if "aggressive" in name:
        return "BICTR aggressive"
    if "bictr_fast" in name or name.endswith("_bictr"):
        return "BICTR fast"
    if "bictr_terrain" in name:
        return "BICTR DEM"
    if "bictr_flat" in name:
        return "BICTR flat"
    return result_dir.name


def resolve_labels(dirs: list[Path], labels_arg: list[str] | None,
                   label_a: str | None, label_b: str | None) -> list[str]:
    if labels_arg is not None:
        if len(labels_arg) != len(dirs):
            raise SystemExit(
                f"--labels count ({len(labels_arg)}) must match directories ({len(dirs)})"
            )
        return list(labels_arg)
    if len(dirs) == 2:
        a = label_a or infer_label(dirs[0])
        b = label_b or infer_label(dirs[1])
        return [a, b]
    return [infer_label(d) for d in dirs]


def plot_bler_timeseries(ax, series, direction="DL"):
    key = "dl_bler" if direction == "DL" else "ul_bler"
    tx_key = "dl_first_tx" if direction == "DL" else "ul_first_tx"
    for s in series:
        deltas = s["deltas"]
        if not deltas:
            continue
        t_b = [d["elapsed_s"] for d in deltas if d[tx_key] > 0]
        b_b = [d[key] for d in deltas if d[tx_key] > 0]
        if t_b:
            ax.plot(
                t_b,
                b_b,
                color=s["color"],
                linewidth=1.5,
                marker=s["marker"],
                markersize=3,
                label=s["label"],
                alpha=0.85,
            )
    ax.set_xlabel("Time (s)")
    ax.set_ylabel(f"{direction} BLER")
    ax.set_title(f"{direction} Block Error Rate Over Time")
    ax.set_ylim(bottom=-0.02, top=1.05)
    ax.legend(loc="upper right")


def plot_throughput_timeseries(ax, series):
    for s in series:
        deltas = s["deltas"]
        if not deltas:
            continue
        t_b = [d["elapsed_s"] for d in deltas]
        tp_b = [d["dl_throughput_kbps"] for d in deltas]
        ax.plot(
            t_b,
            tp_b,
            color=s["color"],
            linewidth=1.5,
            label=s["label"],
            marker=s["marker"],
            markersize=3,
            alpha=0.85,
        )
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("DL Throughput (kbps)")
    ax.set_title("Downlink Throughput Over Time")
    ax.legend(loc="upper right")
    ax.set_ylim(bottom=0)


def plot_harq_distribution(ax, summaries, labels, colors, direction="DL"):
    key = "dl_harq_distribution" if direction == "DL" else "ul_harq_distribution"
    harq_rows = []
    for sm in summaries:
        h = list(sm.get(key, [0, 0, 0, 0]))
        harq_rows.append(h)
    max_rounds = max(len(h) for h in harq_rows)
    for h in harq_rows:
        while len(h) < max_rounds:
            h.append(0)

    pct_rows = []
    for h in harq_rows:
        tot = sum(h) if sum(h) > 0 else 1
        pct_rows.append([100 * x / tot for x in h])

    x = np.arange(max_rounds)
    n = len(summaries)
    group_w = 0.8
    bar_w = group_w / n

    for i, (pct, label, color) in enumerate(zip(pct_rows, labels, colors)):
        offset = (i - (n - 1) / 2) * bar_w
        bars = ax.bar(
            x + offset,
            pct,
            bar_w,
            label=label,
            color=color,
            alpha=0.85,
            edgecolor="white",
            linewidth=0.5,
        )
        for bar in bars:
            hgt = bar.get_height()
            if hgt > 2:
                ax.annotate(
                    f"{hgt:.1f}%",
                    xy=(bar.get_x() + bar.get_width() / 2, hgt),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha="center",
                    va="bottom",
                    fontsize=7,
                )

    ax.set_xlabel("HARQ Round")
    ax.set_ylabel("Percentage of Transmissions (%)")
    ax.set_title(f"{direction} HARQ Round Distribution")
    ax.set_xticks(x)
    ax.set_xticklabels([f"Round {i}" for i in range(max_rounds)])
    ax.legend(loc="upper right")
    ax.set_ylim(bottom=0)
    ax.xaxis.set_major_locator(MaxNLocator(integer=True))


def plot_summary_table(ax, summaries: list[dict], labels: list[str], colors: list[str]):
    ax.axis("off")
    if not summaries:
        return

    rows = []
    keys = [
        ("Duration (s)", "duration_s", ".0f"),
        ("DL Total TX", "dl_total_tx", ","),
        ("DL Errors", "dl_total_errors", ","),
        ("DL BLER", "dl_bler", ".5f"),
        ("DL Throughput (kbps)", "dl_throughput_kbps", ".1f"),
        ("DL HARQ Distribution", "dl_harq_distribution", "harq"),
        ("UL Total TX", "ul_total_tx", ","),
        ("UL Errors", "ul_total_errors", ","),
        ("UL BLER", "ul_bler", ".5f"),
        ("UL Throughput (kbps)", "ul_throughput_kbps", ".1f"),
        ("Avg RSRP (dBm)", "avg_rsrp", ".1f"),
    ]

    for title, sk, fmt in keys:
        row = [title]
        for s in summaries:
            v = s.get(sk, 0)
            if fmt == "harq":
                row.append("/".join(str(x) for x in (v or [])))
            elif fmt == ",":
                row.append(f"{int(v):,}")
            else:
                row.append(f"{v:{fmt}}")
        rows.append(row)

    col_labels = ["Metric"] + labels
    cell_text = rows
    col_colours = ["#f0f0f0"] + [c + "33" for c in colors]

    table = ax.table(
        cellText=cell_text,
        colLabels=col_labels,
        cellLoc="center",
        loc="center",
        colColours=col_colours,
    )
    table.auto_set_font_size(False)
    fs = 8 if len(labels) > 2 else 9
    table.set_fontsize(fs)
    table.scale(1, 1.35)

    for (row, col), cell in table.get_celld().items():
        if row == 0:
            cell.set_text_props(weight="bold")
        cell.set_edgecolor("#cccccc")

    ax.set_title(
        "Summary Comparison", fontsize=13, fontweight="bold", pad=20
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot OAI RFsim experiment results (2+ scenarios)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "dirs",
        nargs="+",
        help="One or more result directories (each with stats_timeseries.csv)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="Output directory for plots (default: parent of first dir)",
    )
    parser.add_argument(
        "--labels",
        nargs="*",
        default=None,
        help="Legend labels (same count as dirs). If omitted, inferred from dir names.",
    )
    parser.add_argument(
        "--label-a",
        default=None,
        help="(Two-dir only) Label for first directory if --labels not used",
    )
    parser.add_argument(
        "--label-b",
        default=None,
        help="(Two-dir only) Label for second directory if --labels not used",
    )
    args = parser.parse_args()

    dirs = [Path(p).resolve() for p in args.dirs]
    for d in dirs:
        csv_path = d / "stats_timeseries.csv"
        if not csv_path.is_file():
            print(f"ERROR: missing {csv_path}", file=sys.stderr)
            sys.exit(1)

    labels = resolve_labels(dirs, args.labels, args.label_a, args.label_b)
    colors = [SERIES_COLORS[i % len(SERIES_COLORS)] for i in range(len(dirs))]
    markers = [SERIES_MARKERS[i % len(SERIES_MARKERS)] for i in range(len(dirs))]

    output_dir = Path(args.output).resolve() if args.output else dirs[0].parent
    output_dir.mkdir(parents=True, exist_ok=True)

    setup_style()

    series = []
    summaries = []
    for d, label, color, marker in zip(dirs, labels, colors, markers):
        print(f"Loading {label} from {d}")
        samples = load_timeseries(str(d / "stats_timeseries.csv"))
        deltas = compute_deltas(samples)
        summary = compute_summary(samples)
        series.append(
            {"deltas": deltas, "label": label, "color": color, "marker": marker}
        )
        summaries.append(summary)

    # --- DL BLER ---
    fig1, ax1 = plt.subplots(figsize=(8, 5))
    plot_bler_timeseries(ax1, series, direction="DL")
    fig1.tight_layout()
    fig1.savefig(output_dir / "dl_bler_timeseries.png", bbox_inches="tight")
    fig1.savefig(output_dir / "dl_bler_timeseries.pdf", bbox_inches="tight")
    print("  Saved dl_bler_timeseries.png/pdf")

    # --- UL BLER ---
    fig2, ax2 = plt.subplots(figsize=(8, 5))
    plot_bler_timeseries(ax2, series, direction="UL")
    fig2.tight_layout()
    fig2.savefig(output_dir / "ul_bler_timeseries.png", bbox_inches="tight")
    fig2.savefig(output_dir / "ul_bler_timeseries.pdf", bbox_inches="tight")
    print("  Saved ul_bler_timeseries.png/pdf")

    # --- HARQ ---
    w = 6 + 4 * (len(labels) - 2)
    w = min(w, 16)
    fig3, (ax3a, ax3b) = plt.subplots(1, 2, figsize=(w, 5))
    plot_harq_distribution(ax3a, summaries, labels, colors, direction="DL")
    plot_harq_distribution(ax3b, summaries, labels, colors, direction="UL")
    fig3.tight_layout()
    fig3.savefig(output_dir / "harq_distribution.png", bbox_inches="tight")
    fig3.savefig(output_dir / "harq_distribution.pdf", bbox_inches="tight")
    print("  Saved harq_distribution.png/pdf")

    # --- Summary table ---
    tw = 8 + 3 * (len(labels) - 2)
    tw = min(tw, 14)
    fig4, ax4 = plt.subplots(figsize=(tw, 5.5))
    plot_summary_table(ax4, summaries, labels, colors)
    fig4.tight_layout()
    fig4.savefig(output_dir / "summary_table.png", bbox_inches="tight")
    fig4.savefig(output_dir / "summary_table.pdf", bbox_inches="tight")
    print("  Saved summary_table.png/pdf")

    # --- DL throughput ---
    fig5, ax5 = plt.subplots(figsize=(8, 5))
    plot_throughput_timeseries(ax5, series)
    fig5.tight_layout()
    fig5.savefig(output_dir / "dl_throughput_timeseries.png", bbox_inches="tight")
    fig5.savefig(output_dir / "dl_throughput_timeseries.pdf", bbox_inches="tight")
    print("  Saved dl_throughput_timeseries.png/pdf")

    print(f"\n{'=' * 60}")
    print("  Experiment summary")
    print(f"{'=' * 60}")
    for label, s in zip(labels, summaries):
        print(f"\n  [{label}]")
        print(f"    Duration:        {s.get('duration_s', 0):.0f} s")
        print(
            f"    DL BLER:         {s.get('dl_bler', 0):.5f}  "
            f"({s.get('dl_total_errors', 0)}/{s.get('dl_total_tx', 0)})"
        )
        print(
            f"    DL HARQ:         {'/'.join(str(x) for x in s.get('dl_harq_distribution', []))}"
        )
        print(f"    DL Throughput:   {s.get('dl_throughput_kbps', 0):.1f} kbps")
        print(
            f"    UL BLER:         {s.get('ul_bler', 0):.5f}  "
            f"({s.get('ul_total_errors', 0)}/{s.get('ul_total_tx', 0)})"
        )
        print(
            f"    UL HARQ:         {'/'.join(str(x) for x in s.get('ul_harq_distribution', []))}"
        )
        print(f"    UL Throughput:   {s.get('ul_throughput_kbps', 0):.1f} kbps")
        print(f"    Avg RSRP:        {s.get('avg_rsrp', 0):.1f} dBm")
    print(f"\n{'=' * 60}")
    print(f"Plots saved to: {output_dir}")


if __name__ == "__main__":
    main()
