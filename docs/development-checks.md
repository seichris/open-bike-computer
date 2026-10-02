# Development checks

From any directory, invoke the repository's `tools/dev-check` entry point. Local
development and CI execute the same checks in `tools/development/checks.json`.
Swift compiler invocations resolve their production source graphs from
`tools/development/swift-sources.json`; update those graphs when a dependency
changes. Existing test scripts remain compatible entry points.

```sh
tools/dev-check --plan
tools/dev-check
tools/dev-check --suite ios --level full
tools/dev-check --suite firmware --level full --board 175
tools/dev-check --suite all --level full --board 175
tools/dev-check --suite ios --level full --fresh --evidence
```

Automatic selection uses the merge base with `origin/main`, commits since that
base, staged/unstaged edits, and nonignored untracked files. `--base REF` changes
the comparison. The default fast level selects affected host checks and always
checks the development registry and CI policy. Full adds simulator contracts,
unsigned Debug/Release app containers and a firmware build through the locked
wrapper. Ordinary builds accept uncommitted edits and record their dirty-source
fingerprint. `--evidence` requires clean committed source before builds and retains
exact-build symbols; `--fresh` uses disposable iOS build state. CI explicitly uses
both for app qualification. Dirty firmware builds retain the wrapper's existing
prohibition on cache publication and upload. Identify
the connected board before selecting its build environment; this command never
flashes, installs apps, or deploys services. CI-only image/service qualification
continues to use the existing deployment scripts and required aggregate gate.

Scenario fixtures and host-only Swift source graphs select host checks without
selecting native app/simulator builds, even at the full level. App/protocol changes
continue to select native validation. Check-registry recipe edits are compared
with the base version and select their old/new consumers; unavailable baselines
or unknown registry metadata conservatively select all consumers. Shared runner
changes also validate every consumer. Development unit tests do not select
product builds. Explicit `--suite ios --level full` always includes native checks.

`--check ID` selects an exact registered check; repeat it for several checks.
CI uses this form to keep each existing check visible as a named step. Use
`--report /absolute/path/results.json` to choose a retained report; the default
is a unique directory in this worktree's Git metadata. A report records the
commit/tree, dirty-state content fingerprint, host, interpreter, scope, board,
durations, log locations and individual results. Source changes during execution
invalidate the overall result even if individual tests passed. Reports for dirty
worktrees cannot be described as clean-commit validation.

Every selected prerequisite is checked before tests begin. Missing tools,
unsupported hosts, Python modules, native headers, and simulator runtimes are
**blocked**, and make an executed check return nonzero. Test failures are
**failed**. `--plan` inspects selection/prerequisites without running tests.
Neither a blocked prerequisite nor an omitted full check is proof of validation.

On macOS, use a healthy Python and an isolated environment for host dependencies:

```sh
python3 -m venv /absolute/path/to/development-venv
/absolute/path/to/development-venv/bin/python -m pip install \
  -r tools/development/requirements.txt
/absolute/path/to/development-venv/bin/python tools/dev_check.py --plan
```

This environment is for host tests. Firmware continues to hand off to its exact
repository-locked runtime. Map checks use the dependencies documented by the
backend and extractor; native crypto checks also need compatible MbedTLS headers
and libraries. The plan reports missing prerequisites without installing into an
ambient interpreter or modifying the firmware runtime.

Host checks receive their own temporary directories and compiler module caches.
Local app-container checks keep Debug/Release DerivedData under this worktree's
ignored `ios-app/DerivedData/development-checks/`, with an exclusive lease spanning
builds and container verification. Concurrent builds in the same worktree fail
with an ownership message; separate worktrees have separate state. Xcode retains
its module caches for incremental reuse. `--fresh` creates disposable state,
without deleting the persistent local directories.
Standalone Swift scripts also create their own temporary namespace. Simulator
contracts select a runtime compatible with the active Xcode SDK, create a fresh
simulator, exclusively lease it through completion and
cleanup, then delete only that owned simulator. To use a deliberately selected
existing simulator, set `BICINO_SIMULATOR_UDID`; it must match the platform and
cannot be concurrently leased by another check. Borrowed simulators are never
shut down or deleted by the runner. Worktrees must also have separate DerivedData
paths. A simulator lease does not authorize physical iPhone/Watch actions.

CI runs simulator contracts and Debug/Release app builds as separate jobs. The
protected CI Gate requires both when heavy iOS validation is selected, and
requires both to be skipped otherwise. App container validation and release
debug-feature exclusion remain mandatory. Check reports/logs are retained on
both success and failure, including native `.xcresult` bundles.

The durable download coordinator and zone delivery clock policy live in small
production compilation units. Host tests compile those files directly with
controlled delegates, private storage and clocks; they do not extract source
between declarations. The durable test invocation uses whole-module compilation
and host-only access-control inspection for existing private-state assertions;
app builds retain ordinary Swift access control. These tests do not establish
physical radio, filesystem power-loss or device delivery acceptance.
