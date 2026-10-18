# Browser USB recovery

The consumer page is **https://bicino.com/update**, implemented in the separate
`seichris/bicino` repository. This change adds the signed package producer and a
quiet USB status implementation for qualification. It does not publish a firmware
release, enable a consumer package, flash hardware, or complete issue #483.

## Release package contract

The existing protected publisher calls `tools/web_flasher_manifest.py` only after
validating and signing the factory archive. Candidate build jobs remain without
release credentials. The generator re-verifies the complete archive/attestation
chain and emits a `.web-recovery.json` envelope plus individually hashed images.
It never signs the merged factory image as an ordinary recovery operation.

The envelope identifies schema 1, key `bicino-release-p256-1`, and `ES256-P1363`.
Its base64 payload is canonical ASCII JSON (sorted keys, no insignificant spaces,
one trailing LF). Sign `bicino-web-flasher-v1\n` followed by those exact bytes with
P-256/SHA-256, storing the 64-byte `r || s` signature in base64. Existing OTA and
factory signature encodings are unchanged. The browser verifies the signature
before interpreting offsets and rechecks all artifact SHA-256 values before any
write. `tools/web-flasher/test-vector.json` is a public test-key fixture shared
byte-for-byte with the website; it must never be admitted as a real release.

Each payload binds the model, production profile, full SHA, version/build, chip,
16 MiB capacity, exact binary table and bootloader hashes, complete flash region
inventory, ordered writes and erase spans, and factory archive/descriptor provenance.
New packages sign `minFlasherVersion=2`, `unknownBuildPolicy="rescue"`, and
`qualificationRequired=false` together. The website automatically admits these
packages from immutable published GitHub releases after checking signatures and
asset digests. Legacy version-1 deny packages, including release 9, retain their
qualification requirement and cannot be changed in place. A signature proves
origin; automatic availability is not physical qualification. The original
`test-vector.json` remains the legacy fixture; `rescue-test-vector.json` binds
the new policy using the same public test key.

The implemented recipe supports the existing dual-3-MiB layout only. It writes
and verifies app0 before replacing OTA selection with the pinned Arduino app0
bootstrap. It preserves bootloader/table, app1, NVS, FFat, coredump, and SD. This
deliberately uses a named deterministic ROM rescue recipe rather than pretending
that factory bootstrap replay is an inactive-slot OTA transaction. Both initial
active-slot states still need physical evidence for a qualification claim. The
rescue planner accepts unknown development images, stale app1, partial/erased
application slots and partial OTA selection, allowing a fresh-session retry after
interruption. It never writes app1. Exact bootloader/table, chip/capacity/security,
model confirmation, signed write bounds and every image readback remain required.
Known wrong-model/newer/conflicting builds are blocked; unidentified firmware
cannot provide downgrade protection and the user must acknowledge that risk.
Fully blank chips and damaged bootloader/table remain incompatible.

The new producer rejects unsupported layouts/bootstrap bytes rather than silently
emitting unsafe packages. Future partition/toolchain changes must update and test
this contract before using the release workflow. No migration is inferred from a
larger application binary.

## Quiet status protocol (qualification profiles only)

`USB_RECOVERY_STATUS` defaults to zero. Ordinary production and developer profiles
remain unchanged. Named `WAVESHARE_AMOLED_175_USB_RECOVERY_VALIDATION` and
`WAVESHARE_AMOLED_206_USB_RECOVERY_VALIDATION` profiles opt in while retaining
`FIRMWARE_DIAGNOSTICS=0` and `ARDUINO_USB_CDC_ON_BOOT=0`. They use a dedicated HWCDC
instance, so existing Serial/UART diagnostics are not redirected to USB.

The only accepted command is ASCII `BICINO_USB_STATUS 1 ` followed by exactly 32
lowercase hexadecimal nonce characters and LF. The response is one bounded JSON
line with type/schema, the same nonce, target/profile, version/build, full SHA,
binary partition-table SHA-256, boot sequence, running app offset, chip MAC, and
readiness. MAC is used only to correlate the same physical chip inspected by the
ROM loader, after the user's local inspection consent. No credentials, TLS key,
location, or unsolicited diagnostics are returned. This is local operational
evidence, not cryptographic device attestation.

Input processing is bounded to 64 bytes per loop, a 64-byte parser buffer, a
one-second inter-byte timeout, and at most one reply per second. Replies are
smaller than 768 bytes and emitted only with TX queue capacity available. The
readiness bit uses the existing boot diagnostic milestone after initialization
and durable OTA confirmation. No storage or eFuse writes are exposed.

Qualification builds retain their distinct profile identity and cannot pass the
consumer's production-profile match. After both boards pass the quiet-USB power,
boot, parser, privacy, and interoperability gates, enable the flag in production
through a separate reviewed rollout. Do not substitute a validation-profile boot
for acceptance of actual production bytes. The page currently falls back to
owner-app boot confirmation when production firmware does not answer the protocol.

## Consumer admission and remaining gates

The maintainer explicitly accepted automatic signed rescue admission and the
unknown-source/interruption risks on 2026-10-03. Build 103 publishes that policy;
release 9 (build 102) stays immutable with its original deny policy. This change
modifies packaging/planning, not the firmware's production hardware paths or the
validation-only USB status rollout.

The website rechecks the still-published immutable release, pinned signature and
manifest digest immediately before writing, with an explicit revocation denylist.
No per-release qualification entry or website asset import is needed for the new
policy. Automatic admission must not be described as completed physical testing.
Qualification still binds exact website/firmware commits, manifest/image hashes,
board identity, flash/readback, fresh ready boot, real cold boot and preservation.
Only 1.75-inch hardware is available; its valid development app0 and stale app1
have been inspected read-only. No new rescue write or physical interruption test
has passed, and 2.06-inch physical validation remains pending.

Still required to close #483:

- Physical recovery from the reported 0.3.4 build-95 OTA-entry failure on both
  targets, including ownership/TLS/settings/maps preservation.
- Qualification and production rollout of the request-only status protocol.
- Physical interruption/retry evidence for app erase/write and OTA metadata.
  Mock browser tests cover fresh-session retry of unknown partial/erased slots;
  damaged bootloader/table remain blocked and require a separate procedure.
- #461's measured layout decision and matching developer layout, followed by a
  distinct migration recipe with overlap/erase analysis, FFat restore policy,
  and representative power-loss tests. No larger-slot OTA release before that.
- Separately qualified first-install and factory-reset operations if exposed.

Keep these per-target hardware gates visible until their evidence is complete.
Do not describe automatically available releases as a physically qualified
recovery path or factory/golden images. Development tests and merged PRs do not
replace physical records.
