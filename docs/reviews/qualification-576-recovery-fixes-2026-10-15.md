# Follow-up to qualification #576

Base: main `9732b09e3635b41641b794b7d389cd592e4c98a6`.
Review profile: deep, sequential local fixes, P0/P1/P2 gate, no subagents.

## Evidence and scope

The matching main iPhone/Watch bench retained the original Watch workout but
failed the first custom snapshot after both paused and running iPhone process
restarts. Manual Watch Resume restored the paused test. These are physical
failures, but they do not by themselves identify a single software root cause.

The cold iPhone attachment has native state but no custom snapshot credentials.
Its existing credentialed snapshot request therefore cannot be constructed.
The repair adds a fixed, state-neutral bootstrap message over the current
HealthKit mirrored session. Only the current primary Watch session in running
or paused state can answer by publishing its existing snapshot. The request
cannot pause, resume, finish, adopt identity or acknowledge any control. All
subsequent controls still require the existing validated credentials and replay
gate. Existing first-snapshot timeouts and honest unresolved presentation remain.
Older peers ignore the unknown message and retain their existing snapshot path.
This closes a confirmed handshake gap; physical retesting is still required to
establish whether it fully resolves the observed stall.

On both ordinary and REMOTE_DEBUG 1.75 profiles, first diagnostics Wi-Fi startup
was refused by the existing memory guard. The preparation task starts the HTTP
worker before releasing its own 6 KB internal stack. Self deletion does not
establish reclamation before the network owner checks memory. The repair
publishes preparation results, parks the task and has the main-loop owner
reclaim the suspended task before starting the network. Cancellation, storage
failure, lease ownership and specific startup failures remain explicit. Shutdown also cancels and drains asynchronous preparation before storage
quiescence, rather than counting only the already-returned BLE callback. Memory
floors are unchanged, and genuine low headroom still rejects startup. This
removes confirmed overlapping allocations; it is not proof that 6 KB alone
explains every physical refusal, especially the debug profile's lower baseline.

The reported checked-idle no-op did not reproduce through the actual failed
launch callback or launch-timeout reducers: both explicitly clear without an
app restart. The observation remains in the physical ledger; no speculative
coordinator change is made. End saving directly is intentional in the tested
views. Normal iPhone Discard remains a product/qualification gap; this patch
does not silently change End semantics or remove saved Health records.

## Verification and release boundary

Regression tests exercise cold native attachment in paused/running states,
state-neutral Watch snapshot publication, malformed/foreign-session rejection,
credentialed controls after the first snapshot, actual failed-launch checked-idle
recovery, synchronous preparation reclamation, cancellation and unchanged
low-memory rejection. Exact commands/results and the review ledger are retained
outside Git for this local run.

Matching builds at `ede93b48` passed paused/running Watch recovery and ordinary
1.75 diagnostics delivery (138/138 inventoried chunks). The Watch bench was
discarded and both native stores confirmed cleanup. The remote-debug profile
still rejected its first diagnostics attempt with `wifi_memory` before inventory.

The remote-debug ELF also linked C++ locale/stream state absent from the ordinary
image: internal-DRAM data symbols alone differed by 4,164 bytes. Its two debug JSON
responses used `std::ostringstream`, pulling that state into every boot even
before a debug request. They now reuse the renderer's stream-free JSON builder,
with the same response fields and integer/escaping behavior. The shared builder
reserves response storage above Arduino's internal-allocation threshold. No
Wi-Fi, TLS, credential or owner stack moves to PSRAM, and all four Wi-Fi memory
safety floors remain unchanged. Confirm the removed locale symbols in the final
ELF and retest first-attempt diagnostics without live polling on the matching
remote-debug image before claiming this remaining physical blocker resolved.

Keep issue #576's longer ride/map logging, retained evidence handoff, resource endurance, stack,
OTA and map/power durability rows open. The user excluded the 2.06-inch and
three-card campaigns; they are not qualified. No production rollout or factory
image is authorized by these local fixes.
