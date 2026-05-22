# Shared helpers for run_mcs_snr_sweep.sh and recover_mcs_snr_sweep.sh
# Required globals: BUILD_DIR GNB_CONF UE_CONF SWEEP_ROOT NUM_TRIALS TARGET_TX
#   DURATION WARMUP SAMPLE_INTERVAL UE_SN_OPT
# Optional: GNB_PID UE_PID (used by cleanup_procs)

write_sweep_meta() {
  local f="$SWEEP_ROOT/.sweep_meta"
  {
    echo "SWEEP_META_VERSION=1"
    echo "NUM_TRIALS=$NUM_TRIALS"
    echo "TARGET_TX=${TARGET_TX:-}"
    echo "DURATION=$DURATION"
    echo "WARMUP=$WARMUP"
    echo "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
    echo "UE_SN_OPT=$UE_SN_OPT"
    echo "GNB_CONF=$GNB_CONF"
    echo "UE_CONF=$UE_CONF"
    echo "MCS_CSV=$(echo "$MCS_LIST" | tr ' ' ',')"
    echo "SNR_CSV=$(echo "$SNR_LIST" | tr ' ' ',')"
  } > "$f"
}

load_sweep_meta() {
  local f="$SWEEP_ROOT/.sweep_meta"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local k v
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      SWEEP_META_VERSION) SWEEP_META_VERSION="$v" ;;
      NUM_TRIALS) NUM_TRIALS="$v" ;;
      TARGET_TX) TARGET_TX="$v" ;;
      DURATION) DURATION="$v" ;;
      WARMUP) WARMUP="$v" ;;
      SAMPLE_INTERVAL) SAMPLE_INTERVAL="$v" ;;
      UE_SN_OPT) UE_SN_OPT="$v" ;;
      GNB_CONF) GNB_CONF="$v" ;;
      UE_CONF) UE_CONF="$v" ;;
      MCS_CSV) MCS_CSV="$v" ;;
      SNR_CSV) SNR_CSV="$v" ;;
    esac
  done < "$f"
  MCS_LIST=$(echo "$MCS_CSV" | tr ',' ' ')
  SNR_LIST=$(echo "$SNR_CSV" | tr ',' ' ')
  return 0
}

infer_sweep_from_dirs() {
  MCS_LIST=""
  SNR_LIST=""
  local d
  for d in "$SWEEP_ROOT"/mcs*_snr*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" =~ ^mcs([0-9]+)_snr(-?[0-9.]+)$ ]] || continue
    MCS_LIST+=" ${BASH_REMATCH[1]}"
    SNR_LIST+=" ${BASH_REMATCH[2]}"
  done
  MCS_LIST=$(echo "$MCS_LIST" | tr ' ' '\n' | sed '/^$/d' | sort -nu | tr '\n' ' ')
  SNR_LIST=$(echo "$SNR_LIST" | tr ' ' '\n' | sed '/^$/d' | sort -g | tr '\n' ' ')

  NUM_TRIALS=1
  local any_trial=0 global_max=0
  for d in "$SWEEP_ROOT"/mcs*_snr*; do
    [[ -d "$d" ]] || continue
    local cell_max=0
    local found=0
    for tdir in "$d"/trial_*; do
      [[ -d "$tdir" ]] || continue
      found=1
      [[ "$(basename "$tdir")" =~ ^trial_0*([0-9]+)$ ]] || continue
      local n="${BASH_REMATCH[1]}"
      any_trial=1
      if [[ "$n" -gt "$cell_max" ]]; then cell_max=$n; fi
    done
    if [[ "$found" -eq 1 && "$cell_max" -gt "$global_max" ]]; then global_max=$cell_max; fi
  done
  if [[ "$any_trial" -eq 1 ]]; then
    NUM_TRIALS=$global_max
  else
    NUM_TRIALS=1
  fi
  if [[ "$NUM_TRIALS" -lt 1 ]]; then NUM_TRIALS=1; fi

  NEED_TARGET_TX_HINT=0
  for d in "$SWEEP_ROOT"/mcs*_snr*/trial_*; do
    if [[ -f "$d/start_stats.txt" ]]; then
      NEED_TARGET_TX_HINT=1
      break
    fi
  done

  DURATION="${DURATION:-600}"
  WARMUP="${WARMUP:-12}"
  SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
  UE_SN_OPT="${UE_SN_OPT:-1}"
  GNB_CONF="${GNB_CONF:-$SCRIPT_DIR/../targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb.sa.band78.fr1.106PRB.usrpb210.bictr.conf}"
  UE_CONF="${UE_CONF:-$SCRIPT_DIR/../targets/PROJECTS/GENERIC-NR-5GC/CONF/ue.bictr.conf}"
}

trial_dir_complete() {
  local outdir="$1"
  [[ -f "$outdir/.trial_complete" ]] && return 0
  # Legacy sweeps (before .trial_complete): plausible finished trial
  if [[ -f "$outdir/stats_timeseries.csv" ]] && [[ -f "$outdir/nrMAC_stats_final.log" ]]; then
    local n
    n=$(wc -l < "$outdir/stats_timeseries.csv")
    [[ "$n" -ge 2 ]] && return 0
  fi
  return 1
}

cleanup_procs() {
  kill "${UE_PID:-}" 2>/dev/null || true
  sleep 1
  kill "${GNB_PID:-}" 2>/dev/null || true
  wait "${UE_PID:-}" 2>/dev/null || true
  wait "${GNB_PID:-}" 2>/dev/null || true
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

trial_out_dir() {
  local TAG="$1"
  local TRIAL_IDX="$2"
  if [[ "$NUM_TRIALS" -eq 1 && -z "$TARGET_TX" ]]; then
    echo "$SWEEP_ROOT/$TAG"
  else
    printf '%s/%s/trial_%02d' "$SWEEP_ROOT" "$TAG" "$TRIAL_IDX"
  fi
}

run_one_trial() {
  local MCS="$1"
  local SNR="$2"
  local TRIAL_IDX="$3"
  local TAG="mcs${MCS}_snr${SNR}"
  local OUT
  OUT=$(trial_out_dir "$TAG" "$TRIAL_IDX")
  mkdir -p "$OUT"

  if [[ "$NUM_TRIALS" -eq 1 && -z "$TARGET_TX" ]]; then
    echo "=== $TAG  (duration ${DURATION}s, sample every ${SAMPLE_INTERVAL}s) ==="
  else
    echo "=== $TAG  trial ${TRIAL_IDX}/${NUM_TRIALS} ==="
  fi

  rm -f "$BUILD_DIR/nrMAC_stats.log"
  cd "$BUILD_DIR"

  ./nr-softmodem \
    -O "$GNB_CONF" \
    --rfsim --phy-test --noS1 \
    "--rfsimulator.[0].serveraddr" "server" \
    --gNBs.[0].min_rxtxtime 6 \
    -m "$MCS" -t "$MCS" -s "$SNR" \
    > "$OUT/gnb.log" 2>&1 &
  GNB_PID=$!
  sleep 5

  local UE_EXTRA=()
  if [[ "$UE_SN_OPT" -eq 1 ]]; then
    UE_EXTRA=(-s "$SNR")
  fi

  ./nr-uesoftmodem \
    -O "$UE_CONF" \
    -r 106 --numerology 1 --band 78 -C 3619200000 \
    --rfsim --phy-test --noS1 \
    "${UE_EXTRA[@]}" \
    > "$OUT/ue.log" 2>&1 &
  UE_PID=$!

  if [[ -n "$TARGET_TX" ]]; then
    echo "    target ${TARGET_TX} DL first-TX, warmup ${WARMUP}s, timeout ${DURATION}s"
    sleep 2
    if ! kill -0 "$UE_PID" 2>/dev/null; then
      echo "    WARNING: nr-uesoftmodem exited during startup (see $OUT/ue.log)" >&2
      tail -n 25 "$OUT/ue.log" >&2 || true
    fi
    sleep "$WARMUP"
    if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
      cp "$BUILD_DIR/nrMAC_stats.log" "$OUT/start_stats.txt"
    else
      echo "" > "$OUT/start_stats.txt"
    fi
    local START_DL_TX
    START_DL_TX=$(extract_dl_first_tx "$OUT/start_stats.txt")
    echo "sample_id,elapsed_s,raw_stats" > "$OUT/stats_timeseries.csv"
    local ELAPSED=0 SAMPLE_COUNT=0 TARGET_REACHED=0
    while [[ $ELAPSED -lt $DURATION ]]; do
      sleep 1
      ELAPSED=$((ELAPSED + 1))
      if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
        STATS_LINE=$(cat "$BUILD_DIR/nrMAC_stats.log" 2>/dev/null | tr '\n' '|')
        echo "${SAMPLE_COUNT},${ELAPSED},${STATS_LINE}" >> "$OUT/stats_timeseries.csv"
        SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
        local CUR_DL_TX
        CUR_DL_TX=$(extract_dl_first_tx "$BUILD_DIR/nrMAC_stats.log")
        local DELTA_DL_TX=$((CUR_DL_TX - START_DL_TX))
        if [[ $DELTA_DL_TX -ge $TARGET_TX ]]; then
          TARGET_REACHED=1
          break
        fi
      fi
      if (( ELAPSED % 30 == 0 )); then
        _hb_delta=0
        if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
          _hb_cur=$(extract_dl_first_tx "$BUILD_DIR/nrMAC_stats.log")
          _hb_delta=$((_hb_cur - START_DL_TX))
        fi
        if kill -0 "$UE_PID" 2>/dev/null; then
          echo "    ... ${ELAPSED}s / ${DURATION}s  DL_first_tx=${_hb_delta}/${TARGET_TX}  (UE alive)"
        else
          echo "    ... ${ELAPSED}s / ${DURATION}s  DL_first_tx=${_hb_delta}/${TARGET_TX}  (UE exited — will hit timeout or target)" >&2
        fi
      fi
    done
    if [[ "$TARGET_REACHED" -eq 1 ]]; then
      echo "    target reached in ${ELAPSED}s"
    else
      echo "    timeout ${ELAPSED}s before ${TARGET_TX} DL first-TX"
    fi
  else
    sleep 8
    local SAMPLE_COUNT=0 ELAPSED=0
    echo "sample_id,elapsed_s,raw_stats" > "$OUT/stats_timeseries.csv"
    while [[ $ELAPSED -lt $DURATION ]]; do
      if [[ -f "$BUILD_DIR/nrMAC_stats.log" ]]; then
        STATS_LINE=$(cat "$BUILD_DIR/nrMAC_stats.log" 2>/dev/null | tr '\n' '|')
        echo "${SAMPLE_COUNT},${ELAPSED},${STATS_LINE}" >> "$OUT/stats_timeseries.csv"
      fi
      SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
      sleep "$SAMPLE_INTERVAL"
      ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
    done
  fi

  cp "$BUILD_DIR/nrMAC_stats.log" "$OUT/nrMAC_stats_final.log" 2>/dev/null || true
  grep -E "\[BICTR\]|\[CHANNEL\].*BICTR" "$OUT/gnb.log" > "$OUT/bictr_init.log" 2>/dev/null || true

  cleanup_procs
  date -Iseconds > "$OUT/.trial_complete"
  echo "    done $OUT"
}
