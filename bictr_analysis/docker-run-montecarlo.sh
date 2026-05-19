#!/usr/bin/env bash
#
# Build (optional) and run run_montecarlo.sh inside oai-montecarlo with correct mounts.
#
# Usage:
#   ./docker-run-montecarlo.sh --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90
#   ./docker-run-montecarlo.sh --build --mcs 16 --noise 0 --trials 1 --target-tx 50
#   ./docker-run-montecarlo.sh --build --trials 1000 --target-tx 1000 --warmup 15 --duration 600
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${OAI_MONTECARLO_IMAGE:-oai-montecarlo:latest}"
BUILD=0

ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--build" ]]; then
    BUILD=1
  else
    ARGS+=("$arg")
  fi
done

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building ${IMAGE} (Ubuntu 24.04, OAI RFSim + BICTR) ..."
  docker build -f "${REPO_ROOT}/Dockerfile.montecarlo" -t "${IMAGE}" "${REPO_ROOT}"
fi

mkdir -p "${SCRIPT_DIR}/montecarlo_results" "${SCRIPT_DIR}/phytest_rrc"

if [[ ${#ARGS[@]} -eq 0 ]]; then
  echo "ERROR: pass run_montecarlo.sh options after --build (if used)." >&2
  echo "Example: $0 --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90" >&2
  exit 1
fi

# Quote args for bash -lc inside the container.
quoted_args=""
for a in "${ARGS[@]}"; do
  quoted_args+=" $(printf '%q' "$a")"
done

docker run --rm -it \
  --shm-size=2g \
  --cap-add=SYS_NICE \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v "${REPO_ROOT}/bictr_terrain:/opt/openairinterface5g/bictr_terrain:ro" \
  -v "${SCRIPT_DIR}:/opt/openairinterface5g/bictr_analysis" \
  "${IMAGE}" \
  bash -lc "cd /opt/openairinterface5g/bictr_analysis && ./run_montecarlo.sh${quoted_args}"
