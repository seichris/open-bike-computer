#!/usr/bin/env python3
"""Seal/verify the existing firmware key. Never export plaintext or delete secrets."""

import argparse
import ast
import base64
import hashlib
import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

import firmware_release_controls as controls

REPOSITORY = "seichris/open-bike-computer"
ENVIRONMENT = "firmware-release"
SOURCE_ENVIRONMENT = "firmware-runtime-publication"
SECRET = "FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY"
WORKFLOW = ".github/workflows/firmware-key-migration.yml"
ROOT = Path(__file__).resolve().parents[2]
DOMAIN = b"Bicino firmware key migration receipt v1\x00"


class MigrationError(Exception):
    pass


def run_gh(arguments, input_data=None):
    # No shell, secret argv, inherited key, HTTP debug logging or raw errors.
    env = {k: v for k, v in os.environ.items()
           if k not in ("MIGRATION_SIGNING_KEY", SECRET, "GH_DEBUG", "DEBUG")}
    result = subprocess.run(["gh", *arguments], input=input_data,
                            capture_output=True, timeout=60, env=env)
    if result.returncode:
        raise MigrationError("GitHub operation failed; no secret data emitted")
    return result.stdout


def api(path, payload=None):
    arguments = ["api", "--hostname", "github.com", "-H", "X-GitHub-Api-Version: 2026-03-10", path]
    if payload is not None:
        arguments += ["--method", "PUT", "--input", "-"]
    result = run_gh(arguments, None if payload is None else json.dumps(payload).encode())
    return json.loads(result) if result.strip() else None


def root_path(suffix):
    return f"repos/{REPOSITORY}/{suffix}".rstrip("/")


def environment_path(suffix):
    return root_path(f"environments/{ENVIRONMENT}/{suffix}")


def secret_metadata(environment=None, secret=SECRET):
    path = (root_path(f"environments/{environment}/secrets?per_page=100")
            if environment else root_path("actions/secrets?per_page=100"))
    result = api(path)
    if result.get("total_count", 101) > 100:
        raise MigrationError("secret inventory exceeds bounded migration scope")
    return next((x for x in result["secrets"] if x["name"] == secret), None)


def trusted_public_key():
    source = (ROOT / "esp32/lib/firmware_update/firmware_update_http.cpp").read_text()
    match = re.search(r'kManifestSigningPublicKeyPem\s*=\s*((?:"[^"\n]*"\s*)+);', source)
    if not match:
        raise MigrationError("firmware trust anchor missing")
    pem = "".join(ast.literal_eval(x) for x in re.findall(r'"[^"\n]*"', match[1]))
    key = serialization.load_pem_public_key(pem.encode())
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise MigrationError("firmware trust anchor must be P-256")
    return key


def fingerprint(key):
    return hashlib.sha256(key.public_bytes(serialization.Encoding.DER,
                            serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()


def signing_key(value):
    try:
        raw = base64.b64decode(value, validate=True)
        if len(raw) != 32 or base64.b64encode(raw) != value:
            raise ValueError()
        key = ec.derive_private_key(int.from_bytes(raw, "big"), ec.SECP256R1())
        if fingerprint(key.public_key()) != fingerprint(trusted_public_key()):
            raise ValueError()
        return key
    except Exception:
        raise MigrationError("signing key does not match the firmware trust anchor") from None


def canonical(receipt):
    return DOMAIN + json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()


def sign_receipt(receipt, key):
    return {"receipt": receipt, "signature": base64.b64encode(
        key.sign(canonical(receipt), ec.ECDSA(hashes.SHA256()))).decode()}


def validate_run(run, sha, run_id, *, completed):
    if (run.get("id") != run_id or run.get("head_sha") != sha or
        run.get("head_branch") != "main" or run.get("event") != "workflow_dispatch" or
        run.get("run_attempt") != 1 or run.get("path") != WORKFLOW or
        run.get("actor", {}).get("id") != 25006584 or
        run.get("head_repository", {}).get("full_name") != REPOSITORY or
        (completed and run.get("conclusion") != "success")):
        raise MigrationError("migration run identity or conclusion does not match")


def predates_run(metadata, run):
    # Strictly earlier than dispatch prevents a repository fallback captured
    # before a same-name environment secret was created from passing proof.
    if metadata is None or datetime.fromisoformat(metadata["updated_at"].replace("Z", "+00:00")) >= datetime.fromisoformat(run["created_at"].replace("Z", "+00:00")):
        raise MigrationError("environment secret must predate this verification run")


def validate_destination():
    environment = api(root_path(f"environments/{ENVIRONMENT}"))
    controls.validate_review(environment, controls.review_policy())
    policies = api(environment_path("deployment-branch-policies?per_page=100"))
    if (environment.get("deployment_branch_policy") != {
        "protected_branches": False, "custom_branch_policies": True
    } or [(x["name"], x["type"]) for x in policies["branch_policies"]] != [("main", "branch")]):
        raise MigrationError("destination environment must admit only main")


def workflow_context(operation):
    env = os.environ
    sha = env.get("GITHUB_SHA", "")
    run_id = env.get("GITHUB_RUN_ID", "")
    if (env.get("GITHUB_REPOSITORY") != REPOSITORY or
        env.get("GITHUB_REF") != "refs/heads/main" or
        env.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or
        env.get("GITHUB_ACTOR_ID") != "25006584" or
        env.get("GITHUB_RUN_ATTEMPT") != "1" or
        env.get("GITHUB_WORKFLOW_REF") != f"{REPOSITORY}/{WORKFLOW}@refs/heads/main" or
        not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[1-9][0-9]*", run_id)):
        raise MigrationError("migration requires the owner's first-attempt main workflow")
    repo = api(root_path(""))
    if repo.get("default_branch") != "main" or api(root_path("commits/main"))["sha"] != sha:
        raise MigrationError("main changed since dispatch; dispatch a fresh reviewed run")
    protection = api(root_path("branches/main/protection"))
    checks = protection.get("required_status_checks") or {}
    if (not protection.get("enforce_admins", {}).get("enabled") or
        not checks.get("strict") or "CI Gate" not in checks.get("contexts", [])):
        raise MigrationError("main must enforce strict CI Gate, including admins")
    validate_destination()
    run = api(root_path(f"actions/runs/{run_id}"))
    validate_run(run, sha, int(run_id), completed=False)
    source = SOURCE_ENVIRONMENT if operation == "prepare" else ENVIRONMENT
    controls.validate_review(api(root_path(f"environments/{source}")), controls.review_policy())
    predates_run(secret_metadata(source, "FIRMWARE_RELEASE_PREFLIGHT_APP_PRIVATE_KEY"), run)
    return {"schemaVersion": 1, "repository": REPOSITORY, "environment": ENVIRONMENT,
            "secret": SECRET, "runId": int(run_id), "gitSha": sha,
            "firmwarePublicKeySha256": fingerprint(trusted_public_key())}


def prepare(value):
    receipt = workflow_context("prepare")
    if secret_metadata(ENVIRONMENT) is not None or secret_metadata(SOURCE_ENVIRONMENT) is not None:
        raise MigrationError("destination must be absent and source environment must not shadow repository key")
    if secret_metadata() is None:
        raise MigrationError("repository signing key is missing")
    key = signing_key(value)
    recipient = api(environment_path("public-key"))
    ciphertext = run_gh(["secret", "set", SECRET, "--repo", f"github.com/{REPOSITORY}",
                         "--env", ENVIRONMENT, "--no-store"], value).strip()
    if len(base64.b64decode(ciphertext, validate=True)) != len(value) + 48:
        raise MigrationError("invalid sealed-secret output")
    if api(environment_path("public-key")) != recipient:
        raise MigrationError("environment encryption key changed; prepare again")
    receipt.update(operation="prepare", keyId=recipient["key_id"],
                   recipientKeySha256=hashlib.sha256(base64.b64decode(recipient["key"], validate=True)).hexdigest(),
                   encryptedValue=ciphertext.decode())
    return sign_receipt(receipt, key)


def verify_destination(value):
    receipt = workflow_context("verify")
    before = secret_metadata(ENVIRONMENT)
    if before is None:
        raise MigrationError("destination secret absent; repository fallback is not verification")
    predates_run(before, api(root_path(f"actions/runs/{receipt['runId']}")))
    key = signing_key(value)
    if secret_metadata(ENVIRONMENT) != before:
        raise MigrationError("destination metadata changed during verification")
    receipt.update(operation="verify", destinationUpdatedAt=before["updated_at"])
    return sign_receipt(receipt, key)


def validate_receipt(document, operation):
    receipt = document["receipt"]
    trusted_public_key().verify(base64.b64decode(document["signature"], validate=True),
                                canonical(receipt), ec.ECDSA(hashes.SHA256()))
    common = {"schemaVersion", "repository", "environment", "secret", "runId", "gitSha",
              "firmwarePublicKeySha256", "operation"}
    extra = ({"keyId", "recipientKeySha256", "encryptedValue"} if operation == "prepare"
             else {"destinationUpdatedAt"})
    if (set(receipt) != common | extra or receipt["schemaVersion"] != 1 or
        receipt["repository"] != REPOSITORY or receipt["environment"] != ENVIRONMENT or
        receipt["secret"] != SECRET or receipt["operation"] != operation or
        receipt["firmwarePublicKeySha256"] != fingerprint(trusted_public_key()) or
        type(receipt["runId"]) is not int or receipt["runId"] <= 0 or
        not re.fullmatch(r"[0-9a-f]{40}", receipt["gitSha"])):
        raise MigrationError("unexpected migration receipt")
    return receipt


def install(document, expected_run, expected_sha):
    receipt = validate_receipt(document, "prepare")
    if receipt["runId"] != expected_run or receipt["gitSha"] != expected_sha:
        raise MigrationError("receipt is not the explicitly selected run and SHA")
    validate_run(api(root_path(f"actions/runs/{expected_run}")), expected_sha, expected_run, completed=True)
    comparison = api(root_path(f"compare/{expected_sha}...main"))
    if comparison.get("status") not in ("ahead", "identical"):
        raise MigrationError("migration workflow commit is not on current main")
    validate_destination()
    recipient = api(environment_path("public-key"))
    if (recipient["key_id"] != receipt["keyId"] or
        hashlib.sha256(base64.b64decode(recipient["key"], validate=True)).hexdigest() != receipt["recipientKeySha256"] or
        len(base64.b64decode(receipt["encryptedValue"], validate=True)) != 92):
        raise MigrationError("sealed value or destination key identity is invalid")
    if secret_metadata(ENVIRONMENT) is not None:
        raise MigrationError("destination already exists; refusing to overwrite")
    api(environment_path(f"secrets/{SECRET}"), {
        "key_id": receipt["keyId"], "encrypted_value": receipt["encryptedValue"]})
    if secret_metadata(ENVIRONMENT) is None:
        raise MigrationError("destination metadata is not visible after upload")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "verify", "install"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--expected-run", type=int)
    parser.add_argument("--expected-sha")
    args = parser.parse_args()
    # Remove the scalar before any child process is launched.
    value = os.environ.pop("MIGRATION_SIGNING_KEY", "").encode()
    try:
        if args.operation == "install":
            if not args.receipt or args.receipt.stat().st_size > 8192 or not args.expected_run or not args.expected_sha:
                raise MigrationError("install requires a bounded receipt and explicit run/SHA")
            install(json.loads(args.receipt.read_text()), args.expected_run, args.expected_sha)
            print("Encrypted environment copy installed. Original retained; destination verification still required.")
        else:
            if args.output is None:
                raise MigrationError("receipt output path required")
            document = prepare(value) if args.operation == "prepare" else verify_destination(value)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x") as handle:
                json.dump(document, handle, sort_keys=True)
            print(f"Firmware key migration {args.operation} passed; only a signed non-secret receipt was written.")
    except Exception:
        # Do not serialize third-party exceptions or command responses from a
        # process that handled the signing scalar. Debug in synthetic tests.
        raise SystemExit("Firmware key migration failed closed; no plaintext output; original secret retained.") from None


if __name__ == "__main__":
    main()
