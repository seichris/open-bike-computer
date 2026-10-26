# Durable map compatibility

Maps created from baseline **MAP-COMPAT-20261026** onward stay usable. App,
firmware and backend updates never require a rider to recreate them. This page
defines that guarantee (compatibility contract v1), what it covers and the rules
every later release must follow.

The source of truth is
[`map-platform/config/map-compatibility-contract-v1.json`](../map-platform/config/map-compatibility-contract-v1.json).
The frozen producer corpus in
[`map-platform/backend/tests/fixtures/map-compatibility-v1/`](../map-platform/backend/tests/fixtures/map-compatibility-v1/README.md)
is the release regression.

## The guarantee

A map belongs to contract v1 exactly when its **signed** canonical manifest
contains:

```json
"compatibility": {"contract": 1}
```

The marker is inside the BMAP signature (see
[map-stream format v1](map-stream-format-v1.md#canonical-manifest)). It travels
with every copy: the shared catalog, a direct job, the iPhone, the bike's SD
card and every re-download. No date, app build, firmware build or worker
digest decides whether a map is covered.

A covered map keeps working after:

- an app update of Bicino or Bicino Dev, including offline reopening of a saved
  copy;
- a firmware update. Install depends on the bike's reader capabilities and
  trusted signers, never on its build or Git SHA;
- a backend deployment or worker promotion. Earlier approved durable maps stay
  listed and refreshable;
- a signing-key rotation. Readers keep every registered signer until it is
  revoked for a compromise;
- a re-download from the catalog or a direct job.

Genuine revocation is preserved. A compromised signer, a quarantined or
tombstoned catalog map, a removed hardware approval, the catalog
`MAP_DELIVERY_ENABLED=0` switch and integrity failures still stop delivery or
installation.

### Pre-baseline maps

Maps without the marker are pre-baseline. They are not migrated, deleted or
reinterpreted. They keep their original rules, including any exact firmware
identity attached at delivery, and they are not covered. They are recognised
as follows:

- Saved Maps labels archives and signed streams without the marker: "Saved
  before durable maps. To keep it working after updates, download this area
  again."
- If an install fails because of a pre-baseline firmware pin, the error says so
  and offers a fresh download, which produces a durable map.

## Contract v1 profiles

| Profile | Renderer target | Features | Channels | iPhone companion |
| --- | ---: | --- | --- | --- |
| `buildings-3d-v1` | 3 | `3d-buildings`, `street-labels` | development, production | — |
| `topographic-contours-v1` | 4 | `3d-buildings`, `contours`, `street-labels` | development, production | `topography-ios-v1` |
| `map-pois-v1` | 5 | `3d-buildings`, `map-pois`, `street-labels` | development | — |
| `map-pois-contours-v1` | 5 | `3d-buildings`, `contours`, `map-pois`, `street-labels` | development | `topography-ios-v1` |

The stream format is `bike-map-stream-v1` with manifest schema 1.

Not covered:

- Renderer targets 1 and 2. No supported app requests them, and the producer
  leaves their manifests unmarked.
- Terrain experiments (`terrainProfileVersion`). They also carry no marker.

Production may publish a profile only when the profile lists the production
channel. Target 4 is listed because every app and firmware profile already reads
it, but production generation and topography promotion stay gated separately.
POI maps remain development-only until the POI firmware reader passes its
hardware gate.

## Readers per channel

| Reader | Must read | Trusts |
| --- | --- | --- |
| Bicino (production app) | production profiles | registered production signers |
| Bicino Dev | every profile: development artifacts first, then the production copy | production and development signers |
| Production and ordinary firmware | production profiles | production signers |
| `*_PERSONAL` firmware | production profiles | production and development signers |
| `*_REMOTE_DEBUG` and POI qualification firmware | every profile | as compiled (`*_REMOTE_DEBUG` adds the development signer) |

Both apps share one reader and the production library catalog. Development and
production generation stay on separate backends.

A phone app cannot make firmware parse a format that firmware lacks. The app
reads the bike's authenticated `mapReader` report from the map transfer status
(see [BLE protocol](ble-protocol.md)). Firmware without that report falls back
to its renderer capability bits. A durable POI map on stock firmware is refused
before upload with "This Bike Computer's firmware can't read this map's
features". That message never points to a firmware build.

## How each component applies the contract

- **Producer.** The worker stamps the marker only for a registered profile that
  its channel may publish. It refuses to sign a marked manifest with a key that
  is not a registered signer for that channel. Production promotion re-signs the
  exact development content, so the marker and content receipt survive and only
  the signer and producer change.
- **Direct jobs.** In `percentage` and `all` modes, a durable map stays listed
  and refreshable while any record in `map-stream-rollout-approvals.json` covers
  its producer, image digest and still-trusted signer. Its responses never
  include `requiredFirmware*`. Pre-baseline maps keep the single active-approval
  rule and the exact firmware identity. `allowlist` mode is unchanged.
- **Catalog.** The backend publisher and promotion omit firmware gates from
  durable artifacts. `MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_*` affects only
  pre-baseline publications. The Worker's generation classes already exclude
  producer identity:
  - a rotated signer is a new generation, so apps that trust either key still
    receive a copy;
  - a worker update supersedes within its generation, so saved copies keep
    validating and the app offers "Updated map available".
- **iPhone.** Both delivery paths validate the same signed bytes and derive the
  reader requirements and contract from the manifest. Install needs three
  things: the bike trusts the signer, the bike's reader capabilities cover the
  requirements, and the phone can read them. For a durable map, firmware
  identities in saved or delivered metadata are ignored. A URL refresh compares
  only immutable artifact identity, so a new approval or backend version cannot
  break a re-download.
- **Firmware.** The HTTPS and BLE map transfer status report `mapReader`. The
  report is derived from the same compile flags that decide which renderer
  targets the parser admits. The parser still rejects unknown formats, untrusted
  signers and corrupt bytes before writing a payload. The signed
  `minFirmwareVersion` stays a minimum, which later firmware satisfies.

## Evolution rules

1. **Append-only.** Later revisions may add profiles, channels, stream formats,
   manifest schemas and signers. They never remove or narrow existing ones.
   Dropping a reader needs a verified automatic migration that keeps every
   covered map usable, delivered before the reader is removed.
2. **New production feature.** Before production may generate or promote a new
   format or feature, add it to the contract with the production channel and
   ship the reader in the app and in every production firmware profile. Freeze
   a new corpus directory of real producer output for it. The generation
   policies are checked against the contract in CI.
3. **New semantics need new requirements.** A changed meaning needs a new
   renderer target, feature, manifest schema or stream format, so older readers
   refuse it cleanly. Never reuse an existing identifier.
4. **Signers.** Every key that signs durable maps is listed in `signers` and
   stays `trusted` in `map-stream-trust.json` (checked in CI). Rotation works
   like this:
   - Add the new key to the trust registry and the contract.
   - Ship apps and firmware with it.
   - Switch the worker to the new key.

   Retired production keys stop signing but keep verifying. Only a compromise
   moves a key to `revokedSigners`, which deliberately revokes its maps. The
   client trust list is capped at four keys, so raising that cap is a reviewed
   change.
5. **Approvals.** A new hardware approval never hides earlier approved durable
   maps. To revoke a producer, remove its approval record in a reviewed change.
   Its durable artifacts are then no longer listed or refreshed, while
   downloaded copies keep validating unless their signer is revoked.
6. **Saved state.** iPhone saved-map metadata schema 1 keeps decoding, and new
   fields stay optional. Firmware library records keep their on-SD format or
   migrate in place.
7. **Firmware versions** stay monotonic, because the signed `minFirmwareVersion`
   is compared as a minimum.
8. **Frozen corpus.** Never regenerate or edit a committed corpus. A failing
   reader is a regression to fix.

## Release checks

Each release candidate must pass these checks from the shared runner
(`tools/dev-check`, CI Gate):

| Component | Check | Coverage |
| --- | --- | --- |
| Backend | `map-backend-tests` | Corpus hash pins and signatures, every profile, companions, direct-job/catalog parity, worker updates, key rotation, promotion, signer and channel guards, pre-baseline behavior |
| Catalog | Map Platform CI `catalog` (`pnpm check`) | Frozen publications accepted without firmware gates; Bicino vs Bicino Dev grants, rotation, worker update, POI isolation, reader mismatch |
| iPhone | `ios-navigation-map` | Validation on both delivery paths, install against later firmware via `mapReader` or legacy bits, trust and reader refusals, saved-copy reopen with stale firmware metadata, pre-baseline marking, corrupt, truncated, untrusted and unknown-format rejection |
| Firmware | `esp32-host-map-stream-format-host-tests` | Production and POI builds parse every frozen stream they should, refuse POI maps without the reader, report exactly `protocol/fixtures/map-reader-capabilities-v1.txt`, reject old firmware, untrusted signers and corruption |

Changes to the contract, corpus or reader fixture select all four suites.

These checks do not prove physical installs. The physical gates in the
[rollout runbook](map-stream-rollout-runbook.md) still apply, and each new
firmware profile needs both boards:

1. Install a durable production map.
2. Update the firmware.
3. Confirm the saved and installed copies still install and select.

## Deployment order and rollback

Each part can ship independently:

- **New app on older backends.** Maps carry no marker yet, so pre-baseline
  behavior is unchanged.
- **New app with older firmware.** The app falls back to the renderer capability
  bits.
- **New worker behind an older controller.** Maps are marked, but the old
  controller still attaches firmware identities and hides older producers. The
  new app ignores the attached identity; older apps keep their previous
  behavior.
- **Contract covered on the backend.** Production gets the full contract only
  after a worker and controller built from this change are promoted through the
  normal image PR flow, with a new hardware approval for that worker.

Rollback:

- **Backend rollback.** Older backends ignore the job's `compatibilityContract`
  field and may attach firmware identities again. New apps still treat the
  signed maps as durable.
- **App rollback.** The previous app enforces delivery firmware identities
  again.
- **Firmware rollback.** Drops `mapReader`. The app then uses the capability
  bits.

None of these rollbacks rewrites signed map bytes.
