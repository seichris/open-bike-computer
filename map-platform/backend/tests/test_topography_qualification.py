import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from map_platform.topography_cli import main
from map_platform.topography_qualification import load_qualification_registry, may_fallback, qualification_summary

ROOT = Path(__file__).resolve().parents[3]


class QualificationTests(unittest.TestCase):
    def test_registry_preserves_source_identity_and_separates_access_obligations(self):
        registry = load_qualification_registry(ROOT)
        sources = {s["id"]: s for s in registry["sources"]}
        self.assertIn("copernicus-glo90-2021", sources)
        self.assertNotIn("copernicus-glo90-public-2021", sources)
        self.assertEqual(sources["aw3d30-per-tile"]["accessRequirement"], "registered-and-commercial-notification")
        self.assertIsNone(sources["usgs-3dep-per-project"]["nativeVerticalDatum"])
        summary = qualification_summary(registry)
        self.assertFalse(summary["generationEnabled"])
        self.assertFalse(summary["mainlandChina"]["publicationEnabled"])
        self.assertTrue(all(not s["productionEligible"] and s["missingEvidence"] for s in summary["sources"]))

    def test_cannot_turn_research_into_approval_or_a_cyclic_fallback(self):
        registry = load_qualification_registry(ROOT)
        del registry["registrySha256"]
        mutations = [
            lambda d: d["sources"][0].update(productionApproved=True),
            lambda d: d["sources"][1].update(fallbackIds=[d["sources"][0]["id"]]),
            lambda d: d["sources"][0].update(fallbackIds=["does-not-exist"]),
            lambda d: d["sources"][0]["evidenceSha256"].update(license="approved"),
            lambda d: d["sources"][0].update(extra="untrusted"),
            lambda d: d["sources"].append(copy.deepcopy(d["sources"][0])),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "map-platform/config/topography-qualification-v1.json"
            path.parent.mkdir(parents=True)
            for mutate in mutations:
                data = copy.deepcopy(registry)
                mutate(data)
                path.write_text(json.dumps(data))
                with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                    load_qualification_registry(root)

    def test_only_declared_quality_or_coverage_reasons_allow_fallback(self):
        for reason in ("outside-coverage", "declared-void", "quality-rejected"):
            self.assertTrue(may_fallback(reason))
        for reason in ("timeout", "401", "403", "rate-limit", "corrupt-raster", "checksum-mismatch", "missing-transform", "unknown"):
            self.assertFalse(may_fallback(reason))

    def test_sources_cli_does_not_contact_any_provider(self):
        with patch("map_platform.topography_cli.ElevationCache", side_effect=AssertionError("no cache/network")):
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(main(["--repo-root", str(ROOT), "--cache", "/unused", "sources"]), 0)
            self.assertEqual(len(json.loads(output.getvalue())["sources"]), 16)
