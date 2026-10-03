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
The iPhone stores it in device-only Keychain. Pairing expires (maximum 24 hours),
can be revoked by `diag broker revoke`, and can be removed on the phone.

The certificate/private key, bearer and SQLite inbox live under
`~/.local/share/bicino/diagnostics` with restrictive permissions. Override with
`tools/bicino diag --broker-root /private/path ...`. A broker enrolls one phone;
re-enrollment requires deliberate fresh pairing. The protocol accepts only
bounded diagnostics commands. It cannot execute shell commands, reset, flash,
change ownership, operate the UI, or request raw protected payloads.

The phone polls only while foreground-active and paired. Files remain in a
recipient-scoped, bounded outbox until the authenticated Mac verifies and
acknowledges their exact hash. No claim is made that iOS permits arbitrary
background execution. Reopen the app to resume an offline handoff.

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

## Ride now, collect later

Both producers record locally through a BLE disconnection. Standard retention
and fault capsules continue to apply; volatile tails are not guaranteed through
power loss. Mark an issue using the predefined phone categories. Device marker
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
deduplicated evidence cache (32 MiB total, 256 KiB per chunk, at most 20 jobs
with 256 chunks each). This is additional to ordinary recorder retention.
Completing a collection revalidates every retained body. Ordinary capture/age/
byte pruning cannot remove these acquisition bytes. When the job journal evicts
a completed or cancelled job, only cache files no remaining job references are
removed; incomplete jobs are never evicted to admit another request. A full
cache leaves the collection partial and preserves earlier verified bodies.
Restart and export rehash cached bytes. Export combines them with the recorder
snapshot under their original device/boot/chunk paths, through the existing v1
validator; it does not restore them into ordinary recorder retention. Receipts
from older app versions have no guaranteed cache and still require actual
archive bytes to prove delivery. This protects retrieval evidence, not physical
card durability or completeness of the original recording.

New collections also freeze the recorder's existing iOS chunks for their original
capture, closing the mutable chunk before caching it. App and firmware evidence
share the same 32 MiB budget; app chunks retain their original process/chunk
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

Delivery completeness and recording coverage are separate. Exit status 3 from
`verify --require-complete` means valid evidence but insufficient delivery/source
coverage. A completed download cannot prove that every desired provider was on.

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
