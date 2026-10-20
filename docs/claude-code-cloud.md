# Claude Code cloud setup

At <https://claude.ai/code>, choose the `seichris/open-bike-computer` repository
and add a personal cloud environment named **Open Bike Computer**.

- Keep **Trusted** network access.
- Paste `.claude/cloud-environment-setup.sh` into **Setup script**. It installs
  Ubuntu host-test prerequisites without starting builds or services.
- Set `BASH_DEFAULT_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS=600000` in
  **Environment variables** for longer checks. Do not put credentials there.
- Select a branch containing this setup. `CLAUDE.md` imports `AGENTS.md`, and
  the shared `.claude/settings.json` hook runs `tools/dev-setup --quiet`.

The hook uses the same per-worktree development environment as Codex. Keep
installation and dependency fingerprinting in `tools/development/environment.py`;
do not add a separate cloud installer or virtual environment. Run commands through
`tools/dev-env`, which checks that the selected environment is current.
Environment setup is cached independently of the checkout; rerun `tools/dev-setup`
if requirements change during a session.

Cloud clones may initially track only the selected branch. Before using the
`origin/main` comparison, materialize it without changing the checkout:

```sh
git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
tools/dev-env tools/dev-check --plan
```

Start a smoke-check session with:

> Read CLAUDE.md and AGENTS.md. Verify the shared setup completed, fetch the
> origin/main comparison ref as documented, run tools/dev-env tools/dev-check
> --plan, then run the development registry and CI policy checks selected by the
> plan. Report the commit, results, and blocked prerequisites. Do not edit files,
> build firmware, deploy, or access physical devices.

Linux supports the repository's Python and C/C++ host checks. Apple SDK,
Xcode/Simulator, and physical-device checks still require Mac/CI/device evidence.
Use `docs/development-checks.md` for check selection and reports. A plan is not a
passing test run. Full firmware builds use the existing locked runtime on demand
and may require additional network hosts; report a blocked download rather than
switching to ambient PlatformIO or broadening network access automatically.

For map-platform work, use the separate environment:

```sh
tools/dev-setup --map-backend
tools/dev-env --map-backend tools/dev-check --suite map
```

This selects Python 3.10-3.12 for the pinned topography dependencies and keeps the
backend's cryptography constraints separate from host tests. Read the backend
and extractor documentation before running services or map builds.

Reference: [Claude cloud environment documentation](https://code.claude.com/docs/en/cloud-environments).
