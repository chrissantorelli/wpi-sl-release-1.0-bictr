#!/usr/bin/env bash
#
# Parallel Monte Carlo BLER sweep for SL Mode 1 (Ahmed et al. / AWGN phy-test Figure 7 style).
#
# Shards MCS 0–28 across N workers (separate OAI build dirs → no nrMAC_stats.log collision).
# Merges shard CSVs and optionally plots BLER vs SNR waterfalls.
#
# Usage (requires root — run once with sudo):
#   sudo ./run_montecarlo_parallel_slmode1.sh
#   sudo ./run_montecarlo_parallel_slmode1.sh --workers 8 --trials 1000 --target-tx 1000
#   sudo ./run_montecarlo_parallel_slmode1.sh --quick --workers 4
#
# Options:
#   --workers N        parallel workers (default: min(nproc, 8))
#   --trials N         trials per (MCS, SNR) cell (default: 1000)
#   --target-tx N      DL first-TX stop target per trial (default: 1000)
#   --warmup SEC       warmup seconds (default: 15)
#   --duration SEC     max measurement seconds per trial (default: 600)
#   --snr LIST         comma-separated SINR dB for AWGN (default: 14,16,18,20,22,24,26)
#   --quick            35 trials × 80 TX, 120s duration (smoke / timing test)
#   --no-plot          skip plot_montecarlo.py after merge
#   --keep-builds      do not delete per-worker build trees under montecarlo_parallel_builds/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_BUILD="$OAI_DIR/cmake_targets/ran_build/build"
WORKER_BUILD_ROOT="$SCRIPT_DIR/montecarlo_parallel_builds"
RUN_TAG="$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="$SCRIPT_DIR/montecarlo_results/parallel_slmode1_${RUN_TAG}"

WORKERS=""
NUM_TRIALS=1000
TARGET_TX=1000
WARMUP=15
RUN_DURATION=600
SNR_LIST="14,16,18,20,22,24,26"
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
    --snr) SNR_LIST="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --no-plot) DO_PLOT=0; shift ;;
    --keep-builds) KEEP_BUILDS=1; shift ;;
    -h|--help)
      sed -n '1,25p' "$0" | grep '^#' | sed 's/^# \?//'
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

if [[ -z "$WORKERS" ]]; then
  WORKERS=$(nproc 2>/dev/null || echo 4)
  if [[ "$WORKERS" -gt 8 ]]; then
    WORKERS=8
  fi
  if [[ "$WORKERS" -lt 1 ]]; then
    WORKERS=1
  fi
fi

mapfile -t ALL_MCS < <(seq 0 28)
IFS=',' read -ra SNR_VALUES <<< "$SNR_LIST"
N_MCS=${#ALL_MCS[@]}
N_SNR=${#SNR_VALUES[@]}
TOTAL_TRIALS=$((N_MCS * N_SNR * NUM_TRIALS))

mkdir -p "$RUN_ROOT"
echo "======================================================="
echo "  Parallel SL Mode 1 Monte Carlo (AWGN / Ahmed Fig. 7)"
echo "  MCS:           0–28 ($N_MCS values)"
echo "  SNR (dB):      ${SNR_VALUES[*]}"
echo "  Trials/cell:   $NUM_TRIALS"
echo "  Target DL TX:  $TARGET_TX"
echo "  Workers:       $WORKERS"
echo "  Total trials:  $TOTAL_TRIALS"
echo "  Run root:      $RUN_ROOT"
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

# Split MCS list into WORKERS contiguous chunks
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
    --desc "SL Mode 1 AWGN (MCS 0–28)" &
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

  echo "Worker $w: MCS {$MCS_CHUNK}  build=$WORKER_BUILD"

  (
    trap 'touch "'"$RUN_ROOT"'/worker_'"$w"'.done"' EXIT
    export OAI_BUILD_DIR="$WORKER_BUILD"
    export MC_RUN_DIR="$WORKER_OUT"
    "$SCRIPT_DIR/run_montecarlo.sh" \
      --channels AWGN \
      --mcs "$MCS_CHUNK" \
      --snr "$SNR_LIST" \
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
echo "  Parallel sweep finished (worker failures: $FAIL)"
echo "  Merged CSV: $MERGED"
echo "======================================================="

if [[ "$DO_PLOT" -eq 1 ]]; then
  python3 "$SCRIPT_DIR/plot_montecarlo.py" "$MERGED" \
    --channel AWGN --direction DL \
    -o "$RUN_ROOT/merged/plots"
  echo "  Plots:      $RUN_ROOT/merged/plots/"
fi

if [[ "$KEEP_BUILDS" -eq 0 ]]; then
  rm -rf "$WORKER_BUILD_ROOT"
fi

echo ""
echo "Ejaz SL Mode 1 waterfall (MCS 0–28, AWGN SINR): $MERGED"
