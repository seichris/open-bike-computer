#!/bin/bash
# Fetch the pinned Natural Earth layers and write the territory audit's inventory.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run

boundaries=$BICINO_AUDIT/boundaries
places=$BICINO_AUDIT/ne_10m_populated_places_simple.geojson
mkdir -p "$boundaries"

# coverage.json pins the boundary layers, coverage_audit.py the places layer.
python3 - "$BICINO_ROUTING" > "$BICINO_AUDIT/downloads.txt" <<'PY'
import json, sys
from pathlib import Path
routing = Path(sys.argv[1])
sys.path.insert(0, str(routing))
import coverage_audit
policy = json.loads((routing / "coverage.json").read_text())
for name, sha256 in policy["boundaryFiles"].items():
    print(f"boundaries/{name}", sha256, policy["boundaryBaseUrl"] + name)
name = "ne_10m_populated_places_simple.geojson"
print(name, coverage_audit.PLACES_SHA256, policy["boundaryBaseUrl"] + name)
PY
while read -r target sha256 url; do
  if ! echo "$sha256  $BICINO_AUDIT/$target" | sha256sum -c --quiet 2>/dev/null; then
    curl -fsSL --retry 10 --retry-delay 5 --retry-all-errors -o "$BICINO_AUDIT/$target" "$url"
    echo "$sha256  $BICINO_AUDIT/$target" | sha256sum -c
  fi
done < "$BICINO_AUDIT/downloads.txt"

docker run --rm --init --platform "$BICINO_PLATFORM" --network none -u "$(id -u):$(id -g)" \
  --label "bicino.stage=$BICINO_STAGE" \
  -v "$BICINO_ROUTING:/routing:ro" -v "$BICINO_AUDIT:/audit:ro" \
  --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" \
  /routing/coverage_audit.py generate --all-units --boundaries /audit/boundaries \
  --places "/audit/${places##*/}" > "$BICINO_AUDIT/inventory-all-units.json.partial"
mv "$BICINO_AUDIT/inventory-all-units.json.partial" "$BICINO_AUDIT/inventory-all-units.json"
python3 -c 'import json, sys; print("audit inventory:", len(json.load(open(sys.argv[1]))["units"]), "units")' \
  "$BICINO_AUDIT/inventory-all-units.json"
