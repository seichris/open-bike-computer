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
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
pio device list
python3 tools/build_firmware.py WAVESHARE_AMOLED_175 \
  --upload-port /dev/cu.usbmodemXXXX
pio device monitor -b 115200
```

Use `tools/build_firmware.py` for build-only checks, upload, and CI. A clean
pioarduino installation first converts content-pinned tool wrappers into the
host compiler/runtime packages, then compiles a custom core against a generated
`.dummy` sketch. The helper detects both bootstrap transitions, switches to a
steady verified config after tool conversion, forces pioarduino's recursive
build through that config, rebuilds the requested source, and requires the
target `firmware.elf`. Direct
`pio run -e ... -t upload` is intentionally not the documented upload path:
PlatformIO reruns prebuild before upload, so the helper must preserve its narrow
generated-config allowance through that pass to keep the flashed Git identity
exact.

Use the matching `WAVESHARE_AMOLED_206` environment for a 2.06-inch board. If
upload fails, hold BOOT (`GPIO0`) while reconnecting USB and retry.

For a reproducible post-flash or cold-start capture, prefer the repository
helper over an interactive PlatformIO monitor. It waits for a disconnected
board to reappear and leaves RTS/DTR deasserted so the serial reader does not
hold the ESP32-S3 in reset:

```sh
cd esp32
python3 tools/capture_boot.py \
  --port '/dev/cu.usbmodem*' \
  --duration 40 \
  --expected-target WAVESHARE_AMOLED_175 \
  --expected-profile WAVESHARE_AMOLED_175 \
  --expected-git "$(git rev-parse HEAD)" \
  --require-cold-start \
  --confirm-all-power-removed \
  --require-pmic-read-only \
  --require-ready
```

Arm that command before reconnecting a fully unpowered device for a true
cold-start test. Disconnect both USB and battery first so the PMIC reloads its
power-on baseline; preserving rails cannot prove that a still-powered PMIC is
in factory state. `--confirm-all-power-removed` is the operator attestation for
that physical step; the helper requires it because a warm USB reset after an
RTC schema/checksum failure can produce the same empty history. A USB-only
ESP32-S3 cold start may report `reset=usb` instead of `reset=power_on`;
`--require-cold-start` accepts either only as supporting device evidence when
`BOOT_META sequence=1` and `BOOT_PREVIOUS` reports complete empty/invalid
retained history. Use `--expected-reset` when the exact reset cause matters. Use
`--reset` only when an intentional warm reset is wanted. Treat `BOOT_META` as the
running-image source of truth: target identifies OTA compatibility, while
profile distinguishes ordinary, production, metrics, light-sleep, and other
builds from the same Git SHA. Use `BOOT_PREVIOUS`/`BOOT_FAILURE` to locate an
interrupted setup stage; their fingerprint and failure-reset fields identify
the failed image and how it ended after rescue firmware is flashed. Require a
final `BOOT_STAGE ... event=ready` from the same boot sequence.
`--require-pmic-read-only` also requires schema-1 PMIC evidence, a successful
probe, status and LDO-state reads, and the explicit `current-preserved` rail
state; it is the 1.75-inch safety gate. For a 2.06-inch capture, use
`--require-pmic-display-enable-only`; it requires schema-1 evidence plus the
dedicated one-way display recovery and verified display-enable bit. Ready and
identity gates likewise reject unsupported boot-record schemas. Any
`AXP_WRITE_BLOCKED` or `BOOT_DIAGNOSTICS_ERROR` makes the capture helper fail
validation.

The pioarduino custom-core build creates `sdkconfig.defaults`, may create
`sdkconfig.<environment>`, and can populate `managed_components/` in `esp32/`.
`tools/build_firmware.py` serializes all deterministic builds/uploads for the
project and gives each PlatformIO environment private core/tool, package, platform,
global-library, download-cache, build-cache, ESP-IDF component-cache, and
component-manager configuration stores below
`.pio/open-bike-build/platformio/`. Another project or another profile therefore
cannot replace the effective custom core during validation or upload.

The helper preserves pioarduino's defaults cache only when it was produced from
the same exact clean Git commit and environment and its exact contents,
`platformio.ini`, generated environment-config state, full
`managed_components/` tree, pinned platform/build scripts and manifests, full
installed package, compiler, uploader, PlatformIO runtime, Arduino framework,
platform, and ESP32-S3 library trees still match. A cache miss, branch/commit
switch, dirty source tree, profile
change, generated-component edit, or installed-core change removes the generated
state and rebuilds it. Dirty builds remain available for diagnosis but do not
produce a reusable cache and cannot be uploaded through this exact-identity
path. Nested passes exclude only recognized generated SDK configs from the Git
identity.

The helper accepts `PLATFORMIO_CORE_DIR` (or the legacy
`PLATFORMIO_HOME_DIR`) only as an ambient value to restore afterward; the
subprocess always uses the profile-private PlatformIO core/tool store. Other
ambient `PLATFORMIO_*`, `IDF_COMPONENT_*`, ESP-IDF source/store/target overrides,
compiler/linker/CMake injection variables, legacy component-manager aliases,
and `ICENAV3_LAT`/`ICENAV3_LON` are rejected; all other nonessential ambient
values are scrubbed from the build subprocess. Put deliberate flags and inputs
in a named, tracked environment in `platformio.ini`. The helper downloads the
pioarduino release and every tracked PlatformIO executable-package bootstrap to
its private store, verifies their tracked sizes and SHA-256 values before those
package payloads execute, seeds the exact SCons runtime, forces the bootstrap and every recursive
custom-core pass through generated local project configs, and enables strict
component checksums. Project-level PlatformIO directory overrides and
`extra_configs` likewise disable cache/upload attestation. The emitted
`coreAttestationSha256` summarizes the PlatformIO-installed package, tool,
nested-runtime, platform, framework, private global-library, and core-board
state after bootstrap. It does not cover the host Python interpreter, top-level
`pio` launcher, or pioarduino's first-run online Python dependency resolver
(including its package registries, external `uv`, private `penv`, and ESP-IDF
venv before their resulting trees are attested); those remain part of the
trusted workstation or CI boundary. The attestation detects later mutation or
cache reuse of those installed trees, but it is not a pre-execution Python
supply-chain proof. Raw Waveshare
PlatformIO builds fail with a pointer to the helper; raw legacy-board builds are
stamped `unverified-...` rather than advertising an exact Git SHA. AMOLED upload
rechecks the clean source identity, generated state, managed components,
profile-private library dependencies, isolated installed-core attestation, and
the exact ELF and binary while holding the project-wide lock, then invokes
PlatformIO's `nobuild` upload target so it cannot relink different bytes. Keep the
structured `FIRMWARE_BUILD_PROVENANCE` and
`FIRMWARE_UPLOAD_PROVENANCE` lines with test notes. The upload marker is a
preflight record of the eligible USB-upload inputs: firmware binary/ELF,
bootloader, partition table, OTA bootstrap, platform/package archives,
library dependencies, and managed components. A successful command means
PlatformIO accepted the upload. A later `BOOT_META` independently confirms the
embedded Git/profile identity; it does not contain those SHA-256 values or prove
on-device byte equality. Flash readback or a runtime image digest is required
for that stronger claim.

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
