# Agent-operated diagnostics and post-ride handoff

The iPhone and firmware always retain their own bounded, privacy-reviewed v1
JSONL streams. V2 adds a generated registry, runtime policies, immutable
acquisition receipts, an app-owned collection job and an explicitly enrolled
Mac handoff. It does not replace recording with an internet telemetry service.

## Mac setup

Run from a checkout matching the phone/firmware registry. Python 3.11+ and OpenSSL
are required for the broker; all Python modules otherwise use the standard
library. No package installer, cloud account or MCP server is required.

```sh
tools/bicino diag doctor --json
tools/bicino diag broker init --origin https://192.168.1.20:8443 \
  --pairing-file /private/local/path/bicino-pairing.json --hours 8
tools/bicino diag broker serve --listen 0.0.0.0
```

Replace the private IPv4 address with the Mac's actual trusted-LAN address. Do
not port-forward the broker or expose it publicly. Import the pairing file via
**Settings → Diagnostics → Pair Mac** on the iPhone, then securely delete that
transfer copy. It contains a temporary bearer credential and exact TLS leaf pin;
do not put it in Git, a prompt, shell history, an issue or a public artifact.
The **enrollment file** expires within 24 hours and can enroll one phone once.
The iPhone generates an independent credential and saves it in device-only
Keychain before contacting the pinned Mac. The Mac stores its hash, binds it to
that phone and returns a matching receipt. Once confirmed, pairing lasts until
the phone unpairs or the Mac revokes it; the enrollment deadline does not stop
later handoffs. No owner credential is included in the import file.

Lost enrollment replies retry the same persisted phone credential and identity.
An already-committed pairing can be confirmed after the enrollment deadline;
an unused expired file cannot create one. Re-importing the same file preserves
the existing credential. Revoked pairings cannot be restored by replaying a file.

The certificate/private key, local owner credential and SQLite inbox live under
`~/.local/share/bicino/diagnostics` with restrictive permissions. Override with
`tools/bicino diag --broker-root /private/path ...`. A broker enrolls one phone;
re-enrollment requires deliberate fresh pairing. The protocol accepts only
bounded diagnostics commands. It cannot execute shell commands, reset, flash,
change ownership, operate the UI, or request raw protected payloads.

```sh
tools/bicino diag broker pairings
tools/bicino diag broker revoke --credential-id PHONE_CREDENTIAL_UUID
# Revoke every phone and unused enrollment file, preserving retained evidence:
tools/bicino diag broker revoke
tools/bicino diag broker enroll --pairing-file /private/local/path/new-enrollment.json --hours 8
```

The phone credential can poll bounded commands, acknowledge them and submit its
own status, live observations and verified bundles. It cannot enqueue commands
or read the Mac's administrative status. An enrollment token cannot use these
data endpoints. One phone is enrolled at a time; replacement requires deliberate
revocation and a fresh file. Pairing history and unused enrollment admission are
bounded. Revocation retires pending commands and clears the old phone observation
without deleting recording or inbox evidence.

For an existing temporary v2 pairing, run the matching broker version against
its existing private directory first, then:

```sh
tools/bicino diag broker upgrade
tools/bicino diag broker enroll --pairing-file /private/local/path/bicino-enrollment.json --hours 8
```

`upgrade` verifies the running server's v3 support and exact TLS pin before it
changes credentials. The capability probe contains no phone or inbox data and
sends no bearer credential, so upgrade also works after a legacy pairing expires.
It preserves the server key, certificate, inbox and the
legacy phone's original expiry. Successful durable enrollment permanently
retires the shared legacy bearer. Old v2 import files remain temporary; they are
never silently promoted into lasting credentials. Deploy the matching phone app
and import the new file to finish migration. No device is needed for Mac setup,
but source/host tests do not prove phone enrollment or Keychain behavior.

Command receipts retain their original deadlines. Expired receipts can age out
of the phone's bounded journal, so durable pairing does not fill it after 100
historical commands. Expired commands remain rejected after their receipts age
out. A process-loss receipt reports interrupted/unknown instead of executing
the command again; completed receipts and deadlines cannot be changed by replay.
Legacy receipts receive one frozen maximum-lifetime migration window.

The phone polls only while foreground-active and paired. Files remain in a
recipient-scoped, bounded outbox until the authenticated Mac verifies and
acknowledges their exact hash. No claim is made that iOS permits arbitrary
background execution. Reopen the app to resume an offline handoff. Completed acquisition manifests
also remain durable automatic handoff intent: startup, completed exports and
foreground polling reconcile them against recipient-scoped ZIPs and hash
receipts. A busy export or full outbox does not consume a completion. ZIP names
bind automatic handoffs to acquisition IDs, closing the process-loss window
between publication and receipt bookkeeping.
SwiftUI foreground transitions and the combination of BLE authentication and
logging capability discovery recheck eligible retained collections. Resume
revalidates cached chunks at the original saved
cutoff; explicit cancellation and transport failures still require manual retry.
When the Mac's bounded inbox is full, the pinned broker reports `507` with the
typed `inbox_full` reason. The app asks the user to archive received bundles on
the Mac and retains the pending ZIP for the same hash-verified retry. Existing
acknowledged uploads can still replay their receipts at the capacity limit.
Use the explicit archive operation to verify a new copy outside the broker and
retire the active inbox copy while preserving its receipt:

```sh
tools/bicino diag inbox archive --id BUNDLE_ID --output /private/archive/ride.zip --json
```

Keep that archive at the recorded path: duplicate uploads recheck its exact hash.
`inbox get` remains a copy operation and does not free capacity. The 20-bundle /
512 MiB active payload budget includes unindexed renamed files after process
loss. One serialized upload has a separate 104 MiB staging budget, allowing a
lost receipt to retry even when the active inbox is full. The broker takes an
exclusive server lock before reclaiming abandoned partial uploads at startup;
opening the CLI never cleans up an active request. Archive receipt metadata is
retained separately from active payload capacity. TLS handshakes and HTTP
headers have 15-second deadlines, JSON bodies 15 seconds, and upload bodies
120 seconds, including time spent continuously receiving small fragments.
Unpair removes the local Keychain credential immediately and tries to revoke it
on the pinned Mac. If the Mac is unreachable, use the Mac's revocation command;
local logs and recipient-scoped pending handoffs remain preserved. The explicit
LAN origin and TLS leaf pin stay fixed; endpoint or certificate changes require
deliberate re-enrollment.

## Capture

```sh
tools/bicino diag status --json
tools/bicino diag capabilities --device iphone --json
tools/bicino diag capabilities --device DEVICE_DIGEST --json
tools/bicino diag capture start --device DEVICE_DIGEST \
  --profile ble-navigation --duration 1h --budget-mib 8 --json
```

Use the freshly observed pseudonymous device digest, never the first connected
board or a remembered USB port. The phone acknowledges acceptance separately
from the firmware's effective policy in `DSTS.diagnosticsPolicy`. A request with
an unknown registry, missing provider, unsupported mask, stale identity or invalid
budget fails rather than pretending to enable complete tracing.

The registry at `protocol/diagnostics/registry-v2.json` generates scalar field
types, severity/domain vocabularies and schema identities across C++, Swift and
Python. Update it and run `python3 tools/generate_diagnostics_contract.py`;
`--check` is a CI gate. Existing v1 event names remain readable; new event
families should be typed in the registry rather than broadening arbitrary text.

Standard info/warning/error/fatal recording remains independent of the additional
trace budget. Debug/trace is charged conservatively by maximum record size and
bounded to four hours and 32 MiB. Identical generation retries do not extend the
lease or replenish its budget. A capture UUID change invalidates the old policy.
Record severity is not an authorization to persist coordinates, route text,
credentials, raw sensor/health values or complete transport payloads.

Production includes the compact capture policy and persistent recorder without
turning on USB, remote framebuffer control or compiled-out ride-automation/SDK
raw traces. The capability report states this boundary; selectable levels do
not manufacture events a provider does not emit. Intrusive hardware profilers
remain separately built and qualified. The 64 KiB OTA reserve and existing
lifecycle rollout gates are unchanged.

The phone stamps occurrence time, uptime, capture and an emission sequence before
enqueueing. The v1 storage sequence remains writer order; `writerDelayMs` measures
queue delay. Firmware uses its boot identity and monotonic sequence. Existing
clock anchors remain raw evidence; host correlation does not rewrite them.
Derived firmware times report 1000 ms timestamp resolution and null (unknown)
clock uncertainty: synchronization delay and oscillator drift are unbounded by
this evidence, including at the anchor itself. Phone clock uncertainty is also
unknown unless independently established.

## Ride now, collect later

Both producers record locally through a BLE disconnection. The iPhone recorder
is a rolling 50 MiB history: byte pressure overwrites the oldest chunks, even
within an active capture, so old evidence cannot prevent the latest events from
being recorded. The open writer and its manifest remain intact; immutable
acquisition snapshots use their separate cache. Retention can leave a partial
capture, and validation must continue to report its missing history. Standard retention
and fault capsules continue to apply; volatile tails are not guaranteed through
power loss. Firmware checkpoints commit libc buffers and call the filesystem
VFS fsync at a bounded five-second cadence, critical events, markers, fault
receipts and chunk close/seal. Sync errors preserve RTC capsules for retry;
no capsule is acknowledged before its checked sync/close boundary. A successful
fsync is not proof of arbitrary SD-controller power-loss durability. A firmware
boot without a retained controlled-shutdown marker reports
`unknown_unsealed_boot` (or degraded when measured losses exist); its unwritten
tail count is unknown rather than zero. Mark an issue using the predefined phone categories. Device marker
queueing is not claimed as durable device acknowledgement. The phone assigns a
shared incident UUID to matching-registry v2 device markers. Older firmware uses
the v1 marker without claiming that shared UUID. On the bike, **Device Settings →
Mark diagnostic issue** queues an independent incident ID without consuming the
phone's anti-replay counter or starting any network connection. Use the control
only when safe. Neither marker currently pins evidence against ordinary retention.

```sh
tools/bicino diag collect --device DEVICE_DIGEST --json
tools/bicino diag status --json
tools/bicino diag export --device DEVICE_DIGEST --json
tools/bicino diag inbox list --json
tools/bicino diag inbox get --id BUNDLE_ID --output /private/path/ride.zip --json
tools/bicino diag verify /private/path/ride.zip --require ios,firmware --require-complete --json
```

Enable **Settings → Diagnostics → Collect Device Logs After Rides** to opt in
to the post-ride queue. The app remembers at most eight authenticated
capture/device contexts during the ride, including disconnections and capture
rotations. Ride end queues distinct, idempotent request IDs in the bounded
20-job acquisition journal, before losing those original identities. This queue
needs neither Codex nor a paired Mac. Disabling the option prevents automatic
execution of its pending post-ride requests; manual requests stay independently
resumable. Explicit cancellation is terminal for automatic scheduling.

The request survives an app restart **after it has been saved**; an app that is
killed before receiving/persisting ride end cannot manufacture an automatic
request afterward. Its retained logs can still be collected manually. Storage
or queue-capacity errors are reported and do not delete the original logs.
No retrieval occurs while riding; starting a ride interrupts a current download
with a resumable `ride_started` result and cancellation-independent cleanup.
Collection chooses pending jobs for the original device, not an old completed
job or a newly connected unrelated board. One automatic attempt is made per
eligible trigger, not a continuous retry loop. A transport error requires manual
retry, persisted per acquisition: neither a successful newer collection nor
relaunch/reconnect re-enables an older failed partial job. Legacy partial jobs
without a reason also require manual retry. Only a `ride_started` partial job
can resume automatically (subject to its original opt-in/device fences). Leaving the screen has no effect on the job lifetime.

A capture and an acquisition cutoff are different identities. Collection stores
the original authenticated index before the first body and never silently swaps
in a newer inventory on retry. Cached chunks are rehashed. Missing/expired chunks
leave a partial result. App restart or leaving Settings does not erase progress;
explicit cancellation preserves the evidence. Network retrieval waits until the
app is active and neither navigation nor workout is active. The existing shared
operation coordinator prevents diagnostic cleanup from displacing maps or OTA.

Verified acquisition chunks are stored before their receipts in a separate,
deduplicated evidence cache (64 MiB total, 256 KiB per chunk, at most 20 jobs
with 256 chunks each). This is additional to ordinary recorder retention.
Completing a collection revalidates every retained body. Ordinary capture/age/
byte pruning cannot remove these acquisition bytes. Admission evicts the oldest
completed or cancelled jobs when either the job limit or the evidence byte/file
limit requires space. Only cache files no remaining job references are removed;
the current acquisition and all incomplete jobs are protected. App snapshots
are admitted as a whole; all outstanding immutable firmware inventories are
reserved before body download. A supported cutoff can contain 32 MiB firmware
plus 32 MiB app evidence. Verified acquisition bodies are not duplicated into
the ordinary phone recorder's capture/age/byte retention pool.
Shared bodies count once, including prospective app-snapshot references. The
store plans a feasible reclamation before eviction: if the request still cannot
fit, even terminal receipts and bodies are left intact. A full cache leaves the
collection partial with `failureCode=cache_full`, an explicit cache-full status
and a privacy-safe `diagnostics_download_failed` event, including failures before
network entry. Earlier verified bodies survive. Retrying requires user action.
Restart and export rehash cached bytes. Export uses the selected acquisition's
frozen app and firmware evidence (all cached acquisitions if no selection is
loaded), without merging unrelated ordinary recorder history. When there are no
acquisitions it exports ordinary recorder history. This keeps acquisition
archives below the unchanged 100 MiB reader bound. The existing v1 validator
checks original device/boot/chunk paths; export does not restore bodies into
ordinary recorder retention. Small current/referenced app process manifests
remain in the archive so required sidecars and available historical loss
counters stay valid. Export Recorder History provides newer retained phone
events separately; the collection export labels its saved cutoff.
Export Partial Evidence preserves an incomplete
cutoff; Release Incomplete Collection makes that job eligible for later cache
reclamation without deleting other incomplete jobs. Receipts
from older app versions have no guaranteed cache and still require actual
archive bytes to prove delivery. This protects retrieval evidence, not physical
card durability or completeness of the original recording.

New collections also freeze the recorder's existing iOS chunks for their original
capture, closing the mutable chunk before caching it. App and firmware evidence
share the same 64 MiB budget (at most 32 MiB app evidence per job); app chunks retain their original process/chunk
paths and are deduplicated by SHA-256. Each job can reference at most 256 app
chunks; the cache keeps its existing total file bound. Optional `appEvidence`
receipts record path, byte count and hash. Export and the CLI verify the actual
bytes and original capture/process identity before accepting those receipts.
Cache pressure prevents network collection until evidence admission succeeds.
This snapshot preserves already-recorded capture context, not future events.
Bounded crash tails are preserved byte-for-byte and still degrade recording coverage.
Older requests whose iOS chunks have already expired remain missing-source
results; retries cannot manufacture history or remove recorded sequence gaps.

Firmware writes an optional checksummed `.cat2` descriptor when a chunk is sealed,
containing its byte/hash/sequence identities. It avoids rehashing every retained
payload merely to list them. Missing/corrupt descriptor caches use the legacy
hash path. The downloaded bytes still have to match the descriptor hash. A cache
is never a substitute for immutable source bytes or physical-card durability.

V2 exported stored-ZIP contains a closed manifest, checksums, immutable
`evidence-v1.zip`, and at most 20 acquisition manifests. Each acquisition has a
frozen index and verified chunk identities; it contains no transfer credentials.
The host verifies the nested legacy archive and actual chunk bytes independently
of the claimed receipt. Original raw members, checksums and torn tails remain
unchanged. V1 direct archives are still accepted but cannot prove a v2 cutoff.

Scope an investigation explicitly when the archive contains several rides:

```sh
tools/bicino diag verify /private/path/ride.zip --capture CAPTURE_UUID \
  --device DEVICE_DIGEST --require ios,firmware --require-complete --json
tools/bicino diag analyze /private/path/ride.zip --acquisition COLLECTION_UUID --json
tools/bicino diag query /private/path/ride.zip --capture CAPTURE_UUID --incident INCIDENT_UUID --json
```

An acquisition selector derives its original capture/device; explicit conflicting
selectors match nothing. Unknown captures cannot borrow unrelated source logs,
and an unrelated old partial collection cannot invalidate a scoped complete one.
Integrity still covers the entire archive. Stream-wide gaps and bundle-global
loss counters remain conservative and are labelled separately from the event
scope; no zero-loss proof is invented for a filtered time/capture interval.
`collect --device iphone` queues a local snapshot/handoff only and never starts
a firmware Wi-Fi session. An iPhone-only policy is never forwarded to a device.
The Mac outbox checks the prospective byte total, including the prepared file,
before publication. It never exceeds eight files / 400 MiB through admission.
Permanent upload rejection (400/409/413/415/422) leaves the ZIP in that quota with
a synchronized, hash-bound rejection receipt. Future polls/relaunch skip the
unchanged rejected bytes and continue later eligible files; rejection is never
a delivery acknowledgement. UI reports preserved rejected handoffs separately
from connectivity. Authentication revocation, inbox capacity, and transient
transport failures keep their distinct handling; failures back off up to 60s.
Source evidence can be exported, or explicit retained-diagnostics deletion can
release local outbox capacity. Broker validation remains strict.

Deleting retained iPhone diagnostics first stops and joins collection and
handoff tasks, then erases acquisition manifests/cache, every local recipient
outbox and the recorder. Pairing and bounded command anti-replay receipts remain
so deleting logs cannot replay an unacknowledged command. Already delivered
Mac/archive copies remain separate.
Replacement chunks retain a monotonically advancing process-local namespace,
so an independently held pre-deletion snapshot cannot alias new bytes.

Watch transport batches carry an optional stable producer UUID and cumulative
truncation count. These survive queued retries/relaunch and are imported as
privacy-bounded `watch_ble_diagnostics_loss` events; older batches remain
readable. Producer truncation is distinct from BLE payload queue counters.
New events additionally preserve origin Unix milliseconds and a per-process
Watch clock identity; the persistent producer UUID is not a boot identity.
The phone envelope is explicitly receipt time, uses a process-level capture,
and marks original ride association and clock uncertainty unknown. Legacy
batches keep Watch uptime but never inherit the phone's current ride.

Delivery completeness and recording coverage are separate. Retained firmware
health/index storage errors and drops, and historical iPhone process drop counters, degrade
coverage even if their original events have aged out. Firmware health snapshots
use the maximum per device/boot, never a sum of repeated cumulative snapshots.
Counters are labelled with their boot/process scope rather than attributed to
an arbitrary selected capture interval. Old cached inbox summaries that predate
this accounting report `unknown_legacy` instead of claiming no detected loss;
verify their archive with the current CLI to compute current coverage. Exit status 3 from
`verify --require-complete` means valid evidence but insufficient delivery/source
coverage. A completed download cannot prove that every desired provider was on.

Firmware `gps.quality_checkpoint` includes fix/availability flags, packet-gap
durations, and source/mailbox age. These are scalar timing and quality metadata;
coordinates, speed values and raw GPS payloads are excluded.

Firmware `logger.loss` reports `dropReason`, a boot-local cumulative
`eventCount` for that reason, and the cumulative total `droppedCount`. Reasons
distinguish invalid fields/tokens, unavailable storage/boot identity/queue,
producer or queue lock contention, full queues, eviction
of an ordinary record, and an oversized record. Counts are never reset by
collection. Do not add repeated snapshots together or equate a `storage_gap`
fault capsule with an SD write failure: it can also describe admission loss.
Loss summaries are attempted at most once per 30 seconds after the queue
drains; a continuously overloaded or interrupted recorder may not retain them.
Policy filtering remains separate from dropped records.

The recorder keeps eight reserved critical slots and 24 shared normal slots.
Spilled critical records do not block normal admission into free shared slots.
When both lanes are full, one bounded rotation evicts the oldest normal record,
preserves every critical record and survivor sequence order, and appends the
new critical record. Publication into either lane shares the writer's bounded
cross-lane head-selection fence. Contended admission never waits and increments
`queue_busy`; free space alone is not an admission guarantee. This prevents a
new critical event overtaking an unseen older ordinary event when both lanes
were initially empty. The zero-wait producer lock and total capacity are unchanged.
Explicit storage transitions fence ordinary admission (`storage_transition`),
seal the old medium and park its writer before remount. If the old medium is
unavailable, queued losses become a fault capsule before changing identity.
A remount allocates a namespace above both media's retained boot IDs. Existing
nonempty chunks are never reopened for append. Failed fault-capsule writes
release their exact in-flight receipt for retry; old RTC evidence remains until
its durable write acknowledgement.
`critical_spill` remains a recognizable historical loss reason.

## Live observations

```sh
tools/bicino diag live start --device DEVICE_DIGEST --seconds 120 --json
tools/bicino diag tail --device DEVICE_DIGEST --json
tools/bicino diag live stop --device DEVICE_DIGEST --json
```

Live subscriptions do not enable trace levels, switch Wi-Fi, wake the panel or
stop recording when they disconnect. The firmware retains at most 16 events in
an optional PSRAM ring, sends at most two per authenticated BLE observation, and
rate-limits requests. Phone/Mac windows are bounded too. Cursors include source
boot/process identity, and stale snapshots or missing sequences are explicit.
Firmware live polling pauses while riding to preserve navigation priority.
A previously reported gap remains visible for that stream even after later
successful batches. Cursor-to-first-event gaps are checked even if older cached
events remain. The data is labelled `observed_not_durable`; only collected retained evidence can
prove persistence. The in-memory broker buffer is not a crash recorder.

## Investigation and validation

Use `diag analyze` first and `diag query` with source/category/capture/operation/
incident/time filters. Query cursors are bound to the exact bundle hash and
filters. Every returned event includes its original member, line and bundle hash.
Use operation IDs when present; timestamps alone do not establish causality.

Run the registry checker, root Python tests (including real pinned-TLS broker
cases), and the acquisition/policy/broker Swift test scripts. CI also executes
C++ policy, catalog and live-ring tests plus complete iOS builds and firmware
reserve checks. Hardware qualification must separately cover both boards,
production flash margin, storage/power interruption, real iPhone foreground and
network races, CPU/stack/heap, dropped records and battery impact. A source test
or accepted command is not physical evidence.

Native raw crash dumps, arbitrary SDK log capture, iOS system logs, comprehensive
provider migration and incident pinning require their own explicit capability
and privacy contracts; do not infer them from the existence of a coredump
partition or this registry. Current standard bundles report that native crash
artifacts are absent rather than synthesizing stack traces.

### Wi-Fi readiness evidence

Accessory association and an accepted iOS configuration are distinct from IP
routing and pinned HTTP readiness. The app keeps one proxy-free, Wi-Fi-only
pinned session and retries transient failures through the existing 20-second
absolute window, with 750 ms then 2-second backoff. Each request is capped by
the remaining budget; cancellation and pin/HTTP failures remain terminal.
An already observed target network is not reapplied during this window.

`transfer.wifi_apply`, `wifi_observation` and `server_probe` record apply and
association duration, transfer generation, phone operation UUID and readiness
elapsed/remaining time. `metricsAvailable` and `transactionCount` distinguish
missing URLSession metrics from observed connection/TLS fields; absent metrics
must not be interpreted as proof that no network load occurred.

Firmware `wifi.readiness` records driver-start return separately from AP_START,
netif-up, configured address, DHCP server status/error and actual listener state.
`wifi.events` carries boot-lifetime AP start/stop, client join/leave and IP-lease
counters, last relevant event uptime and station disconnect reason. DHCP status
uses the pinned ESP-IDF enum (`INIT=0`, `STARTED=1`, `STOPPED=2`); -1 is unavailable,
with a separate API error. A configured address is not proof that a phone obtained
a lease. Counters preserve transient edges but are not a full ordered event log.
Snapshots are sampled at most every 100 ms and emitted only on change/checkpoint,
with at most 16 two-record samples per session including the final stop sample.
Callbacks update atomics only and never format, allocate, log or touch storage.
`generation` is the boot-local resource cycle; `connectionGeneration` links the
readiness snapshot to the authenticated transport generation recorded by iOS.

`http.transport` records actual listen success/failure, the first accepted TCP
client, first successful TLS, at most three TLS failures and final session counts.
A failed bind/listen reports `http_listener_start` rather than advertising ready.
`transfer.diagnostics_preparation` records storage/seal duration and queue/drop/
write/error counters before Wi-Fi starts, so a seal timeout remains distinguishable
from association or HTTPS failure. `transfer.diagnostics_resume_selected` records
the original acquisition UUID, phase, origin and persisted eligibility reason.
All new records omit SSIDs, client MACs/addresses, tokens, passwords and payloads.
Delivery, recording loss and physical qualification remain separate gates.

The firmware index stays bounded to 256 chunks and 64 KiB. If a snapshot lease
or deferred pruning exposes more closed chunks, the index fails explicitly with
`diagnostics_index_unreadable`; it never advertises a truncated subset as a
complete inventory. Retry after the lease ends and retention runs.
