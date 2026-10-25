"""Keep active-map regeneration on the shared ZIP/signed-stream bounds path."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
MANAGER = ROOT / "ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift"
SETTINGS = ROOT / "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"


class MapRegenerationContractTests(unittest.TestCase):
    def test_regeneration_uses_normalized_manifest_bounds(self):
        source = MANAGER.read_text()
        body = source.split("func regenerateActiveMap(", 1)[1].split(
            "private func installBoundsMap(", 1)[0]
        self.assertIn("OfflineMapPackPreviewReader.manifest(for: packURL)", body)
        self.assertIn("manifest.previewBounds", body)
        self.assertNotIn("manifest.bounds", body)
        self.assertIn("preserveContours:", body)
        self.assertIn("OfflineMapPoiRequestPolicy.regenerationRequirement(", body)

    def test_target5_is_negotiated_before_every_submission(self):
        source = MANAGER.read_text()
        # Device capability alone never upgrades a request to target 5.
        self.assertNotIn(".withMapPois(", source)
        for start, end in (("private func installBoundsMap(", "func resumePendingMapJobIfNeeded("),
                           ("private func createJobAndDownload(", "private func startMapJobTask(")):
            body = source.split(start, 1)[1].split(end, 1)[0]
            negotiated = body.index("negotiatedGenerationRequest(")
            self.assertLess(negotiated, body.index("createJob("), start)

    def test_poi_action_is_distinct_from_label_regeneration(self):
        source = SETTINGS.read_text()
        poi = source.split('Section(header: Text("Points of Interest")', 1)[1].split(
            'Section(header: Text("Map Rendering")', 1)[0]
        self.assertIn("purpose: .pointsOfInterest", poi)
        labels = source.split("labelLanguagesNeedUpdate\n", 1)[1].split(
            'Section(header: Text("Line Thickness"))', 1)[0]
        self.assertIn("offlineMapManager.regenerateActiveMap(", labels)
        self.assertNotIn(".pointsOfInterest", labels)


if __name__ == "__main__":
    unittest.main()
