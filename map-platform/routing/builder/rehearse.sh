#!/bin/bash
# Rehearse the build chain on one city sample with Docker, on any machine.
#
#   rehearse.sh --root /abs/scratch --city Berlin --radius 200 [rehearse.py options]
#
# It copies this checkout's map-platform tools to ROOT/tools/repo, as setup.sh
# checks them out on the builder, and runs rehearse.py in an Ubuntu container
# that reaches this host's Docker. ROOT is mounted at the same path inside,
# because the stage scripts hand their paths to the host's Docker. A city
# needs a few gigabytes below ROOT; see rehearse.py for what the run covers.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checkout=$(cd "$here/../../.." && pwd)
root=
arguments=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=${2:-}; shift 2 ;;
    *) arguments+=("$1"); shift ;;
  esac
done
case "$root" in
  /*) ;;
  *) echo "error: --root takes an absolute path" >&2; exit 64 ;;
esac

repo=$root/tools/repo
mkdir -p "$repo/map-platform/backend"
for part in routing config backend/map_platform; do
  rm -rf "${repo:?}/map-platform/$part"
  cp -R "$checkout/map-platform/$part" "$repo/map-platform/$part"
done
find "$repo" -name __pycache__ -type d -prune -exec rm -rf {} +

image=bicino-builder-rehearsal:1
docker build --quiet --tag "$image" --file "$here/rehearsal.Dockerfile" "$here" >/dev/null
exec docker run --rm --init \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$root:$root" \
  "$image" python3 "$repo/map-platform/routing/builder/rehearse.py" --root "$root" ${arguments[@]+"${arguments[@]}"}
