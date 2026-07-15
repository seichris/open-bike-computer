from __future__ import annotations

import json
from pathlib import Path
from typing import Protocol

from .geometry import bbox_area_km2
from .models import Bounds, SourceRegion


class SourceResolutionError(ValueError):
    """Raised when no configured OSM source can cover a requested area."""


class SourceProvider(Protocol):
    def resolve_for_bounds(self, bounds: Bounds) -> SourceRegion:
        ...

    def source_regions(self) -> list[SourceRegion]:
        ...


class SourceIndex:
    def __init__(self, regions: list[SourceRegion], fallback_provider: SourceProvider | None = None):
        if not regions:
            raise SourceResolutionError("source index must contain at least one region")
        self.regions = regions
        self.fallback_provider = fallback_provider

    @classmethod
    def from_json(cls, path: str | Path, fallback_provider: SourceProvider | None = None) -> "SourceIndex":
        data = json.loads(Path(path).read_text())
        return cls([SourceRegion.from_dict(region) for region in data["regions"]], fallback_provider=fallback_provider)

    def to_dict(self, *, include_dynamic: bool = False) -> dict[str, object]:
        return {"regions": [region.to_dict() for region in self.all_regions(include_dynamic=include_dynamic)]}

    def all_regions(self, *, include_dynamic: bool = False) -> list[SourceRegion]:
        regions = list(self.regions)
        if include_dynamic and self.fallback_provider is not None:
            seen = {region.id for region in regions}
            regions.extend(region for region in self.fallback_provider.source_regions() if region.id not in seen)
        return regions

    def resolve_for_bounds(self, bounds: Bounds) -> SourceRegion:
        containing = [region for region in self.regions if contains_bounds(region.bounds, bounds)]
        if containing:
            return sorted(containing, key=lambda region: bbox_area_km2(region.bounds))[0]
        intersecting = [region for region in self.regions if intersects_bounds(region.bounds, bounds)]
        if self.fallback_provider is not None:
            try:
                return self.fallback_provider.resolve_for_bounds(bounds)
            except SourceResolutionError:
                pass
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
