# Offline-map lifecycle remediation

Base: freshly fetched GitHub main `fe73e43431ed76c39159de7624c4cd9ede509434`.
Branch: `fix/offline-map-lifecycle-durability`. Profile: **deep**.
Authorization: **publish** (source fixes, local verification, branch and PR;
not deployment, device access, flashing, physical tests or merging).
Strategy: **sequential-local**; subagents: **0**; severity gate: **P0/P1/P2**.

The prior architecture review's four lenses were revalidated against main:
code/integration/security, claims/spec/reachability, tests/verification, and
repository policy/hygiene. PR #388's Watch/BLE changes are not incorporated into
this main-based fix branch; the affected lifecycle implementations were unchanged.

## Persistent finding ledger

| ID | Priority | Boundary and remediation | State |
| --- | --- | --- | --- |
| C1 | P1 | Canonical job/index publication: durable intent, serialized reads and peer repair before indexed lookup | fixed+verified |
| C10 | P1 | Backend rollout/catalog delivery split: fail-closed catalog switch at grant creation and resolution; coordinated incident runbook | fixed+verified |
| C2 | P2 | iOS artifact/metadata replacement: persisted commit decision and idempotent startup rollback/cleanup | fixed+verified |
| C3 | P2 | Catalog and job downloads: shared immutable-identity background tasks, retained completion and bounded resume data | fixed+verified (local contract; OS lifecycle qualification outstanding) |
| C4 | P2 | Saved-map durability: Application Support, backup exclusion and legacy cache-directory migration | fixed+verified |
| C5 | P2 | SD checkpoint trust: compare persisted bytes to the rehashed retransmission without rewriting or whole-map blocking scan | fixed+verified (host installer; hardware qualification outstanding) |
| C8 | P2 | Source-fetch authority: exact approved HTTPS origins on primary URLs and every redirect | fixed+verified |
| C11 | P2 | Promotion child timeout: parent-owned scratch, inherited lease, safe orphan cleanup and capacity preflight | fixed+verified |
| C12 | P2 | Source catalog resources: byte/node/depth/feature limits before replacing validated cache | fixed+verified |

C3 correction: the existing background coordinator handles device **uploads**;
neither former download path was background-resumable. C6 (blanket missing
fsync), C7 (manual hardware matrix as a runtime defect), and C9 (production
missing App Attest) remain invalidated by current source, not silently deferred.

## Failure paths addressed

- **C1:** termination or ENOSPC after canonical JSON publication but before an
  index update hid the job from existing peers, allowing a duplicate idempotency
  key and undercounting admission. Fault injection now covers all four index
  boundaries and an actual child process exiting while holding the queue lock.
- **C10:** catalog library grants bypassed the backend rollout gate. Tests now
  disable new grants and resolution of pre-existing library/promotion bearers;
  both deployment environments have an explicit binding and generated-type check.
- **C2:** process termination after moving the previous artifact into a hidden
  UUID backup bypassed catch-based rollback. Five journal boundaries now test
  old/new pair selection and repeated recovery, including canonicalized Darwin
  file URLs. Cleanup happens after the durable commit decision.
- **C3:** catalog and job downloads lost process-local progress/completion.
  Host tests exercise the shared downloader and reconstruct a new coordinator
  that recovers completed bytes under a renewed grant URL without a second GET;
  HTTP failures never publish a completed artifact. OS-owned partial transfer
  recovery, suspension and force-quit behavior still require platform tests.
- **C4:** the OS could purge user-saved maps under Caches. Migration tests cover
  a normal upgrade and a downgrade/re-upgrade with conflicting saved filenames.
  Conflicts are retained outside Caches in `OfflineMapLegacyRecovery`, not
  overwritten or automatically deleted.
- **C5:** a size-only durable-prefix check accepted equal-length SD corruption
  and ignored correct retransmitted bytes. The native regression now rejects
  that exact case without producing a ready marker; valid resume still skips
  writes. The parser rehashes every retransmitted checkpointed payload.
- **C8:** a compromised source index/redirect could direct worker HTTP requests
  outside the provider. Initial and redirect URL tests reject non-HTTPS,
  loopback, credential-bearing, alternate-port and deceptive-host URLs.
- **C11:** timeout killed the CLI before its own temporary-directory cleanup.
  A real subprocess timeout now tests inherited lease ownership and parent
  cleanup; separate tests preserve a live lease and unrelated directories and
  prevent starting a child when capacity is insufficient.
- **C12:** an unbounded upstream read/JSON tree could exhaust API resources and
  overwrite the usable cache. Tests enforce byte/structural/feature limits and
  preserve the last valid cache after a rejected refresh.

## Deployment and compatibility contract

- Stop all old API/worker/maintenance processes sharing the job directory before
  upgrading its writers. Startup rebuilding handles legacy records; old binaries
  do not understand the new write intents and must not run beside new writers.
  Journal/index failures fail closed until storage is writable/repaired.
- Set the catalog delivery binding explicitly in staging and production.
  Emergency shutdown must also stop backend generation and automatic promotion.
  Already-issued R2 URLs, downloaded maps, and compiled device trust are separate
  revocation boundaries; see the updated stream rollout runbook.
- Automatic attempts now use a scheduler-private data root and an inherited
  lease. Startup reaps only released, scheduler-owned attempts. Legacy
  `/data/promotions` directories and manually started CLI work are not deleted:
  inventory and explicit operator approval are required for those older orphans.
- New iOS installations and normal upgrades retain saved payloads outside
  purgeable Caches; previews remain disposable. A persisted replacement journal
  chooses old or new artifact/metadata together after process interruption.
  Legacy UUID backups are recovered only when the missing target is unambiguous.
- Authenticated artifact digest/length identify background downloads independently
  of expiring URLs. Catalog authorization, final host constraints, full artifact
  checksums/signatures and reader checks remain required before installation.
  Legacy unsigned endpoints without immutable identity retain the foreground path.
  URLSession decides whether a partial response is resumable; unsupported resume
  or expired resume URLs may require a bounded fresh download. Force quit prevents
  automatic relaunch until the user opens the app again.
- The stream wire format and renderer requirements do not change. Both 1.75 and
  2.06 consume the same modified installer. Resumed payloads are rehashed and
  compared with SD bytes, but not rewritten. Corruption fails closed and requires
  discarding the paused transfer before retry. Resume cost now includes SD reads;
  physical throughput/watchdog/power-loss qualification remains outstanding.
- Converter/source changes require a separately qualified producer image and
  reviewed promotion. No production digest, trust material or approval gate is
  relaxed or regenerated merely to make this source patch deployable.

## Evidence

Source review retained the existing App Attest/service authentication, signed
producer and immutable artifact identities, catalog leases, generation-head and
alias transaction rules, manifest/renderer validation, owner-authenticated local
transfer, inactive-map install roots and rollback activation logic. No signing
key, production image digest, authorization threshold or reader contract changes.

Local evidence:

- Backend discovery suite passed (741 tests before the final additional promotion
  capacity regression; the nine-test scheduler suite also passed independently).
- Catalog `pnpm check`: formatting, generated-binding drift check, TypeScript,
  66 tests, and staging/production deployment **dry-runs** passed.
- `ios-app/scripts/run-navigation-tests.sh` passed, including real downloader
  delegates, journal/migration tests and Catalyst saved-map preview tests.
- Release iOS app-container build passed using the repository compiler wrapper
  with signing disabled and isolated DerivedData.
- Native C++17 stream installer suite passed with warnings treated as errors and
  Mbed TLS 2.28.10. Deployment configuration tests: 55 passed. Workflow policy
  tests: 73 passed.
- Read-only upstream compatibility sample: the Geofabrik index fetched on
  2026-09-07 was 3,790,471 bytes; all 555 regions passed the new bounds.

The confirming four-lens pass found no remaining source-backed P0/P1/P2 defect
in this remediation scope after fixing the Darwin path-normalization regression
and generated binding drift. Final committed-head verification and live CI are
reported in the PR; this document is not a release approval.

Evidence limits: no deployed service, physical device, real SDMMC power-loss,
1.75/2.06 watchdog/throughput or iOS background-daemon interruption test was run.
Background HTTP redirects are managed by iOS; final origins and full artifact
digests/signatures are checked before publication, not proof that every suspended
background request was inspected by app code. Partial resume depends on the
server/URLSession validators; a bounded fresh download remains necessary when
resume data is unavailable or stale. Already-cached/offline trust cannot be
revoked by the new catalog delivery switch. These remain rollout qualification
items, not evidence of deployed or physical success.
