# Monte Carlo BLER Sweep — **1000 trials × 1000 DL first‑TX**

This README describes how to run the **high‑statistics** Monte Carlo campaign using `run_montecarlo.sh` on a **real Linux host** with a working OpenAirInterface build (**RFSim**, phy‑test). The driver defaults to the **BICTR lunar** channel (`BICTR_LUNAR`): templates `gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf` and `ue.bictr.conf`, with **`channelmod` `noise_power_dB`** swept via `--noise`.

## Run commands (copy‑paste)

**1 — Full grid, one machine** (BICTR default MCS×noise, **220 000** simulator runs). From repo root (`openairinterface5g`):

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  --trials 1000 \
  --target-tx 1000 \
  --warmup 15 \
  --duration 600 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_1000x1000.log"
```

**2 — Plot the latest completed run’s CSV** (DL figures + tables under `plots/`):

```bash
cd bictr_analysis
LATEST_CSV="$(ls -td montecarlo_results/*/montecarlo_results.csv 2>/dev/null | head -1)"
python3 plot_montecarlo.py "$LATEST_CSV" --direction DL -o "$(dirname "$LATEST_CSV")/plots"
echo "Plots: $(dirname "$LATEST_CSV")/plots/"
```

**3 — Optional: shard on 4 workers** (250 trials each → **1000** pooled trials per cell after merge). Run **exactly this block on each isolated host**, then combine CSVs from the four hosts:

Worker command (repeat per worker; paths must point at each shard’s `montecarlo_results.csv`):

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  --trials 250 \
  --target-tx 1000 \
  --warmup 15 \
  --duration 600 \
  2>&1 | tee "montecarlo_results/run_$(hostname)_shard.log"
```

After copying each host’s **`montecarlo_results/<timestamp>/montecarlo_results.csv`** into one directory (for example renaming them `shards/host1.csv`, …):

```bash
cd bictr_analysis
python3 merge_montecarlo_csv.py -o merged_1000x1000/montecarlo_results.csv \
  shards/host1.csv shards/host2.csv shards/host3.csv shards/host4.csv

python3 plot_montecarlo.py merged_1000x1000/montecarlo_results.csv \
  --direction DL -o merged_1000x1000/plots
```

## What “1000 × 1000” means here

| Parameter | Meaning |
|-----------|---------|
| `--trials 1000` | One thousand **independent** simulator runs **per** (MCS, `noise_power_dB`) cell. |
| `--target-tx 1000` | Each trial stops early after **`nrMAC_stats.log`** counts **1000 DL first transmissions** (`dlsch_rounds` numerator growth), unless `--duration` is hit first. |

Pooled BLER for each cell is computed when plotting: **total errors / total first‑TX** across all trials (see `plot_montecarlo.py` → `aggregate()`).

## Default grid size (BICTR, no extra flags)

With only `--trials 1000 --target-tx 1000` (and duration/warmup adjusted — see below):

- **MCS:** 9–28 → **20** values  
- **`noise_power_dB`:** `6 4 2 0 -2 -4 -6 -8 -10 -14 -20` → **11** values  
- **Total simulator runs:** `20 × 11 × 1000 = **220 000**`

Runtime is **order of weeks to months** on a **single** machine unless each trial is very short. Use **parallel hosts** and **merge CSVs** (see below).

## Prerequisites

- OAI built under `openairinterface5g/cmake_targets/ran_build/build` with `nr-softmodem` and `nr-uesoftmodem`.  
- Run as **root**: `sudo ./run_montecarlo.sh` (required by the script).  
- BICTR config templates present under `targets/PROJECTS/GENERIC-NR-5GC/CONF/`.  
- Python 3 with **numpy** and **matplotlib** for plotting.

**Why large `--duration`:** with `--target-tx 1000`, many trials will **never** reach the target before timeout if `--duration` is too small (default 120 s). Increase until logs consistently show **target reached**, or accept truncated statistics.

The script prints **`Output: …/montecarlo_results/<timestamp>`** at start — that directory contains **`montecarlo_results.csv`**.

Use **`mc_dl_bler_fig7.png`** under the plot output directory unless you specifically need UL. The plotting script also writes UL figures.

## Parallel safety

Do **not** run two copies of `run_montecarlo.sh` on the **same** host without separate build trees — they share **`nrMAC_stats.log`** under `cmake_targets/ran_build/build`.

## Worker estimate for ~24 h wall clock

`total_runs = N_mcs × N_noise × trials` (default **220 000** for full grid × 1000 trials).

Approximate parallel workers:

\[
\text{workers} \approx \left\lceil \frac{\text{total\_runs} \times t_{\text{avg\_seconds}}}{86400 \times \text{safety\_factor}} \right\rceil
\]

Example: `t_avg = 90` s, safety **1.15**, 24 h → `ceil(220000 × 90 / (86400 × 1.15)) ≈ **229**` identical workers if runs are evenly distributed.

## Related

- Lighter preset: **`README_montecarlo_100x100.md`**  
- Merge helper: **`merge_montecarlo_csv.py`**  
- Single‑MCS quick curve: **`run_montecarlo_single_mcs.sh`**
