#!/usr/bin/env bash
# Episci: sync sl_CSI_Acquisition and sl_PSFCH_Period (same behavior as legacy sync_sl_config_params.sh)

set -euo pipefail

: "${EPISCI_REMOTE_UE_HOST:=${EPISCI_REMOTE_UE_HOST:-remote_ue}}"
CONF_PATH="$HOME/openairinterface5g/targets/PROJECTS/NR-SIDELINK/CONF"
GNB_CONF_PATH="$HOME/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF"
REMOTE_CONF_PATH="${EPISCI_REMOTE_CONF_PATH:-/home/$(whoami)/openairinterface5g/targets/PROJECTS/NR-SIDELINK/CONF}"

DEFAULT_CSI_ACQ=${1:-0}
DEFAULT_PSFCH_PERIOD=${2:-0}

echo "=========================================="
echo "Episci — sidelink CSI / PSFCH sync"
echo "=========================================="
echo "CSI acquisition : $DEFAULT_CSI_ACQ"
echo "PSFCH period    : $DEFAULT_PSFCH_PERIOD"
echo "Remote SSH host : $EPISCI_REMOTE_UE_HOST"
echo ""

set_config_param() {
    local file=$1 param=$2 value=$3
    [[ -f "$file" ]] || { echo "ERROR: missing $file"; return 1; }
    local c
    c=$(grep -c "$param" "$file" || true)
    [[ "$c" -eq 0 ]] && { echo "WARNING: $param not in $file"; return 1; }
    sed -i "s/\(${param}[[:space:]]*=[[:space:]]*\)[0-9]\+/\1${value}/g" "$file"
    echo "  ✓ $param=$value in $(basename "$file")"
}

verify_config_param() {
    local file=$1 param=$2 expected=$3
    [[ -f "$file" ]] || return 1
    while read -r line; do
        val=$(echo "$line" | grep -oP '=\s*\K[0-9]+' || true)
        [[ "$val" == "$expected" ]] || echo "  ✗ $param=$val (want $expected) in $(basename "$file")"
    done < <(grep "$param" "$file" || true)
}

set_remote() {
    local file=$1 param=$2 value=$3
    ssh "$EPISCI_REMOTE_UE_HOST" "test -f $file" || { echo "ERROR: remote missing $file"; return 1; }
    ssh "$EPISCI_REMOTE_UE_HOST" "sed -i 's/\\(${param}[[:space:]]*=[[:space:]]*\\)[0-9]\\+/\\1${value}/g' $file"
    echo "  ✓ remote $param=$value in $(basename "$file")"
}

echo "Local sidelink + gNB relay ..."
set_config_param "$CONF_PATH/sl_sync_ref.conf" "sl_CSI_Acquisition" "$DEFAULT_CSI_ACQ"
set_config_param "$CONF_PATH/sl_sync_ref.conf" "sl_PSFCH_Period" "$DEFAULT_PSFCH_PERIOD"
set_config_param "$CONF_PATH/sl_ue1.conf" "sl_CSI_Acquisition" "$DEFAULT_CSI_ACQ"
set_config_param "$CONF_PATH/sl_ue1.conf" "sl_PSFCH_Period" "$DEFAULT_PSFCH_PERIOD"
set_config_param "$GNB_CONF_PATH/gnb.sa.band78.fr1.106PRB.usrpb210_relay_ue.conf" "sl_CSI_Acquisition" "$DEFAULT_CSI_ACQ"
set_config_param "$GNB_CONF_PATH/gnb.sa.band78.fr1.106PRB.usrpb210_relay_ue.conf" "sl_PSFCH_Period" "$DEFAULT_PSFCH_PERIOD"

echo ""
echo "Remote sl_ue1.conf ($EPISCI_REMOTE_UE_HOST) ..."
set_remote "$REMOTE_CONF_PATH/sl_ue1.conf" "sl_CSI_Acquisition" "$DEFAULT_CSI_ACQ"
set_remote "$REMOTE_CONF_PATH/sl_ue1.conf" "sl_PSFCH_Period" "$DEFAULT_PSFCH_PERIOD"

echo ""
echo "Verify local ..."
verify_config_param "$CONF_PATH/sl_sync_ref.conf" "sl_CSI_Acquisition" "$DEFAULT_CSI_ACQ"
verify_config_param "$CONF_PATH/sl_ue1.conf" "sl_PSFCH_Period" "$DEFAULT_PSFCH_PERIOD"
echo "Done. Usage: $0 [csi_acq] [psfch_period]  (override EPISCI_REMOTE_UE_HOST / EPISCI_REMOTE_CONF_PATH as needed)"
