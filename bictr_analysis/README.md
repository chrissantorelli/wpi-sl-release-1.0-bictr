# BICTR Channel Model — Experiment & Analysis Tooling

Automated A/B comparison of BICTR lunar channel vs AWGN baseline
using OAI RFsimulator in phy-test mode.

## Quick Start

```bash
# Run both BICTR and AWGN scenarios (100s each, ~10 000 frames)
cd bictr_analysis
sudo ./run_experiment.sh --duration 100

# Generate plots from the latest run
python3 plot_results.py results/<timestamp>_bictr results/<timestamp>_awgn
```

## What It Produces

### Collected Data (per scenario)
- `gnb.log` — full gNB console output
- `ue.log` — full UE console output
- `stats_timeseries.csv` — nrMAC_stats sampled every 1s
- `nrMAC_stats_final.log` — final stats snapshot
- `bictr_init.log` — BICTR channel initialization parameters

### Generated Figures
| File | Description |
|------|-------------|
| `dl_bler_timeseries.png/pdf` | DL BLER over time, BICTR vs AWGN |
| `ul_bler_timeseries.png/pdf` | UL BLER over time, BICTR vs AWGN |
| `harq_distribution.png/pdf` | HARQ round distribution (stacked bar) |
| `dl_throughput_timeseries.png/pdf` | DL throughput over time |
| `summary_table.png/pdf` | Side-by-side comparison table |

### Text Summary
The plot script also prints a text summary with:
- DL/UL BLER (computed as errors/first_tx, not the OAI windowed field)
- HARQ round distribution (round 0/1/2/3)
- DL/UL throughput in kbps
- Average RSRP

## Duration Guidelines

| Duration | Frames | BLER Resolution | Use Case |
|----------|--------|-----------------|----------|
| 30s | ~3 000 | ~10⁻¹ | Quick sanity check |
| 100s | ~10 000 | ~10⁻² | Standard evaluation |
| 300s | ~30 000 | ~10⁻³ | Publication quality |
| 1000s | ~100 000 | ~10⁻⁴ | High-precision measurement |

For thesis/publication work, 100–300s per scenario is standard.
At 10 000 frames you can resolve BLER down to ~0.01 with
statistical confidence.

## Options

```
sudo ./run_experiment.sh [--duration SECONDS] [--samples INTERVAL]
```

- `--duration` — how long to run each scenario (default: 60s)
- `--samples` — stats sampling interval in seconds (default: 1s)

## File Structure

```
bictr_analysis/
├── README.md
├── run_experiment.sh     # Orchestrator: runs gNB+UE, collects stats
├── parse_stats.py        # Parser: extracts metrics from OAI logs
├── plot_results.py       # Visualizer: generates publication figures
└── results/              # Created at runtime
    ├── 20260414_153000_bictr/
    │   ├── gnb.log
    │   ├── ue.log
    │   ├── stats_timeseries.csv
    │   ├── nrMAC_stats_final.log
    │   └── bictr_init.log
    └── 20260414_153000_awgn/
        ├── gnb.log
        ├── ue.log
        ├── stats_timeseries.csv
        └── nrMAC_stats_final.log
```
