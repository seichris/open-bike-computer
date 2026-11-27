#!/usr/bin/env python3
"""Elevation tiles kept in a storage bucket: restore them, check them, pack them.

A record under `releases/` pins one bucket's content: for each tile set the
SHA-256 of its `elevation-manifest.json` and of its cell list, and for each
tar file its size and SHA-256. Nothing is taken on the bucket's own word.

`restore` puts a set into an empty directory:

1. `meta.tar` must have its pinned size and SHA-256. Its
   `elevation-manifest.json` must hash to the record's `manifestSha256`, and
   `cells.txt` to the `cellListSha256` of the record and of the manifest.
   Every cell must have a receipt that names the tile `cells.txt` names.
2. Every band's tar must have its pinned size and SHA-256. Each tile in it is
   unpacked and hashed and must match its line in `cells.txt` before it is
   written. A member that is not a tile of that band stops the restore.
3. No cell may be missing or extra.

The set is assembled in `DIR.restoring` beside its directory and moved there
in one step once all of it has passed. A restore that fails removes what it
assembled and leaves the directory as it was, so the caller can build the
tiles instead. A restore that is killed keeps its finished bands for the next
attempt. `build_elevation.py` then finds a receipt for every restored cell
and builds none of them.

The builder reads the bucket as its service account, with a token from the
metadata server. The token goes to Google's address and nowhere else;
`--endpoint`, for rehearsals, gets none.

`compare` tells, after the build, whether a restored set is still the one the
record pins. `verify` checks the bucket against the record and keeps nothing.
`pack` writes a set's tar files and a record, for a rehearsal or before a new
set is uploaded.

Only the standard library is used: this runs on the bare builder.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import multiprocessing
import os
import re
import shutil
import sys
import tarfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import zlib
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "bicino-routing-elevation-cache-v1"
REPORT_SCHEMA = "bicino-elevation-restore-v1"
MANIFEST_SCHEMA = "bicino-valhalla-elevation-v1"
RECEIPT = "restore.json"
GOOGLE = "https://storage.googleapis.com"
METADATA_TOKEN = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
CHUNK = 4 << 20
ATTEMPTS = 6
TIMEOUT = 120
# An unpacked tile is 3601 x 3601 posts of two bytes, 26 MB. Nothing else is unpacked.
MAX_TILE = 64 << 20
MAX_SMALL_FILE = 64 << 20
# Restore exits with this when a set was not restored and must be built instead.
NOT_RESTORED = 3

HEX = re.compile(r"[0-9a-f]{64}")
BAND_SHARD = re.compile(r"([NS]\d)\.tar")
BAND_DIRECTORY = re.compile(r"[NS]\d\d")
TILE = re.compile(r"([NS]\d\d)/(\1[EW]\d{3})\.hgt\.gz")
CELL_LINE = re.compile(r"([NS]\d\d[EW]\d{3}) ([0-9a-f]{64})")
RECEIPT_FILE = re.compile(r"receipts/([NS]\d\d[EW]\d{3})\.json")
INDEX_FILE = re.compile(r"index/[A-Za-z0-9][A-Za-z0-9._-]*")
META_FILES = ("cells.txt", "elevation-manifest.json")


class CacheError(Exception):
    """The set cannot be restored; the message says why."""


class NotEmpty(CacheError):
    """The directory holds tiles already. `restored` tells whether this set was once restored into it."""

    def __init__(self, message, restored):
        super().__init__(message)
        self.restored = restored


def now_text():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def say(message):
    print(f"{now_text()} {message}", flush=True)


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_json(path, value):
    partial = path.with_name(f".{path.name}.partial")
    partial.write_text(json.dumps(value, indent=1) + "\n")
    os.replace(partial, path)


# The record ----------------------------------------------------------------


@dataclass(frozen=True)
class Record:
    name: str
    sha256: str
    bucket: str
    sets: dict


def record_problems(record):
    """Why the record cannot be used; empty when it can."""
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        return [f"its schema is not {SCHEMA}"]
    problems = []
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]", str(record.get("bucket"))):
        problems.append(f"bucket is not a bucket name: {record.get('bucket')!r}")
    sets = record.get("sets")
    if not isinstance(sets, dict) or not sets:
        return problems + ["it holds no sets"]
    for name, tiles in sets.items():
        where = f"set {name}"
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", name) or not isinstance(tiles, dict):
            problems.append(f"{where}: not a named set")
            continue
        if not re.fullmatch(r"(?:[a-z0-9][a-z0-9._-]*/)+", str(tiles.get("prefix"))):
            problems.append(f"{where}: prefix must be a path that ends in /")
        for key in ("manifestSha256", "cellListSha256"):
            if not HEX.fullmatch(str(tiles.get(key))):
                problems.append(f"{where}: {key} is not a SHA-256")
        cells, shards = tiles.get("cells"), tiles.get("shards")
        if type(cells) is not int or cells < 1:
            problems.append(f"{where}: cells must be a positive number")
        if not isinstance(shards, list) or not all(isinstance(shard, dict) for shard in shards):
            problems.append(f"{where}: shards must be a list")
            continue
        names = [shard.get("name") for shard in shards]
        if len(set(map(str, names))) != len(names) or names.count("meta.tar") != 1:
            problems.append(f"{where}: needs one meta.tar and every other tar once")
        for shard in shards:
            shard_name = str(shard.get("name"))
            if shard_name != "meta.tar" and not BAND_SHARD.fullmatch(shard_name):
                problems.append(f"{where}: {shard_name} is neither meta.tar nor a band such as N5.tar")
            if any(type(shard.get(key)) is not int or shard[key] < 1 for key in ("bytes", "files")):
                problems.append(f"{where}: {shard_name} needs its bytes and files")
            if not HEX.fullmatch(str(shard.get("sha256"))):
                problems.append(f"{where}: {shard_name} has no SHA-256")
        in_bands = [shard.get("files") for shard in shards if shard.get("name") != "meta.tar"]
        if all(type(files) is int for files in in_bands) and sum(in_bands) != cells:
            problems.append(f"{where}: the bands hold {sum(in_bands)} tiles for {cells} cells")
    return problems


def load_record(path):
    try:
        data = Path(path).read_bytes()
        record = json.loads(data)
    except (OSError, ValueError) as error:
        raise CacheError(f"cannot read the record {path}: {error}") from None
    problems = record_problems(record)
    if problems:
        raise CacheError(f"{Path(path).name} is not a usable record: {problems[0]}")
    return Record(Path(path).name, sha256_of(data), record["bucket"], record["sets"])


# The bucket ----------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the token to another address; it is an error instead."""

    def redirect_request(self, *args, **kwargs):
        return None


# No proxy either, whatever the environment names: the token and the
# metadata server's answer go to the address asked and nowhere else.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)


class Token:
    """A bearer token for Google's storage address, and for no other address.

    Read from `token_file` when one is given, as an operator does from a
    signed-in machine; otherwise from the metadata server, as the builder's
    service account.
    """

    def __init__(self, endpoint=GOOGLE, token_file=None, metadata=METADATA_TOKEN):
        self.wanted = endpoint == GOOGLE
        self.token_file = token_file
        self.metadata = metadata
        self.value, self.expires = None, 0.0

    def header(self, refresh=False):
        if not self.wanted:
            return {}
        if self.token_file is not None:
            try:
                return {"Authorization": f"Bearer {Path(self.token_file).read_text().strip()}"}
            except OSError as error:
                raise CacheError(f"cannot read the token file: {error}") from None
        if refresh or self.value is None or time.monotonic() > self.expires - 120:
            self.value, self.expires = self._from_metadata()
        return {"Authorization": f"Bearer {self.value}"}

    def _from_metadata(self):
        request = urllib.request.Request(self.metadata, headers={"Metadata-Flavor": "Google"})
        try:
            with _OPENER.open(request, timeout=10) as response:
                answer = json.loads(response.read())
            return answer["access_token"], time.monotonic() + float(answer.get("expires_in", 0))
        except urllib.error.HTTPError as error:
            error.close()
            if error.code == 404:
                raise CacheError("this machine has no service account: create the builder with "
                                 "provision.sh --cache-reader (see cache-access.sh)") from None
            raise CacheError(f"the metadata server gave no token: HTTP {error.code}") from None
        except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
            raise CacheError(f"the metadata server gave no token: {error}") from None


def object_url(endpoint, bucket, name):
    return f"{endpoint}/storage/v1/b/{bucket}/o/{urllib.parse.quote(name, safe='')}?alt=media"


def fetch_object(url, token, path, size, sha256, *, attempts=ATTEMPTS):
    """Download the object to `path`, which must end with the pinned size and SHA-256.

    A transfer that ends early is taken up where it stopped.
    """
    name = urllib.parse.unquote(urllib.parse.urlsplit(url).path.rpartition("/o/")[2])
    digest, held, refreshed, refresh = hashlib.sha256(), 0, False, False
    with path.open("wb") as out:
        for attempt in range(1, attempts + 1):
            headers = token.header(refresh)
            refresh = False
            if held:
                headers["Range"] = f"bytes={held}-"
            try:
                with _OPENER.open(urllib.request.Request(url, headers=headers), timeout=TIMEOUT) as response:
                    if held and response.status != 206:
                        # The whole object again: start over rather than append it.
                        out.seek(0)
                        out.truncate()
                        digest, held = hashlib.sha256(), 0
                    while True:
                        chunk = response.read(CHUNK)
                        if not chunk:
                            break
                        held += len(chunk)
                        if held > size:
                            raise CacheError(f"{name} is longer than its pinned {size} bytes")
                        out.write(chunk)
                        digest.update(chunk)
                if held == size:
                    break
                problem = f"the transfer ended at byte {held} of {size}"
            except urllib.error.HTTPError as error:
                error.close()
                if error.code == 401 and not refreshed:
                    refreshed = refresh = True
                    problem = "the token was refused once"
                elif error.code in (401, 403):
                    raise CacheError(f"may not read {name} (HTTP {error.code}): the builder's service account needs "
                                     "roles/storage.objectViewer on the bucket") from None
                elif error.code == 404:
                    raise CacheError(f"the bucket holds no {name}") from None
                elif error.code in (408, 429) or error.code >= 500:
                    problem = f"HTTP {error.code}"
                else:
                    raise CacheError(f"{name}: HTTP {error.code}") from None
            except (OSError, http.client.HTTPException) as error:
                problem = f"{type(error).__name__}: {error}"
            if attempt == attempts:
                raise CacheError(f"{name}: {problem}, after {attempts} attempts")
            time.sleep(min(60, 2 ** attempt))
    if digest.hexdigest() != sha256:
        raise CacheError(f"{name} is not the pinned file: SHA-256 {digest.hexdigest()}, the record has {sha256}")


# Restore -------------------------------------------------------------------


def members_of(tar_path, name, limit):
    """The tar's files as (name, content); anything but a plain file of at most `limit` bytes stops the restore."""
    try:
        with tarfile.open(tar_path, "r:") as archive:
            for member in archive:
                if member.isdir():
                    continue
                if not member.isreg() or member.size > limit:
                    raise CacheError(f"{name}: {member.name!r} is not a plain file of at most {limit} bytes")
                yield member.name, archive.extractfile(member).read()
    except (tarfile.TarError, EOFError) as error:
        raise CacheError(f"{name} is not a whole tar file: {error}") from None


def write_file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".partial")
    partial.write_bytes(data)
    os.replace(partial, path)


def unpacked_sha256(data, cell):
    unpacker = zlib.decompressobj(wbits=31)
    try:
        payload = unpacker.decompress(data, MAX_TILE)
    except zlib.error as error:
        raise CacheError(f"{cell} is not a gzipped tile: {error}") from None
    if unpacker.unconsumed_tail or not unpacker.eof or unpacker.unused_data:
        raise CacheError(f"{cell} is not one gzipped tile of at most {MAX_TILE} bytes")
    return sha256_of(payload)


def parse_cells(listing, where):
    cells = {}
    for line in listing.decode("ascii", "replace").splitlines():
        match = CELL_LINE.fullmatch(line)
        if match is None or match[1] in cells:
            raise CacheError(f"{where}: cells.txt has a line that is no cell, or a cell twice: {line[:80]!r}")
        cells[match[1]] = match[2]
    return cells


def restore_meta(tar_path, name, tiles, staging):
    """Unpack the set's manifest, cell list, receipts and source indexes; returns cell: tile SHA-256."""
    small, receipts, files = {}, {}, 0
    for member, data in members_of(tar_path, name, MAX_SMALL_FILE):
        files += 1
        receipt = RECEIPT_FILE.fullmatch(member)
        if receipt and receipt[1] not in receipts:
            receipts[receipt[1]] = data
        elif member in META_FILES and member not in small:
            small[member] = data
        elif not INDEX_FILE.fullmatch(member):
            raise CacheError(f"{name}: unexpected member {member!r}")
        write_file(staging / member, data)
    if files != tiles["shards_by_name"][name]["files"]:
        raise CacheError(f"{name} holds {files} files, the record has {tiles['shards_by_name'][name]['files']}")
    for member in META_FILES:
        if member not in small:
            raise CacheError(f"{name} holds no {member}")
    if sha256_of(small["elevation-manifest.json"]) != tiles["manifestSha256"]:
        raise CacheError(f"{name}: elevation-manifest.json is not the manifest the record pins")
    try:
        manifest = json.loads(small["elevation-manifest.json"])
    except ValueError:
        manifest = None
    if not isinstance(manifest, dict) or manifest.get("schema") != MANIFEST_SCHEMA:
        raise CacheError(f"{name}: elevation-manifest.json is not a {MANIFEST_SCHEMA} manifest")
    listed = sha256_of(small["cells.txt"])
    if not listed == tiles["cellListSha256"] == manifest.get("cellListSha256"):
        raise CacheError(f"{name}: cells.txt does not hash to the cellListSha256 of the record and the manifest")
    cells = parse_cells(small["cells.txt"], name)
    if not len(cells) == tiles["cells"] == manifest.get("cells"):
        raise CacheError(f"{name}: cells.txt lists {len(cells)} cells, the record has {tiles['cells']}")
    if set(receipts) != set(cells):
        raise CacheError(f"{name}: {len(set(cells) ^ set(receipts))} cells have a receipt or a line in cells.txt, not both")
    for cell, data in receipts.items():
        try:
            receipt = json.loads(data)
        except ValueError:
            receipt = None
        if not isinstance(receipt, dict) or receipt.get("cell") != cell or receipt.get("hgtSha256") != cells[cell]:
            raise CacheError(f"{name}: the receipt of {cell} does not name the tile cells.txt names")
    return cells


def restore_band(tar_path, name, files, cells, staging):
    """Check and write every tile of one band; `cells` are the band's own, cell: tile SHA-256."""
    band, written = name[:2], set()
    for member, data in members_of(tar_path, name, MAX_TILE):
        match = TILE.fullmatch(member)
        cell = match[2] if match else None
        if cell is None or not member.startswith(band) or cell not in cells or cell in written:
            raise CacheError(f"{name}: {member!r} is not a tile of this band that cells.txt lists once")
        if unpacked_sha256(data, cell) != cells[cell]:
            raise CacheError(f"{name}: the tile {cell} does not match its line in cells.txt")
        write_file(staging / member, data)
        written.add(cell)
    if len(written) != files or written != set(cells):
        raise CacheError(f"{name} holds {len(written)} tiles; the record has {files} and cells.txt "
                         f"{len(cells)} for this band")
    return len(written)


def _restore_shard(job):
    """One tar, downloaded, checked and unpacked; runs in a worker process."""
    url, token, shard, cells, staging = job
    started = time.monotonic()
    tar_path = staging / ".shards" / shard["name"]
    fetch_object(url, token, tar_path, shard["bytes"], shard["sha256"])
    count = restore_band(tar_path, shard["name"], shard["files"], cells, staging)
    write_json(staging / ".shards" / f"{shard['name']}.done", {"sha256": shard["sha256"], "tiles": count})
    tar_path.unlink()
    return shard["name"], shard["bytes"], count, round(time.monotonic() - started)


def tiles_on_disk(directory):
    return {path.name[:-len(".hgt.gz")] for band in directory.iterdir()
            if band.is_dir() and BAND_DIRECTORY.fullmatch(band.name) for path in band.glob("*.hgt.gz")}


def assemble(record, name, staging, *, endpoint, token, jobs, log, only=None):
    """Download and check the set's tars into `staging`; returns cell: tile SHA-256.

    `only` names the band tars to take, for a check of part of a set; without
    it every band is taken and no cell may then be missing or extra.
    """
    tiles = dict(record.sets[name])
    tiles["shards_by_name"] = {shard["name"]: shard for shard in tiles["shards"]}
    shards_dir = staging / ".shards"
    shards_dir.mkdir(parents=True, exist_ok=True)

    def url(shard):
        return object_url(endpoint, record.bucket, tiles["prefix"] + shard)

    meta = tiles["shards_by_name"]["meta.tar"]
    fetch_object(url("meta.tar"), token, shards_dir / "meta.tar", meta["bytes"], meta["sha256"])
    cells = restore_meta(shards_dir / "meta.tar", "meta.tar", tiles, staging)
    (shards_dir / "meta.tar").unlink()
    log(f"{name}: meta.tar holds the pinned manifest and {len(cells)} cells")

    by_band = {}
    for cell, digest in cells.items():
        by_band.setdefault(f"{cell[:2]}.tar", {})[cell] = digest
    bands = [shard for shard in tiles["shards"] if shard["name"] != "meta.tar"]
    without_shard = sorted(set(by_band) - {shard["name"] for shard in bands})
    if without_shard:
        raise CacheError(f"{name}: the record has no tar for {', '.join(without_shard)}")
    if only is not None:
        unknown = sorted(set(only) - {shard["name"] for shard in bands})
        if unknown:
            raise CacheError(f"{name}: the record has no band tar {', '.join(unknown)}")
        bands = [shard for shard in bands if shard["name"] in only]
    pending = []
    for shard in bands:
        done = read_json(shards_dir / f"{shard['name']}.done")
        if isinstance(done, dict) and done.get("sha256") == shard["sha256"]:
            log(f"{name}: {shard['name']} was restored by an earlier attempt")
        else:
            pending.append((url(shard["name"]), token, shard, by_band.get(shard["name"], {}), staging))
    if jobs > 1 and len(pending) > 1:
        # Fresh processes: a fork would copy whatever threads and locks the caller holds.
        with ProcessPoolExecutor(min(jobs, len(pending)), mp_context=multiprocessing.get_context("spawn")) as pool:
            try:
                for future in as_completed([pool.submit(_restore_shard, job) for job in pending]):
                    shard, size, count, seconds = future.result()
                    log(f"{name}: {shard} {size} bytes, {count} tiles checked, {seconds} s")
            except BaseException:
                # The tars already in flight finish; none is started after a failure.
                pool.shutdown(wait=True, cancel_futures=True)
                raise
    else:
        for job in pending:
            shard, size, count, seconds = _restore_shard(job)
            log(f"{name}: {shard} {size} bytes, {count} tiles checked, {seconds} s")

    # A killed attempt may have left a file it was still writing.
    for partial in staging.rglob("*.partial"):
        partial.unlink()
    if only is None:
        found = tiles_on_disk(staging)
        if found != set(cells):
            raise CacheError(f"{name}: {len(set(cells) - found)} cells are missing and {len(found - set(cells))} are extra")
    return cells


def restore_set(record, name, dest, *, endpoint=GOOGLE, token=None, jobs=6, log=say):
    """Put the record's set `name` into the empty directory `dest`; returns its restore receipt.

    Raises CacheError when the set cannot be restored. Then `dest` is as it
    was, and what was assembled beside it is still there for the caller to
    remove, or for the next attempt to finish.
    """
    tiles = record.sets[name]
    identity = {"set": name, "manifestSha256": tiles["manifestSha256"], "cellListSha256": tiles["cellListSha256"]}
    receipt = read_json(dest / RECEIPT)
    was_restored = isinstance(receipt, dict) and all(receipt.get(key) == value for key, value in identity.items())
    if was_restored:
        # A build may since have written tiles over the restored ones: some cells
        # again, or under other settings all of them.
        try:
            unchanged = sha256_of((dest / "cells.txt").read_bytes()) == tiles["cellListSha256"]
        except OSError:
            unchanged = False
        if unchanged:
            log(f"{name}: already restored into {dest} at {receipt.get('restoredAt')}")
            return receipt
    if dest.exists() and any(dest.iterdir()):
        raise NotEmpty(f"{dest} holds files that were not restored from this set; it is left alone", was_restored)
    started = time.monotonic()
    staging = staging_of(dest)
    # Bands an earlier, killed attempt finished are kept, if it restored this very set.
    if staging.exists() and read_json(staging / ".shards" / "state.json") != identity:
        shutil.rmtree(staging)
    (staging / ".shards").mkdir(parents=True, exist_ok=True)
    write_json(staging / ".shards" / "state.json", identity)
    cells = assemble(record, name, staging, endpoint=endpoint, token=token or Token(endpoint), jobs=jobs, log=log)
    shutil.rmtree(staging / ".shards")
    receipt = {
        "schema": REPORT_SCHEMA, **identity, "record": record.name, "recordSha256": record.sha256,
        "bucket": record.bucket, "prefix": tiles["prefix"], "cells": len(cells),
        "bytes": sum(shard["bytes"] for shard in tiles["shards"]),
        "seconds": round(time.monotonic() - started), "restoredAt": now_text(),
    }
    write_json(staging / RECEIPT, receipt)
    # One step: a rename replaces an empty directory and refuses any other.
    os.rename(staging, dest)
    log(f"{name}: restored {len(cells)} cells into {dest} in {receipt['seconds']} s")
    return receipt


def verify(record_path, name, work, *, only=None, endpoint=GOOGLE, token_file=None, jobs=6, log=say):
    """Check that the bucket still holds what the record pins, and keep nothing.

    Every tar of the set is downloaded and checked as a restore checks it, or
    only the bands of `only` with `meta.tar`. `work` needs room for them.
    """
    record = load_record(record_path)
    if name not in record.sets:
        raise CacheError(f"{record.name} holds no set {name}")
    staging = Path(work) / f"verify-{name}-{os.getpid()}"
    try:
        cells = assemble(record, name, staging, endpoint=endpoint, token=Token(endpoint, token_file), jobs=jobs,
                         log=log, only=only)
    except OSError as error:
        raise CacheError(f"{name}: {error}") from None
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    log(f"{name}: {'every tar' if only is None else 'meta.tar, ' + ', '.join(sorted(only))} of "
        f"gs://{record.bucket}/{record.sets[name]['prefix']} is as {record.name} pins it ({len(cells)} cells listed)")


def staging_of(dest):
    return dest.with_name(dest.name + ".restoring")


def restore(record_path, wanted, report_path=None, *, endpoint=GOOGLE, token_file=None, jobs=6, log=say):
    """Restore each (set, directory, required) of `wanted`; returns the report.

    A set that fails leaves its directory as it was and nothing beside it.
    """
    report = {"schema": REPORT_SCHEMA, "record": Path(record_path).name, "recordSha256": None,
              "bucket": None, "endpoint": endpoint, "sets": {}}

    def note(name, dest, entry):
        report["sets"][name] = {"directory": str(dest), **entry}
        if report_path:
            Path(report_path).parent.mkdir(parents=True, exist_ok=True)
            write_json(Path(report_path), report)

    try:
        record = load_record(record_path)
    except CacheError as error:
        for name, dest, _ in wanted:
            log(f"{name}: NOT restored: {error}")
            note(name, dest, {"restored": False, "kept": True, "reason": str(error)})
        return report
    report.update(recordSha256=record.sha256, bucket=record.bucket)
    earlier = read_json(report_path) if report_path else None
    if not isinstance(earlier, dict) or earlier.get("recordSha256") != record.sha256:
        earlier = {}
    token = Token(endpoint, token_file)
    for name, dest, required in wanted:
        dest = Path(dest)
        if name not in record.sets:
            # What an attempt under another record or radius assembled here is nobody's now.
            shutil.rmtree(staging_of(dest), ignore_errors=True)
            entry = {"restored": False, "kept": False, "reason": f"{record.name} holds no set {name}"}
            if required:
                log(f"{name}: NOT restored: {entry['reason']}")
        else:
            try:
                receipt = restore_set(record, name, dest, endpoint=endpoint, token=token, jobs=jobs, log=log)
                entry = {"restored": True, **{key: receipt.get(key) for key in (
                    "manifestSha256", "cellListSha256", "prefix", "cells", "bytes", "seconds", "restoredAt")}}
            except Exception as error:
                # The build that follows must not find half a set's bytes on its disk.
                shutil.rmtree(staging_of(dest), ignore_errors=True)
                reason = str(error)
                if not isinstance(error, (CacheError, OSError)):
                    # A fault of this tool, not of the bucket: say so, and show where.
                    traceback.print_exc()
                    reason = f"the restore tool failed: {type(error).__name__}: {error}"
                entry = {"restored": False, "kept": True, "reason": reason}
                before = earlier.get("sets", {}).get(name)
                # A later attempt of the same run finds the directory in use. What the
                # earlier attempt reported still holds: why the tiles were built, or
                # that they were restored and the build has written cells again since.
                if isinstance(error, NotEmpty) and isinstance(before, dict) and before.get("directory") == str(dest) \
                        and before.get("restored") in (False, error.restored):
                    entry = {key: value for key, value in before.items() if key != "directory"}
                if entry["restored"]:
                    log(f"{name}: restored by an earlier attempt; the build has written cells again since")
                else:
                    log(f"{name}: NOT restored: {entry['reason']}")
        note(name, dest, entry)
    return report


def failed_sets(report):
    """The sets the record keeps that were not restored."""
    return [name for name, entry in report["sets"].items() if not entry["restored"] and entry.get("kept", True)]


def compare(report_path, log=say):
    """After the build: is each restored set still the one the record pins?"""
    report = read_json(Path(report_path))
    if not isinstance(report, dict) or report.get("schema") != REPORT_SCHEMA:
        raise CacheError(f"no restore report at {report_path}")
    for name, entry in report["sets"].items():
        if not entry.get("restored"):
            continue
        directory = Path(entry["directory"])
        try:
            after = {"manifestSha256": sha256_of((directory / "elevation-manifest.json").read_bytes()),
                     "cellListSha256": sha256_of((directory / "cells.txt").read_bytes())}
        except OSError as error:
            raise CacheError(f"{name}: {error}") from None
        entry["afterBuild"] = after
        entry["tilesAsRecorded"] = after["cellListSha256"] == entry["cellListSha256"]
        entry["manifestAsRecorded"] = after["manifestSha256"] == entry["manifestSha256"]
        if not entry["tilesAsRecorded"]:
            log(f"{name}: the build wrote some cells again; the tiles are no longer the ones {report['record']} pins")
        elif not entry["manifestAsRecorded"]:
            log(f"{name}: the tiles are the recorded ones; the build wrote the manifest again as {after['manifestSha256']}")
        else:
            log(f"{name}: the tiles and the manifest are the recorded ones")
    write_json(Path(report_path), report)
    return report


# Pack ----------------------------------------------------------------------


def write_tar(path, source, members):
    """A tar of `members` (paths below `source`) that is the same bytes on every machine."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT) as archive:
        for member in members:
            info = tarfile.TarInfo(member)
            info.size, info.mode, info.mtime = (source / member).stat().st_size, 0o644, 0
            with (source / member).open("rb") as stream:
                archive.addfile(info, stream)
    sha256, md5 = hashlib.sha256(), hashlib.md5()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            sha256.update(chunk)
            md5.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size, "files": len(members),
            "sha256": sha256.hexdigest(), "md5": base64.b64encode(md5.digest()).decode()}


def pack_set(source, out, family, name):
    """Write the set's tars below `out/<prefix>`; returns its entry for the record."""
    manifest_bytes = (source / "elevation-manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    listing = (source / "cells.txt").read_bytes()
    if manifest.get("schema") != MANIFEST_SCHEMA or sha256_of(listing) != manifest.get("cellListSha256"):
        raise CacheError(f"{source} is not a finished tile set: its cells.txt and manifest do not agree")
    cells = parse_cells(listing, str(source))
    if tiles_on_disk(source) != set(cells):
        raise CacheError(f"{source}: the tiles on disk are not the cells of cells.txt")
    prefix = f"{family}/{name}-{sha256_of(manifest_bytes)[:12]}/"
    shards = []
    for band in sorted({cell[:2] for cell in cells}, key=lambda band: (band[0] != "N", band)):
        members = sorted(f"{cell[:3]}/{cell}.hgt.gz" for cell in cells if cell[:2] == band)
        shards.append(write_tar(out / prefix / f"{band}.tar", source, members))
    meta = sorted(f"receipts/{cell}.json" for cell in cells) + list(META_FILES)
    if (source / "index").is_dir():
        meta += sorted(f"index/{path.name}" for path in (source / "index").iterdir() if path.is_file())
    shards.append(write_tar(out / prefix / "meta.tar", source, meta))
    return {
        "prefix": prefix, "method": manifest.get("method"),
        "manifestSha256": sha256_of(manifest_bytes), "cellListSha256": manifest["cellListSha256"],
        "cells": len(cells), "tileBytes": manifest.get("fileBytes"),
        "sources": [{key: source_entry.get(key) for key in ("id", "indexSha256", "cells")}
                    for source_entry in manifest.get("sources", [])],
        "policySha256": (manifest.get("policy") or {}).get("sha256"), "runtime": manifest.get("runtime"),
        "shardBytes": sum(shard["bytes"] for shard in shards), "shards": shards,
    }


def pack(record_path, out, bucket, family, sets):
    record = {"schema": SCHEMA, "bucket": bucket, "storedAt": now_text()[:10],
              "sets": {name: pack_set(Path(source), Path(out), family, name) for name, source in sets}}
    problems = record_problems(record)
    if problems:
        raise CacheError(f"the packed sets do not make a usable record: {problems[0]}")
    write_json(Path(record_path), record)
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    restoring = commands.add_parser("restore", help="Restore sets of a record into empty directories")
    restoring.add_argument("--record", required=True, type=Path)
    restoring.add_argument("--set", dest="sets", action="append", nargs=2, metavar=("NAME", "DIR"), default=[],
                           help="A set the record must hold")
    restoring.add_argument("--set-if-kept", dest="optional", action="append", nargs=2, metavar=("NAME", "DIR"),
                           default=[], help="A set to restore when the record holds it")
    restoring.add_argument("--report", type=Path, help="Write what was restored, and why not, to this file")
    restoring.add_argument("--jobs", type=int, default=6, help="Tars downloaded and checked at once")
    restoring.add_argument("--endpoint", default=GOOGLE, help="For rehearsals: another address; it gets no token")
    restoring.add_argument("--token-file", type=Path,
                           help="A file with an access token, instead of the metadata server's")
    comparing = commands.add_parser("compare", help="After the build: are the restored sets still the recorded ones?")
    comparing.add_argument("--report", required=True, type=Path)
    checking = commands.add_parser("check", help="Check that a record is well formed")
    checking.add_argument("--record", required=True, type=Path)
    verifying = commands.add_parser("verify", help="Check the bucket against a record; nothing is kept")
    verifying.add_argument("--record", required=True, type=Path)
    verifying.add_argument("--set", dest="name", required=True, metavar="NAME")
    verifying.add_argument("--work", required=True, type=Path, help="A directory with room for the tars checked")
    verifying.add_argument("--band", dest="bands", action="append", metavar="TAR",
                           help="Only this band tar, such as S9.tar, with meta.tar; may be given again")
    verifying.add_argument("--jobs", type=int, default=6)
    verifying.add_argument("--endpoint", default=GOOGLE)
    verifying.add_argument("--token-file", type=Path)
    packing = commands.add_parser("pack", help="Write the tars and the record of finished tile sets")
    packing.add_argument("--record", required=True, type=Path, help="The record file to write")
    packing.add_argument("--out", required=True, type=Path, help="Where the tars go, below each set's prefix")
    packing.add_argument("--bucket", required=True)
    packing.add_argument("--family", default="copernicus-2021", help="First part of every prefix")
    packing.add_argument("--set", dest="sets", action="append", nargs=2, metavar=("NAME", "DIR"), required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "restore":
            if not 1 <= args.jobs <= 64:
                parser.error("--jobs must be between 1 and 64")
            wanted = [(name, directory, True) for name, directory in args.sets]
            wanted += [(name, directory, False) for name, directory in args.optional]
            if not wanted or any(not Path(directory).is_absolute() for _, directory, _ in wanted):
                parser.error("name at least one set, each with an absolute directory")
            report = restore(args.record, wanted, args.report, endpoint=args.endpoint.rstrip("/"),
                             token_file=args.token_file, jobs=args.jobs)
            missing = failed_sets(report) + [name for name, _, required in wanted
                                             if required and not report["sets"][name].get("kept", True)]
            return NOT_RESTORED if missing else 0
        if args.command == "compare":
            compare(args.report)
        elif args.command == "verify":
            verify(args.record, args.name, args.work, only=args.bands, endpoint=args.endpoint.rstrip("/"),
                   token_file=args.token_file, jobs=args.jobs)
        elif args.command == "check":
            record = load_record(args.record)
            print(f"{record.name}: gs://{record.bucket}, sets {', '.join(record.sets)}")
        else:
            record = pack(args.record, args.out, args.bucket, args.family, args.sets)
            print(f"{args.record}: {', '.join(record['sets'])}")
    except CacheError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
