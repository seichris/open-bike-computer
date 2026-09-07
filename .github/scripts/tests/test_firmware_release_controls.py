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
                                                "reviewers": [{"type": "User"}]}],
                         "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}},
            policies=[{"name": "main", "type": "branch"}],
            environment_secrets=list(controls.PRIVATE_KEYS), broad_secrets=[], branch="main",
            rulesets=[{"target": "tag", "enforcement": "active",
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
        self_review = copy.deepcopy(good)
        self_review["environment"]["protection_rules"][0]["prevent_self_review"] = False
        bad.append(self_review)
        bypass = copy.deepcopy(good)
        bypass["rulesets"][0]["conditions"]["ref_name"]["exclude"] = ["refs/tags/v0.*"]
        bad.append(bypass)
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):
                controls.validate(**value)

    def test_control_check_precedes_secret_use(self):
        workflow = (Path(__file__).resolve().parents[2] / "workflows/firmware-release.yml").read_text()
        self.assertLess(workflow.index("uses: ./.github/actions/require-firmware-release-controls"),
                        workflow.index("- name: Generate signed manifests"))
        self.assertNotIn("git_sha_short", workflow)
        self.assertIn("group: firmware-release-channel", workflow)


if __name__ == "__main__":
    unittest.main()
