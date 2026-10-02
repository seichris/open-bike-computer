"""Compatibility images must never become signed-map generation workers."""
import os
import sys


def allowed(command, environment):
    if environment.get("MAP_PLATFORM_INLINE_WORKER_ENABLED", "0").strip().lower() not in {"0", "false", "no"}:
        return False
    return command in [
        ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"],
        ["map-platform", "maintenance-loop"],
    ]


if __name__ == "__main__":
    command = sys.argv[1:]
    if not allowed(command, os.environ):
        sys.exit("authentication compatibility image only supports API and maintenance; keep the generation worker pinned")
    os.execvp(command[0], command)
