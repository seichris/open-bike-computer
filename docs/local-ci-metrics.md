# Local-result reuse metrics

The shared check runner writes an optional `*-reuse-metrics.json` alongside its
existing validation reports. These files are included by the existing report
artifact upload; there is no network telemetry service or added CI job. Receipt
trust, source matching, command selection and fallback gates stay unchanged.

## Counts and denominators

Each visited check has one observation. `eligible` means the runner permits this
kind of check to reuse a result; it does not mean an authorized receipt exists.
`attempted` means a receipt lookup actually happened. Reading the base trust policy
is shared initialization, not a per-check lookup. Initialization failures therefore
produce eligible, not-attempted checks, followed by normal execution.

Accepted receipts, lookup misses, and eligible checks that could not attempt reuse
are separate outcomes. Failed fallbacks remain failed checks. Ineligible commands
continue to run. Unselected commands and commands never reached after an earlier
failure are outside these denominators; Bicino records visited planned/blocked
checks with their own reasons. Local publication runs have `context: local` and
are aggregated separately from CI-mode consumption.

`context: ci-mode` means CI or GITHUB_ACTIONS was set, matching the existing
runner mode. It is not proof of GitHub/VPS origin: a local `CI=1` invocation also
belongs here. Use GitHub artifact provenance when selecting hosted runs for a
comparison; do not infer actual hosting from this field.

## Reasons and timing

Reasons are fixed categories, never exception text. They distinguish source/merge
tree, recipe, environment, toolchain/dependency mismatches; absent, stale or invalid
timestamps, signature/log/receipt failures; unavailable policy/fingerprint/network;
and disabled/ineligible/planned/blocked checks. A receipt must reach the relevant
verification stage before its mismatch can be classified. Only the first rejecting
condition is counted. No secret values or mismatch contents are exported.

An **absent** receipt does not identify why no candidate exists. In the Node repos,
the lookup key already incorporates the source tree, recipe and runtime hint;
any of these differences can yield absence. Bicino keys by tree and check. We do
not scan unrelated receipts or guess a mismatch from a missing lookup.

- `initializationMs`: shared policy/configuration and preparation once per runner
  invocation. Bicino's eager toolchain fingerprints are included here.
- `preparationMs`: per-check source/recipe/environment preparation (Node runners).
- `lookupMs`: per-check receipt transport, including failed lookups.
- `verificationMs`: parsing, fingerprinting and signed receipt verification;
  Bicino also includes materializing the verified receipt/log.
- `fallbackDurationMs`: actual eligible CI-mode command execution after reuse fails
  or is unavailable, including nonzero exits. Null means no fallback executed.
  This excludes receipt lookup/verification and local receipt publication.
- `estimatedAvoidedExecutionMs`: only for accepted receipts, computed from signed
  `completedAt - startedAt`, in whole seconds converted to milliseconds. This is
  the elapsed local receipt window (which can include preparation), not a measured
  duration for a hypothetical hosted command. Subsecond work can estimate zero.

These estimates are **not measured end-to-end, queue, runner or billing savings**.
A runner still starts and may install dependencies, fingerprint tools, verify
receipts and execute other checks. The report does not subtract these costs to
invent net savings. Queue metrics are owned by the VPS/controller workflow.

## Aggregate final artifacts

Download the existing report artifacts for the runs and window being compared.
Keep all final metric files together; this script accepts all three repositories:

```sh
python3 tools/development/summarize-local-reuse.py /path/to/downloaded-artifacts > local-reuse-summary.json
```

The summary contains CI-mode/local totals, repository/check/platform breakdowns,
reason counts, elapsed totals and rates with explicit numerators and denominators:
lookups/eligible, accepted/lookups, accepted/eligible. Zero denominators produce
null rates. Shared initialization is counted once per invocation and is not
allocated to checks. Duplicate repository/run UUIDs count once; provide only the
final snapshot, not intermediate and final versions of the same run. Invalid files
are counted and excluded. Each rerun has a new UUID and counts as another attempt.

Only fixed labels, check/repository identifiers and numeric measurements are
exported. No commands, logs, source hashes, environment values, keys, signatures,
transport bodies, user paths or raw exception messages appear in these artifacts.
Extra fields from input files are not copied into summaries.

Metric collection and writing failures cannot accept a receipt, suppress fallback,
or change a check's exit status. Missing artifacts are outside measured coverage;
compare available artifacts against GitHub run/job inventory before interpreting
rates. Existing validation reports and signed evidence retain their prior access
and retention rules; the metrics file does not replace them.

## Qualification and recovery

The receipt tests use temporary real signing keys, matching injected toolchain and
source identities, and the real runners with marker commands. They exercise hits,
mismatch/network/absent fallbacks, failed fallback exit status, timing, privacy and
unavailable telemetry. Aggregation tests cover all three repositories, denominators,
platform/context separation and duplicate/invalid inputs. These are deterministic
fixture measurements, not evidence of production reuse or savings.

Revert this metrics PR to remove instrumentation. No trust policy, signing key,
evidence data branch, VPS configuration or workflow change is required. Because
runner/verifier bytes are part of existing recipes, deploying or reverting this
change invalidates older recipe receipts and causes normal fallback until matching
fresh local evidence exists.
