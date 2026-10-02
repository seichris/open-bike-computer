# Web USB firmware recovery implementation plan

Status: original implementation plan. See [implementation and remaining gates](usb-firmware-recovery.md) for current progress; physical qualification is pending.

Tracks [issue #483](https://github.com/seichris/open-bike-computer/issues/483).
Partition selection and stable-camera qualification remain owned by
[issue #461](https://github.com/seichris/open-bike-computer/issues/461).

## Outcome and scope

Ship `https://bicino.com/update` so a non-developer can recover either Waveshare
AMOLED model over USB when OTA cannot start, including the reported 0.3.4 build 95
failure. Support signed, release-owned packages for ordinary recovery, first
installation, and explicitly qualified partition migrations. Keep OTA as the
normal update path. Never accept an arbitrary binary, silently choose a model,
or erase the whole chip in the consumer recovery flow.

Deliver the recovery flow first, then enable migration after #461 settles the
layout and both boards pass physical tests. This does not close #483 until its
migration acceptance criteria also pass. Factory reset is a separate, clearly
explained operation, not a recovery prerequisite or an automatic retry step.

## Inspected baseline

Planning date: 2026-10-02. Firmware source inspected at fetched `origin/main`
`0f6fc8c6f0238d5508df199f2a50b1482b62ca1d`. Website source inspected read-only in
the separate `seichris/bicino` checkout at
`95c1a019903a5fd5839e440f044f6446ac7e3cc1`; refresh that repository before
implementation. These are source observations, not live release or device proof.

| Existing component | Consequence for this work |
| --- | --- |
| `esp32/tools/build_firmware.py`, `record_flash_plan.py`, `package_factory_firmware.py` | Reuse exact-source build attestation and resolved image offsets. Do not reconstruct an upload from guessed PlatformIO defaults. |
| `tools/factory_release_manifest.py` | Schema-2 factory releases already sign the archive and descriptor identity. Extend packaging with a distinct web operation contract; a factory archive alone does not authorize a preservation-safe recovery. |
| `tools/firmware_manifest.py` | OTA signatures use P-256/SHA-256 and a fixed schema-1 field list. Do not append unsigned web fields to this format or change existing OTA signature semantics. |
| `.github/workflows/firmware-release-candidate.yml`, `firmware-release.yml` | Candidate builds are unprivileged; the protected default-branch publisher validates and signs their artifacts. Preserve this separation and create-only publication. |
| `esp32/partitions.csv` | Production has dual 3 MiB apps, 9 MiB FFat, and a 960 KiB coredump allocation on 16 MiB flash. |
| `esp32/partitions_remote_debug.csv` | Development uses one 6 MiB app while retaining the production FFat start at `0x610000`. It is a different layout, not a second supported production recovery layout by default. |
| `docs/firmware-factory-release.md`, `tools/verify_firmware_boot_acceptance.py` | Production disables USB CDC and continuous serial diagnostics. Current production boot acceptance uses owner-authenticated app diagnostics; debug `BOOT_META` cannot verify production bytes. |
| Website `app/`, `package.json`, `next.config.ts` | Bicino is a separate Next.js App Router application. Add the page and browser logic there; firmware packaging and release authority stay here. |

## Architecture decisions

1. Use a pinned, locally bundled `esptool-js` behind a narrow transport adapter.
   It exposes connection, flash reading, writing, and reset operations. Keep all
   package verification, target selection, compatibility, erase policy, and
   operation sequencing in Bicino-owned code. Validate exact API behavior in a
   hardware spike before freezing the adapter.
2. Evaluate ESP Web Tools in that spike as the UI/installer alternative. Prefer
   direct `esptool-js` because this flow needs explicit preservation rules,
   partition inspection, and interrupted-migration handling beyond a generic
   installation manifest. Do not expose a generic install/erase button underneath
   the safety checks. References: [esptool-js](https://github.com/espressif/esptool-js)
   and [ESP Web Tools](https://esphome.github.io/esp-web-tools/).
3. Separate pure verification/planning from device I/O. The only writer accepts
   a validated operation plan containing already verified bytes and exact erase
   spans. No UI handler can pass arbitrary offsets or URLs to the writer.
4. Serve signed packages through an immutable, same-origin artifact path such as
   `/firmware-artifacts/<manifest-digest>/...`. A reviewed website import step
   verifies protected-publisher output and copies bytes without rebuilding or
   re-signing. This avoids browser dependence on GitHub download redirect/CORS
   behavior. If hosting limits require an artifact origin, explicitly allowlist
   it, configure CORS, and qualify the deployed download path before launch.
5. Do not include release private keys in the website, website CI, or candidate
   build jobs. Signing remains exclusively in the existing protected publisher.
   Its current environment-scoped signing boundary is a prerequisite; key
   custody changes are separate administrative work, not a reason to weaken it.

## Package and trust contract

Add `tools/web_flasher_manifest.py`, a checked-in schema, cross-language test
vectors, and shared compatibility fixtures. Generate from the validated factory
descriptor and parsed binary partition table, not handwritten offsets. Publish
separate immutable manifests per target and operation.

The versioned signed payload must bind:

| Group | Required fields |
| --- | --- |
| Identity | Schema/type, package ID, operation (`recover`, `install`, `migrate`), exact target and production profile, ESP32-S3 chip family, required flash bytes, version, monotonically allocated build, full Git SHA, minimum flasher version. |
| Provenance | Release tag, factory descriptor/archive hashes, build/runtime attestation hashes, qualification record reference and digest. |
| Compatibility | Exact accepted source layout IDs/table hashes, destination layout ID/table hash, permitted installed-build range, explicit same-build reinstall policy, bootloader compatibility, recognized interrupted-operation states. |
| Regions | Full source and destination region inventories: offset, length, type, owner, preservation/erase rule. Include bootloader, partition table, OTA metadata, every app slot, FFat/filesystem, coredump, NVS, and any separately discovered identity/calibration region. |
| Actions | Ordered writes and explicit erases; artifact name, immutable path, byte length, SHA-256, offset, erase-sector span, expected readback. Include bootloader/table/bootstrap images only for operations that require them. |
| Result | Expected app identity/digest, selected boot slot, destination layout, map/diagnostic impact, restore instructions, retry package identity, measured duration range. |

Sign a domain-separated payload, for example
`bicino-web-flasher-v1\n` followed by exact UTF-8 payload bytes. Use a bounded
envelope carrying base64 payload bytes, key ID, algorithm, and signature; verify
the bytes before parsing into an operation. Specify duplicate-key rejection,
integer-only offsets/sizes, strict schema handling, and deterministic producer
serialization. Reject unknown schemas, algorithms, keys, critical fields, and
unsupported flasher versions.

Retain P-256/SHA-256 and existing approved public trust material. Specify the new
signature encoding as fixed-width 64-byte `r || s` for Web Crypto, with an explicit
DER-to-raw conversion in the publisher and Python/browser golden vectors. Do not
change the existing OTA/factory DER signature formats. Pin trusted public keys in
reviewed website source; never trust a key supplied by the downloaded package.
Record rotation/revocation procedures and require reviewed trust-store updates.

Validate the entire manifest and download/hash **all** required artifacts before
the first erase/write. Bound downloads, lengths, record counts, offsets, memory
use, and redirects; reject overflow, overlaps, truncation, extra writes, and any
erase-sector overlap with a protected region. Validate the actual binary
partition table against the signed destination inventory. Prevent the transport
library from rewriting signed image headers (`keep` semantics); verify exact
bytes in tests and readback. Never use a merged image whose padding crosses NVS.

A signed release catalog selects currently approved packages; a mutable pointer
is only discovery metadata. Import/revocation updates must be reviewed and
deployed. Pin the chosen manifest digest for the session; selection or device
changes invalidate preparation. Recheck catalog approval before writing. Do not
claim that browser storage provides device anti-rollback enforcement.

## Device inspection and operation planning

Before connecting, show distinct photos, labels, and model-specific BOOT
instructions. Explain that connection may reset the device and that minimal
identity/layout data will be inspected locally. Request Web Serial through an
explicit user gesture. Keep that consent separate from optional diagnostic export.

Read the chip, physical flash capacity, relevant security flags, partition table,
OTA selection state, and safely readable firmware identity. Treat unreadable,
encrypted, unsupported secure-boot/download configurations as unsupported; never
modify eFuses or bypass device security. Do not read entire NVS or export secrets
just to discover the board model.

USB VID/PID, chip type, and compiled firmware target do not establish the panel
model. Use independently provisioned hardware identity only when its format and
trust are known. Otherwise require explicit model selection plus confirmation
against the actual enclosure/board. Block any conflict between selected model
and available identity; do not offer a mismatch override. Revalidate the same
device after reconnect and immediately before writing. Any changed identity or
ambiguous replacement requires a new inspection and confirmation.

Use the signed accepted-layout list and compare the actual partition table.
Ordinary recovery rejects unknown, corrupt, and development layouts. First
installation requires positively blank relevant metadata/regions and explicit
model confirmation; a damaged table alone does not mean a blank board. Unknown
layouts require a separately qualified rescue package with a defensible protected
region inventory, not a guessed layout or blanket erase.

Reject lower builds; allow exact-identity same-build reinstallation when signed
policy permits it. If installed build identity is unavailable, block generic
recovery and use only a specifically reviewed rescue policy for that unknown
state. Do not claim downgrade safety from selecting the latest visible release.
Historical short SHA identities require exact approved mappings, never arbitrary
prefix matching.

### Ordinary recovery

Preserve the partition table, bootloader, NVS, identity/calibration storage,
FFat, coredump, and SD contents. Prefer writing a valid inactive app slot, verifying
it, then changing only required OTA selection metadata. The plan must handle
both currently selected slots, pending rollback state, and corrupt OTA metadata;
derive a deterministic valid selection from the installed layout and bootloader
contract. Do not unconditionally replay the factory `boot_app0.bin` or reset both
slots. If safe inactive-slot recovery cannot be established, require a named
rescue operation with an explicit write set and ROM retry instructions.

### Partition migration

#461 must supply the chosen destination layout, occupancy evidence, and matching
development layout. Dual 4 MiB apps and 7 MiB FFat are the leading candidate, not
an approved fact. Never enable a larger application as a normal OTA update to a
device still using a 3 MiB slot.

For each accepted source-to-destination pair, enumerate intersections between old
and new regions, retained apps, metadata, filesystem, and every erase sector.
Prefer retaining NVS and other identity regions at their existing locations.
Moving one of those regions requires a separate migration design and gate.

Default proposed FFat policy: explicitly erase/reinitialize only affected FFat
and overlapping obsolete storage, preserve SD maps, and restore fallback maps
through the owner app afterward. Explain diagnostic loss before confirmation.
If existing-device data requirements demand preservation, implement and qualify
a backup/restore migration before enabling that package. Never silently mount an
old filesystem under a shifted partition boundary. Check map indexes and actual
map rendering after the chosen restore path.

Produce a signed, ordered migration recipe with a phase-by-phase interruption
table. Where verified safe for the actual overlap geometry, write/verify the new
bootable app before the final partition/OTA metadata switch. Do not describe that
switch as atomic: interrupted sector erases/writes may destroy the table. Avoid
bootloader replacement unless required by the package. Keep credentials outside
every write/erase footprint even when old application/filesystem regions overlap.

On interruption, reconnect to the ROM loader, re-read state, and recompute from
the same signed recipe. Resume only exact recognized source, intermediate, or
destination states with verified protected boundaries; do not trust a cached
progress percentage. Supply a qualified retry path for partially written table
and OTA sectors. Browser-local state can remember the package digest but is not
the sole recovery authority. Test recovery from a fresh browser session too.

Do not offer an old-layout firmware downgrade after migration. Recovery uses the
new layout; reversing the storage layout would need its own qualified migration.

## Browser flow and post-install verification

Implement an explicit state machine:

`unsupported → model selection → connect → inspect → choose package → verify
package → review operation → confirm → write → readback → reboot → reconnect →
verify running identity → complete`

Model unsupported as an early terminal branch, and allow documented recoverable
errors at each later stage. Chrome and Edge desktop are the initial qualification
targets. Detect HTTPS, `navigator.serial`, and crypto capability; give Safari,
iPhone/iPad, denied permission, occupied port, no port, and disconnect their own
concise guidance. Other browsers may be technically capable without being
qualified. Do not promise support based only on user-agent matching.

The review screen displays model, version/build, full SHA in expandable details,
source/destination layout, exact data impact, measured time estimate, and retry
instructions. Migration has a separate data-loss acknowledgement. Present phase
progress and bytes verified; disable competing operations and cross-tab writes.
Cancellation before writing is harmless; after writing begins explain how to
finish/recover without promising cancellation restores previous contents.

Read back written regions and compare SHA-256 before reporting flash verification.
A transport checksum alone does not verify authenticity. Release the port cleanly,
reset, and guide any port re-selection caused by USB re-enumeration.

**Production identity work is a required dependency.** Add a small, bounded,
request-only USB status protocol to production firmware rather than enabling
continuous debug logs. Review the deliberate USB CDC configuration change for
power, boot delay, privacy, and attack surface on both boards. A versioned status
request includes a nonce; the reply echoes it and exposes only target/profile,
version/build, full Git SHA, layout ID, boot sequence, selected app, and readiness.
Report ready only after the existing initialization/OTA-confirmation milestone.
No shell, writes, owner secrets, TLS material, coordinates, or unrequested logs.
Treat this as local operational evidence, not cryptographic hardware attestation.

Older broken firmware needs no such protocol: enter ROM mode and install a new
qualified recovery release. If the new production USB status path cannot be
qualified, keep the page at “flash verified; boot confirmation needed” and use
owner-app acceptance. That fallback does not meet the full automatic browser
identity criterion, so it cannot close #483. A timeout must never display success.

## Website security and privacy

Add a dedicated flasher route without analytics, third-party runtime scripts,
remote fonts, or generic upload inputs. Bundle the pinned transport dependency
locally. Set a production-tested CSP with `default-src 'none'`, narrowly scoped
self-hosted script/style/image/connect sources, `object-src 'none'`,
`base-uri 'none'`, and `frame-ancestors 'none'`. Use framework-compatible nonces or
hashes for required inline code; do not solve CSP failures with `unsafe-eval` or
broad script exceptions. Set `Permissions-Policy: serial=(self)` and test the
deployed headers. Avoid service-worker substitution of stale manifests or code.

Process device identity and serial responses transiently in memory for the stated
operation. No identifiers, raw serial streams, NVS dumps, or automatic error
uploads in analytics, server logs, URLs, or browser persistence. Offer a separate
opt-in, previewable diagnostic download containing redacted errors, package/page
identity, and phase outcomes. Support upload is another explicit action.

## Implementation sequence and review units

| Step | Changes | Exit condition |
| --- | --- | --- |
| 1. Contract and transport spike | Inspect both boards and factory artifacts; exercise pinned esptool-js read/erase/write/reset behavior, Web Crypto vectors, production USB status feasibility, and host browser behavior. Document bootloader/OTA rules and security-state detection. | Exact supported operations and unanswered hardware assumptions recorded; no consumer write path enabled. |
| 2. Firmware/release contract | Add web manifest schema/generator and test vectors; extend factory packaging/candidate inventory and protected-publisher validation; include region/layout identity and immutable individual images. Update candidate size/file allowlists and release-history policy tests. | Altered target, offset, signature, provenance, or protected-region write rejected before signing/publication. |
| 3. Production status | Implement bounded USB status in `esp32/src/main.cpp` and an owned module, named production configuration, host tests, and protocol documentation. Reuse existing build identity and readiness sources. | Both production targets build and pass USB/power/boot gates; no continuous sensitive output. |
| 4. Website recovery | In `seichris/bicino`, add `app/update/page.tsx`, client UI, `lib/firmware/` verifier/planner/state machine/transport adapter, immutable artifact import, and route security headers. | Complete ordinary recovery/install flow under mocked transport and browser tests; no migration shown yet. |
| 5. Migration packages | After #461, generate source/destination recipes and retry-state fixtures; implement map restore UX and compatibility guards. | Both targets pass migration, interruption, NVS preservation, and map restore tests. |
| 6. Release and support | Publish qualified artifacts through existing authority, import exact bytes to website, deploy page, and add OTA/USB/migration/reset guidance and photo instructions. | Deployed page/artifact identity matches qualification records; all #483 acceptance rows have evidence. |

Add firmware-side tests under `tools/tests/`, `esp32/tools/tests/`, and the existing
workflow-policy suites. Website tests live in `seichris/bicino/tests/`; share schema
fixtures by a versioned, hash-checked contract export rather than copied divergent
rules. Suggested support/evidence files are `docs/usb-firmware-recovery.md` and
`hardware/qualification/web-usb-flasher/<release>/<target>.md`.

## Validation and acceptance evidence

Run `tools/dev-check --plan` and affected fast checks for each firmware change;
use the repository build wrapper and release qualification workflow for both
production targets. Website changes run its `npm run lint`, `npm test`, and
dedicated browser tests. Use mock serial for exhaustive fault injection, then
real hardware for transport, power-loss, preservation, and boot claims.

| Layer | Required cases |
| --- | --- |
| Trust/parser | Valid cross-language signature; one-bit tampering; wrong key/algorithm; DER/raw confusion; malformed/duplicate JSON; unsupported schema; truncated/oversized download; wrong hash; catalog revocation; stale flasher. |
| Planner | Both models; wrong chip/flash size; selected/observed target conflict; unknown/dev layout; blank vs corrupt metadata; same-build reinstall; downgrade; unknown build; arithmetic overflow; overlapping images; erase padding touching NVS; signature-valid but forbidden operations. |
| Boot/OTA | Either active slot; corrupt OTA selection; rollback/pending states; app verify before selection change; production status timeout, stale nonce, wrong build/SHA/layout, not-ready state, USB re-enumeration. |
| UI/deployment | Unsupported browser/insecure context; denied/occupied/missing port; model photos and accessible keyboard flow; consent; measured progress; refresh and multi-tab behavior; CSP/permissions; immutable artifact delivery; no unexpected network/diagnostic traffic. |
| Migration/retry | Approved old/new layouts; partial app/table/OTA/filesystem writes; wrong retry package; new browser session; repeated recovery; explicit map restore; no automatic factory reset. |

For each model, qualify Chrome and Edge on the supported desktop OS matrix
(initial target: macOS and Windows). Record actual tested browser/OS versions;
block launch claims for untested combinations. Include a non-developer following
the published instructions without a terminal.

Physical records must include page commit/build, manifest digest, every artifact
hash, exact physical board identity and model confirmation, flash size, source and
destination layout, before/after firmware identity, write/readback result, USB
reconnect, and fresh production readiness evidence. Preserve owner pairing and
TLS identity without exporting their secrets; exercise owner authentication,
pinned transfer, calibration/settings, and installed maps after recovery.

Reproduce the build-95 OTA-entry failure on each applicable target and recover
using only the consumer instructions. Test power/USB loss during app erase/write,
verification, OTA metadata, partition-table replacement, and filesystem work.
Distinguish USB removal while battery-powered from actual power loss. Record
repeatable ROM recovery and a real cold boot with USB and battery power removed
as required by the board runbook. A browser reboot is not cold-start evidence.

Close #483 only when ordinary recovery, migration, mismatch blocking, signature
and readback checks, running identity, interruption recovery, region-policy tests,
both-target physical records, and support documentation are complete. Host tests,
CI, published artifacts, deployed-page checks, and physical evidence remain
separate gates.

## Open decisions that must be resolved before enabling writes

- #461 destination layout and measured FFat occupancy; matching developer layout.
- Actual factory/NVS identity and calibration inventory for both board revisions.
- Pinned transport version and exact erase/readback/reset behavior on each host.
- Production request-only USB status feasibility and its power/boot/security cost.
- Recognizable incomplete-migration states and the protected-region proof for each.
- Whether any unknown-build legacy rescue policy can safely be offered; default
  is blocked until its downgrade and layout boundaries are explicitly defined.

These are implementation/qualification gates, not assumptions that the issue
description or this plan has already satisfied them.
