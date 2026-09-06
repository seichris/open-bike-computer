#!/usr/bin/env python3
"""Build an authentication-only API overlay on the exact production base.

This is deliberately not a switch to run current API/job code with an old
worker. All non-authentication code comes from the immutable base image.
"""
from __future__ import annotations

import argparse
import ast
import copy
import difflib
import hashlib
import json
from pathlib import Path
import shutil

BASE_SOURCE = "e739dfe6c0612e95db8241249dcc2edfe52d8372"
BASE_API_SHA256 = "0bb2596ebffa6d96f1caffb513c0d18a1ba38964ebcf78c9d6141bb7e121621a"
AUTH_ARGUMENTS = {
    "request_body", "x_app_attest_challenge_id", "x_app_attest_key_id",
    "x_app_attest_assertion", "x_app_attest_app_build",
}


def named(nodes, name):
    matches = [node for node in nodes if getattr(node, "name", None) == name]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {name}")
    return matches[0]


def dump(node):
    return ast.dump(node, include_attributes=False)


def authenticated_create_handler(current, baseline):
    handler = copy.deepcopy(baseline)
    offset = len(current.args.args) - len(current.args.defaults)
    additions = [(a, current.args.defaults[i - offset])
                 for i, a in enumerate(current.args.args) if a.arg in AUTH_ARGUMENTS and i >= offset]
    if {a.arg for a, _ in additions} != AUTH_ARGUMENTS:
        raise ValueError("authentication arguments changed")
    handler.args.args.extend(copy.deepcopy(a) for a, _ in additions)
    handler.args.defaults.extend(copy.deepcopy(d) for _, d in additions)
    current_lock = next(n for n in ast.walk(current) if isinstance(n, ast.With))
    authentication = []
    for statement in current_lock.body:
        text = ast.unparse(statement)
        if (isinstance(statement, ast.If) and "x_app_attest_challenge_id" in text
            or isinstance(statement, ast.Assign) and text.startswith("assertion_object =")
            or isinstance(statement, ast.Expr) and text.startswith("app_attest_store.verify_map_create_assertion(")):
            authentication.append(statement)
    if len(authentication) != 3:
        raise ValueError("authentication statements changed")
    lock = next(n for n in ast.walk(handler) if isinstance(n, ast.With))
    insertion = next(i for i, n in enumerate(lock.body)
                     if isinstance(n, ast.If) and ast.unparse(n.test) == "existing is not None") + 1
    lock.body[insertion:insertion] = copy.deepcopy(authentication)

    # Prove that deleting ONLY the authentication additions recovers the exact
    # base handler, including job persistence, idempotency and rate limiting.
    projection = copy.deepcopy(handler)
    projection.args.args = projection.args.args[:-len(additions)]
    projection.args.defaults = projection.args.defaults[:-len(additions)]
    projected_lock = next(n for n in ast.walk(projection) if isinstance(n, ast.With))
    del projected_lock.body[insertion:insertion + len(authentication)]
    if dump(projection) != dump(baseline):
        difference = "\n".join(difflib.unified_diff(ast.unparse(baseline).splitlines(), ast.unparse(projection).splitlines()))
        raise ValueError("current map-create logic is not compatible with the base worker:\n" + difference)
    return handler


def backport_api(baseline_text: str, current_text: str) -> str:
    if hashlib.sha256(baseline_text.encode()).hexdigest() != BASE_API_SHA256:
        raise ValueError("production API base does not match the reviewed source")
    baseline, current = ast.parse(baseline_text), ast.parse(current_text)
    old_factory = named(baseline.body, "create_app")
    new_factory = named(current.body, "create_app")
    old_factory.args = ast.parse(
        "def create_app(*, app_attest_verifier: AppAttestationVerifying | None = None): pass"
    ).body[0].args
    replacements = {
        "create_installation": copy.deepcopy(named(new_factory.body, "create_installation")),
        "create_map_job": authenticated_create_handler(
            named(new_factory.body, "create_map_job"), named(old_factory.body, "create_map_job")
        ),
    }
    for index, node in enumerate(old_factory.body):
        if getattr(node, "name", None) in replacements:
            old_factory.body[index] = replacements[node.name]

    imports = [n for n in current.body if isinstance(n, ast.ImportFrom) and n.module == "app_attest"]
    if len(imports) != 1:
        raise ValueError("App Attest import changed")
    baseline.body[1:1] = ast.parse("import logging\n_LOGGER = logging.getLogger(__name__)\n").body + imports
    setup = ast.parse('''
app_attest_store = AppAttestStore(
    data_root / "app-attest.sqlite3",
    app_attest_verifier or production_app_attest_verifier(deployment_channel),
    challenge_ttl_seconds=int(os.environ.get("MAP_PLATFORM_APP_ATTEST_CHALLENGE_TTL_SECONDS", "300")),
)
''').body[0]
    channel_indices = [i for i, n in enumerate(old_factory.body)
                       if isinstance(n, ast.Assign) and ast.unparse(n).startswith("deployment_channel =")]
    if len(channel_indices) != 1:
        raise ValueError("base deployment channel changed")
    old_factory.body.insert(channel_indices[0] + 1, setup)
    app_state_index = next(i for i, n in enumerate(old_factory.body)
                           if ast.unparse(n).startswith("app.state.installation_store ="))
    old_factory.body.insert(app_state_index + 1, ast.parse("app.state.app_attest_store = app_attest_store").body[0])
    insertion = next(i for i, n in enumerate(old_factory.body) if getattr(n, "name", None) == "enforce_rate_limits")
    old_factory.body[insertion:insertion] = [
        copy.deepcopy(named(new_factory.body, name))
        for name in ("app_attest_error", "captured_request_body")
    ]
    insertion = next(i for i, n in enumerate(old_factory.body) if getattr(n, "name", None) == "create_installation")
    old_factory.body.insert(insertion, copy.deepcopy(named(new_factory.body, "create_app_attest_challenge")))
    public = named(old_factory.body, "is_public_api_request")
    text = ast.unparse(public)
    needle = "path == '/v1/installations'"
    if text.count(needle) != 1:
        raise ValueError("base public route guard changed")
    replacement = ast.parse(text.replace(needle, "path in {'/v1/installations', '/v1/installations/app-attest/challenges'}")).body[0]
    old_factory.body[old_factory.body.index(public)] = replacement
    health = named(old_factory.body, "healthz").body[0].value
    new_health = named(new_factory.body, "healthz").body[0].value
    attest = next(value for key, value in zip(new_health.keys, new_health.values) if key.value == "appAttest")
    health.keys.append(ast.Constant("appAttest"))
    health.values.append(copy.deepcopy(attest))
    ast.fix_missing_locations(baseline)
    result = ast.unparse(baseline) + "\n"
    compile(result, "compatibility/api.py", "exec")
    return result


def prepare(package: Path, current: Path):
    baseline = package / "api.py"
    result = backport_api(baseline.read_text(), (current / "api.py").read_text())
    # The package is inside a disposable build context/image, never live /data.
    baseline.write_text(result)
    for relative in ("app_attest.py", "data/Apple_App_Attestation_Root_CA.pem"):
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(current / relative, target)
    print(json.dumps({"profile": "production-auth-compatibility", "baseSource": BASE_SOURCE,
                      "apiSha256": hashlib.sha256(result.encode()).hexdigest()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.package, args.current)
