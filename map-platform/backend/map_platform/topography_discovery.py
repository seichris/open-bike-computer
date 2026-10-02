"""Bounded regional native-asset discovery, never raster download/approval.

Preserve complete upstream metadata and checksums for a later pinned ingestion
review. Neither a STAC footprint nor traversal completion proves valid pixels.
No credentials, registrations, notifications or implicit fallback are used.
"""
from __future__ import annotations

import hashlib
import math
import re
import time
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .strict_json import loads_strict_json

MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
MAX_DOCUMENTS = 1024
MAX_ITEMS = 4096
MAX_ASSETS = 256
DEADLINE_SECONDS = 180


@dataclass(frozen=True)
class RegionalSource:
    collection_url: str
    metadata_prefixes: tuple[str, ...]
    asset_prefixes: tuple[str, ...]
    collection_id: str | None
    static: bool = False


SWISS = "https://data.geo.admin.ch/"
CANADA = "https://datacube.services.geo.ca/"
LINZ = "https://nz-elevation.s3-ap-southeast-2.amazonaws.com/"
REGIONAL_SOURCES = {
    "swissalti3d-2m": RegionalSource(
        SWISS + "api/stac/v0.9/collections/ch.swisstopo.swissalti3d",
        (SWISS + "api/stac/v0.9/collections/ch.swisstopo.swissalti3d",),
        (SWISS + "ch.swisstopo.swissalti3d/",), "ch.swisstopo.swissalti3d"),
    "canada-hrdem-lidar": RegionalSource(
        CANADA + "stac/api/collections/hrdem-lidar",
        tuple(CANADA + path + "/collections/hrdem-lidar" for path in ("stac/api", "pgstac/api")),
        ("https://canelevation-dem.s3.ca-central-1.amazonaws.com/hrdem-lidar/",), "hrdem-lidar"),
    "linz-national-dem-1m": RegionalSource(
        LINZ + "new-zealand/new-zealand/dem_1m/2193/collection.json",
        (LINZ + "new-zealand/new-zealand/dem_1m/2193/",),
        (LINZ + "new-zealand/new-zealand/dem_1m/2193/",), None, True),
}


def _allowed_url(value: str, prefixes: tuple[str, ...]) -> str:
    if not isinstance(value, str) or len(value) > 8192 or any(ord(c) <= 32 for c in value):
        raise ValueError("invalid elevation discovery URL")
    try:
        url = urlsplit(value)
        if (url.scheme != "https" or url.username or url.password or url.port is not None or url.fragment
                or "%" in url.path or "\\" in value or any(p in (".", "..") for p in url.path.split("/"))):
            raise ValueError("invalid elevation discovery URL")
    except ValueError as exc:
        raise ValueError("invalid elevation discovery URL") from exc
    if not any(value == p or value.startswith(p if p.endswith("/") else p + "/")
               or value.startswith(p + "?") for p in prefixes):
        raise ValueError("elevation discovery URL is outside the source contract")
    return value


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("elevation metadata redirect requires source contract review")


def _fetch(url: str, cancel: Callable[[], None], deadline: float) -> bytes:
    request = Request(url, headers={"User-Agent": "Bicino-Elevation-Qualification/1", "Accept": "application/json"})
    with build_opener(_NoRedirect()).open(request, timeout=min(20, max(0.1, deadline - time.monotonic()))) as response:
        if response.status != 200 or response.geturl() != url:
            raise ValueError("unexpected elevation metadata response")
        data = bytearray()
        while True:
            cancel()
            if time.monotonic() >= deadline:
                raise TimeoutError("elevation discovery exceeded its deadline")
            chunk = response.read(min(65536, MAX_DOCUMENT_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_DOCUMENT_BYTES:
                raise ValueError("elevation metadata exceeds document byte bound")
        return bytes(data)


def _bounds(value) -> tuple:
    if (not isinstance(value, (list, tuple)) or len(value) != 4
            or any(type(v) not in (int, float) or not math.isfinite(v) for v in value)):
        raise ValueError("invalid WGS84 discovery bounds")
    w, s, e, n = value
    if not (-180 <= w < e <= 180 and -90 <= s < n <= 90):
        raise ValueError("split wrapped discovery bounds into separate requests")
    return tuple(value)


def _checksum(asset: dict) -> str | None:
    values = [asset[k] for k in ("checksum:multihash", "file:checksum") if k in asset]
    if not values:
        return None
    if any(not isinstance(v, str) or re.fullmatch(r"1220[0-9a-fA-F]{64}", v) is None for v in values):
        raise ValueError("unsupported provider checksum; do not discard it")
    digests = {v[4:].lower() for v in values}
    if len(digests) != 1:
        raise ValueError("conflicting provider checksums")
    return digests.pop()


def _links(document: dict, relation: str) -> list[dict]:
    links = document.get("links", [])
    if not isinstance(links, list) or any(not isinstance(link, dict) for link in links):
        raise ValueError("malformed elevation catalog links")
    return [link for link in links if link.get("rel") == relation]


def discover_regional(source_id: str, bounds: list[float], *,
                      fetch: Callable[[str, Callable[[], None], float], bytes] = _fetch,
                      cancel: Callable[[], None] = lambda: None) -> dict:
    from shapely.geometry import box, shape

    source = REGIONAL_SOURCES[source_id]
    selection = box(*_bounds(bounds))
    started = time.monotonic()
    documents, assets, identities, visited = [], [], set(), set()
    total_bytes = item_count = 0

    def read(url: str, expected_sha: str | None = None):
        nonlocal total_bytes
        cancel()
        _allowed_url(url, source.metadata_prefixes)
        if url in visited:
            raise ValueError("cyclic or duplicate elevation pagination link")
        if len(visited) >= MAX_DOCUMENTS or time.monotonic() - started >= DEADLINE_SECONDS:
            raise ValueError("elevation discovery budget exhausted; snapshot is incomplete")
        visited.add(url)
        raw = fetch(url, cancel, started + DEADLINE_SECONDS)
        total_bytes += len(raw)
        if len(raw) > MAX_DOCUMENT_BYTES or total_bytes > MAX_TOTAL_BYTES:
            raise ValueError("elevation discovery metadata byte budget exhausted")
        digest = hashlib.sha256(raw).hexdigest()
        if expected_sha is not None and expected_sha != digest:
            raise ValueError("provider catalog item checksum mismatch")
        document = loads_strict_json(raw, description="elevation discovery metadata")
        if not isinstance(document, dict):
            raise ValueError("elevation metadata must be an object")
        # Keep original UTF-8 bytes, not a lossy subset of license/provider and
        # source-lineage metadata. The digest is locally observed, not signed.
        documents.append({"url": url, "sha256": digest, "utf8": raw.decode("utf-8")})
        return document, digest

    collection, collection_sha = read(source.collection_url)
    collection_id = collection.get("id")
    if not isinstance(collection_id, str) or not collection_id or (source.collection_id and collection_id != source.collection_id):
        raise ValueError("unexpected elevation collection identity")
    license_id = collection.get("license")  # 'proprietary' can represent custom OGD terms.

    def item(document: dict, document_url: str, document_sha: str):
        nonlocal item_count
        cancel()
        if time.monotonic() - started >= DEADLINE_SECONDS:
            raise TimeoutError("elevation discovery exceeded its deadline")
        item_count += 1
        if item_count > MAX_ITEMS:
            raise ValueError("elevation discovery item budget exhausted")
        if document.get("type") != "Feature" or document.get("collection") != collection_id:
            raise ValueError("unexpected elevation item collection")
        item_id = document.get("id")
        if not isinstance(item_id, str) or not item_id or len(item_id) > 512 or item_id in identities:
            raise ValueError("invalid or duplicate elevation item identity")
        identities.add(item_id)
        _bounds(document.get("bbox"))
        geometry = shape(document["geometry"])
        if geometry.is_empty or not geometry.is_valid or geometry.geom_type not in ("Polygon", "MultiPolygon"):
            raise ValueError("invalid elevation item footprint")
        _bounds(geometry.bounds)
        if not geometry.intersects(selection):
            return
        properties = document.get("properties")
        native_assets = document.get("assets")
        if not isinstance(properties, dict) or not isinstance(native_assets, dict):
            raise ValueError("invalid elevation item metadata")
        selected = []
        for key, asset in sorted(native_assets.items()):
            if not isinstance(asset, dict):
                raise ValueError("invalid elevation asset metadata")
            if source_id == "swissalti3d-2m":
                accept = (key.endswith("_2_2056_5728.tif") and asset.get("eo:gsd") == 2
                          and asset.get("proj:epsg") == 2056)
            else:
                accept = key == ("dtm" if source_id == "canada-hrdem-lidar" else "visual")
            if not accept:
                continue
            if not str(asset.get("type", "")).startswith("image/tiff"):
                raise ValueError("selected elevation asset is not a native TIFF")
            href = _allowed_url(urljoin(document_url, asset["href"]), source.asset_prefixes)
            if urlsplit(href).query or not urlsplit(href).path.lower().endswith((".tif", ".tiff")):
                raise ValueError("selected elevation asset is not a stable native object URL")
            if source_id == "canada-hrdem-lidar" and not urlsplit(href).path.endswith("-dtm.tif"):
                raise ValueError("Canadian DTM key and native product suffix disagree")
            selected.append({"itemId": item_id, "assetKey": key, "url": href,
                             "providerSha256": _checksum(asset), "documentSha256": document_sha,
                             "collectionSha256": collection_sha, "footprint": document["geometry"],
                             "surfaceModel": "dtm", "licenseLabel": document.get("license", license_id),
                             "horizontalCrs": asset.get("proj:epsg", properties.get("proj:epsg")),
                             "verticalDatum": None, "rasterContractVerified": False,
                             "datetime": properties.get("datetime"),
                             "startDatetime": properties.get("start_datetime"),
                             "endDatetime": properties.get("end_datetime"),
                             "updated": asset.get("updated", properties.get("updated"))})
        if len(selected) != 1:
            raise ValueError("expected one unambiguous native DTM asset per intersecting item")
        assets.extend(selected)
        if len(assets) > MAX_ASSETS:
            raise ValueError("elevation discovery asset budget exhausted; use smaller bounds")

    if source.static:
        links = _links(collection, "item")
        if not links:
            raise ValueError("static elevation collection has no item links")
        for link in links:
            url = urljoin(source.collection_url, link["href"])
            document, digest = read(url, _checksum(link))
            item(document, url, digest)
    else:
        url = source.collection_url + "/items?" + urlencode({"bbox": ",".join(map(str, bounds)), "limit": 100})
        while url:
            page, digest = read(url)
            features = page.get("features")
            if page.get("type") != "FeatureCollection" or not isinstance(features, list):
                raise ValueError("expected elevation FeatureCollection")
            for document in features:
                if not isinstance(document, dict):
                    raise ValueError("invalid elevation feature")
                item(document, url, digest)
            links = _links(page, "next")
            if len(links) > 1 or any(link.get("method", "GET") != "GET" or link.get("body") for link in links):
                raise ValueError("unsupported elevation pagination contract")
            url = urljoin(url, links[0]["href"]) if links else None
    cancel()
    if time.monotonic() - started >= DEADLINE_SECONDS:
        raise TimeoutError("elevation discovery exceeded its deadline")
    return {"schemaVersion": 1, "kind": "bicino-elevation-discovery-v1", "sourceId": source_id,
            "bounds": bounds, "access": "free", "productionEligible": False,
            "catalogTraversalComplete": True, "validPixelCoverageVerified": False,
            "assets": sorted(assets, key=lambda a: (a["itemId"], a["assetKey"])),
            "documents": documents,
            "pendingGates": ["license-notices", "native-raster-masks", "vertical-transform",
                             "quality-source-boundaries", "jurisdiction", "client-qualification"]}
