import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import firmware_release_controls as controls


class ReleaseControlsTests(unittest.TestCase):
    def fixture(self):
        return dict(
            environment={"protection_rules": [{"type": "required_reviewers", "prevent_self_review": True,
                                                "reviewers": [{"type": "User", "reviewer": {"id": 25006584, "login": "seichris"}}]}],
                         "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}},
            policies=[{"name": "main", "type": "branch"}],
            environment_secrets=list(controls.PRIVATE_KEYS), broad_secrets=[], branch="main",
            rulesets=[{"target": "tag", "enforcement": "active",
                       "bypass_actors": [{"actor_type": "User", "actor_id": 25006584, "bypass_mode": "always"}],
                       "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
                       "rules": [{"type": kind} for kind in ("creation", "update", "deletion")]}])

    def test_complete_controls_pass(self):
        controls.validate(**self.fixture())

    def test_missing_or_broadened_controls_fail(self):
        good = self.fixture()
        bad = []
        for key, value in (("environment", {}), ("policies", []),
                           ("policies", [{"name": "*", "type": "branch"}]),
                           ("policies", [{"name": "main", "type": "tag"}]),
                           ("environment_secrets", []), ("rulesets", [])):
            bad.append({**copy.deepcopy(good), key: value})
        for secret in controls.PRIVATE_KEYS:
            bad.append({**copy.deepcopy(good), "broad_secrets": [secret]})
        for reviewers in ([], [{"type": "Team", "reviewer": {"id": 25006584}}],
                          [{"type": "User", "reviewer": {"id": 123, "login": "seichris"}}]):
            wrong_reviewer = copy.deepcopy(good)
            wrong_reviewer["environment"]["protection_rules"][0]["reviewers"] = reviewers
            bad.append(wrong_reviewer)
        broad_bypass = copy.deepcopy(good)
        broad_bypass["rulesets"][0]["bypass_actors"].append({"actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always"})
        bad.append(broad_bypass)
        bypass = copy.deepcopy(good)
        bypass["rulesets"][0]["conditions"]["ref_name"]["exclude"] = ["refs/tags/v0.*"]
        bad.append(bypass)
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):
                controls.validate(**value)

    def test_self_review_is_explicit_policy_not_missing_review(self):
        fixture = self.fixture()
        fixture["environment"]["protection_rules"][0]["prevent_self_review"] = False
        controls.validate(**fixture)
        independent = {**controls.review_policy(), "reviewMode": "independent"}
        with self.assertRaises(ValueError):
            controls.validate(**fixture, policy=independent)
        fixture["environment"]["protection_rules"][0]["prevent_self_review"] = True
        controls.validate(**fixture, policy=independent)

    def test_migration_workflow_has_no_write_token_or_secret_deletion(self):
        source = (Path(__file__).resolve().parents[2] / "workflows/firmware-key-migration.yml").read_text()
        self.assertIn("github.ref == 'refs/heads/main'", source)
        self.assertIn("github.actor_id == '25006584'", source)
        self.assertIn("github.run_attempt == '1'", source)
        self.assertIn("persist-credentials: false", source)
        self.assertIn("--require-hashes --only-binary=:all: --no-deps", source)
        self.assertNotIn(": write", source)
        self.assertNotIn("secret delete", source)
        self.assertNotIn("pull_request", source)
        self.assertEqual(source.count("secrets.FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY"), 1)
        self.assertIn("retention-days: 1", source)

    def test_control_check_precedes_secret_use(self):
        workflow = (Path(__file__).resolve().parents[2] / "workflows/firmware-release.yml").read_text()
        self.assertLess(workflow.index("uses: ./.github/actions/require-firmware-release-controls"),
                        workflow.index("- name: Generate signed manifests"))
        self.assertLess(workflow.index("uses: ./.github/actions/require-firmware-release-controls"),
                        workflow.index("FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY: ${{ secrets."))


if __name__ == "__main__":
    unittest.main()
