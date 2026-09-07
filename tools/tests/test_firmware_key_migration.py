"""Synthetic keys only; never invokes GitHub or accesses production secrets."""
import base64
import copy
import hashlib
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric import ec

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
import firmware_key_migration as migration


class KeyMigrationTests(unittest.TestCase):
    def setUp(self):
        self.key = ec.derive_private_key(1, ec.SECP256R1())
        self.value = base64.b64encode((1).to_bytes(32, "big"))
        self.public_patch = patch.object(migration, "trusted_public_key", return_value=self.key.public_key())
        self.public_patch.start()
        self.addCleanup(self.public_patch.stop)
        self.sha = "a" * 40
        self.recipient = {"key_id": "test-key-id", "key": base64.b64encode(b"p" * 32).decode()}
        self.metadata = {"name": migration.SECRET, "updated_at": "2026-09-07T00:00:00Z"}
        self.run = {"id": 42, "head_sha": self.sha, "head_branch": "main", "event": "workflow_dispatch",
                    "run_attempt": 1, "path": migration.WORKFLOW, "actor": {"id": 25006584},
                    "head_repository": {"full_name": migration.REPOSITORY}, "conclusion": "success",
                    "created_at": "2026-09-07T00:01:00Z"}
        self.context = {"schemaVersion": 1, "repository": migration.REPOSITORY,
                        "environment": migration.ENVIRONMENT, "secret": migration.SECRET,
                        "runId": 42, "gitSha": self.sha,
                        "firmwarePublicKeySha256": migration.fingerprint(self.key.public_key())}

    def receipt(self):
        return migration.sign_receipt({**self.context, "operation": "prepare", "keyId": self.recipient["key_id"],
            "recipientKeySha256": hashlib.sha256(b"p" * 32).hexdigest(),
            "encryptedValue": base64.b64encode(b"c" * 92).decode()}, self.key)

    def test_real_firmware_anchor_can_be_parsed(self):
        self.public_patch.stop()
        key = migration.trusted_public_key()
        self.assertIsInstance(key.curve, ec.SECP256R1)
        self.assertNotEqual(migration.fingerprint(key), migration.fingerprint(self.key.public_key()))

    def test_source_scalar_format_and_existing_trust_are_required(self):
        self.assertEqual(migration.signing_key(self.value).private_numbers().private_value, 1)
        for value in (b"", b"not a scalar", self.value + b"\n", base64.b64encode(b"\x00" * 32),
                      base64.b64encode((2).to_bytes(32, "big")), base64.b64encode(b"a" * 33)):
            with self.subTest(value=value), self.assertRaises(migration.MigrationError):
                migration.signing_key(value)

    def test_receipt_is_signed_bound_and_domain_separated(self):
        document = self.receipt()
        self.assertEqual(migration.validate_receipt(document, "prepare")["runId"], 42)
        self.assertTrue(migration.canonical(document["receipt"]).startswith(migration.DOMAIN))
        for field in document["receipt"]:
            bad = copy.deepcopy(document)
            bad["receipt"][field] = "tampered"
            with self.subTest(field=field), self.assertRaises(Exception):
                migration.validate_receipt(bad, "prepare")
        with self.assertRaises(Exception):
            migration.validate_receipt(document, "verify")
        self.assertNotIn(self.value.decode(), json.dumps(document))

    def test_signing_key_never_enters_child_argv_environment_or_errors(self):
        with patch.dict(os.environ, {"MIGRATION_SIGNING_KEY": self.value.decode(), migration.SECRET: self.value.decode(),
                                     "GH_DEBUG": "api"}), patch.object(migration.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"ciphertext", b"")
            migration.run_gh(["secret", "set", migration.SECRET, "--no-store"], self.value)
            args, kwargs = run.call_args
            self.assertNotIn(self.value.decode(), str(args))
            self.assertNotIn("MIGRATION_SIGNING_KEY", kwargs["env"])
            self.assertNotIn(migration.SECRET, kwargs["env"])
            self.assertNotIn("GH_DEBUG", kwargs["env"])
            self.assertEqual(kwargs["input"], self.value)
            run.return_value = subprocess.CompletedProcess([], 1, self.value, self.value)
            with self.assertRaises(migration.MigrationError) as raised:
                migration.run_gh(["secret", "set", migration.SECRET], self.value)
            self.assertNotIn(self.value.decode(), str(raised.exception))

    def test_prepare_only_seals_for_fixed_environment_and_retains_source(self):
        def metadata(environment=None, secret=migration.SECRET):
            return self.metadata if environment is None else None
        with patch.object(migration, "workflow_context", return_value=dict(self.context)), \
             patch.object(migration, "secret_metadata", side_effect=metadata), \
             patch.object(migration, "api", return_value=self.recipient) as api, \
             patch.object(migration, "run_gh", return_value=base64.b64encode(b"c" * 92)) as gh:
            document = migration.prepare(self.value)
            migration.validate_receipt(document, "prepare")
            self.assertEqual(gh.call_args.args[1], self.value)
            command = gh.call_args.args[0]
            self.assertIn("--no-store", command)
            self.assertEqual(command[command.index("--env") + 1], migration.ENVIRONMENT)
            self.assertTrue(all(len(call.args) == 1 for call in api.call_args_list))

    def test_prepare_rejects_existing_or_shadowed_key_before_encryption(self):
        for existing in (migration.ENVIRONMENT, migration.SOURCE_ENVIRONMENT):
            with patch.object(migration, "workflow_context", return_value=dict(self.context)), \
                 patch.object(migration, "secret_metadata", side_effect=lambda env, existing=existing: self.metadata if env == existing else None), \
                 patch.object(migration, "run_gh") as gh, self.assertRaises(migration.MigrationError):
                migration.prepare(self.value)
            gh.assert_not_called()

    def test_prepare_rejects_rotated_recipient(self):
        with patch.object(migration, "workflow_context", return_value=dict(self.context)), \
             patch.object(migration, "secret_metadata", side_effect=[None, None, self.metadata]), \
             patch.object(migration, "api", side_effect=[self.recipient, {**self.recipient, "key_id": "new"}]), \
             patch.object(migration, "run_gh", return_value=base64.b64encode(b"c" * 92)), \
             self.assertRaises(migration.MigrationError):
            migration.prepare(self.value)

    def test_destination_verification_is_not_repository_fallback(self):
        with patch.object(migration, "workflow_context", return_value=dict(self.context)), \
             patch.object(migration, "api", return_value=self.run), \
             patch.object(migration, "secret_metadata", return_value=self.metadata):
            result = migration.verify_destination(self.value)
            self.assertEqual(migration.validate_receipt(result, "verify")["destinationUpdatedAt"], self.metadata["updated_at"])
        for metadata in (None, {**self.metadata, "updated_at": self.run["created_at"]},
                         {**self.metadata, "updated_at": "2026-09-07T00:02:00Z"}):
            with patch.object(migration, "workflow_context", return_value=dict(self.context)), \
                 patch.object(migration, "api", return_value=self.run), \
                 patch.object(migration, "secret_metadata", return_value=metadata), \
                 self.assertRaises(migration.MigrationError):
                migration.verify_destination(self.value)

    def test_wrong_fork_branch_actor_attempt_workflow_or_conclusion_fails(self):
        migration.validate_run(self.run, self.sha, 42, completed=True)
        for field, value in (("id", 43), ("head_sha", "b" * 40), ("head_branch", "feature"),
                             ("event", "pull_request"), ("run_attempt", 2), ("path", "other.yml"),
                             ("actor", {"id": 1}), ("head_repository", {"full_name": "fork/repo"}),
                             ("conclusion", "failure")):
            with self.subTest(field=field), self.assertRaises(migration.MigrationError):
                migration.validate_run({**self.run, field: value}, self.sha, 42, completed=True)

    def test_install_sends_only_ciphertext_and_never_deletes_source(self):
        writes = []
        def api(path, payload=None):
            if payload is not None:
                writes.append((path, payload))
                return None
            if "actions/runs" in path: return self.run
            if "compare/" in path: return {"status": "ahead"}
            if path.endswith("public-key"): return self.recipient
            raise AssertionError(path)
        with patch.object(migration, "api", side_effect=api), \
             patch.object(migration, "validate_destination"), \
             patch.object(migration, "secret_metadata", side_effect=[None, self.metadata]):
            migration.install(self.receipt(), 42, self.sha)
        self.assertEqual(writes, [(migration.environment_path(f"secrets/{migration.SECRET}"),
            {"key_id": self.recipient["key_id"], "encrypted_value": self.receipt()["receipt"]["encryptedValue"]})])
        self.assertNotIn(self.value.decode(), json.dumps(writes))

    def test_install_rejects_existing_destination_or_wrong_selected_run(self):
        with patch.object(migration, "api", side_effect=[self.run, {"status": "identical"}, self.recipient]) as api, \
             patch.object(migration, "validate_destination"), \
             patch.object(migration, "secret_metadata", return_value=self.metadata), \
             self.assertRaises(migration.MigrationError):
            migration.install(self.receipt(), 42, self.sha)
        self.assertTrue(all(len(call.args) == 1 for call in api.call_args_list))
        with patch.object(migration, "api") as api, self.assertRaises(migration.MigrationError):
            migration.install(self.receipt(), 43, self.sha)
        api.assert_not_called()

    def test_destination_cannot_allow_all_refs_with_lingering_main_rule(self):
        environment = {"protection_rules": [{"type": "required_reviewers", "prevent_self_review": False,
            "reviewers": [{"type": "User", "reviewer": {"id": 25006584, "login": "seichris"}}]}],
            "deployment_branch_policy": None}
        with patch.object(migration, "api", side_effect=[environment, {
            "branch_policies": [{"name": "main", "type": "branch"}]}]), self.assertRaises(migration.MigrationError):
            migration.validate_destination()

    def test_off_main_context_rejected_before_network(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/topic"}), \
             patch.object(migration, "api") as api, self.assertRaises(migration.MigrationError):
            migration.workflow_context("prepare")
        api.assert_not_called()

    def test_full_workflow_context_and_changed_main_or_late_app_key(self):
        environment = {"protection_rules": [{"type": "required_reviewers", "prevent_self_review": False,
            "reviewers": [{"type": "User", "reviewer": {"id": 25006584, "login": "seichris"}}]}],
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}
        runner = {"GITHUB_REPOSITORY": migration.REPOSITORY, "GITHUB_REF": "refs/heads/main",
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR_ID": "25006584",
            "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": self.sha, "GITHUB_RUN_ID": "42",
            "GITHUB_WORKFLOW_REF": f"{migration.REPOSITORY}/{migration.WORKFLOW}@refs/heads/main"}
        responses = {
            migration.root_path(""): {"default_branch": "main"},
            migration.root_path("commits/main"): {"sha": self.sha},
            migration.root_path("branches/main/protection"): {"enforce_admins": {"enabled": True},
                "required_status_checks": {"strict": True, "contexts": ["CI Gate"]}},
            migration.root_path(f"environments/{migration.ENVIRONMENT}"): environment,
            migration.root_path(f"environments/{migration.SOURCE_ENVIRONMENT}"): environment,
            migration.environment_path("deployment-branch-policies?per_page=100"):
                {"branch_policies": [{"name": "main", "type": "branch"}]},
            migration.root_path("actions/runs/42"): self.run,
        }
        for source in (migration.ENVIRONMENT, migration.SOURCE_ENVIRONMENT):
            responses[migration.root_path(f"environments/{source}/secrets?per_page=100")] = {
                "total_count": 1, "secrets": [{**self.metadata,
                    "name": "FIRMWARE_RELEASE_PREFLIGHT_APP_PRIVATE_KEY"}]}
        with patch.dict(os.environ, runner, clear=True), patch.object(migration, "api", side_effect=responses.__getitem__):
            for operation in ("prepare", "verify"):
                self.assertEqual(migration.workflow_context(operation), self.context)
            responses[migration.root_path("commits/main")]["sha"] = "b" * 40
            with self.assertRaises(migration.MigrationError):
                migration.workflow_context("prepare")
            responses[migration.root_path("commits/main")]["sha"] = self.sha
            inventory = responses[migration.root_path(f"environments/{migration.SOURCE_ENVIRONMENT}/secrets?per_page=100")]
            inventory["secrets"][0]["updated_at"] = self.run["created_at"]
            with self.assertRaises(migration.MigrationError):
                migration.workflow_context("prepare")

    def test_entrypoint_suppresses_secret_bearing_exception(self):
        with patch.dict(os.environ, {"MIGRATION_SIGNING_KEY": self.value.decode()}), \
             patch.object(sys, "argv", ["migration", "prepare", "--output", "/unused/receipt.json"]), \
             patch.object(migration, "prepare", side_effect=ValueError(self.value.decode())), \
             self.assertRaises(SystemExit) as raised:
            migration.main()
        self.assertNotIn(self.value.decode(), str(raised.exception))


if __name__ == "__main__":
    unittest.main()
