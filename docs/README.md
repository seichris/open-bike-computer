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

## Open plans and investigations

These documents still contain unfinished work. Completed software plans have
been removed; their design history remains available in Git.

| Plan | Remaining scope |
| --- | --- |
| [Topographic map support](plans/issue-190-topographic-map-support-implementation-plan.md) | Provider acquisition, datum verification, source approval and production/physical qualification; development implementation is documented in [the pipeline guide](topography-pipeline.md) |
| [Reusable map preparation](plans/issue-508-map-reuse-implementation-plan.md) | Worldwide source-preparation and measured acceptance; exact reuse and local source shards are on main |
| [Bluetooth data reliability architecture](plans/bluetooth-data-reliability-and-architecture-plan.md) | Further adapter migration, optional protocol extensions and measured tuning; DATA-01–04 repairs are on main |
| [Bluetooth reliability follow-ups](plans/bluetooth-reliability-follow-ups-2026-09-07.md) | Broader callback-identity audits, transport measurements and physical qualification |
| [Map-transfer Wi-Fi reliability](plans/map-transfer-wifi-startup-reliability-implementation-plan.md) | Retained physical failure/repair evidence and outstanding activation, resource-margin and both-board qualification |

## Implementation and validation records

- [Bluetooth data reliability implementation](plans/bluetooth-data-reliability-implementation.md)
- [Bluetooth reliability implementation and bundle review](plans/bluetooth-reliability-implementation-2026-09-07.md)
- [Historical Bluetooth reassessment](plans/bluetooth-reliability-reassessment-2026-09-06.md)
- [Stable map camera and qualification](map-stable-camera.md)
- [Watch navigation validation](watch-bicino-navigation-validation.md)
- [Watch navigation release notes and blockers](watch-bicino-navigation-release-notes.md)
- [Ride automation traces](ride-automation-traces.md)
- [Ride diagnostics format](ride-diagnostics-format.md)
- [Firmware OTA hardware validation](firmware-ota-hardware-validation.md)
- [Cloudflare R2 map library runbook](runbooks/cloudflare-r2-final-map-library.md)
- [Shanghai 3D orchestration runbook](runbooks/shanghai-3d-map-orchestration.md)

## Releases

- [watchOS workout companion](releases/watchos-workout-companion.md)

Machine-readable test vectors and example reports remain alongside the documents
that define their formats.
