#!/usr/bin/env bash
# Container entrypoint: optional DEM check, then exec the user command.
set -euo pipefail

OAI_ROOT="${OAI_ROOT:-/opt/openairinterface5g}"
DEM="${OAI_ROOT}/bictr_terrain/lunar_south_pole.bdem"

if [[ ! -f "$DEM" ]]; then
  echo "WARNING: ${DEM} not found." >&2
  echo "  Mount terrain at run time, e.g.:" >&2
  echo "    -v \"\$PWD/bictr_terrain:${OAI_ROOT}/bictr_terrain:ro\"" >&2
  echo "  BICTR will fall back to flat terrain if the DEM cannot be loaded." >&2
fi

# The parallel sweep wraps each worker in `ip netns exec`, which needs
# /var/run/netns to exist and be writable. Docker's overlay rootfs ships
# without it; create it idempotently so `ip netns add` works inside the
# container (CAP_SYS_ADMIN must also be granted at `docker run` time).
mkdir -p /var/run/netns

exec "$@"
