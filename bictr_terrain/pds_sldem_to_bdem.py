#!/usr/bin/env python3
"""
Convert PDS3 SLDEM rasters to OAI BDEM for bictr_dem_load.

Inputs:
  - Uncompressed *.IMG + label (e.g. *_FLOAT.LBL with LINES / LINE_SAMPLES), or
  - JPEG2000 *.JP2 + detached label (e.g. *_JP2.LBL with LINE_LAST_PIXEL in
    IMAGE_MAP_PROJECTION).

The label must describe *elevation* (HEIGHT / shape), not slope (NAME = SLOPE).

Layout (BDEM, little-endian): see bictr_analysis/write_bdem.py and bictr_channel.c.

Examples:

  python3 pds_sldem_to_bdem.py --lbl tile.LBL --img tile_FLOAT.IMG -o out.bdem
  python3 pds_sldem_to_bdem.py --lbl tile_JP2.LBL --jp2 tile.JP2 -o out.bdem

SLDEM FLOAT/JP2 values are usually kilometers relative to the reference radius; the
script scales to meters for BICTR unless --height-scale overrides.

LRO cylindrical tiles: line 1 is the northern edge; by default we flip vertically
so BDEM row 0 is MINIMUM_LATITUDE (south row).
"""

from __future__ import annotations

import argparse
import re
import struct
import sys

import numpy as np

MAGIC = b"BDEM"


def _strip_value(raw: str) -> str:
    s = raw.strip().rstrip(";")
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    s = re.sub(r"\s*<[^>]+>\s*$", "", s).strip()
    return s


def parse_sldem_lbl(path: str) -> dict:
    d: dict[str, str] = {}
    with open(path, encoding="ascii", errors="replace") as f:
        for line in f:
            m = re.match(r"^\s*([A-Z0-9_]+)\s*=\s*(.*)$", line)
            if not m:
                continue
            key, val = m.group(1), _strip_value(m.group(2))
            if val and not val.startswith("{"):
                d[key] = val.split("{")[0].strip()
    return d


def lbl_int(lbl: dict, key: str) -> int:
    v = lbl[key]
    v = re.sub(r"\s*<[^>]+>\s*$", "", v).strip()
    return int(float(v))


def lbl_float(lbl: dict, key: str) -> float:
    v = lbl[key]
    v = re.sub(r"\s*<[^>]+>\s*$", "", v).strip()
    return float(v)


def image_line_sample_count(lbl: dict) -> tuple[int, int]:
    if "LINES" in lbl and "LINE_SAMPLES" in lbl:
        return lbl_int(lbl, "LINES"), lbl_int(lbl, "LINE_SAMPLES")
    if "LINE_LAST_PIXEL" in lbl and "SAMPLE_LAST_PIXEL" in lbl:
        n_lat = lbl_int(lbl, "LINE_LAST_PIXEL") - lbl_int(lbl, "LINE_FIRST_PIXEL") + 1
        n_lon = lbl_int(lbl, "SAMPLE_LAST_PIXEL") - lbl_int(lbl, "SAMPLE_FIRST_PIXEL") + 1
        return n_lat, n_lon
    raise KeyError("Label has neither LINES/LINE_SAMPLES nor LINE_*_PIXEL grid size")


def infer_height_scale_m(raw_lbl: str) -> float:
    if re.search(r"UNIT\s*=\s*KILOMETER", raw_lbl, re.I):
        return 1000.0
    if re.search(r"UNIT\s*=\s*METER", raw_lbl, re.I):
        return 1.0
    # JP2 detached labels often omit UNIT; values match FLOAT IMG (km vs 1737.4 km).
    if "LRO-L-LOLA-4-GDR-V1.0" in raw_lbl and "SLDEM2015" in raw_lbl:
        return 1000.0
    return 1.0


def read_jp2(path: str) -> np.ndarray:
    try:
        import glymur  # type: ignore

        return np.asarray(glymur.Jp2k(path)[:])
    except ImportError:
        pass
    try:
        import rasterio  # type: ignore

        with rasterio.open(path) as src:
            return np.asarray(src.read(1), dtype=np.float64)
    except ImportError:
        pass
    try:
        from osgeo import gdal  # type: ignore

        ds = gdal.Open(path)
        if ds is None:
            raise RuntimeError(f"gdal.Open failed for {path}")
        arr = ds.GetRasterBand(1).ReadAsArray()
        return np.asarray(arr, dtype=np.float64)
    except ImportError:
        pass
    raise RuntimeError(
        "Reading JP2 requires rasterio or GDAL Python bindings (osgeo.gdal). "
        "Install e.g. pip install rasterio, or python3-gdal."
    )


def image_is_slope(label_text: str) -> bool:
    if re.search(r"NAME\s*=\s*SLOPE\b", label_text, re.I):
        return True
    return False


def write_bdem_file(
    out_path: str,
    z: np.ndarray,
    min_lon: float,
    max_lon: float,
    min_lat: float,
    max_lat: float,
) -> None:
    z = np.asarray(z, dtype=np.float32)
    if z.ndim != 2:
        raise ValueError("elevation must be 2D (n_lat, n_lon)")
    n_lat, n_lon = z.shape
    hdr = struct.pack(
        "<4sii4d",
        MAGIC,
        int(n_lon),
        int(n_lat),
        float(min_lon),
        float(max_lon),
        float(min_lat),
        float(max_lat),
    )
    body = z.astype(np.float32, copy=False).tobytes(order="C")
    with open(out_path, "wb") as f:
        f.write(hdr)
        f.write(body)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lbl", required=True)
    ap.add_argument("--img", default=None, help="Uncompressed PDS float32 .IMG")
    ap.add_argument("--jp2", default=None, help="JPEG2000 .JP2 (needs rasterio or GDAL)")
    ap.add_argument("-o", "--output", required=True, help="Output BDEM path")
    ap.add_argument("--endian", choices=("<", ">"), default="<", help="numpy float32 endian (IMG only)")
    ap.add_argument(
        "--height-scale",
        type=float,
        default=None,
        help="Multiply elevations by this to get meters (default: infer from LBL, often 1000 for km)",
    )
    ap.add_argument(
        "--no-flip-lat",
        action="store_true",
        help="Do not flip vertically (use if row 0 is already min_lat / south row)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Allow conversion even if the label indicates a slope product (unsafe)",
    )
    args = ap.parse_args()

    if (args.img is None) == (args.jp2 is None):
        print("[pds_sldem_to_bdem] Specify exactly one of --img or --jp2", file=sys.stderr)
        return 2

    with open(args.lbl, encoding="ascii", errors="replace") as f:
        raw_lbl = f.read()

    if image_is_slope(raw_lbl) and not args.force:
        print(
            "[pds_sldem_to_bdem] This label describes a SLOPE map (degrees), not elevation (m).\n"
            "  BICTR will misbehave if you feed slope as height. Download the SLDEM2015 *elevation*\n"
            "  tile for the same lon/lat footprint (product name differs from the *_SL_* slope tiles).\n"
            "  Override with --force only if you know what you are doing.",
            file=sys.stderr,
        )
        return 2

    lbl = parse_sldem_lbl(args.lbl)
    n_lines, n_samp = image_line_sample_count(lbl)
    min_lon = lbl_float(lbl, "WESTERNMOST_LONGITUDE")
    max_lon = lbl_float(lbl, "EASTERNMOST_LONGITUDE")
    min_lat = lbl_float(lbl, "MINIMUM_LATITUDE")
    max_lat = lbl_float(lbl, "MAXIMUM_LATITUDE")

    if args.jp2:
        z = read_jp2(args.jp2)
        if z.shape != (n_lines, n_samp):
            print(
                f"[pds_sldem_to_bdem] JP2 shape {z.shape} != label {n_lines}x{n_samp}",
                file=sys.stderr,
            )
            return 1
    else:
        need_bytes = n_lines * n_samp * 4
        with open(args.img, "rb") as f:
            blob = f.read()
        if len(blob) != need_bytes:
            print(
                f"[pds_sldem_to_bdem] IMG size {len(blob)} != expected {need_bytes} "
                f"for {n_lines}x{n_samp} float32",
                file=sys.stderr,
            )
            return 1
        dt = np.dtype(args.endian + "f4")
        z = np.frombuffer(blob, dtype=dt).reshape(n_lines, n_samp)

    hscale = args.height_scale
    if hscale is None:
        if args.jp2 and np.issubdtype(z.dtype, np.integer):
            # SLDEM2015 JP2 uses int16; DN*0.5 = height in meters (matches FLOAT .IMG km range).
            hscale = 0.5
        else:
            hscale = infer_height_scale_m(raw_lbl)

    z = np.asarray(z, dtype=np.float64) * hscale
    if not args.no_flip_lat:
        z = np.flipud(z)

    write_bdem_file(args.output, z, min_lon, max_lon, min_lat, max_lat)
    print(
        f"Wrote {args.output}  BDEM  {n_samp}x{n_lines}  "
        f"lon [{min_lon},{max_lon}]  lat [{min_lat},{max_lat}]  height_scale={hscale}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
