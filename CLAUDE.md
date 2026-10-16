# Claude Code

@AGENTS.md

## Cloud sessions

Read `docs/claude-code-cloud.md` for environment setup and validation limits.
The cloud SessionStart hook prepares a Python environment for host tests and
puts it on PATH. Start with `tools/dev-check --plan`; use the checked-in check
registry rather than duplicating test recipes.

Cloud sessions run on Linux. Xcode, Apple SDKs, Simulator, physical iPhone/Watch,
USB firmware upload, and physical board acceptance require the corresponding
Mac, device, or CI evidence. Report blocked checks explicitly.

Use the repository-locked `esp32/tools/build_firmware.py` for explicit firmware
builds; do not install ambient PlatformIO or replace the locked runtime.
Do not start a full firmware build merely to initialize this environment.

Keep map-platform dependencies in `map-platform/backend/.venv`; they have
different cryptography constraints from the host-test environment.
