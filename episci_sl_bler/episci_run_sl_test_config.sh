#!/bin/bash
#############################################################
# Episci: BLER profile config for run_sl_test.sh (sidelink Mode 1 sweep)
# Copy or symlink into EPISCI_CI_SCRIPT_DIR, or used directly by
# episci_run_distributed_bler_auto.sh (per-machine overrides appended).
#############################################################
# USRP serial numbers for the SL mode 1 relay test.
RELAY_UE_USRP_SN_FOR_UU=340EA03
RELAY_UE_USRP_SN_FOR_SL=3271246

uu_basic_tests=(
    rfsim_uu_ping_test_on_local_host
    rfsim_uu_ping_test_on_two_hosts
    usrp_B210_uu_ping_test_on_two_hosts
)
slmode2_basic_tests=(
    rfsim_pc5_ping_test_on_local_host
    rfsim_pc5_ping_test_on_two_hosts
    usrp_B210_pc5_ping_test_on_two_hosts
)
slmode2_csi_psfch_tests=(
    rfsim_pc5_csi_acquisition_psfch_period_test_on_local_host
    rfsim_pc5_csi_acquisition_psfch_period_test_on_two_hosts
    usrp_B210_pc5_csi_acquisition_psfch_period_test_on_two_hosts
)
slmode1_basic_tests=(
    rfsim_slmode1_srap_ping_test_on_local_host
    rfsim_slmode1_srap_ping_test_on_three_hosts
    usrp_B210_slmode1_srap_ping_test_on_three_hosts
)
slmode1_bler_tests=(
    rfsim_slmode1_bler_sweep_test_on_local_host
)
enabled_tests=(
    slmode1_bler_tests
)

base_log_dir="~/openairinterface5g"
use_gnome=0
test_profile='bler'

if [[ $test_profile == "pilot" ]]; then
    num_repeat=1
    mcs_array=(2)
    duration=70
    snr_array=($(seq 0 1 0))
    atten_array=(0)
    tx_gain=30
    rx_gain=70
    noise_power_array=(0)
    ploss_db=10
elif [[ $test_profile == "regress" ]]; then
    num_repeat=1
    mcs_array=(1 9)
    duration=70
    snr_array=($(seq 0 1 0))
    atten_array=(20)
    tx_gain=30
    rx_gain=70
elif [[ $test_profile == "stress" ]]; then
    num_repeat=3
    mcs_array=(9 16 28)
    duration=300
    snr_array=($(seq 0 1 0))
    atten_array=(20 30 40 50 55 60)
    tx_gain=20
    rx_gain=110
elif [[ $test_profile == "bler" ]]; then
    num_repeat=1
    mcs_array=($(seq 0 1 28))
    duration=100
    snr_array=($(seq 0 1 0))
    atten_array=(20)
    noise_power_array=(-12 -10 -8 -6 -4 -2 0 2 4)
    ploss_db=10
    csi_acquisition=0
    psfch_period=2
    bler_optimization="parallel_mcs"
else
    echo "ERROR: Unknown test profile '$test_profile'"
    exit 1
fi

softmodem_log_files=(
    result_gNB.log
    result_nrUE.log
    result_syncref.log
    result_nearby.log
    result_nrUE_syncref.log
)

echo "=========================================="
echo "Episci BLER config — profile: $test_profile"
echo "=========================================="
echo "MCS Array            : ${mcs_array[@]}"
echo "Duration per Test    : ${duration}s"
echo "Enabled Test Cases:"
for test in "${enabled_tests[@]}"; do
    echo "  - $test"
done
if [[ $test_profile == "bler" ]]; then
    echo "Noise Power Array    : ${noise_power_array[@]}"
    echo "Path Loss            : ${ploss_db} dB"
    echo "CSI Acquisition      : ${csi_acquisition}"
    echo "PSFCH Period         : ${psfch_period}"
fi
echo "=========================================="
echo ""
