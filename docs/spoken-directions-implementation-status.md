# Spoken directions implementation status

Work-in-progress PR: [#440](https://github.com/seichris/open-bike-computer/pull/440).
Base: GitHub main `ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`.
The [full plan](plans/spoken-turn-by-turn-directions-implementation-plan.md)
remains the completion contract. This document does not reduce its scope.

## Implemented

- Host candidate codec, deterministic Swift encoder and bounded C++ decoder,
  synthetic measurements, and unsigned resident-pack preparation with
  provenance/rights inputs. See [prototype evidence](spoken-directions-codec-prototype.md).
- Generated channel-8, client-24/25, capability-bit-26/27, cue/control enums,
  limits, and Swift/C++ golden fixtures. Strict 56-byte cue and 36-byte control
  codecs; bounded session admission, owner-only authorization, phase ledger,
  step cancellation, shrinking start deadlines, progress lease and terminal grace.
- Conservative speech-specific English maneuver classifier, separate from the
  visual/persisted maneuver contract. Pure threshold scheduler with frozen
  per-step thresholds, speed smoothing, action-over-prepare priority, invalid-fix
  suppression, no reconnect/restoration catch-up, and arrival-before-teardown.
- iPhone lifecycle controller invoked on start, replacement, location updates,
  disconnect, and stop. One outstanding control/cue transaction, application ACK
  before cue dispatch, absolute-deadline fencing on all dispatches/retries, and
  terminal control after arrival cue admission.
- Native speech discovery and protected writer path in `BLEManager`, sharing
  the existing ATT/application-ACK barriers. Per-device preference storage,
  independently default-off at 70% volume. No UI exposes the preference yet.
- Host Swift/controller and C++ sanitizer tests wired into navigation and
  firmware-host CI. Owner/Watch authorization and production BLE channel-routing
  regressions added to the existing actual-adapter suites.

## Remaining software gates

1. Firmware speech manager, coherent readiness/status, native characteristic
   callback and application ACK result integration; priority audio worker with
   safety preemption, bounded decode/read-ahead, cancellation and hardware cleanup.
2. Final signed resident-pack format, separately scoped trust, worker-owned
   HTTPS installer, fifth transfer handler, bounded checkpoints and recovery,
   atomic activation journal, space checks, SD/FFat backend, app install flow.
3. Dynamic `AVSpeechSynthesizer.write`/`AVAudioConverter` rendering, rolling
   prefetch, bounded resumable low-priority BLE stream, PSRAM cache admission,
   asset validation, eviction, and resident fallback. Do not increase the
   64 KiB asset ceiling just to fit the prototype's 8-second output.
4. Device settings controls and live mute/volume propagation, workout pause and
   rerouting lifecycle hooks, background/locked-phone tests, dynamic selection.
5. Full app and both-board firmware build/qualification, parser fuzzing,
   transport/storage fault injection, memory/priority/privacy acceptance and
   exact-head review. Host tests are not physical audio evidence.

## External/physical gates (not performed)

- User confirmed the **1.75-inch** board is connected. No image has been flashed
  by this implementation task. Exact device/image confirmation is required
  immediately before any flash. The 2.06-inch board remains a separate target.
- User requested pack preparation; no owned/licensed production recordings have
  been provided. Synthetic test waveforms are not a production voice pack.
- Codec choice, audible quality, latency, PWR/horn preemption, power/battery,
  SD/FFat contention, cold boot and recovery remain unmeasured on both boards.
- Production speech signing keys/trust provisioning and release distribution
  have not been authorized or performed.

No resident/dynamic readiness capability is advertised by current firmware.
This PR must remain a draft until the complete implementation and its explicit
qualification policy are satisfied; do not present it as a working spoken-turn
feature or an issue-closing release on the strength of these host tests.
