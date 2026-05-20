#!/usr/bin/env bash
#
# Parallel Monte Carlo BLER waterfall for SL Mode 1 over the BICTR lunar channel.
#
# Sweeps MCS 0–28 and channelmod noise_power_dB (BICTR_LUNAR configs). Shards MCS
# across N workers (separate OAI build dirs → no nrMAC_stats.log collision). Merges
# shard CSVs and plots BLER vs effective SNR (−noise_power_dB) waterfalls.
#
# Requires lunar DEM (bictr_terrain/lunar_south_pole.bdem) for terrain; OAI falls
# back to flat terrain if the file is missing.
#
# Usage (requires root — run once with sudo):
#   sudo ./run_montecarlo_parallel_slmode1_lunar.sh
#   sudo ./run_montecarlo_parallel_slmode1_lunar.sh --workers 16 --trials 1000
#   sudo ./run_montecarlo_parallel_slmode1_lunar.sh --quick
#
# Options:
#   --workers N        parallel workers (default: nproc, all logical CPUs)
#   --trials N         trials per (MCS, noise) cell (default: 1000)
#   --target-tx N      DL first-TX stop target per trial (default: 1000)
#   --warmup SEC       warmup seconds (default: 15)
#   --duration SEC     max measurement seconds per trial (default: 600)
#   --noise LIST       comma-separated channelmod noise_power_dB (default: full grid)
#   --quick            35 trials × 80 TX, 120s duration (smoke / timing test)
#   --no-plot          skip plot_montecarlo.py after merge
#   --keep-builds      do not delete per-worker build trees
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_BUILD="$OAI_DIR/cmake_targets/ran_build/build"
WORKER_BUILD_ROOT="$SCRIPT_DIR/montecarlo_parallel_builds_lunar"
DEM_FILE="$OAI_DIR/bictr_terrain/lunar_south_pole.bdem"
RUN_TAG="$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="$SCRIPT_DIR/montecarlo_results/parallel_slmode1_lunar_${RUN_TAG}"

WORKERS=""
NUM_TRIALS=1000
TARGET_TX=1000
WARMUP=15
RUN_DURATION=600
# Default BICTR_LUNAR sweep (matches run_montecarlo.sh)
NOISE_LIST="6,4,2,0,-2,-4,-6,-8,-10,-14,-20"
DO_PLOT=1
KEEP_BUILDS=0
QUICK=0
EXTRA_MC_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) WORKERS="$2"; shift 2 ;;
    --trials) NUM_TRIALS="$2"; shift 2 ;;
    --target-tx) TARGET_TX="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --duration) RUN_DURATION="$2"; shift 2 ;;
    --noise) NOISE_LIST="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --no-plot) DO_PLOT=0; shift ;;
    --keep-builds) KEEP_BUILDS=1; shift ;;
    -h|--help)
      sed -n '1,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *)
      EXTRA_MC_ARGS+=("$1")
      shift ;;
  esac
done

if [[ $QUICK -eq 1 ]]; then
  NUM_TRIALS=35
  TARGET_TX=80
  WARMUP=12
  RUN_DURATION=120
  NOISE_LIST="6,4,2,0,-2,-4,-6"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run with sudo (workers call run_montecarlo.sh as root)." >&2
  exit 1
fi

if [[ ! -x "$MAIN_BUILD/nr-softmodem" || ! -x "$MAIN_BUILD/nr-uesoftmodem" ]]; then
  echo "ERROR: build OAI first:" >&2
  echo "  cd $OAI_DIR/cmake_targets && ./build_oai -I && ./build_oai --ninja --gNB --nrUE" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/phytest_rrc/reconfig.raw" ]]; then
  echo "ERROR: missing $SCRIPT_DIR/phytest_rrc/reconfig.raw (phy-test seeds)." >&2
  exit 1
fi

if [[ ! -f "$DEM_FILE" ]]; then
  echo "WARNING: lunar DEM not found at $DEM_FILE" >&2
  echo "         BICTR will use flat terrain (see gNB log for [BICTR] DEM load failed)." >&2
fi

# Each worker runs inside its own Linux network namespace so that the gNB and
# UE can each create their hard-coded TUN interfaces (oaitun_enb1 / oaitun_ue1)
# and bind rfsim on 127.0.0.1:4043 without colliding across workers. Requires
# `ip` (iproute2) and root.
if ! command -v ip >/dev/null 2>&1; then
  echo "ERROR: 'ip' (iproute2) is required for per-worker netns isolation." >&2
  exit 1
fi
NETNS_PREFIX="mc_worker_${RUN_TAG}"
cleanup_netns() {
  local i
  for ((i=0; i<WORKERS; i++)); do
    ip netns del "${NETNS_PREFIX}_${i}" 2>/dev/null || true
  done
}
trap cleanup_netns EXIT INT TERM

if [[ -z "$WORKERS" ]]; then
  WORKERS=$(nproc 2>/dev/null || echo 4)
  if [[ "$WORKERS" -lt 1 ]]; then
    WORKERS=1
  fi
fi

mapfile -t ALL_MCS < <(seq 0 28)
IFS=',' read -ra NOISE_VALUES <<< "$NOISE_LIST"
N_MCS=${#ALL_MCS[@]}
N_NOISE=${#NOISE_VALUES[@]}
TOTAL_TRIALS=$((N_MCS * N_NOISE * NUM_TRIALS))

mkdir -p "$RUN_ROOT"
echo "======================================================="
echo "  Parallel SL Mode 1 Monte Carlo (BICTR lunar channel)"
echo "  MCS:              0–28 ($N_MCS values)"
echo "  noise_power_dB:   ${NOISE_VALUES[*]}"
echo "  Plot x-axis:      −noise_power_dB (higher = better)"
echo "  Trials/cell:      $NUM_TRIALS"
echo "  Target DL TX:     $TARGET_TX"
echo "  Workers:          $WORKERS (all available CPUs)"
echo "  Total trials:     $TOTAL_TRIALS"
echo "  DEM:              $DEM_FILE"
echo "  Run root:         $RUN_ROOT"
echo "======================================================="
echo ""

prepare_worker_build() {
  local id="$1"
  local dst="$WORKER_BUILD_ROOT/worker_${id}"
  rm -rf "$dst"
  mkdir -p "$WORKER_BUILD_ROOT"
  if cp -al "$MAIN_BUILD" "$dst" 2>/dev/null; then
    :
  else
    cp -a "$MAIN_BUILD" "$dst"
  fi
  cp "$SCRIPT_DIR/phytest_rrc/reconfig.raw" "$SCRIPT_DIR/phytest_rrc/rbconfig.raw" "$dst/"
  echo "$dst"
}

split_mcs_for_worker() {
  local id=$1
  local start=$(( id * N_MCS / WORKERS ))
  local end=$(( (id + 1) * N_MCS / WORKERS ))
  local chunk=()
  local i
  for ((i=start; i<end; i++)); do
    chunk+=("${ALL_MCS[i]}")
  done
  (IFS=,; echo "${chunk[*]}")
}

if command -v python3 >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/montecarlo_parallel_progress.py" \
    --run-root "$RUN_ROOT" \
    --total-rows "$TOTAL_TRIALS" \
    --workers "$WORKERS" \
    --desc "SL Mode 1 lunar (MCS 0–28)" &
  PROGRESS_PID=$!
else
  PROGRESS_PID=""
fi

PIDS=()
for ((w=0; w<WORKERS; w++)); do
  MCS_CHUNK=$(split_mcs_for_worker "$w")
  if [[ -z "$MCS_CHUNK" ]]; then
    touch "$RUN_ROOT/worker_${w}.done"
    continue
  fi

  WORKER_BUILD=$(prepare_worker_build "$w")
  WORKER_OUT="$RUN_ROOT/worker_${w}"
  mkdir -p "$WORKER_OUT"
  rm -f "$RUN_ROOT/worker_${w}.done"

  WORKER_PORT=$(( ${OAI_RFSIM_PORT_BASE:-4043} + w ))
  WORKER_NETNS="${NETNS_PREFIX}_${w}"

  # Create / reset this worker's netns and bring loopback up so localhost rfsim
  # works inside it. Each ns has its own oaitun_enb1/oaitun_ue1 + own 4043,
  # eliminating cross-worker TUN and port collisions.
  ip netns del "$WORKER_NETNS" 2>/dev/null || true
  ip netns add "$WORKER_NETNS"
  ip netns exec "$WORKER_NETNS" ip link set lo up

  echo "Worker $w: MCS {$MCS_CHUNK}  build=$WORKER_BUILD  rfsim_port=$WORKER_PORT  netns=$WORKER_NETNS"

  (
    trap 'touch "'"$RUN_ROOT"'/worker_'"$w"'.done"' EXIT
    export OAI_BUILD_DIR="$WORKER_BUILD"
    export MC_RUN_DIR="$WORKER_OUT"
    # Per-worker rfsim port (still set as defense-in-depth, though each netns
    # already has its own 4043).
    export OAI_RFSIM_PORT=$(( ${OAI_RFSIM_PORT_BASE:-4043} + w ))
    ip netns exec "$WORKER_NETNS" "$SCRIPT_DIR/run_montecarlo.sh" \
      --channels BICTR_LUNAR \
      --mcs "$MCS_CHUNK" \
      --noise "$NOISE_LIST" \
      --trials "$NUM_TRIALS" \
      --target-tx "$TARGET_TX" \
      --warmup "$WARMUP" \
      --duration "$RUN_DURATION" \
      "${EXTRA_MC_ARGS[@]}" \
      > "$WORKER_OUT/worker.log" 2>&1
  ) &
  PIDS+=($!)
done

FAIL=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    FAIL=$((FAIL + 1))
  fi
done

if [[ -n "$PROGRESS_PID" ]]; then
  wait "$PROGRESS_PID" 2>/dev/null || true
fi

MERGED="$RUN_ROOT/merged/montecarlo_results.csv"
mkdir -p "$RUN_ROOT/merged"
SHARDS=()
for ((w=0; w<WORKERS; w++)); do
  f="$RUN_ROOT/worker_${w}/montecarlo_results.csv"
  if [[ -f "$f" ]]; then
    SHARDS+=("$f")
  fi
done

if [[ ${#SHARDS[@]} -eq 0 ]]; then
  echo "ERROR: no shard CSVs produced." >&2
  exit 1
fi

python3 "$SCRIPT_DIR/merge_montecarlo_csv.py" -o "$MERGED" "${SHARDS[@]}"

echo ""
echo "======================================================="
echo "  Parallel lunar sweep finished (worker failures: $FAIL)"
echo "  Merged CSV: $MERGED"
echo "======================================================="

if [[ "$DO_PLOT" -eq 1 ]]; then
  python3 "$SCRIPT_DIR/plot_montecarlo.py" "$MERGED" \
    --channel BICTR_LUNAR --direction DL \
    -o "$RUN_ROOT/merged/plots"
  echo "  Plots:      $RUN_ROOT/merged/plots/"
fi

if [[ "$KEEP_BUILDS" -eq 0 ]]; then
  rm -rf "$WORKER_BUILD_ROOT"
fi

echo ""
echo "SL Mode 1 BLER waterfall (MCS 0–28, BICTR lunar): $MERGED"
