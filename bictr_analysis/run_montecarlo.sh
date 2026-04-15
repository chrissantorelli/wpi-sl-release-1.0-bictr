#!/usr/bin/env bash
#
# Monte Carlo BLER-vs-noise sweep for BICTR and AWGN channels.
#
# Replicates the methodology of Ahmed et al. "An Open-Source 5G Sidelink
# Testbed" Figure 7: sweep noise levels across MCS values, measure BLER
# at each operating point, average over multiple trials.
#
# Usage:
#   sudo ./run_montecarlo.sh [OPTIONS]
#
# Options:
#   --mcs      Comma-separated MCS values          (default: 9-28)
#   --noise    Comma-separated noise_power_dB vals  (default: 6,4,...,-20)
#   --channels Comma-separated channel types        (default: BICTR_LUNAR)
#   --trials   Number of trials per point           (default: 5)
#   --duration Measurement window in seconds        (default: 30)
#   --warmup   Warmup before measurement in seconds (default: 12)
#   --early-stop N  Skip remaining trials if first N all saturated (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"
RESULTS_BASE="$SCRIPT_DIR/montecarlo_results"

MCS_VALUES=(9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28)
NOISE_DB_VALUES=(6 4 2 0 -2 -4 -6 -8 -10 -14 -20)
CHANNEL_TYPES=("BICTR_LUNAR")
NUM_TRIALS=25
RUN_DURATION=10
WARMUP=12
EARLY_STOP=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcs)      IFS=',' read -ra MCS_VALUES <<< "$2"; shift 2 ;;
    --noise)    IFS=',' read -ra NOISE_DB_VALUES <<< "$2"; shift 2 ;;
    --channels) IFS=',' read -ra CHANNEL_TYPES <<< "$2"; shift 2 ;;
    --trials)   NUM_TRIALS="$2"; shift 2 ;;
    --duration) RUN_DURATION="$2"; shift 2 ;;
    --warmup)   WARMUP="$2"; shift 2 ;;
    --early-stop) EARLY_STOP="$2"; shift 2 ;;
    -h|--help)
      head -20 "$0" | grep '^#' | sed 's/^# \?//'
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

TOTAL=$(( ${#CHANNEL_TYPES[@]} * ${#MCS_VALUES[@]} * ${#NOISE_DB_VALUES[@]} * NUM_TRIALS ))
RUN_NUM=0
FAIL_COUNT=0

echo "======================================================="
echo "  Monte Carlo BLER Sweep"
echo "  Channels:      ${CHANNEL_TYPES[*]}"
echo "  MCS values:    ${MCS_VALUES[*]}"
echo "  Noise dB:      ${NOISE_DB_VALUES[*]}"
echo "  Trials/point:  $NUM_TRIALS"
echo "  Per-trial:     ${WARMUP}s warmup + ${RUN_DURATION}s measurement"
echo "  Early-stop:    after $EARLY_STOP saturated/clean trials"
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

run_single_point() {
  local CHAN="$1" MCS="$2" NOISE_DB="$3" TRIAL="$4"
  RUN_NUM=$((RUN_NUM + 1))

  local TMPDIR
  TMPDIR=$(mktemp -d /tmp/mc_oai.XXXXXX)
  local GNB_CONF="$TMPDIR/gnb.conf"
  local UE_CONF="$TMPDIR/ue.conf"

  if [[ "$CHAN" == "BICTR_LUNAR" ]]; then
    cp "$GNB_BICTR_TMPL" "$GNB_CONF"
    cp "$UE_BICTR_TMPL"  "$UE_CONF"
  else
    cp "$GNB_AWGN_TMPL"  "$GNB_CONF"
    cp "$UE_AWGN_TMPL"   "$UE_CONF"
  fi

  sed -i "s/noise_power_dB\s*=\s*-\?[0-9]\+/noise_power_dB  = $NOISE_DB/g" "$GNB_CONF"
  sed -i "s/noise_power_dB\s*=\s*-\?[0-9]\+/noise_power_dB  = $NOISE_DB/g" "$UE_CONF"

  printf "[%d/%d] %-12s MCS=%-3d noise=%-4d trial=%d ... " \
    "$RUN_NUM" "$TOTAL" "$CHAN" "$MCS" "$NOISE_DB" "$TRIAL"

  rm -f "$BUILD_DIR/nrMAC_stats.log"

  cd "$BUILD_DIR"
  ./nr-softmodem \
    -O "$GNB_CONF" \
    --rfsim --phy-test --noS1 \
    "--rfsimulator.[0].serveraddr" "server" \
    --gNBs.[0].min_rxtxtime 6 \
    --MCS "$MCS" \
    > "$TMPDIR/gnb.log" 2>&1 &
  GNB_PID=$!

  sleep 5

  ./nr-uesoftmodem \
    -O "$UE_CONF" \
    -r 106 --numerology 1 --band 78 -C 3619200000 \
    --rfsim --phy-test --noS1 \
    > "$TMPDIR/ue.log" 2>&1 &
  UE_PID=$!

  sleep "$WARMUP"

  if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
    cp "$BUILD_DIR/nrMAC_stats.log" "$TMPDIR/start_stats.txt"
  else
    echo "" > "$TMPDIR/start_stats.txt"
  fi

  sleep "$RUN_DURATION"

  if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
    cp "$BUILD_DIR/nrMAC_stats.log" "$TMPDIR/end_stats.txt"
  else
    echo "" > "$TMPDIR/end_stats.txt"
  fi

  cleanup_procs

  local RESULT
  RESULT=$(python3 "$SCRIPT_DIR/parse_montecarlo_point.py" \
    "$TMPDIR/start_stats.txt" "$TMPDIR/end_stats.txt" 2>/dev/null) || RESULT="0,0,0.0,0/0/0/0,0,0,0.0"

  echo "$CHAN,$MCS,$NOISE_DB,$TRIAL,$RESULT" >> "$CSV"

  DL_BLER_VAL=$(echo "$RESULT" | cut -d',' -f3)
  UL_BLER_VAL=$(echo "$RESULT" | cut -d',' -f7)
  echo "DL_BLER=$DL_BLER_VAL  UL_BLER=$UL_BLER_VAL"

  rm -rf "$TMPDIR"
}

trap 'echo ""; echo "Interrupted — cleaning up..."; cleanup_procs 2>/dev/null; exit 130' INT TERM

SKIPPED=0

for CHAN in "${CHANNEL_TYPES[@]}"; do
  echo ""
  echo "--- Channel: $CHAN ---"
  for MCS in "${MCS_VALUES[@]}"; do
    for NOISE_DB in "${NOISE_DB_VALUES[@]}"; do
      CONSEC_SAT=0   # consecutive trials with BLER >= 0.99
      CONSEC_CLEAN=0 # consecutive trials with BLER <= 0.001
      POINT_SKIP=0

      for ((TRIAL=1; TRIAL<=NUM_TRIALS; TRIAL++)); do
        if [[ "$POINT_SKIP" -eq 1 ]]; then
          RUN_NUM=$((RUN_NUM + 1))
          SKIPPED=$((SKIPPED + 1))
          printf "[%d/%d] %-12s MCS=%-3d noise=%-4d trial=%d ... SKIPPED (early-stop)\n" \
            "$RUN_NUM" "$TOTAL" "$CHAN" "$MCS" "$NOISE_DB" "$TRIAL"
          continue
        fi

        run_single_point "$CHAN" "$MCS" "$NOISE_DB" "$TRIAL" || {
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
