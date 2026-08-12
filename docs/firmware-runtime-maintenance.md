# Firmware runtime maintenance and publication

Ordinary contributors build and test firmware with the usual
`python3 tools/build_firmware.py <environment>` command. Only maintainers use
this refresh process; no scheduled job, dependency bot, repair operation, or
normal build updates the accepted closure.

## Refresh sequence

1. On a dedicated review branch, deliberately edit exact roots, versions,
   source sizes/SHA-256 values, license evidence, or generator logic under
   `esp32/tools/firmware-runtime/`. Choose a new unique lock-set/release ID in
   `publication-v1.json`; its strict contract requires the tag and lock-set ID
   to match.
2. Manually dispatch **Firmware runtime refresh candidate** from that exact
   commit. It has read-only repository permissions. Native Linux x86-64 and
   Apple Silicon jobs build independent A/B candidates, require byte identity,
   replay nested environments offline, perform clean/warm builds, package both
   production targets through the locked helper, and prove tamper rejection.
3. Review the uploaded `firmware-runtime-review-summary` plus native evidence.
   The canonical summary compares old/candidate roots, wheels, source digests,
   distribution sets, licenses, runner/generator evidence, validation files,
   and the proposed 11-asset publication inventory. It is evidence, not
   approval or lock acceptance.
4. Manually dispatch **Publish reviewed firmware runtime** at the same exact
   commit and supply the successful candidate run ID. Its first job rebinds the
   run ID to the expected workflow, commit, event, conclusion, both native
   candidate artifacts, and both build-validation artifacts.
5. Approve the `firmware-runtime-publication` environment only after human
   review. Configure that GitHub environment with required reviewers before the
   next refresh. Only the post-approval job receives `contents: write`.
6. Enable GitHub repository immutable releases before publication. The
   publisher fails before creating a release unless that repository setting is
   active.
7. The publisher requires the Git tag to be absent, creates a draft prerelease
   and a lightweight tag at the exact reviewed generator commit, proves that
   binding, uploads the exact create-only 11-asset set without `--clobber`, and verifies
   every server-reported size/SHA-256 while recovery is still possible. It then
   publishes the draft, requires GitHub to report the release as immutable,
   re-verifies the complete asset set, and retains that immutable publication
   receipt. Any existing tag/asset, mutable release, or transport mismatch
   fails closed.
8. In a later normal pull request, assemble and review `lock-v1.json` from the
   published contracts. Merging that lock is the acceptance event. Publication
   alone never changes ordinary builds.

Create-only publication and server-side immutable releases are both mandatory.
The repository currently has to be configured once by an administrator before
the next runtime or product release; this workflow never weakens the repository
setting or silently falls back to a mutable release.

## Performance and rollback

Runtime-affecting pull requests run five warm handoff checks on
`ubuntu-24.04` and `macos-15`. The checked baseline is lock-specific; a median
regression beyond 20% requires a profile and explicit baseline review. The
existing custom-core source-only/cold-build 35% gate remains separate.

Rollback never edits an accepted asset. Revert the tracked lock to a previous
accepted lock in a normal pull request, rebuild affected private state, and use
a new product release tag for rollback firmware. `--repair-runtime` can only
redownload the same accepted target; it is not an update mechanism.
