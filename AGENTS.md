# Agent Notes (open-bike-computer)

## Repository map

- `esp32/`: PlatformIO/Arduino firmware for the Waveshare 1.75-inch and
  2.06-inch ESP32-S3 devices, including LVGL, BLE navigation, SD map rendering,
  device settings, telemetry, audio, and firmware updates.
- `ios-app/`: SwiftUI companion app using MapKit, CoreBluetooth, and
  CoreLocation for route planning, navigation, device settings, firmware
  updates, and offline-map creation/download/installation.
- `map-platform/backend/`: FastAPI map platform with installation-scoped authentication,
  rate limits, persistent jobs, immutable artifacts, and separate API, worker,
  and maintenance processes.
- `map-platform/deploy/`: digest-pinned production Compose lock plus image
  validation and promotion tooling.
- `tools/OSM_Extract/`: Dockerized OSM/PBF extraction and vector-map pipeline
  used by the backend worker.
- `map-platform/config/`: checked-in map-stream trust, rollout approval, and hardware-gate
  configuration.
- `hardware/`: authoritative Waveshare pinouts, board findings, schematics,
  datasheets, and physical validation records. Read `hardware/README.md` before
  changing board-specific firmware.
- `docs/`: protocol, rollout, and implementation documentation.

## Quick commands

### ESP32 firmware

Before the first build/upload/device-debug action in a task, ask which physical
device is connected. Do not assume 1.75 versus 2.06.

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_175
pio run -e WAVESHARE_AMOLED_206
pio device list
pio run -e WAVESHARE_AMOLED_175 -t upload --upload-port /dev/cu.usbmodemXXXX
pio device monitor -b 115200
```

Use the matching `WAVESHARE_AMOLED_206` environment for a 2.06-inch board. If
upload fails, hold BOOT (`GPIO0`) while reconnecting USB and retry.

### iOS app

Open `ios-app/BikeComputer/BikeComputer.xcodeproj`. Run the portable Swift
navigation/BLE tests with:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
```

The CI build shape is:

```sh
cd ios-app
xcodebuild -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

### Map backend

```sh
cd map-platform/backend
python -m pip install -e '.[api,test,object-storage]'
python -m unittest discover -s tests
python -m unittest discover -s ../deploy/tests
MAP_PLATFORM_INSTALLATION_SECRET='local-development-secret-at-least-32-bytes' \
  uvicorn --factory map_platform.api:create_app --reload --port 8080
```

See `map-platform/backend/README.md` for local API/worker commands and
`map-platform/deploy/README.md` for production promotion and rollback.

## App/backend authentication contract

The production map endpoint is defined by
`OfflineMapServiceConfig.productionServerURLString` in the iOS app. The public
app must not contain a server-wide API key: it obtains an installation-scoped
credential from `POST /v1/installations`, stores it in the Keychain, and uses it
only for that installation's resources. Public issuance and map operations are
protected by persistent server-side limits. Preserve this model when changing
the app or backend.

Coordinate request/response changes across `map-platform/backend/map_platform/`,
`ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift`, and
`ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift`, with tests
on both sides.

## Production map backend updates

For changes under `map-platform/backend/` or other image inputs listed in
`.github/workflows/map-platform-image.yml`:

1. Merge the code through a pull request to `main`; do not deploy `:latest` or
   change server-side image-selection variables.
2. Wait for **Map Platform Image** to publish and attest the image, then review
   the generated `deploy/map-platform-production` pull request. Production is
   defined by the immutable digest pins in `map-platform/deploy/compose.yaml`.
3. If the promotion moves the signed worker, complete the worker/hardware gates
   in `docs/map-stream-rollout-runbook.md`. Merge only after **Map Backend** CI
   passes; the manifest merge triggers the production deployment.
4. Verify the deployment and `/healthz`. Roll back through a pull request that
   restores the complete previous Compose lock, including both image anchors
   and both source markers.

If promotion automation needs an explicit pending-worker decision, follow
`map-platform/deploy/README.md`; never bypass the digest/provenance checks.

## BLE contract

Hardware documentation does not replace the cross-device protocol contract.
Treat `docs/ble-protocol.md` as the source of truth instead of duplicating UUIDs
here. When changing BLE services, characteristics, framing, or payloads, update
the firmware implementation under `esp32/lib/ble_navigation/`, the iOS
implementation in `BLEManager.swift` and `NavigationProtocol.swift`, the
relevant host/Swift tests, and the protocol document in the same change.
