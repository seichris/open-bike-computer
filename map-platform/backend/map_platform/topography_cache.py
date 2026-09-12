"""Bounded operator-side DEM acquisition with immutable, rehashed receipts."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import tempfile
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Callable

from .strict_json import loads_strict_json
from .topography_sources import ElevationSource, SHA256, parse_tile_index

MAX_TILE_BYTES = 128 * 1024 * 1024
MIN_FREE_BYTES = 256 * 1024 * 1024


def file_sha256(path: Path, cancellation_check: Callable[[], None] = lambda: None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            cancellation_check()
            digest.update(chunk)
    return digest.hexdigest()


def _sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class _SourceRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def __init__(self, source: ElevationSource):
        self.source = source

    def redirect_request(self, request, response, code, message, headers, newurl):
        # A redirect is not permission to switch datasets or even tile objects.
        self.source.validate_url(newurl)
        if newurl != request.full_url:
            raise ValueError("elevation object redirects are not permitted")
        return super().redirect_request(request, response, code, message, headers, newurl)


class ElevationCache:
    def __init__(self, root: Path, *, opener=None, cancellation_check=lambda: None):
        self.root = root
        self.opener = opener
        self.cancel = cancellation_check
        root.mkdir(parents=True, exist_ok=True)
        for name in ("indexes", "blobs", "receipts", "locks"):
            (root / name).mkdir(exist_ok=True)

    @contextmanager
    def _lock(self, key: str):
        # Nonblocking acquisition permits cancellation while another job stages.
        with (self.root / "locks" / (key + ".lock")).open("a") as lock:
            while True:
                self.cancel()
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def _download(self, source: ElevationSource, url: str, maximum: int, destination: Path,
                  expected_sha256: str | None = None, expected_bytes: int | None = None) -> tuple[int, str]:
        source.validate_url(url)
        self.cancel()
        if shutil.disk_usage(self.root).free < maximum + MIN_FREE_BYTES:
            raise ValueError("insufficient elevation staging space")
        opener = self.opener or urllib.request.build_opener(_SourceRedirects(source)).open
        request = urllib.request.Request(url, headers={"Accept-Encoding": "identity", "User-Agent": "Bicino-Elevation/1"})
        digest, count, started = hashlib.sha256(), 0, time.monotonic()
        with opener(request, timeout=20) as response:
            if response.status != 200 or response.geturl() != url:
                raise ValueError("elevation download returned an unexpected response")
            length = response.headers.get("Content-Length")
            if length is not None and (not length.isdecimal() or not 0 < int(length) <= maximum):
                raise ValueError("elevation download length exceeds bound")
            if response.headers.get("Content-Encoding", "identity") != "identity":
                raise ValueError("compressed elevation transport is not supported")
            with destination.open("xb") as output:
                while True:
                    self.cancel()
                    if time.monotonic() - started > 600:
                        raise TimeoutError("elevation download deadline exceeded")
                    chunk = response.read(min(1024 * 1024, maximum - count + 1))
                    if not chunk:
                        break
                    count += len(chunk)
                    if count > maximum:
                        raise ValueError("elevation download exceeds bound")
                    if shutil.disk_usage(self.root).free < len(chunk) + MIN_FREE_BYTES:
                        raise ValueError("insufficient elevation staging space")
                    digest.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
        actual = digest.hexdigest()
        if (count == 0 or (length is not None and count != int(length))
                or (expected_bytes is not None and count != expected_bytes)
                or (expected_sha256 is not None and actual != expected_sha256)):
            raise ValueError("elevation download does not match its receipt")
        return count, actual

    def index(self, source: ElevationSource) -> frozenset[tuple[int, int]]:
        target = self.root / "indexes" / (source.index_sha256 + ".txt")
        with self._lock(source.index_sha256):
            if not target.exists():
                with tempfile.TemporaryDirectory(prefix="index-", dir=self.root) as tmp:
                    staged = Path(tmp) / "index.txt"
                    self._download(source, source.index_url, source.index_bytes, staged,
                                   source.index_sha256, source.index_bytes)
                    parse_tile_index(source, staged.read_bytes())
                    os.replace(staged, target)
                    _sync_directory(target.parent)
            if target.is_symlink() or target.stat().st_size != source.index_bytes:
                raise ValueError("invalid cached elevation index")
            return parse_tile_index(source, target.read_bytes())

    def stage(self, source: ElevationSource, cell: tuple[int, int]) -> dict:
        if cell not in self.index(source):
            raise ValueError("elevation tile is absent from the pinned index")
        url = source.tile_url(*cell)
        key = hashlib.sha256((source.id + "\n" + source.index_sha256 + "\n" + url).encode()).hexdigest()
        receipt_path = self.root / "receipts" / (key + ".json")
        with self._lock(key):
            if receipt_path.exists():
                if receipt_path.is_symlink() or receipt_path.stat().st_size > 4096:
                    raise ValueError("invalid elevation receipt")
                receipt = loads_strict_json(receipt_path.read_bytes(), description="elevation receipt")
                if not isinstance(receipt, dict) or set(receipt) != {"sourceId", "indexSha256", "url", "bytes", "sha256", "cell"}:
                    raise ValueError("invalid elevation receipt fields")
                if (receipt["sourceId"] != source.id or receipt["indexSha256"] != source.index_sha256
                        or receipt["url"] != url or receipt["cell"] != list(cell)
                        or not isinstance(receipt["cell"], list)
                        or any(type(value) is not int for value in receipt["cell"])):
                    raise ValueError("elevation receipt has different source authority")
                self.verify(receipt)
                return receipt
            with tempfile.TemporaryDirectory(prefix="tile-", dir=self.root) as tmp:
                staged = Path(tmp) / "tile.tif"
                size, digest = self._download(source, url, MAX_TILE_BYTES, staged)
                with staged.open("rb") as file:
                    if file.read(4) not in (b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+"):
                        raise ValueError("elevation object is not a TIFF")
                target = self.root / "blobs" / (digest + ".tif")
                if target.exists():
                    if target.is_symlink() or file_sha256(target, self.cancel) != digest:
                        raise ValueError("corrupt immutable elevation blob")
                else:
                    os.replace(staged, target)
                    _sync_directory(target.parent)
                receipt = {"sourceId": source.id, "indexSha256": source.index_sha256,
                           "url": url, "bytes": size, "sha256": digest, "cell": list(cell)}
                staged_receipt = Path(tmp) / "receipt.json"
                with staged_receipt.open("x") as output:
                    json.dump(receipt, output, sort_keys=True, separators=(",", ":"))
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(staged_receipt, receipt_path)
                _sync_directory(receipt_path.parent)
                return receipt

    def verify(self, receipt: dict) -> Path:
        digest, size = receipt.get("sha256"), receipt.get("bytes")
        if (not isinstance(digest, str) or SHA256.fullmatch(digest) is None
                or type(size) is not int or not 0 < size <= MAX_TILE_BYTES):
            raise ValueError("invalid elevation blob receipt")
        path = self.root / "blobs" / (digest + ".tif")
        if path.is_symlink() or path.stat().st_size != size or file_sha256(path, self.cancel) != digest:
            raise ValueError("cached elevation blob does not match its receipt")
        return path
