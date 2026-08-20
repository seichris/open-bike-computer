# Shanghai 3D map orchestration runbook

This runbook covers the internal `shadow`/`chunked_allowlist`/`chunked`
coordinator. The documented inspect, task, alert, and resource-report surfaces
are intentionally read-only. Lease expiry, cache rebuild, and
public/coordinator ready reconciliation use bounded, transactional recovery
paths rather than manual database changes. The CLI also contains the internal,
mutating `complete-workload-scan` receipt handoff described below; it is not a
routine operator recovery command. Production remains on the monolithic
executor until the rollout gates in the implementation plan are complete.

## First response

1. Capture the parent job ID, deployment image digest, deployment channel, and
   the authenticated plan diagnostics. Do not copy installation credentials,
   admin tokens, signed download URLs, or the full environment into tickets.
2. Check the parent state, progress, task attempts, reservations, resource
   model, and alerts:

   ```sh
   map-platform build-plan inspect JOB_ID --limit 100 --offset 0
   map-platform build-plan tasks JOB_ID --limit 100 --offset 0
   map-platform build-plan alerts JOB_ID --limit 100 --offset 0
   map-platform resource-report
   ```

   The same information is available from the authenticated API endpoint
   `/v1/admin/building-plans/JOB_ID` and the read-only
   `/v1/admin/building-plans/JOB_ID/alerts` endpoint.
   Inspect/task pages limit each task, attempt, receipt, and child/parent
   reservation collection to 100 rows and report total counts plus `hasMore`;
   advance `offset` until the retained result is complete. Alerts derive only
   from the same bounded evidence page and return its cursor/counts. Raw
   workload-object arrays are deliberately omitted. Retain their identity and
   byte-count fields instead of trying to reconstruct them from diagnostics.
3. Record the exact image digest and source/index/calibration identities before
   restarting anything. A changed identity is a new build, not a retry.

`map-platform build-plan complete-workload-scan` is an internal, mutating
receipt handoff. It requires the active worker ID, live lease token, and exact
source-index receipt, and can split or requeue durable work. Do not use it as a
manual retry. Invoke it only under an explicitly approved break-glass procedure
that preserves the source, plan, worker, and lease identities.

Child leases are refreshed every 30 seconds while a workload scan or building
command is running. This lease cadence is separate from the 30-minute hard
command deadline. A healthy task should show a recent `heartbeat_at`; a stale
timestamp is actionable evidence of worker loss or an older image without the
heartbeat fix, not a reason to extend the relation ceiling.

Source preparation and whole-map assembly hold durable parent-phase leases in
the same heavy resource pool. They refresh every 30 seconds, are token-fenced
on release, and participate in the same concurrency, effective-memory, and
CPU-capacity snapshot as child reservations. If the pool is busy, the public
parent yields and resumes without consuming another retry. The reservation
miss and parent-stage wait are one durable transaction: a planless parent gets
a `map_build_parent_stage_eligibility` waiting row before any coordinator plan
or child rows exist. A worker whitelists that row only when its current
parent-phase capacity can progress; an occupied pool therefore keeps all such
parents quiet instead of creating a reclaim/yield loop. Active rows are
token-fenced, expiry recovery returns them to waiting, and terminal/reconciled
parents remove them. Failed-child evidence still surfaces immediately, while
receipt-complete assembly is admitted only after the assembly pool is free. An
expired parent-phase lease is removed by the normal recovery pass; do not add a
second worker or manually delete the reservation.

The worker executes at most one child task for a claimed parent before yielding
the parent job. The next global claim is selected across eligible parents using
admission priority, weighted virtual finish, last-claim ordering, and the
per-parent quota. Never-started and yielded parents are merged by their durable
waiting timestamps, so continuous arrivals do not bypass an older yielded
parent. A parent whose only pending child is still in retry backoff is not
claimable until that deadline; this is expected quiet time, not worker loss.
Receipt-complete parents remain claimable for assembly. Repeatedly draining one
parent's children while another eligible parent never receives a claim is
therefore a scheduler incident, not expected chunk behavior.

## Typed alerts

### Child and parent-phase lease alerts

`stale_lease`, `stale_heartbeat`, `parent_phase_lease_expired`, and
`parent_phase_stale_heartbeat` identify lease-health problems.

Confirm the worker container is alive and inspect its health/heartbeat and
resource report. Every global scheduling or claim pass automatically recovers
expired leases in the same transaction: it closes the old attempt as
`lease_expired` with `building_task_lease_expired`, releases its reservation,
and returns active-plan work to `pending`. Heartbeats, receipts, transitions,
and cache recovery also reject an expired token before a replacement claim, so
do not publish with or manually requeue an old lease. If the worker is
unhealthy, restart only the validation worker after checking that no active
reservation is being held by a healthy replacement.

The parent-phase variants identify `source_preparation` or `map_assembly` and
the owning worker without exposing the lease token. They are read-only evidence:
normal scheduling removes an expired parent-phase lease transactionally, so do
not release or replace it manually. The authenticated task, resource-reservation,
and parent-phase diagnostic projections also omit every live fencing token;
never add those credentials to logs or incident tickets.

### `task_split`

This is expected for dense or relation-heavy work. An exact post-scan estimate
above 70% of effective memory or ten minutes of predicted wall time causes a
deterministic multi-block target split. The 85% memory limit and 30-minute
runtime deadline are hard: a multi-block breach uses the bounded split path,
while a singleton is pathological. Verify that the parent still owns the same
global plan, that completed receipts remain present, and that child workload
scans are pending. Do not raise the relation/object guard or retry the same
oversized task. Repeated splits at the configured depth are a capacity incident
and require a new benchmark review.

### `worker_oom` or `memory_headroom`

Record configured memory, cgroup memory, and the strict minimum of the available
positive caps as the effective cap, along with predicted reservation, worker
capability identity, and task workload counters. Admission refuses work above
85% of that effective cap.

Retain the bounded process-group/descendant peak RSS history, command wall time,
and before/after cgroup `memory.events` snapshots. Only a positive delta in
`oom`, `oom_kill`, or `oom_group_kill` confirms `building_worker_oom`; a generic
command failure with unchanged counters is not OOM evidence. Keep heavy-task
concurrency at one. Do not increase production memory or relation ceilings from
a single run. If the task remains within policy, allow the bounded split/retry
path; otherwise fail closed and retain the attempt evidence.

When reviewing the resource-model report, use the p95 of each retained
attempt's paired actual/predicted ratio, including the explicit safety margin;
do not divide independent p95 values. A positive actual paired with a zero
prediction makes that capability cohort untrainable. The report remains
review-only and never changes admission automatically.

### `cache_integrity`

Stop publication for the parent. Preserve the cache identity, block coordinate,
producer image digest, and validation error. Readers and writers hold a shared
lease on the stable namespace lock outside the removable directory; garbage
collection needs a nonblocking exclusive lease. Maintenance also protects any
cache identity referenced by a nonterminal receipt or cache-hit task and fails
safe for ambiguous legacy identities. A missing or mismatched cache read
transactionally deletes stale receipts, clears the cache-hit identity, restores
a conservative nonzero memory estimate, releases reservations, and requeues
affected work. Let that coordinator path rebuild only the affected canonical
blocks. Never manually delete a namespace while it is leased or protected.

### `building_storage_admission`

This failure occurs before source preparation. Retain the estimated archive
and source sizes, cache and attempt quotas, live free bytes, and configured
reserve. The cache estimate budgets two archive-sized copies. The attempt
estimate combines those two copies, three archive-sized temporary copies, and
two source-sized working copies; it must fit the attempt quota, and live free
space must cover that attempt estimate plus the reserve. Freeing unrelated
validation data through its normal retention policy may make a retry admissible;
do not lower the reserve, bypass quotas, or start preparation until the complete
model passes again. Different cold source downloads serialize admission,
checksum, and atomic publication through one data-volume lock, so adding a
second worker is not a way to bypass the reserve.

The source cache's cold publication boundary covers download, temporary-file
hashing, expected-checksum validation, and the final atomic replace. Any
unsuccessful publication (including cancellation, hash/checksum failure, or a
replace error) removes the complete `.tmp` file and leaves an existing stable
target unchanged. A `.tmp` file is never a valid cache hit; let the next
coordinator attempt download and publish again through the same boundary.

### `missing_receipts` or `receipt_overflow`

Do not assemble or publish. Compare the global output-block set with durable
receipts and task ownership. A missing receipt must be regenerated by its
owning child task; an overflow indicates a coordinator invariant violation and
requires an incident review before any cleanup.

### `plan_failed`

Read the typed task failure and the latest attempt chain. A job-level retry is
safe only through the coordinator's reopen operation and only when source,
image, rules, calibration, and global-plan identities are unchanged. Never
manually edit SQLite rows or mark a plan ready. A
`building_chunk_retry_exhausted` failure is terminal: its public error retains
the task ID and root failure code, and another public retry cannot make that
child executable.

### Terminal shadow observation

A shadow plan ends as `observed`, and every proposed child is cancelled with
`building_shadow_observed`. It is retained as nonclaimable terminal evidence
under the bounded evidence-retention policy and is exposed as
`buildingPlanObservation`; it never replaces the monolithic job's authoritative
`progress`. Do not reopen or execute a retained observation. A later executable
activation may replace only a disposable observation that has no execution
evidence.

### `building_relation_incomplete`

Treat this as a source-data or product-policy failure, not as a memory or
relation-ceiling signal. The extractor now includes the offending source
relation and up to eight part-member IDs when a `type=building` relation has
parts but no outline (for example, `source relation r11258294 ...`). Preserve
that detail from the public job error and preserve it with the immutable source
snapshot identity. Do not silently drop
the relation or promote a higher closure limit. The exact full-bbox job may
proceed under the identity-versioned narrow policy only when the relation has
one direct way member whose source way is explicitly tagged `building=yes`.
All ambiguous, multi-part, or untagged relations still require corrected
source data or an explicit product-policy review.

## Completion checks

Before accepting a Shanghai job's server-side ZIP as ready, verify all of the
following from retained evidence:

- every expected global block has one matching canonical cache receipt;
- the receipt-set SHA-256 and preprocessing identity are present;
- retained metrics confirm the local ZIP passed the complete structural,
  manifest, content, and size validator before the first immutable upload;
- the published file is a positive-size, parseable ZIP whose CRC test passes,
  whose paths are safe, unique, stored, and exactly match a schema-1
  `manifest.json`; every declared map file and preview must match its manifest
  byte count and SHA-256, at least one FMB must be nonempty, every FMB must be no
  larger than 2 MiB, and the total ZIP must be no larger than 512 MiB;
- exactly one ZIP receipt exists and its byte count and SHA-256 match the
  published file;
- when stream signing is enabled, the separate signed-manifest validation
  passed;
- no active lease, reservation, split child, or failed task remains; and
- the bounded diagnostics show no active child or parent-phase reservation.

Public job completion is durable before the coordinator marker moves from
`artifact_publication` to `ready`. If the public job is already ready but the
coordinator marker remains behind, let the maintenance reconciliation advance
it; do not mark the plan ready manually. This also repairs a yielded plan that
became ready by exact reuse: unfinished children are cancelled, active attempts
are closed, and child/parent-phase reservations are released in the same
transaction. A reconciliation error must leave the public job ready for the
next maintenance pass.

Server `ready` is not signed product acceptance when validation stream rollout
is disabled. Only after the applicable signing gate passes should the ordinary
iOS download, transfer, installation, render, and route-navigation acceptance
gates be started.

## Monolithic-versus-chunked equivalence

Run the retained-artifact comparison from `map-platform/backend`:

```sh
python tools/compare_building_equivalence.py \
  --reference-zip MONOLITHIC.zip \
  --candidate-zip CHUNKED.zip \
  --output equivalence-report.json
```

The canonical equality gate is only the exact sorted set of safe relative
`.fmb` paths and the SHA-256 of each entry's uncompressed bytes. A missing,
extra, renamed, unsafe, or content-changed FMB fails closed. Raw ZIP byte counts
and SHA-256 digests remain in the report as provenance evidence, but are not
equality inputs because legitimate orchestration metadata in `manifest.json`
may differ. Comparing an artifact with itself exercises the comparator; it does
not satisfy the retained monolithic-versus-chunked gate.

## Retained validation baseline

This is the authoritative retained validation baseline for this runbook, not a
claim about the current live deployment or validation of later source commits.
It used candidate image
`ghcr.io/seichris/open-bike-computer-map-platform@sha256:eab9c1337acffa6206fa0f36f5728a40f47ba0109828099e80cd43e369744a55`
(commit `d84c5c3a`). The validation-only exact cold run on 2026-08-20 is job
`242ab1e1cd76478bbbd7`, map
`shanghai-exact-cold-candidate-de7fbf0ea9`. It completed all 442 blocks and
16 chunks under `memory.max=12,884,901,888`, with peak cgroup memory
8,929,234,944 bytes and every `memory.events` counter at zero. Its immutable
ZIP receipt is 25,894,124 bytes with SHA-256
`79f49da19b0fea20ed4894a0d339bb5bc30b334ccd5a0370ae1c9477ed26234e`;
the retained object path is
`/data/artifacts/maps/shanghai-exact-cold-candidate-de7fbf0ea9/zip-stored-v1/79f49da19b0fea20ed4894a0d339bb5bc30b334ccd5a0370ae1c9477ed26234e.zip`,
and the measured worker container is `67fca6c98e67`. The archive contains
420 FMB entries, the largest is 507,316 bytes, and its canonical FMB path/hash
digest is
`5983a6bb7f79f6d276574e99a8c7da87edbf05c84bf38d2f197d5e2f8fac92cb`.
The receipt-set SHA-256 is
`648dcefa710fdbc5ccc85dd42ad72a2d0a5f752b56c608cf026abe9686f8ae90`
and the partition-invariant artifact identity is
`04d22a29beed417b94bf7ccc617997631e76f49d51f797afbf79d05d214c07a4`.

Processing took 10,957.745211 seconds. Including the 2.017497-second queue
wait, total service time was 10,959.762708 seconds (182.66 minutes), so this run
proves the cold functional, artifact-integrity, and capped-resource gates but
explicitly misses the unchanged 90-minute performance objective. It is not
production or physical-device acceptance: validation stream rollout was
disabled, production was untouched, and the signed-manifest, install, render,
and route gates remain open.
