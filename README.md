<h1 align="center">
    <a href="https://openairinterface.org/"><img src="https://openairinterface.org/wp-content/uploads/2015/06/cropped-oai_final_logo.png" alt="OAI" width="550"></a>
</h1>

<p align="center">
    <a href="https://gitlab.eurecom.fr/oai/openairinterface5g/-/blob/master/LICENSE"><img src="https://img.shields.io/badge/license-OAI--Public--V1.1-blue" alt="License"></a>
    <a href="https://releases.ubuntu.com/18.04/"><img src="https://img.shields.io/badge/OS-Ubuntu18-Green" alt="Supported OS Ubuntu 18"></a>
    <a href="https://releases.ubuntu.com/20.04/"><img src="https://img.shields.io/badge/OS-Ubuntu20-Green" alt="Supported OS Ubuntu 20"></a>
    <a href="https://releases.ubuntu.com/22.04/"><img src="https://img.shields.io/badge/OS-Ubuntu22-Green" alt="Supported OS Ubuntu 22"></a>
    <a href="https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux"><img src="https://img.shields.io/badge/OS-RHEL8-Green" alt="Supported OS RHEL8"></a>
    <a href="https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux"><img src="https://img.shields.io/badge/OS-RHEL9-Green" alt="Supported OS RELH9"></a>
    <a href="https://getfedora.org/en/workstation/"><img src="https://img.shields.io/badge/OS-Fedore37-Green" alt="Supported OS Fedora 37"></a>
</p>

<p align="center">
    <a href="https://jenkins-oai.eurecom.fr/job/RAN-Container-Parent/"><img src="https://img.shields.io/jenkins/build?jobUrl=https%3A%2F%2Fjenkins-oai.eurecom.fr%2Fjob%2FRAN-Container-Parent%2F&label=build%20Images"></a>
</p>

<p align="center">
  <a href="https://hub.docker.com/r/oaisoftwarealliance/oai-gnb"><img alt="Docker Pulls" src="https://img.shields.io/docker/pulls/oaisoftwarealliance/oai-gnb?label=gNB%20docker%20pulls"></a>
  <a href="https://hub.docker.com/r/oaisoftwarealliance/oai-nr-ue"><img alt="Docker Pulls" src="https://img.shields.io/docker/pulls/oaisoftwarealliance/oai-nr-ue?label=NR-UE%20docker%20pulls"></a>
  <a href="https://hub.docker.com/r/oaisoftwarealliance/oai-enb"><img alt="Docker Pulls" src="https://img.shields.io/docker/pulls/oaisoftwarealliance/oai-enb?label=eNB%20docker%20pulls"></a>
  <a href="https://hub.docker.com/r/oaisoftwarealliance/oai-lte-ue"><img alt="Docker Pulls" src="https://img.shields.io/docker/pulls/oaisoftwarealliance/oai-lte-ue?label=LTE-UE%20docker%20pulls"></a>
</p>

# OpenAirInterface License #

 *  [OAI License Model](http://www.openairinterface.org/?page_id=101)
 *  [OAI License v1.1 on our website](http://www.openairinterface.org/?page_id=698)

It is distributed under **OAI Public License V1.1**.

The license information is distributed under [LICENSE](LICENSE) file in the same directory.

Please see [NOTICE](NOTICE.md) file for third party software that is included in the sources.

# Where to Start #

 *  [General overview of documentation](./doc/README.md)
 *  [The implemented features](./doc/FEATURE_SET.md)
 *  [How to build](./doc/BUILD.md)
 *  [How to run the modems](./doc/RUNMODEM.md)
 *  [Running 5G Sidelink Mode 1 / Mode 2 (this fork)](#5g-sidelink-mode-1--mode-2)
 *  [EpiSci sidelink Mode 2 guide](./doc/episys/README_SL.md)

# 5G Sidelink Mode 1 / Mode 2 #

This fork (`sl-release-1.0`) supports NR sidelink over RFSim:

 *  **Mode 2** (UE-autonomous): SyncRef UE + Nearby UE over PC5.
 *  **Mode 1** (network-scheduled, U2N relay): gNB + Relay UE (Uu + PC5 SyncRef) +
    Remote UE (PC5-only client). Note: the remote UE is launched with `--sl-mode 2`
    for its PC5 PHY — the proven path for this topology; the true sl-mode-1 remote
    path in `nr-ue.c` is work in progress.

Both modes can run over a clean RFSim channel or through a channel model
(`AWGN` or the `BICTR_LUNAR` terrain model).

## Build ##

```bash
cd cmake_targets
./build_oai --nrUE --gNB -w SIMU --cmake-opt -DENABLE_BLER_INSTRUMENTATION=ON
# incremental rebuilds:
cd ran_build/build && make nr-uesoftmodem nr-softmodem -j$(nproc)
```

`ENABLE_BLER_INSTRUMENTATION=ON` enables the `[BLER_STATS]` / `[HARQ_STATS]` /
`[LDPC_STATS]` log tags (`PC5_RX_SUMMARY`, `PC5_PSSCH_SINR_SUMMARY`,
`PC5_PSFCH_RX_TOTALS`, `GNB_UL_LDPC_ITERATIONS`, `SRAP_FWD_SUMMARY`, ...) used
for BLER/HARQ/LDPC data collection. Verify with
`grep -ac PC5_RX_SUMMARY nr-uesoftmodem` (must be ≥ 1).

**Real-time scheduling:** `nr-uesoftmodem` calls `sched_setscheduler(79)` at
startup and aborts if it is not permitted. Run with `sudo`, or in a container
with `--cap-add=SYS_NICE` (add `--cap-add=NET_ADMIN --device /dev/net/tun` for
the `oaitun_*` interfaces).

## Mode 2 — without channel model (clean RFSim) ##

All commands below run from `cmake_targets/ran_build/build` with
`export LD_LIBRARY_PATH=$PWD:$LD_LIBRARY_PATH`.

Terminal 1 — SyncRef UE:

```bash
sudo -E ./nr-uesoftmodem \
  -O ../../../targets/PROJECTS/NR-SIDELINK/CONF/sl_sync_ref.conf \
  --sa --sl-mode 2 --sync-ref --rfsim --nokrnmod --mcs 9 \
  --rfsimulator.serveraddrsl server --rfsimulator.serverportsl 4048 \
  --node-number 2 --thread-pool -1,-1,-1,-1
```

Terminal 2 — Nearby UE (use the SyncRef machine's IP instead of `127.0.0.1`
when running on two hosts):

```bash
sudo -E ./nr-uesoftmodem \
  -O ../../../targets/PROJECTS/NR-SIDELINK/CONF/sl_ue1.conf \
  --sa --sl-mode 2 --rfsim --nokrnmod --mcs 9 \
  --rfsimulator.serveraddrsl 127.0.0.1 --rfsimulator.serverportsl 4048 \
  --node-number 3 --thread-pool -1,-1,-1,-1
```

Expected: the Nearby UE logs `PSBCH RX OK` / `Sync Achievd` within ~10 s, then
both sides emit `PC5_RX_SUMMARY ... BLER=0.0000` lines. IP traffic
(two hosts): `ping -I oaitun_ue2 10.0.0.1`.

## Mode 2 — with channel model (AWGN or BICTR) ##

Append an `rfsimulator`/`channelmod` block to a **copy** of each UE conf, e.g.
AWGN:

```
rfsimulator : {
  options = ("chanmod");
  modelname = "AWGN";
  IQfile = "/tmp/rfsimulator.iqs";
};
channelmod = {
  max_chan  = 10;
  modellist = "modellist_sl_awgn";
  modellist_sl_awgn = (
    { model_name = "rfsimu_channel_enB0"; type = "AWGN";
      ploss_dB = 10; noise_power_dB = -4; forgetfact = 0; offset = 0; ds_tdl = 0; },
    { model_name = "rfsimu_channel_ue0";  type = "AWGN";
      ploss_dB = 10; noise_power_dB = -4; forgetfact = 0; offset = 0; ds_tdl = 0; }
  );
};
```

`noise_power_dB` is the sweep axis (SINR ≈ −noise_power_dB). For the
`BICTR_LUNAR` terrain model, use `type = "BICTR_LUNAR"` entries with the
`bictr_*` parameters and a DEM raster (`bictr_dem_file`). The canonical block
generator and full sweep harness live in the local-only `bictr_analysis/` tree
(not pushed to this repo): `mc_sl_helpers.sh` (`mc_sl_append_pc5_bictr_conf`)
and:

```bash
sudo bictr_analysis/run_montecarlo_slmode2.sh --smoke                 # 3-point BICTR sanity sweep
sudo bictr_analysis/run_montecarlo_slmode2.sh --mcs 9 --noise -4      # single point
```

## Mode 1 (U2N relay) — without channel model ##

Three nodes on one host; Uu on rfsim port 4043, PC5 on port 4048.

Terminal 1 — gNB:

```bash
sudo -E ./nr-softmodem \
  -O ../../../targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb.sa.band78.fr1.106PRB.usrpb210_relay_ue.conf \
  --sa --noS1 --nokrnmod --rfsim --relay-type 1 \
  --rfsimulator.serveraddr server --rfsimulator.serverport 4043 \
  --gNBs.[0].min_rxtxtime 6 --thread-pool -1,-1,-1,-1
```

Note: this gNB conf ships with a `channelmod` block (`noise_power_dB = -16`) on
the Uu link. For a clean backhaul set those entries to −30 or remove the
`chanmod` option in a copy of the conf.

Terminal 2 — Relay UE (Uu attach + PC5 SyncRef):

```bash
sudo -E ./nr-uesoftmodem \
  -O ../../../targets/PROJECTS/NR-SIDELINK/CONF/sl_sync_ref.conf \
  --sa --noS1 --sl-mode 1 --sync-ref --relay-type 1 \
  --rfsim --nokrnmod --mcs 9 \
  -C 3619200000 --numerology 1 -r 106 --ssb 516 \
  --rfsimulator.serveraddr 127.0.0.1 --rfsimulator.serverport 4043 \
  --rfsimulator.serveraddrsl server --rfsimulator.serverportsl 4048 \
  --node-number 2 --thread-pool -1,-1,-1,-1
```

Terminal 3 — Remote UE (PC5-only; start after the relay attaches and its PC5
server is listening on 4048):

```bash
sudo -E ./nr-uesoftmodem \
  -O ../../../targets/PROJECTS/NR-SIDELINK/CONF/sl_ue1.conf \
  --sa --noS1 --sl-mode 2 --relay-type 1 \
  --rfsim --nokrnmod --mcs 9 \
  -C 3619200000 --numerology 1 -r 106 --ssb 516 \
  --rfsimulator.serveraddrsl 127.0.0.1 --rfsimulator.serverportsl 4048 \
  --node-number 3 --thread-pool -1,-1,-1,-1
```

Expected bring-up sequence: relay logs RRC connection on Uu, then
`Launching UE_thread_sl`; remote logs `PSBCH RX OK`; SRAP threads start on
both UEs; `PC5_RX_SUMMARY` (PC5) and `UU_RX_SUMMARY` / `GNB_UL_SUMMARY` (Uu)
report per-hop BLER.

## Mode 1 — with channel model (AWGN or BICTR) ##

Same conf-append mechanism as Mode 2, applied to copies of the relay and
remote confs (PC5 channel) and/or the gNB conf (Uu channel). The local-only
sweep harness automates this, including decoupled Uu/PC5 noise axes:

```bash
# PC5 BLER sweep over BICTR_LUNAR (default), Uu backhaul pinned clean:
sudo bictr_analysis/run_montecarlo_slmode1.sh --mcs 9 --noise -4
# AWGN instead of BICTR:
sudo bictr_analysis/run_montecarlo_slmode1.sh --mcs 9 --noise -4 --channels AWGN --ploss 10
# Sweep the Uu axis instead, PC5 pinned:
sudo bictr_analysis/run_montecarlo_slmode1.sh --sweep-axis uu --mcs 9 --noise -10
```

BICTR runs require the DEM raster `bictr_terrain/lunar_south_pole.bdem`
(local-only, not in this repo) and store results on the `Log_Storage` drive.

## Verifying a run ##

```bash
grep -a 'PC5_RX_SUMMARY'        nearby_or_remote.log   # PC5 data BLER + HARQ rounds
grep -a 'PC5_PSSCH_SINR_SUMMARY' nearby_or_remote.log  # measured SINR axis
grep -a 'PC5_PSFCH_RX_TOTALS'   syncref_or_relay.log   # HARQ feedback ACK/NACK/DTX
grep -a 'UU_RX_SUMMARY'         relay.log              # Mode 1: relay Uu DL BLER
grep -a 'GNB_UL_SUMMARY'        gnb.log                # Mode 1: gNB UL BLER
```

Not all information is available in a central place, and information for
specific sub-systems might be available in the corresponding sub-directories.
To find all READMEs, this command might be handy:

```
find . -iname "readme*"
```

# RAN repository structure #

The OpenAirInterface (OAI) software is composed of the following parts: 

```
openairinterface5g
├── charts
├── ci-scripts        : Meta-scripts used by the OSA CI process. Contains also configuration files used day-to-day by CI.
├── CMakeLists.txt    : Top-level CMakeLists.txt for building
├── cmake_targets     : Build utilities to compile (simulation, emulation and real-time platforms), and generated build files.
├── common            : Some common OAI utilities, some other tools can be found at openair2/UTILS.
├── doc               : Documentation
├── docker            : Dockerfiles to build for Ubuntu and RHEL
├── executables       : Top-level executable source files (gNB, eNB, ...)
├── maketags          : Script to generate emacs tags.
├── nfapi             : (n)FAPI code for MAC-PHY interface
├── openair1          : 3GPP LTE Rel-10/12 PHY layer / 3GPP NR Rel-15 layer. A local Readme file provides more details.
├── openair2          : 3GPP LTE Rel-10 RLC/MAC/PDCP/RRC/X2AP + LTE Rel-14 M2AP implementation. Also 3GPP NR Rel-15 RLC/MAC/PDCP/RRC/X2AP.
├── openair3          : 3GPP LTE Rel10 for S1AP, NAS GTPV1-U for both ENB and UE.
├── openshift         : OpenShift helm charts for some deployment options of OAI
├── radio             : Drivers for various radios such as USRP, AW2S, RFsim, ...
└── targets           : Some configuration files; only historical relevance, and might be deleted in the future
```
