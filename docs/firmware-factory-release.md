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

Compilation, host tests, and a merged pull request establish software readiness;
they do not establish physical acceptance. Before calling an artifact
factory/golden firmware, record the target-specific device identity, attested
upload, matching `BOOT_META` target/profile/Git identity, ready checkpoint, and
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

## Release outputs

For each production target, `.github/workflows/firmware-release.yml` publishes:

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
factory release manifest. Afterward, require matching `BOOT_META` plus the ready
checkpoint. Use flash readback or a runtime image digest when byte-for-byte
on-device equality is required.

Tagged GitHub publication is create-only. The workflow creates a draft release,
uploads without replacement flags, verifies GitHub's reported size and SHA-256
for every local asset, and only then publishes the draft. Repository immutable
releases must already be enabled; after publication the workflow requires the
release to be immutable and re-verifies the exact asset inventory before
retaining its receipt. An existing release tag or asset, disabled immutable
release setting, or mutable published release is a hard failure; recovery uses
a new tag rather than `--clobber`.
