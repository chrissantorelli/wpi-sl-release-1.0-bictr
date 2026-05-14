#!/usr/bin/env bash
#############################################################
# Episci: automated distributed sidelink Mode 1 BLER sweep
# (same workflow as legacy run_distributed_bler_auto.sh, Episci-prefixed
#  artifacts and configurable paths).
#
# Usage: ./episci_run_distributed_bler_auto.sh
#
# Environment (optional):
#   EPISCI_CI_SCRIPT_DIR   — dir containing run_sl_test.sh (default: ~/ci_script)
#   EPISCI_SL_TEST_SH      — override path to run_sl_test.sh
#   EPISCI_OAI_LOG_ROOT    — OAI tree for latest/ logs (default: ~/openairinterface5g)
#   EPISCI_ANALYZE_SCRIPT  — analyze_bler_results.py path
#                            (default: $EPISCI_CI_SCRIPT_DIR/analyze_bler_results.py)
#   EPISCI_MACHINES_CONF   — machine map (default: episci_machines.conf next to this script)
#   EPISCI_BLER_VENV       — Python venv (default: episci_bler_venv next to this script)
#   EPISCI_RESULTS_PARENT  — parent dir for episci_bler_results_* (default: EPISCI_OAI_LOG_ROOT)
#   POLL_INTERVAL          — seconds between status checks (default: 60)
#############################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EPISCI_CI_SCRIPT_DIR:=${EPISCI_CI_SCRIPT_DIR:-$HOME/ci_script}}"
: "${EPISCI_SL_TEST_SH:=${EPISCI_SL_TEST_SH:-$EPISCI_CI_SCRIPT_DIR/run_sl_test.sh}}"
: "${EPISCI_OAI_LOG_ROOT:=${EPISCI_OAI_LOG_ROOT:-$HOME/openairinterface5g}}"
: "${EPISCI_ANALYZE_SCRIPT:=${EPISCI_ANALYZE_SCRIPT:-$EPISCI_CI_SCRIPT_DIR/analyze_bler_results.py}}"
: "${EPISCI_MACHINES_CONF:=${EPISCI_MACHINES_CONF:-$SCRIPT_DIR/episci_machines.conf}}"
: "${EPISCI_BLER_VENV:=${EPISCI_BLER_VENV:-$SCRIPT_DIR/episci_bler_venv}}"
: "${EPISCI_RESULTS_PARENT:=${EPISCI_RESULTS_PARENT:-$EPISCI_OAI_LOG_ROOT}}"
: "${POLL_INTERVAL:=60}"

MACHINES_CONF="$EPISCI_MACHINES_CONF"
RESULTS_DIR="$EPISCI_RESULTS_PARENT/episci_bler_results_$(date +%Y%m%d_%H%M%S)"
VENV_DIR="$EPISCI_BLER_VENV"
CONFIG_TEMPLATE="$SCRIPT_DIR/episci_run_sl_test_config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_prerequisites() {
    echo -e "${BLUE}=========================================="
    echo "Episci — distributed sidelink BLER (auto)"
    echo -e "==========================================${NC}"
    echo ""
    echo "Harness:        $EPISCI_SL_TEST_SH"
    echo "CI script dir:  $EPISCI_CI_SCRIPT_DIR"
    echo "OAI log root:   $EPISCI_OAI_LOG_ROOT"
    echo "Machines file:  $MACHINES_CONF"
    echo ""

    if [[ ! -f "$MACHINES_CONF" ]]; then
        echo -e "${RED}ERROR: machines config not found: $MACHINES_CONF${NC}"
        exit 1
    fi
    if [[ ! -f "$EPISCI_SL_TEST_SH" ]]; then
        echo -e "${RED}ERROR: run_sl_test.sh not found (set EPISCI_SL_TEST_SH).${NC}"
        exit 1
    fi
    if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
        echo -e "${RED}ERROR: missing template $CONFIG_TEMPLATE${NC}"
        exit 1
    fi
    if [[ ! -f "$EPISCI_ANALYZE_SCRIPT" ]]; then
        echo -e "${RED}ERROR: analyze script not found: $EPISCI_ANALYZE_SCRIPT${NC}"
        exit 1
    fi

    if [[ ! -d "$VENV_DIR" ]]; then
        echo -e "${YELLOW}Python venv missing; running episci_setup_python_env.sh ...${NC}"
        bash "$SCRIPT_DIR/episci_setup_python_env.sh" || exit 1
    fi
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    if ! python3 -c "import pandas, matplotlib, numpy" 2>/dev/null; then
        echo -e "${RED}ERROR: venv missing deps. Run: $SCRIPT_DIR/episci_setup_python_env.sh${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Prerequisites OK${NC}"
    echo ""
}

declare -A MACHINES
declare -A NOISE_ARRAYS
declare -A STATUS

parse_config() {
    echo -e "${BLUE}Reading $MACHINES_CONF ...${NC}"
    local count=0
    while IFS='=' read -r machine_id config || [[ -n "$machine_id" ]]; do
        [[ "$machine_id" =~ ^#.*$ ]] && continue
        [[ -z "$machine_id" ]] && continue
        local hostname
        hostname=$(echo "$config" | cut -d':' -f1)
        local noise_list
        noise_list=$(echo "$config" | cut -d':' -f2)
        MACHINES[$machine_id]="$hostname"
        NOISE_ARRAYS[$machine_id]="$noise_list"
        STATUS[$machine_id]="pending"
        echo "  $machine_id: $hostname → noise [$noise_list] dB"
        count=$((count + 1))
    done < "$MACHINES_CONF"
    if [[ $count -eq 0 ]]; then
        echo -e "${RED}ERROR: no machines in $MACHINES_CONF${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ $count machines${NC}"
    echo ""
}

append_overrides() {
    local machine_id=$1
    local noise_array=$2
    local target_path=$3
    cat >> "$target_path" << EOF

# === EPISCI distributed BLER overrides ($machine_id) ===
test_profile='bler'
mcs_array=(\$(seq 0 1 28))
noise_power_array=($noise_array)
ploss_db=10
duration=100
enabled_tests=(rfsim_slmode1_bler_sweep_test_on_local_host)
EOF
}

launch_test() {
    local machine_id=$1
    local hostname=${MACHINES[$machine_id]}
    local noise_list=${NOISE_ARRAYS[$machine_id]}
    local noise_array
    noise_array=$(echo "$noise_list" | tr ',' ' ')
    local logf="$HOME/episci_bler_${machine_id}.log"
    local pidf="$HOME/episci_bler_${machine_id}.pid"
    local cfg_name="episci_run_sl_test_config_${machine_id}.sh"
    local cfg_path="$EPISCI_CI_SCRIPT_DIR/$cfg_name"

    echo -e "${BLUE}[$machine_id] Launch on $hostname${NC}"
    echo "  Noise dB: $noise_array"

    if [[ "$hostname" == "localhost" ]]; then
        cp -f "$CONFIG_TEMPLATE" "$cfg_path"
        append_overrides "$machine_id" "$noise_array" "$cfg_path"
        (
            cd "$EPISCI_CI_SCRIPT_DIR"
            export BLER_CONFIG_FILE="$cfg_name"
            nohup bash "$EPISCI_SL_TEST_SH" >"$logf" 2>&1 &
            echo $! >"$pidf"
        )
    else
        local rtmp
        rtmp=$(mktemp)
        cp -f "$CONFIG_TEMPLATE" "$rtmp"
        append_overrides "$machine_id" "$noise_array" "$rtmp"
        ssh "$hostname" "mkdir -p \"$EPISCI_CI_SCRIPT_DIR\""
        scp -q "$rtmp" "$hostname:$cfg_path"
        rm -f "$rtmp"

        local ltmp
        ltmp=$(mktemp)
        cat >"$ltmp" <<EOF
#!/bin/bash
set -e
cd "$EPISCI_CI_SCRIPT_DIR"
export BLER_CONFIG_FILE="$cfg_name"
nohup bash "$EPISCI_SL_TEST_SH" > "\$HOME/episci_bler_${machine_id}.log" 2>&1 &
echo \$! > "\$HOME/episci_bler_${machine_id}.pid"
EOF
        scp -q "$ltmp" "$hostname:~/episci_launch_bler_${machine_id}.sh"
        rm -f "$ltmp"
        ssh "$hostname" "chmod +x \"\$HOME/episci_launch_bler_${machine_id}.sh\" && nohup \"\$HOME/episci_launch_bler_${machine_id}.sh\" >/dev/null 2>&1 &"
    fi

    STATUS[$machine_id]="running"
    sleep 3
    if [[ "$hostname" == "localhost" ]]; then
        if [[ -f "$pidf" ]] && ps -p "$(cat "$pidf")" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Running locally PID $(cat "$pidf")${NC}"
        else
            echo -e "${YELLOW}⚠ Check $logf${NC}"
        fi
    else
        if ssh "$hostname" "test -f \"$HOME/episci_bler_${machine_id}.pid\" && ps -p \$(cat \"$HOME/episci_bler_${machine_id}.pid\") >/dev/null 2>&1"; then
            echo -e "${GREEN}✓ Running on $hostname${NC}"
        else
            echo -e "${YELLOW}⚠ ssh $hostname 'tail -50 $HOME/episci_bler_${machine_id}.log'${NC}"
        fi
    fi
    echo ""
    sleep 2
}

check_status() {
    local machine_id=$1
    local hostname=${MACHINES[$machine_id]}
    [[ "${STATUS[$machine_id]}" != "running" ]] && return 0

    if [[ "$hostname" == "localhost" ]]; then
        local pidf="$HOME/episci_bler_${machine_id}.pid"
        if [[ -f "$pidf" ]]; then
            local pid
            pid=$(cat "$pidf")
            if ! ps -p "$pid" >/dev/null 2>&1; then
                STATUS[$machine_id]="complete"
                echo -e "${GREEN}[$machine_id] complete (local)${NC}"
            fi
        fi
    else
        if ssh "$hostname" "grep -q 'Test Execution Complete' \"$HOME/episci_bler_${machine_id}.log\" 2>/dev/null"; then
            STATUS[$machine_id]="complete"
            echo -e "${GREEN}[$machine_id] complete on $hostname${NC}"
        fi
    fi
}

monitor_tests() {
    echo -e "${BLUE}Monitoring (poll ${POLL_INTERVAL}s)...${NC}"
    local all_complete=false
    while [[ "$all_complete" == "false" ]]; do
        all_complete=true
        echo -e "${YELLOW}$(date +%H:%M:%S)${NC}"
        for machine_id in "${!MACHINES[@]}"; do
            check_status "$machine_id"
            echo "  [$machine_id] ${MACHINES[$machine_id]}: ${STATUS[$machine_id]}"
            [[ "${STATUS[$machine_id]}" == "running" ]] && all_complete=false
        done
        if [[ "$all_complete" == "false" ]]; then
            echo "Waiting ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            echo ""
        fi
    done
    echo -e "${GREEN}✓ All machines reported complete${NC}"
    echo ""
}

collect_logs() {
    echo -e "${BLUE}Collecting *mcs*_noise*.log into $RESULTS_DIR${NC}"
    mkdir -p "$RESULTS_DIR"
    local total_logs=0
    for machine_id in "${!MACHINES[@]}"; do
        local hostname=${MACHINES[$machine_id]}
        echo "[$machine_id] $hostname"
        if [[ "$hostname" == "localhost" ]]; then
            cp "$EPISCI_OAI_LOG_ROOT/latest/"*mcs*_noise*.log "$RESULTS_DIR/" 2>/dev/null || true
        else
            scp -q "$hostname:$EPISCI_OAI_LOG_ROOT/latest/"*mcs*_noise*.log "$RESULTS_DIR/" 2>/dev/null || true
        fi
        total_logs=$(find "$RESULTS_DIR" -maxdepth 1 -name '*mcs*.log' 2>/dev/null | wc -l)
        echo "  → cumulative logs: $total_logs"
    done
    echo -e "${GREEN}✓ Collected $total_logs log files${NC}"
    if [[ $total_logs -lt 400 ]]; then
        echo -e "${YELLOW}WARNING: expected ~522 lines for full 4-machine grid.${NC}"
    fi
    echo ""
}

run_analysis() {
    echo -e "${BLUE}Running analysis...${NC}"
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    python3 "$EPISCI_ANALYZE_SCRIPT" "$RESULTS_DIR"
}

display_results() {
    echo ""
    echo "Output: $RESULTS_DIR"
    echo "  Plot: $RESULTS_DIR/pc5_bler_curves.png"
    echo "  CSV:  $RESULTS_DIR/bler_data.csv"
    if command -v eog &>/dev/null && [[ -f "$RESULTS_DIR/pc5_bler_curves.png" ]]; then
        eog "$RESULTS_DIR/pc5_bler_curves.png" &
    fi
}

main() {
    check_prerequisites
    parse_config
    echo -e "${BLUE}Launching...${NC}"
    for machine_id in "${!MACHINES[@]}"; do
        launch_test "$machine_id"
    done
    monitor_tests
    collect_logs
    if run_analysis; then
        display_results
    else
        echo -e "${RED}Analysis failed. Logs in $RESULTS_DIR${NC}"
        exit 1
    fi
}

main
