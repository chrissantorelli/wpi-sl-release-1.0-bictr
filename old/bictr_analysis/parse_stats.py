"""
Parser for OAI nrMAC_stats time-series collected by run_experiment.sh.

The stats_timeseries.csv has rows:
  sample_id, elapsed_s, raw_stats

where raw_stats is the full nrMAC_stats.log content with newlines replaced by '|'.

OAI stats are CUMULATIVE counters — they only grow. This parser extracts
the cumulative values at each sample, then computes per-interval deltas
for instantaneous BLER and throughput.
"""

import re
import csv
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class StatsSample:
    sample_id: int
    elapsed_s: float
    frame: int = 0
    slot: int = 0
    rsrp: int = 0
    dl_rounds: list = field(default_factory=lambda: [0, 0, 0, 0])
    dl_errors: int = 0
    dl_total_bytes: int = 0
    ul_rounds: list = field(default_factory=lambda: [0, 0, 0, 0])
    ul_errors: int = 0
    ul_total_bytes_scheduled: int = 0
    ul_total_bytes_received: int = 0
    pucch0_dtx: int = 0
    ulsch_dtx: int = 0


def parse_raw_stats(raw: str) -> dict:
    """Extract key fields from a pipe-delimited nrMAC_stats snapshot."""
    result = {}

    m = re.search(r'Frame\.Slot\s+(\d+)\.(\d+)', raw)
    if m:
        result['frame'] = int(m.group(1))
        result['slot'] = int(m.group(2))

    m = re.search(r'average RSRP\s+(-?\d+)', raw)
    if m:
        result['rsrp'] = int(m.group(1))

    m = re.search(r'dlsch_rounds\s+([\d/]+)', raw)
    if m:
        result['dl_rounds'] = [int(x) for x in m.group(1).split('/')]

    m = re.search(r'dlsch_errors\s+(\d+)', raw)
    if m:
        result['dl_errors'] = int(m.group(1))

    m = re.search(r'dlsch_total_bytes\s+(\d+)', raw)
    if m:
        result['dl_total_bytes'] = int(m.group(1))

    m = re.search(r'ulsch_rounds\s+([\d/]+)', raw)
    if m:
        result['ul_rounds'] = [int(x) for x in m.group(1).split('/')]

    m = re.search(r'ulsch_errors\s+(\d+)', raw)
    if m:
        result['ul_errors'] = int(m.group(1))

    m = re.search(r'pucch0_DTX\s+(\d+)', raw)
    if m:
        result['pucch0_dtx'] = int(m.group(1))

    m = re.search(r'ulsch_DTX\s+(\d+)', raw)
    if m:
        result['ulsch_dtx'] = int(m.group(1))

    m = re.search(r'ulsch_total_bytes_scheduled\s+(\d+)', raw)
    if m:
        result['ul_total_bytes_scheduled'] = int(m.group(1))

    m = re.search(r'ulsch_total_bytes_received\s+(\d+)', raw)
    if m:
        result['ul_total_bytes_received'] = int(m.group(1))

    return result


def load_timeseries(csv_path: str) -> list[StatsSample]:
    """Load stats_timeseries.csv and return list of StatsSample."""
    samples = []
    with open(csv_path) as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            if len(row) < 3:
                continue
            sample_id = int(row[0])
            elapsed_s = float(row[1])
            raw = row[2] if len(row) == 3 else ','.join(row[2:])

            parsed = parse_raw_stats(raw)
            if not parsed:
                continue

            s = StatsSample(sample_id=sample_id, elapsed_s=elapsed_s)
            s.frame = parsed.get('frame', 0)
            s.rsrp = parsed.get('rsrp', 0)
            s.dl_rounds = parsed.get('dl_rounds', [0, 0, 0, 0])
            s.dl_errors = parsed.get('dl_errors', 0)
            s.dl_total_bytes = parsed.get('dl_total_bytes', 0)
            s.ul_rounds = parsed.get('ul_rounds', [0, 0, 0, 0])
            s.ul_errors = parsed.get('ul_errors', 0)
            s.ul_total_bytes_scheduled = parsed.get('ul_total_bytes_scheduled', 0)
            s.ul_total_bytes_received = parsed.get('ul_total_bytes_received', 0)
            s.pucch0_dtx = parsed.get('pucch0_dtx', 0)
            s.ulsch_dtx = parsed.get('ulsch_dtx', 0)
            samples.append(s)

    return samples


def compute_deltas(samples: list[StatsSample]) -> list[dict]:
    """Compute per-interval delta metrics from cumulative samples.

    Returns list of dicts with instantaneous BLER, throughput, etc.
    """
    deltas = []
    for i in range(1, len(samples)):
        prev, curr = samples[i - 1], samples[i]
        dt = curr.elapsed_s - prev.elapsed_s
        if dt <= 0:
            continue

        d_dl_r0 = curr.dl_rounds[0] - prev.dl_rounds[0]
        d_dl_err = curr.dl_errors - prev.dl_errors
        d_ul_r0 = curr.ul_rounds[0] - prev.ul_rounds[0]
        d_ul_err = curr.ul_errors - prev.ul_errors

        dl_bler = min(d_dl_err / d_dl_r0, 1.0) if d_dl_r0 > 0 else 0.0
        ul_bler = min(d_ul_err / d_ul_r0, 1.0) if d_ul_r0 > 0 else 0.0

        dl_retx_rate = ((curr.dl_rounds[1] - prev.dl_rounds[1]) / d_dl_r0) if d_dl_r0 > 0 else 0.0

        d_dl_bytes = curr.dl_total_bytes - prev.dl_total_bytes
        d_ul_bytes = curr.ul_total_bytes_received - prev.ul_total_bytes_received

        deltas.append({
            'elapsed_s': curr.elapsed_s,
            'dt': dt,
            'dl_first_tx': d_dl_r0,
            'dl_errors': d_dl_err,
            'dl_bler': dl_bler,
            'dl_retx_rate': dl_retx_rate,
            'dl_harq_rounds': [curr.dl_rounds[j] - prev.dl_rounds[j] for j in range(len(curr.dl_rounds))],
            'dl_throughput_kbps': d_dl_bytes * 8 / dt / 1000 if dt > 0 else 0,
            'ul_first_tx': d_ul_r0,
            'ul_errors': d_ul_err,
            'ul_bler': ul_bler,
            'ul_harq_rounds': [curr.ul_rounds[j] - prev.ul_rounds[j] for j in range(len(curr.ul_rounds))],
            'ul_throughput_kbps': d_ul_bytes * 8 / dt / 1000 if dt > 0 else 0,
            'rsrp': curr.rsrp,
        })

    return deltas


def annotate_cumulative_tx(deltas: list[dict]) -> list[dict]:
    """Add dl_tx_cum / ul_tx_cum (cumulative first-transmission counts at end of each interval)."""
    cdl = 0
    cul = 0
    out = []
    for d in deltas:
        cdl += d['dl_first_tx']
        cul += d['ul_first_tx']
        row = dict(d)
        row['dl_tx_cum'] = cdl
        row['ul_tx_cum'] = cul
        out.append(row)
    return out


def compute_summary(samples: list[StatsSample]) -> dict:
    """Compute overall summary statistics from first to last sample.

    DL/UL BLER here is ``(last_errors - first_errors) / (last_round0 - first_round0)`` using
    gNB MAC cumulative counters. This matches summing per-interval ``errors`` / ``first_tx`` from
    ``compute_deltas`` over the same window.

    In OAI NR **phy-test / RFSim**, ``dlsch_errors`` frequently does not increase during a trial
    even as ``dlsch_rounds[0]`` grows, so reported **DL BLER can sit at 0** while **UL** counters
    usually do increase, giving a non-zero **UL BLER** that need not vary monotonically with the
    ``-s`` SINR knob on the x-axis.
    """
    if len(samples) < 2:
        return {}

    first, last = samples[0], samples[-1]
    total_time = last.elapsed_s - first.elapsed_s

    dl_r0 = last.dl_rounds[0] - first.dl_rounds[0]
    dl_err = last.dl_errors - first.dl_errors
    ul_r0 = last.ul_rounds[0] - first.ul_rounds[0]
    ul_err = last.ul_errors - first.ul_errors

    return {
        'duration_s': total_time,
        'dl_total_tx': dl_r0,
        'dl_total_errors': dl_err,
        'dl_bler': dl_err / dl_r0 if dl_r0 > 0 else 0.0,
        'dl_harq_distribution': [last.dl_rounds[j] - first.dl_rounds[j]
                                  for j in range(len(last.dl_rounds))],
        'dl_throughput_kbps': (last.dl_total_bytes - first.dl_total_bytes) * 8 / total_time / 1000 if total_time > 0 else 0,
        'ul_total_tx': ul_r0,
        'ul_total_errors': ul_err,
        'ul_bler': ul_err / ul_r0 if ul_r0 > 0 else 0.0,
        'ul_harq_distribution': [last.ul_rounds[j] - first.ul_rounds[j]
                                  for j in range(len(last.ul_rounds))],
        'ul_throughput_kbps': (last.ul_total_bytes_received - first.ul_total_bytes_received) * 8 / total_time / 1000 if total_time > 0 else 0,
        'avg_rsrp': sum(s.rsrp for s in samples) / len(samples),
    }


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    csv_path = results_dir / 'stats_timeseries.csv'

    samples = load_timeseries(str(csv_path))
    print(f"Loaded {len(samples)} samples from {csv_path}")

    summary = compute_summary(samples)
    print(f"\n{'='*50}")
    print(f"Summary over {summary.get('duration_s', 0):.1f}s:")
    print(f"  DL: {summary.get('dl_total_tx', 0)} TX, "
          f"{summary.get('dl_total_errors', 0)} errors, "
          f"BLER={summary.get('dl_bler', 0):.5f}, "
          f"throughput={summary.get('dl_throughput_kbps', 0):.1f} kbps")
    print(f"  DL HARQ rounds: {summary.get('dl_harq_distribution', [])}")
    print(f"  UL: {summary.get('ul_total_tx', 0)} TX, "
          f"{summary.get('ul_total_errors', 0)} errors, "
          f"BLER={summary.get('ul_bler', 0):.5f}, "
          f"throughput={summary.get('ul_throughput_kbps', 0):.1f} kbps")
    print(f"  UL HARQ rounds: {summary.get('ul_harq_distribution', [])}")
    print(f"  Avg RSRP: {summary.get('avg_rsrp', 0):.1f} dBm")
    print(f"{'='*50}")
