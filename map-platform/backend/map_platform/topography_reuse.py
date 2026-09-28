"""Verified pre-render inputs for exact reuse of a topographic map pair."""

from __future__ import annotations

import hashlib
import platform
from typing import Any

from .topography_artifacts import TOPOGRAPHY_PROFILE_VERSION
from .topography_grid import contour_grid, processing_region, region_resolution
from .topography_pipeline import CONTOUR_ALGORITHM, MAX_GRID_PIXELS, canonical_bytes
from .topography_sources import TopographySourcePolicy, plan_elevation

def topography_input_identity(policy: TopographySourcePolicy, cache, bounds: list[float]) -> dict[str, Any]:
    """Stage and rehash every selected DEM tile without sampling contours."""
    import contourpy
    import numpy as np
    import rasterio

    region = processing_region(bounds)
    indexes = {source.id: cache.index(source) for source in policy.sources}
    resolution = region_resolution(policy, indexes, region)
    grid = contour_grid(bounds, resolution, MAX_GRID_PIXELS)
    plan = plan_elevation(policy, indexes, list(grid.acquisition_bounds))
    if not plan["coverageComplete"]:
        raise ValueError("topography halo has uncovered geocells")
    if len(plan["tiles"]) > 256:
        raise ValueError("topography input exceeds tile acquisition limit")
    sources = {source.id: source for source in policy.sources}
    receipts = [cache.stage(sources[tile["sourceId"]], tuple(tile["cell"])) for tile in plan["tiles"]]
    receipts.sort(key=lambda r: (-sources[r["sourceId"]].priority, r["sourceId"], r["cell"]))
    body = {
        "schemaVersion": 1,
        "sourcePolicySha256": policy.sha256,
        "processingGrid": grid.evidence(),
        "gridSize": [grid.width, grid.height],
        "qualityMode": plan["qualityMode"],
        "inputs": receipts,
        "algorithm": CONTOUR_ALGORITHM,
        "runtime": {
            "rasterio": rasterio.__version__, "gdal": rasterio.__gdal_version__,
            "proj": rasterio.__proj_version__, "contourpy": contourpy.__version__,
            "numpy": np.__version__, "machine": platform.machine(),
            "system": platform.system(), "python": platform.python_version(),
        },
        "topographyProfileVersion": TOPOGRAPHY_PROFILE_VERSION,
    }
    return {**body, "identitySha256": hashlib.sha256(canonical_bytes(body)).hexdigest()}


def sample_matches_input_identity(sample: dict[str, Any], identity: dict[str, Any]) -> bool:
    return all(sample.get(field) == identity.get(field) for field in (
        "sourcePolicySha256", "processingGrid", "gridSize", "qualityMode",
        "inputs", "algorithm", "runtime",
    ))


def valid_input_identity(identity: Any) -> bool:
    if not isinstance(identity, dict) or set(identity) != {
        "schemaVersion", "sourcePolicySha256", "processingGrid", "gridSize",
        "qualityMode", "inputs", "algorithm", "runtime",
        "topographyProfileVersion", "identitySha256",
    }:
        return False
    digest = identity.get("identitySha256")
    if not isinstance(digest, str) or len(digest) != 64:
        return False
    body = {key: value for key, value in identity.items() if key != "identitySha256"}
    try:
        return hashlib.sha256(canonical_bytes(body)).hexdigest() == digest
    except (TypeError, ValueError):
        return False
