"""Assemble development FMB5/companion pairs without modifying vector inputs.

No signing, catalog publication or production source approval happens here.
The output receipt is written last; incomplete output is never a ready pack.
"""
from __future__ import annotations

import hashlib
import os
import re
import tempfile
from pathlib import Path
from typing import Callable

from .map_artifact_validation import validate_fma1, validate_fmb5
from .reuse import MapBlock, block_from_pack_path
from .topography_artifacts import ContourSection, empty_fmb5, upgrade_fmb4
from .topography_cache import _sync_directory
from .topography_companion import write_companion
from .topography_geometry import CompiledTopography, MAX_BLOCKS
from .topography_pipeline import canonical_bytes


def assemble_topographic_pack(vector_root: Path, output: Path, map_id: str,
                              compiled: CompiledTopography, sample: dict, attribution: bytes,
                              *, cancel: Callable[[], None] = lambda: None) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", map_id):
        raise ValueError("invalid topographic map ID")
    if output.exists() or output.is_symlink():
        raise FileExistsError(output)
    if not 1 <= len(attribution) <= 256 * 1024:
        raise ValueError("complete source notices are required and bounded")
    attribution.decode("utf-8", errors="strict")
    # The caller supplies the exact contributing-source notices. Their digest
    # binds both output outcomes; a digest alone is not legal approval.
    sample_sha = hashlib.sha256(canonical_bytes(sample)).hexdigest()
    if sample_sha != compiled.sample_sha256:
        raise ValueError("compiled contours do not belong to this source sample")
    source = vector_root / "VECTMAP" / map_id
    if source.is_symlink() or not source.is_dir():
        raise ValueError("vector input map folder is missing")
    font = source / "assets/street-labels.fma"
    if font.is_symlink() or not font.is_file():
        raise ValueError("vector input label font is missing")
    profile = validate_fma1(font)
    blocks = {}
    for path in sorted(source.rglob("*.fmb")):
        cancel()
        relative_parts = path.relative_to(vector_root).parts
        if path.is_symlink() or any(vector_root.joinpath(*relative_parts[:index]).is_symlink() for index in range(len(relative_parts))):
            raise ValueError("vector input must not contain symlinks")
        key = block_from_pack_path(path.relative_to(vector_root).as_posix())
        if key is None or (key.x, key.y) in blocks:
            raise ValueError("invalid or duplicate vector block path")
        blocks[key.x, key.y] = path
    keys = sorted(set(blocks) | set(compiled.sections))
    if not keys or len(keys) > MAX_BLOCKS:
        raise ValueError("topographic map exceeds block budget or has no device coverage")
    empty = ContourSection(sample["minorIntervalM"], sample["indexIntervalM"], ())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="topography-pack-", dir=output.parent) as tmp:
        staged = Path(tmp)
        device = staged / "device"
        font_output = device / "VECTMAP" / map_id / "assets/street-labels.fma"
        font_output.parent.mkdir(parents=True)
        font_output.write_bytes(font.read_bytes())
        files = []
        totals = {"recordCount": 0, "pointCount": 0, "buildingCount": 0}
        for bx, by in keys:
            cancel()
            section = compiled.sections.get((bx, by), empty)
            data = upgrade_fmb4(blocks[bx, by], section) if (bx, by) in blocks else empty_fmb5(profile.profile_fingerprint, section)
            block = MapBlock(bx, by)
            relative = f"VECTMAP/{map_id}/{block.folder_name}/{bx & 15}_{by & 15}.fmb"
            destination = device / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            metadata = validate_fmb5(destination)
            if (metadata.profile_fingerprint != profile.profile_fingerprint
                    or metadata.maximum_glyph_id > profile.glyph_count
                    or metadata.maximum_language_id > profile.language_count):
                raise ValueError("topographic block/font identity differs")
            totals["recordCount"] += metadata.contour_records
            totals["pointCount"] += metadata.contour_points
            totals["buildingCount"] += metadata.building_records
            files.append({"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        font_data = font_output.read_bytes()
        files.append({"path": font_output.relative_to(device).as_posix(), "bytes": len(font_data), "sha256": hashlib.sha256(font_data).hexdigest()})
        notice_sha = hashlib.sha256(attribution).hexdigest()
        companion = staged / f"{map_id}.btopo"
        companion_metadata = write_companion(companion, compiled, map_id=map_id,
                                            source_policy_sha256=sample["sourcePolicySha256"],
                                            attribution_sha256=notice_sha, bounds_e7=sample["boundsE7"], cancel=cancel)
        (staged / "ATTRIBUTION.txt").write_bytes(attribution)
        receipt = {"schemaVersion": 1, "kind": "bicino-topography-development-pair-v1", "productionEligible": False,
                   "mapId": map_id, "rendererFormatVersion": 4, "blockFormatVersion": 5,
                   "topographyProfileVersion": 1, "sourcePolicySha256": sample["sourcePolicySha256"],
                   "sampleSha256": sample_sha, "selectionSha256": compiled.selection_sha256,
                   "intermediateSha256": compiled.intermediate_sha256, "attributionSha256": notice_sha,
                   "qualityMode": sample["qualityMode"], "minorIntervalM": empty.minor_interval_m,
                   "indexIntervalM": empty.index_interval_m, "noDataMillionths": sample["noDataMillionths"],
                   "surfaceModel": sample["surfaceModel"], "horizontalCrs": "EPSG:4326",
                   "verticalDatum": sample["verticalDatum"], "sourcePixels": sample["sourcePixels"],
                   "gridSize": sample["gridSize"], "sources": sample["sources"],
                   "inputs": sample["inputs"], **totals,
                   "files": sorted(files, key=lambda value: value["path"]),
                   "companion": {"format": "topography-ios-v1", "filename": companion.name,
                                 "bytes": companion.stat().st_size, "sha256": hashlib.sha256(companion.read_bytes()).hexdigest(),
                                 "tileCount": companion_metadata["tileCount"]}}
        cancel()
        # Reserve the destination exclusively, publish only new files, and put
        # the completion receipt last. Existing user output is never replaced.
        output.mkdir()
        for path in sorted(staged.rglob("*")):
            if path.is_file():
                destination = output / path.relative_to(staged)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with path.open("rb") as file:
                    os.fsync(file.fileno())
                os.link(path, destination)
        for directory in sorted((p for p in output.rglob("*") if p.is_dir()), reverse=True):
            _sync_directory(directory)
        data = canonical_bytes(receipt)
        with (output / "topography-receipt.json").open("xb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        _sync_directory(output)
        _sync_directory(output.parent)
    return receipt
