#!/usr/bin/env bash
#
# BICTR + RFSim phy-test: sweep MCS (-m/-t) and SNR (-s) on gNB/UE.
# Default grid matches Ahmed et al. Figure 7 SINR axis (14–26 dB, 2 dB steps)
# and MCS 9–28; configs are the lunar BICTR gNB/UE pair (not AWGN channelmod).
#
# Each point writes results under bictr_analysis/results/sweep_MCS_SNR_<timestamp>/mcs<M>_snr<S>/
# Metadata is written to .sweep_meta; each finished trial touches .trial_complete (see recover script).
#
# Usage (requires root):
#   sudo ./run_mcs_snr_sweep.sh
#   sudo ./run_mcs_snr_sweep.sh --duration 120 --mcs "9 15 21" --snr "10 20 30"
#
# Lists accept spaces or commas. Optional:
#   --gnb-conf PATH --ue-conf PATH   (default: usrpb210.bictr + ue.bictr)
#   --no-s-on-ue                     do not pass -s to nr-uesoftmodem
#   --trials N                       repeat each (MCS, SNR) cell N times (default: 1)
#   --target-tx N                    stop each trial after N new DL first-TX (optional).
#   --warmup SEC                     (default: 12; used with --target-tx)
#
# Resume an interrupted sweep (example: latest results tree):
#   sudo ./recover_mcs_snr_sweep.sh results/sweep_MCS_SNR_20260512_095140
#
# Post-process (from bictr_analysis/):
#   python3 plot_mcs_snr_curves.py results/sweep_MCS_SNR_20260512_095140 -o results/sweep_MCS_SNR_20260512_095140/curves
#   SW=$(ls -dt results/sweep_MCS_SNR_* | head -1); python3 plot_mcs_snr_curves.py "$SW" -o "$SW/curves"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"
RESULTS_DIR="$SCRIPT_DIR/results"

GNB_CONF="$CONF_DIR/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf"
UE_CONF="$CONF_DIR/ue.bictr.conf"
DURATION=60
SAMPLE_INTERVAL=1
MCS_LIST=""
SNR_LIST=""
UE_SN_OPT=1
NUM_TRIALS=1
TARGET_TX=""
WARMUP=12

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --samples) SAMPLE_INTERVAL="$2"; shift 2 ;;
    --gnb-conf) GNB_CONF="$2"; shift 2 ;;
    --ue-conf) UE_CONF="$2"; shift 2 ;;
    --mcs) MCS_LIST=$(echo "$2" | tr ',' ' '); shift 2 ;;
    --snr) SNR_LIST=$(echo "$2" | tr ',' ' '); shift 2 ;;
    --trials) NUM_TRIALS="$2"; shift 2 ;;
    --target-tx) TARGET_TX="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --no-s-on-ue) UE_SN_OPT=0; shift ;;
    -h|--help)
      head -35 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Defaults: full MCS 9–28 and SINR 14–26 dB (2 dB steps), Figure 7–style axis.
if [[ -z "$MCS_LIST" ]]; then
  MCS_LIST="9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28"
fi
if [[ -z "$SNR_LIST" ]]; then
  SNR_LIST="14 16 18 20 22 24 26"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run with sudo" >&2
  exit 1
fi
if [[ "$NUM_TRIALS" -lt 1 ]]; then
  echo "ERROR: --trials must be >= 1" >&2
  exit 1
fi
if [[ -n "$TARGET_TX" && "$TARGET_TX" -lt 1 ]]; then
  echo "ERROR: --target-tx must be >= 1 when set" >&2
  exit 1
fi

# shellcheck source=mcs_snr_sweep_lib.sh
source "$SCRIPT_DIR/mcs_snr_sweep_lib.sh"

mkdir -p "$RESULTS_DIR"
TS=$(date +%Y%m%d_%H%M%S)
SWEEP_ROOT="$RESULTS_DIR/sweep_MCS_SNR_${TS}"
mkdir -p "$SWEEP_ROOT"
write_sweep_meta

N_MCS=$(echo "$MCS_LIST" | wc -w)
N_SNR=$(echo "$SNR_LIST" | wc -w)
N_CELLS=$((N_MCS * N_SNR))
N_RUNS=$((N_CELLS * NUM_TRIALS))
echo "======================================================="
echo "  MCS × SNR sweep (BICTR + phy-test)"
echo "  gNB: $GNB_CONF"
echo "  UE:  $UE_CONF"
echo "  MCS ($N_MCS): $MCS_LIST"
echo "  SNR dB ($N_SNR): $SNR_LIST"
echo "  Trials/cell:   $NUM_TRIALS"
if [[ -n "$TARGET_TX" ]]; then
  echo "  Stop rule:     ${TARGET_TX} DL first-TX/trial (max ${DURATION}s), warmup ${WARMUP}s"
else
  echo "  Duration/trial: ${DURATION}s, sample every ${SAMPLE_INTERVAL}s"
fi
echo "  Total runs:    $N_RUNS  ($N_CELLS cells × $NUM_TRIALS trials)"
echo "  Output:        $SWEEP_ROOT"
echo "  Resume later:  sudo $SCRIPT_DIR/recover_mcs_snr_sweep.sh $SWEEP_ROOT"
echo "======================================================="
echo ""

trap 'echo ""; echo "Interrupted — cleaning up..."; cleanup_procs 2>/dev/null; exit 130' INT TERM

for MCS in $MCS_LIST; do
  for SNR in $SNR_LIST; do
    for ((T=1; T<=NUM_TRIALS; T++)); do
      run_one_trial "$MCS" "$SNR" "$T"
    done
  done
done

if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$SWEEP_ROOT"
fi

echo ""
echo "=== Sweep complete ==="
echo "Plot SNR curves as your user not root, for example:"
echo "  python3 $SCRIPT_DIR/plot_mcs_snr_curves.py $SWEEP_ROOT -o $SWEEP_ROOT/curves"
echo "BLER vs cumulative TX for one trial, for example:"
echo "  python3 $SCRIPT_DIR/plot_bler_vs_tx.py $SWEEP_ROOT/mcs9_snr20/trial_01 -o $SWEEP_ROOT/curves/tx_one_run"
