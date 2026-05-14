# Monte Carlo BLER Sweep — **100 trials × 100 DL first‑TX**

This README describes the **moderate‑statistics** Monte Carlo preset used for shorter runs on a **real Linux host** with OpenAirInterface (**RFSim**, phy‑test). It matches the **defaults built into `run_montecarlo.sh`**: **`NUM_TRIALS=100`** and **`TARGET_TX=100`**. The sweep channel defaults to **BICTR lunar** (`BICTR_LUNAR`).

## Run commands (copy‑paste)

**1 — Defaults only** (**100 trials × 100 DL first‑TX**, BICTR full MCS×noise, **22 000** simulator runs):

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_100x100_default.log"
```

**2 — Same statistics, explicit flags + log**:

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  --trials 100 \
  --target-tx 100 \
  --warmup 12 \
  --duration 120 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_100x100_explicit.log"
```

**3 — Plot the latest completed run’s CSV**:

```bash
cd bictr_analysis
LATEST_CSV="$(ls -td montecarlo_results/*/montecarlo_results.csv 2>/dev/null | head -1)"
python3 plot_montecarlo.py "$LATEST_CSV" --direction DL -o "$(dirname "$LATEST_CSV")/plots"
echo "Plots: $(dirname "$LATEST_CSV")/plots/"
```

**4 — Faster smoke sweep** (one MCS subset, fewer noise points; still **100×100** per cell):

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  --mcs 9 \
  --noise 10,6,2,-2,-8,-14,-18,-22 \
  --trials 100 \
  --target-tx 100 \
  --warmup 8 \
  --duration 90 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_100x100_smoke.log"
```

**5 — Optional: merge shards** from parallel **isolated** hosts, then plot:

```bash
cd bictr_analysis
python3 merge_montecarlo_csv.py -o merged_100x100/montecarlo_results.csv \
  shards/host1.csv shards/host2.csv

python3 plot_montecarlo.py merged_100x100/montecarlo_results.csv \
  --direction DL -o merged_100x100/plots
```

## Defaults (no overrides)

Equivalent to **§1** (`sudo ./run_montecarlo.sh` with no flags). Implicit settings:

| Setting | Default |
|---------|---------|
| `--trials` | **100** |
| `--target-tx` | **100** |
| `--duration` | **120** (seconds max measurement per trial) |
| `--warmup` | **12** (seconds) |
| Channel | **BICTR_LUNAR** |
| MCS | **9–28** (20 values) |
| `--noise` | `6 4 2 0 -2 -4 -6 -8 -10 -14 -20` (**11** values) |

**Total simulator runs:** `20 × 11 × 100 = **22 000**` (printed at script start).

If trials often **time out** before reaching 100 first‑TX, raise **`--duration`** (e.g. **`180`**); see **§ Run command 2**.

For a **single‑MCS** BICTR quick curve using env defaults, run **`sudo ./run_montecarlo_single_mcs.sh <MCS>`** (see that script).

## Prerequisites

- OAI built under **`cmake_targets/ran_build/build`**. **`sudo`** required.  
- BICTR templates under **`targets/PROJECTS/GENERIC-NR-5GC/CONF/`**.  
- Python **numpy** + **matplotlib** for **`plot_montecarlo.py`**.

## Related

- High‑statistics campaign: **`README_montecarlo_1000x1000.md`**  
- Merge helper: **`merge_montecarlo_csv.py`**
