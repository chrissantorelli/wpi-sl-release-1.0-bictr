#!/usr/bin/env bash
#
# Build (optional) and run a Monte Carlo BLER sweep inside the oai-montecarlo
# container with the right mounts and capabilities.
#
# Single-worker (default — runs run_montecarlo.sh):
#   ./docker-run-montecarlo.sh --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90
#   ./docker-run-montecarlo.sh --build --mcs 16 --noise 0 --trials 1 --target-tx 50
#   ./docker-run-montecarlo.sh --build --trials 1000 --target-tx 1000 --warmup 15 --duration 600
#
# Parallel sweep (runs run_montecarlo_parallel_slmode1_lunar.sh with per-worker
# Linux netns isolation — adds CAP_SYS_ADMIN + AppArmor opt-out so `ip netns
# add` and the bind-mount it performs are allowed inside the container):
#   ./docker-run-montecarlo.sh --parallel --workers 4 --trials 10 --target-tx 1000
#   ./docker-run-montecarlo.sh --build --parallel --workers 4 --trials 1000 --target-tx 1000 --early-stop 3
#
# Flags consumed by THIS wrapper (everything else passes through to the inner script):
#   --build      Rebuild the oai-montecarlo image before running.
#   --parallel   Use run_montecarlo_parallel_slmode1_lunar.sh (multi-worker, netns).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${OAI_MONTECARLO_IMAGE:-oai-montecarlo:latest}"
BUILD=0
PARALLEL=0

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --build)    BUILD=1 ;;
    --parallel) PARALLEL=1 ;;
    *)          ARGS+=("$arg") ;;
  esac
done

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building ${IMAGE} (Ubuntu 24.04, OAI RFSim + BICTR) ..."
  docker build -f "${REPO_ROOT}/Dockerfile.montecarlo" -t "${IMAGE}" "${REPO_ROOT}"
fi

mkdir -p "${SCRIPT_DIR}/montecarlo_results" "${SCRIPT_DIR}/phytest_rrc"

if [[ ${#ARGS[@]} -eq 0 ]]; then
  echo "ERROR: pass sweep options after --build / --parallel (if used)." >&2
  if [[ "$PARALLEL" -eq 1 ]]; then
    echo "Example: $0 --parallel --workers 4 --trials 10 --target-tx 1000" >&2
  else
    echo "Example: $0 --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90" >&2
  fi
  exit 1
fi

# Quote args for bash -lc inside the container.
quoted_args=""
for a in "${ARGS[@]}"; do
  quoted_args+=" $(printf '%q' "$a")"
done

# Caps + security opts:
#   SYS_NICE   : OAI sets realtime priorities on its threads.
#   NET_ADMIN  : OAI creates TUN devices for PDCP (oaitun_*) in noS1 mode.
#   SYS_ADMIN  : `ip netns add` does unshare(CLONE_NEWNET) + bind-mount of
#                /proc/<pid>/ns/net -> /var/run/netns/<name>. Both need this.
#                Only added in --parallel mode (least-privilege otherwise).
#   apparmor=unconfined : Docker's default AppArmor profile denies the mount
#                syscall used by `ip netns add` even with CAP_SYS_ADMIN.
DOCKER_CAPS=(--cap-add=SYS_NICE --cap-add=NET_ADMIN)
DOCKER_SECOPTS=()
if [[ "$PARALLEL" -eq 1 ]]; then
  DOCKER_CAPS+=(--cap-add=SYS_ADMIN)
  DOCKER_SECOPTS+=(--security-opt apparmor=unconfined)
fi

if [[ "$PARALLEL" -eq 1 ]]; then
  INNER_SCRIPT="./run_montecarlo_parallel_slmode1_lunar.sh"
else
  INNER_SCRIPT="./run_montecarlo.sh"
fi

# When the container is started by an unprivileged host user, the script needs
# to run as root inside (it enforces EUID==0 for sudo-equivalent operations).
# `docker run` defaults to root unless --user is set, so no extra flag needed.

docker run --rm -it \
  --shm-size=2g \
  "${DOCKER_CAPS[@]}" \
  "${DOCKER_SECOPTS[@]}" \
  --device /dev/net/tun:/dev/net/tun \
  -v "${REPO_ROOT}/bictr_terrain:/opt/openairinterface5g/bictr_terrain:ro" \
  -v "${SCRIPT_DIR}:/opt/openairinterface5g/bictr_analysis" \
  "${IMAGE}" \
  bash -lc "cd /opt/openairinterface5g/bictr_analysis && ${INNER_SCRIPT}${quoted_args}"
