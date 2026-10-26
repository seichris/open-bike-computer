"""Signed target-5 maps built by the real packaging, signing and catalog code.

``build_target5_maps`` runs ``MapBuildPipeline._package_map`` for a combined
POI+contour map and for an explicitly contour-free POI map. Only the DEM sample
and its source notice are supplied by the fixture; contour compilation, pair
assembly, the iPhone companion, the manifest, the BMAP signature and catalog
publication all use production code.

``python -m tests.contour_companion_fixture`` rewrites the committed text
fixture consumed by the iPhone contract tests. Signing is deterministic, so
regeneration with the same native SQLite/PNG runtime reproduces the bytes.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    TOPOGRAPHY_COMPANION_FORMAT,
    ArtifactRecord,
    FileSystemArtifactStore,
)
from map_platform.catalog import publication_payload
from map_platform.artifacts import map_stream_object_key
from map_platform.map_signing import P256MapArtifactSigner
from map_platform.map_stream import write_map_stream_artifact
from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.topography_pipeline import canonical_bytes
from tests.map_label_fixtures import fmb6_with_pois, one_label_fma1


FIXTURE = Path(__file__).parent / "fixtures" / "map_contour_companion_v1.txt"
SIGNATURE_KEY_ID = "map-contour-test-1"
PRODUCER_BUILD_SHA256 = "1" * 64
PRODUCER_IMAGE_DIGEST = "sha256:" + "2" * 64
SOURCE_NOTICE = b"Contour companion fixture elevation notice\n"
# Block (0, 0) spans Web Mercator metres [0, 4096); this keeps both maps in
# one Nearby coverage block and one short contour, so the companion is small.
BOUNDS = Bounds(0.001, 0.001, 0.03, 0.03)
VARIANTS = {
    "combined": ("contour-fixture", True),
    "plain": ("poi-fixture", False),
}


@dataclass(frozen=True)
class BuiltMap:
    job: MapJob
    artifacts: tuple[ArtifactRecord, ...]
    artifact_root: Path
    publication: dict[str, Any]
    pack_root: Path
    stream_manifest: dict[str, Any]

    def artifact(self, artifact_format: str) -> ArtifactRecord:
        matches = [value for value in self.artifacts if value.format == artifact_format]
        if len(matches) != 1:
            raise AssertionError(f"expected one {artifact_format} artifact")
        return matches[0]

    def artifact_bytes(self, artifact: ArtifactRecord) -> bytes:
        return (self.artifact_root / artifact.object_key).read_bytes()


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


def target5_job(map_id: str, contours: bool) -> MapJob:
    features = ["3d-buildings", "map-pois", "street-labels"]
    if contours:
        features = sorted([*features, "contours"])
    job = MapJob(
        job_id=f"fixture-{map_id}",
        status=JobStatus.QUEUED,
        request={
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 5,
                "firmwareVersion": "1.2.3",
                "requestedFeatures": features,
            },
            "labels": {"profileVersion": 1, "preferredLanguages": ["en"],
                       "internationalFallback": "en"},
        },
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX, bounds=BOUNDS,
            area_km2=10, vertex_count=4,
        ),
        source_region=SourceRegion(
            id="fixture", provider="test", name="Fixture",
            url="https://example.invalid/fixture.osm.pbf",
            bounds=Bounds(-1, -1, 1, 1), checksum="3" * 64,
        ),
    )
    job.map_id = map_id
    return job


def signer() -> P256MapArtifactSigner:
    return P256MapArtifactSigner(
        SIGNATURE_KEY_ID, ec.derive_private_key(53, ec.SECP256R1())
    )


def public_key_x963(map_signer: P256MapArtifactSigner) -> bytes:
    return map_signer._private_key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )


def build_target5_map(root: Path, variant: str) -> BuiltMap:
    map_id, contours = VARIANTS[variant]
    root.mkdir(parents=True, exist_ok=True)
    pack = root / "pack"
    block = pack / f"VECTMAP/{map_id}/+000+000/0_0.fmb"
    block.parent.mkdir(parents=True)
    block.write_bytes(fmb6_with_pois())
    font = pack / f"VECTMAP/{map_id}/assets/street-labels.fma"
    font.parent.mkdir()
    font.write_bytes(one_label_fma1())
    artifact_root = root / "artifacts"
    pipeline = MapBuildPipeline(
        PipelinePaths(Path(__file__).resolve().parents[3], root / "work", root / "packs"),
        artifact_store=FileSystemArtifactStore(artifact_root),
        map_signer=signer(),
        producer_build_sha256=PRODUCER_BUILD_SHA256,
        producer_image_digest=PRODUCER_IMAGE_DIGEST,
    )
    job = target5_job(map_id, contours)
    sample = contour_sample()
    signed_manifests = []

    def record_stream(map_root, manifest, *args, **kwargs):
        signed_manifests.append(deepcopy(manifest))
        return write_map_stream_artifact(map_root, manifest, *args, **kwargs)

    with patch("map_platform.pipeline.contour_sample", return_value=sample), \
            patch("map_platform.pipeline.write_map_stream_artifact", side_effect=record_stream), \
            patch.object(MapBuildPipeline, "_topography_attribution", return_value=SOURCE_NOTICE):
        packaged = pipeline._package_map(
            job, pack, root / f"{map_id}.zip", validate_final_artifact=True,
        )
    if len(signed_manifests) != 1:
        raise AssertionError("packaging must sign exactly one stream")
    job.status = JobStatus.READY
    job.artifacts = list(packaged.artifacts)
    job.finished_at = "2026-10-26T00:00:00Z"
    return BuiltMap(
        job=job,
        artifacts=tuple(packaged.artifacts),
        artifact_root=artifact_root,
        publication=publication_payload(job, "development"),
        pack_root=pack,
        stream_manifest=signed_manifests[0],
    )


def build_target5_maps(root: Path) -> dict[str, BuiltMap]:
    return {variant: build_target5_map(root / variant, variant) for variant in VARIANTS}


def restamped_stream(built: BuiltMap, output: Path) -> tuple[ArtifactRecord, bytes]:
    """Return a second exact stream for the same map content.

    Signing is deterministic, so this mirrors production promotion: another
    producer identity signs the identical content. The stream digest changes
    while the producer-independent content receipt (and companion) stays.
    """
    original = built.artifact(BIKE_MAP_STREAM_FORMAT)
    producer_build_sha256 = "3" * 64
    manifest = deepcopy(built.stream_manifest)
    manifest["producer"] = {
        "buildSha256": producer_build_sha256,
        "imageDigest": PRODUCER_IMAGE_DIGEST,
    }
    map_signer = signer()
    stream = write_map_stream_artifact(built.pack_root, manifest, map_signer, output)
    record = ArtifactRecord(
        format=original.format,
        media_type=original.media_type,
        filename=original.filename,
        object_key=map_stream_object_key(
            built.job.map_id, stream.signed_manifest_receipt, stream.signature_key_id,
            map_signer.public_key_sha256, producer_build_sha256, PRODUCER_IMAGE_DIGEST,
        ),
        bytes=stream.bytes,
        sha256=stream.sha256,
        manifest_receipt=stream.manifest_receipt,
        signed_manifest_receipt=stream.signed_manifest_receipt,
        signature_key_id=stream.signature_key_id,
        signature_key_sha256=map_signer.public_key_sha256,
        producer_build_sha256=producer_build_sha256,
        producer_image_digest=PRODUCER_IMAGE_DIGEST,
    )
    content = {key: value for key, value in manifest.items() if key != "producer"}
    original_content = {key: value for key, value in built.stream_manifest.items() if key != "producer"}
    if record.sha256 == original.sha256 or content != original_content:
        raise AssertionError("restamping must keep content and change the exact stream")
    return record, output.read_bytes()


def fixture_lines(maps: dict[str, BuiltMap]) -> list[str]:
    map_signer = signer()
    lines = [
        f"signature_key_id={SIGNATURE_KEY_ID}",
        f"public_key_x963_hex={public_key_x963(map_signer).hex()}",
    ]
    for variant, built in maps.items():
        stream = built.artifact(BIKE_MAP_STREAM_FORMAT)
        lines.extend([
            f"{variant}_map_id={built.job.map_id}",
            f"{variant}_job_id={built.job.job_id}",
            f"{variant}_artifacts_json=" + json.dumps(
                [value.to_dict() for value in built.artifacts],
                sort_keys=True, separators=(",", ":"),
            ),
            f"{variant}_publication_json=" + canonical_bytes(built.publication).decode().rstrip("\n"),
            f"{variant}_stream_hex={built.artifact_bytes(stream).hex()}",
        ])
        if variant == "combined":
            restamped, data = restamped_stream(built, built.pack_root.parent / "restamped.bmap")
            lines.extend([
                f"{variant}_restamped_stream_json=" + json.dumps(
                    restamped.to_dict(), sort_keys=True, separators=(",", ":"),
                ),
                f"{variant}_restamped_stream_hex={data.hex()}",
            ])
        companions = [value for value in built.artifacts if value.format == TOPOGRAPHY_COMPANION_FORMAT]
        if companions:
            lines.append(f"{variant}_companion_hex={built.artifact_bytes(companions[0]).hex()}")
    return lines


def load_fixture(path: Path = FIXTURE) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def main() -> int:
    with tempfile.TemporaryDirectory() as temporary:
        os.environ.setdefault("MAP_PLATFORM_SOURCE_PREPARATION_MODE", "demand")
        maps = build_target5_maps(Path(temporary))
        FIXTURE.write_text("\n".join(fixture_lines(maps)) + "\n")
    print(f"wrote {FIXTURE}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
