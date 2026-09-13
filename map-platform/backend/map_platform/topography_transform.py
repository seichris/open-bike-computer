"""Pinned, offline coordinate operations for regional height normalization.

Operator contracts describe reviewed operations; this code never chooses a
datum conversion by country name or resolves an approximate EPSG operation.
No pipeline can reference an unlisted/optional/remote grid. Private verified
copies keep grid bytes stable for the lifetime of the PROJ transformer.
"""
from __future__ import annotations

import hashlib
import math
import re
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .strict_json import loads_strict_json
from .topography_discovery import _bounds

MAX_GRID_BYTES = 256 * 1024 * 1024
MAX_TOTAL_GRID_BYTES = 512 * 1024 * 1024
MAX_CONTRACT_BYTES = 64 * 1024
SHA = re.compile(r"[a-f0-9]{64}")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
OPS = {"pipeline", "noop", "unitconvert", "vgridshift", "hgridshift", "utm", "tmerc", "lcc",
       "somerc", "longlat", "cart", "helmert", "push", "pop", "axisswap"}
PARAMETERS = {"proj", "step", "inv", "ellps", "a", "b", "rf", "f", "e", "es", "R", "zone", "south",
              "lat_0", "lat_1", "lat_2", "lat_ts", "lon_0", "k", "k_0", "x_0", "y_0", "units", "to_meter",
              "xy_in", "xy_out", "z_in", "z_out", "grids", "multiplier", "order", "x", "y", "z",
              "rx", "ry", "rz", "s", "convention", "exact", "v_1", "v_2", "v_3"}
# Time-dependent operations need a versioned observation-epoch contract. Never
# let PROJ choose a default epoch for a regional dataset whose epoch is unknown.


def _sha(value):
    if not isinstance(value, str) or SHA.fullmatch(value) is None:
        raise ValueError("invalid transformation evidence checksum")
    return value


def pipeline_grid_names(pipeline: str) -> set[str]:
    if not isinstance(pipeline, str) or not 1 <= len(pipeline) <= 8192:
        raise ValueError("invalid explicit PROJ pipeline")
    if not pipeline.startswith("+proj="):
        raise ValueError("operation must be an explicit PROJ pipeline, not a database lookup")
    grids = set()
    for token in pipeline.split():
        if re.fullmatch(r"\+[A-Za-z][A-Za-z0-9_]*(?:=[A-Za-z0-9_.{},:+-]+)?", token) is None:
            raise ValueError("unsupported PROJ token or file reference")
        key, _, value = token[1:].partition("=")
        if key not in PARAMETERS:
            raise ValueError("implicit or unsupported PROJ parameter is forbidden")
        if key == "proj" and value not in OPS:
            raise ValueError("unsupported explicit PROJ operation")
        if key == "grids":
            for name in value.split(","):
                if not (name.startswith("{") and name.endswith("}") and NAME.fullmatch(name[1:-1])):
                    raise ValueError("every transformation grid must be an explicit pinned placeholder")
                grids.add(name[1:-1])
        elif "{" in value or "}" in value:
            raise ValueError("grid placeholders are allowed only in +grids")
    return grids


def load_transform_contract(path: Path) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_CONTRACT_BYTES:
        raise ValueError("invalid or oversized regional transform contract")
    raw = path.read_bytes()
    value = loads_strict_json(raw, description="regional transform contract")
    fields = {"schemaVersion", "sourceId", "assetSha256", "sourceReviewSha256", "sourceVerticalDatum",
              "targetVerticalDatum", "native", "areaOfUse", "horizontalPipeline", "verticalPipeline",
              "grids", "productionApproved"}
    if (not isinstance(value, dict) or set(value) != fields or type(value["schemaVersion"]) is not int
            or value["schemaVersion"] != 1 or value["productionApproved"] is not False
            or value["targetVerticalDatum"] != "EPSG:3855"):
        raise ValueError("unsupported regional transform contract or production approval")
    if not isinstance(value["sourceId"], str) or NAME.fullmatch(value["sourceId"]) is None:
        raise ValueError("invalid regional source identity")
    _sha(value["assetSha256"])
    _sha(value["sourceReviewSha256"])
    if not isinstance(value["sourceVerticalDatum"], str) or not 1 <= len(value["sourceVerticalDatum"]) <= 128:
        raise ValueError("source vertical datum must be explicit")
    native = value["native"]
    if (not isinstance(native, dict) or set(native) != {"horizontalEpsg", "dtype", "noData", "bandUnits"}
            or type(native["horizontalEpsg"]) is not int or not 1 <= native["horizontalEpsg"] <= 999999
            or native["dtype"] not in ("int16", "int32", "float32", "float64")
            or native["bandUnits"] not in (None, "m", "metre", "meter")):
        raise ValueError("unsupported native regional height contract")
    nodata = native["noData"]
    if nodata is not None and nodata != "nan" and (type(nodata) not in (int, float) or not math.isfinite(nodata)):
        raise ValueError("invalid explicit native no-data value")
    _bounds(value["areaOfUse"])
    used = set()
    for key in ("horizontalPipeline", "verticalPipeline"):
        operation = value[key]
        if not isinstance(operation, dict) or set(operation) != {"proj", "sha256"}:
            raise ValueError("operation requires its exact pipeline checksum")
        used.update(pipeline_grid_names(operation["proj"]))
        if hashlib.sha256(operation["proj"].encode()).hexdigest() != _sha(operation["sha256"]):
            raise ValueError("transformation pipeline checksum mismatch")
    vertical = value["verticalPipeline"]["proj"]
    if value["sourceVerticalDatum"] != "EPSG:3855" and "+proj=vgridshift" not in vertical.split():
        raise ValueError("non-EGM2008 heights require an explicit vertical grid operation")
    entries = value["grids"]
    if not isinstance(entries, list) or len(entries) > 16:
        raise ValueError("invalid transformation grid inventory")
    names, total = set(), 0
    for grid in entries:
        if (not isinstance(grid, dict) or set(grid) != {"name", "sha256", "bytes"}
                or not isinstance(grid["name"], str) or NAME.fullmatch(grid["name"]) is None
                or grid["name"] in names or grid["name"] in (".", "..")
                or type(grid["bytes"]) is not int or not 1 <= grid["bytes"] <= MAX_GRID_BYTES):
            raise ValueError("invalid transformation grid entry")
        _sha(grid["sha256"])
        total += grid["bytes"]
        names.add(grid["name"])
    if names != used or total > MAX_TOTAL_GRID_BYTES:
        raise ValueError("transformation grid inventory differs from pipeline or exceeds bound")
    return {**value, "contractSha256": hashlib.sha256(raw).hexdigest()}


class RegionalTransform:
    def __init__(self, contract, horizontal, vertical):
        self.contract, self.horizontal, self.vertical = contract, horizontal, vertical
        self.closed = False

    def close(self):
        self.closed = True
        self.horizontal = self.vertical = None

    def _inside(self, longitude, latitude):
        import numpy as np
        if self.closed:
            raise ValueError("regional transformation context is closed")
        west, south, east, north = self.contract["areaOfUse"]
        lon, lat = np.asarray(longitude), np.asarray(latitude)
        if not np.all(np.isfinite(lon) & np.isfinite(lat) & (lon >= west) & (lon <= east) & (lat >= south) & (lat <= north)):
            raise ValueError("coordinates are outside the reviewed transformation area")

    def native_xy(self, longitude, latitude):
        import numpy as np
        self._inside(longitude, latitude)
        x, y = self.horizontal.transform(np.asarray(longitude).tolist(), np.asarray(latitude).tolist(), errcheck=True)
        if not np.all(np.isfinite(x)) or not np.all(np.isfinite(y)):
            raise ValueError("regional horizontal transform failed")
        return x, y

    def egm2008(self, longitude, latitude, height):
        import numpy as np
        self._inside(longitude, latitude)
        x, y, z = self.vertical.transform(np.asarray(longitude).tolist(), np.asarray(latitude).tolist(),
                                         np.asarray(height).tolist(), errcheck=True)
        if (not np.all(np.isfinite(x)) or not np.all(np.isfinite(y)) or not np.all(np.isfinite(z))
                or np.any(np.abs(np.asarray(x) - longitude) > 1e-9)
                or np.any(np.abs(np.asarray(y) - latitude) > 1e-9)
                or np.any(np.asarray(z) < -12000) or np.any(np.asarray(z) > 10000)):
            raise ValueError("vertical operation changed horizontal coordinates or returned invalid heights")
        return z


@contextmanager
def open_regional_transform(contract: dict, grid_directory: Path, cancel=lambda: None):
    import pyproj

    # Do not toggle process-global network state for other users of PROJ. The
    # transformer must have been constructed in an offline context already.
    if pyproj.network.is_network_enabled():
        raise ValueError("PROJ network must be disabled for pinned transformations")
    with tempfile.TemporaryDirectory(prefix="bicino-transform-") as tmp:
        private = Path(tmp)
        resolved = {}
        for grid in contract["grids"]:
            cancel()
            source = grid_directory / grid["name"]
            if source.is_symlink() or not source.is_file() or source.stat().st_size != grid["bytes"]:
                raise ValueError("missing or changed pinned transformation grid")
            destination = private / grid["name"]
            digest, size = hashlib.sha256(), 0
            with source.open("rb") as stream, destination.open("xb") as output:
                while chunk := stream.read(1024 * 1024):
                    cancel()
                    size += len(chunk)
                    if size > grid["bytes"]:
                        raise ValueError("transformation grid grew during snapshot")
                    digest.update(chunk)
                    output.write(chunk)
            if size != grid["bytes"] or digest.hexdigest() != grid["sha256"]:
                raise ValueError("transformation grid checksum mismatch")
            resolved[grid["name"]] = destination.as_posix()
        transformers = []
        for key in ("horizontalPipeline", "verticalPipeline"):
            pipeline = contract[key]["proj"]
            for name, path in resolved.items():
                pipeline = pipeline.replace("{" + name + "}", path)
            transformer = pyproj.Transformer.from_pipeline(pipeline)
            if transformer.is_network_enabled:
                raise ValueError("network-enabled PROJ transformation is forbidden")
            transformers.append(transformer)
        context = RegionalTransform(contract, *transformers)
        try:
            yield context
        finally:
            context.close()
