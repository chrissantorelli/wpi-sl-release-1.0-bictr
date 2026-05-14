#!/usr/bin/env bash
# Episci entrypoint: runs the OAI sidelink test harness with Episci BLER config.
#
# Requires run_sl_test.sh (not shipped here). Set one of:
#   EPISCI_SL_TEST_SH     — full path to run_sl_test.sh
#   EPISCI_CI_SCRIPT_DIR  — directory containing run_sl_test.sh (default: ~/ci_script)
#
# Optional:
#   BLER_CONFIG_FILE      — config filename under EPISCI_CI_SCRIPT_DIR (default below)
#   EPISCI_CONFIG_COPY    — if 1, copy episci_run_sl_test_config.sh into EPISCI_CI_SCRIPT_DIR
#                           as BLER_CONFIG_FILE before running (one-time convenience).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EPISCI_CI_SCRIPT_DIR:=${EPISCI_CI_SCRIPT_DIR:-$HOME/ci_script}}"
: "${EPISCI_SL_TEST_SH:=${EPISCI_SL_TEST_SH:-$EPISCI_CI_SCRIPT_DIR/run_sl_test.sh}}"
: "${BLER_CONFIG_FILE:=${BLER_CONFIG_FILE:-episci_run_sl_test_config.sh}}"
: "${EPISCI_CONFIG_COPY:=0}"

if [[ ! -f "$EPISCI_SL_TEST_SH" ]]; then
    echo "ERROR: run_sl_test harness not found: $EPISCI_SL_TEST_SH" >&2
    echo "Set EPISCI_SL_TEST_SH or EPISCI_CI_SCRIPT_DIR." >&2
    exit 1
fi

if [[ "$EPISCI_CONFIG_COPY" == "1" ]] || [[ ! -f "$EPISCI_CI_SCRIPT_DIR/$BLER_CONFIG_FILE" ]]; then
    if [[ -f "$SCRIPT_DIR/episci_run_sl_test_config.sh" ]]; then
        echo "Installing $BLER_CONFIG_FILE into $EPISCI_CI_SCRIPT_DIR"
        cp -f "$SCRIPT_DIR/episci_run_sl_test_config.sh" "$EPISCI_CI_SCRIPT_DIR/$BLER_CONFIG_FILE"
    fi
fi

if [[ ! -f "$EPISCI_CI_SCRIPT_DIR/$BLER_CONFIG_FILE" ]]; then
    echo "ERROR: Config not found: $EPISCI_CI_SCRIPT_DIR/$BLER_CONFIG_FILE" >&2
    echo "Copy episci_run_sl_test_config.sh there or set BLER_CONFIG_FILE." >&2
    exit 1
fi

export EPISCI_CI_SCRIPT_DIR
export BLER_CONFIG_FILE
cd "$EPISCI_CI_SCRIPT_DIR"
exec bash "$EPISCI_SL_TEST_SH" "$@"
