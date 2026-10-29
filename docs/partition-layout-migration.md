# Partition layout generations and the dual-4-MiB migration

This runbook implements the layout decision from
[issue #461](https://github.com/seichris/open-bike-computer/issues/461): dual
4 MiB production OTA slots, 7 MiB internal FFat and the unchanged 960 KiB
coredump on 16 MiB flash. It covers builds, OTA, signed USB recovery, the USB
migration, FFat data handling and the remaining physical gates. Software tests
and green CI are not physical qualification.

## Decision

The production application was within 67,696 bytes (1.75-inch) and 74,384 bytes
(2.06-inch) of the enforced 64 KiB reserve at `v0.3.4-release.13` (build 105:
3,012,496 and 3,005,808 bytes). Dual 4 MiB slots add 1,048,576 bytes of safe
growth per image. Nothing currently requires more than 4 MiB, and 5 MiB slots
would cut FFat to 5 MiB. FFat no longer holds maps (#632); it keeps diagnostics
recorded without an SD card (1 MiB retention, 2 MiB free floor, 256 KiB chunks;
#464) and other device files, so 7 MiB is a credible budget. Fleet FFat
occupancy has not been measured; legacy devices may still carry unused map files
there.

## Layout registry

[`esp32/partition_layouts.json`](../esp32/partition_layouts.json) is the only
numeric source. `esp32/tools/partition_layouts.py` validates it, renders the
exact `gen_esp32part.py` binary table, parses tables strictly and checks the
PlatformIO CSVs. The website keeps a byte-identical copy as a test fixture.

| Generation | Layout id | Role | app0 | app1 | FFat | Table SHA-256 |
|---|---|---|---|---|---|---|
| 1 (legacy) | `esp32s3-16m-dual3m-ffat9m-v1` | production | `0x10000`/3 MiB | `0x310000`/3 MiB | `0x610000`/9 MiB | `6d6e1059…cbbf` |
| 1 (legacy) | `esp32s3-16m-single6m-ffat9m-v1` | development | `0x10000`/6 MiB | — | `0x610000`/9 MiB | `7dd5955a…c7ce` |
| 2 (current) | `esp32s3-16m-dual4m-ffat7m-v1` | production | `0x10000`/4 MiB | `0x410000`/4 MiB | `0x810000`/7 MiB | `60ec28f8…dea1` |
| 2 (current) | `esp32s3-16m-single8m-ffat7m-v1` | development | `0x10000`/8 MiB | — | `0x810000`/7 MiB | `cf7f29eb…7364` |

Every layout keeps NVS at `0x9000`/20 KiB, OTA data at `0xE000`/8 KiB and the
coredump at `0xF10000`/960 KiB. The two legacy table hashes are not derived
assumptions: they equal the table signed in `v0.3.4-release.13`'s web recovery
manifests and the `partitions.bin` of a CI-built developer profile. Published
layouts are immutable; a change gets a new id.

Both FFat generations end at `0xF10000`. Replacing a legacy table without an
explicit FFat recreate therefore leaves the old filesystem's last 7 MiB,
including its wear-levelling metadata, underneath the new partition.

## Builds and profiles

`partitions.csv` is the current production layout and
`partitions_remote_debug.csv` the current development layout; only these two
CSVs exist. The legacy generation lives in the registry for recovery, migration
and channel decisions. `test_firmware_profile_config.py` requires every
`WAVESHARE_AMOLED_*`/`WAVESHARE_EPAPER_*` environment to resolve a current
layout, and production, lifecycle, personal and USB-recovery profiles to resolve
the production layout. Current profiles share FFat, so switching between them
over USB never relocates it.

The locked build helper rejects any built `partitions.bin` that is not a current
registered table, any `_PRODUCTION` or `_LIFECYCLE_QUALIFICATION` build without
the production layout, and any production-behavior image that leaves less than
64 KiB in its slot (now `4,128,768` bytes maximum).

Flashing a generation-2 developer image onto a generation-1 board relocates
FFat. The firmware then refuses to touch the stale bytes (below), so internal
storage stays unavailable on no-card boots until it is explicitly recreated:
erase the span once (`erase_region 0x810000 0x700000` with the board's esptool)
or use the signed browser migration on a production layout. Never flash
generation-1 firmware onto a migrated board: older firmware formats FFat on any
mount failure.

## FFat data policy

Moving FFat cannot preserve a 9 MiB filesystem in a 7 MiB partition at another
offset, and the browser never reads user files. The migration keeps:

- NVS bytes: ownership, TLS identity, settings, calibration, OTA receipts;
- the coredump partition;
- everything on the removable SD card, which the migration never touches.

It permanently erases internal FFat (diagnostics recorded without a card, GPX
waypoint/track files and unused legacy map files) and the old rollback image.
Export internal diagnostics first if they matter: boot without the SD card and
use the app's diagnostics export. The website shows this impact and requires an
explicit acknowledgement; it offers no partial preservation.

Firmware never lets an FFat mount silently perform a migration.
`Storage::initSPIFFS()` classifies the raw partition before the first mount
attempt, because even a mount without format rewrites wear-levelling metadata
it does not recognise:

| Raw state | Ownership evidence | Action |
|---|---|---|
| fully erased | any | record the geometry in NVS, then format; no format if the record cannot be written |
| data | NVS record for this exact offset/size | mount; on failure reformat (previous corruption recovery) |
| data | no record, but a valid wear-levelling state at this geometry | adopt: mount, record; on failure reformat |
| data | no record and no valid state at this geometry | do not mount; run without FFat |
| data | record for another offset/size | do not mount; run without FFat |

The record is `ffat_layout/geometry` in NVS. Recording before the first format
means an interrupted first format is recognised as this device's volume and
reformatted on the next boot. Wear-levelling state is read exactly as ESP-IDF
5.5 writes it (`esp32/lib/storage/wear_levelling_state.hpp`, cross-checked with
states built like IDF's `wl_fatfsgen.py`). A dual-3-MiB device updated over the
air therefore adopts its existing volume, while old data shifted under a
replaced table (its state lies at other offsets) and vendor leftovers are
neither mounted nor formatted. The `STORAGE_FFAT` log line reports the decision.
Factory programming must start from an erased chip or erase FFat.

## OTA on existing devices

OTA never rewrites the partition table. A legacy device keeps dual 3 MiB slots,
and firmware from this generation runs there while its image fits. The device
rejects `size > inactive slot` in `/firmware-update/begin` before
`esp_ota_begin` erases anything, and `DSTS` reports the inactive slot in
`firmware.maxImageBytes`. A single-slot developer layout reports
`otaEligible=false`; its `maxImageBytes` is the running slot and is ignored.

The protected publisher stages two GitHub Pages channels per target with
`tools/firmware_ota_channels.py`:

- `firmware/<target>/dual4m/manifest.json`: every release;
- `firmware/<target>/manifest.json`: the newest release whose image fits a
  dual-3-MiB slot with its reserve. Apps that predate this change read only this
  path and keep receiving compatible updates.

When an image outgrows 3,080,192 bytes, the legacy channel keeps serving exactly
the manifest it serves now. The publisher reads it back from Pages and requires
it to equal a fitting, digest-verified manifest of an immutable published
release, so a channel rolled back with Pages recovery is never re-advanced to a
withdrawn release; otherwise publication fails closed. Pages recovery stages
both channels the same way and never points the legacy channel past the
recovered build. To recover an oversized release while the legacy channel is
broken, first recover the intended fitting release.

The app selects a channel from the device's fresh `DSTS` capacity, never from
its version or build: a 4 MiB slot prefers `dual4m` and falls back to the legacy
channel while no dual-4-MiB release exists; 3 MiB, unknown and ineligible
reports use the legacy channel. It checks `size <= slot - 64 KiB` against the
fresh `DSTS` before downloading and against the maintenance HTTP status before
`begin`, and rejects with `layoutMigrationRequired` without writing. Legacy
devices see a "Storage Layout Update" notice when the dual-4-MiB channel has a
newer build that does not fit. The signed OTA manifest format is unchanged.

## Signed USB packages

`tools/web_flasher_manifest.py` emits, per target and release, from the attested
factory bundle (which must carry the current production table):

| Asset | Contract |
|---|---|
| `<target>.web-recovery.json` | Unchanged dual-3-MiB rescue, `minFlasherVersion=2`, automatic admission; only while the image fits 3 MiB with its reserve |
| `<target>.web-recovery-dual4m.json` | Same app0 + OTA-selection rescue for dual-4-MiB tables, `minFlasherVersion=3` |
| `<target>.web-migration-dual3m-dual4m.json` | `bicino-web-migration`, `minFlasherVersion=3`, `qualificationRequired=true` |
| `<target>.web-<sha256>.bin` | Content-addressed application, OTA bootstrap and destination table |

Existing website builds keep rescuing legacy devices from new releases through
the unchanged asset name; they reject the new manifests by schema. Every package
binds target, production profile, full SHA, version/build, chip, 16 MiB, exact
bootloader and table hashes, and factory archive/descriptor provenance, and is
signed with the existing release key under the `bicino-web-flasher-v1` domain.
`tools/web-flasher/migration-test-vector.json` is the shared public-test-key
fixture; never admit it as a release.

### Migration recipe

The website admits a migration only for the exact legacy table and the package's
bootloader, with the same chip/capacity/security, model and downgrade checks as
recovery. Writes run in this order, each read back by SHA-256 before the next:

1. app0 at `0x10000`: the release image;
2. OTA selection at `0xE000`: the pinned Arduino bootstrap (sequence 1, app0);
3. erase app1 `0x410000`-`0x810000`;
4. erase FFat `0x810000`-`0xF10000`;
5. destination table at `0x8000` (3072 bytes in its 4 KiB sector), the commit.

Bootloader `0x0`-`0x8000`, NVS `0x9000`-`0xE000` and coredump
`0xF10000`-`0x1000000` are outside every erase span; the producer and the
website both enforce that. Device identity, bootloader, table and OTA data are
rechecked between steps.

Interruption behavior:

- Before step 5 the legacy table is active. After steps 1-2 a fitting image
  boots on the legacy layout with the old FFat; after steps 3-4 FFat is erased
  (or, when step 4 was cut short, refused). An image above 3 MiB does not boot
  until the migration finishes. Retry restarts from the legacy table; every step
  is idempotent.
- During step 5 the table may be erased or partial and nothing boots. A fresh
  session resumes only if app0, OTA selection and both erased spans already read
  back exactly; otherwise the page refuses with a concrete explanation.
- After step 5 the device boots the new image on the new layout and formats the
  erased FFat on its next no-card boot. The migration package then refuses the
  device; the dual-4-MiB recovery package applies.

The ROM download mode always remains available (hold BOOT while reconnecting
USB). Damaged bootloaders and unknown tables are not migrated or guessed.

### OTA receipts

An Accepted firmware-operation receipt (lifecycle-qualification profiles only)
survives in NVS. After USB recovery or migration it can name a legacy slot
(`0x310000`) or app0 holding different bytes. Once the running image is
accepted, such receipts now resolve to Failed and can be acknowledged; a
pending-verify OTA boot must still prove its exact bytes before confirmation.

## Device states

| State | OTA | USB |
|---|---|---|
| Legacy dual-3-MiB | Legacy channel; images up to 3,080,192 bytes | Legacy rescue while the image fits; migration once qualified |
| Legacy developer 6 MiB | Not OTA-eligible | Developer flashing; FFat relocates (see above) |
| Migrated dual-4-MiB | `dual4m` channel; up to 4,128,768 bytes | Dual-4-MiB rescue |
| Current developer 8 MiB | Not OTA-eligible | Developer flashing |
| Unknown, malformed or erased table | Not offered | Refused, except a verified interrupted step-5 resume |

## Physical qualification gates (each board separately)

Nothing here has run on hardware. Keep the migration package unadmitted (no
website catalog entry) until all of these pass on both the 1.75-inch and
2.06-inch boards with exact release bytes:

1. USB migration from a legacy production device: every step's readback, then
   read-only verification of the destination table and bootloader.
2. Preservation: owner authentication, TLS identity and settings work after
   migration; SD maps and files are intact.
3. FFat: no-card boot formats exactly once (`STORAGE_FFAT` erased/plan 0), and
   diagnostics record and export afterwards; a no-card boot without data loss
   on a device that kept its legacy layout.
4. OTA into app1 (`0x410000`) and back into app0 on the new layout, with
   boot confirmation and forced rollback.
5. True cold boot (USB and battery disconnected) on the migrated layout.
6. Interruption: USB detach and power loss during each step, including the
   table write, followed by a fresh-session retry or verified resume.
7. A legacy device receiving a fitting release over the legacy channel, and the
   app's rejection and notice for an oversized one.

Record the board model, serial, release tag, manifest and image hashes, website
and firmware commits, and every readback result, as in
[USB recovery](usb-firmware-recovery.md). Only then add the migration manifest
digest to the website catalog's qualified packages.
