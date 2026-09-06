# Bluetooth reliability follow-ups (outside R1–R3 implementation)

Status: proposed, not implemented or physically validated. This document does
not authorize installation, flashing, production ride automation, or merging.
See [the R1–R3 implementation record](bluetooth-reliability-reassessment-2026-09-06.md).

## 1. Attempt-scoped callback and phone-coordinator review

Review the iPhone BLEManager's actual lifecycle independently. Sharing a phase
enum or an owner-phone reducer test does not prove runtime integration. Map its
writer, capability, authentication, handoff and cancellation side effects before
proposing a common adapter abstraction. Avoid replacing proven #366 delivery and
#339 resource protections to achieve cosmetic symmetry.

CoreBluetooth callbacks have no application attempt token. The R1–R3 cancellation
barrier prevents normal old cancellation from racing a successor on the same
peripheral; it is not a claim that arbitrary cross-attempt callback reuse has been
eliminated. Evaluate scoped delegate ownership, explicit peripheral/session
identity and generated traces before broadening this patch.

## 2. Model-based and cross-language contract testing

Extend deterministic adapter traces with generated permutations of authentication,
CAP2, disconnect, radio state, revocation, selected-device changes, restoration,
clock expiry and simultaneous navigation/workout boundaries. Shrink failing traces
into named regression cases. Test against the real shared queue and session code;
a copied policy or regex assertion is not adapter validation.

Keep Swift/C++ golden vectors for authenticated framing, scoped permissions,
lease generation, grouped RCM1/RAK1 delivery, stale/duplicate acknowledgements,
terminal replay and malformed/rejected data. Existing generation, capacity and
retry invariants remain hard requirements. Validate changed contracts jointly
rather than editing generated output independently.

## 3. Privacy-bounded observability

Assess whether existing transition/timeout diagnostics adequately distinguish
lease release, phone-outbox admission and peripheral cancellation. Add only
bounded non-secret counters/IDs if evidence shows a gap. Never log credentials,
nonces, protected payloads, route coordinates or workout values as a shortcut.
Measure distributions of handoff, negotiation and cancellation latency before
changing deadlines. Record explicit reasons for failed cancellation recovery.

## 4. Authorized physical qualification

First confirm the exact physical board and profile. Record exact app, Watch and
firmware build/commit identities. Use repository build/boot tools and preserve the
#339 DMA/crypto acceptance gates. No host or CI result substitutes for this step.

Exercise repeated navigation-only, workout-only and simultaneous stop/start;
phone nearby/absent/unreachable; WatchConnectivity activation and relaunch;
Bluetooth-off/on and unexpected disconnect at every shutdown stage; foreground,
background and wrist-down execution; preparation selection/revocation; terminal
ACK loss/retry; and successor rides during release/cancellation. Verify exactly
matched phone release, no unintended writer overlap, latest-state replay, and
explicit bounded failure when cancellation never completes.

Collect battery/thermal, latency and sustained-session measurements under the
normal renderer workload. Preserve exact-head evidence and separate cold-start,
warm-reset and radio recovery results. Obtain further authorization before any
installation or flash operation.
