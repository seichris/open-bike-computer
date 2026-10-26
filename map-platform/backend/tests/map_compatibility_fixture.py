"""Frozen durable-map corpus for compatibility contract v1.

Every profile in ``map-platform/config/map-compatibility-contract-v1.json`` is
built here with the real producer code:

* development maps run ``MapBuildPipeline._package_map`` (renderer packaging,
  POI index, contour compilation and pair assembly, iPhone companion, manifest,
  contract marker, BMAP signature) and ``publication_payload``;
* production maps run ``promote_catalog_map`` on the development ZIP, exactly
  as the production backend re-signs a promoted map. A rotated production key
  and a changed worker identity repeat that promotion for one map.

Only the FMB/FMA block inputs, the DEM sample and its notice come from small
test helpers, as in ``contour_companion_fixture.py``. The fixture signers use
public test scalars that the trust tooling refuses for production.

The committed corpus is frozen: readers must keep reading those exact bytes.
``python -m tests.map_compatibility_fixture --output <new directory>`` writes a
new corpus for a later contract revision and refuses to overwrite one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from copy import deepcopy
from dataclasses import dataclass, field, replace
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    TOPOGRAPHY_COMPANION_FORMAT,
    ZIP_STORED_FORMAT,
    ArtifactRecord,
    FileSystemArtifactStore,
)
from map_platform.catalog import publication_payload
from map_platform.catalog_promotion import promote_catalog_map
from map_platform.map_compatibility import (
    MapCompatibilityContract,
    load_map_compatibility_contract,
)
from map_platform.map_signing import P256MapArtifactSigner
from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from tests.map_label_fixtures import fmb6_with_pois, one_building_fmb4, one_label_fma1


CORPUS = Path(__file__).parent / "fixtures" / "map-compatibility-v1"
REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE_NOTICE = b"Durable map compatibility fixture elevation notice\n"
# Block (0, 0) spans Web Mercator metres [0, 4096): one block, one Nearby
# coverage block and one short contour keep every artifact small.
BOUNDS = Bounds(0.001, 0.001, 0.03, 0.03)
CREATED_AT = "2026-10-26T00:00:00Z"
DEVELOPMENT_PRODUCER = ("4" * 64, "sha256:" + "5" * 64)
PRODUCTION_PRODUCER = ("1" * 64, "sha256:" + "2" * 64)
UPDATED_PRODUCTION_PRODUCER = ("3" * 64, "sha256:" + "6" * 64)
SIGNER_SCALARS = {
    "map-compat-fixture-dev-1": 0x4D430001,
    "map-compat-fixture-prod-1": 0x4D430002,
    "map-compat-fixture-prod-2": 0x4D430003,
}
# Variant -> (signer, producer). Rotation and the worker update re-promote the
# same development content, so their content receipt is unchanged.
PRODUCTION_VARIANTS = {
    "production": ("map-compat-fixture-prod-1", PRODUCTION_PRODUCER),
    "production-rotated-key": ("map-compat-fixture-prod-2", PRODUCTION_PRODUCER),
    "production-updated-worker": (
        "map-compat-fixture-prod-1",
        UPDATED_PRODUCTION_PRODUCER,
    ),
}
# Profile -> (map ID, production variants). Every production-eligible profile
# gets a production promotion; the plain 3D map also covers key rotation and a
# worker update.
PROFILES = {
    "buildings-3d-v1": (
        "compat-v1-buildings",
        ("production", "production-rotated-key", "production-updated-worker"),
    ),
    "topographic-contours-v1": ("compat-v1-contours", ("production",)),
    "map-pois-v1": ("compat-v1-pois", ()),
    "map-pois-contours-v1": ("compat-v1-pois-contours", ()),
}


def fixture_signer(key_id: str) -> P256MapArtifactSigner:
    return P256MapArtifactSigner(
        key_id, ec.derive_private_key(SIGNER_SCALARS[key_id], ec.SECP256R1())
    )


def public_key_x963(signer: P256MapArtifactSigner) -> bytes:
    return signer._private_key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )


def fixture_contract() -> MapCompatibilityContract:
    """The checked-in contract with the fixture signers registered."""
    return replace(
        load_map_compatibility_contract(),
        signers=frozenset(
            (
                "development" if key_id.startswith("map-compat-fixture-dev")
                else "production",
                key_id,
                fixture_signer(key_id).public_key_sha256,
            )
            for key_id in SIGNER_SCALARS
        ),
    )


def contour_sample() -> dict[str, Any]:
    return {
        "kind": "bicino-contour-evidence-v1", "workingCrs": "EPSG:3857",
        "verticalDatum": "EPSG:3855", "minorIntervalM": 20, "indexIntervalM": 100,
        "boundsE7": [10000, 10000, 300000, 300000], "noDataMillionths": 0,
        "qualityMode": "standard-20m-v1", "surfaceModel": "dsm",
        "horizontalCrs": "EPSG:4326", "sourcePixels": {"fixture": 1},
        "gridSize": [2, 2],
        "sources": [{
            "sourceId": "fixture", "datasetRelease": "fixture-release",
            "termsUrl": "https://example.invalid/terms",
            "attributionUrl": "https://example.invalid/attribution",
            "accessReviewedAt": "2026-10-26",
        }],
        "inputs": [{"sourceId": "fixture", "cell": [0, 0], "sha256": "b" * 64}],
        "sourcePolicySha256": "a" * 64,
        "contours": [{
            "elevationM": 100, "index": True,
            "pointsMm": [[1_000_000, 2_000_000], [1_120_000, 2_000_000]],
        }],
    }


def profile_job(map_id: str, format_version: int, features: tuple[str, ...]) -> MapJob:
    target: dict[str, Any] = {
        "renderer": "esp32-fmb",
        "rendererFormatVersion": format_version,
        "firmwareVersion": "0.3.4",
    }
    if format_version == 5:
        target["requestedFeatures"] = list(features)
    job = MapJob(
        job_id=f"fixture-{map_id}",
        status=JobStatus.QUEUED,
        request={
            "target": target,
            "labels": {"profileVersion": 1, "preferredLanguages": ["en"],
                       "internationalFallback": "en"},
        },
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX, bounds=BOUNDS,
            area_km2=10, vertex_count=4,
        ),
        source_region=SourceRegion(
            id="fixture", provider="test", name="Compatibility fixture",
            url="https://example.invalid/fixture.osm.pbf",
            bounds=Bounds(-1, -1, 1, 1), checksum="3" * 64,
        ),
        created_at=CREATED_AT,
        updated_at=CREATED_AT,
    )
    job.map_id = map_id
    return job


class CatalogArtifactStore(FileSystemArtifactStore):
    """Filesystem storage standing in for the shared R2 delivery buckets."""

    catalog_delivery_backed = True


@dataclass
class PromotionCatalog:
    """Records the production publication the real promotion code finalizes."""

    channel: str = "production"
    base_url: str = "https://maps-share.invalid"
    timeout_seconds: float = 10
    finalized: list[dict[str, Any]] = field(default_factory=list)

    def renew_promotion_lease(self, entry_id, *, lease_id, artifact):
        del artifact
        return {"mapEntryId": entry_id, "leaseId": lease_id,
                "leaseExpiresAt": "2026-10-26T01:00:00Z"}

    def finalize_promotion(self, entry_id, payload, *, lease_id):
        del lease_id
        self.finalized.append(deepcopy(payload))
        return {"mapEntryId": entry_id, "state": "finalized"}


@dataclass(frozen=True)
class BuiltProfile:
    profile: str
    job: MapJob
    publication: dict[str, Any]
    artifact_root: Path
    productions: dict[str, tuple[dict[str, Any], dict[str, Any]]]

    def artifact(self, artifact_format: str) -> ArtifactRecord:
        matches = [value for value in self.job.artifacts if value.format == artifact_format]
        if len(matches) != 1:
            raise AssertionError(f"expected one {artifact_format} artifact")
        return matches[0]

    def object_bytes(self, object_key: str) -> bytes:
        return (self.artifact_root / object_key).read_bytes()


def build_development_map(
    root: Path,
    profile_id: str,
    contract: MapCompatibilityContract,
) -> tuple[MapJob, Path]:
    map_id = PROFILES[profile_id][0]
    profile = next(value for value in contract.profiles if value.profile_id == profile_id)
    format_version = profile.renderer_format_version
    pack = root / "pack"
    block = pack / f"VECTMAP/{map_id}/+000+000/0_0.fmb"
    block.parent.mkdir(parents=True)
    block.write_bytes(fmb6_with_pois() if format_version == 5 else one_building_fmb4())
    font = pack / f"VECTMAP/{map_id}/assets/street-labels.fma"
    font.parent.mkdir()
    font.write_bytes(one_label_fma1())
    artifact_root = root / "artifacts"
    pipeline = MapBuildPipeline(
        PipelinePaths(REPO_ROOT, root / "work", root / "packs"),
        artifact_store=CatalogArtifactStore(artifact_root),
        map_signer=fixture_signer("map-compat-fixture-dev-1"),
        producer_build_sha256=DEVELOPMENT_PRODUCER[0],
        producer_image_digest=DEVELOPMENT_PRODUCER[1],
        deployment_channel="development",
        compatibility_contract=contract,
    )
    job = profile_job(map_id, format_version, profile.features)
    with patch("map_platform.pipeline.contour_sample", return_value=contour_sample()), \
            patch.object(MapBuildPipeline, "_topography_attribution", return_value=SOURCE_NOTICE):
        packaged = pipeline._package_map(
            job, pack, root / f"{map_id}.zip", validate_final_artifact=True,
        )
    if packaged.compatibility_contract != contract.contract:
        raise AssertionError(f"{profile_id} was not packaged as a durable map")
    job.status = JobStatus.READY
    job.artifacts = list(packaged.artifacts)
    job.compatibility_contract = packaged.compatibility_contract
    job.finished_at = CREATED_AT
    return job, artifact_root


def promote(
    built_job: MapJob,
    publication: dict[str, Any],
    artifact_root: Path,
    work_root: Path,
    variant: str,
    contract: MapCompatibilityContract,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Run the real production promotion of one development map."""
    signer_id, (producer_build, producer_image) = PRODUCTION_VARIANTS[variant]
    source = {value["format"]: value for value in publication["artifacts"]}
    local_objects = {
        "https://maps-share.invalid/v1/internal/promotions/downloads/zip":
            artifact_root / source[ZIP_STORED_FORMAT]["objectKey"],
    }
    grant: dict[str, Any] = {
        "state": "granted",
        "leaseId": "promotion_lease_v1_" + "f" * 32,
        "downloadURL": "https://maps-share.invalid/v1/internal/promotions/downloads/zip",
        "artifact": source[ZIP_STORED_FORMAT],
        "map": {
            key: publication[key]
            for key in (
                "mapEntryId", "contentReceipt", "originChannel", "canonicalName",
                "sourceRegionName", "bounds", "renderer", "rendererFormatVersion",
                "features", "attribution", "generatedAt",
            )
        } | {"mapId": publication["legacyMapId"]},
    }
    if TOPOGRAPHY_COMPANION_FORMAT in source:
        companion_url = "https://maps-share.invalid/v1/internal/promotions/downloads/btopo"
        local_objects[companion_url] = (
            artifact_root / source[TOPOGRAPHY_COMPANION_FORMAT]["objectKey"]
        )
        grant["companion"] = {
            "artifact": source[TOPOGRAPHY_COMPANION_FORMAT],
            "downloadURL": companion_url,
        }

    def download(url, destination, **_kwargs):
        shutil.copyfile(local_objects[url], destination)

    approved_policy = SimpleNamespace(
        sha256=contour_sample()["sourcePolicySha256"],
        sources=(SimpleNamespace(production_approved=True),),
    )
    catalog = PromotionCatalog()
    with patch("map_platform.catalog_promotion._download_exact_zip", side_effect=download), \
            patch.dict(os.environ, {"MAP_PLATFORM_S3_ENDPOINT_URL": "https://r2.invalid"}):
        result = promote_catalog_map(
            publication["mapEntryId"],
            catalog_client=catalog,
            artifact_store=CatalogArtifactStore(artifact_root),
            signer=fixture_signer(signer_id),
            producer_build_sha256=producer_build,
            producer_image_digest=producer_image,
            work_root=work_root,
            grant=grant,
            source_policy=approved_policy,
            compatibility_contract=contract,
        )
    if result.get("state") != "finalized" or len(catalog.finalized) != 1:
        raise AssertionError(f"{built_job.map_id} {variant} promotion did not finalize")
    return result, catalog.finalized[0]


def build_profile(root: Path, profile_id: str, contract: MapCompatibilityContract) -> BuiltProfile:
    job, artifact_root = build_development_map(root, profile_id, contract)
    publication = publication_payload(job, "development")
    productions = {
        variant: promote(job, publication, artifact_root, root / variant, variant, contract)
        for variant in PROFILES[profile_id][1]
    }
    return BuiltProfile(
        profile=profile_id,
        job=job,
        publication=publication,
        artifact_root=artifact_root,
        productions=productions,
    )


def write_corpus(output: Path, built: dict[str, BuiltProfile]) -> None:
    files: dict[str, bytes] = {}
    maps = []
    for profile_id, value in built.items():
        stream = value.artifact(BIKE_MAP_STREAM_FORMAT)
        development = {
            "deliveryTier": "development",
            "file": f"{profile_id}.development.bmap",
            "artifacts": [artifact.to_dict() for artifact in value.job.artifacts],
            "publication": value.publication,
        }
        files[development["file"]] = value.object_bytes(stream.object_key)
        companion_file = None
        if any(item.format == TOPOGRAPHY_COMPANION_FORMAT for item in value.job.artifacts):
            companion = value.artifact(TOPOGRAPHY_COMPANION_FORMAT)
            companion_file = f"{profile_id}.btopo"
            files[companion_file] = value.object_bytes(companion.object_key)
        productions = []
        for variant, (result, publication) in value.productions.items():
            production_file = f"{profile_id}.{variant}.bmap"
            files[production_file] = value.object_bytes(result["objectKey"])
            published_companion = [
                item for item in publication["artifacts"]
                if item["format"] == TOPOGRAPHY_COMPANION_FORMAT
            ]
            if published_companion and (
                companion_file is None
                or hashlib.sha256(files[companion_file]).hexdigest()
                != published_companion[0]["sha256"]
            ):
                raise AssertionError("promotion changed the companion bytes")
            productions.append({
                "variant": variant,
                "deliveryTier": "production",
                "file": production_file,
                "publication": publication,
            })
        maps.append({
            "profile": profile_id,
            "mapId": value.job.map_id,
            "jobId": value.job.job_id,
            "compatibilityContract": value.job.compatibility_contract,
            "contentReceipt": value.publication["contentReceipt"],
            "mapEntryId": value.publication["mapEntryId"],
            "renderer": value.publication["renderer"],
            "rendererFormatVersion": value.publication["rendererFormatVersion"],
            "features": value.publication["features"],
            "companionFile": companion_file,
            "development": development,
            "production": productions,
        })
    signers = []
    for key_id in sorted(SIGNER_SCALARS):
        signer = fixture_signer(key_id)
        signers.append({
            "keyId": key_id,
            "channel": "development" if "-dev-" in key_id else "production",
            "publicKeyX963Hex": public_key_x963(signer).hex(),
            "publicKeySha256": signer.public_key_sha256,
        })
    contract = load_map_compatibility_contract()
    corpus = {
        "schemaVersion": 1,
        "contract": contract.contract,
        "baselineId": contract.baseline_id,
        "generator": "map-platform/backend/tests/map_compatibility_fixture.py",
        "signers": signers,
        "maps": maps,
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())},
    }
    output.mkdir(parents=True)
    for name, data in files.items():
        (output / name).write_bytes(data)
    (output / "corpus.json").write_text(
        json.dumps(corpus, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output / "corpus.txt").write_text(corpus_index(corpus, files), encoding="ascii")


def corpus_index(corpus: dict[str, Any], files: dict[str, bytes]) -> str:
    """Line-oriented copy of the stream identities for the C++ host tests."""
    from map_platform.map_stream import FIXED_HEADER_BYTES, MapStreamHeader, manifest_receipt

    lines = [f"contract={corpus['contract']}"]
    for signer in corpus["signers"]:
        lines.append(f"signer={signer['keyId']} {signer['publicKeyX963Hex']}")
    for entry in corpus["maps"]:
        variants = [entry["development"], *entry["production"]]
        for variant in variants:
            data = files[variant["file"]]
            header = MapStreamHeader.decode(data[:FIXED_HEADER_BYTES])
            manifest = data[FIXED_HEADER_BYTES:FIXED_HEADER_BYTES + header.manifest_bytes]
            stream = next(
                item for item in variant["publication"]["artifacts"]
                if item["format"] == BIKE_MAP_STREAM_FORMAT
            )
            lines.append(" ".join((
                "stream=" + variant["file"],
                entry["profile"],
                entry["mapId"],
                str(entry["rendererFormatVersion"]),
                variant["deliveryTier"],
                stream["signatureKeyId"],
                manifest_receipt(manifest),
                stream["signedManifestReceipt"],
                str(header.file_count),
                str(header.payload_bytes),
            )))
    return "\n".join(lines) + "\n"


def build_corpus(root: Path) -> dict[str, BuiltProfile]:
    contract = fixture_contract()
    registered = {profile.profile_id for profile in contract.profiles}
    if registered != set(PROFILES):
        raise AssertionError(
            "every contract v1 profile needs a frozen corpus map: "
            f"{sorted(registered ^ set(PROFILES))}"
        )
    for profile in contract.profiles:
        production_eligible = "production" in profile.channels
        if production_eligible != bool(PROFILES[profile.profile_id][1]):
            raise AssertionError(f"{profile.profile_id} production coverage is wrong")
    return {
        profile_id: build_profile(root / profile_id, profile_id, contract)
        for profile_id in PROFILES
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output.exists():
        print(
            f"refusing to overwrite {args.output}: frozen corpora are never regenerated",
            file=sys.stderr,
        )
        return 1
    with tempfile.TemporaryDirectory() as temporary:
        os.environ.setdefault("MAP_PLATFORM_SOURCE_PREPARATION_MODE", "demand")
        built = build_corpus(Path(temporary))
        write_corpus(args.output, built)
    print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
