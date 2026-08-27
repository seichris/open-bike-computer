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
- [Firmware build and upload provenance](firmware-build-provenance.md)
- [Firmware factory release process](firmware-factory-release.md)
- [Firmware runtime maintenance and publication](firmware-runtime-maintenance.md)
- [Remote device debugging](remote-device-debugging.md)
- [Waveshare AMOLED 2.06 audio bring-up](waveshare-amoled-206-audio-bringup.md)
- [App Store privacy disclosures](app-store-privacy-disclosures.md)

## Implementation plans

| Plan | Status |
| --- | --- |
| [iPhone MapKit appearance switcher](plans/iphone-mapkit-appearance-switcher-implementation-plan.md) | Implemented in software; simulator and physical validation pending |
| [Opportunistic Bicino discovery and single-session BLE scanning](plans/opportunistic-bicino-discovery-implementation-plan.md) | Implemented in software; physical validation pending |
| [Geofabrik/OSM 3D buildings](plans/geofabrik-osm-3d-buildings-implementation-plan.md) | Implemented; physical rendering validated on the 1.75-inch device |
| [Cycling sensor settings and workout tile gating](plans/cycling-sensor-settings-implementation-plan.md) | Implemented slice; direct ESP32 sensor support remains in [issue #85](https://github.com/seichris/open-bike-computer/issues/85) |
| [iPhone interactive workout Live Activity](plans/iphone-workout-live-activity-implementation-plan.md) | Implemented |
| [Two-finger map zoom](plans/two-finger-map-zoom-implementation-plan.md) | Implemented; physical two-contact acceptance remains documented in the plan |
| [Watch + Bicino online and offline navigation](plans/watch-bicino-online-offline-navigation-implementation-plan.md) | Implemented in software; physical and provider-policy release gates remain open; tracks [issue #106](https://github.com/seichris/open-bike-computer/issues/106) |
| [Watch + Bicino navigation release notes](watch-bicino-navigation-release-notes.md) | Draft release copy and release blockers |
| [watchOS workout companion](plans/watchos-workout-companion-implementation-plan.md) | Implemented |
| [Firmware runtime, core cache, SD, and maintenance hardening](plans/firmware-runtime-cache-sd-hardening-implementation-plan.md) | Software implementation split across [#222](https://github.com/seichris/open-bike-computer/pull/222), [#223](https://github.com/seichris/open-bike-computer/pull/223), [#228](https://github.com/seichris/open-bike-computer/pull/228), [#229](https://github.com/seichris/open-bike-computer/pull/229), [#231](https://github.com/seichris/open-bike-computer/pull/231), and [#232](https://github.com/seichris/open-bike-computer/pull/232); physical SD/audio acceptance remains open |
| [Pioarduino first-run Python supply-chain hardening reconciliation](plans/pioarduino-wheelhouse-hardening.md) | Mandatory wheelhouse gap implemented by [#228](https://github.com/seichris/open-bike-computer/pull/228) and [#229](https://github.com/seichris/open-bike-computer/pull/229); document tracks the as-built boundary and long-term maintenance gates |
| [Bicino real-device browser debugging](plans/bicino-real-device-browser-debugging-implementation-plan.md) | Implemented in branch; two-target physical validation pending |

## Releases

- [watchOS workout companion](releases/watchos-workout-companion.md)

Machine-readable test vectors and example reports remain alongside the documents
that define their formats.
