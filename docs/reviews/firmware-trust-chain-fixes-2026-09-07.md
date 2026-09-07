# Firmware trust-chain remediation

Original remediation base: freshly fetched GitHub main
`fe73e43431ed76c39159de7624c4cd9ede509434`.
Branch: `fix/firmware-trust-chain`. PR #388 was still open at original dispatch.
The later integration includes merged #388, #421 and #423 through main
`c3e2bbc641834a159b850abe04f85b4da36ac21a`.

Protocol: deep / publish / sequential-local / zero subagents / P0/P1/P2.
The initial four-lens pass revalidated the six review findings against unchanged
main. Subsequent passes cover code/integration/security, claims/reachability,
verification strength, and repository policy independently before reconciliation.
The original source-delivery stage changed no devices, production settings,
secrets, release tags or release assets. Subsequent user-authorized environment
and tag-rule administration is recorded below. The dirty primary checkout is excluded.

## Behavior matrix and persistent ledger

| ID / severity | Contract and implementation | Verification / state |
| --- | --- | --- |
| FWR-001 P1 | Check explicit environment review policy, exact default-branch admission, key scopes, strict protected-main gate and v* tag rules before signing | **Active administrative blocker**: environment/tag controls now configured; maintainer explicitly chose self-review. App environment copies are present, but authentication and firmware-key migration remain unexecuted. Repository copies remain until destination proof. See continuation below. |
| FWR-002 P1 | Emit full SHA; compare full BLE/pending identity; only two explicitly mapped immutable legacy tuples | Signed publisher CLI fixture, real manager current/relaunch reconciliation, arbitrary-prefix rejection; fixed+verified at host level |
| FWR-003 P1 | Strong Arduino deferral hook; confirm only after application finalization, read back VALID; on failure reject pending/reboot before ready | Both target definitions compile the actual confirmation bodies and linked hook against faulting host APIs. Physical rollback gates remain OPEN; fixed+verified at source/host level, not physically qualified |
| FWR-004 P2 | Production boot acceptance through existing authenticated persistent diagnostics, preserving no-CDC policy | Compile actual metadata formatter and privacy filter for both profiles; parse and reject wrong target/profile/SHA/build/boot/state. Requires working SD for capture, not for OTA. Fixed+verified at host level |
| FWR-007 P2 | Build 94; scan all historical published manifest allocations and reject reused/regressed build before signing; serialize channel and explicit older recovery | Live maximum 93; tests for equal/lower/invalid builds, out-of-order publication, higher-build implementation rollback, paginated inventory/digest/target pair and recovery override. Fixed+verified at source/host level |
| FWR-010 P2 | Stream metadata ≤2 KiB and image ≤signed size/3 MiB; incremental hashing; HTTPS-only initial/redirect URLs | URLProtocol tests for unknown/false lengths, oversize, exact boundary, truncation/hash mismatch; redirect-policy checks. Fixed+verified at host level; no physical memory-pressure or wire-level compression test |

Prior rejected independent findings FWR-005 (profile substitution without a
signer bypass), FWR-006 (no existing expiry promise), FWR-008 (unproven physical
compromise), and FWR-009 (intentional ordinary CI coverage) remain invalidated
in this remediation ledger; this work does not silently claim their residual
architectural risks are solved. No P0 established, no user-deferred items.

## Verification record

- Baseline: 73 workflow-policy tests and 11 firmware-tool tests passed.
- Updated repository-tool suite: 82 tests passed; workflow-policy suite:
  76 passed; selected firmware profile/build-identity/build-helper/generated-SDK
  suite: 125 passed. Synthetic helper-test build messages are not real firmware
  artifact evidence.
- Frozen portable Swift suite passed: navigation/protocol tests (including
  bounded downloads and actual pending-update reconciliation), renderer host
  tests, cycling sensors, destination layout, map appearance and saved-map
  Catalyst tests. The opt-in live MapKit smoke test was not run.
- Full iOS application build passed with the repository Xcode wrapper,
  generic iOS destination, fresh DerivedData and signing disabled. No install.
- Host fault harness compiles the actual `markRunningAppValid` and
  `rejectRunningApp` implementations with the strong startup hook for both
  Waveshare macros. This is **not** a full firmware link or ESP-IDF emulator.
- Existing release manifests and signed factory manifests independently
  establish the two legacy full-SHA mappings. No real signing key used.
- Read-only live release history returned builds
  `93,92,91,90,89,88,88,87,86,86`; new build 94 passed the history gate.
- Original live control preflight failed closed on the missing `firmware-release`
  environment. That failure is expected evidence of FWR-001, not a passing
  deployment rehearsal. No administration setting changed in that original stage.
- The first full host suite caught an introduced diagnostics allowlist mismatch;
  the Swift, firmware and Python allowlists now include the same four non-secret
  boot identity/state fields. A Swift run overlapping an edit was discarded and
  rerun on frozen inputs. A local Python HTTPS check initially lacked CA roots;
  rerunning with the system CA bundle succeeded, without disabling TLS validation.
- One full Swift attempt failed the unchanged offline-map compatibility-archive
  orphan-cleanup assertion; it did not recur on retry or the independently
  compiled prior-review baseline (that map implementation is identical to main).
  The new pending-update test initially starved the main actor; changing the
  test to await its asynchronous reconciliation fixed the test harness. No map
  implementation changes were bundled into this firmware remediation.

Exact committed-head local results, PR identity and CI conclusions belong in the
PR validation record; pre-commit host results alone are not remote-head evidence.
No full local firmware build, physical boot, fault injection, flash readback,
rollback, rescue or no-SD device test is claimed. Ordinary PR CI builds 1.75
profiles; it does not substitute for separate 2.06 qualification.

## Remaining release/merge gates

1. Administrator migrates private keys into protected environments, coordinates
   runtime publication, applies the explicit single-maintainer approval policy, and
   reviews the live read-back and a test-key rehearsal. See the factory runbook.
   Self-review is not independent review. Moving a key does not revoke historical signatures; assess exposure history
   and key rotation separately.
2. Both production artifacts require effective SDK configuration/linked hook
   evidence and the physical matrix in `firmware-ota-hardware-validation.md`.
   Do not release/tag/distribute as factory/golden. Merge requires either that
   qualification or explicit recorded maintainer acceptance of the open risk.
3. Ship the companion app with full-SHA migration/diagnostic export support and
   independently validate authenticated reconnect, confirmed boot, and the
   outstanding SD migration matrix.

The repository fix can be reviewed and published as a PR without pretending
that FWR-001's live administrative boundary or physical qualification is complete.

Three sequential four-lens passes (initial revalidation, integration review,
fresh confirming review) found no remaining introduced source defect after
verification corrections. Ledger: 5 fixed+verified at source/host level,
1 active administrative blocker, 4 invalidated, 0 user-deferred. Hardware and
exact-head CI remain separately reported gates, not inferred from this count.

## Single-maintainer policy and encrypted migration preparation

Continuation input head: `c4c6b33188ca2d82edcd054ea151cf70c931f913`.
The maintainer explicitly confirmed self-review and authorized preparation of
the existing-key migration, retaining originals until verification. No new
firmware key is generated and the embedded firmware trust anchor is unchanged.

Live metadata read-back on 2026-09-07: `firmware-release` requires `seichris`,
allows self-review, and admits exact branch `main`; release-tag ruleset 22420508
allows only user 25006584 as bypass actor. Both environment App-key copies are
present. The firmware environment key is absent; both repository copies remain.
The updated read-only control check accepts the explicit self-review policy but
fails closed on the absent firmware environment key. Metadata presence does not
prove new App-key authentication. No live key was consumed or migrated by this
preparation, and no migration workflow was dispatched.

| Boundary | Implementation and proving evidence |
| --- | --- |
| Explicit approval | Checked-in single-maintainer policy; exact reviewer and tag-bypass identity tests; independent mode still rejects self-review |
| Source identity and destination | Canonical P-256 scalar must derive the existing firmware public key; fixed environment, read-only runner token, stdin sealing, recipient-key read-back and domain-separated signed receipt |
| Execution provenance | Owner/main/first-attempt workflow guards; current-main, strict admin CI Gate, environment admission and App-key metadata checks; full synthetic context tests |
| Operator installation | Signed receipt bound to selected successful run/SHA, main ancestry and destination public key; ciphertext-only PUT; existing destination rejected; no delete implementation |
| Destination proof | Destination scalar metadata must predate dispatch; loaded key matches firmware trust and signs proof; repository fallback and changed metadata rejected |
| Secret handling | Captured child output, stripped scalar/debug environment, generic errors; synthetic tests assert no scalar in argv, inherited child environment, receipts or failure output |

Local synthetic tests use workstation cryptography 48.0.1; the workflow uses the
existing content-locked signing requirements (cryptography 50.0.0). Remote runner
execution, actual GitHub sealed-box encryption/decryption, App authentication and
live destination proof remain unexecuted. The runbook explicitly preserves the
runner/OS/actions/dependencies/CLI/control-plane trust boundary and GitHub PUT's
non-atomic check/create interval. No production credentials are used in tests.

The workflow must first land on reviewed main. This is not authority to merge
the broader hardware-gated PR: complete/accept those gates or use a separately
reviewed administrative-only prerequisite. FWR-001 therefore remains active;
source preparation alone is not closure. Original ledger counts remain
5 source/host fixed+verified, 1 active, 4 invalidated, 0 user-deferred.

Continuation verification: all 97 repository-tool tests (including 15 synthetic
migration tests), all 78 workflow-policy tests, YAML parsing and `git diff
--check` passed. A frozen sequential four-lens pass covered data flow/integration,
reachable claims, test strength and repository/PR policy; no additional in-gate
source defect was established. The published-head confirmation and CI results
are recorded separately in the PR. The live administrative blocker and physical
gates are not reclassified as passing by these source checks.
