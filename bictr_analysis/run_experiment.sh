#!/usr/bin/env bash
#
# Run a BICTR vs AWGN A/B experiment and collect stats for analysis.
#
# Usage:
#   sudo ./run_experiment.sh [--duration SECONDS] [--samples SAMPLES]
#
# Defaults: 60 seconds runtime, sampling nrMAC_stats every 1 second.
# Academically standard: 10 000+ frames (~100 s) gives statistically
# meaningful BLER at 10^-2 resolution (≥100 error events expected).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"
RESULTS_DIR="$SCRIPT_DIR/results"

DURATION=60
SAMPLE_INTERVAL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --samples)  SAMPLE_INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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

echo "============================================"
echo "  BICTR Channel Model — A/B Experiment"
echo "  Duration per scenario: ${DURATION}s"
echo "  Sample interval: ${SAMPLE_INTERVAL}s"
echo "============================================"
echo ""

# Run BICTR scenario (channel on both gNB and UE)
run_scenario "bictr" \
  "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf" \
  "$CONF_DIR/ue.bictr.conf"

# Run AWGN control scenario (channel on both gNB and UE)
run_scenario "awgn" \
  "$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.awgn.conf" \
  "$CONF_DIR/ue.awgn.conf"

echo "=== Both scenarios complete ==="
echo "Results in: $RESULTS_DIR/${TIMESTAMP}_*"
echo ""
echo "Generate plots with:"
echo "  python3 $SCRIPT_DIR/plot_results.py $RESULTS_DIR/${TIMESTAMP}_bictr $RESULTS_DIR/${TIMESTAMP}_awgn"
