#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 --device <identifier> --bundle-id <LetItRide.BikeComputer|LetItRide.BikeComputer.dev> [--destination <dir>]" >&2
  exit 64
}

DEVICE_ID=""
BUNDLE_ID=""
DESTINATION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || usage
      DEVICE_ID="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || usage
      BUNDLE_ID="$2"
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || usage
      DESTINATION="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "${DEVICE_ID}" && -n "${BUNDLE_ID}" ]] || usage
case "${BUNDLE_ID}" in
  LetItRide.BikeComputer|LetItRide.BikeComputer.dev) ;;
  *)
    echo "unsupported bundle id: ${BUNDLE_ID}" >&2
    exit 64
    ;;
esac

if [[ -z "${DESTINATION}" ]]; then
  DESTINATION="$(mktemp -d "${TMPDIR:-/tmp}/bicino-ride-diagnostics.XXXXXX")"
else
  mkdir -p "${DESTINATION}"
fi

JSON_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/bicino-devicectl.XXXXXX.json")"
trap 'rm -f "${JSON_OUTPUT}"' EXIT

SOURCE="Library/Application Support/BicinoDiagnostics/v1"
xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source "${SOURCE}" \
  --destination "${DESTINATION}" \
  --remove-existing-content false \
  --json-output "${JSON_OUTPUT}"

python3 - "${JSON_OUTPUT}" "${DESTINATION}" "${SOURCE}" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
source = pathlib.Path(sys.argv[3])
payload = json.loads(result_path.read_text())

def failed_copy(value):
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower()
            if normalized in {"error", "errors", "failure", "failures"} and child:
                return True
            if normalized in {"status", "state"} and isinstance(child, str) and child.lower() in {
                "failed", "failure", "error"
            }:
                return True
            if failed_copy(child):
                return True
    elif isinstance(value, list):
        return any(failed_copy(child) for child in value)
    return False

if failed_copy(payload):
    raise SystemExit("devicectl reported a failed copy; inspect JSON output")

root = destination / source
if not root.is_dir():
    raise SystemExit(f"diagnostics root was not copied: {root}")
streams = sorted(root.rglob("*.jsonl"))
if not streams:
    raise SystemExit("copied diagnostics root contains no JSONL streams")
for stream in streams:
    for index, line in enumerate(stream.read_bytes().splitlines(), 1):
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid JSON at {stream}:{index}: {exc}")
        if event.get("schema") != 1 or event.get("source") not in {"ios", "firmware", "host"}:
            raise SystemExit(f"unsupported event at {stream}:{index}")
print(f"copied and validated {len(streams)} JSONL stream(s) under {root}")
PY

echo "Ride diagnostics collected at ${DESTINATION}"
