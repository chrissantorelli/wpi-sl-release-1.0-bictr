#!/usr/bin/env python3
"""
Generate a Figure 7-style BLER waterfall plot from Monte Carlo sweep data.

Replicates the visual style of Ahmed et al. "An Open-Source 5G Sidelink
Testbed" Figure 7: BLER vs SINR with one curve per MCS, grouped by
modulation order.

Usage:
  python3 plot_montecarlo.py <montecarlo_results.csv> [OPTIONS]

Options:
  --output DIR       Output directory (default: same as CSV)
  --channel NAME     Channel to plot (default: first in data, or BICTR_LUNAR)
  --direction DL|UL  Which link direction (default: DL)
  --title TITLE      Custom plot title
"""

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import FancyBboxPatch


# NR MCS Table 5.1.3.1-1 (38.214): modulation order by MCS index
def mcs_mod_order(mcs: int) -> int:
    if mcs <= 9:
        return 2   # QPSK
    elif mcs <= 16:
        return 4   # 16QAM
    elif mcs <= 28:
        return 6   # 64QAM
    return 0


def mcs_mod_label(order: int) -> str:
    return {2: 'QPSK', 4: '16QAM', 6: '64QAM'}.get(order, '?')


def channel_uses_phytest_snr(channel: str) -> bool:
    """AWGN rows from run_montecarlo.sh store phy-test SINR (dB) in noise_power_dB."""
    return channel == 'AWGN' or channel.upper().startswith('AWGN')


def x_display_db(channel: str, noise_power_db: int) -> float:
    """X-axis dB for BLER curves: direct SINR for AWGN; legacy −noise for BICTR."""
    if channel_uses_phytest_snr(channel):
        return float(noise_power_db)
    return float(-noise_power_db)


def sweep_axis_label(channel: str) -> str:
    if channel_uses_phytest_snr(channel):
        return 'SINR (dB)'
    return '−noise_power_dB  (dB, higher = better channel)'


def sweep_table_col_label(channel: str) -> str:
    if channel_uses_phytest_snr(channel):
        return 'SINR (dB)'
    return 'noise_power_dB'


# Colors: use a distinct colormap that spreads well across 20 MCS curves
def get_mcs_color(mcs: int, mcs_list: list[int]):
    n = len(mcs_list)
    idx = mcs_list.index(mcs)
    cmap = plt.cm.turbo
    return cmap(0.1 + 0.8 * idx / max(n - 1, 1))


def load_csv(csv_path: str) -> list[dict]:
    rows = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            row['mcs'] = int(row['mcs'])
            row['noise_power_dB'] = int(row['noise_power_dB'])
            row['trial'] = int(row['trial'])
            row['dl_first_tx'] = int(row['dl_first_tx'])
            row['dl_errors'] = int(row['dl_errors'])
            row['dl_bler'] = float(row['dl_bler'])
            row['ul_first_tx'] = int(row['ul_first_tx'])
            row['ul_errors'] = int(row['ul_errors'])
            row['ul_bler'] = float(row['ul_bler'])
            rows.append(row)
    return rows


def aggregate(rows: list[dict]) -> dict:
    """Group by (channel, mcs, noise) and compute aggregate BLER across trials.

    Uses pooled error counts (not mean of per-trial BLERs) for correct
    weighting when trial lengths differ.
    """
    buckets: dict[tuple, list] = defaultdict(list)
    for r in rows:
        key = (r['channel_type'], r['mcs'], r['noise_power_dB'])
        buckets[key].append(r)

    result = {}
    for key, trials in buckets.items():
        total_dl_tx = sum(t['dl_first_tx'] for t in trials)
        total_dl_err = sum(t['dl_errors'] for t in trials)
        total_ul_tx = sum(t['ul_first_tx'] for t in trials)
        total_ul_err = sum(t['ul_errors'] for t in trials)

        result[key] = {
            'dl_bler': total_dl_err / total_dl_tx if total_dl_tx > 0 else 0.0,
            'ul_bler': total_ul_err / total_ul_tx if total_ul_tx > 0 else 0.0,
            'dl_total_tx': total_dl_tx,
            'ul_total_tx': total_ul_tx,
            'n_trials': len(trials),
        }
    return result


def plot_figure7(agg: dict, channel: str, direction: str,
                 mcs_list: list[int], noise_list: list[int],
                 title: str | None, output_dir: Path):
    """Produce a single-panel waterfall plot matching Ahmed et al. Figure 7."""

    bler_key = 'dl_bler' if direction == 'DL' else 'ul_bler'

    plt.rcParams.update({
        'figure.dpi': 150,
        'font.size': 11,
        'font.family': 'serif',
        'axes.grid': True,
        'grid.alpha': 0.25,
        'grid.linestyle': '--',
        'axes.spines.top': True,
        'axes.spines.right': True,
        'legend.framealpha': 0.95,
        'legend.edgecolor': '0.7',
        'legend.fontsize': 8,
    })

    fig, ax = plt.subplots(figsize=(10, 6.5))

    sinr_values = sorted(x_display_db(channel, n) for n in noise_list)
    markers = ['o', 's', '^', 'v', 'D', 'P', 'X', '*', 'h', '<', '>', 'p',
               'd', '8', 'H', '+', 'x', '1', '2', '3']

    mod_order_groups: dict[int, list[int]] = defaultdict(list)
    for mcs in mcs_list:
        mod_order_groups[mcs_mod_order(mcs)].append(mcs)

    for idx, mcs in enumerate(mcs_list):
        color = get_mcs_color(mcs, mcs_list)
        marker = markers[idx % len(markers)]
        x_vals, y_vals = [], []

        for noise in sorted(noise_list):
            key = (channel, mcs, noise)
            if key in agg:
                x_pt = x_display_db(channel, noise)
                bler = min(agg[key][bler_key], 1.0)
                x_vals.append(x_pt)
                y_vals.append(bler)

        if x_vals:
            ax.plot(x_vals, y_vals, color=color, linewidth=1.6,
                    marker=marker, markersize=5, markeredgewidth=0.5,
                    markeredgecolor='white', label=f'MCS {mcs}', alpha=0.9)

    chan_label = 'BICTR Lunar' if 'BICTR' in channel else (
        'AWGN (RFSim phy-test)' if channel_uses_phytest_snr(channel) else channel)
    if title:
        ax.set_title(title, fontsize=14, fontweight='bold', pad=12)
    else:
        ax.set_title(
            f'{direction} BLER for Various MCS Values — {chan_label} Channel\n'
            f'(RFSim, phy-test mode)',
            fontsize=13, fontweight='bold', pad=12)

    ax.set_xlabel(sweep_axis_label(channel), fontsize=12)
    ax.set_ylabel('Block Error Rate (BLER)', fontsize=12)
    ax.set_ylim(-0.02, 1.05)
    ax.set_yticks(np.arange(0, 1.1, 0.1))

    if sinr_values:
        margin = (max(sinr_values) - min(sinr_values)) * 0.05 + 0.5
        ax.set_xlim(min(sinr_values) - margin, max(sinr_values) + margin)

    # Group annotations by modulation order (like Figure 7)
    legend_handles = []
    mod_orders_present = sorted(mod_order_groups.keys())

    for mod_ord in mod_orders_present:
        mcss = mod_order_groups[mod_ord]
        mod_label = mcs_mod_label(mod_ord)

        separator = Line2D([], [], color='none',
                           label=f'── Mod. Order {mod_ord} ({mod_label}) ──')
        legend_handles.append(separator)

        for mcs in mcss:
            idx = mcs_list.index(mcs)
            color = get_mcs_color(mcs, mcs_list)
            marker = markers[idx % len(markers)]
            handle = Line2D([], [], color=color, marker=marker, markersize=5,
                            linewidth=1.5, markeredgewidth=0.5,
                            markeredgecolor='white', label=f'MCS {mcs}')
            legend_handles.append(handle)

    ncol = 1
    if len(mcs_list) > 12:
        ncol = 2
    if len(mcs_list) > 24:
        ncol = 3

    ax.legend(handles=legend_handles, loc='upper right', ncol=ncol,
              fontsize=7.5, handlelength=2, columnspacing=1)

    fig.tight_layout()
    prefix = f'mc_{direction.lower()}_bler_fig7'
    fig.savefig(output_dir / f'{prefix}.png', bbox_inches='tight')
    fig.savefig(output_dir / f'{prefix}.pdf', bbox_inches='tight')
    print(f"  Saved {prefix}.png/pdf")
    plt.close(fig)


def plot_summary_table(agg: dict, channel: str, direction: str,
                       mcs_list: list[int], noise_list: list[int],
                       output_dir: Path):
    """Tabular summary of all BLER values."""

    bler_key = 'dl_bler' if direction == 'DL' else 'ul_bler'

    col_labels = [sweep_table_col_label(channel)] + [f'MCS {m}' for m in mcs_list]
    table_data = []
    for noise in sorted(noise_list):
        row = [str(noise)]
        for mcs in mcs_list:
            key = (channel, mcs, noise)
            if key in agg:
                bler = min(agg[key][bler_key], 1.0)
                row.append(f'{bler:.3f}')
            else:
                row.append('—')
        table_data.append(row)

    fig, ax = plt.subplots(figsize=(max(8, 1.2 * len(mcs_list)),
                                     max(4, 0.45 * len(noise_list) + 1.5)))
    ax.axis('off')

    table = ax.table(cellText=table_data, colLabels=col_labels,
                     cellLoc='center', loc='center')
    table.auto_set_font_size(False)
    table.set_fontsize(7 if len(mcs_list) > 12 else 8)
    table.scale(1, 1.3)

    for (r, c), cell in table.get_celld().items():
        if r == 0:
            cell.set_text_props(weight='bold', fontsize=7)
            cell.set_facecolor('#e0e0e0')
        else:
            try:
                val = float(table_data[r - 1][c])
                intensity = val
                cell.set_facecolor(plt.cm.RdYlGn_r(intensity * 0.8 + 0.1))
                cell.set_text_props(color='white' if intensity > 0.6 else 'black')
            except (ValueError, IndexError):
                pass
        cell.set_edgecolor('#cccccc')

    chan_label = 'BICTR Lunar' if 'BICTR' in channel else (
        'AWGN (RFSim phy-test)' if channel_uses_phytest_snr(channel) else channel)
    ax.set_title(f'{direction} BLER Summary — {chan_label}',
                 fontsize=12, fontweight='bold', pad=20)
    fig.tight_layout()
    fig.savefig(output_dir / f'mc_{direction.lower()}_bler_table.png',
                bbox_inches='tight')
    fig.savefig(output_dir / f'mc_{direction.lower()}_bler_table.pdf',
                bbox_inches='tight')
    print(f"  Saved mc_{direction.lower()}_bler_table.png/pdf")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(
        description='Plot Monte Carlo BLER sweep (Figure 7 style)')
    parser.add_argument('csv_path', help='Path to montecarlo_results.csv')
    parser.add_argument('--output', '-o', default=None,
                        help='Output directory (default: same as CSV)')
    parser.add_argument('--channel', default=None,
                        help='Channel type to plot (default: AWGN if present, else BICTR)')
    parser.add_argument('--direction', default='DL', choices=['DL', 'UL'],
                        help='Link direction (default: DL)')
    parser.add_argument('--title', default=None, help='Custom plot title')
    args = parser.parse_args()

    csv_path = Path(args.csv_path)
    output_dir = Path(args.output) if args.output else csv_path.parent

    print(f"Loading data from {csv_path}")
    rows = load_csv(str(csv_path))
    print(f"  {len(rows)} data points loaded")

    channels = sorted(set(r['channel_type'] for r in rows))
    mcs_list = sorted(set(r['mcs'] for r in rows))

    target_channel = args.channel
    if target_channel is None:
        for c in channels:
            if channel_uses_phytest_snr(c):
                target_channel = c
                break
        if target_channel is None:
            for c in channels:
                if 'BICTR' in c:
                    target_channel = c
                    break
        if target_channel is None:
            target_channel = channels[0]

    chan_rows = [r for r in rows if r['channel_type'] == target_channel]
    noise_list = sorted(set(r['noise_power_dB'] for r in chan_rows))

    print(f"  Channels in data: {channels}")
    print(f"  Plotting channel: {target_channel}")
    print(f"  MCS values: {mcs_list}")
    print(f"  Sweep dB (noise_power_dB column): {noise_list}")
    print(f"  Direction:  {args.direction}")

    agg = aggregate(chan_rows)
    print(f"  {len(agg)} aggregated (MCS, noise) points")

    # Figure 7-style waterfall
    plot_figure7(agg, target_channel, args.direction,
                 mcs_list, noise_list, args.title, output_dir)

    # Also generate UL if DL was primary
    other_dir = 'UL' if args.direction == 'DL' else 'DL'
    plot_figure7(agg, target_channel, other_dir,
                 mcs_list, noise_list, args.title, output_dir)

    # Summary heatmap table
    plot_summary_table(agg, target_channel, args.direction,
                       mcs_list, noise_list, output_dir)

    # Text summary
    bler_key = 'dl_bler' if args.direction == 'DL' else 'ul_bler'
    chan_label = 'BICTR Lunar' if 'BICTR' in target_channel else (
        'AWGN (RFSim phy-test)' if channel_uses_phytest_snr(target_channel) else target_channel)
    print(f"\n{'='*60}")
    print(f"  {chan_label} — {args.direction} BLER Summary")
    print(f"{'='*60}")
    header = f"{sweep_table_col_label(target_channel):>12}"
    for mcs in mcs_list:
        header += f"  MCS{mcs:>3}"
    print(header)
    for noise in sorted(noise_list):
        line = f"{noise:>12}"
        for mcs in mcs_list:
            key = (target_channel, mcs, noise)
            if key in agg:
                line += f"  {min(agg[key][bler_key], 1.0):>6.3f}"
            else:
                line += f"  {'—':>6}"
        print(line)
    print(f"{'='*60}")
    print(f"Plots saved to: {output_dir}")

    # If multiple channels present, offer AWGN comparison too
    if len(channels) > 1:
        for other_chan in channels:
            if other_chan == target_channel:
                continue
            other_rows = [r for r in rows if r['channel_type'] == other_chan]
            other_noise_list = sorted(set(r['noise_power_dB'] for r in other_rows))
            other_mcs_list = sorted(set(r['mcs'] for r in other_rows))
            other_agg = aggregate(other_rows)
            plot_figure7(other_agg, other_chan, args.direction,
                         other_mcs_list, other_noise_list, None, output_dir)
            print(f"  Also plotted {other_chan} for comparison")


if __name__ == '__main__':
    main()
