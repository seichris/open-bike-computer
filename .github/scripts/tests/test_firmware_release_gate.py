from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "firmware_release_gate.py"
SPEC = importlib.util.spec_from_file_location("firmware_release_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

REPOSITORY = "owner/repository"
WORKFLOW_PATH = ".github/workflows/firmware-release-candidate.yml"
GIT_SHA = "0123456789abcdef0123456789abcdef01234567"


class FirmwareReleaseGateTests(unittest.TestCase):
    def fixture(self) -> tuple[dict, dict, dict]:
        workflow = {
            "id": 91,
            "name": gate.EXPECTED_WORKFLOW_NAME,
            "path": WORKFLOW_PATH,
            "state": "active",
        }
        run = {
            "id": 1234,
            "workflow_id": 91,
            "name": gate.EXPECTED_WORKFLOW_NAME,
            "path": f"{WORKFLOW_PATH}@refs/tags/v1.2.3-release.4",
            "event": "push",
            "status": "completed",
            "conclusion": "success",
            "run_attempt": 1,
            "head_branch": "v1.2.3-release.4",
            "head_sha": GIT_SHA,
            "head_repository": {"full_name": REPOSITORY},
        }
        event = {
            "action": "completed",
            "repository": {"full_name": REPOSITORY},
            "workflow_run": run,
        }
        artifacts = {
            "total_count": 2,
            "artifacts": [
                {
                    "id": index,
                    "name": target,
                    "size_in_bytes": 1024 + index,
                    "digest": f"sha256:{str(index)[-1] * 64}",
                    "expired": False,
                    "workflow_run": {"id": 1234, "head_sha": GIT_SHA},
                }
                for index, target in enumerate(
                    gate.EXPECTED_ARTIFACTS, start=100
                )
            ],
        }
        return event, workflow, artifacts

    def validate(self, event: dict, workflow: dict, artifacts: dict) -> dict:
        return gate.validate_gate(
            event,
            workflow,
            artifacts,
            repository=REPOSITORY,
            expected_workflow_path=WORKFLOW_PATH,
        )

    def test_accepts_exact_first_attempt_candidate_and_artifacts(self) -> None:
        event, workflow, artifacts = self.fixture()
        artifacts["artifacts"].append(
            {"id": 999, "name": "unrelated-ci-diagnostics"}
        )
        artifacts["total_count"] = 3

        receipt = self.validate(event, workflow, artifacts)

        self.assertEqual(1234, receipt["candidateRunId"])
        self.assertEqual("v1.2.3-release.4", receipt["tag"])
        self.assertEqual(GIT_SHA, receipt["gitSha"])
        self.assertEqual(
            sorted(gate.EXPECTED_ARTIFACTS),
            [artifact["name"] for artifact in receipt["artifacts"]],
        )

    def test_rejects_wrong_or_replayed_workflow_identity(self) -> None:
        mutations = {
            "event repository": lambda event, workflow, artifacts: event[
                "repository"
            ].update(full_name="attacker/fork"),
            "head repository": lambda event, workflow, artifacts: event[
                "workflow_run"
            ]["head_repository"].update(full_name="attacker/fork"),
            "workflow id": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(workflow_id=92),
            "workflow name": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(name="Lookalike"),
            "workflow path": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(path=".github/workflows/lookalike.yml"),
            "inactive workflow": lambda event, workflow, artifacts: workflow.update(
                state="disabled_manually"
            ),
            "wrong event": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(event="workflow_dispatch"),
            "not completed": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(status="in_progress"),
            "failed": lambda event, workflow, artifacts: event["workflow_run"].update(
                conclusion="failure"
            ),
            "rerun": lambda event, workflow, artifacts: event["workflow_run"].update(
                run_attempt=2
            ),
            "unsafe tag": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(head_branch="release/latest"),
            "short sha": lambda event, workflow, artifacts: event[
                "workflow_run"
            ].update(head_sha="abc123"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                event, workflow, artifacts = copy.deepcopy(self.fixture())
                mutate(event, workflow, artifacts)
                with self.assertRaises(ValueError):
                    self.validate(event, workflow, artifacts)

    def test_rejects_incomplete_or_unsafe_artifact_inventory(self) -> None:
        mutations = {
            "missing": lambda artifacts: artifacts["artifacts"].pop(),
            "wrong total": lambda artifacts: artifacts.update(total_count=3),
            "unexpected": lambda artifacts: artifacts["artifacts"][0].update(
                name="firmware-other"
            ),
            "duplicate": lambda artifacts: artifacts["artifacts"][0].update(
                name=artifacts["artifacts"][1]["name"]
            ),
            "expired": lambda artifacts: artifacts["artifacts"][0].update(
                expired=True
            ),
            "oversized": lambda artifacts: artifacts["artifacts"][0].update(
                size_in_bytes=gate.MAX_ARTIFACT_BYTES + 1
            ),
            "bad digest": lambda artifacts: artifacts["artifacts"][0].update(
                digest="sha256:abc"
            ),
            "wrong run": lambda artifacts: artifacts["artifacts"][0][
                "workflow_run"
            ].update(id=99),
            "wrong sha": lambda artifacts: artifacts["artifacts"][0][
                "workflow_run"
            ].update(head_sha="f" * 40),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                event, workflow, artifacts = copy.deepcopy(self.fixture())
                mutate(artifacts)
                with self.assertRaises(ValueError):
                    self.validate(event, workflow, artifacts)


if __name__ == "__main__":
    unittest.main()
