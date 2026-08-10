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
        self.assertIn("    name: CI Gate\n", general_ci)
        self.assertIn("uses: ./.github/workflows/map-platform-ci.yml", general_ci)
        self.assertIn("  workflow_call:\n", map_ci)
        self.assertNotIn("  pull_request:\n", map_ci)
        self.assertNotIn("  push:\n", map_ci)

    def test_image_promotion_watches_and_dispatches_dedicated_ci(self) -> None:
        image_workflow = workflow_source("map-platform-image.yml")

        self.assertIn('      - ".github/workflows/map-platform-ci.yml"', image_workflow)
        self.assertNotIn('      - ".github/workflows/ci.yml"', image_workflow)
        self.assertIn(
            "python3 map-platform/deploy/export_pending_compose.py",
            image_workflow,
        )
        self.assertIn("gh workflow run ci.yml", image_workflow)
        self.assertIn("-f scope=map", image_workflow)
        self.assertNotIn("gh workflow run map-platform-ci.yml", image_workflow)

    def test_image_publishing_is_automatic_only_on_main(self) -> None:
        image_workflow = workflow_source("map-platform-image.yml")

        self.assertIn("  push:\n    branches:\n      - main\n", image_workflow)


if __name__ == "__main__":
    unittest.main()
