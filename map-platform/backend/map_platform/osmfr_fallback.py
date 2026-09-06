"""Explicit PBF alternatives, not a hostname-rewriting mirror.

OpenStreetMap France uses different region names, boundaries and snapshots.
Only unpinned latest extracts with a known corresponding region may fail over.
See docs/osm-source-fallback.md before extending the mapping.
"""
from __future__ import annotations

import http.client
import ssl
import urllib.error
from pathlib import Path

from .models import SourceRegion

GEOFABRIK_BASE = "https://download.geofabrik.de/"
OSMFR_BASE = "https://download.openstreetmap.fr/extracts/"

# These are explicit region names, not a rule for arbitrary Geofabrik paths.
# Destination listings verified on 2026-09-06. In particular, never replace
# malaysia-singapore-brunei with malaysia, or ireland-and-northern-ireland
# with ireland: those would silently drop part of the requested source.
_SAME_PATH_REGIONS = {
    "asia/china",
    "asia/japan",
    "asia/india",
    "asia/indonesia",
    "asia/bhutan",
    "asia/cambodia",
    "asia/laos",
    "asia/myanmar",
    "asia/philippines",
    "europe/andorra",
    "europe/austria",
    "europe/belgium",
    "europe/denmark",
    "europe/finland",
    "europe/france",
    "europe/germany",
    "europe/italy",
    "europe/luxembourg",
    "europe/monaco",
    "europe/netherlands",
    "europe/norway",
    "europe/poland",
    "europe/portugal",
    "europe/slovakia",
    "europe/spain",
    "europe/sweden",
    "europe/switzerland",
    "europe/ukraine",
}
_CHINA_REGIONS = {
    "anhui", "beijing", "chongqing", "fujian", "gansu", "guangdong",
    "guangxi", "guizhou", "hainan", "hebei", "heilongjiang", "henan",
    "hubei", "hunan", "jiangsu", "jiangxi", "jilin", "liaoning", "ningxia",
    "qinghai", "shaanxi", "shandong", "shanghai", "shanxi", "sichuan",
    "tianjin", "xinjiang", "yunnan", "zhejiang",
}
_FALLBACK_URLS = {
    f"{GEOFABRIK_BASE}{path}-latest.osm.pbf": f"{OSMFR_BASE}{path}-latest.osm.pbf"
    for path in _SAME_PATH_REGIONS | {f"asia/china/{name}" for name in _CHINA_REGIONS}
}

# Explicit naming differences in the China subdivision catalog.
_FALLBACK_URLS.update({
    f"{GEOFABRIK_BASE}asia/china/{primary}-latest.osm.pbf":
        f"{OSMFR_BASE}asia/china/{alternative}-latest.osm.pbf"
    for primary, alternative in {
        "xizang": "tibet",
        "neimenggu": "inner_mongolia",
        "hong-kong": "hong_kong",
        "macau": "macau",
    }.items()
})


def fallback_url(region: SourceRegion) -> str | None:
    """Never translate pinned snapshots, custom hosts, or unknown regions."""
    if region.provider != "geofabrik" or region.checksum or region.published_at:
        return None
    # Exact full-URL lookup also rejects credentials, queries, fragments,
    # alternate ports, lookalike hosts, and path traversal.
    return _FALLBACK_URLS.get(region.url)


def is_upstream_unavailable(error: BaseException | None) -> bool:
    """Classify transport/availability failures, not local or integrity errors."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code in {404, 408, 410, 429} or 500 <= error.code <= 599
    if isinstance(error, urllib.error.URLError):
        # Do not conceal a TLS trust failure by silently changing provider.
        return not isinstance(error.reason, ssl.SSLError)
    return isinstance(
        error,
        (TimeoutError, ConnectionError, http.client.IncompleteRead, http.client.RemoteDisconnected),
    )


def validate_pbf_header(path: Path) -> None:
    """Reject empty/HTML/truncated-header fallback bodies before publication.

    This is a bounded BlobHeader sanity check, not whole-file OSM validation;
    the extraction pipeline still parses the PBF and checks its contents.
    """
    with path.open("rb") as stream:
        prefix = stream.read(4)
        size = int.from_bytes(prefix, "big")
        if len(prefix) != 4 or not 0 < size < 64 * 1024:
            raise ValueError("fallback response is not an OSM PBF header")
        header = stream.read(size)
    if len(header) != size:
        raise ValueError("fallback PBF header is truncated")
    position = 0
    blob_type = None
    blob_size = None

    def varint() -> int:
        nonlocal position
        value = 0
        for shift in range(0, 70, 7):
            if position >= len(header):
                break
            byte = header[position]
            position += 1
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
        raise ValueError("fallback PBF header has an invalid varint")

    while position < len(header):
        tag = varint()
        field, wire = tag >> 3, tag & 7
        if field == 0:
            raise ValueError("fallback PBF header has an invalid field")
        if wire == 0:
            value = varint()
            if field == 3:
                blob_size = value
        elif wire == 2:
            length = varint()
            end = position + length
            if field == 1:
                blob_type = header[position:end]
            position = end
        elif wire in {1, 5}:
            position += 8 if wire == 1 else 4
        else:
            raise ValueError("fallback PBF header has an invalid wire type")
        if position > len(header):
            raise ValueError("fallback PBF header is truncated")
    if (
        blob_type != b"OSMHeader"
        or blob_size is None
        or not 0 < blob_size < 32 * 1024 * 1024
        or path.stat().st_size < 4 + size + blob_size
    ):
        raise ValueError("fallback response has no complete OSMHeader blob")
