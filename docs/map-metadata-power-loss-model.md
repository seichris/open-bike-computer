# Metadata power-loss shadow model

This is a **bounded storage-risk characterization**, not a FAT/SD durability
qualification. `test_map_metadata_power_loss.cpp` executes the real installer
and recovery code against first-install and replacement content fixtures. It
uses the mutation seam introduced for interruption testing; it does not replace
installer decisions with a simplified state machine.

## Model and scope

The helper maintains separate read-visible and power-durable file images.
Completed open/truncate, flush, close, rename and delete effects are collected
from the actual filesystem into an unfenced metadata window. Payload content is
verified before the baseline and remains independently checked after recovery.
A C++ stream flush or close is **not** treated as a directory durability fence.
The helper's `provenFence()` is tested only as a hypothetical control, never
attributed to ESP32, FAT, readback, or a particular SD controller.

For each actual metadata-effect prefix the executable enumerates:

- loss of the remaining tail
- loss of each individual effect within that prefix
- every single adjacent-order permutation within that prefix
- three subsequent recovery attempts, each subject to another deterministic
  metadata loss when recovery has a mutation, followed by three clean recovery passes

Both POSIX replacing rename and FAT-style replacement refusal exercise the real
backup/restore branches. A single recorded rename's multi-path effect is atomic
in this model. Reordering means persistence of recorded directory effects,
**not** rerunning syscalls in a different order with different arguments.
Sector tears, arbitrary permutations, multiple independent losses in the
original window, controller write amplification, and all-card behavior are not
covered. Empty-directory persistence is not modeled; restored file paths get
parent directories. Zero-effect boundaries have the same shadow image as the
preceding effect and are covered by that prefix.

This extension covers legacy-ready active-pointer/journal/consumed-marker
transactions. The separate explicit-operation promotion/receipt cut tests cover
those software transitions, but this model does not establish power persistence
of the new operation ledger or cover reordered accepted/terminal receipt writes.
Do not report full T8 or physical acceptance from these results.

## Observed counterexamples

Before the anchor fix, the initial run enumerated 1,794 schedules and 1,794 recovery-loss injections.
Two FAT replacement schedules left no recoverable active selection after all
recovery passes. No tested schedule selected invalid content or deleted the
verified previous payload root.

Both failures persist the complete 24-effect window with:

1. The active-pointer publication rename lost, while later backup and journal
   cleanup persists
2. The active-pointer publication rename's directory effects persisting before
   the preceding active-pointer-to-backup rename's effects

The previous map's payload survives, but its selection/rollback metadata does
not. That is an availability counterexample; payload retention alone is not
successful recovery. Exact indexed mutation names and any recovery losses are
printed with each counterexample. The original failures remain evidence of why
readback plus canonical pointer/backup cleanup was insufficient.

## Bounded predecessor-anchor repair

Before replacing a canonical pointer, the installer preserves the exact verified
predecessor named by that transaction in one of two alternating selection-anchor
slots. Each record is bounded to 2,560 bytes and carries schema 1, a monotonic
64-bit sequence, device and operation provenance, SHA-256 checksum, and the full
canonical `ActiveMapSelection` bytes including its previous selection and target
metadata. Only the older/inactive slot is overwritten; the other is never
renamed or removed as part of pointer/journal cleanup.

Recovery of a missing/corrupt canonical pointer checks schema, checksum, sequence
consistency and device/operation binding, and rehashes the exact referenced
current and previous payloads against their verified manifests/receipts. It
never guesses among ready roots or manufactures an Installed receipt. Unknown
schemas, conflicting equal sequences, foreign-device records, or absence of an
exact verified predecessor fail closed. Existing canonical JSON remains readable
by older firmware; a downgrade does not understand the extra recovery guarantee
and still must obey the existing explicit-operation metadata compatibility floor.

Normal sequential installs now retain at most four current/history roots: the
current selection and the complete roots referenced by two predecessor anchors.
In-progress/staging reservations remain additional. Pruning tests rotate through
five installs and prove that the oldest root is removed after neither slot nor
the current selection references it. Unknown schemas conservatively stop
pruning rather than deleting unexplained evidence.

Full payload rehashing has real large-map latency. It runs on the existing storage
owner or setup recovery path, never as a new UI filesystem operation. Every 64 KiB
of actual hashing (plus trailing bytes) reports progress and cooperatively yields;
the shutdown watchdog can distinguish progress from a stuck read while retaining
its absolute deadline. Board/card latency and resource qualification remain open.

After the fix and the stdio-helper conversion, the strict shadow executable
passes 1,974 schedules with 1,972 recovery-loss injections: zero unavailable
selections, invalid selections, or previous-payload losses. Additional executable
coverage includes 270 installer mutation cuts, 80 explicit-operation promotion
cuts, 36 terminal-cleanup cuts, and 64 alternating-anchor overwrite cuts, with
re-interrupted recovery. Envelope corruption, unsupported schema, conflicting
sequence, foreign device, payload damage and bounded-retention cases also pass.

These results close the two demonstrated schedules within this finite model.
They do not prove arbitrary controller ordering, torn-sector behavior, operation
ledger power persistence, or any real FAT32 card's behavior. Physical per-board,
per-card qualification and rollout approval remain separate.

## Running

From `esp32/`, compile this test with the same sources and mbedcrypto dependency
as the existing `test_map_stream_install.cpp` CI command, substituting
`tools/tests/test_map_metadata_power_loss.cpp` as the test translation unit and
`/tmp/test_map_metadata_power_loss` as the output. The fixture translation unit
is reused with its `main` renamed; its other test suite is not run implicitly.

Run `/tmp/test_map_metadata_power_loss` for the strict qualification result.
Counterexamples make it exit **1**. `--observe` permits collecting its complete
report with exit 0; that mode is explicitly **not a successful qualification**.
Do not substitute observation mode for a required production acceptance gate.
