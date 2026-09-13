"""Executable review inventory; a research recommendation is not approval.

This registry is deliberately separate from the two already-pinned acquisition
sources. Adding a candidate cannot change source priority, enable a downloader,
grant rights, or publish a map. Unknown evidence remains null, not fabricated.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

from .strict_json import loads_strict_json
from .topography_sources import _https

GATES = ("license", "notices", "access", "coverage", "rasterMasks", "verticalTransform",
         "sourceBoundaryQuality", "jurisdiction", "clientQualification")
ALLOWED_FALLBACK_REASONS = frozenset({"outside-coverage", "declared-void", "quality-rejected"})


def may_fallback(reason: str) -> bool:
    # In particular: timeout, rate limit, 401/403, hash failure, corrupt raster
    # and unavailable transform are failures, not reasons to change geography.
    return reason in ALLOWED_FALLBACK_REASONS


def load_qualification_registry(repo_root: Path) -> dict:
    path = repo_root / "map-platform/config/topography-qualification-v1.json"
    if path.stat().st_size > 128 * 1024:
        raise ValueError("topography qualification registry exceeds size bound")
    raw = path.read_bytes()
    data = loads_strict_json(raw, description="topography qualification registry")
    if (not isinstance(data, dict) or set(data) != {"schemaVersion", "researchDate", "reportSha256", "sources"}
            or type(data["schemaVersion"]) is not int or data["schemaVersion"] != 1
            or data["researchDate"] != "2026-09-13"
            or not isinstance(data["reportSha256"], str) or re.fullmatch(r"[a-f0-9]{64}", data["reportSha256"]) is None):
        raise ValueError("invalid topography qualification registry")
    values = data["sources"]
    if not isinstance(values, list) or not 1 <= len(values) <= 64:
        raise ValueError("invalid qualification source list")
    sources = {}
    fields = {"id", "stage", "release", "surfaceModel", "nativeVerticalDatum", "accessRequirement",
              "termsUrl", "fallbackIds", "evidenceSha256", "productionApproved"}
    for source in values:
        if (not isinstance(source, dict) or set(source) != fields or not isinstance(source["id"], str)
                or re.fullmatch(r"[a-z][a-z0-9_-]{2,80}", source["id"]) is None or source["id"] in sources):
            raise ValueError("invalid or duplicate qualification source")
        if (source["stage"] not in ("pinned-acquisition", "metadata-discovery", "planned")
                or source["surfaceModel"] not in ("dsm", "dtm", "surface-hybrid")
                or source["accessRequirement"] not in ("anonymous", "registered", "registered-and-commercial-notification", "batch-contract-review")
                or not isinstance(source["release"], str) or not source["release"]
                or (source["nativeVerticalDatum"] is not None and not isinstance(source["nativeVerticalDatum"], str))):
            raise ValueError("unsupported qualification source contract")
        _https(source["termsUrl"], "qualification terms URL")
        if source["productionApproved"] is not False:
            raise ValueError("research inventory cannot grant production approval")
        evidence = source["evidenceSha256"]
        if (not isinstance(evidence, dict) or set(evidence) != set(GATES)
                or any(v is not None and (not isinstance(v, str) or re.fullmatch(r"[a-f0-9]{64}", v) is None) for v in evidence.values())):
            raise ValueError("invalid qualification evidence identity")
        fallback = source["fallbackIds"]
        if (not isinstance(fallback, list) or any(not isinstance(v, str) for v in fallback)
                or len(fallback) != len(set(fallback))):
            raise ValueError("invalid qualification fallback references")
        sources[source["id"]] = source
    visited, active = set(), set()

    def visit(source_id):
        if source_id not in sources:
            raise ValueError("unknown qualification fallback source")
        if source_id in active:
            raise ValueError("cyclic qualification fallback graph")
        if source_id in visited:
            return
        active.add(source_id)
        for child in sources[source_id]["fallbackIds"]:
            visit(child)
        active.remove(source_id)
        visited.add(source_id)

    for source_id in sources:
        visit(source_id)
    return {**data, "registrySha256": hashlib.sha256(raw).hexdigest()}


def qualification_summary(registry: dict) -> dict:
    return {"schemaVersion": 1, "access": "free", "generationEnabled": False,
            "registrySha256": registry["registrySha256"],
            "sources": [{"sourceId": s["id"], "stage": s["stage"], "release": s["release"],
                         "productionEligible": False,
                         "missingEvidence": [gate for gate in GATES if s["evidenceSha256"][gate] is None],
                         "accessRequirement": s["accessRequirement"]} for s in registry["sources"]],
            "mainlandChina": {"publicationEnabled": False, "requiredReviews": ["legal-scope", "MapKit-alignment"],
                              "changingContourIntervalIsNotApproval": True},
            "verticalNormalization": {"target": "EPSG:3855", "ballparkAllowed": False,
                                      "unreviewedDatumMixingAllowed": False, "implicitGridDownloadsAllowed": False}}
