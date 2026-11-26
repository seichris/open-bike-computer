#!/bin/bash
# Pull the two pinned images every later stage runs, before anything needs them.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run

valhalla_image=$(bicino_valhalla_image)
mkdir -p "$BICINO_EVIDENCE"
: > "$BICINO_EVIDENCE/images.txt"
for image in "$valhalla_image" "$BICINO_MAP_PLATFORM_IMAGE"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull --quiet --platform "$BICINO_PLATFORM" "$image"
  fi
  docker image inspect --format "$image {{.Id}} {{.Architecture}}" "$image" | tee -a "$BICINO_EVIDENCE/images.txt"
done
