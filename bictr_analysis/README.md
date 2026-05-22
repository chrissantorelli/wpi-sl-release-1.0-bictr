# BICTR Monte Carlo BLER sweeps

Cellular phy-test Monte Carlo over the **BICTR lunar** channel (`BICTR_LUNAR`) using OAI RFSim.
Outputs CSV BLER data and Figure-7-style plots.

## Active files

| File | Role |
|------|------|
| `run_montecarlo.sh` | Main sweep driver (`--mcs`, `--noise`, `--trials`, `--target-tx`, …) |
| `parse_montecarlo_point.py` | Parses one trial from `nrMAC_stats.log` (called by the driver) |
| `plot_montecarlo.py` | Plots BLER vs SINR from `montecarlo_results.csv` |
| `phytest_rrc/` | RRC seeds (`reconfig.raw`, `rbconfig.raw`) for phy-test UE startup |

Configs (not in this folder): `targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf`, `ue.bictr.conf`.

## Run (example matching recent quick sweep)

One trial per (MCS, noise) point, ~100 DL first-TX per trial:

```bash
cd bictr_analysis

sudo ./run_montecarlo.sh \
  --mcs 9,20 \
  --noise 8,6,4,2,0,-2,-4,-6,-8,-10,-12,-14,-16,-18,-20,-22,-24,-26,-28,-30 \
  --trials 1 \
  --target-tx 100 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S).log"
```

Results land in `montecarlo_results/<timestamp>/montecarlo_results.csv` (gitignored).

## Plot

```bash
cd bictr_analysis
LATEST="$(ls -td montecarlo_results/*/montecarlo_results.csv 2>/dev/null | head -1)"
python3 plot_montecarlo.py "$LATEST" -o "$(dirname "$LATEST")"
```

Or a specific run:

```bash
python3 plot_montecarlo.py montecarlo_results/20260521_155838/montecarlo_results.csv \
  -o montecarlo_results/20260521_155838
```

## `run_montecarlo.sh` options (summary)

```
--mcs      Comma-separated MCS indices (default: 9–28)
--noise    channelmod noise_power_dB sweep (BICTR_LUNAR)
--trials   Trials per (MCS, noise) cell (default: 100)
--target-tx  Stop trial after this many DL first-TX (default: 100)
--warmup   Seconds before measurement (default: 12)
--duration Max measurement seconds (default: 120)
--channels BICTR_LUNAR (default) or AWGN for phy-test -s sweep
```

Requires **root** (`sudo`) and a built OAI tree at `cmake_targets/ran_build/build/`.

**Full flag definitions and flow diagram:** `doc/episys/README_MONTECARLO_BICTR.md`

## Archived tooling

Older experiment scripts, Docker helpers, parallel/100×100/1000×1000 READMEs, and sidelink/MCS×SNR sweep tools are under **`../old/`**.
