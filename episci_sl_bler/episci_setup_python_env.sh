#!/bin/bash
# Episci: Python venv for BLER post-processing (pandas/matplotlib/numpy).
# Default venv directory: episci_sl_bler/episci_bler_venv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${EPISCI_BLER_VENV:-$SCRIPT_DIR/episci_bler_venv}"

echo "=========================================="
echo "Episci BLER analysis — Python venv"
echo "=========================================="

if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 not found."
    exit 1
fi

if [[ -d "$VENV_DIR" ]]; then
    echo "Virtual environment exists: $VENV_DIR"
    read -p "Recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$VENV_DIR"
    else
        echo "Activate: source $VENV_DIR/bin/activate"
        exit 0
    fi
fi

python3 -m venv "$VENV_DIR" || exit 1
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install --upgrade pip >/dev/null 2>&1
pip install pandas matplotlib numpy

echo "=========================================="
echo "Done. Venv: $VENV_DIR"
echo "Activate: source $VENV_DIR/bin/activate"
echo "=========================================="
