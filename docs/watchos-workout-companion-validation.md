# Watch workout companion validation record

This is the release evidence ledger for the paired Apple Watch, iPhone, and
ESP32 workout companion. A checked result requires evidence from the exact build
identified below. Unit tests and Simulator results never satisfy a physical
criterion.

## Candidate identity

| Field | Value |
| --- | --- |
| Branch | `feature/watchos-workout-companion` |
| Phase 6 base | `cf52c1a26d4068f72d45dab216fb27535a580f92` |
| Main integration checkpoint | `3b583669de7141c37f00d1f05713f46aced0fa1c` (includes `origin/main` / PR #111 at `e90118509d517bd34e0e5adabfb2f197fcd3ee23`) |
| Candidate code commit | `5b8ff66232999d7ad5f4ce81ab094d7b5fae4484` (`1.1 (6)`; supersedes the earlier `1.0 (3)` candidate because App Store Connect already contains distributed version 1.0 and builds through 5) |
| Signed-archive provenance | `/tmp/open-bike-watch-companion-1.1-6-5b8ff662-20260720.xcarchive`, built from exact candidate code commit `5b8ff662` with only the evidence ledger changed afterward |
| iPhone build | Exact-candidate `1.1 (6)` Apple Development-signed Release archive passed strict signature validation and was installed on an iPhone 16 Pro Max running iOS 26.5.2 through Xcode's paired network connection, 2026-07-20; Xcode and `devicectl device info apps` report installed bundle `LetItRide.BikeComputer` at `1.1 (6)`; pending final launch/matrix and App Store distribution export |
| Watch build | Exact-candidate embedded `1.1 (6)` Apple Development-signed Release archive passed strict signature validation and was installed on an Apple Watch Series 8 running watchOS 26.5 through Xcode's paired network connection, 2026-07-20; Xcode and `devicectl device info apps` report installed bundle `LetItRide.BikeComputer.watchkitapp` at `1.1 (6)`; final launch/matrix plus App Store distribution export remain pending |
| ESP32 1.75 firmware SHA | Pending final candidate flash |
| ESP32 2.06 firmware SHA | Pending final candidate flash |

Record dates, OS versions, device models, firmware environment, and evidence
links or filenames with each executed run. Never copy results from a different
build into the final-candidate column.

## Automated and packaging gates

| Gate | Status | Evidence |
| --- | --- | --- |
| iOS 15 compatibility/typecheck | Passed | `./scripts/run-workout-contract-tests.sh` and navigation helper suite on the post-main candidate, 2026-07-20 |
| iOS workout unit tests | Passed | 36 tests, zero failures/skips, iPhone 17 Pro Simulator from behavior candidate `40b8e034`; release-identity candidate `5b8ff662` changes only project versions, release notes, and the enforcing asset test, 2026-07-20 |
| watchOS workout unit tests | Passed | 92 tests, zero failures/skips, Series 11 Simulator from behavior candidate `40b8e034`; release-identity candidate `5b8ff662` changes only project versions, release notes, and the enforcing asset test, 2026-07-20 |
| iOS device and Simulator builds with embedded Watch app | Passed with provenance split | Unsigned `1.1 (6)` iPhoneOS packaging check at `/tmp/open-bike-version-1.1-6` was built from the same version diff before checkpoint `5b8ff662` and identifies itself as dirty; prior exact-behavior unsigned iPhoneOS/Simulator Release containers cover candidate `40b8e034`. The exact committed release-identity candidate is covered by the signed archive below, not by those unsigned containers, 2026-07-20. |
| App Store release identity | Passed locally / pending editable version and upload | App Store Connect app `6788977349` has version 1.0 in `READY_FOR_DISTRIBUTION` and valid builds through 5. Both iPhone and Watch Debug/Release configurations resolve to marketing version 1.1 and build 6; six release-asset tests and target-linked project assertions passed, 2026-07-20. Creating an editable 1.1 version and uploading remain separately authorized actions. |
| Signed Release archive integrity | Passed for development signing / pending distribution export | `/tmp/open-bike-watch-companion-1.1-6-5b8ff662-20260720.xcarchive`; `xcodebuild clean archive` succeeded without provisioning updates, both nested signatures passed strict verification, iPhone/Watch/archive metadata all report `1.1 (6)`, archive format version is 2, and signing team is `4H5PK8686H`, 2026-07-20. The installed identities are development identities with `get-task-allow = true`, so this is not an App Store distribution export. |
| App Store distribution signing | Pending signing authority/assets | The iPhone bundle has an active App Store profile, but App Store Connect lists no Watch distribution profile and only a development certificate is available locally/remotely. Creating certificates/profiles or enabling provisioning updates requires separate authorization. |
| Installed-app launch smoke | iPhone passed / Watch blocked by live connection | `devicectl` launched `LetItRide.BikeComputer` successfully on the installed iPhone candidate. Repeated Watch launch attempts through `devicectl` and Xcode timed out establishing the network tunnel after its successful install/version query; Xcode Devices reports “Waiting to reconnect” with the same tunnel error. Open the exact installed Watch app manually before counting Watch launch, 2026-07-20. |
| `ValidateEmbeddedBinary` | Passed | Prior exact-behavior unsigned iPhoneOS/Simulator Release containers plus the exact `5b8ff662` development-signed Release archive, 2026-07-20 |
| iPhone HealthKit entitlement | Passed in signed Release archive | Signed application identifier `4H5PK8686H.LetItRide.BikeComputer`, team `4H5PK8686H`, and `com.apple.developer.healthkit = true`, 2026-07-20 |
| Watch HealthKit entitlement | Passed in signed Release archive | Signed application identifier `4H5PK8686H.LetItRide.BikeComputer.watchkitapp`, team `4H5PK8686H`, and `com.apple.developer.healthkit = true`, 2026-07-20 |
| Watch `workout-processing` background mode | Passed | Development-signed exact-candidate embedded Release Watch `Info.plist` contains `workout-processing` and points to companion `LetItRide.BikeComputer`, 2026-07-20 |
| iPhone and Watch privacy manifests in bundles | Passed | Source manifests matched the exact `5b8ff662` development-signed archive byte-for-byte and also matched the prior behavior-candidate unsigned containers; archive SHA-256 values are `5f51c506726d785bedd75dba4181b6a564dc0d0ca72de58858242ade6a24842b` (iPhone) and `521eb6ef8430773e5c010e1838fe9dd8fa5d62b7b76d1cea8d7d8daadcb144e2` (Watch), 2026-07-20 |
| Watch app icon in bundle / asset validation | Passed | Exact-candidate Watch `Assets.car` and `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName = AppIcon` verified; a mutated missing-metadata fixture is rejected, 2026-07-20 |
| In-app privacy-policy reachability | Passed automated / pending final tap | iPhone Settings and Watch start screen compile against one shared HTTPS URL; URL is present in both exact-candidate Release binaries and release-asset tests pass. Open it on the final installed build before submission. |
| App Store Connect privacy-policy URL | Configured / pending branch publication and final verification | App Store Connect already displays the documented GitHub URL. The current public `main` policy still predates the Watch/HealthKit and 30-day retention text, so the candidate policy must be published before final tap and submission verification. |
| App Store Connect App Privacy declarations | Published but stale / submission blocker | The authenticated App Store Connect dashboard reports the declaration was published 11 days ago and currently shows only **Precise Location** under **Data Not Linked to You**, used for app functionality. Candidate code and `docs/app-store-privacy-disclosures.md` require Precise Location, Device ID, Other User Content, and Product Interaction, all linked to the installation identity and not used for tracking. Update, review the product-page preview, and publish those answers before submission; no dashboard mutation was made, 2026-07-20. |
| Production privacy retention/provider contract | Pending authenticated production/provider check | Candidate compose defaults and policy agree on 30-day artifact retention, scheduled deletion, and equivalent provider protection, and the public production health endpoint returned HTTP 200 on 2026-07-20. Exact deployed environment values and provider contractual obligations could not be authenticated through the available Coolify or SSH paths and remain required before submission. |
| Backend retention/privacy regressions | Passed | 206 backend tests passed (one unrelated skip) after integrating current main; the subsequent candidate changes do not touch backend code, 2026-07-20. |
| Workout protocol/vector/state/presenter host tests | Passed | Strict C++ protocol/state/presenter/GPS suites plus exact protected native channel-six dispatch, replay, and wrong-channel checks, 2026-07-20 |
| Existing navigation/BLE regression tests | Passed | `./scripts/run-navigation-tests.sh` on candidate `40b8e034`, 2026-07-20 |
| `WAVESHARE_AMOLED_175` firmware build | Passed | Prior exact-behavior candidate `40b8e034` PlatformIO Release build; RAM 40.8%, flash 88.5% (2,785,031 / 3,145,728 bytes). Release-identity candidate `5b8ff662` does not touch the ESP32 subtree, 2026-07-20. |
| `WAVESHARE_AMOLED_206` firmware build | Passed | Prior exact-behavior candidate `40b8e034` PlatformIO Release build; RAM 40.8%, flash 88.5% (2,784,603 / 3,145,728 bytes). Release-identity candidate `5b8ff662` does not touch the ESP32 subtree, 2026-07-20. |
| 1.75 and 2.06 layout/interaction host tests | Passed | Both `test_gui_layout.cpp` variants after current-main integration; the candidate changes do not touch layout code, 2026-07-20 |
| App Store iPhone screenshot export validation | Passed | Four opaque 1242x2688 PNGs plus manifest/contact sheet/source provenance/ZIP; candidate changes do not touch rendering inputs or derivatives, and generation/validation/provenance/package checks passed, 2026-07-20 |
| App Store Watch screenshot dimensions/alpha | Passed | Opaque 416x496 JPEG; `bun run validate:watch`, candidate changes do not touch the asset, 2026-07-20 |

## Physical-device matrix

| # | Scenario and required observation | Final-candidate status | Evidence |
| --- | --- | --- | --- |
| 1 | Start on Watch with iPhone foreground and ESP32 connected; one coherent session appears on all three. | Pending | — |
| 2 | Start on iPhone; Watch wakes, requires the explicit start confirmation, and owns the workout. | Pending | — |
| 3 | Start without ESP32, connect it mid-workout, and receive the latest coherent state. | Pending | — |
| 4 | Disconnect and reconnect ESP32; Watch continues and ESP32 resynchronizes without stale replay. | Pending | — |
| 5 | Disable and restore Watch/iPhone Bluetooth; Watch continues and iPhone reconciles current state. | Pending | — |
| 6 | Lock/background iPhone while navigating; record end-to-end sample latency and p95. | Pending | — |
| 7 | Background iPhone without navigation; ESP32 must become honestly stale rather than show old speed as current. | Pending | — |
| 8 | Pause and resume from both Watch and iPhone; state agrees and paused time/distance do not inflate. | Pending | — |
| 9 | End and save once from Watch and once from iPhone in separate runs; each produces one synchronized terminal outcome. | Pending | — |
| 10 | With Apple's Workout active, test both BikeComputer start surfaces: warning shown, Cancel is a no-op, Start Anyway proceeds only after confirmation and reports any displacement honestly. | Pending | — |
| 11 | Deny Health access, then deny Watch location separately; workout setup and unavailable route/GPS metrics remain honest. | Pending | — |
| 12 | Ride without external sensors; optional power/cadence stay unavailable and GPS fallback behavior is correct. | Pending | — |
| 13 | Ride with cycling speed, power, and cadence sensors; available values propagate without double counting. | Pending | — |
| 14 | Terminate/crash the Watch app during a workout; relaunch and recover the same session without duplicate save. | Pending | — |
| 15 | Save after outdoor movement; Health/Fitness shows exactly one workout with route, distance, energy, and available zone data. | Pending | — |
| 16 | Run at least two hours; record Watch, iPhone, and ESP32 battery deltas plus thermal observations. | Pending | — |
| 17 | Validate readable, unclipped live/stale/paused/ended/idle screens on physical 1.75- and 2.06-inch devices. | Pending | — |

## Exact-build confirmation paths carried from Phase 3

These were not performed on the latest confirmation-UX build and remain part of
the final matrix even though an earlier build exercised adjacent paths:

- **Keep Riding** is a no-op and leaves the exact active session unchanged.
- Final **Discard Workout** confirmation saves no Health workout.
- **End and Save** creates exactly one Health workout.
- Ending navigation and ending the workout remain independent in both orders.
- A moving outdoor test saves and displays a route when permission is granted.

## Measurements

### Foreground latency

Capture at least 100 timestamp-correlated metric changes from Watch collection
through iPhone presentation and ESP32 presentation. Report sample count, median,
p95, maximum, clock method, and whether p95 is at most three seconds.

| Path | Samples | Median | p95 | Maximum | Pass |
| --- | ---: | ---: | ---: | ---: | --- |
| Watch to iPhone | — | — | — | — | Pending |
| Watch to ESP32 | — | — | — | — | Pending |

### Two-hour battery and thermal run

Start with recorded battery percentages and stable thermal state. Use a real
outdoor or representative moving ride with Watch workout, iPhone mirroring, and
ESP32 telemetry active. Record navigation state separately so results are
interpretable.

| Device | Start battery | End battery | Delta | Thermal observation |
| --- | ---: | ---: | ---: | --- |
| Apple Watch | — | — | — | Pending |
| iPhone | — | — | — | Pending |
| ESP32 / power source | — | — | — | Pending |

## Health/Fitness inspection

For the final outdoor save, record the workout start/end timestamps and inspect
Health/Fitness for:

- exactly one BikeComputer cycling workout;
- route present when location was permitted;
- distance and active energy present;
- heart rate and available zone information present;
- source identified as the BikeComputer Watch app;
- no workout for the final confirmed discard run.

Redact personal route coordinates from committed evidence. Store private device
screenshots outside the repository or crop them so they disclose no home or
other sensitive location.

## Release decision

Release is blocked while any required row is Pending or Failed. The user may
elect to continue development while assuming a hardware path behaves as
designed, but an assumption does not convert that row into release evidence. If
optional external sensor hardware is unavailable, record that concrete blocker
rather than substituting simulated data. The ownership-capable app must be
available before ownership-v2 firmware, and App Store publication remains a
separate authorized action.
