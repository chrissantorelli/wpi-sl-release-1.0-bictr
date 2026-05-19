# Monte Carlo in Docker

OAI RFSim + BICTR phy-test Monte Carlo sweeps run inside **`oai-montecarlo:latest`**.

| Item | Location |
|------|----------|
| Dockerfile | `openairinterface5g/Dockerfile.montecarlo` |
| Run helper | `bictr_analysis/docker-run-montecarlo.sh` |
| Results (host) | `bictr_analysis/montecarlo_results/` |
| RRC phy-test seeds | `bictr_analysis/phytest_rrc/reconfig.raw`, `rbconfig.raw` |

The helper mounts **`bictr_terrain/`** (DEM) and the full **`bictr_analysis/`** tree from the host, so script updates apply without rebuilding the image.

---

## Prerequisites (any machine)

```bash
# Docker
docker --version

# TUN device (gNB PDCP); usually present on Linux servers
sudo modprobe tun
ls -l /dev/net/tun

# Terrain file (not in git — copy from build machine)
ls -lh ~/openairinterface5g/bictr_terrain/lunar_south_pole.bdem
```

---

## Build the image (first time on a machine)

```bash
cd ~/openairinterface5g
docker build -f Dockerfile.montecarlo -t oai-montecarlo:latest .
```

Or build via the helper:

```bash
cd ~/openairinterface5g/bictr_analysis
./docker-run-montecarlo.sh --build --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90
```

First build compiles OAI inside the image (~30–60+ minutes). Rebuild only after OAI/BICTR code or `Dockerfile.montecarlo` changes.

---

## Run commands (copy-paste)

All commands assume:

```bash
cd ~/openairinterface5g/bictr_analysis
```

### Smoke test (verified)

One MCS, one noise point, 50 DL first-TX, 1 trial (~1 minute):

```bash
./docker-run-montecarlo.sh \
  --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90
```

**Success looks like:** `DL_first_tx=50+`, no `Aborted (core dumped)`, no `waiting for nrMAC_stats.log` loop.

### Full campaign — default grid (MCS 9–28)

**1000 trials × 1000 DL first-TX** per (MCS, `noise_power_dB`) cell → **220 000** simulator runs:

```bash
./docker-run-montecarlo.sh \
  --trials 1000 \
  --target-tx 1000 \
  --warmup 15 \
  --duration 600 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_1000x1000.log"
```

### Full campaign — MCS 0–28

**319 000** simulator runs:

```bash
./docker-run-montecarlo.sh \
  --mcs $(seq -s, 0 28) \
  --trials 1000 \
  --target-tx 1000 \
  --warmup 15 \
  --duration 600 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_1000x1000_mcs0-28.log"
```

### Plot latest results (on host)

```bash
cd ~/openairinterface5g/bictr_analysis
LATEST_CSV="$(ls -td montecarlo_results/*/montecarlo_results.csv | head -1)"
python3 plot_montecarlo.py "$LATEST_CSV" --direction DL -o "$(dirname "$LATEST_CSV")/plots"
```

---

## What `docker-run-montecarlo.sh` does

Equivalent to:

```bash
docker run --rm -it \
  --shm-size=2g \
  --cap-add=SYS_NICE \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v "$REPO_ROOT/bictr_terrain:/opt/openairinterface5g/bictr_terrain:ro" \
  -v "$REPO_ROOT/bictr_analysis:/opt/openairinterface5g/bictr_analysis" \
  oai-montecarlo:latest \
  bash -lc 'cd /opt/openairinterface5g/bictr_analysis && ./run_montecarlo.sh <your flags>'
```

---

## Export image → use on a more powerful machine

You need **two things** on the remote host:

1. **Docker image** `oai-montecarlo:latest` (OAI binaries + deps baked in)
2. **Host directories** mounted at run time:
   - `bictr_analysis/` — scripts, `phytest_rrc/`, `montecarlo_results/`
   - `bictr_terrain/lunar_south_pole.bdem` — ~1.4 GB DEM (gitignored)

### On the build machine (export)

**One-shot helper:**

```bash
cd ~/openairinterface5g/bictr_analysis
./docker-export-montecarlo.sh
# writes ~/openairinterface5g/oai-montecarlo_latest.tar.gz
# and ~/openairinterface5g/bictr-montecarlo-runtime.tgz
```

**Manual steps:**

```bash
cd ~/openairinterface5g

# 1) Save image (~several GB compressed)
docker save oai-montecarlo:latest | gzip -1 > oai-montecarlo_latest.tar.gz

# 2) Pack runtime files the container mounts (scripts + terrain + seeds)
tar czf bictr-montecarlo-runtime.tgz \
  bictr_analysis/docker-run-montecarlo.sh \
  bictr_analysis/run_montecarlo.sh \
  bictr_analysis/run_montecarlo_single_mcs.sh \
  bictr_analysis/parse_montecarlo_point.py \
  bictr_analysis/plot_montecarlo.py \
  bictr_analysis/merge_montecarlo_csv.py \
  bictr_analysis/phytest_rrc \
  bictr_analysis/README.docker.md \
  bictr_terrain/lunar_south_pole.bdem

# 3) Copy to remote (example)
scp oai-montecarlo_latest.tar.gz bictr-montecarlo-runtime.tgz user@REMOTE:~/openairinterface5g/
```

`rsync` is better for large files or resume:

```bash
rsync -avP oai-montecarlo_latest.tar.gz bictr-montecarlo-runtime.tgz user@REMOTE:~/openairinterface5g/
```

### On the powerful machine (import)

```bash
mkdir -p ~/openairinterface5g
cd ~/openairinterface5g

# 1) Load image
gunzip -c oai-montecarlo_latest.tar.gz | docker load
docker images | grep oai-montecarlo

# 2) Unpack runtime tree (creates bictr_analysis/ and bictr_terrain/)
tar xzf bictr-montecarlo-runtime.tgz

chmod +x bictr_analysis/docker-run-montecarlo.sh

# 3) TUN + smoke test
sudo modprobe tun
cd bictr_analysis
./docker-run-montecarlo.sh \
  --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90
```

### Full grid on remote

```bash
cd ~/openairinterface5g/bictr_analysis

./docker-run-montecarlo.sh \
  --trials 1000 --target-tx 1000 --warmup 15 --duration 600 \
  2>&1 | tee "montecarlo_results/run_$(date +%Y%m%d_%H%M%S)_1000x1000.log"
```

Results stay on the remote disk under `montecarlo_results/`. Copy CSVs back for plotting:

```bash
# From laptop
scp -r user@REMOTE:~/openairinterface5g/bictr_analysis/montecarlo_results ./montecarlo_results_from_remote
```

---

## Alternative: full git checkout on remote

Instead of `bictr-montecarlo-runtime.tgz`, clone/copy the repo and only transfer the image + DEM:

```bash
git clone <your-repo-url> ~/openairinterface5g
# copy lunar_south_pole.bdem into bictr_terrain/
gunzip -c oai-montecarlo_latest.tar.gz | docker load
cd ~/openairinterface5g/bictr_analysis
./docker-run-montecarlo.sh --trials 1000 --target-tx 1000 --warmup 15 --duration 600
```

Rebuild on remote only if you change OAI/BICTR source (`docker build -f Dockerfile.montecarlo ...`).

---

## Parallel workers (optional)

Do **not** run two containers on the **same** host sharing one build dir (they collide on `nrMAC_stats.log`).

For multiple machines:

1. Export the same image to each host.
2. Copy `bictr_analysis/` + `bictr_terrain/`.
3. Run disjoint slices, e.g. different `--mcs` subsets:

```bash
# Worker A
./docker-run-montecarlo.sh --mcs $(seq -s, 0 9) --trials 1000 --target-tx 1000 --warmup 15 --duration 600

# Worker B
./docker-run-montecarlo.sh --mcs $(seq -s, 10 19) --trials 1000 --target-tx 1000 --warmup 15 --duration 600
```

Merge CSVs on one machine:

```bash
python3 merge_montecarlo_csv.py -o merged/montecarlo_results.csv \
  workerA/montecarlo_results/*/montecarlo_results.csv \
  workerB/montecarlo_results/*/montecarlo_results.csv
python3 plot_montecarlo.py merged/montecarlo_results.csv -o merged/plots
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Aborted` / `cannot read file reconfig.raw` | Use current `run_montecarlo.sh` + `phytest_rrc/`; image ≥ 2026-05-19 fixes |
| `gNB exited` / `[TUN] failed to open /dev/net/tun` | `sudo modprobe tun`; use `docker-run-montecarlo.sh` (adds `--device /dev/net/tun`) |
| `UE_PID: unbound variable` | Update `run_montecarlo.sh` from repo |
| `DL_first_tx=0` | gNB/UE not linked; check `gnb.log` in `/tmp/mc_oai.*` inside container |
| DEM warnings | Mount `bictr_terrain/lunar_south_pole.bdem`; flat fallback still runs but not lunar terrain |

---

## phy-test / RRC note

`nr-uesoftmodem` in phy-test mode needs `reconfig.raw` and `rbconfig.raw` under `cmake_targets/ran_build/build/`. The run script:

- Seeds from `bictr_analysis/phytest_rrc/`
- Waits for the gNB to refresh them (up to 120s)
- Passes `--rrc_config_path` to the UE

See also: `README_montecarlo_100x100.md`, `README_montecarlo_1000x1000.md`.
