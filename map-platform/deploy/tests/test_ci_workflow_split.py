from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW_ROOT = REPO_ROOT / ".github" / "workflows"


def workflow_source(filename: str) -> str:
    return (WORKFLOW_ROOT / filename).read_text(encoding="utf-8")


class CIWorkflowSplitTests(unittest.TestCase):
    def test_map_jobs_live_only_in_dedicated_workflow(self) -> None:
        general_ci = workflow_source("ci.yml")
        map_ci = workflow_source("map-platform-ci.yml")

        self.assertNotIn("  backend:\n", general_ci)
        self.assertNotIn("  osm:\n", general_ci)
        self.assertIn("  backend:\n", map_ci)
        self.assertIn("  osm:\n", map_ci)
        self.assertIn("    name: Map Backend\n", map_ci)
        self.assertIn("    name: OSM Pipeline\n", map_ci)

    def test_pull_requests_route_map_jobs_through_the_aggregate_gate(self) -> None:
        general_ci = workflow_source("ci.yml")
        map_ci = workflow_source("map-platform-ci.yml")

        self.assertIn("  pull_request:\n", general_ci)
        self.assertIn("  gate:\n", general_ci)
        self.assertIn("&& 'CI Gate' ||", general_ci)
        self.assertIn("uses: ./.github/workflows/map-platform-ci.yml", general_ci)
        self.assertIn("  workflow_call:\n", map_ci)
        self.assertNotIn("  pull_request:\n", map_ci)
        self.assertNotIn("  push:\n", map_ci)

    def test_reusable_map_jobs_follow_inputs_and_manual_defaults_run_both(self) -> None:
        map_ci = workflow_source("map-platform-ci.yml")

        self.assertIn("    if: inputs.run_backend\n", map_ci)
        self.assertIn("    if: inputs.run_osm\n", map_ci)
        self.assertNotIn("github.event_name != 'workflow_call'", map_ci)
        self.assertEqual(map_ci.count("        default: true\n"), 2)

    def test_image_promotion_watches_and_dispatches_dedicated_ci(self) -> None:
        image_workflow = workflow_source("map-platform-image.yml")

        self.assertIn('      - ".github/workflows/map-platform-ci.yml"', image_workflow)
        self.assertNotIn('      - ".github/workflows/ci.yml"', image_workflow)
        self.assertIn(
            "python3 map-platform/deploy/export_pending_compose.py",
            image_workflow,
        )
        self.assertEqual(2, image_workflow.count("gh workflow run ci.yml"))
        self.assertEqual(2, image_workflow.count("-f scope=map"))
        self.assertNotIn("gh workflow run map-platform-ci.yml", image_workflow)

    def test_production_and_development_have_independent_promotion_locks(self) -> None:
        general_ci = workflow_source("ci.yml")
        image_workflow = workflow_source("map-platform-image.yml")
        map_ci = workflow_source("map-platform-ci.yml")
        production_job, development_job = image_workflow.split(
            "  propose-development:\n", 1
        )

        self.assertIn("  propose-production:\n", image_workflow)
        self.assertIn("  propose-development:\n", image_workflow)
        self.assertIn("deploy/map-platform-production", image_workflow)
        self.assertIn("deploy/map-platform-development", image_workflow)
        self.assertIn("map-platform/deploy/compose.yaml", image_workflow)
        self.assertIn("map-platform/deploy/compose.development.yaml", image_workflow)
        self.assertIn("--worker-digest \"$IMAGE_DIGEST\"", image_workflow)
        self.assertIn(
            "updates only the digest-pinned development Compose",
            image_workflow,
        )
        self.assertNotIn(
            "map-platform/deploy/compose.development.yaml",
            production_job,
        )
        self.assertNotIn(
            "map-platform/deploy/compose.yaml",
            development_job,
        )
        self.assertIn("deploy/map-platform-development", general_ci)
        self.assertIn("deployment_lock=map-platform/deploy/compose.yaml", general_ci)
        self.assertIn(
            "deployment_lock=map-platform/deploy/compose.development.yaml",
            general_ci,
        )
        self.assertIn("../deploy/compose.development.yaml", map_ci)

    def test_image_publishing_is_automatic_only_on_main(self) -> None:
        image_workflow = workflow_source("map-platform-image.yml")

        self.assertIn("  push:\n    branches:\n      - main\n", image_workflow)

    def test_authentication_compatibility_is_candidate_only(self) -> None:
        workflow = workflow_source("map-platform-image.yml")
        excluded = "inputs.release_profile != 'production-auth-compatibility'"
        self.assertEqual(workflow.count(excluded), 3)
        self.assertIn("'-auth-compat' || ''", workflow)
        self.assertIn("'runtime' || ''", workflow)
        self.assertIn('test "$SOURCE_REF" = "refs/heads/$DEFAULT_BRANCH"', workflow)
        self.assertIn("--target validation", workflow)
        for job in ("propose-production", "propose-development"):
            section = workflow.split(f"  {job}:\n", 1)[1].split("    runs-on:", 1)[0]
            self.assertIn(excluded, section)


if __name__ == "__main__":
    unittest.main()
