from __future__ import annotations

import json
from pathlib import Path

from .geometry import bbox_area_km2
from .models import Bounds, SourceRegion


class SourceResolutionError(ValueError):
    """Raised when no configured OSM source can cover a requested area."""


class SourceIndex:
    def __init__(self, regions: list[SourceRegion]):
        if not regions:
            raise SourceResolutionError("source index must contain at least one region")
        self.regions = regions

    @classmethod
    def from_json(cls, path: str | Path) -> "SourceIndex":
        data = json.loads(Path(path).read_text())
        return cls([SourceRegion.from_dict(region) for region in data["regions"]])

    def to_dict(self) -> dict[str, object]:
        return {"regions": [region.to_dict() for region in self.regions]}

    def resolve_for_bounds(self, bounds: Bounds) -> SourceRegion:
        containing = [region for region in self.regions if contains_bounds(region.bounds, bounds)]
        if containing:
            return sorted(containing, key=lambda region: bbox_area_km2(region.bounds))[0]
        intersecting = [region for region in self.regions if intersects_bounds(region.bounds, bounds)]
        if len(intersecting) > 1:
            raise SourceResolutionError(
                "requested area crosses configured source regions; add a parent source or merge support"
            )
        raise SourceResolutionError("no configured source region covers the requested area")


def contains_bounds(container: Bounds, child: Bounds) -> bool:
    return (
        container.min_lon <= child.min_lon
        and container.min_lat <= child.min_lat
        and container.max_lon >= child.max_lon
        and container.max_lat >= child.max_lat
    )


def intersects_bounds(a: Bounds, b: Bounds) -> bool:
    return not (
        a.max_lon <= b.min_lon
        or a.min_lon >= b.max_lon
        or a.max_lat <= b.min_lat
        or a.min_lat >= b.max_lat
    )

