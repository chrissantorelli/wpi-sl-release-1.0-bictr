#!/usr/bin/env bash
#
# Quick single-MCS BLER curve using the BICTR lunar channel model (same as
# run_montecarlo.sh --channels BICTR_LUNAR: gnb/ue *.bictr.conf, sweep
# channelmod noise_power_dB). For AWGN phy-test SINR sweeps, call
# run_montecarlo.sh directly with --channels AWGN --snr ...
#
# Usage:
#   sudo ./run_montecarlo_single_mcs.sh [MCS] [-- extra run_montecarlo.sh args]
#
# Examples:
#   sudo ./run_montecarlo_single_mcs.sh 16
#   sudo ./run_montecarlo_single_mcs.sh 22 --trials 50 --target-tx 100
#   QUICK_NOISE="2,0,-2,-4" sudo ./run_montecarlo_single_mcs.sh 16   # fewer noise points
#
# Environment (optional):
#   QUICK_TRIALS     trials per (MCS, noise) point (default: 35)
#   QUICK_TARGET_TX  DL first-TX stop target per trial (default: 80)
#   QUICK_NOISE      comma-separated channelmod noise_power_dB values
#                    (default: 6,4,2,0,-2,-4,-6 — subset of run_montecarlo defaults)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root, e.g.  sudo $0 [MCS]" >&2
  exit 1
fi

MCS="${1:-16}"
shift || true

: "${QUICK_TRIALS:=35}"
: "${QUICK_TARGET_TX:=80}"
: "${QUICK_NOISE:=6,4,2,0,-2,-4,-6}"

echo "======================================================="
echo "  Single-MCS Monte Carlo (BICTR_LUNAR quick curve)"
echo "  MCS=$MCS  noise_power_dB points: $QUICK_NOISE"
echo "  trials=$QUICK_TRIALS  target-tx=$QUICK_TARGET_TX"
echo "  Config templates: gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf, ue.bictr.conf"
echo "  (override QUICK_* or pass extra flags accepted by run_montecarlo.sh)"
echo "======================================================="
echo ""
echo "After the run, plot one curve:"
echo "  python3 $SCRIPT_DIR/plot_montecarlo.py <RUN_DIR>/montecarlo_results.csv"
echo ""

exec "$SCRIPT_DIR/run_montecarlo.sh" \
  --mcs "$MCS" \
  --channels BICTR_LUNAR \
  --noise "$QUICK_NOISE" \
  --trials "$QUICK_TRIALS" \
  --target-tx "$QUICK_TARGET_TX" \
  "$@"
