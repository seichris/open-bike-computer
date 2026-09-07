# Firmware factory release process

This document defines how a tagged production build becomes a portable
factory-flash artifact without bypassing the repository-owned firmware runtime
or its upload attestation.

## Source and qualification boundary

`open-bike-computer` is the production firmware source of truth. Build both
supported targets with `esp32/tools/build_firmware.py` from the exact clean Git
commit being released. The authoritative release form is:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_PRODUCTION \
  --factory-output-dir dist
```

The 2.06-inch job selects its matching production environment. The initial
caller Python performs only the normal locked-runtime handoff; packaging runs
under the accepted private CPython while the project build lock is still held.
The option is deliberately absent from ordinary developer and device-test
builds. Diagnostic/calibration images stored elsewhere are not production
inputs.

Tagged publication is split across two trust domains. A pushed `v*` tag starts
`.github/workflows/firmware-release-candidate.yml`, which has read-only
permissions, no environment, and no signing or release credential. It runs the
full CI and diagnostic gates, builds both production targets, and records a
canonical receipt for the exact OTA image, factory archive, and factory
descriptor from the tagged commit.

Only `.github/workflows/firmware-release.yml`, loaded by GitHub from the
protected default branch through `workflow_run`, may publish. Before entering
the `firmware-release` environment, it verifies the registered candidate
workflow ID and path, repository, first successful push attempt, semantic tag,
full source SHA, exact candidate artifact names and GitHub SHA-256 digests, tag
target, protected-main ancestry, and absence of an existing release. After
environment approval it repeats the workflow/artifact and tag checks, then
uses only protected-default-branch verification and signing tools. Tagged code
is never checked out or executed by the publisher.

Before merging and using this flow, repository administrators must:

1. Create the `firmware-release` environment, require at least one named human
   reviewer, prevent self-review, restrict deployments to the protected
   default branch used by `workflow_run`, and limit bypass actors to the
   reviewed break-glass owner.
2. Make `FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY`,
   `FIRMWARE_RELEASE_PREFLIGHT_APP_ID`, and
   `FIRMWARE_RELEASE_PREFLIGHT_APP_PRIVATE_KEY` available to that environment
   with no broader scope than operationally required. Store both private keys
   as environment secrets and remove any repository-level copies after the
   environment migration is verified.
3. Add a `v*` tag ruleset that restricts tag creation, update, and deletion to
   release maintainers. Enable GitHub's full-SHA Actions policy after every
   workflow has landed with immutable action pins.
4. Run a non-production rehearsal proving that an off-main tag, moved tag,
   rerun candidate, altered candidate receipt, missing artifact, and existing
   release all stop before signing.

Source changes alone do not prove those live controls are configured. Do not
push the first release tag until their read-back has been reviewed.

The publisher now runs `firmware_release_controls.py` before exposing the
firmware scalar to the signing command. Its read-only App token needs
Administration, Actions, Contents, Environments and Secrets **read** permissions.
It reads secret names only, requires both private keys in `firmware-release`,
rejects repository/organization copies, requires independent environment review,
an exact default-branch-only deployment policy, strict admin-enforced `CI Gate`,
and an active `v*` creation/update/deletion ruleset. Missing API access fails
closed. See GitHub's [environment API](https://docs.github.com/en/rest/deployments/environments)
and [secret metadata API](https://docs.github.com/en/rest/actions/secrets).

This gate is not a substitute for secret migration: another branch workflow can
bypass source checks while a repository-scoped key still exists. An administrator
must provision the existing key from its secure custody source (GitHub cannot
return its value), verify environment scope, then remove the broad copy. Do not
print or pass the real scalar in a rehearsal. Coordinate the preflight App key
with `firmware-runtime-publication`: provision an environment-scoped copy there
before removing its repository copy, retain that publisher's required permissions,
and independently review its environment/ref policy. This PR does not migrate
live keys or decide independent reviewers/break-glass actors.

## Release identity and build allocation

New OTA manifests carry the **full 40-character Git SHA**, matching embedded
firmware and authenticated BLE identity. Signatures remain over the original
schema-1 fields; do not rewrite a signed manifest to expand its SHA. The app
has exact mappings for the two immutable historical releases, backed by their
verified signed factory manifests:

| Release | Build | Full identity |
| --- | --- | --- |
| `v0.3.3-release.3` | 92 | `02bce8150d2c0f88fa0481d9b6fcef76da8865ef` |
| `v0.3.4-release.1` | 93 | `8a0c9df6db26120bc988651d6a43a99ac04ef778` |

These mappings apply only to the exact version/build/short-SHA tuple and the
two Waveshare targets. Arbitrary prefix matching is forbidden. Older mutable
short-SHA releases are not accepted as immutable source identities by the new
app; recover their implementation with a newly qualified full-SHA, increasing
build release, or use the separately authorized USB recovery workflow.

`common.revision` allocates one increasing uint32 build across both targets,
independently of semantic version. `firmware_release_history.py` reads all pages
of published releases, verifies each manifest against GitHub's asset digest,
requires paired target builds, and rejects a candidate at or below the maximum
before signing. This includes prereleases and historical mutable releases as
consumed build allocations. Network errors, missing manifests, or missing asset
digests fail closed. Reverting implementation still requires a **new higher build**.
All firmware signing, Pages deployment and Pages recovery share one concurrency
group; out-of-order queued publications must recheck history under that lock.
Do not publish firmware outside this serialized workflow or delete build history.
GitHub may replace an older pending run in a concurrency group; a dropped release
needs a new candidate, not an assumption that every queued tag will publish.

Compilation, host tests, and a merged pull request establish software readiness;
they do not establish physical acceptance. Before calling an artifact
factory/golden firmware, record the target-specific device identity, attested
upload, matching production boot-acceptance target/profile/Git identity, ready checkpoint, and
the hardware observations required by the changed production paths. The
1.75-inch and 2.06-inch boards qualify independently.

A production-enabled change with an open hardware gate may merge, but the next
factory image remains blocked unless the capability is excluded from production
or the maintainer explicitly records acceptance of the residual risk. At the
time this process was introduced, the remaining 1.75-inch factory-image gate was
physical screen-switch/render-ahead validation from
[PR #239](https://github.com/seichris/open-bike-computer/pull/239). The incomplete
speaker soak is an accepted non-blocking risk documented in
[`hardware/README.md`](../hardware/README.md).

The first OTA release that changes Waveshare storage from HSPI/Arduino `SD` to
native `SD_MMC` has an additional migration gate. A card selected into SPI mode
cannot return to native SD mode without losing card power, while the OTA
finalizer performs only a warm `ESP.restart()`. Before publishing that release,
physically validate the native-first HSPI migration fallback on the exact
release head and release an iOS build that understands the optional `DSTS`
storage state. The fallback must keep the existing map available after the warm
OTA reboot, the app must instruct the rider to fully power off and disconnect
USB, and the warning must clear only after the same device reports a true
native-SDMMC boot. Post-reboot firmware identity alone does not prove that
removable storage or installed maps are available. The exact observed behavior
and remaining matrix are recorded in
[`hardware/README.md`](../hardware/README.md#8-sd-card--map-io).

## Release outputs

For each production target, the candidate and protected publisher together
publish:

| Asset | Purpose |
|---|---|
| `<target>.bin` | Application-only image consumed by OTA |
| `<target>.manifest.json` | Existing signed OTA manifest |
| `<target>.factory.tar.gz` | Deterministic factory archive |
| `<target>.factory-bundle.json` | Portable copy of the archive's flash layout and hashes |
| `<target>.factory-release.json` | Signed release identity for the archive and bundle manifest |

The factory archive contains every image from the verified PlatformIO flash
plan, named by offset; a merged image beginning at offset `0x0`; the original
current-schema build attestation; the portable factory-bundle manifest; and
`SHA256SUMS` for the extracted files. Gaps in the merged image are filled with
`0xFF`. Packaging fails closed if the build is not upload eligible, the
environment is not the matching `*_PRODUCTION` profile, the Git SHA or flash
plan differs, an image size/hash changed, images overlap, or the merged image
exceeds the configured flash capacity. The packager invokes the same complete
runtime/core/source/generated-state/artifact/uploader/flash-plan validator used
by upload; it does not establish a second, weaker authority.

Factory-bundle schema 2 includes `runtimeAttestation`: the accepted lock-set,
host target, lock-manifest SHA-256, runtime-bundle SHA-256, and canonical
SHA-256 of the complete `runtimeProvenance` object stored in the embedded build
manifest. The external descriptor and archived `factory-bundle.json` are
byte-identical.

The release tag must be `v<firmware-version>` or a prerelease below that exact
version, such as `v0.3.2-ota-test.1`. The signing gate rejects a tag for another
firmware version. It also opens the completed archive and verifies its safe
member layout, embedded bundle manifest, declared image hashes, and
`SHA256SUMS` before signing the archive hash; a corrupt or mixed artifact cannot
become a validly signed factory release.

The schema-2 signed factory release manifest binds the target, production
environment, version/build, full Git SHA, release URL, archive size/SHA-256,
portable bundle-manifest name/SHA-256, embedded build-attestation SHA-256, and
runtime-provenance SHA-256. Before signing it performs bounded safe extraction,
requires complete checksum inventory, proves the embedded build/runtime chain,
and rejects internal/external descriptor mixing. It uses the same P-256 release key as the OTA manifest,
but a separate canonical payload and artifact type so factory archives cannot
be mistaken for OTA application images. Factory verification must pin the same
X9.63 public key as
`FirmwareManifestSignatureVerifier.publicKeyBase64` in
`ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift`; a key
supplied alongside the download is not a trust anchor.

The publisher installs its signing library closure from exact Python 3.13 wheel
versions and SHA-256 hashes in `tools/firmware-signing-requirements.txt`, with
binary-only/no-dependency resolution. These dependencies run after compilation
and cannot change firmware bytes; their lock still prevents a silent signer
update or live transitive solve.

## Verification and flashing

Before extracting or flashing, verify the signature on
`<target>.factory-release.json`, then verify that its archive and bundle-manifest
hashes and direct build/runtime digests match the downloaded files. After
extraction, run one of:

```sh
# From the extracted <target>.factory directory:
shasum -a 256 -c SHA256SUMS
sha256sum -c SHA256SUMS
```

Normal development and recovery uploads must continue through
`build_firmware.py`; the presence of a factory bundle is not permission to
bypass upload-only validation with raw esptool. A controlled factory provisioner
may use either the component offsets or the merged image at `0x0` only after it
has verified the signed release identity, archive hash, extracted checksums,
connected board model, and stable device identity. Preserve the attested image
headers by using `keep` for flash mode, frequency, and size.

Immediately before the write, obtain explicit confirmation of the physical
target, production profile, stable serial/device identity, exact Git SHA, and
factory release manifest. Afterward, use the production acceptance path below.
Use flash readback or a runtime image digest when byte-for-byte on-device equality
is required.

### Production boot acceptance (no USB logging required)

Production deliberately disables USB CDC and continuous diagnostic serial output.
Do not require `BOOT_META` from those images or substitute a diagnostic image.
After successful initialization and durable OTA confirmation, the production
image emits one `boot/acceptance` event through the existing persistent ride
diagnostics recorder. The event contains schema, exact target, production profile,
version/build, full Git SHA, readiness and OTA state. Its envelope adds the
persistent boot sequence and firmware fingerprint. No credentials or transfer
tokens are recorded. The app and host diagnostics allowlists preserve these fields.

1. Provision the exact production artifact and record the stable physical device
   identity plus the intentional boot event. Keep a working SD card available for
   this **log-based acceptance** (OTA itself still supports no SD card).
2. Pair/authenticate the owner app. Use **Settings → Diagnostics → Download Device
   Logs → Export Support Bundle**, keeping the BLE owner session connected during
   the certificate-pinned, token-authenticated transfer.
3. Select that new boot's firmware JSONL stream and boot sequence from the captured
   envelope, independently correlating it with the device/provisioning record.
   Do not select an old retained boot merely because its source matches.
4. Validate the actual production checkpoint, for example:

   ```sh
   python3 tools/verify_firmware_boot_acceptance.py captured-firmware.jsonl \
     --target WAVESHARE_AMOLED_175 --git-sha FULL_REVIEWED_SHA \
     --version RELEASE_VERSION --build RELEASE_BUILD \
     --boot-sequence CAPTURED_NEW_BOOT_SEQUENCE --ota
   ```

   Select `WAVESHARE_AMOLED_206` independently. `--ota` requires `otaState=valid`;
   omit it only for a separately recorded USB/factory first boot, which can have
   an `untracked`/`undefined` OTA state. Wrong profile/SHA/build/boot, unsupported
   schema, false readiness, pending/failed OTA state and ambiguous checkpoints fail.
5. Preserve the authenticated capture and physical observations. A dropped record,
   failed export, missing SD card, or uncorrelated old stream is **no acceptance**;
   repeat the intentional boot/capture after correcting the condition. Log parsing
   alone does not authenticate a local file's origin or prove flash-byte equality.

`capture_boot.py` and `BOOT_META`/ready remain the serial acceptance path for
profiles that actually enable those markers. Their cold-power/PMIC checks qualify
those diagnostic bytes, not a replacement production image. Production hardware
observations and flash readback remain separate per-target gates.

Tagged GitHub publication is create-only. The workflow creates a draft release,
uploads without replacement flags, verifies GitHub's reported size and SHA-256
for every local asset, and only then publishes the draft. Repository immutable
releases must already be enabled; after publication the workflow requires the
release to be immutable and re-verifies the exact asset inventory before
retaining its receipt. An existing release tag or asset, disabled immutable
release setting, or mutable published release is a hard failure; recovery uses
a new tag rather than `--clobber`.

If publication succeeds but the same job stops before GitHub Pages deployment,
run **Firmware Release** manually from the default branch with the immutable
release tag in `release_tag`. An older-than-history channel also requires explicitly
setting `allow_older_channel=true`; the run records this choice in its summary.
Normal recovery of the highest published build needs no downgrade override.
This recovery path never signs, rebuilds,
uploads, edits, or replaces release assets. It downloads the complete
published inventory,
requires the repository verifier and GitHub release attestation to accept the
immutable release, verifies every downloaded asset against that attestation,
and deploys only the two exact signed OTA manifests. A mutable, incomplete, or
unattested release fails closed. This manual path is for OTA Pages recovery
only; failed or partial asset publication still requires a new release tag.
