#!/usr/bin/env python3
"""
Plot MCS vs SNR sweep results produced by run_mcs_snr_sweep.sh.

1) Figure 7–style DL plot: BLER vs SINR (dB), one curve per MCS (Ahmed et al. look),
   plus optional UL companion figure.
2) BLER vs cumulative transmissions (per sampling interval), one file per MCS.

Expects subdirectories named: mcs<M>_snr<S> with stats_timeseries.csv at the cell root,
or trial_NN/stats_timeseries.csv under each cell (multiple trials pooled per SINR point).

Usage (from `bictr_analysis/`):

  SW=$(ls -dt results/sweep_MCS_SNR_* | head -1)
  python3 plot_mcs_snr_curves.py "$SW" -o "$SW/curves"

  # Or a fixed sweep directory, e.g.:
  python3 plot_mcs_snr_curves.py results/sweep_MCS_SNR_20260512_095140 -o results/sweep_MCS_SNR_20260512_095140/curves

Caption: defaults to 1000 packets × 100 trials. Use --auto-caption to build text
from sweep directory .sweep_meta (target-tx and trials) when present.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Rectangle

from parse_stats import (
    annotate_cumulative_tx,
    compute_deltas,
    compute_summary,
    load_timeseries,
)

SUBDIR_RE = re.compile(r"^mcs(\d+)_snr(-?[0-9.]+)$")

# Default caption matches typical sweep: 1000 DL first-TX per trial, 100 trials per SINR point.
FIG7_CAPTION_DEFAULT = (
    "Figure 7: BLERs for various MCS values with CSI reporting in RFSim "
    "(1000 data packets and 100 trials)"
)

def discover_runs(sweep_root: Path) -> dict[tuple[int, float], Path]:
    out: dict[tuple[int, float], Path] = {}
    for p in sweep_root.iterdir():
        if not p.is_dir():
            continue
        m = SUBDIR_RE.match(p.name)
        if not m:
            continue
        mcs = int(m.group(1))
        snr = float(m.group(2))
        out[(mcs, snr)] = p
    return out


def stats_csvs_for_cell(cell_dir: Path) -> list[Path]:
    """Ordered list of stats_timeseries.csv for one (MCS, SNR) cell."""
    direct = cell_dir / "stats_timeseries.csv"
    if direct.is_file():
        return [direct]
    trials = sorted(cell_dir.glob("trial_*/stats_timeseries.csv"))
    return trials


def pooled_bler_from_cell(cell_dir: Path) -> tuple[float, float]:
    """Pooled DL/UL BLER across trials: sum(errors) / sum(first-TX counts).

    Uses ``parse_stats.compute_summary`` on each trial's timeseries (first→last sample deltas).

    **NR RFSim phy-test (typical sweep):** In gNB MAC stats, ``dlsch_errors`` often stays constant
    for the whole run while ``dlsch_rounds[0]`` grows, so incremental DL errors are ~0 and the
    pooled **DL BLER is ~0** everywhere. **UL** increments both ``ulsch_errors`` and
    ``ulsch_rounds[0]``, so pooled **UL BLER** is meaningful but can look **flat or jagged vs
    swept SINR** if the ``-s`` noise mainly tracks the DL PHY path or UL sees only weak SNR
    dependence; with ~few×10³ UL TBs per cell, ±0.01 BLER point-to-point noise is normal.
    """
    dl_tx = dl_err = ul_tx = ul_err = 0
    for csv_path in stats_csvs_for_cell(cell_dir):
        sm = compute_summary(load_timeseries(str(csv_path)))
        if not sm:
            continue
        dl_tx += sm.get("dl_total_tx", 0)
        dl_err += sm.get("dl_total_errors", 0)
        ul_tx += sm.get("ul_total_tx", 0)
        ul_err += sm.get("ul_total_errors", 0)
    dl_b = dl_err / dl_tx if dl_tx > 0 else 0.0
    ul_b = ul_err / ul_tx if ul_tx > 0 else 0.0
    return dl_b, ul_b


def read_sweep_meta(sweep_root: Path) -> dict[str, str]:
    p = sweep_root / ".sweep_meta"
    if not p.is_file():
        return {}
    out: dict[str, str] = {}
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def caption_from_meta(meta: dict[str, str]) -> str | None:
    """Build a Figure 7–style caption from .sweep_meta when target-tx / trials exist."""
    try:
        nt = int(meta.get("NUM_TRIALS", "0"))
        tt = int(meta.get("TARGET_TX", "0"))
    except ValueError:
        return None
    if nt < 1 or tt < 1:
        return None
    return (
        "Figure 7: BLERs for various MCS values with CSI reporting in RFSim "
        f"({tt} data packets per trial, {nt} trials pooled per SINR point)"
    )


def get_mcs_color(mcs: int, mcs_list: list[int]):
    n = len(mcs_list)
    idx = mcs_list.index(mcs)
    cmap = plt.cm.turbo
    return cmap(0.1 + 0.8 * idx / max(n - 1, 1))


def collect_curve(
    runs: dict[tuple[int, float], Path],
    snr_vals: list[float],
    mcs: int,
    ul: bool,
) -> tuple[list[float], list[float]]:
    xs, ys = [], []
    for snr in snr_vals:
        p = runs.get((mcs, snr))
        if p is None or not stats_csvs_for_cell(p):
            continue
        dl_b, ul_b = pooled_bler_from_cell(p)
        xs.append(float(snr))
        ys.append(ul_b if ul else dl_b)
    return xs, ys


def plot_figure7_panel(
    runs: dict[tuple[int, float], Path],
    mcs_vals: list[int],
    snr_vals: list[float],
    *,
    ul: bool,
    caption: str,
    show_title: bool,
    out_png: Path,
    out_pdf: Path,
) -> None:
    plt.rcParams.update(
        {
            "figure.dpi": 150,
            "font.size": 11,
            "font.family": "serif",
            "axes.grid": True,
            "grid.alpha": 0.28,
            "grid.linestyle": "--",
            "axes.spines.top": True,
            "axes.spines.right": True,
            "legend.framealpha": 0.95,
            "legend.edgecolor": "0.7",
            "legend.fontsize": 7.5,
        }
    )

    fig, ax = plt.subplots(figsize=(10, 6.5))

    for mcs in mcs_vals:
        color = get_mcs_color(mcs, mcs_vals)
        snr_pts, bler_pts = collect_curve(runs, snr_vals, mcs, ul=ul)
        if not snr_pts:
            continue
        ax.plot(
            snr_pts,
            bler_pts,
            color=color,
            linewidth=1.6,
            label=f"MCS {mcs}",
            alpha=0.92,
            zorder=4,
        )

    if show_title:
        if not ul:
            ax.set_title(
                "BLER vs. SINR (dB) conducted in RFSim.",
                fontsize=13,
                fontweight="bold",
                pad=14,
            )
        else:
            ax.set_title(
                "Uplink BLER vs. SINR (dB) conducted in RFSim.",
                fontsize=13,
                fontweight="bold",
                pad=14,
            )
    ax.set_xlabel("SINR (dB)", fontsize=12)
    ax.set_ylabel("Average Block Error Rate (BLER)", fontsize=12)
    ax.set_ylim(0.0, 0.2)
    ax.set_yticks(np.arange(0, 0.21, 0.02))
    ax.set_xlim(14.0, 30.0)
    ax.set_xticks(np.arange(14, 31, 2))

    # SINR ≈26–30 dB for xlim 14–30 → panel in transAxes x∈[0.75, 1], inset from spines; legend bbox matches.
    # Panel zorder below BLER lines (zorder=4) so curves remain visible through the strip; legend stays on top.
    pad_l, pad_r, pad_b, pad_t = 0.014, 0.014, 0.022, 0.020
    band_left = 0.75
    legend_x0 = band_left + pad_l
    legend_w = 1.0 - legend_x0 - pad_r
    legend_y0 = pad_b
    legend_h = 1.0 - pad_b - pad_t
    ax.add_patch(
        Rectangle(
            (legend_x0, legend_y0),
            legend_w,
            legend_h,
            transform=ax.transAxes,
            facecolor="white",
            edgecolor="black",
            linewidth=1.05,
            alpha=0.96,
            zorder=2,
            clip_on=False,
        )
    )

    n_mcs = len(mcs_vals)
    ncol = max(2, min(5, (n_mcs + 3) // 4))
    leg = ax.legend(
        loc="upper left",
        bbox_to_anchor=(legend_x0, legend_y0, legend_w, legend_h),
        bbox_transform=ax.transAxes,
        mode="expand",
        ncol=ncol,
        fontsize=7,
        handlelength=2.0,
        borderaxespad=0.02,
        labelspacing=0.32,
        columnspacing=0.7,
        frameon=False,
        facecolor="none",
    )
    leg.set_zorder(10)

    fig.subplots_adjust(bottom=0.2, top=0.92)
    if caption.strip():
        fig.text(0.5, 0.06, caption, ha="center", va="top", fontsize=10, wrap=True)

    fig.savefig(out_png, bbox_inches="tight")
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("sweep_dir", type=Path, help="sweep_MCS_SNR_* directory")
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument(
        "--caption",
        default=None,
        help="Figure caption below the plot (default: 1000 packets, 100 trials). "
        "Pass empty string for no caption.",
    )
    ap.add_argument(
        "--auto-caption",
        action="store_true",
        help="Build caption from .sweep_meta TARGET_TX and NUM_TRIALS when available",
    )
    ap.add_argument(
        "--no-title",
        action="store_true",
        help="Omit the Figure 7 panel title (axes labels unchanged)",
    )
    args = ap.parse_args()

    root = args.sweep_dir.resolve()
    if not root.is_dir():
        print(f"ERROR: {root} not found", file=sys.stderr)
        return 1

    runs = discover_runs(root)
    if not runs:
        print(f"ERROR: no mcs*_snr* subdirs in {root}", file=sys.stderr)
        return 1

    mcs_vals = sorted({k[0] for k in runs})
    snr_vals = sorted({k[1] for k in runs}, key=float)

    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    meta = read_sweep_meta(root)
    if args.caption is not None:
        caption = args.caption
    elif args.auto_caption:
        caption = caption_from_meta(meta) or FIG7_CAPTION_DEFAULT
    else:
        caption = FIG7_CAPTION_DEFAULT

    plot_figure7_panel(
        runs,
        mcs_vals,
        snr_vals,
        ul=False,
        caption=caption,
        show_title=not args.no_title,
        out_png=out / "bler_vs_snr_by_mcs.png",
        out_pdf=out / "bler_vs_snr_by_mcs.pdf",
    )
    plot_figure7_panel(
        runs,
        mcs_vals,
        snr_vals,
        ul=True,
        caption=caption,
        show_title=not args.no_title,
        out_png=out / "bler_vs_snr_by_mcs_ul.png",
        out_pdf=out / "bler_vs_snr_by_mcs_ul.pdf",
    )

    # --- BLER vs cumulative TX; separate file per MCS, lines = SNR ---
    cmap = plt.cm.tab10
    plt.rcParams.update(
        {
            "figure.figsize": (8, 5),
            "figure.dpi": 150,
            "font.size": 11,
            "font.family": "serif",
            "axes.grid": True,
            "grid.alpha": 0.3,
        }
    )

    for mcs in mcs_vals:
        fig, (ax_d, ax_u) = plt.subplots(1, 2, figsize=(12, 5))
        for j, snr in enumerate(snr_vals):
            p = runs.get((mcs, snr))
            if p is None:
                continue
            paths = stats_csvs_for_cell(p)
            if not paths:
                continue
            csv_path = paths[0]
            deltas = annotate_cumulative_tx(compute_deltas(load_timeseries(str(csv_path))))
            color = cmap(j % 10)
            xd = [d["dl_tx_cum"] for d in deltas if d["dl_first_tx"] > 0]
            yd = [d["dl_bler"] for d in deltas if d["dl_first_tx"] > 0]
            xu = [d["ul_tx_cum"] for d in deltas if d["ul_first_tx"] > 0]
            yu = [d["ul_bler"] for d in deltas if d["ul_first_tx"] > 0]
            if xd:
                ax_d.plot(xd, yd, "o-", ms=3, color=color, label=f"SNR {snr} dB")
            if xu:
                ax_u.plot(xu, yu, "o-", ms=3, color=color, label=f"SNR {snr} dB")
        ax_d.set_xlabel("Cumulative DL first transmissions")
        ax_d.set_ylabel("DL BLER / interval")
        ax_d.set_title(f"DL BLER vs cumulative TBs (MCS {mcs})")
        ax_d.set_ylim(-0.02, 1.05)
        ax_d.legend(loc="best", fontsize=8)

        ax_u.set_xlabel("Cumulative UL first transmissions")
        ax_u.set_ylabel("UL BLER / interval")
        ax_u.set_title(f"UL BLER vs cumulative TBs (MCS {mcs})")
        ax_u.set_ylim(-0.02, 1.05)
        ax_u.legend(loc="best", fontsize=8)
        fig.tight_layout()
        fig.savefig(out / f"bler_vs_cumtx_mcs{mcs}.png", bbox_inches="tight")
        fig.savefig(out / f"bler_vs_cumtx_mcs{mcs}.pdf", bbox_inches="tight")
        plt.close(fig)

    print(f"Wrote plots under {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
