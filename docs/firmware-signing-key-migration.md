# Firmware signing authority and existing-key migration

This administrative-only prerequisite preserves the existing firmware identity.
It does not build, flash or publish firmware. Execution and secret cleanup require
separate operator approval after this workflow lands on reviewed main.

The publisher now runs `firmware_release_controls.py` before exposing the
firmware scalar to the signing command. Its read-only App token needs
Administration, Actions, Contents, Environments and Secrets **read** permissions.
It reads secret names only, requires both private keys in `firmware-release`,
rejects repository/organization copies, requires the checked-in environment-review policy,
an exact default-branch-only deployment policy, strict admin-enforced `CI Gate`,
and an active `v*` creation/update/deletion ruleset. Missing API access fails
closed. See GitHub's [environment API](https://docs.github.com/en/rest/deployments/environments)
and [secret metadata API](https://docs.github.com/en/rest/actions/secrets).

This gate is not a substitute for secret migration: another branch workflow can
bypass source checks while a repository-scoped key still exists. An administrator
must provision the existing key from secure custody or the controlled encrypted
migration (GitHub's API cannot return its value), verify environment scope, then
remove the broad copy. Do not
print or pass the real scalar in a rehearsal. Coordinate the preflight App key
with `firmware-runtime-publication`: provision an environment-scoped copy there
before removing its repository copy, retain that publisher's required permissions,
and review its environment/ref policy. Preparing the workflow does not migrate
live keys, authenticate new App keys, or satisfy any physical firmware gate.

### Controlled migration when the local firmware key is lost

The manually dispatched `firmware-key-migration.yml` preserves the existing
P-256 identity. It has no delete operation, no arbitrary recipient input, no
secret-write token on a runner, and does not publish firmware or a release. Its
scripts and policy must first land through a reviewed PR on `main`. Do not run
an equivalent key-handling workflow from a feature branch. This administrative-only
prerequisite is split from #422; it does not
include or qualify that PR's firmware changes. Do not merge or release the
hardware changes merely to enable migration.

Prerequisites:

- Keep both repository-level private keys until verification completes.
- Add the existing/new preflight App private key to `firmware-release` and
  `firmware-runtime-publication`. It must be for App ID 4579522, with repository
  Administration, Environments, Secrets, Contents and Actions read access. No
  secret-write permission or replacement App is needed.
- Both environments require the named maintainer reviewer. Only `main` may
  deploy to `firmware-release`; the workflow also rejects non-main dispatches,
  a moved default-branch head, other actors, forks and reruns.
- There must be no firmware-scalar secret in `firmware-runtime-publication`
  shadowing the repository source, and no destination scalar yet. The same-name
  App secret in each environment must predate dispatch to prove the environment
  copy was used. Disable debug logging and keep concurrent secret writers stopped.

1. Dispatch and approve the exact reviewed main commit:

   ```sh
   gh workflow run firmware-key-migration.yml --ref main -f operation=prepare
   ```

   Record the exact successful run ID and SHA; never select a merely "latest"
   artifact. The source job uses `firmware-runtime-publication` for approval and
   the environment-scoped read-only App key. It validates that the repository
   scalar derives the public key embedded in firmware. `gh secret set --no-store`
   then encrypts the scalar for the fixed destination environment using stdin,
   not an argument. The destination public-key identity is read before and after.
   Only a one-day artifact containing ciphertext and a domain-separated signed
   receipt is uploaded. No plaintext key is logged, written to a file or sent to
   an operator. The trusted runner/OS, pinned actions and dependencies, GitHub CLI
   and GitHub control plane remain execution trust boundaries.

2. Download that run's `firmware-key-migration-RUN_ID-prepare` artifact. In a clean
   reviewed checkout with the pinned signing dependencies, run:

   ```sh
   python3 .github/scripts/firmware_key_migration.py install \
     --receipt /absolute/path/to/receipt.json \
     --expected-run RUN_ID --expected-sha FULL_REVIEWED_SHA
   ```

   This local step needs the existing operator's environment-write authority.
   It checks the receipt signature, selected run/SHA, successful owner/main run,
   main ancestry, unchanged destination encryption key and absent destination
   before uploading **ciphertext only**. It does not need the firmware private
   key. An existing destination fails rather than being intentionally replaced.
   GitHub's PUT API has no conditional-create primitive: exclude concurrent
   writers during the check/upload interval. Metadata read-back is not yet
   cryptographic proof of the stored key; do not delete the source now.

3. After installation, dispatch a new verification run:

   ```sh
   gh workflow run firmware-key-migration.yml --ref main -f operation=verify
   ```

   Approve `firmware-release`. The job requires its scalar's metadata timestamp
   to predate dispatch, rejects metadata changes during verification, and uses
   the destination environment's same-name secret. A missing/late-created
   destination cannot pass using repository fallback. The loaded scalar must
   derive the unchanged firmware public key and sign a non-release receipt.
   A successful run also authenticates that environment's App key. Review both
   exact-run receipts and App access before any cleanup.

4. Only after both successful runs and review, remove the two exact
   repository-level secret copies. The environment copies remain. Re-run
   `firmware_release_controls.py` and record its `single-maintainer` result;
   never label it independent approval. The migration tool intentionally does
   not automate deletion. Remove/disable the one-time migration workflow after
   completion through a reviewed change. Moving the firmware key does not
   rotate it, revoke old signatures or prove absence of prior exposure.
