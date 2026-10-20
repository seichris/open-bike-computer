# Firmware 0.3.4 build 104 release acceptance

On 2026-10-20, seichris requested public GitHub/OTA publication of the latest
firmware and explicitly accepted the outstanding production-board storage,
transfer/OTA recovery, and rendering risks after software checks pass. The
accepted implementation is merged source `6033914a8fa2e7c54143ef5202014648f648f2d7`;
this release advances only its monotonic build allocation from 103 to 104.
Build 103 is already allocated to immutable `v0.3.4-release.10`.

Both Waveshare production targets and all selected firmware checks passed in
run [39355434674](https://github.com/seichris/open-bike-computer/actions/runs/39355434674)
for that implementation. The new exact release commit must additionally pass
the protected candidate workflow before publication.

Neither board has new physical qualification in this release task. No board
is flashed. This is explicit residual-risk acceptance, not a claim of physical
factory/golden qualification. Signing identity, trust anchors, App Attest,
and default-off experimental capabilities remain unchanged.

The unpublished `v0.3.4-release.11` candidate used the already allocated build
103 and was cancelled. It must not be published. Use a fresh release tag for
build 104; never retag or overwrite existing firmware assets.
