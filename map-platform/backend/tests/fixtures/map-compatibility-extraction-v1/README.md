# Worker extraction inputs, contract v1 corpus

Real renderer blocks for the `*-osm-*` maps in
[`map-compatibility-v1`](../map-compatibility-v1/README.md). Each directory is
the `VECTMAP/<mapId>/` tree that the production worker extracted on 2026-10-26,
right before packaging. `tests/map_compatibility_fixture.py` packages, signs and
promotes them with the real producer code.

| Directory | OSM fixture | Request | Content |
| --- | --- | --- | --- |
| `singapore-buildings-t3` | `tools/OSM_Extract/tests/fixtures/singapore_r14346906.osm` | target 3, bbox `[103.8644, 1.3093, 103.8655, 1.31]` | 5 building parts with level-derived heights, an empty label asset |
| `singapore-buildings-t5` | same | target 5 with `map-pois`, same bbox | the same buildings with an empty POI section |
| `golden-gate-labels-t3` | `map-platform/backend/tests/fixtures/route_elevation_structures.osm` | target 3, bbox `[-122.48, 37.808, -122.476, 37.829]` | 2 blocks of roads and one street label with its 13-glyph font |

The fixtures have no POI tags, so no frozen map has real POI records.

How the blocks were produced:

1. The map-platform backend image ran offline (`--network none`) with the
   production Compose worker settings (`shadow` building scope, 4 block
   workers, shard mode disabled) and English labels.
2. `osmium sort` converted each fixture into a local source region pinned by
   its path and checksum.
3. `MapWorker.run_next()` ran `MapBuildPipeline.build()`, which runs
   `osmium extract`, `pbf_to_geojson.sh` and `extract_features.py` for the
   requested renderer target.
4. The capture stopped before `_package_map` and copied the tree. Repeated runs
   and other map IDs gave byte-identical blocks.

Only the generator reads these files. Like the corpus, they are frozen: never
regenerate or edit them.
