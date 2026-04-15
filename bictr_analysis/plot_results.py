#!/usr/bin/env python3
"""
Generate publication-quality BLER and HARQ visualizations from OAI
experiment data. Produces 4 figures standard for wireless channel
model evaluation papers:

  1. DL BLER over time  (BICTR vs AWGN)
  2. UL BLER over time  (BICTR vs AWGN)
  3. HARQ round distribution  (stacked bar, BICTR vs AWGN)
  4. Summary comparison table  (DL/UL BLER, throughput, RSRP)

Usage:
  python3 plot_results.py <bictr_results_dir> <awgn_results_dir> [--output DIR]
"""

import sys
import argparse
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

from parse_stats import load_timeseries, compute_deltas, compute_summary


BICTR_COLOR = '#D64045'
AWGN_COLOR = '#1B998B'
BICTR_LABEL = 'BICTR Lunar'
AWGN_LABEL = 'AWGN'


def setup_style():
    plt.rcParams.update({
        'figure.figsize': (8, 5),
        'figure.dpi': 150,
        'font.size': 11,
        'font.family': 'serif',
        'axes.grid': True,
        'grid.alpha': 0.3,
        'axes.spines.top': False,
        'axes.spines.right': False,
        'legend.framealpha': 0.9,
        'legend.edgecolor': '0.8',
    })


def plot_bler_timeseries(ax, deltas_bictr, deltas_awgn, direction='DL'):
    key = 'dl_bler' if direction == 'DL' else 'ul_bler'
    tx_key = 'dl_first_tx' if direction == 'DL' else 'ul_first_tx'

    if deltas_bictr:
        t_b = [d['elapsed_s'] for d in deltas_bictr if d[tx_key] > 0]
        b_b = [d[key] for d in deltas_bictr if d[tx_key] > 0]
        if t_b:
            ax.plot(t_b, b_b, color=BICTR_COLOR, linewidth=1.5,
                    marker='o', markersize=3, label=BICTR_LABEL, alpha=0.85)

    if deltas_awgn:
        t_a = [d['elapsed_s'] for d in deltas_awgn if d[tx_key] > 0]
        b_a = [d[key] for d in deltas_awgn if d[tx_key] > 0]
        if t_a:
            ax.plot(t_a, b_a, color=AWGN_COLOR, linewidth=1.5,
                    marker='s', markersize=3, label=AWGN_LABEL, alpha=0.85)

    ax.set_xlabel('Time (s)')
    ax.set_ylabel(f'{direction} BLER')
    ax.set_title(f'{direction} Block Error Rate Over Time')
    ax.set_ylim(bottom=-0.02, top=max(1.05, ax.get_ylim()[1]))
    ax.legend(loc='upper right')


def plot_harq_distribution(ax, summary_bictr, summary_awgn, direction='DL'):
    key = 'dl_harq_distribution' if direction == 'DL' else 'ul_harq_distribution'

    harq_b = summary_bictr.get(key, [0, 0, 0, 0])
    harq_a = summary_awgn.get(key, [0, 0, 0, 0])

    max_rounds = max(len(harq_b), len(harq_a))
    while len(harq_b) < max_rounds:
        harq_b.append(0)
    while len(harq_a) < max_rounds:
        harq_a.append(0)

    total_b = sum(harq_b) if sum(harq_b) > 0 else 1
    total_a = sum(harq_a) if sum(harq_a) > 0 else 1
    pct_b = [100 * h / total_b for h in harq_b]
    pct_a = [100 * h / total_a for h in harq_a]

    x = np.arange(max_rounds)
    width = 0.35

    bars_b = ax.bar(x - width / 2, pct_b, width, label=BICTR_LABEL,
                    color=BICTR_COLOR, alpha=0.85, edgecolor='white', linewidth=0.5)
    bars_a = ax.bar(x + width / 2, pct_a, width, label=AWGN_LABEL,
                    color=AWGN_COLOR, alpha=0.85, edgecolor='white', linewidth=0.5)

    for bars in [bars_b, bars_a]:
        for bar in bars:
            h = bar.get_height()
            if h > 2:
                ax.annotate(f'{h:.1f}%', xy=(bar.get_x() + bar.get_width() / 2, h),
                            xytext=(0, 3), textcoords='offset points',
                            ha='center', va='bottom', fontsize=8)

    ax.set_xlabel('HARQ Round')
    ax.set_ylabel('Percentage of Transmissions (%)')
    ax.set_title(f'{direction} HARQ Round Distribution')
    ax.set_xticks(x)
    ax.set_xticklabels([f'Round {i}' for i in range(max_rounds)])
    ax.legend(loc='upper right')
    ax.set_ylim(bottom=0)


def plot_summary_table(ax, summary_bictr, summary_awgn):
    ax.axis('off')

    rows = [
        ('Duration (s)',
         f"{summary_bictr.get('duration_s', 0):.0f}",
         f"{summary_awgn.get('duration_s', 0):.0f}"),
        ('DL Total TX',
         f"{summary_bictr.get('dl_total_tx', 0):,}",
         f"{summary_awgn.get('dl_total_tx', 0):,}"),
        ('DL Errors',
         f"{summary_bictr.get('dl_total_errors', 0):,}",
         f"{summary_awgn.get('dl_total_errors', 0):,}"),
        ('DL BLER',
         f"{summary_bictr.get('dl_bler', 0):.5f}",
         f"{summary_awgn.get('dl_bler', 0):.5f}"),
        ('DL Throughput (kbps)',
         f"{summary_bictr.get('dl_throughput_kbps', 0):.1f}",
         f"{summary_awgn.get('dl_throughput_kbps', 0):.1f}"),
        ('DL HARQ Distribution',
         '/'.join(str(x) for x in summary_bictr.get('dl_harq_distribution', [])),
         '/'.join(str(x) for x in summary_awgn.get('dl_harq_distribution', []))),
        ('UL Total TX',
         f"{summary_bictr.get('ul_total_tx', 0):,}",
         f"{summary_awgn.get('ul_total_tx', 0):,}"),
        ('UL Errors',
         f"{summary_bictr.get('ul_total_errors', 0):,}",
         f"{summary_awgn.get('ul_total_errors', 0):,}"),
        ('UL BLER',
         f"{summary_bictr.get('ul_bler', 0):.5f}",
         f"{summary_awgn.get('ul_bler', 0):.5f}"),
        ('UL Throughput (kbps)',
         f"{summary_bictr.get('ul_throughput_kbps', 0):.1f}",
         f"{summary_awgn.get('ul_throughput_kbps', 0):.1f}"),
        ('Avg RSRP (dBm)',
         f"{summary_bictr.get('avg_rsrp', 0):.1f}",
         f"{summary_awgn.get('avg_rsrp', 0):.1f}"),
    ]

    col_labels = ['Metric', BICTR_LABEL, AWGN_LABEL]
    cell_text = [[r[0], r[1], r[2]] for r in rows]

    table = ax.table(cellText=cell_text, colLabels=col_labels,
                     cellLoc='center', loc='center',
                     colColours=['#f0f0f0', '#fde8e8', '#e0f5f2'])
    table.auto_set_font_size(False)
    table.set_fontsize(9)
    table.scale(1, 1.4)

    for (row, col), cell in table.get_celld().items():
        if row == 0:
            cell.set_text_props(weight='bold')
        cell.set_edgecolor('#cccccc')

    ax.set_title('Summary Comparison', fontsize=13, fontweight='bold', pad=20)


def main():
    parser = argparse.ArgumentParser(description='Plot BICTR vs AWGN experiment results')
    parser.add_argument('bictr_dir', help='Path to BICTR results directory')
    parser.add_argument('awgn_dir', help='Path to AWGN results directory')
    parser.add_argument('--output', '-o', default=None,
                        help='Output directory for plots (default: bictr_dir)')
    args = parser.parse_args()

    bictr_dir = Path(args.bictr_dir)
    awgn_dir = Path(args.awgn_dir)
    output_dir = Path(args.output) if args.output else bictr_dir.parent

    setup_style()

    print(f"Loading BICTR data from {bictr_dir}")
    samples_b = load_timeseries(str(bictr_dir / 'stats_timeseries.csv'))
    deltas_b = compute_deltas(samples_b)
    summary_b = compute_summary(samples_b)

    print(f"Loading AWGN data from {awgn_dir}")
    samples_a = load_timeseries(str(awgn_dir / 'stats_timeseries.csv'))
    deltas_a = compute_deltas(samples_a)
    summary_a = compute_summary(samples_a)

    # --- Figure 1: DL BLER time series ---
    fig1, ax1 = plt.subplots()
    plot_bler_timeseries(ax1, deltas_b, deltas_a, direction='DL')
    fig1.tight_layout()
    fig1.savefig(output_dir / 'dl_bler_timeseries.png', bbox_inches='tight')
    fig1.savefig(output_dir / 'dl_bler_timeseries.pdf', bbox_inches='tight')
    print(f"  Saved dl_bler_timeseries.png/pdf")

    # --- Figure 2: UL BLER time series ---
    fig2, ax2 = plt.subplots()
    plot_bler_timeseries(ax2, deltas_b, deltas_a, direction='UL')
    fig2.tight_layout()
    fig2.savefig(output_dir / 'ul_bler_timeseries.png', bbox_inches='tight')
    fig2.savefig(output_dir / 'ul_bler_timeseries.pdf', bbox_inches='tight')
    print(f"  Saved ul_bler_timeseries.png/pdf")

    # --- Figure 3: HARQ distribution (DL + UL side by side) ---
    fig3, (ax3a, ax3b) = plt.subplots(1, 2, figsize=(14, 5))
    plot_harq_distribution(ax3a, summary_b, summary_a, direction='DL')
    plot_harq_distribution(ax3b, summary_b, summary_a, direction='UL')
    fig3.tight_layout()
    fig3.savefig(output_dir / 'harq_distribution.png', bbox_inches='tight')
    fig3.savefig(output_dir / 'harq_distribution.pdf', bbox_inches='tight')
    print(f"  Saved harq_distribution.png/pdf")

    # --- Figure 4: Summary table ---
    fig4, ax4 = plt.subplots(figsize=(10, 5))
    plot_summary_table(ax4, summary_b, summary_a)
    fig4.tight_layout()
    fig4.savefig(output_dir / 'summary_table.png', bbox_inches='tight')
    fig4.savefig(output_dir / 'summary_table.pdf', bbox_inches='tight')
    print(f"  Saved summary_table.png/pdf")

    # --- Figure 5: DL Throughput time series ---
    fig5, ax5 = plt.subplots()
    if deltas_b:
        t_b = [d['elapsed_s'] for d in deltas_b]
        tp_b = [d['dl_throughput_kbps'] for d in deltas_b]
        ax5.plot(t_b, tp_b, color=BICTR_COLOR, linewidth=1.5, label=BICTR_LABEL, alpha=0.85)
    if deltas_a:
        t_a = [d['elapsed_s'] for d in deltas_a]
        tp_a = [d['dl_throughput_kbps'] for d in deltas_a]
        ax5.plot(t_a, tp_a, color=AWGN_COLOR, linewidth=1.5, label=AWGN_LABEL, alpha=0.85)
    ax5.set_xlabel('Time (s)')
    ax5.set_ylabel('DL Throughput (kbps)')
    ax5.set_title('Downlink Throughput Over Time')
    ax5.legend(loc='upper right')
    ax5.set_ylim(bottom=0)
    fig5.tight_layout()
    fig5.savefig(output_dir / 'dl_throughput_timeseries.png', bbox_inches='tight')
    fig5.savefig(output_dir / 'dl_throughput_timeseries.pdf', bbox_inches='tight')
    print(f"  Saved dl_throughput_timeseries.png/pdf")

    # --- Print text summary ---
    print(f"\n{'='*60}")
    print(f"  BICTR vs AWGN — Experiment Summary")
    print(f"{'='*60}")
    for label, s in [(BICTR_LABEL, summary_b), (AWGN_LABEL, summary_a)]:
        print(f"\n  [{label}]")
        print(f"    Duration:        {s.get('duration_s', 0):.0f} s")
        print(f"    DL BLER:         {s.get('dl_bler', 0):.5f}  "
              f"({s.get('dl_total_errors', 0)}/{s.get('dl_total_tx', 0)})")
        print(f"    DL HARQ:         {'/'.join(str(x) for x in s.get('dl_harq_distribution', []))}")
        print(f"    DL Throughput:   {s.get('dl_throughput_kbps', 0):.1f} kbps")
        print(f"    UL BLER:         {s.get('ul_bler', 0):.5f}  "
              f"({s.get('ul_total_errors', 0)}/{s.get('ul_total_tx', 0)})")
        print(f"    UL HARQ:         {'/'.join(str(x) for x in s.get('ul_harq_distribution', []))}")
        print(f"    UL Throughput:   {s.get('ul_throughput_kbps', 0):.1f} kbps")
        print(f"    Avg RSRP:        {s.get('avg_rsrp', 0):.1f} dBm")
    print(f"\n{'='*60}")
    print(f"Plots saved to: {output_dir}")


if __name__ == '__main__':
    main()
