#!/usr/bin/env python3
"""Prepare a pinned source snapshot before a map job needs it.

This intentionally uses the same source-index and calibration builders as the
request path. The result is ready only when both existing sealed manifests pass
their full validators. Run it on a host with measured scratch capacity and a
shared cache root; it does not download a source or select a new release.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from build_building_calibration import scan_full_pbf
from build_building_source_index import scan_source
from building_calibration_cache import CalibrationCache, CalibrationIdentity
from building_pipeline import BUILDING_PROFILE_VERSION, load_rules
from building_source_index import BuildingSourceIndex, file_sha256


def precompute(source_pbf: Path, source_sha256: str, rules_path: Path, cache_root: Path) -> dict:
    if file_sha256(source_pbf) != source_sha256:
        raise ValueError("source PBF does not match its pinned SHA-256")
    rules, rules_sha256 = load_rules(rules_path)
    index = BuildingSourceIndex(cache_root, source_sha256)

    def build_index(temporary: Path) -> None:
        scan_source(source_pbf, temporary)
        if file_sha256(source_pbf) != source_sha256:
            raise ValueError("source PBF changed during indexing")

    index.build_with_scanner(build_index)
    identity = CalibrationIdentity(
        source_snapshot_sha256=source_sha256,
        rules_sha256=rules_sha256,
        building_profile_version=BUILDING_PROFILE_VERSION,
        cell_size_meters=rules.cell_size_meters,
        halo_cells=rules.halo_cells,
        minimum_samples=rules.minimum_samples,
    )
    calibration = CalibrationCache(cache_root, identity)

    def build_calibration():
        result = scan_full_pbf(source_pbf, rules)
        if file_sha256(source_pbf) != source_sha256:
            raise ValueError("source PBF changed during calibration")
        return result

    calibration.materialize_complete_with_snapshot_builder(build_calibration)
    if file_sha256(source_pbf) != source_sha256:
        raise ValueError("source PBF changed before readiness validation")
    source_manifest = index.validate()
    calibration_manifest = calibration.validate_complete_generation()
    return {
        "schemaVersion": 1,
        "sourceSnapshotSha256": source_sha256,
        "rulesSha256": rules_sha256,
        "sourceIndexKey": index.index_key,
        "sourceIndexManifestSha256": source_manifest["manifestSha256"],
        "calibrationKey": identity.key,
        "calibrationManifestSha256": calibration_manifest["manifestSha256"],
        "calibrationCellCount": len(calibration_manifest["cells"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-pbf", required=True, type=Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--cache-root", required=True, type=Path)
    parser.add_argument("--publish-contabo", action="store_true",
                        help="publish verified source preparation to the configured Contabo bucket")
    args = parser.parse_args()
    result = precompute(args.source_pbf, args.source_sha256, args.rules, args.cache_root)
    if args.publish_contabo:
        from map_platform.preparation_objects import create_preparation_store_from_environment
        from map_platform.prepared_source_catalog import PreparedSourceCatalog

        remote = create_preparation_store_from_environment()
        if remote is None:
            raise ValueError("Contabo preparation storage is not configured")
        catalog = PreparedSourceCatalog(remote)
        catalog.publish_index(args.cache_root, args.source_sha256)
        rules, _ = load_rules(args.rules)
        identity = CalibrationIdentity(
            source_snapshot_sha256=args.source_sha256,
            rules_sha256=result["rulesSha256"],
            building_profile_version=BUILDING_PROFILE_VERSION,
            cell_size_meters=rules.cell_size_meters,
            halo_cells=rules.halo_cells,
            minimum_samples=rules.minimum_samples,
        )
        catalog.publish_calibration(args.cache_root, {
            **identity.document(), "calibrationKey": identity.key,
        })
        result["contaboPublished"] = True
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
