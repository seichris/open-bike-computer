"""Bounded native regional TIFF staging from replay-verified discovery evidence."""
from __future__ import annotations

import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .strict_json import loads_strict_json
from .topography_cache import ElevationCache, MAX_TILE_BYTES, _sync_directory
from .topography_discovery import REGIONAL_SOURCES, discover_regional, _allowed_url
from .topography_pipeline import canonical_bytes


def verified_discovery(path: Path) -> tuple[dict, str]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("invalid regional discovery snapshot")
    raw = path.read_bytes()
    value = loads_strict_json(raw, description="regional discovery snapshot")
    if not isinstance(value, dict) or value.get("sourceId") not in REGIONAL_SOURCES:
        raise ValueError("unsupported regional discovery source")
    documents = value.get("documents")
    if not isinstance(documents, list) or len(documents) > 1024:
        raise ValueError("invalid regional discovery document inventory")
    by_url = {}
    for document in documents:
        if (not isinstance(document, dict) or set(document) != {"url", "sha256", "utf8"}
                or not isinstance(document["url"], str) or document["url"] in by_url
                or not isinstance(document["utf8"], str)):
            raise ValueError("invalid or duplicate discovery metadata document")
        encoded = document["utf8"].encode()
        if hashlib.sha256(encoded).hexdigest() != document["sha256"]:
            raise ValueError("discovery metadata checksum mismatch")
        by_url[document["url"]] = encoded

    def replay(url, cancel, deadline):
        if url not in by_url:
            raise ValueError("discovery snapshot is missing a required catalog page")
        return by_url[url]

    expected = discover_regional(value["sourceId"], value["bounds"], fetch=replay)
    if canonical_bytes(value) != canonical_bytes(expected):
        raise ValueError("regional discovery claims differ from captured provider metadata")
    return value, hashlib.sha256(raw).hexdigest()


@dataclass(frozen=True)
class _NativeAsset:
    source_id: str
    url: str

    def validate_url(self, value):
        _allowed_url(value, REGIONAL_SOURCES[self.source_id].asset_prefixes)
        if value != self.url:
            raise ValueError("regional asset redirects cannot change native object identity")
        return value


def stage_regional_asset(cache: ElevationCache, discovery_path: Path, item_id: str) -> dict:
    discovery, discovery_sha = verified_discovery(discovery_path)
    selected = [a for a in discovery["assets"] if a["itemId"] == item_id]
    if len(selected) != 1:
        raise ValueError("select exactly one regional native asset by item ID")
    asset = selected[0]
    source = _NativeAsset(discovery["sourceId"], asset["url"])
    identity = {"kind": "bicino-regional-elevation-receipt-v1", "sourceId": source.source_id,
                "discoverySha256": discovery_sha, "itemId": item_id, "assetKey": asset["assetKey"],
                "url": asset["url"], "providerSha256": asset["providerSha256"]}
    key = hashlib.sha256(canonical_bytes(identity)).hexdigest()
    receipt_path = cache.root / "receipts" / ("regional-" + key + ".json")
    with cache._lock(key):
        if receipt_path.exists() or receipt_path.is_symlink():
            if receipt_path.is_symlink() or receipt_path.stat().st_size > 16384:
                raise ValueError("invalid regional elevation receipt")
            receipt = loads_strict_json(receipt_path.read_bytes(), description="regional elevation receipt")
            if (not isinstance(receipt, dict) or set(receipt) != set(identity) | {"bytes", "sha256"}
                    or any(receipt.get(k) != v for k, v in identity.items())
                    or (asset["providerSha256"] is not None and receipt["sha256"] != asset["providerSha256"])):
                raise ValueError("regional receipt has a different source identity")
            cache.verify(receipt)
            return receipt
        with tempfile.TemporaryDirectory(prefix="regional-tile-", dir=cache.root) as tmp:
            staged = Path(tmp) / "tile.tif"
            size, digest = cache._download(source, asset["url"], MAX_TILE_BYTES, staged,
                                           expected_sha256=asset["providerSha256"])
            with staged.open("rb") as stream:
                if stream.read(4) not in (b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+"):
                    raise ValueError("regional native asset is not a TIFF")
            target = cache.root / "blobs" / (digest + ".tif")
            receipt = {**identity, "bytes": size, "sha256": digest}
            if target.exists() or target.is_symlink():
                cache.verify(receipt)
            else:
                os.replace(staged, target)
                _sync_directory(target.parent)
            staged_receipt = Path(tmp) / "receipt.json"
            with staged_receipt.open("xb") as stream:
                stream.write(canonical_bytes(receipt))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(staged_receipt, receipt_path)
            _sync_directory(receipt_path.parent)
            return receipt
