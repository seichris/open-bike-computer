# Durable map compatibility

Maps created from baseline **MAP-COMPAT-20261026** onward stay usable. App,
firmware and backend updates never require a rider to recreate them. This page
defines that guarantee (compatibility contract v1), what it covers and the rules
every later release must follow.

The sources of truth are:

- [`map-platform/config/map-compatibility-contract-v1.json`](../map-platform/config/map-compatibility-contract-v1.json):
  the covered profiles, stream formats, optional layers and companions. The
  worker reads it.
- [`map-platform/config/map-compatibility-signers-v1.json`](../map-platform/config/map-compatibility-signers-v1.json):
  the keys that sign durable maps. Only CI reads it.
- The frozen producer corpus in
  [`map-platform/backend/tests/fixtures/map-compatibility-v1/`](../map-platform/backend/tests/fixtures/map-compatibility-v1/README.md),
  which is the release regression.

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
  listed and refreshable (for a backend rollback, see
  [Deployment order and rollback](#deployment-order-and-rollback));
- a signing-key rotation. Readers keep every registered signer until it is
  revoked for a compromise;
- a re-download from the catalog or a direct job.

Genuine revocation is preserved. These still stop delivery or installation:

- a compromised signer;
- a quarantined or tombstoned catalog map;
- a removed hardware approval;
- the direct-job rollout switch (`disabled`, or a smaller `percentage`
  cohort) and the catalog `MAP_DELIVERY_ENABLED=0` switch. Both stop new
  downloads only; saved copies keep working;
- integrity failures.

### Maps outside the contract

A map without the marker is outside the contract. That covers every map made
before the baseline, and later maps of a profile or channel the contract does
not list (see below). These maps are not migrated, deleted or reinterpreted.
They keep their original rules, including any exact firmware identity attached
at delivery. They are recognised as follows:

- Saved Maps labels archives and signed streams without the marker: "Not a
  durable map, so an update may stop it working. Download this area again with
  current firmware to replace it."
- If an install fails because of an exact firmware identity, the error says the
  map isn't durable and offers a fresh download, which produces a durable map.

## Contract v1 profiles

| Profile | Renderer target | Features | Channels | iPhone companion | Optional layers |
| --- | ---: | --- | --- | --- | --- |
| `buildings-3d-v1` | 3 | `3d-buildings`, `street-labels` | development, production | — | — |
| `topographic-contours-v1` | 4 | `3d-buildings`, `contours`, `street-labels` | development, production | `topography-ios-v1` | `terrain-experiment-v1` |
| `map-pois-v1` | 5 | `3d-buildings`, `map-pois`, `street-labels` | development | — | — |
| `map-pois-contours-v1` | 5 | `3d-buildings`, `contours`, `map-pois`, `street-labels` | development | `topography-ios-v1` | — |

The stream format is `bike-map-stream-v1` with manifest schema 1.

An **optional layer** is extra signed content that a reader of its profile
accepts and may ignore. `terrain-experiment-v1` adds the `.fme` terrain grids
that Bicino Dev requests (`terrainProfileVersion` 1) from firmware with the
terrain experiment. Every firmware build from v0.3.4-release.11 on (main since
#565, 2026-10-18) installs those files for target 4, and only diagnostics builds
render them. Earlier releases that read target 4 refuse them. The iPhone
therefore sends a durable map's terrain layer to any bike that reports
`mapReader`, and to older firmware only when it has the terrain experiment.

Not covered:

- Renderer targets 1 and 2. No supported app requests them, and the producer
  leaves their manifests unmarked.
- A profile made on a channel it does not list. The producer leaves that map
  unmarked, and CI checks that the generation policies never publish such a
  profile.

Production may publish a profile only when the profile lists the production
channel. Target 4 is listed because every app and firmware profile already reads
it, but production generation and topography promotion stay gated separately.
POI maps remain development-only until the POI firmware reader passes its
hardware gate.

## Readers per channel

| Reader | Must read | Trusts |
| --- | --- | --- |
| Bicino (production app) | production profiles | registered production signers |
| Bicino Dev | every profile: development artifacts first, then the production copy, among the copies the connected bike trusts when there are any | production and development signers |
| Production and ordinary firmware | production profiles | production signers |
| `*_PERSONAL` firmware | production profiles | production and development signers |
| `*_REMOTE_DEBUG` and POI qualification firmware | every profile | as compiled (`*_REMOTE_DEBUG` adds the development signer) |

Both apps share one reader and the production library catalog. Development and
production generation stay on separate backends.

A phone app cannot make firmware parse a format that firmware lacks. The app
reads the bike's `mapReader` report from the authenticated, pinned map transfer
status (see [BLE protocol](ble-protocol.md)). Firmware without that report, or
with a report schema the app does not know, falls back to its renderer
capability bits. A durable POI map on stock firmware is refused before upload
with "This Bike Computer's firmware can't read this map's features". That
message never points to a firmware build.

## How each component applies the contract

- **Producer.** The worker stamps the marker only for a registered profile that
  its channel may publish. It records the same classification as
  `artifactMetrics.compatibilityContract` on the job. Every control-plane
  version saves artifact metrics verbatim and exact reuse copies them, so an
  older backend that rewrites the job cannot turn a durable map into one outside
  the contract. Production promotion re-signs the exact development content, so
  the marker and content receipt survive and only the signer and producer
  change. The worker does not read the signer registry; CI keeps it in step with
  client trust.
- **Direct jobs.** For installations in the rollout cohort in `percentage` and
  `all` modes, a durable map stays listed and refreshable while any record in
  `map-stream-rollout-approvals.json` covers its producer, image digest and
  still-trusted signer. Its responses never include `requiredFirmware*`. Maps
  outside the contract keep the single active-approval rule and the exact
  firmware identity. `allowlist` mode is unchanged.
- **Catalog.** The backend publisher and promotion omit firmware gates from
  durable artifacts. `MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_*` affects only
  maps outside the contract. The Worker's generation classes already exclude
  producer identity:
  - a rotated signer is a new generation, so apps that trust either key still
    receive a copy;
  - a worker update supersedes within its generation, so saved copies keep
    validating and the app offers "Updated map available".
- **iPhone.** Both delivery paths validate the same signed bytes and derive the
  reader requirements and contract from the manifest. Install needs three
  things: the bike trusts the signer, the bike's reader capabilities cover the
  requirements, and the phone can read them. For a durable map, firmware
  identities in saved or delivered metadata are ignored, and the optional
  terrain layer goes to any bike that reports `mapReader` (older firmware needs
  the terrain experiment). A URL refresh compares only immutable artifact
  identity, so a new approval or backend version cannot break a re-download.
  Shared-library downloads prefer the copies whose signer the connected bike
  reports in `streamTrust` (or, with no bike reporting, the bike the saved copy
  was chosen for), so Bicino Dev gives stock firmware the production copy.
- **Firmware.** The HTTPS and BLE map transfer status report `mapReader`. The
  report is derived from the same compile flags that decide which renderer
  targets the parser admits. The parser still rejects unknown formats, untrusted
  signers and corrupt bytes before writing a payload. The signed
  `minFirmwareVersion` stays a minimum, which later firmware satisfies.

## Evolution rules

1. **Append-only.** Later revisions may add profiles, channels, optional layers,
   stream formats, manifest schemas and signers. They never remove or narrow
   existing ones. Dropping a reader needs a verified automatic migration that
   keeps every covered map usable, delivered before the reader is removed.
2. **New production feature.** Before production may generate or promote a new
   format or feature, add it to the contract with the production channel and
   ship the reader in the app and in every production firmware profile. Freeze
   a new corpus directory of producer output for it. The generation policies
   are checked against the contract in CI. A contract change moves the worker
   build identity, so it ships through a worker promotion and hardware approval.
3. **New semantics need new requirements.** A changed meaning needs a new
   renderer target, feature, manifest schema or stream format, so older readers
   refuse it cleanly. Never reuse an existing identifier. Current parsers refuse
   unknown files and `mapReader` schema 1 lists no layers, so a new optional
   layer also needs readers that report it before the iPhone may send it.
4. **Contract numbers.** The marker is exactly `{"contract": N}`, with N from 1
   to 255. A later contract adds a contract file and a corpus directory; readers
   and the backend keep accepting every earlier contract. The iPhone treats any
   valid N as durable but still installs only reader requirements it supports.
5. **Reader reports.** `mapReader` schema 1 may gain optional fields. A changed
   meaning needs schema 2, which older apps ignore in favour of the renderer
   capability bits.
6. **Signers.** Every key that signs durable maps is listed in
   `map-compatibility-signers-v1.json`. CI checks that each listed production
   key stays `trusted` in `map-stream-trust.json`, that the development key
   matches Bicino Dev and development firmware, and that no registered signer
   disappears. Changes to the trust registry, the generated client trust files
   or `Development.xcconfig` select these backend checks. Rotation works like
   this:
   1. Add the new key to the trust registry and the signer registry.
   2. Ship apps and firmware that trust it.
   3. Switch the worker to the new key. The signer registry is not a worker
      input, so this needs no new worker image.

   A key's `retireAfter` date is when it stops signing new maps. Readers keep
   trusting it after that date. Only a compromise moves a key to
   `revokedSigners`, which deliberately revokes its maps. The client trust list
   is capped at four keys, so raising that cap is a reviewed change. Bicino Dev
   and development firmware trust exactly one development key, so it cannot
   rotate until both accept several. The registry cannot see which key a
   deployed worker uses: register a key before any worker signs with it.
7. **Approvals.** A new hardware approval never hides earlier approved durable
   maps. To revoke a producer, remove its approval record in a reviewed change.
   Its durable artifacts are then no longer listed or refreshed, while
   downloaded copies keep validating unless their signer is revoked.
8. **Saved state.** iPhone saved-map metadata schema 1 keeps decoding, and new
   fields stay optional. Firmware library records keep their on-SD format or
   migrate in place.
9. **Firmware versions** stay monotonic, because the signed `minFirmwareVersion`
   is compared as a minimum.
10. **Frozen corpus.** Never regenerate or edit a committed corpus. A failing
    reader is a regression to fix.

## Release checks

Each release candidate must pass these checks from the shared runner
(`tools/dev-check`, CI Gate):

| Component | Check | Coverage |
| --- | --- | --- |
| Backend | `map-backend-tests` | Corpus hash pins and signatures, every profile and optional layer, companions, republishing persisted jobs, rollback-safe classification, worker updates, key rotation, promotion, signer registry and client trust, generation policies, maps outside the contract |
| Catalog | Map Platform CI `catalog` (`pnpm check`) | Frozen publications accepted without firmware gates; Bicino vs Bicino Dev grants, rotation, worker update, optional terrain, POI isolation, reader mismatch |
| iPhone | `ios-navigation-map` | Validation on both delivery paths, install against later firmware via `mapReader`, legacy bits or a later report schema, optional terrain, trust and reader refusals, saved-copy reopen with stale firmware metadata, marking maps outside the contract, corrupt, truncated, untrusted and unknown-format rejection |
| Firmware | `esp32-host-map-stream-format-host-tests` | Production and POI builds parse every frozen stream they should, refuse POI maps without the reader, report exactly `protocol/fixtures/map-reader-capabilities-v1.txt`, reject old firmware, untrusted signers and corruption |

A corpus change selects all four suites. A contract change selects the backend,
catalog and iPhone suites, the reader fixture the firmware and iPhone suites,
and the signer registry the backend suites.

Every corpus stream comes from the real packaging, promotion, companion and
signing code. The `*-osm-*` maps also carry blocks that the production worker
extracted from checked-in OSM fixtures. The other maps use small test-helper
blocks, every contour layer and terrain grid uses test elevation data, and no
map has real POI records, because the OSM fixtures have no POI tags. The
firmware suite runs only the current parser, so it cannot show which older
releases read a frozen map.

These checks do not prove physical installs. The physical gates in the
[rollout runbook](map-stream-rollout-runbook.md) still apply, and each new
firmware profile needs both boards:

1. Install a durable production map.
2. Update the firmware.
3. Confirm the saved and installed copies still install and select.

## Deployment order and rollback

Each part can ship independently:

- **New app on older backends.** Maps carry no marker yet, so behavior for
  maps outside the contract is unchanged. Saved Maps labels every new map as
  not durable, and a re-download does not change that until the backend runs
  this change, so deploy the backend before releasing the app.
- **New app with older firmware.** The app falls back to the renderer capability
  bits.
- **New worker behind an older controller.** Maps are marked, but the old
  controller still attaches firmware identities and hides older producers. The
  new app ignores the attached identity; older apps keep their previous
  behavior.
- **Promotion by an older image.** The marker survives, because promotion copies
  the signed development content, but the older image still attaches the
  configured catalog firmware gate. New apps ignore it for durable maps.
- **Contract covered on the backend.** Production gets the full contract only
  after a worker and controller built from this change are promoted through the
  normal image PR flow, with a new hardware approval for that worker.

Rollback:

- **Backend rollback.** Older controllers ignore the classification in the
  artifact metrics and may attach firmware identities again, but they keep the
  metrics. New apps still treat the signed maps as durable, and rolling forward
  restores durable delivery.
- **App rollback.** The previous app enforces delivery firmware identities
  again.
- **Firmware rollback.** Drops `mapReader`. The app then uses the capability
  bits and sends a durable map's terrain layer only to firmware with the
  terrain experiment.

None of these rollbacks rewrites signed map bytes.
