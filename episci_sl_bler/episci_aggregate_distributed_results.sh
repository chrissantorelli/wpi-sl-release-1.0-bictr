#!/usr/bin/env bash
# Episci: aggregate *mcs*_noise*.log from all machines in episci_machines.conf and run analyze_bler_results.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EPISCI_MACHINES_CONF:=${EPISCI_MACHINES_CONF:-$SCRIPT_DIR/episci_machines.conf}}"
: "${EPISCI_OAI_LOG_ROOT:=${EPISCI_OAI_LOG_ROOT:-$HOME/openairinterface5g}}"
: "${EPISCI_ANALYZE_SCRIPT:=${EPISCI_ANALYZE_SCRIPT:-${EPISCI_CI_SCRIPT_DIR:-$HOME/ci_script}/analyze_bler_results.py}}"
: "${EPISCI_BLER_VENV:=${EPISCI_BLER_VENV:-$SCRIPT_DIR/episci_bler_venv}}"

AGGREGATE_DIR="${EPISCI_OAI_LOG_ROOT}/episci_bler_aggregate_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$AGGREGATE_DIR"

echo "=========================================="
echo "Episci — aggregate distributed BLER logs"
echo "=========================================="
echo "Output: $AGGREGATE_DIR"
echo ""

if [[ ! -f "$EPISCI_MACHINES_CONF" ]]; then
    echo "ERROR: $EPISCI_MACHINES_CONF not found"
    exit 1
fi

echo "[local] Copying from $EPISCI_OAI_LOG_ROOT/latest ..."
cp "$EPISCI_OAI_LOG_ROOT/latest/"*mcs*_noise*.log "$AGGREGATE_DIR/" 2>/dev/null || true
count=$(find "$AGGREGATE_DIR" -maxdepth 1 -name '*mcs*.log' 2>/dev/null | wc -l)
echo "  → $count log files so far"

while IFS='=' read -r mid cfg || [[ -n "$mid" ]]; do
    [[ "$mid" =~ ^#.*$ ]] && continue
    [[ -z "$mid" ]] && continue
    host=$(echo "$cfg" | cut -d':' -f1)
    if [[ "$host" == "localhost" ]]; then
        continue
    fi
    echo "[$mid] scp from $host ..."
    prev=$count
    scp -q "$host:$EPISCI_OAI_LOG_ROOT/latest/"*mcs*_noise*.log "$AGGREGATE_DIR/" 2>/dev/null || true
    count=$(find "$AGGREGATE_DIR" -maxdepth 1 -name '*mcs*.log' 2>/dev/null | wc -l)
    echo "  → +$((count - prev)) (total $count)"
done <"$EPISCI_MACHINES_CONF"

echo ""
echo "Total logs: $count (full grid ~522)"
if [[ $count -lt 400 ]]; then
    echo "WARNING: fewer than 400 logs."
    read -p "Continue with analysis? (y/n) " -n 1 -r
    echo
    if [[ ! ${REPLY:-n} =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [[ ! -f "$EPISCI_ANALYZE_SCRIPT" ]]; then
    echo "ERROR: $EPISCI_ANALYZE_SCRIPT not found. Set EPISCI_ANALYZE_SCRIPT or EPISCI_CI_SCRIPT_DIR."
    exit 1
fi
if [[ -f "$EPISCI_BLER_VENV/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "$EPISCI_BLER_VENV/bin/activate"
fi
python3 "$EPISCI_ANALYZE_SCRIPT" "$AGGREGATE_DIR"
echo ""
echo "Results: $AGGREGATE_DIR/bler_data.csv , pc5_bler_curves.png"
