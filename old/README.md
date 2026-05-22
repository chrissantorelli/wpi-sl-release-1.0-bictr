# Archived BICTR / Monte Carlo tooling

Scripts and READMEs moved here because they are **not** used by the current
**`bictr_analysis/run_montecarlo.sh`** + **`plot_montecarlo.py`** workflow.

## `bictr_analysis/`

| Item | Was used for |
|------|----------------|
| `README_montecarlo_100x100.md` | 100 trials × 100 DL first-TX preset |
| `README_montecarlo_1000x1000.md` | 1000 × 1000 large campaign |
| `README.docker.md` | `oai-montecarlo` Docker image |
| `docker-run-montecarlo.sh`, `docker-export-montecarlo.sh` | Container runs |
| `run_montecarlo_parallel_slmode1*.sh` | Parallel MCS 0–28 (AWGN / lunar) |
| `run_montecarlo_single_mcs.sh` | Single-MCS quick curve wrapper |
| `run_mcs_snr_sweep.sh`, `mcs_snr_sweep_lib.sh`, `recover_mcs_snr_sweep.sh` | MCS×SNR time-series sweeps |
| `run_experiment.sh` | Timed BICTR vs AWGN A/B experiments |
| `plot_results.py`, `parse_stats.py`, `plot_mcs_snr_curves.py`, … | Non–Monte-Carlo plotting/parsing |
| `merge_montecarlo_csv.py` | Merge shards from parallel hosts |
| `BICTR_thesis_vs_oai_rfsim.tex`, `snapshot.readme`, `write_bdem.py` | Docs / terrain helpers |

## Root-level

| Item | Was used for |
|------|----------------|
| `Dockerfile.montecarlo` | Docker image build |
| `scripts/docker-montecarlo-entry.sh` | Container entrypoint |

Restore a file by moving it back into `bictr_analysis/` or the repo root.
