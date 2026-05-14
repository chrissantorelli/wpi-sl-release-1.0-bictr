#!/usr/bin/env bash
# Episci: live progress from episci_bler_*.log on each host in episci_machines.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EPISCI_MACHINES_CONF:=${EPISCI_MACHINES_CONF:-$SCRIPT_DIR/episci_machines.conf}}"
: "${EPISCI_WATCH_INTERVAL:=${EPISCI_WATCH_INTERVAL:-180}}"

echo "=========================================="
echo "Episci BLER progress (refresh ${EPISCI_WATCH_INTERVAL}s, Ctrl+C exit)"
echo "=========================================="

if [[ ! -f "$EPISCI_MACHINES_CONF" ]]; then
    echo "ERROR: $EPISCI_MACHINES_CONF not found"
    exit 1
fi

while true; do
    clear
    echo "Episci BLER — $(date +%H:%M:%S)"
    echo "=========================================="
    while IFS='=' read -r mid cfg || [[ -n "$mid" ]]; do
        [[ "$mid" =~ ^#.*$ ]] && continue
        [[ -z "$mid" ]] && continue
        host=$(echo "$cfg" | cut -d':' -f1)
        noise=$(echo "$cfg" | cut -d':' -f2)
        echo ""
        echo "=== $mid ($host) noise=$noise ==="
        if [[ "$host" == "localhost" ]]; then
            if [[ -f "$HOME/episci_bler_${mid}.log" ]]; then
                grep -A 4 "PROGRESS:" "$HOME/episci_bler_${mid}.log" 2>/dev/null | tail -5 || tail -5 "$HOME/episci_bler_${mid}.log"
            else
                echo "(no $HOME/episci_bler_${mid}.log)"
            fi
        else
            ssh "$host" "grep -A 4 PROGRESS: \"\$HOME/episci_bler_${mid}.log\" 2>/dev/null | tail -5" 2>/dev/null \
                || ssh "$host" "tail -5 \"\$HOME/episci_bler_${mid}.log\" 2>/dev/null" 2>/dev/null \
                || echo "(no remote log yet)"
        fi
    done <"$EPISCI_MACHINES_CONF"
    echo ""
    echo "=========================================="
    sleep "$EPISCI_WATCH_INTERVAL"
done
