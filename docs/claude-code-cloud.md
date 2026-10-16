# Claude Code cloud setup

At <https://claude.ai/code>, choose the `seichris/open-bike-computer` repository
and add a personal cloud environment named **Open Bike Computer**.

- Keep **Trusted** network access.
- Paste `.claude/cloud-environment-setup.sh` into **Setup script**. It installs
  Ubuntu host-test prerequisites without starting builds or services.
- Set `BASH_DEFAULT_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS=600000` in
  **Environment variables** for longer checks. Do not put credentials there.
- Select a branch containing this setup. `CLAUDE.md` imports `AGENTS.md`, and
  `.claude/settings.json` runs the cloud-only dependency hook after checkout.

The hook fetches `main` into `origin/main` without changing the checkout. Claude
cloud clones may initially track only the selected branch, while `dev-check`
needs `origin/main` for its comparison. The hook then installs
`tools/development/requirements.txt` in `.claude/.venv` and
persists its PATH using `CLAUDE_ENV_FILE`. It skips installation when its inputs
are unchanged, and does nothing in local sessions. Environment setup is cached;
the repository hook checks dependencies again on startup and resume.

Start a smoke-check session with:

> Read CLAUDE.md and AGENTS.md. Verify the cloud hook completed, run
> tools/dev-check --plan, then run the development registry and CI policy checks
> selected by the plan. Report the commit, results, and blocked prerequisites.
> Do not edit files, build firmware, deploy, or access physical devices.

Linux supports the repository's Python and C/C++ host checks. Apple SDK,
Xcode/Simulator, and physical-device checks still require Mac/CI/device evidence.
Use `docs/development-checks.md` for check selection and reports. A plan is not a
passing test run. Full firmware builds use the existing locked runtime on demand
and may require additional network hosts; report a blocked download rather than
switching to ambient PlatformIO or broadening network access automatically.

For map-platform work, install into its separate ignored environment:

```sh
python3 -m venv map-platform/backend/.venv
map-platform/backend/.venv/bin/python -m pip install \
  -e 'map-platform/backend[test,api,object-storage]'
```

Use that interpreter for backend tests. Add the `topography` extra only when
needed; use Python 3.11 or 3.12 for its pinned NumPy version. Read the backend
and extractor documentation before running services or map builds. The host-test
environment pins cryptography 50 while the backend requires a version below 49,
so combining them breaks dependency resolution.

Reference: [Claude cloud environment documentation](https://code.claude.com/docs/en/cloud-environments).
