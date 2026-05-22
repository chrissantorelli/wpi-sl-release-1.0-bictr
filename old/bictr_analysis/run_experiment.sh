#!/usr/bin/env bash
#
# Run A/B RFsim experiments and collect nrMAC_stats time-series.
#
# Usage:
#   sudo ./run_experiment.sh [--duration SECONDS] [--samples SAMPLES] [--compare MODE]
#
# Modes (--compare):
#   awgn           BICTR fast (DEM) vs AWGN — two scenarios
#   triad          BICTR fast + BICTR aggressive + AWGN — three scenarios
#   bictr-flat     BICTR DEM terrain vs BICTR flat (empty DEM); fair geometry A/B
#
# Defaults: 60 seconds runtime, sampling nrMAC_stats every 1 second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"
RESULTS_DIR="$SCRIPT_DIR/results"
# DEM path must match gnb.sa...bictr.conf / ue.bictr.conf when using terrain
DEM_FILE="$OAI_DIR/bictr_terrain/lunar_south_pole.bdem"

DURATION=60
SAMPLE_INTERVAL=1
COMPARE_MODE="awgn"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --samples)  SAMPLE_INTERVAL="$2"; shift 2 ;;
    --compare)  COMPARE_MODE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$COMPARE_MODE" != "awgn" && "$COMPARE_MODE" != "bictr-flat" && "$COMPARE_MODE" != "triad" ]]; then
  echo "ERROR: --compare must be 'awgn', 'triad', or 'bictr-flat' (got: $COMPARE_MODE)" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [[ "$COMPARE_MODE" == "triad" || "$COMPARE_MODE" == "awgn" ]]; then
  if [[ ! -f "$DEM_FILE" ]]; then
    echo "WARNING: DEM not found at $DEM_FILE" >&2
    echo "         BICTR will fall back to flat terrain until you build the BDEM (pds_sldem_to_bdem.py)." >&2
  fi
fi

if [[ "$COMPARE_MODE" == "bictr-flat" ]]; then
  if [[ ! -f "$DEM_FILE" ]]; then
    echo "WARNING: DEM not found at $DEM_FILE" >&2
    echo "         The terrain run will fall back to flat in OAI (see gNB log for [BICTR] DEM load failed)." >&2
    echo "         Install the BDEM file there for a real terrain vs flat comparison." >&2
  fi
fi

run_scenario() {
  local SCENARIO_NAME="$1"
  local GNB_CONF="$2"
  local UE_CONF="$3"
  local OUT_DIR="$RESULTS_DIR/${TIMESTAMP}_${SCENARIO_NAME}"
  mkdir -p "$OUT_DIR"

  echo "=== Running scenario: $SCENARIO_NAME for ${DURATION}s ==="
  echo "    gNB Config: $GNB_CONF"
  echo "    UE  Config: $UE_CONF"
  echo "    Output: $OUT_DIR"

  # Clean any prior stats file
  rm -f "$BUILD_DIR/nrMAC_stats.log"

  # Launch gNB in background
  cd "$BUILD_DIR"
  ./nr-softmodem \
    -O "$GNB_CONF" \
    --rfsim --phy-test --noS1 \
    "--rfsimulator.[0].serveraddr" "server" \
    --gNBs.[0].min_rxtxtime 6 \
    > "$OUT_DIR/gnb.log" 2>&1 &
  GNB_PID=$!
  echo "    gNB PID: $GNB_PID"

  # Wait for gNB to start listening
  sleep 5

  # Launch UE in background — pass -O for channelmod on DL path
  ./nr-uesoftmodem \
    -O "$UE_CONF" \
    -r 106 --numerology 1 --band 78 -C 3619200000 \
    --rfsim --phy-test --noS1 \
    > "$OUT_DIR/ue.log" 2>&1 &
  UE_PID=$!
  echo "    UE  PID: $UE_PID"

  # Wait for UE to attach
  sleep 8

  # Sample nrMAC_stats.log periodically
  echo "    Sampling stats for ${DURATION}s (every ${SAMPLE_INTERVAL}s)..."
  local SAMPLE_COUNT=0
  local ELAPSED=0
  echo "sample_id,elapsed_s,raw_stats" > "$OUT_DIR/stats_timeseries.csv"

  while [[ $ELAPSED -lt $DURATION ]]; do
    if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
      STATS_LINE=$(cat "$BUILD_DIR/nrMAC_stats.log" 2>/dev/null | tr '\n' '|')
      echo "${SAMPLE_COUNT},${ELAPSED},${STATS_LINE}" >> "$OUT_DIR/stats_timeseries.csv"
    fi
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    sleep "$SAMPLE_INTERVAL"
    ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
  done

  echo "    Collected $SAMPLE_COUNT samples."

  # Capture final snapshot
  cp "$BUILD_DIR/nrMAC_stats.log" "$OUT_DIR/nrMAC_stats_final.log" 2>/dev/null || true

  # Extract BICTR-specific log lines
  grep -E "\[BICTR\]|\[CHANNEL\].*BICTR" "$OUT_DIR/gnb.log" > "$OUT_DIR/bictr_init.log" 2>/dev/null || true

  # Shutdown
  echo "    Stopping UE and gNB..."
  kill "$UE_PID" 2>/dev/null || true
  sleep 2
  kill "$GNB_PID" 2>/dev/null || true
  wait "$UE_PID" 2>/dev/null || true
  wait "$GNB_PID" 2>/dev/null || true
  sleep 2

  echo "    Scenario $SCENARIO_NAME complete."
  echo ""
}

if [[ "$COMPARE_MODE" == "bictr-flat" ]]; then
  echo "============================================"
  echo "  BICTR terrain (DEM) vs BICTR flat experiment"
  echo "  Duration per scenario: ${DURATION}s"
  echo "  Sample interval: ${SAMPLE_INTERVAL}s"
  echo "============================================"
  echo ""
  run_scenario "bictr_terrain" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf" \
    "$CONF_DIR/ue.bictr.conf"
  run_scenario "bictr_flat" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr_flat.conf" \
    "$CONF_DIR/ue.bictr_flat.conf"
  echo "=== Both scenarios complete ==="
  echo "Results in: $RESULTS_DIR/${TIMESTAMP}_*"
  echo ""
  echo "Generate plots with:"
  echo "  python3 $SCRIPT_DIR/plot_results.py $RESULTS_DIR/${TIMESTAMP}_bictr_terrain $RESULTS_DIR/${TIMESTAMP}_bictr_flat \\"
  echo "      --label-a 'BICTR DEM' --label-b 'BICTR flat'"
elif [[ "$COMPARE_MODE" == "triad" ]]; then
  echo "============================================"
  echo "  BICTR fast + BICTR aggressive + AWGN"
  echo "  Duration per scenario: ${DURATION}s"
  echo "  Sample interval: ${SAMPLE_INTERVAL}s"
  echo "============================================"
  echo ""
  run_scenario "bictr_fast" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf" \
    "$CONF_DIR/ue.bictr.conf"
  run_scenario "bictr_aggressive" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr_aggressive.conf" \
    "$CONF_DIR/ue.bictr_aggressive.conf"
  run_scenario "awgn" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.awgn.conf" \
    "$CONF_DIR/ue.awgn.conf"
  echo "=== All three scenarios complete ==="
  echo "Results in: $RESULTS_DIR/${TIMESTAMP}_*"
  echo ""
  echo "Plots:"
  echo "  python3 $SCRIPT_DIR/plot_results.py \\"
  echo "      $RESULTS_DIR/${TIMESTAMP}_bictr_fast $RESULTS_DIR/${TIMESTAMP}_bictr_aggressive $RESULTS_DIR/${TIMESTAMP}_awgn \\"
  echo "      --labels 'BICTR fast' 'BICTR aggressive' 'AWGN' -o $RESULTS_DIR/${TIMESTAMP}_plots"
else
  echo "============================================"
  echo "  BICTR fast (DEM) vs AWGN"
  echo "  Duration per scenario: ${DURATION}s"
  echo "  Sample interval: ${SAMPLE_INTERVAL}s"
  echo "  (use --compare triad for fast+aggressive+AWGN; --compare bictr-flat for DEM vs flat)"
  echo "============================================"
  echo ""
  run_scenario "bictr" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf" \
    "$CONF_DIR/ue.bictr.conf"
  run_scenario "awgn" \
    "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.awgn.conf" \
    "$CONF_DIR/ue.awgn.conf"
  echo "=== Both scenarios complete ==="
  echo "Results in: $RESULTS_DIR/${TIMESTAMP}_*"
  echo ""
  echo "Plots (BICTR fast vs AWGN):"
  echo "  python3 $SCRIPT_DIR/plot_results.py $RESULTS_DIR/${TIMESTAMP}_bictr $RESULTS_DIR/${TIMESTAMP}_awgn \\"
  echo "      --label-a 'BICTR fast' --label-b 'AWGN' -o $RESULTS_DIR/${TIMESTAMP}_plots"
fi

if [[ -n "${SUDO_USER:-}" ]]; then
  for d in "$RESULTS_DIR/${TIMESTAMP}_"*; do
    [[ -e "$d" ]] || continue
    chown -R "$SUDO_USER:$SUDO_USER" "$d"
  done
fi
