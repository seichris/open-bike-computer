"""Per-request PBF alternatives, not a byte-identical mirror or catalogue.

Derive the same path by default; use exact aliases only for reviewed differences.
The download validates availability and file framing, not geographic equivalence.
See docs/osmfr-alias-research.md for evidence and coverage exceptions.
"""
from __future__ import annotations

import http.client
import re
import ssl
import urllib.error
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .models import SourceRegion

GEOFABRIK_BASE = "https://download.geofabrik.de/"
OSMFR_BASE = "https://download.openstreetmap.fr/extracts/"

# Full source paths, without -latest.osm.pbf. No basename matching, fuzzy
# translation, blanket punctuation replacement, or inheritance by descendants.
# Reviewed 2026-09-06 against the provider catalogues/listings; see the research
# document for evidence. These are naming correspondences, not polygon proofs.
ALIASES = {
    "africa/congo-brazzaville": "africa/congo_brazzaville",
    "africa/congo-democratic-republic": "africa/congo_kinshasa",
    "africa/equatorial-guinea": "africa/equatorial_guinea",
    "africa/ivory-coast": "africa/ivory_coast",
    "africa/south-africa": "africa/south_africa",
    "africa/south-sudan": "africa/south_sudan",
    "asia/china/hong-kong": "asia/china/hong_kong",
    "asia/china/inner-mongolia": "asia/china/inner_mongolia",
    "asia/east-timor": "asia/east_timor",
    "asia/israel-and-palestine": "asia/israel_and_palestine",
    "australia-oceania/australia": "oceania/australia",
    "australia-oceania/fiji": "merge/fiji",
    "australia-oceania/new-caledonia": "oceania/new_caledonia",
    "australia-oceania/papua-new-guinea": "oceania/papua_new_guinea",
    "australia-oceania/solomon-islands": "oceania/solomon_islands",
    "central-america/costa-rica": "central-america/costa_rica",
    "central-america/el-salvador": "central-america/el_salvador",
    "europe/czech-republic": "europe/czech_republic",
    "europe/georgia": "asia/georgia",
    "europe/germany/nordrhein-westfalen": "europe/germany/nordrhein_westfalen",
    "europe/united-kingdom": "europe/united_kingdom",
    "europe/united-kingdom/england": "europe/united_kingdom/england",
    "europe/united-kingdom/falklands": "south-america/falkland",
    "north-america/canada/british-columbia": "north-america/canada/british_columbia",
    "north-america/canada/new-brunswick": "north-america/canada/new_brunswick",
    "north-america/canada/newfoundland-and-labrador": "north-america/canada/newfoundland_and_labrador",
    "north-america/canada/northwest-territories": "north-america/canada/northwest_territories",
    "north-america/canada/nova-scotia": "north-america/canada/nova_scotia",
    "north-america/canada/prince-edward-island": "north-america/canada/prince_edward_island",
    "north-america/us/california": "north-america/us-west/california",
    "north-america/us/colorado": "north-america/us-west/colorado",
    "north-america/us/florida": "north-america/us-south/florida",
    "north-america/us/georgia": "north-america/us-south/georgia",
    "north-america/us/illinois": "north-america/us-midwest/illinois",
    "north-america/us/michigan": "north-america/us-midwest/michigan",
    "north-america/us/new-york": "north-america/us-northeast/new-york",
    "north-america/us/north-carolina": "north-america/us-south/north-carolina",
    "north-america/us/texas": "north-america/us-south/texas",
    "north-america/us/virginia": "north-america/us-south/virginia",
    "russia/central-fed-district": "russia/central_federal_district",
    "russia/far-eastern-fed-district": "russia/far_eastern_federal_district",
    "russia/north-caucasus-fed-district": "russia/north_caucasian_federal_district",
    "russia/northwestern-fed-district": "russia/northwestern_federal_district",
    "russia/siberian-fed-district": "russia/siberian_federal_district",
    "russia/south-fed-district": "russia/southern_federal_district",
    "russia/ural-fed-district": "russia/ural_federal_district",
    "russia/volga-fed-district": "russia/volga_federal_district",
}

# These particular source scopes must not be replaced by a smaller component
# or an unreviewed larger union. Absence from a directory alone is NOT a reason
# to block a same-path probe: unknown regions (including Taiwan) remain eligible.
EXCEPTIONS = {
    "africa/senegal-and-gambia": "Combined source; Senegal alone omits Gambia.",
    "africa/south-africa-and-lesotho": "Combined source; South Africa alone may omit Lesotho.",
    "asia/gcc-states": "Combined source; no single member is an equivalent extract.",
    "asia/indonesia": "Geofabrik explicitly includes East Timor; OSM.fr publishes it separately.",
    "asia/malaysia-singapore-brunei": "Combined source; Malaysia alone omits Singapore and Brunei.",
    "australia-oceania/australia/new-south-wales": "Geofabrik explicitly includes ACT and JBT; a state-only alias is unverified.",
    "central-america/haiti-and-domrep": "Combined source; Haiti or Dominican Republic alone is incomplete.",
    "europe/britain-and-ireland": "Combined source; neither the UK nor Ireland alone suffices.",
    "europe/great-britain": "Great Britain is not the same source scope as the United Kingdom.",
    "europe/ireland-and-northern-ireland": "Combined source; Ireland alone omits Northern Ireland.",
    "north-america/us": "OSM.fr publishes regional US quadrants; none alone covers the whole US.",
}

# Full matching deliberately rejects ports, credentials, queries, fragments,
# encoded separators, dot segments, empty segments, backslashes and whitespace.
# Do not normalize an untrusted URL before this check (urlsplit strips controls).
_LATEST_URL = re.compile(
    re.escape(GEOFABRIK_BASE)
    + r"(?P<path>[a-z0-9][a-z0-9_-]*(?:/[a-z0-9][a-z0-9_-]*)*)-latest\.osm\.pbf"
)


def fallback_url(region: SourceRegion) -> str | None:
    """Return one candidate for an unpinned canonical Geofabrik latest URL.

    Candidate construction performs no I/O. SourceCache tries it only after an
    eligible primary failure; a missing candidate fails normally, without a
    catalogue crawl, additional guesses, or a larger parent-region download.
    """
    if region.provider != "geofabrik" or region.checksum or region.published_at:
        return None
    if not isinstance(region.url, str) or (match := _LATEST_URL.fullmatch(region.url)) is None:
        return None
    path = match.group("path")
    if path in EXCEPTIONS:
        return None
    return f"{OSMFR_BASE}{ALIASES.get(path, path)}-latest.osm.pbf"


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
