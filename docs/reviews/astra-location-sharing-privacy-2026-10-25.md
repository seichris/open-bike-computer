# Location sharing and account isolation review — 25 October 2026

## Result and immutable target

**State: clean.** Five findings fixed locally: **2 P1, 3 P2; 0 active, 5 fixed+verified, 0 invalidated, 0 user-deferred**. Pass 2 found no additional actionable defects in the fix delta and affected contracts. Required local checks passed. Real authentication-provider, interactive UI and physical-device acceptance remain unperformed as detailed below.

- Worktree: `/Users/chris/.codex/worktrees/astra-six-reviews-20261025-c5e83d/location-sharing-privacy`.
- Immutable baseline/head/base/merge-base: `cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`; tree `36d1c7691bbcb20a5210b234e0820105599c7900`. Detached, initially clean; no pre-existing changes included. Origin: `git@github.com:seichris/open-bike-computer.git`. Baseline was not moved or refetched.
- Mode/profile/strategy: **fix-local / deep / sequential-local**, zero subagents. Gate **P0/P1/P2**. Requested review profile: GPT-6 Astra, Max reasoning. On 26 October 2026 the user authorized **publish** mode for this batch (commit, push a branch, open a PR to `main`; no merge or auto-merge); see "Publication and integration".
- Pass count: **2 of at most 3**. Pass 1 covered the architecture; pass 2 covered the fix delta, affected callers/contracts and every prior finding. Both applied all four lenses. Stop after the clean confirming pass.
- Risk: **high** because sharing consent, account isolation and access revocation are privacy boundaries.
- Tested source patch SHA-256: `07e3df07be2ab0d93c4b9d02f31f0638a693dee4e946b8401c5bfd0f7d2a4900` (33,705 bytes). This includes all tracked source/test/graph changes plus the new loader, and excludes this report. Retained as `ios-app/build/privacy-review/source.patch`.
- Runner working-state SHA-256: `331fb0bf1692766f4c76a1692ee20ba754f8f45923940ba2ba23f0ac5c70942e`. It includes the earlier report draft. Only this report's prose changed after verification; the executable source patch was rehashed unchanged at handoff.
- During the review all changes stayed unstaged and uncommitted in this worktree, with no pushes, PR edits, CI dispatches, deployment, release or signed result publication. This review did not modify any sibling review worktree or the original checkout. The later publication is recorded separately below.

## Persistent finding ledger

All five findings have high confidence. Locations below refer to the final local files; the retained patch records their baseline locations.

| ID | Severity | State | Trigger, impact and concrete evidence | Fix and verification |
| --- | --- | --- | --- | --- |
| ASP-001 | P1 | fixed+verified | Open a previously stopped ride from **My Group Rides**, including after relaunch. The actual caller used `select(..., shareOnJoin: true)`, minting a new location/stats consent lease without a new Join action. This bypassed the service's safe default. | `SocialHubView.swift:77` uses viewing-only selection; line 400 provides a separate disclosed sharing action. Fresh create/join/accept still explicitly opt in. `SocialRuntimeTests.swift:193` checks fresh join, stopped reopening, reopening in a new service instance, and explicit resumption. The actual SwiftUI caller was inspected and compiled. |
| ASP-004 | P1 | fixed+verified | Keep a link view alive across account switch, then deny the replacement read. Unscoped profile/content/preview `@State` retained the earlier account's geometry and local Save action. Client request fencing did not invalidate already loaded view state. | `SocialLinkLoader.swift:33` hides snapshots with a different account generation or URL immediately; lines 43–63 clear replacement state and fence late responses. `SocialLinkView.swift:78` uses a cancellable task keyed to account/state/link; `SocialHubView.swift:10` retires descendant navigation state on account change. `SocialRuntimeTests.swift:513` exercises loaded data, denied replacement, delayed old-account responses and overlapping links. |
| ASP-002 | P2 | fixed+verified | An incoming friend snapshot starts before successful removal and completes after `forget`. The old implementation removed the current array element but allowed the pending response to restore that person's coordinates. The delayed-snapshot fixture failed on the baseline implementation. | `FriendLiveService.swift:395` rotates the generation, durably removes the saved consent, clears stale pending actions, updates riders and restarts polling while retaining other leases. `FriendLiveServiceTests.swift:127` releases the pre-removal snapshot after forgetting the rider and verifies it stays absent. |
| ASP-003 | P2 | fixed+verified | Reset/select another room while old messages, reconnect authorization or Leave's stop await. Late continuations restored old private messages, cleared the replacement room, or issued a retired Leave. All three controlled races failed before fixes. | Epoch/cancellation checks at `LiveRideService.swift:193`, `:380` and `:398` fence reconnect, Leave and messages. Send follow-up and late expiry/error notices receive the same room boundary. `SocialRuntimeTests.swift:548` exercises the three delayed response scenarios and the new-room invariant. |
| ASP-005 | P2 | fixed+verified | After the bounded token refresh, definitive `authentication_required`, `account_deleted` or `identityMissing` was treated as transient by live services. Room/position state or outgoing friend GPS demand and saved consent survived confirmed loss of authority. Each error reproduced for friend sharing and room recovery. | `SocialFailure.endsAccountSession` in `BicinoSocialClient.swift:12` distinguishes terminal identity loss from provider/network outages. Friend read/publication handlers (`FriendLiveService.swift:306`, `:356`) and group recovery/publication handlers (`LiveRideService.swift:210`, `:336`) reset their local state. The focused runtime regressions cover all three errors in both services; existing outage/reconnect tests continue to pass. |

File prefixes: native services are under `ios-app/BikeComputer/BikeComputer/Services/`, native views under `ios-app/BikeComputer/BikeComputer/Views/`, and Swift fixtures under `ios-app/BikeComputerTests/`.

## Behavior and contract matrix

| Conditions | Expected result and reviewed evidence |
| --- | --- |
| Fresh explicit join/create vs opening an existing room | Disclosed join/create may start sharing. Reopening stays stopped until explicit sharing. Verified native caller and runtime fixtures. |
| Friend toggle, Stop, offline restart | Restoration stays bound to the original account, installation, consent epoch and deadline; publication sequences are durably reserved. Stop persists before network work. Existing runtime fixtures remain green. |
| Remove/block while friend snapshot is pending | Server revokes both directional friend consents; the native generation prevents an old marker from reappearing. Removing friendship alone intentionally preserves independently accepted group membership. |
| Leave/reset/select while room requests await | Retired room messages, recovery and Leave cannot mutate the replacement selection. Tested with held responses. |
| Account switch with ephemeral link data | Earlier account data disappears before replacement authorization; denied reads cannot fall back to old geometry. Tested loader and inspected/compiled SwiftUI wiring. |
| Disabled/deleted/revoked identity vs outage | Definitive account loss clears local publishing demand and ephemeral live data; provider/network outage retains bounded retry. |
| Member removal, block, room end/expiry | Current account/member/block/consent checks govern new reads, writes and socket snapshots. Reviewed `require_member`, `ride_read`, `publish`, SERIALIZABLE transactions, account locks and periodic socket reauthorization. PostgreSQL social suite passed. |
| Visibility, links and invitations | Protected reads recheck current authorization; replay receipts return current state and cannot recreate revoked capabilities or geometry. Reviewed invitation preview/accept, content access and replay paths; backend fixtures passed. |
| Shared route ownership | Snapshot archive/hash/provider/owner and provenance remain intact. Recipients cannot republish exposed route geometry by changing IDs or reversing points. Reviewed native route-sharing logic and server fingerprint/ownership checks; fixtures passed. |
| Saved copies and public invitation cards | Deliberately saved local route copies survive revocation as disclosed. Public preview cards have a separately documented capability/lifetime from join codes. Neither is treated as an undisclosed revocation failure. |

## Review passes

**Pass 1, full architecture:** (1) code/integration/security traced native publishers, session and HTTP retry, profile queues, push binding/deletion recovery, device-only persistence, relay and server account/content/member/consent/invitation authorization; (2) specification/reachability compared actual app entry points against operations/privacy copy and the MapKit source-policy review; (3) tests inspected coverage, established a passing social baseline, and added controlled delayed-response reproductions; (4) policy checked `AGENTS.md`, `REVIEW.md`, `CONTRIBUTING.md`, PR template and development checks. No deeper instruction files existed. All four lenses completed before the fix batch.

**Pass 2, fix delta and affected contracts:** (1) checked generation/epoch fences across every changed await, snapshot replacement, persistence fallback and sharing teardown; (2) retraced My Group Rides, fresh join/create, explicit sharing, shared-link loading, account-change navigation and the offline/saved-copy contracts; (3) reviewed regression assertions, held-response ordering, full native compilation and broader registered checks; (4) rechecked graph registration, source identity, changed-path scope, local-only authorization and result-publication suppression. Reconciled all five IDs. **0 additional actionable findings; 0 active findings.**

Rejected candidates were contract distinctions: friendship is independent of accepted group membership; downloaded/saved copies cannot be recalled; public invitation cards are separate from join secrets. No P2 finding was deferred or dropped to fit the pass limit.

## Verification

Every runner command used this process-local publication override, without reading keys or modifying shared Git configuration:

```sh
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=bicino.localResultsKey GIT_CONFIG_VALUE_0=''
```

All final runner commands used `--base cd7ad00bb6c4f9566195cd44ab4d6a675518b94d`. Reports/logs are retained under the ignored, worktree-private `ios-app/build/privacy-review/`. All checks were executed locally; **none reused signed results or published a receipt**.

| Command / selection | Classification and evidence |
| --- | --- |
| `tools/dev-setup`; `tools/dev-setup --map-backend --quiet` | Passed. Host Python 3.13.14; backend Python 3.11.7. Initial interrupted backend setup resumed safely. |
| `tools/dev-env tools/dev-check --check social-riders-host-tests --check social-runtime-tests` | Relay host passed (1.6 s); initial runtime run was interrupted and is not counted. `baseline-host.json`. No firmware build or physical action. |
| `tools/dev-env tools/dev-check --check social-runtime-tests` before edits | Passed (12.5 s), `baseline-social.json`. |
| Same social check with new reproductions before production fixes | **Related failure (expected reproduction)**, ten reproduced assertions for ASP-002/003/005 (57.6 s), `privacy-red.json`. Retained failure log identifies each scenario; this is not a final unresolved failure. ASP-001 was established through the actual caller; ASP-004 through retained view-state flow and post-fix loader regressions. |
| Same social check on the fixed source | Passed (42.7 s), `privacy-green.json`; includes consent/relaunch, delayed room/friend responses, link isolation, terminal identity errors, outage retry, account-scoped persistence, push/deletion and relay contracts. |
| `tools/dev-env tools/dev-check --check development-tools --check ci-routing` | Passed (18.8 s / 0.9 s), `policy-checks.json`. |
| `tools/dev-env --map-backend tools/dev-check --check map-backend-tests` | Passed (141.1 s runner; 134.127 s suite), **1,023 tests, 3 skipped**, `backend-final.json`. Skips: PostgreSQL-only concurrent duplicate test and two Linux `/proc` peak-memory tests. The PostgreSQL test was subsequently exercised below; the Linux memory tests are outside this native privacy delta. |
| `BICINO_SOCIAL_TEST_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:32768/social_test tools/dev-env --map-backend python3 -m unittest discover -s map-platform/backend/tests/social -v` | Passed, **79 tests in 101.650 s, no skips**, `postgres.log`. Dedicated PostgreSQL 17.6 container on OrbStack, including concurrent duplicate-request serialization. Container and anonymous volume removed afterward. No production credentials or accounts. |
| Automatic affected fast checks, excluding already executed social and policy checks | Passed, **14 of 14 checks** (1968.1 s total check time). Full 14-check selection and per-check logs in `affected-fast.json`. |
| `tools/dev-env tools/dev-check --check ios-build-containers` | Passed, **unsigned Debug and Release iOS and embedded Watch containers** (1,113.1 s), `native-build.json`. Repository wrapper and leased worktree-specific DerivedData; signing disabled. |
| Final `git diff --check`, unchanged HEAD, empty index and source patch rehash | Passed. HEAD unchanged, index empty, no whitespace errors, and executable source patch rehashed unchanged. |

The 14 affected fast checks cover generated build identity; navigation map/sensors/workout/radio; ride diagnostics recorder; shared route/Watch BLE; the complete Watch source graph; Watch offline persistence and online navigation policy; workout/legacy firmware compatibility; and durable, bounded and paired diagnostics contracts.

The exact additional affected-check selection was:

```sh
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=bicino.localResultsKey GIT_CONFIG_VALUE_0='' \
  tools/dev-env tools/dev-check --base cd7ad00bb6c4f9566195cd44ab4d6a675518b94d \
  --check ios-fast-test-generated-app-build-identity \
  --check ios-navigation-map --check ios-navigation-sensors \
  --check ios-navigation-workout --check ios-navigation-radio \
  --check ios-fast-run-ride-diagnostics-recorder-tests \
  --check ios-fast-run-shared-route-and-watch-ble-contract-tests \
  --check ios-fast-type-check-the-complete-watch-source-graph \
  --check ios-fast-run-watch-offline-navigation-persistence-tests \
  --check ios-fast-run-watch-online-navigation-policy-tests \
  --check ios-fast-run-workout-contracts-and-firmware-to-swift-legacy-compatibility-tests \
  --check ios-fast-durable-diagnostics-acquisition-contracts \
  --check ios-fast-bounded-diagnostics-capture-policy-contracts \
  --check ios-fast-paired-diagnostics-broker-contracts \
  --report ios-app/build/privacy-review/affected-fast.json
```

The earlier full backend suite itself passed, but its runner rejected the changing worktree identity while native edits were in progress. That result (`backend-baseline.json`) was **superseded**, not used as final evidence. `backend-final.json` reran successfully on the frozen source. All final executed reports record the same tested working-state identity above.

## Limits, changed files and recovery

Local fixtures, SQL tests and unsigned compilation do not prove real Firebase provider login/logout behavior, interactive SwiftUI account switching, physical/background GPS, Bluetooth delivery, hardware Keychain behavior or App Store signing. These were not exercised. No live account, user data, physical device, serial connection, installation or flash was used. No firmware build was needed. No GitHub CI or deployed behavior is claimed.

An offline Stop immediately stops this phone's publisher and records the local choice; already delivered or in-flight bytes cannot be recalled, and the last live fix expires within the documented freshness window (under 60 seconds). Account sign-out here does not claim to revoke every other device's Firebase session. Deliberately saved route copies remain independent.

Loop-owned changes are limited to `BicinoSocialClient.swift`, `FriendLiveService.swift`, `LiveRideService.swift`, new `SocialLinkLoader.swift`, `SocialHubView.swift`, `SocialLinkView.swift`, `FriendLiveServiceTests.swift`, `SocialRuntimeTests.swift`, `tools/development/swift-sources.json`, and this report. No backend, protocol, privacy-policy or deployment changes were necessary.

Recovery before publication: inspect the retained source patch and restore only these loop-owned paths to the recorded baseline if the approach is rejected; remove the new loader/report only after confirming they remain solely this review's work. Never reset/stash the user's original checkout or another review worktree. A later native release must follow normal signing/App Store gates; reverting a server alone cannot retract shipped native code or downloaded data.

After publication, recovery is to close the unmerged PR, or revert the single merge/commit through a new PR if it has already landed. No backend, protocol or data migration needs rolling back; shipped native builds follow the App Store path above.

## Publication and integration (26 October 2026)

- Authorization: the user asked to commit these five fixes and this report, push a new branch and open a PR to `main`, without merging or enabling auto-merge. No deployment, release, device install/flash or signed result publication.
- Before publishing, the working tree was rehashed: the executable patch still matched `07e3df07…2a4900` exactly, with an empty index and HEAD at the baseline.
- Base drift: `main` had advanced to `964bdbfe333b6f30c54c244c6319e7e1e55c7f04` (87 commits, 186 changed paths, merge-base still `cd7ad00b`). Only `tools/development/swift-sources.json` was also changed, in a separate hunk (`TopographyContourSection.swift`), so it merged without conflict. No social service, view or test, no social backend/relay path, and no `social-*` check definition changed on `main`.
- Integration inspection: the two `main` changes that touch the reviewed surface were checked against the fix contracts. `BicinoServiceSession.swift` now also requires App Attest for a matching DEBUG LAN qualification origin. That changes how installations register, not the account generation or the `SocialFailure` classification the fixes rely on. `SettingsView.swift` still constructs `SocialHubView(store:routeLibrary:)`, whose signature is unchanged. No changed contract required a new delta review pass, so the count stays at **2 of 3**, with **0 active findings**.
- The branch was rebased onto the new `main`, so the published commit has `964bdbfe` as its parent. The verification table above is **historical** evidence for the `cd7ad00b` working state. Validation of the integrated, committed head and the CI state are recorded in the PR description, not here, because recording them in this file would change the head they describe.
