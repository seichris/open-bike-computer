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

Host dependencies come from the per-worktree environment that `tools/dev-setup`
creates; run checks with `tools/dev-env tools/dev-check` (see Worktree
environment below). Firmware continues to hand off to its exact
repository-locked runtime.

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

## Worktree environment

Prepare each worktree with `tools/dev-setup` and run Python-dependent commands
through `tools/dev-env`:

```sh
tools/dev-setup
tools/dev-env tools/dev-check --plan
tools/dev-env tools/dev-check
tools/dev-setup --map-backend
tools/dev-env --map-backend tools/dev-check --suite map
```

The Codex app runs `tools/dev-setup` when it creates a worktree
(`.codex/environments/environment.toml`, which also defines check and build-only
actions); Claude Code runs `tools/dev-setup --quiet` from the SessionStart hook
in `.claude/settings.json`. `CLAUDE.md` only imports `AGENTS.md`, and
`.claude/skills` links to `.agents/skills`, so both apps read the same rules and
skills. Keep logic in `tools/development/environment.py`, not in the adapters.

Setup picks the first healthy Python 3.10-3.14 (3.13 preferred; override with
`OPEN_BIKE_PYTHON`), creates the ignored `.venv/` from
`tools/development/requirements.txt` and records an input fingerprint, so an
unchanged rerun only verifies. Input changes update the environment in place;
an environment that is broken or uses a Python outside its range is reported
and moved aside (never deleted) only with `--recreate`. The map backend pins an
incompatible `cryptography`, so `--map-backend` creates the separate
`map-platform/backend/.venv/` with the map-platform CI extras plus `api`
(`.[api,test,object-storage,topography,social]`) on Python 3.10-3.12, because
the topography pins have no wheels for newer Pythons. Runs in the
same worktree serialize on a lock in that worktree's Git directory; separate
worktrees never share or modify each other's environments. Only pip's user
download cache is shared.

Setup then runs `tools/dev_check.py --plan` and prints each blocked
prerequisite, for example missing Xcode command-line tools or MbedTLS. It never
installs global packages, changes `xcode-select`, accepts licenses, builds or
flashes firmware, opens serial ports, installs apps, deploys or reads signing
keys. Firmware still bootstraps lazily through its repository-locked runtime:
verified downloads and core transport use
`~/Library/Caches/OpenBikeComputer/`, while mutable PlatformIO and build state
stays below each worktree's `esp32/.pio/open-bike-build/`; never share or link
those directories, DerivedData, manifests or upload plans between worktrees.
`tools/dev-env` refuses to run when its environment is missing, broken or stale.


## CI scope policy

The required `CI Gate` validates selections and rejects missing, failed or cancelled
selected jobs. Full manual scopes remain available; no branch protection changes are
needed. Empty diffs run full coverage. Deletions and renames retain old/new paths.

| Changed inputs | Selected qualification |
| --- | --- |
| Only production/development Compose locks | Deployment policy, all compatibility images, Compose and referenced-image digest/provenance checks; no backend rebuild, catalog, PostgreSQL or native readers |
| Only catalog | Catalog typecheck/tests and both environment dry-runs |
| Other map source/shared config | Full map consumers, plus OSM when its inputs change |
| Known Swift helper sources | Matching navigation map/sensor/workout/radio groups using the shared source registry; other host contracts remain |
| Unknown Swift source or script/registry/config | Full helper suite |
| Unclassified tooling, protocol or CI input | Selection fails before product jobs; add an explicit consumer mapping. Development/CI unit tests and Markdown remain exempt |
| Workout-zone fixture | One Swift workout helper and both-board zone contracts; no firmware images, native apps/simulators, backend or OSM |
| Firmware release history / boot-acceptance verifier | Existing Python manifest/tool tests only; no native host dependency installation or unrelated zone contracts |
| iOS application source | Fresh Debug app/container evidence; dedicated simulators only for their production/test/shared dependencies |
| iOS build/distribution/project/identity inputs or full manual/release | Debug and Release containers plus relevant simulator contracts |
| Production firmware libraries | Production and lifecycle, with extra ordinary/debug profiles for their conditional features |
| BLE navigation or map-transfer libraries | Production plus remote-debug (2 builds per selected board). A preprocessor coverage test checks all four profiles on both boards and rejects uncovered ordinary/lifecycle-only branches |
| Firmware board/runtime/build configuration | Every regular profile for both boards; board-specific 206 files retain 206 selection |
| CI/shared-runner configuration | Every regular profile for the requested board family (175 by default); full manual/release requests still select both families |

Ordinary source-only PRs no longer prove Release compilation. Before release, use
full CI; the release candidate always requests all components and both board families.
Local `--suite ios --level full` still builds both configurations by default. Explicit
`BICINO_IOS_CONFIGURATIONS=Debug` is a Debug-only result, never Release evidence.
The navigation umbrella script without arguments still runs every assertion; its
`map`, `sensors`, `workout`, and `radio` arguments select the same registry-backed groups.

Promotion dispatch first checks for an eligible existing CI run at the current head;
branch movement aborts selection. The protected partial gate still requires the exact
promotion branch and its sole allowed lock file. No deployment or rollout policy is
relaxed. Unknown product sources keep their component fallback; unmapped shared tools, protocol files and CI inputs must declare their consumers instead of silently skipping or triggering every component.

The host job validates its nonempty check-ID selection before executing named registry steps. A missing/failed selected job still fails the aggregate gate. The rider-badge renderer runs for potentially rendering-related changes; BLE/transfer-only edits skip that unrelated benchmark. Documentation and CI unit-test edits accompanying firmware do not expand the hardware matrix. Lifecycle adapters under `firmware_update` and `map_transfer_http`, shared board/build inputs, and explicit manual/release scopes retain broader qualification. The preprocessor guard establishes source-branch coverage, not linking, runtime equivalence or physical acceptance.

Compare total runner-minutes as well as wall time on the next 5–10 natural PR runs by scope/cache state. Tighten routing if a
full/manual/release lane finds an omitted relevant failure. Revert the selector and
workflow changes to restore the broad policy; do not raise runner resource limits.
