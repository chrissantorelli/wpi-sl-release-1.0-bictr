#!/usr/bin/env python3
"""
Merge BICTR analysis figures from a directory into one multi-page PDF (Slack-friendly).

Prefers PNGs (what open() shows in most viewers). Order matches plot_results.py output.

Usage:
  python3 merge_plots_to_pdf.py \\
      --input /home/chris/openairinterface5g/bictr_analysis/results/20260430_112024_plots \\
      --output ~/Desktop/bictr_20260430_112024.pdf

  python3 merge_plots_to_pdf.py -i .../20260430_112024_plots   # writes <input>/bictr_plots_report.pdf
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Page order for sharing (story order)
PREFERRED_ORDER = (
    "dl_bler_timeseries.png",
    "ul_bler_timeseries.png",
    "dl_throughput_timeseries.png",
    "harq_distribution.png",
    "summary_table.png",
)


def collect_images(plot_dir: Path) -> list[Path]:
    pngs = {p.name: p for p in plot_dir.glob("*.png")}
    ordered: list[Path] = []
    for name in PREFERRED_ORDER:
        if name in pngs:
            ordered.append(pngs.pop(name))
    for name in sorted(pngs.keys()):
        ordered.append(pngs[name])
    return ordered


def rgb_image(path: Path):
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        print(
            "ERROR: needs Pillow. Install with:  python3 -m pip install pillow\n"
            "  (or: sudo apt install python3-pil)",
            file=sys.stderr,
        )
        raise SystemExit(1) from None

    im = Image.open(path)
    if im.mode in ("RGBA", "P"):
        bg = Image.new("RGB", im.size, (255, 255, 255))
        if im.mode == "P":
            im = im.convert("RGBA")
        bg.paste(im, mask=im.split()[-1] if im.mode == "RGBA" else None)
        im = bg
    elif im.mode != "RGB":
        im = im.convert("RGB")
    return im


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "-i",
        "--input",
        type=Path,
        required=True,
        help="Directory containing plot PNGs (e.g. .../20260430_112024_plots)",
    )
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output PDF path (default: <input>/bictr_plots_report.pdf)",
    )
    args = ap.parse_args()

    plot_dir = args.input.expanduser().resolve()
    if not plot_dir.is_dir():
        print(f"ERROR: not a directory: {plot_dir}", file=sys.stderr)
        return 1

    paths = collect_images(plot_dir)
    if not paths:
        print(f"ERROR: no PNG files found in {plot_dir}", file=sys.stderr)
        return 1

    out_pdf = args.output.expanduser().resolve() if args.output else plot_dir / "bictr_plots_report.pdf"
    out_pdf.parent.mkdir(parents=True, exist_ok=True)

    images = [rgb_image(p) for p in paths]
    first, rest = images[0], images[1:]
    first.save(
        out_pdf,
        "PDF",
        resolution=120,
        save_all=True,
        append_images=rest,
    )
    print(f"Wrote {len(paths)} page(s): {out_pdf}")
    for p in paths:
        print(f"  - {p.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
