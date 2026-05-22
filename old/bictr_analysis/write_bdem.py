#!/usr/bin/env python3
"""
Write a BDEM file for OAI BICTR (see openair1/SIMULATION/TOOLS/bictr_channel.c:bictr_dem_load).

Layout (little-endian):
  - 4 bytes: magic "BDEM"
  - int32 n_lon, int32 n_lat
  - 4 x float64: min_lon, max_lon, min_lat, max_lat
  - n_lon * n_lat x float32 heights, row-major with iy=0 at min_lat (south row)
    and ix=0 at min_lon (west column), matching dem->data[iy * n_lon + ix].

You provide a 2D float32 (or convertible) array shape (n_lat, n_lon) and the W/E/S/N bounds in degrees.
"""

from __future__ import annotations

import argparse
import struct
import sys

import numpy as np

MAGIC = b"BDEM"


def write_bdem(
    path: str,
    elevation_m: np.ndarray,
    min_lon: float,
    max_lon: float,
    min_lat: float,
    max_lat: float,
) -> None:
    z = np.asarray(elevation_m, dtype=np.float32)
    if z.ndim != 2:
        raise ValueError("elevation must be 2D with shape (n_lat, n_lon)")
    n_lat, n_lon = z.shape
    if n_lat < 2 or n_lon < 2:
        raise ValueError("need at least 2x2 samples for bictr bilinear interp edges")
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
    if len(body) != n_lon * n_lat * 4:
        raise RuntimeError("internal pack error")
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(body)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("-o", "--output", required=True, help="Output .bin path")
    p.add_argument(
        "--npy",
        required=True,
        help="NumPy .npy file: 2D float array, shape (n_lat, n_lon), "
        "row 0 = min_lat (south), last row = max_lat (north); columns min_lon→max_lon",
    )
    p.add_argument("--min-lon", type=float, required=True)
    p.add_argument("--max-lon", type=float, required=True)
    p.add_argument("--min-lat", type=float, required=True)
    p.add_argument("--max-lat", type=float, required=True)
    args = p.parse_args()

    z = np.load(args.npy)
    write_bdem(
        args.output,
        z,
        args.min_lon,
        args.max_lon,
        args.min_lat,
        args.max_lat,
    )
    print(
        f"Wrote {args.output}  BDEM  "
        f"{z.shape[1]}x{z.shape[0]} lon [{args.min_lon},{args.max_lon}] "
        f"lat [{args.min_lat},{args.max_lat}]",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
