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
  if [[ -e "${DESTINATION}" && ( ! -d "${DESTINATION}" || -n "$(find "${DESTINATION}" -mindepth 1 -maxdepth 1 -print -quit)" ) ]]; then
    echo "destination must be a new or empty directory: ${DESTINATION}" >&2
    exit 64
  fi
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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "${JSON_OUTPUT}" "${DESTINATION}" "${SOURCE}" "${REPO_ROOT}/tools" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
source = pathlib.Path(sys.argv[3])
sys.path.insert(0, sys.argv[4])
import ride_diagnostics
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

legacy_device_root = root / "imported-device"
canonical_device_root = root / "device"
if legacy_device_root.exists():
    if canonical_device_root.exists():
        raise SystemExit(
            "copied diagnostics contain both imported-device/ and device/ trees"
        )
    legacy_device_root.replace(canonical_device_root)

validated_streams = []
sidecar_count = 0
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(root).as_posix()
    if not ride_diagnostics._safe_member(relative) or not (
        ride_diagnostics._supported_bundle_member(relative)
    ):
        raise SystemExit(
            f"unsupported or noncanonical diagnostics member: {relative}"
        )
    if relative in {"manifest.json", "checksums.sha256"}:
        raise SystemExit(
            f"archive-only member is not valid in copied diagnostics: {relative}"
        )
    raw = path.read_bytes()
    if len(raw) > ride_diagnostics.MAX_ENTRY_BYTES:
        raise SystemExit(f"{relative} exceeds entry size limit")
    try:
        if relative.endswith(".jsonl"):
            expected_source = (
                "firmware" if relative.startswith("device/") else "ios"
            )
            validated_streams.append(ride_diagnostics.validate_jsonl(
                raw,
                relative,
                expected_source,
            ))
        else:
            value = json.loads(raw)
            ride_diagnostics._check_privacy(value, path=relative)
            ride_diagnostics._validate_json_sidecar(relative, value)
            sidecar_count += 1
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise SystemExit(f"{relative} is invalid JSON: {exc}")
    except ride_diagnostics.DiagnosticError as exc:
        raise SystemExit(str(exc))
if not validated_streams:
    raise SystemExit("copied diagnostics root contains no JSONL streams")
try:
    ride_diagnostics._validate_stream_boundaries(validated_streams)
except ride_diagnostics.DiagnosticError as exc:
    raise SystemExit(str(exc))
event_count = sum(len(stream.events) for stream in validated_streams)
print(
    f"copied and validated {len(validated_streams)} JSONL stream(s), "
    f"{sidecar_count} JSON sidecar(s), {event_count} event(s) under {root}"
)
PY

echo "Ride diagnostics collected at ${DESTINATION}"
