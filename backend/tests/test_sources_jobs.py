import tempfile
import unittest
from pathlib import Path

from map_platform.jobs import JobStore, MapJobService
from map_platform.models import Bounds, SourceRegion
from map_platform.sources import SourceIndex, SourceResolutionError


class SourceAndJobTests(unittest.TestCase):
    def setUp(self):
        self.singapore = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="backend/data/source-pbf/sg.osm.pbf",
        )
        self.germany = SourceRegion(
            id="de",
            provider="test",
            name="Germany",
            url="https://example.invalid/de.osm.pbf",
            bounds=Bounds(5.5, 47.0, 15.5, 55.2),
            local_path="backend/data/source-pbf/de.osm.pbf",
        )

    def test_resolves_smallest_containing_source(self):
        index = SourceIndex([self.germany, self.singapore])

        source = index.resolve_for_bounds(Bounds(103.75, 1.24, 103.93, 1.37))

        self.assertEqual(source.id, "sg")

    def test_rejects_uncovered_bounds(self):
        index = SourceIndex([self.singapore])

        with self.assertRaises(SourceResolutionError):
            index.resolve_for_bounds(Bounds(-122.6, 37.6, -122.3, 37.9))

    def test_create_job_persists_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Singapore central",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            loaded = service.get_job(job.job_id)
            self.assertEqual(loaded.status.value, "queued")
            self.assertEqual(loaded.source_region.id, "sg")
            self.assertEqual(loaded.request["displayName"], "Singapore central")


if __name__ == "__main__":
    unittest.main()

