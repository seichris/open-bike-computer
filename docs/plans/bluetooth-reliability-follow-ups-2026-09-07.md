# Bluetooth reliability follow-ups — not part of the R1–R3 patch

Date: 2026-09-07. These are proposed work, not claims of reproduced defects or
completed validation. The original broader analysis remains in PR #418; the
implementation evidence is in the [local review report](bluetooth-reliability-implementation-2026-09-07.md).

## Platform callback identity and remaining cancellation paths

Audit connection-generation fencing for every CoreBluetooth callback, including
same-peripheral reuse, state restoration, selected-device changes, enrollment
revocation and invalid-selection recovery. CoreBluetooth delegate callbacks do
not carry the application's write ID. This patch prevents readiness revival in
terminal phases and waits for ordinary shutdown cancellation, but does not
claim to solve every callback identity ambiguity in unrelated reset paths.

Consider small generation-scoped delegate/connection operation objects only
where an actual failure trace establishes the need. Keep one lifecycle authority
and do not introduce a parallel Boolean state machine. Test device-selection and
credential-change races before moving those paths onto a broader coordinator.

## Phone/Watch architecture convergence

The phone and Watch both instantiate the shared reducer, but phone readiness
flags and capability side effects still have separate adapter logic. Audit that
coordination through real adapter tests; do not mistake shared enum/reducer tests
for full phone-path proof. Future extraction must retain owner administration,
connection selection, transfers and Watch handoff precedence. A one-shot phone
rewrite is not needed for the Watch shutdown fixes.

## Durable WatchConnectivity end-to-end tests

Exercise the actual WatchConnectivity coordinator and iPhone BLEManager together:
outbox admission before activation, transferUserInfo completion failures,
prepare/release reordering, tombstones, process termination and independent
navigation/workout restoration. The current host matrix validates the Watch
adapter's persistence and exact identities against the admission contract;
transport disposition doubles are not end-to-end delivery evidence.

Consider compact privacy-bounded diagnostics for retained-release age,
cancellation duration, retries and successor restart outcome. Never log device
credentials, protected payloads, GPS or workout contents. Adjust timeout policy
only from measured latency distributions, not to silence a failing benchmark.

## Native validation and physical qualification

The local full-source Debug/Release builds and iOS/watchOS platform suites passed
during integration; see the implementation report for their exact evidence.
Rerun on the eventual implementation PR head and confirm test-runner behavior on
the macOS CI image, including its isolated framework doubles. Local execution is
not a GitHub CI result.

Then, only with separate device authorization, qualify exact app/firmware
artifacts on the enrolled iPhone, Watch and confirmed hardware profile. Cover
lost or reordered ATT/application/release acknowledgements, BLE/radio loss,
WatchConnectivity unreachability, backgrounding, relaunch recovery, all three
successor-demand combinations, selected-device changes and prolonged soak.
Record software/hardware identities and distinguish reconnect success from
actual firmware application acceptance. Maintain the #339 internal/DMA memory,
crypto-failure and secure-transfer gates; do not import their historical CI or
older physical results as evidence for this patch.

The bounded cancellation failure remains intentionally visible until an actual
disconnect/radio boundary. Measure how often that fallback occurs before
considering a supported recovery mechanism that can prove old callbacks fenced.
