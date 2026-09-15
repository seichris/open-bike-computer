# Firmware build and upload provenance contracts

`build_firmware.py` emits machine-readable evidence lines in addition to the
canonical JSON build, core, and flash-plan manifests. These contracts are
independently versioned; a schema number in one format says nothing about the
others.

The experimental `WAVESHARE_EPAPER_397` family uses this same locked runtime,
source identity, final-link and flash-plan attestation path. Its ordinary,
`DISPLAY_TEST`, `POWER_METRICS`, `IMU_DIAGNOSTICS`, `LIGHT_SLEEP` and
`PRODUCTION` profiles retain the canonical board target. Attestation proves
artifact identity, not a working physical e-paper panel.
See [the board qualification record](../hardware/waveshare-epaper-397.md).

## Build and upload schema 2

`FIRMWARE_BUILD_PROVENANCE schema=2` and
`FIRMWARE_UPLOAD_PROVENANCE schema=2` are closed-field, space-separated
`key=value` records. A parser must require exactly one marker, exactly one
schema field, every documented field once, no unknown field, and values without
ASCII whitespace or control characters. `missing` is an explicit unavailable
value; it is not a digest and must fail any gate that requires that field.

The exact schema-2 field order after the marker is:

```text
schema environment git uploadEligible coreCache coreInputKey
runtimeLockSetId runtimeManifestSha256 runtimeTarget runtimeBundleSha256
runtimeTreeSha256 runtimePythonSha256 runtimePioSha256 runtimeUvSha256
runtimePythonVersion runtimePlatformioVersion
runtimeTopLevelDistributionsSha256
runtimePioarduinoRootDistributionsSha256 runtimeEspIdfDistributionsSha256
runtimeUvDistributionsSha256 runtimeEsptoolDistributionsSha256
runtimeBootstrapMs runtimeSharedMs runtimeHydrationMs runtimeVerificationMs
runtimePioarduinoPenvTreeSha256 runtimeEspIdfVenvTreeSha256
runtimeTransformedPlatformTreeSha256 phasePlatformPreparationMs
phaseCustomCoreBootstrapMs phaseApplicationCompileMs phaseApplicationBuildMs
phaseLinkMs phaseAttestationMs phaseTotalMs sourceDateEpoch buildTimestamp
firmwareBinSha256 firmwareElfSha256 bootloaderBinSha256
partitionTableBinSha256 bootApp0Sha256 flashPlanSha256
coreAttestationSha256 platformArchiveSha256 platformPackagesSha256
libraryDependenciesSha256 managedComponentsSha256
```

Those fields bind:

- exact environment, clean Git identity, upload eligibility, core-cache status,
  and core input key;
- runtime lock-set, manifest, target, bundle, accepted tree, CPython, `pio`,
  `uv`, PlatformIO version, distribution sets, installed nested environments,
  and transformed-platform identities;
- runtime bootstrap/shared-cache/private-hydration/tree-verification timings;
- source-derived epoch/timestamp and platform/core/application/attestation
  phase timings; and
- firmware, ELF, bootloader, partition, OTA bootstrap, flash-plan, installed
  core, platform/package, library, and managed-component identities.

Build consumers may use the phase timings. Upload records reproduce the stored
build-phase values from the revalidated manifest while the runtime timing fields
describe the current upload-only handoff. Upload eligibility always comes from
revalidating the canonical build and flash-plan manifests, not from trusting the
printed line.

Schema-1 consumers must not silently parse schema 2. Historical evidence stays
historical; a new producer never rewrites or relabels it.

## Stable Python state during cache reuse

Verified Waveshare builds also exclude the final ELF link target from SCons
artifact caching. SCons does not restore the linker's `firmware.map` side output
alongside a cached ELF. Re-running the link preserves the required dynamic-TLS
link evidence and link timing while keeping objects and libraries cacheable.
The wrapper still rejects a missing or invalid map; it never substitutes a map
from another build.

The sanitized build environment forces `PYTHONDONTWRITEBYTECODE=1` for
compilation, recursive custom-core subprocesses, and upload. Runtime startup's
inherited setting is not sufficient: environment sanitization must explicitly
restore this policy. The caller's original environment is restored afterward,
including when a build or upload fails.

Core archives preserve Python bytecode as attested executable state, but
hydration recreates source files with different filesystem timestamps. Python
may recompile a stale timestamp-based cache in memory; it must not rewrite or
add `.pyc` files inside the inventoried toolchain. Bytecode remains included in
the existing content attestation. This policy does not excuse missing files,
directories, changed executable state, or a failed post-build comparison.

Cache-reuse qualification requires a real clean build followed by a same-head
cache-hit rebuild, with unchanged core attestation and image/flash-plan hashes.
Unit tests of environment propagation alone are not that qualification.

## Runtime and factory timing records

`FIRMWARE_RUNTIME_CHECK schema=1` is a separate, no-build performance record.
It reports the selected lock/target and aggregate, shared-cache, hydration, and
verification milliseconds. The performance gate requires exactly five warm
samples and compares the median against the target baseline with a 20% limit.

`FIRMWARE_FACTORY_PROVENANCE schema=1` is emitted only when a production build
explicitly requests `--factory-output-dir`. It records the exact environment
and Git identity, packaging time, release filenames, and their SHA-256 values.
It contains no absolute cache path or credential and is not part of ordinary
developer build latency.

The JSON build-manifest schema, runtime-lock schema, core-cache schema,
flash-plan schema, factory-bundle schema, and factory-release schema remain the
authoritative structured contracts for their respective boundaries.

## AMOLED equivalence evidence

An e-paper-only change must not infer AMOLED isolation from successful builds
or from whole-image hashes. Build the baseline and candidate Git identities
through `tools/build_firmware.py` for these four environments:

```text
WAVESHARE_AMOLED_175
WAVESHARE_AMOLED_175_PRODUCTION
WAVESHARE_AMOLED_206
WAVESHARE_AMOLED_206_PRODUCTION
```

For each build, use the exact recorded compiler command to preprocess these
shared translation units with `-E -P` (or remove compiler line markers before
capture):

```text
lib/ble_navigation/ble_navigation.cpp
lib/epaper_display/epaper_display.cpp
lib/gui/src/epaper_ui.cpp
lib/gui/src/mainScr.cpp
lib/maps/src/maps.cpp
```

Capture each side after its final wrapper build:

```sh
python3 tools/compare_amoled_artifacts.py capture \
  --project-dir . \
  --environment WAVESHARE_AMOLED_175 \
  --preprocessed lib/ble_navigation/ble_navigation.cpp=/evidence/ble.ii \
  --preprocessed lib/epaper_display/epaper_display.cpp=/evidence/display.ii \
  --preprocessed lib/gui/src/epaper_ui.cpp=/evidence/epaper-ui.ii \
  --preprocessed lib/gui/src/mainScr.cpp=/evidence/main.ii \
  --preprocessed lib/maps/src/maps.cpp=/evidence/maps.ii \
  --output /evidence/baseline-175.json
```

Repeat for the candidate and compare the create-only evidence files:

```sh
python3 tools/compare_amoled_artifacts.py compare \
  --baseline /evidence/baseline-175.json \
  --candidate /evidence/candidate-175.json \
  --output /evidence/report-175.json
```

The gate requires identical locked runtime/core/dependency identities,
line-marker-free preprocessed outputs, every application object except the
firmware-metadata object, and the linker map after replacing only the absolute
project-root prefix. The sole object exclusion is
`*/firmware_metadata/firmware_metadata.cpp.o`. Whole binaries are deliberately
not compared because they embed the exact Git identity and source timestamp;
the tool performs no binary-byte normalization. Record both source identities,
the preprocessing commands, evidence JSON files, exclusions, object counts,
and all four results in the pull request.
