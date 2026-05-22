#!/usr/bin/env bash
#
# Resume a partial MCS×SNR sweep: skip trials that already finished (.trial_complete
# or legacy markers), re-run only missing trials using parameters from .sweep_meta.
#
# Usage (requires root), e.g. resume latest sweep with results:
#   sudo ./recover_mcs_snr_sweep.sh results/sweep_MCS_SNR_20260512_095140
#
# Or newest sweep directory:
#   sudo ./recover_mcs_snr_sweep.sh "$(ls -dt results/sweep_MCS_SNR_* | head -1)"
#
# If .sweep_meta is missing (older runs), the script infers MCS/SNR/trial count from
# directory names. Legacy target-tx sweeps (trial_*/start_stats.txt) default to
# --target-tx 1000 --duration 600 unless you pass different --target-tx / --duration.
#
# Optional overrides (apply on top of .sweep_meta when you need to tweak):
#   --target-tx N  --duration SEC  --trials N  --warmup SEC
#   --gnb-conf PATH  --ue-conf PATH  --no-s-on-ue
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OAI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$OAI_DIR/cmake_targets/ran_build/build"
CONF_DIR="$OAI_DIR/targets/PROJECTS/GENERIC-NR-5GC/CONF"

SWEEP_ROOT=""
FROM_META=0
NEED_TARGET_TX_HINT=0
O_DURATION="" O_WARMUP="" O_TRIALS="" O_TARGET_TX="" O_GNB_CONF="" O_UE_CONF=""
O_UE_SN_OPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) O_DURATION="$2"; shift 2 ;;
    --warmup) O_WARMUP="$2"; shift 2 ;;
    --trials) O_TRIALS="$2"; shift 2 ;;
    --target-tx) O_TARGET_TX="$2"; shift 2 ;;
    --gnb-conf) O_GNB_CONF="$2"; shift 2 ;;
    --ue-conf) O_UE_CONF="$2"; shift 2 ;;
    --no-s-on-ue) O_UE_SN_OPT=0; shift ;;
    -h|--help)
      head -28 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1 ;;
    *)
      if [[ -z "$SWEEP_ROOT" ]]; then
        SWEEP_ROOT="$(cd "$1" && pwd)"
      else
        echo "ERROR: unexpected extra argument: $1" >&2
        exit 1
      fi
      shift ;;
  esac
done

if [[ -z "${SWEEP_ROOT:-}" ]]; then
  echo "Usage: sudo $0 results/sweep_MCS_SNR_20260512_095140 [options]" >&2
  echo "   or: sudo $0 \"\$(ls -dt results/sweep_MCS_SNR_* | head -1)\" [options]" >&2
  exit 1
fi
if [[ ! -d "$SWEEP_ROOT" ]]; then
  echo "ERROR: not a directory: $SWEEP_ROOT" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run with sudo" >&2
  exit 1
fi

# shellcheck source=mcs_snr_sweep_lib.sh
source "$SCRIPT_DIR/mcs_snr_sweep_lib.sh"

if load_sweep_meta; then
  FROM_META=1
  echo "Loaded parameters from $SWEEP_ROOT/.sweep_meta"
else
  echo "No .sweep_meta — inferring MCS/SNR/trials from subdirectories (legacy sweep)"
  infer_sweep_from_dirs
fi

[[ -n "${O_DURATION:-}" ]] && DURATION="$O_DURATION"
[[ -n "${O_WARMUP:-}" ]] && WARMUP="$O_WARMUP"
[[ -n "${O_TRIALS:-}" ]] && NUM_TRIALS="$O_TRIALS"
[[ -n "${O_TARGET_TX:-}" ]] && TARGET_TX="$O_TARGET_TX"
[[ -n "${O_GNB_CONF:-}" ]] && GNB_CONF="$O_GNB_CONF"
[[ -n "${O_UE_CONF:-}" ]] && UE_CONF="$O_UE_CONF"
if [[ "${O_UE_SN_OPT:-}" == "0" ]]; then UE_SN_OPT=0; fi

if [[ "${FROM_META:-0}" -eq 0 && "${NEED_TARGET_TX_HINT:-0}" -eq 1 && -z "${TARGET_TX:-}" ]]; then
  TARGET_TX=1000
  DURATION="${DURATION:-600}"
  WARMUP="${WARMUP:-12}"
  echo "NOTE: Legacy target-tx sweep (start_stats.txt) and no .sweep_meta — using --target-tx ${TARGET_TX} --duration ${DURATION} --warmup ${WARMUP}. Pass flags to override." >&2
fi

echo "======================================================="
echo "  MCS × SNR sweep RECOVERY"
echo "  Root:       $SWEEP_ROOT"
echo "  gNB:        $GNB_CONF"
echo "  UE:         $UE_CONF"
echo "  MCS:        $MCS_LIST"
echo "  SNR:        $SNR_LIST"
echo "  Trials:     $NUM_TRIALS"
if [[ -n "${TARGET_TX:-}" ]]; then
  echo "  Target TX:  $TARGET_TX (timeout ${DURATION}s, warmup ${WARMUP}s)"
else
  echo "  Duration:   ${DURATION}s / trial, sample ${SAMPLE_INTERVAL}s"
fi
echo "======================================================="
echo ""

SKIPPED=0
RUN=0

trap 'echo ""; echo "Interrupted — cleaning up..."; cleanup_procs 2>/dev/null; exit 130' INT TERM

for MCS in $MCS_LIST; do
  for SNR in $SNR_LIST; do
    for ((T=1; T<=NUM_TRIALS; T++)); do
      TAG="mcs${MCS}_snr${SNR}"
      OUT=$(trial_out_dir "$TAG" "$T")
      if trial_dir_complete "$OUT"; then
        echo "SKIP (complete) $OUT"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      RUN=$((RUN + 1))
      run_one_trial "$MCS" "$SNR" "$T"
    done
  done
done

if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$SWEEP_ROOT"
fi

if [[ "${FROM_META:-0}" -eq 0 ]]; then
  write_sweep_meta
  echo "Wrote $SWEEP_ROOT/.sweep_meta (inferred + any CLI overrides) for future resumes."
fi

echo ""
echo "=== Recovery pass complete ==="
echo "  Skipped (already complete): $SKIPPED"
echo "  Executed this pass:         $RUN"
echo "Plot when ready:"
echo "  python3 $SCRIPT_DIR/plot_mcs_snr_curves.py $SWEEP_ROOT -o $SWEEP_ROOT/curves"
