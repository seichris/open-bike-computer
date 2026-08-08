#!/usr/bin/env python3
"""Print canonical target-3 and legacy source-scope metrics for a request fixture."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from map_platform.building_scope import (
    legacy_building_scope_diagnostics,
    plan_building_scope,
)
from map_platform.geometry import normalize_geometry
from map_platform.models import Bounds, JobStatus, MapJob, SourceRegion


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    job = MapJob(
        job_id="scope-benchmark",
        status=JobStatus.QUEUED,
        request={"target": {"rendererFormatVersion": 3}},
        geometry=normalize_geometry(fixture["request"]),
        source_region=SourceRegion(
            id="benchmark",
            provider="geofabrik",
            name="Benchmark region",
            url="https://download.geofabrik.de/benchmark.osm.pbf",
            bounds=Bounds(120, 20, 125, 35),
        ),
    )
    plan = plan_building_scope(
        job,
        calibration_cell_size_meters=8192,
        calibration_halo_cells=1,
        calibration_minimum_samples=3,
    )
    print(json.dumps({
        "scopePlanSha256": plan.sha256,
        "selectedAreaPolicy": plan.summary(),
        "legacyCellEnvelopePolicy": legacy_building_scope_diagnostics(
            job,
            calibration_cell_size_meters=8192,
            calibration_halo_cells=1,
        ),
    }, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
