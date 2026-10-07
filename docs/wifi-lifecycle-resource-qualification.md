# Wi-Fi lifecycle resource qualification evidence

This is software instrumentation and a capture-analysis procedure, **not physical
acceptance**. No new board, card, iPhone, firmware build, or release qualification
is established by host tests. Worldwide signed-map rollout remains closed.

## Production event path

`HttpTransferServer::observeResources` continues to collect the existing
internal/DMA/PSRAM free, largest-block and sampled boot minima used by
authenticated status. Selected lifecycle boundaries also enqueue records through
the existing persistent ride diagnostics recorder. Production retains its
existing `PERSISTENT_RIDE_DIAGNOSTICS` setting; detailed logging and remote-debug
profile exclusions are unchanged. Export records only through the existing
owner-authenticated diagnostics transport. SD unavailable/recorder disabled or
dropped records means missing evidence, not a successful measurement.

Each checkpoint consists of five bounded records, joined by the existing
`bootSequence`, `firmwareFingerprint`, and new `attempt` + `sampleCount` fields:

- `transfer_checkpoint`: allowlisted mode/phase, boot-local session cycle,
  rotating authorization generation, validated map/OTA UUID (empty until consumer selection/grant),
  and cleanup-failure flag
- Three `transfer_resources`: internal, DMA and PSRAM free/largest bytes and
  their boot-lifetime **sampled** minima (not allocator lifetime watermarks)
- `transfer_stacks`: TLS worker, internal network/flash owner, and renderer
  self-sampled stack high-water reserve bytes; `stackAvailableMask` bits 1/2/4
  identify TLS/owner/renderer availability separately from numeric zero (exhausted)

The session cycle survives revocation and is separate from generation/token.
Map operation UUID is associated at grant; OTA UUID is bound by the consumer
after signed manifest, device/admission and replay validation. Both compact
32-hex and hyphenated UUID spellings are preserved exactly; empty generic grant
headers never erase a validated binding. The binding API checks current request
generation, BLE/token authority and consumer mode without granting authority.
Earlier samples correlate through the same session cycle. Diagnostics/debug use
the boot-local session cycle, not a claim of a durable installation identity. Credentials, pins, tokens, SSIDs,
network addresses, arbitrary request paths/errors and artifact strings are not
accepted by the formatter. No authorization authority is derived from records.

Boundaries include acquisition before worker creation, network readiness,
authorized commit grant, grant release, map activation dispatch, terminal map
publication when supplied by its owner, OTA boot selection, cancellation,
network stop, owner release, worker-creation failure and shutdown request.
`grant_released` and `after_map_activation` **do not mean installed**. Pair map
terminal receipts with renderer acknowledgement and fresh authenticated status.
Shutdown records are produced before recorder sealing; missing post-shutdown
records do not prove successful shutdown. At most 64 checkpoints (320 records)
are emitted per admitted session. Payload-loop samples are excluded. The
recorder's existing bounded queue, drop counters, integrity and retention remain
authoritative; no second recorder or unbounded event backlog is added.

Renderer samples run on its own task, at most once per second at existing work
boundaries and once at start/exit. Readers use an atomic boot-lifetime minimum;
they never inspect a possibly freed worker handle. TLS reserve resets at new
session admission and samples only on its own worker. Owner reserve comes from
its existing self-sampled atomic, with an explicit availability bit. The pinned
ESP32-S3 FreeRTOS `task.h` documents high-water values in bytes and its
`portmacro.h` defines `StackType_t` as `uint8_t`; no word multiplier is applied. Flash/storage controls on that same owner and
renderer control work share those stack measurements. Rendering, full refresh,
buffer ownership and scheduler policy are unchanged.

The network/flash owner reserves one 16 KiB stack and its TCB in internal BSS.
Its one static task is created on first use and blocks on the command queue
between operations. After network teardown, `release()` acknowledges quiescence
and clears staged credentials/data; it does not delete or recreate that task.
This fixed boot-lifetime cost prevents a late owner-stack allocation from
consuming the largest DMA-capable block before Wi-Fi startup. The Wi-Fi memory
floor remains unchanged. Include this reserved memory and persistent idle task
in the baseline; it is not a leaked per-session allocation. A poisoned owner
still cannot admit another command or claim successful quiescence.

Both IPC tasks reserve 1,536 bytes each through the tracked custom-core
configuration, including the separate light-sleep profiles. The effective SDK
value is checked at application compile time. On the retained 1.75-inch Personal
image, Bluetooth startup exhausted the pinned Arduino configuration's 1,024-byte
`ipc0` stack while allocating the controller interrupt. The interrupted call
chain also needs the ESP32-S3's 192-byte interrupt context on that task's stack;
fill-pattern high-water measurements can miss these writes. The 1,536-byte
candidate adds 1 KiB of internal heap allocation across both cores. Keep the
stack watchpoint and heap guards enabled, and include that cost in fresh
internal/DMA free and largest-block measurements. This configuration change
still requires exact-image boot, transfer and recovery qualification on each
board family. A successful host config test or earlier-image boot cannot
establish adequate stack reserve. The startup panic is separate from a later
hotspot association failure on a boot that reached ready.

The native Wi-Fi runtime now retains its initialized driver and AP/STA netifs
for the rest of the boot. Repeated operations call `esp_wifi_start/stop` rather
than destroying and recreating the driver. Teardown stops the radio, clears both
RAM credential configurations and selects null mode before acknowledging
quiescence; failures still block owner release and shutdown. Driver mutations
remain on the internal owner stack, and HTTP reads native network snapshots.
Arduino WiFi lifecycle flags are not used by this owner. First initialization
keeps the unchanged internal/DMA memory floors and pinned dynamic-buffer
configuration. Partial initialization is terminal for this boot. This changes
the idle memory baseline: include the retained driver/netifs in future device
measurements. Host cycles prove control flow only; repeated physical transfer,
idle power, association/DHCP, OTA/map admission and shutdown qualification remain
required for the new candidate. Earlier-image bench transfers do not qualify it.

`owner_released` is before the HTTP task's own deletion, so its heap observation
is not a fully idle baseline. Compare the *next* `transfer_entry` (after the
previous worker-stop fence) to earlier entry samples to check for leaks. Keep
failure-admission cases separately; do not hide failed attempts with a retry.

## Reproducible capture analysis

For each exact board/profile candidate separately, record target and stable
serial, Git/image hash/attestation, app build/bundle/Git, SD vendor/capacity/FAT,
network topology, signed artifact receipt and operator scenario/fault index in
an evidence manifest. Do not combine different images/cards into one passing
campaign. Boot fingerprint is correlation only, not firmware attestation.

Export complete, hash/length-verified diagnostics JSONL chunks and run:

    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_175_PRODUCTION evidence/175-production/events-*.jsonl
    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_206_PRODUCTION evidence/206-production/events-*.jsonl

For ordinary profiles use `WAVESHARE_AMOLED_175` or `WAVESHARE_AMOLED_206` with
that candidate's separate evidence directory. For each opt-in debug candidate:

    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_175_REMOTE_DEBUG evidence/175-debug/events-*.jsonl
    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_206_REMOTE_DEBUG evidence/206-debug/events-*.jsonl

`--profile` is an operator assertion to match the attested evidence manifest,
not automatic verification of firmware identity. The report includes the exact
selected profile and required modes. Mixed firmware fingerprints are rejected;
each board/profile remains a separate analysis, even when images share a Git SHA.

The analyzer checks 100 completed sessions, at least 20 of each supported mode
(map, firmware and diagnostics for ordinary/production; all four including debug
for remote-debug profiles), complete five-record checkpoints, cycle sequence gaps,
startup readiness and failed cleanup; it reports entry free/largest trends.
Unexpected modes for the selected profile, malformed JSON, missing/invalid
record fields, and unreadable files produce useful errors and a nonzero exit.
They cannot turn a partial capture into complete evidence.
Exit zero means only structurally complete event evidence. It cannot prove no
task/file leak, adequate reserve, exact binary identity, renderer acceptance,
SD persistence, NEHotspot behavior or safe physical shutdown. Review minima and
trends per mode/artifact/network, along with recorder drops/storage faults,
reboots and poisoned-owner failures. Review missing stack availability and zero/low measured reserve as blockers.

## Separate acceptance matrix (all pending physical evidence)

| Gate | 1.75 ordinary / production / debug | 2.06 ordinary / production / debug |
| --- | --- | --- |
| Exact-head attested build | Required separately | Required separately; automatic 1.75 CI is insufficient |
| 100 all-mode start/stop sessions, >=20/mode | Pending | Pending |
| Fragmentation, large signed map, TLS/admission failure; measured reserves | Pending | Pending |
| Map first/replacement, exact renderer terminal receipt and cold boot | Pending | Pending |
| iPhone join, lock/background/suspension/force-quit/relaunch, cancel/lost response | Pending | Pending |
| Two-board same-SSID/identity and all-consumer contention | Pending | Pending |
| OTA accept/reject/rollback without SD; diagnostics complete chunks; debug LAN/browser revoke | Pending | Pending |
| Shutdown in every transfer/commit/renderer phase and bounded timeout | Pending | Pending |
| Each metadata/recovery mutation power cut, >=3 FAT32 cards, repeated recovery | Pending | Pending |

Debug mode is intentionally unavailable in ordinary/production profiles. Perform
its >=20-session row on the separate opt-in debug candidate. Select the exact
ordinary/production profile to require all three supported modes rather than
enabling debug or lowering every mode's minimum to zero. Omitting `--profile`
retains the conservative four-mode requirement. Minimum counts must be positive;
explicitly lowered counts describe partial evidence only and do not waive the
100-cycle/20-per-supported-mode qualification requirement. Qualify exact production bytes with the
owner-authenticated boot-acceptance checkpoint, not serial from debug bytes.
Follow [AGENTS.md](../AGENTS.md) before any board write. This procedure grants no
hardware-write, cohort-promotion or deployment authorization.

## Nonshipping enabled-protocol qualification builds

The ordinary, production, personal and remote-debug profiles keep map/firmware
operation-V1 rollout gates at their default off values. Host policy tests alone
do not compile the OTA adapter's conditional implementation. Two explicitly
nonshipping profiles compile both actual adapters with
`MAP_OPERATIONS_V1_ENABLED=1` and `FIRMWARE_OPERATIONS_V1_ENABLED=1`:

- `WAVESHARE_AMOLED_175_LIFECYCLE_QUALIFICATION`
- `WAVESHARE_AMOLED_206_LIFECYCLE_QUALIFICATION`

They inherit their corresponding production profile's behavior, signed-artifact
trust, full renderer, persistent diagnostics and two 3 MiB OTA slots. They do not
inherit the single-slot developer layout, browser service, development signer or
detailed diagnostics. The attestation path enforces the same 64 KiB application
reserve as production; a size failure remains a blocker. The exact distinct
profile identity is embedded and attested. Inheriting production settings does
not classify these bytes as a production/factory release.

Following connected-model identification and the repository build rules, use
only the normal build helper, with no upload selectors:

    cd esp32
    python3 tools/build_firmware.py WAVESHARE_AMOLED_175_LIFECYCLE_QUALIFICATION
    python3 tools/build_firmware.py WAVESHARE_AMOLED_206_LIFECYCLE_QUALIFICATION

These commands describe separate qualification candidates, not permission to
build an unidentified board or flash hardware. The helper still requires its
locked runtime and exact-source attestation. `--factory-output-dir` rejects
qualification profiles; release-candidate packaging selects only the two exact
production environments. CI never supplies an upload selector. Any later
explicitly authorized physical qualification uses the normal clean-image,
board/serial/profile checks and attested upload procedure without bypasses.

The existing firmware CI selector now adds the corresponding qualification
profile to each selected board's build matrix. Automatic firmware CI remains
1.75-only, draft PRs still skip heavy builds, component-only changes still follow
the existing routing, and manual `firmware_hardware=206`/`all` selects precisely
those boards. No additional scheduled workflow is created. CI verifies enabled
OTA-adapter branch markers in the linked qualification ELF, alongside the
existing non-debug, production-behavior and persistent-diagnostics checks.
Build success qualifies compilation and size only; physical OTA acceptance,
rollback, durable maps and the remaining card/iPhone matrix remain pending.

Analyze this profile's separate three-mode capture with its exact name:

    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_175_LIFECYCLE_QUALIFICATION evidence/175-lifecycle/events-*.jsonl
    python3 esp32/tools/analyze_lifecycle_resources.py --profile WAVESHARE_AMOLED_206_LIFECYCLE_QUALIFICATION evidence/206-lifecycle/events-*.jsonl

Remote-debug remains a distinct four-mode candidate. Neither its evidence nor
these enabled-protocol qualification bytes substitute for exact production
candidate acceptance or authorize enabling the production rollout gates.
