#!/usr/bin/env bash
# Episci: stop distributed BLER runs (episci_bler_*.pid) on hosts listed in episci_machines.conf

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EPISCI_MACHINES_CONF:=${EPISCI_MACHINES_CONF:-$SCRIPT_DIR/episci_machines.conf}}"

stop_remote() {
    local host=$1
    ssh "$host" bash -se <<'STOPR' || true
shopt -s nullglob
for f in "$HOME"/episci_bler_*.pid; do
  pid=$(cat "$f" 2>/dev/null || true)
  [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null || true
done
sudo killall -9 nr-softmodem nr-uesoftmodem 2>/dev/null || true
STOPR
}

echo "=========================================="
echo "Episci — stop BLER tests"
echo "=========================================="

if [[ ! -f "$EPISCI_MACHINES_CONF" ]]; then
    echo "ERROR: $EPISCI_MACHINES_CONF not found"
    exit 1
fi

while IFS='=' read -r mid cfg || [[ -n "$mid" ]]; do
    [[ "$mid" =~ ^#.*$ ]] && continue
    [[ -z "$mid" ]] && continue
    host=$(echo "$cfg" | cut -d':' -f1)
    if [[ "$host" == "localhost" ]]; then
        echo "=== localhost ($mid) ==="
        for f in "$HOME"/episci_bler_*.pid; do
            [[ -f "$f" ]] || continue
            pid=$(cat "$f" 2>/dev/null || true)
            [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null || true
        done
        sudo killall -9 nr-softmodem nr-uesoftmodem 2>/dev/null || true
        echo "✓ stopped"
    else
        echo "=== $host ($mid) ==="
        stop_remote "$host" && echo "✓ stopped" || echo "⚠ ssh $host failed"
    fi
done <"$EPISCI_MACHINES_CONF"

echo ""
echo "Done. Re-run: $SCRIPT_DIR/episci_run_distributed_bler_auto.sh"
