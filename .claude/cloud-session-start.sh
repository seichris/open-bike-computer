#!/usr/bin/env bash
# Project dependencies belong here, after checkout, rather than in the VM cache.
set -euo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:?Claude project directory is required}"
repo_root="$PWD"
venv="$repo_root/.claude/.venv"
stamp="$venv/requirements.sha256"

# Install again when either requirement file or this installer changes. Write the
# stamp only after success, so a failed install is retried on the next session.
fingerprint=$(sha256sum tools/development/requirements.txt \
  esp32/tools/preconnection-assets-requirements.txt \
  .claude/cloud-session-start.sh)
if [[ ! -x "$venv/bin/python3" ]]; then
  python3 -m venv "$venv"
fi
if [[ ! -f "$stamp" ]] || [[ "$(cat "$stamp")" != "$fingerprint" ]]; then
  "$venv/bin/python3" -m pip install --disable-pip-version-check \
    -r tools/development/requirements.txt
  printf '%s\n' "$fingerprint" > "$stamp"
fi

# SessionStart's environment file persists PATH for subsequent Bash commands.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  printf 'export PATH=%q:"$PATH"\n' "$venv/bin" >> "$CLAUDE_ENV_FILE"
fi
printf 'Open Bike Computer host dependencies ready. Start with tools/dev-check --plan.\n'
