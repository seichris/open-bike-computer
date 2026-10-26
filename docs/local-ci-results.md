# Automatic reuse of local iOS test results

`tools/dev-check` automatically signs and publishes successful clean-source iOS
helper and simulator results on a configured trusted Mac. The existing iOS CI
jobs verify them before running each selected check. A verified result is marked
`execution: reused-local` in the normal report; a miss runs the original command
and its failure still fails `CI Gate`. Required check names do not change.

Commit the final source, run the normal local checks, then push. For example:

```sh
tools/dev-env tools/dev-check --suite ios
# Optional full simulator contract suite:
tools/dev-env tools/dev-check --check ios-simulator
git push
```

This Mac's repository configuration enables automatic publication across its
worktrees. There is no pre-push hook, extra approval prompt, or manual pass flag.
Tests completed after CI has already looked for evidence help a later rerun;
the current job simply runs hosted tests. Publishing failures never turn local
test success into failure. Old receipts and tests run directly outside the shared
runner are not eligible.

## What must match

- The receipt's commit must equal the PR head. Its **entire Git tree** must equal
  the actual checkout tested by CI, including GitHub's merge result. An unrelated
  base-branch change can therefore cause a conservative miss. No head-only checkout
  is substituted for the merge test. Source must be clean and unchanged throughout
  local execution; assume-unchanged and sparse checkout entries are rejected.
- The full registry entry, command, working directory, flags, runner and verifier
  code hashes must match. The tree also binds all scripts, dependency locks and
  Swift source lists. Reusable runs use a shared environment profile that removes
  test filters such as `ONLY_TESTING`, compiler overrides and shell startup hooks.
  Checks requested with `--reuse-local` keep that profile on every fallback,
  including unavailable policy, toolchain, or source evidence.
- macOS build, CPU architecture, Python version/binary/package metadata, shell,
  Git, xcrun, Swift/Clang versions and binaries, Xcode build, and SDK builds must
  match the hosted runner. Simulator checks additionally match the selected iOS
  and Watch runtime builds and device types. The producer measures the toolchain
  before and after execution. Host path names are not toolchain identity.
- A successful actual execution, valid timestamps no older than seven days, and
  the complete signed log must verify. Malformed, altered, oversized, missing,
  expired, dirty, failed or incompatible evidence falls back to hosted execution.

Hosted macOS machines still start to measure their actual toolchain. When this Mac
and `macos-latest` differ, the hosted commands run normally; this feature does not
change CI's toolchain to manufacture a match. The schema-2 report records the live
fingerprint and each reuse decision for inspection.

## Trust and storage

The Mac holds a dedicated Ed25519 key under
`~/Library/Application Support/OpenBikeComputer/local-ci/` with private permissions.
The reviewed public keys and explicit check allowlist live in
`tools/development/local-results-policy.json`. CI reads that policy from the
**PR base SHA**, never from the PR's proposed key list or the evidence branch.
New keys become trusted only after the policy is merged. Removing a key from the
base policy revokes its receipts for new PR runs.

Signed JSON envelopes, including compressed full test logs, are published through
the authenticated GitHub CLI to the data-only orphan branch `ci/local-test-results`.
The branch contains no workflows and must never be merged. Writes use GitHub's
conditional blob update. The branch itself is not trusted: changing any receipt
or log invalidates its signature. CI uses only its existing read-only contents
token; the signing key is never sent to GitHub. API failure or conflicting uploads
are harmless misses. Receipts are capped at 700 KB and decompressed logs at 8 MB.
Evidence is retained in Git history; acceptance expires after seven days without
rewriting that history.

CI retains the accepted signed envelope and verified text log in the existing
check-evidence artifact. For simulator reuse, the original `.xcresult` bundles
remain beside the local runner's report; they are not transferred through Git.
This receipt certifies the test result, not a downloadable app or firmware build.

To configure another trusted Mac explicitly:

```sh
tools/dev-setup
tools/dev-env python3 tools/development/local_results.py setup
# Review the added public key and submit the policy change in a PR.
```

Setup creates a dedicated key if needed, initializes the data branch if absent,
and sets repository-local `bicino.localResultsKey`. To stop automatic publication,
run `git config --local --unset bicino.localResultsKey`. Do not copy the private key
into the repository or CI secrets.

Only ordinary same-repository PRs can reuse results. Forks, merge groups, manual
qualification, reusable release workflows and tags always execute hosted checks.
Linux/GCC coverage, firmware builds, app-container builds and exact-build symbols,
release signing and physical device acceptance remain outside this mechanism.

Reuse counters, categorized fallbacks, elapsed timings and aggregation are described in [Local-result reuse metrics](local-ci-metrics.md).
