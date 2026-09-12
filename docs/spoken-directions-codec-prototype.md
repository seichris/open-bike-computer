# Spoken directions: Slice 0 codec and pack preparation

## Scope and status

Implements the host-work portion of Slice 0 of the
[issue #77 plan](plans/spoken-turn-by-turn-directions-implementation-plan.md).
The implementation branch starts at GitHub main
`ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`.

This is **not spoken navigation on a device**. There are no new production
capabilities, BLE frames, speaker calls, settings, signing keys, or installable
voice packs. The prototype lives under `tools/spoken_directions/`, outside both
app and firmware source graphs. It must not be imported into production until
the plan's codec, safety-preemption, radio, memory, and storage gates pass.

The user confirmed a connected 1.75-inch board and requested preparation while
production recordings are pending. No device enumeration, debug connection,
flash, installation, playback, signing-secret access, or release is performed.
The separate 2.06 measurements remain necessary.

## Run the host proof

From the repository root:

```sh
python3 tools/spoken_directions/run_tests.py --sanitize
python3 -m unittest discover -s tools/tests -p test_spoken_audio_prototype.py
```

The first command needs a host C++17 compiler and Swift compiler (Xcode's
`xcrun swiftc` on macOS, `swiftc` on Linux). It builds in a unique temporary
directory and deletes only that directory when finished. `--cpp-only` runs the
allocation-free decoder tests without Swift. `--sanitize` enables AddressSanitizer
and UndefinedBehaviorSanitizer for C++ host executables, not firmware.

The C++ decoder tests are invoked by existing root tooling unittest discovery
in `ESP32 Host Tests`. The complete Swift/C++ interoperability run is invoked by
`ios-app/scripts/run-navigation-tests.sh` in `iOS Fast Tests`. Changes to any
prototype file select both consumers. No test is an ESP32 build or device test.

Coverage includes a hand-derived golden vector in both languages, single and
partial blocks, maximum duration, malformed headers and block state, every
truncation of the short golden, canonical nibble padding, signed clipping,
callback cancellation, deterministic mutation stress, no-overwrite CLI behavior,
and full Swift-to-C++ boundary/size checks. Synthetic signal error is reported,
not mistaken for speech quality. The golden format is independently specified
below; neither decoder accepts WAV IMA or RTP DVI4 as this container.

## Candidate BSA0 container

All integers are little-endian. This is a **prototype format**, not a reserved
production codec ID or negotiation contract. It uses the IMA step/index
algorithm with explicitly defined framing. As
[RFC 3551 section 4.5.1](https://www.rfc-editor.org/rfc/rfc3551#section-4.5.1)
explains, DVI4 and IMA differ in framing; a codec name alone is not a wire format.

| Offset | Size | Value |
| --- | --- | --- |
| 0 | 4 | ASCII `BSA0` |
| 4 | 1 | Prototype version 1 |
| 5 | 1 | Candidate codec 1, meaningful only inside BSA0 |
| 6 | 1 | Mono, value 1 |
| 7 | 1 | Reserved, must be zero |
| 8 | 4 | Sample rate, exactly 16000 |
| 12 | 4 | Decoded frame count, 1–128000 |

Each block carries the next `min(160, remainingFrames)` samples. Nonfinal short
blocks are invalid. Its eight-byte header is:

| Offset | Size | Value |
| --- | --- | --- |
| 0 | 2 | First signed PCM16 predictor, emitted as the first sample |
| 2 | 1 | Initial IMA index, 0–88 |
| 3 | 1 | Reserved, must be zero |
| 4 | 2 | Frame count, 1–160 |
| 6 | 2 | Encoded bytes, exactly `floor(frameCount / 2)` |

There are `frameCount - 1` four-bit codes, low nibble first. When the final high
nibble is unused it must be zero. Trailing bytes, truncated payloads, inconsistent
frame counts, out-of-range indexes, and unsupported metadata are rejected.
Maximum complete container size is 70,416 bytes.

The encoder starts each block at the first source sample and chooses the first
IMA step at least as large as the absolute first-to-second difference, capped
at index 88; a single-sample block uses index 0. For each subsequent sample,
it greedily chooses sign and step, half-step, quarter-step bits. Reconstruction
adds `step >> 3` plus the selected terms, saturates to signed 16-bit range, then
updates the index with `[-1,-1,-1,-1,2,4,6,8]`, clamped to 0–88. Integer shifts
apply to positive step values. The checked source contains the complete step
table; changes require updating/versioning the candidate fixtures.

Hand-derived golden for source/decoded samples `[0, 7, -7]`:

```text
42534130 01010100 803e0000 03000000
0000 00 00 0300 0100 e4
```

The first code 4 at step 7 reconstructs +7 and advances index to 2. The next
code E at step 9 reconstructs a delta of -14, giving -7. This fixes predictor,
index update, rounding, signedness, and nibble order independently of an encoder
round-trip claim.

The decoder validates the complete immutable container before any output and
uses one 160-sample stack buffer. Each callback receives at most 10 ms of mono
PCM; returning false stops before the next block. This is **not a measured
preemption guarantee**: upfront validation, device scheduling, stereo expansion,
I2S blocking, silence drain, and safety audio admission are not integrated.
The input must remain immutable across validation and decode. A codec-valid
container still needs separate hash/signature verification before future use.

## Initial host results and unresolved budget

The deterministic byte measurements are:

| Duration | Mono PCM | Existing stereo PCM | BSA0 candidate | Fits proposed 64 KiB asset |
| --- | --- | --- | --- | --- |
| 3 seconds | 96,000 B | 192,000 B | 26,416 B | Yes |
| 8 seconds | 256,000 B | 512,000 B | 70,416 B | No |

The 160-frame blocks allow bounded decode delivery but add 8-byte headers and
padding. Do not raise the dynamic limit just to hide this result. Compare larger
blocks with sub-block cancellation, mono PCM, and ADPCM on both devices before
selecting the production format; retain generic fallback for oversized speech.

The harness prints host decode microseconds including output collection and
marks `physical_evidence=false`. Timing varies by compiler, sanitizers, host,
and load. The synthetic triangle signal is test-owned, generated only in
temporary storage, and is not a licensed resident voice or acoustic test.

## Prepare pending resident recordings

`prepare_pack.py` accepts **already owned/licensed** mono PCM16 WAV recordings
at 16 kHz. It does not synthesize Apple system voices, acquire a license, download
assets, or validate a legal entitlement. The provenance field is a declaration
to review, not proof of ownership.

Create a local specification with exactly these fields:

```json
{
  "schemaVersion": 0,
  "packID": "english-metric",
  "version": "0.0.1",
  "locale": "en-GB",
  "units": "metric",
  "provenance": "REPLACE WITH REVIEWED RECORDING PROVENANCE",
  "noticesFile": "NOTICES.txt",
  "assets": {
    "continue": {"file": "continue.wav", "sourceSHA256": "REPLACE WITH SHA256"}
  }
}
```

The abbreviated `assets` example is deliberately rejected until all 39 keys
exist: each of `straight`, `slight_left`, `left`, `sharp_left`, `slight_right`,
`right`, `sharp_right`, `u_turn`, and `roundabout`, suffixed with `.50m`, `.100m`,
`.200m`, or `.action`, plus `arrive`, `rerouting`, and `continue`. Full phrases,
not word fragments, belong in these recordings. SHA-256 is of the input WAV.

```sh
python3 tools/spoken_directions/prepare_pack.py \
  /absolute/path/to/recordings/spec.json \
  /absolute/path/to/prepared-voice.bpk0 \
  --maximum-bytes 3145728
```

The explicit payload budget is a caller-selected preparation limit (3 MiB in
this example), not measured available space. The host safety ceiling is 4 MiB.
Each input WAV is bounded to 128000 frames plus 64 KiB container overhead.
The tool rejects unknown/missing/duplicate semantics, extra fields, wrong locale
or units, empty/oversized provenance, empty notices, wrong WAV formats, truncation,
input hash mismatch, absolute/escaping/symlink paths, and existing destinations.
Inputs are relative to the specification directory. Use a private stable input
directory; the local tool is not a sandbox for concurrently attacker-modified
recordings. Only hashes and bounded preparation status are printed.

Output is reproducible **unsigned preparation data**, not `.bspk`:

- 16-byte header: magic `BPK0`, schema byte 0, unsigned flag byte 1, zero u16,
  u32 canonical-manifest length, u32 payload length;
- ASCII canonical JSON, sorted keys and compact separators, at most 32 KiB;
- contiguous mono PCM16LE assets sorted by semantic key, with checked offsets,
  lengths, frames, and SHA-256 in the manifest;
- provenance and a digest of the external notices; preserve those notices with
  the recordings for later review.

No loader is added to firmware. The header and `unsigned-measurement-only`
purpose prevent this preparation from masquerading as a trusted production
pack. Only a future reviewed signer/installer may produce and admit the final
signed format. Interrupted output creation can leave an incomplete file;
there is no ready/activation state, and the command never overwrites it on retry.

## Remaining gates before product integration

Local pre-publication evidence (macOS arm64, Swift 6.3.3, Apple clang 21):

- Swift/C++ host proof passed, including C++ AddressSanitizer and UBSan.
- Root tooling: 110 tests passed, including 13 new prototype/preparation tests.
- Workflow routing/policy: 80 tests passed.
- Generated BLE contract verification and whitespace checks passed; the
  production BLE contract is unchanged.

These results do not represent remote CI, firmware builds, or device tests.

- Real licensed/owned voice recordings and provenance review; no production
  recordings are included in this PR.
- Protected BLE throughput with navigation/GPS/workout load, on both boards.
- Firmware-API-to-horn start latency, guidance cancellation, and intelligibility.
- Internal/DMA/PSRAM largest blocks and minima with required display allocations,
  maps, authentication, TLS, decode, and candidate dynamic cache.
- SD/FFat read/write latency, installation reserve, wear, and power-loss behavior.
- Explicit codec/block-size/cache selection from that evidence.
- Generated production contract, priority speaker integration, signed installer,
  scheduler/classifier, app UX, dynamic synthesis/prefetch, and full release matrix.

The current PR must not close #77 or be described as feature-complete. These
pending gates are not waived by host tests, a connected 1.75 board, a draft PR,
or instructions to prepare assets.
