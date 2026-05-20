#!/usr/bin/env bash
#
# Export oai-montecarlo:latest and runtime mount files for use on another host.
#
# Usage:
#   ./docker-export-montecarlo.sh
#   ./docker-export-montecarlo.sh /path/to/output/dir
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${OAI_MONTECARLO_IMAGE:-oai-montecarlo:latest}"
OUT_DIR="${1:-$REPO_ROOT}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: image '$IMAGE' not found. Build first:" >&2
  echo "  docker build -f $REPO_ROOT/Dockerfile.montecarlo -t $IMAGE $REPO_ROOT" >&2
  exit 1
fi

if [[ ! -f "$REPO_ROOT/bictr_terrain/lunar_south_pole.bdem" ]]; then
  echo "ERROR: missing $REPO_ROOT/bictr_terrain/lunar_south_pole.bdem" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
IMG_TAR="$OUT_DIR/oai-montecarlo_latest.tar.gz"
RUNTIME_TAR="$OUT_DIR/bictr-montecarlo-runtime.tgz"

echo "Saving Docker image $IMAGE -> $IMG_TAR"
docker save "$IMAGE" | gzip -1 > "$IMG_TAR"

echo "Packing runtime mounts -> $RUNTIME_TAR"
tar czf "$RUNTIME_TAR" -C "$REPO_ROOT" \
  bictr_analysis/docker-run-montecarlo.sh \
  bictr_analysis/docker-export-montecarlo.sh \
  bictr_analysis/run_montecarlo.sh \
  bictr_analysis/run_montecarlo_single_mcs.sh \
  bictr_analysis/run_montecarlo_parallel_slmode1_lunar.sh \
  bictr_analysis/montecarlo_parallel_progress.py \
  bictr_analysis/parse_montecarlo_point.py \
  bictr_analysis/plot_montecarlo.py \
  bictr_analysis/merge_montecarlo_csv.py \
  bictr_analysis/phytest_rrc \
  bictr_analysis/snapshot.readme \
  bictr_analysis/README.docker.md \
  bictr_terrain/lunar_south_pole.bdem

echo ""
echo "Export complete:"
ls -lh "$IMG_TAR" "$RUNTIME_TAR"
echo ""
echo "On remote host:"
echo "  mkdir -p ~/openairinterface5g && cd ~/openairinterface5g"
echo "  gunzip -c $(basename "$IMG_TAR") | docker load"
echo "  tar xzf $(basename "$RUNTIME_TAR")"
echo "  sudo modprobe tun"
echo "  cd bictr_analysis"
echo "  # single-worker smoke test:"
echo "  ./docker-run-montecarlo.sh --mcs 16 --noise 0 --trials 1 --target-tx 50 --warmup 5 --duration 90"
echo "  # full parallel 1000x1000 sweep across 4 workers:"
echo "  ./docker-run-montecarlo.sh --parallel --workers 4 --trials 1000 --target-tx 1000 --warmup 15 --duration 600 --early-stop 3"
