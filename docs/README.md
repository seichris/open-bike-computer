# Documentation

## Protocols and formats

- [BLE protocol](ble-protocol.md)
- [Map-stream format v1](map-stream-format-v1.md)

## Guides and operations

- [Offline-map build and SD-card installation](offline-map-build-and-sd-install.md)
- [Map-stream rollout runbook](map-stream-rollout-runbook.md)
- [Firmware power management](firmware-power-management.md)
- [Firmware map memory diagnostics](firmware-map-memory-diagnostics.md)
- [Firmware OTA hardware validation](firmware-ota-hardware-validation.md)
- [Waveshare AMOLED 2.06 audio bring-up](waveshare-amoled-206-audio-bringup.md)
- [App Store privacy disclosures](app-store-privacy-disclosures.md)

## Implementation plans

| Plan | Status |
| --- | --- |
| [Geofabrik/OSM 3D buildings](plans/geofabrik-osm-3d-buildings-implementation-plan.md) | Implemented; physical rendering validated on the 1.75-inch device |
| [Cycling sensor settings and workout tile gating](plans/cycling-sensor-settings-implementation-plan.md) | Implemented slice; direct ESP32 sensor support remains in [issue #85](https://github.com/seichris/open-bike-computer/issues/85) |
| [iPhone interactive workout Live Activity](plans/iphone-workout-live-activity-implementation-plan.md) | Implemented |
| [Two-finger map zoom](plans/two-finger-map-zoom-implementation-plan.md) | Implemented; physical two-contact acceptance remains documented in the plan |
| [Watch + Bicino online and offline navigation](plans/watch-bicino-online-offline-navigation-implementation-plan.md) | Implemented in software; physical and provider-policy release gates remain open; tracks [issue #106](https://github.com/seichris/open-bike-computer/issues/106) |
| [Watch + Bicino navigation release notes](watch-bicino-navigation-release-notes.md) | Draft release copy and release blockers |
| [watchOS workout companion](plans/watchos-workout-companion-implementation-plan.md) | Implemented |

## Releases

- [watchOS workout companion](releases/watchos-workout-companion.md)

Machine-readable test vectors and example reports remain alongside the documents
that define their formats.
