#!/usr/bin/env bash
#
# Monte Carlo BLER sweep — defaults to BICTR lunar channel only (bictr configs +
# channelmod noise_power_dB sweep). Legacy AWGN phy-test sweep is optional.
#
# BICTR: templates gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf, ue.bictr.conf.
# Sweep axis: --noise (channelmod noise_power_dB).
#
# Optional AWGN (--channels AWGN): phy-test -s SNR only for comparison / Figure 7
# Ahmed et al. sidelink paper style (not comparable to BICTR curves).
# For BICTR + phy-test MCS×SNR grids with per-cell time-series, use run_mcs_snr_sweep.sh.
#
# Usage:
#   sudo ./run_montecarlo.sh [OPTIONS]
#
# Quick single-MCS curve (BICTR):
#     sudo ./run_montecarlo_single_mcs.sh 16
#
# Optional AWGN phy-test sweep (explicit only):
#     sudo ./run_montecarlo.sh --channels AWGN --snr 14,16,18 --mcs 16 --trials 35 --target-tx 80
#
# Options:
#   --mcs      Comma-separated MCS values           (default: 9-28)
#   --noise    Comma-separated channelmod noise_power_dB — BICTR_LUNAR (default list below)
#   --snr      Comma-separated phy-test SINR (dB)   — only with --channels AWGN
#   --channels Channel types (default: BICTR_LUNAR). Use AWGN only if you intend phy-test AWGN.
#   --trials   Number of trials per point           (default: 100)
#   --target-tx Stop trial after this many DL first-TX packets (default: 100)
#   --duration Max measurement seconds fallback      (default: 120)
#   --warmup   Warmup before measurement in seconds  (default: 12)
#   --early-stop N  Skip remaining trials if first N all saturated (default: 0 = off)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"
RESULTS_BASE="$SCRIPT_DIR/montecarlo_results"

MCS_VALUES=(9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28)
# AWGN (--channels AWGN) only: phy-test -s sweep.
SNR_DB_VALUES=(14 16 18 20 22 24 26)
# BICTR_LUNAR: channelmod noise_power_dB values written into bictr ue/gnb conf copies.
NOISE_DB_VALUES=(6 4 2 0 -2 -4 -6 -8 -10 -14 -20)
CHANNEL_TYPES=("BICTR_LUNAR")
NUM_TRIALS=100
TARGET_TX=100
RUN_DURATION=120
WARMUP=12
EARLY_STOP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcs)      IFS=',' read -ra MCS_VALUES <<< "$2"; shift 2 ;;
    --snr)      IFS=',' read -ra SNR_DB_VALUES <<< "$2"; shift 2 ;;
    --noise)    IFS=',' read -ra NOISE_DB_VALUES <<< "$2"; shift 2 ;;
    --channels) IFS=',' read -ra CHANNEL_TYPES <<< "$2"; shift 2 ;;
    --trials)   NUM_TRIALS="$2"; shift 2 ;;
    --target-tx) TARGET_TX="$2"; shift 2 ;;
    --duration) RUN_DURATION="$2"; shift 2 ;;
    --warmup)   WARMUP="$2"; shift 2 ;;
    --early-stop) EARLY_STOP="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,31p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$RESULTS_BASE/$TIMESTAMP"
mkdir -p "$RUN_DIR"
CSV="$RUN_DIR/montecarlo_results.csv"
LOGFILE="$RUN_DIR/run.log"

echo "channel_type,mcs,noise_power_dB,trial,dl_first_tx,dl_errors,dl_bler,dl_harq,ul_first_tx,ul_errors,ul_bler" > "$CSV"

GNB_BICTR_TMPL="$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf"
GNB_AWGN_TMPL="$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.awgn.conf"
UE_BICTR_TMPL="$CONF_DIR/ue.bictr.conf"
UE_AWGN_TMPL="$CONF_DIR/ue.awgn.conf"

TOTAL=0
for CHAN in "${CHANNEL_TYPES[@]}"; do
  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    TOTAL=$((TOTAL + ${#MCS_VALUES[@]} * ${#NOISE_DB_VALUES[@]} * NUM_TRIALS))
  else
    TOTAL=$((TOTAL + ${#MCS_VALUES[@]} * ${#SNR_DB_VALUES[@]} * NUM_TRIALS))
  fi
done
RUN_NUM=0
FAIL_COUNT=0

HAS_BICTR=0 HAS_AWGN=0
for _c in "${CHANNEL_TYPES[@]}"; do
  if [[ "$_c" == "BICTR_LUNAR" ]]; then HAS_BICTR=1; else HAS_AWGN=1; fi
done

echo "======================================================="
echo "  Monte Carlo BLER Sweep"
echo "  Channels:      ${CHANNEL_TYPES[*]}"
echo "  MCS values:    ${MCS_VALUES[*]}"
if [[ "$HAS_BICTR" -eq 1 ]]; then
echo "  BICTR noise_power_dB: ${NOISE_DB_VALUES[*]}  (channelmod; CSV column noise_power_dB)"
fi
if [[ "$HAS_AWGN" -eq 1 ]]; then
echo "  AWGN phy-test -s dB:    ${SNR_DB_VALUES[*]}  (stored in CSV as noise_power_dB)"
fi
echo "  Trials/point:  $NUM_TRIALS"
echo "  Per-trial:     ${WARMUP}s warmup + up to ${RUN_DURATION}s measurement"
echo "  Target DL TX:  $TARGET_TX first transmissions per trial"
if [[ "$EARLY_STOP" -gt 0 ]]; then
  echo "  Early-stop:    after $EARLY_STOP saturated/clean trials"
else
  echo "  Early-stop:    disabled"
fi
echo "  Total runs:    $TOTAL (max, before early-stop)"
echo "  Est. time:     $(( TOTAL * (WARMUP + RUN_DURATION + 12) / 60 )) min (max)"
echo "  Output:        $RUN_DIR"
echo "======================================================="
echo ""

cleanup_procs() {
  kill "$UE_PID" 2>/dev/null || true
  sleep 1
  kill "$GNB_PID" 2>/dev/null || true
  wait "$UE_PID" 2>/dev/null || true
  wait "$GNB_PID" 2>/dev/null || true
  sleep 1
}

extract_dl_first_tx() {
  local STATS_FILE="$1"
  python3 - "$STATS_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    text = open(path).read()
except Exception:
    print(0)
    raise SystemExit(0)

m = re.search(r'dlsch_rounds\s+([\d/]+)', text)
if not m:
    print(0)
    raise SystemExit(0)

parts = m.group(1).split('/')
print(int(parts[0]) if parts and parts[0].isdigit() else 0)
PY
}

run_single_point() {
  local CHAN="$1" MCS="$2" SWEEP_DB="$3" TRIAL="$4"
  RUN_NUM=$((RUN_NUM + 1))

  local TMPDIR
  TMPDIR=$(mktemp -d /tmp/mc_oai.XXXXXX)
  local GNB_CONF="$TMPDIR/gnb.conf"
  local UE_CONF="$TMPDIR/ue.conf"

  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    cp "$GNB_BICTR_TMPL" "$GNB_CONF"
    cp "$UE_BICTR_TMPL"  "$UE_CONF"
    sed -i "s/noise_power_dB\s*=\s*-\?[0-9]\+/noise_power_dB  = $SWEEP_DB/g" "$GNB_CONF"
    sed -i "s/noise_power_dB\s*=\s*-\?[0-9]\+/noise_power_dB  = $SWEEP_DB/g" "$UE_CONF"
  else
    cp "$GNB_AWGN_TMPL"  "$GNB_CONF"
    cp "$UE_AWGN_TMPL"   "$UE_CONF"
  fi

  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    printf "[%d/%d] %-12s MCS=%-3d noise_power_dB=%-4s trial=%d ... " \
      "$RUN_NUM" "$TOTAL" "$CHAN" "$MCS" "$SWEEP_DB" "$TRIAL"
  else
    printf "[%d/%d] %-12s MCS=%-3d SINR=%-4s trial=%d ... " \
      "$RUN_NUM" "$TOTAL" "$CHAN" "$MCS" "$SWEEP_DB" "$TRIAL"
  fi

  rm -f "$BUILD_DIR/nrMAC_stats.log"

  cd "$BUILD_DIR"
  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    ./nr-softmodem \
      -O "$GNB_CONF" \
      --rfsim --phy-test --noS1 \
      "--rfsimulator.[0].serveraddr" "server" \
      --gNBs.[0].min_rxtxtime 6 \
      --MCS "$MCS" \
      > "$TMPDIR/gnb.log" 2>&1 &
    GNB_PID=$!
  else
    ./nr-softmodem \
      -O "$GNB_CONF" \
      --rfsim --phy-test --noS1 \
      "--rfsimulator.[0].serveraddr" "server" \
      --gNBs.[0].min_rxtxtime 6 \
      -m "$MCS" -t "$MCS" -s "$SWEEP_DB" \
      > "$TMPDIR/gnb.log" 2>&1 &
    GNB_PID=$!
  fi

  sleep 5

  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    ./nr-uesoftmodem \
      -O "$UE_CONF" \
      -r 106 --numerology 1 --band 78 -C 3619200000 \
      --rfsim --phy-test --noS1 \
      > "$TMPDIR/ue.log" 2>&1 &
    UE_PID=$!
  else
    ./nr-uesoftmodem \
      -O "$UE_CONF" \
      -r 106 --numerology 1 --band 78 -C 3619200000 \
      --rfsim --phy-test --noS1 \
      -s "$SWEEP_DB" \
      > "$TMPDIR/ue.log" 2>&1 &
    UE_PID=$!
  fi

  echo "started (warmup ${WARMUP}s, target DL TX ${TARGET_TX}, timeout ${RUN_DURATION}s)"
  sleep "$WARMUP"

  if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
    cp "$BUILD_DIR/nrMAC_stats.log" "$TMPDIR/start_stats.txt"
  else
    echo "" > "$TMPDIR/start_stats.txt"
  fi

  local START_DL_TX=0
  START_DL_TX=$(extract_dl_first_tx "$TMPDIR/start_stats.txt")

  local ELAPSED=0
  local TARGET_REACHED=0
  while [[ $ELAPSED -lt $RUN_DURATION ]]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))

    if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
      local CUR_DL_TX=0
      CUR_DL_TX=$(extract_dl_first_tx "$BUILD_DIR/nrMAC_stats.log")
      local DELTA_DL_TX=$((CUR_DL_TX - START_DL_TX))
      if (( ELAPSED % 10 == 0 )); then
        echo "    progress: ${ELAPSED}s, DL_first_tx=${DELTA_DL_TX}/${TARGET_TX}"
      fi
      if [[ $DELTA_DL_TX -ge $TARGET_TX ]]; then
        TARGET_REACHED=1
        break
      fi
    else
      if (( ELAPSED % 10 == 0 )); then
        echo "    progress: ${ELAPSED}s, waiting for nrMAC_stats.log"
      fi
    fi
  done

  if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
    cp "$BUILD_DIR/nrMAC_stats.log" "$TMPDIR/end_stats.txt"
  else
    echo "" > "$TMPDIR/end_stats.txt"
  fi

  cleanup_procs

  local RESULT
  RESULT=$(python3 "$SCRIPT_DIR/parse_montecarlo_point.py" \
    "$TMPDIR/start_stats.txt" "$TMPDIR/end_stats.txt" 2>/dev/null) || RESULT="0,0,0.0,0/0/0/0,0,0,0.0"

  echo "$CHAN,$MCS,$SWEEP_DB,$TRIAL,$RESULT" >> "$CSV"

  DL_BLER_VAL=$(echo "$RESULT" | cut -d',' -f3)
  UL_BLER_VAL=$(echo "$RESULT" | cut -d',' -f7)
  local MEAS_DL_TX
  MEAS_DL_TX=$(echo "$RESULT" | cut -d',' -f1)
  if [[ "$TARGET_REACHED" -eq 1 ]]; then
    echo "DL_BLER=$DL_BLER_VAL  UL_BLER=$UL_BLER_VAL  DL_first_tx=$MEAS_DL_TX (target reached in ${ELAPSED}s)"
  else
    echo "DL_BLER=$DL_BLER_VAL  UL_BLER=$UL_BLER_VAL  DL_first_tx=$MEAS_DL_TX (timeout at ${ELAPSED}s before target)"
  fi

  rm -rf "$TMPDIR"
}

trap 'echo ""; echo "Interrupted — cleaning up..."; cleanup_procs 2>/dev/null; exit 130' INT TERM

SKIPPED=0

for CHAN in "${CHANNEL_TYPES[@]}"; do
  echo ""
  echo "--- Channel: $CHAN ---"
  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    SWEEP_VALUES=("${NOISE_DB_VALUES[@]}")
  else
    SWEEP_VALUES=("${SNR_DB_VALUES[@]}")
  fi
  for MCS in "${MCS_VALUES[@]}"; do
    for SWEEP_DB in "${SWEEP_VALUES[@]}"; do
      CONSEC_SAT=0   # consecutive trials with BLER >= 0.99
      CONSEC_CLEAN=0 # consecutive trials with BLER <= 0.001
      POINT_SKIP=0

      for ((TRIAL=1; TRIAL<=NUM_TRIALS; TRIAL++)); do
        if [[ "$POINT_SKIP" -eq 1 ]]; then
          RUN_NUM=$((RUN_NUM + 1))
          SKIPPED=$((SKIPPED + 1))
          printf "[%d/%d] %-12s MCS=%-3d sweep=%-4s trial=%d ... SKIPPED (early-stop)\n" \
            "$RUN_NUM" "$TOTAL" "$CHAN" "$MCS" "$SWEEP_DB" "$TRIAL"
          continue
        fi

        run_single_point "$CHAN" "$MCS" "$SWEEP_DB" "$TRIAL" || {
          echo "FAILED"
          FAIL_COUNT=$((FAIL_COUNT + 1))
        }

        if (( EARLY_STOP > 0 && TRIAL <= EARLY_STOP )); then
          SAT=$(python3 -c "print(1 if float('${DL_BLER_VAL}') >= 0.99 else 0)" 2>/dev/null || echo 0)
          CLN=$(python3 -c "print(1 if float('${DL_BLER_VAL}') <= 0.001 else 0)" 2>/dev/null || echo 0)
          if [[ "$SAT" == "1" ]]; then
            CONSEC_SAT=$((CONSEC_SAT + 1))
          else
            CONSEC_SAT=0
          fi
          if [[ "$CLN" == "1" ]]; then
            CONSEC_CLEAN=$((CONSEC_CLEAN + 1))
          else
            CONSEC_CLEAN=0
          fi
          if [[ "$TRIAL" -eq "$EARLY_STOP" ]]; then
            if [[ "$CONSEC_SAT" -ge "$EARLY_STOP" ]]; then
              echo "    >> Early-stop: $EARLY_STOP consecutive trials saturated (BLER>=0.99)"
              POINT_SKIP=1
            elif [[ "$CONSEC_CLEAN" -ge "$EARLY_STOP" ]]; then
              echo "    >> Early-stop: $EARLY_STOP consecutive trials clean (BLER<=0.001)"
              POINT_SKIP=1
            fi
          fi
        fi
      done
    done
  done
done

echo ""
echo "======================================================="
echo "  Monte Carlo sweep complete"
echo "  Executed:   $((RUN_NUM - SKIPPED)) / $RUN_NUM  ($SKIPPED skipped by early-stop)"
echo "  Results:    $CSV"
echo "======================================================="
echo ""
echo "Generate plots with:"
echo "  python3 $SCRIPT_DIR/plot_montecarlo.py $CSV"
