# October 20 production release

The maintainer requested production app, firmware, and backend publication and
accepted the outstanding storage, transfer/OTA recovery, and rendering risks
after software checks. This is operator acceptance, not physical qualification.
No manual hardware-matrix runs were performed for these exact identities.
The checked-in optional matrix and production signing trust are unchanged.

## Bound identities

- Firmware: `0.3.4`, build `104`, commit
  `483ac42937fa3d982410d82b591f2c2ec13a39f0`, tag `v0.3.4-release.12`.
- Signed map worker: source `6033914a8fa2e7c54143ef5202014648f648f2d7`,
  image `sha256:fccd83b043c7e30d0fdb3553873a491f6679e181f4a48d63e73539b48a43173a`,
  contained producer identity
  `471453a21d7aa485b85423735300be65476ed3abd8fbeaa3adc2cb5245e796ca`.
- App 1.10, build 28: final signed archive from the firmware commit above,
  component identity
  `e73deabff6ce13ce63f3d128986579086855bdc2c7fe1ef6fdaff16ad179cce4`.
- Existing public app identities 24 and 25 are retained by new approval records
  bound to this worker and firmware. Historical records remain unchanged.
- Runtime promotion: `msr-20261020-build104-ios28`; compatible app records are
  `msr-20261020-build104-ios24` and `msr-20261020-build104-ios25`.

The report checker validated all three reports against the checked-in production
requirements and trust registry. Raw reports remain in protected operator
release artifacts; only their hash-bound public records are committed.

## Activation order

1. Require the complete protected firmware candidate run `39360158217` to pass
   for both production boards, then publish GitHub/OTA and verify signatures,
   assets, and live manifests. PR #593 CI alone is insufficient for this step.
2. Publish an attested control-plane image containing this approval registry.
   Use the image workflow's `preserve-pending` decision to keep the exact worker
   already proposed by PR #586. Review both resulting immutable Compose pins.
3. Require promotion CI, then deploy the complete lock and new promotion ID
   coherently. Verify `/healthz` reports the new worker, producer, firmware,
   promotion, and approved app identities. Do not override image-selection
   variables on the server.
4. Submit app build 28 only after its map admission record is live.

New signed map installation requires firmware build 104 with the exact Git
identity above. Older firmware must update first. Maps already installed on
devices remain local. Retain the complete old Compose lock and old promotion ID
for an explicit rollback; do not mix old and new approval bindings.

The isolated production social API/worker use the same attested application
image and a separate private production database, Firebase project, and R2
bucket. Twenty synthetic-account production checks passed, including private
media, private saved routes, accepted-rider GPS/statistics, live WebSockets,
public invitation metadata/image integrity, website rendering, revocation,
signed deletion handoff, and verified fixture cleanup. Interactive native
Apple/Google login and physical APNs delivery are separate, unmeasured gates.
