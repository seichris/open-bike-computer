#!/usr/bin/env python3
"""Valhalla's tagging rules with every bridge marked as a bridge.

Valhalla grades a bridge from the heights at its two ends and every other
edge from the terrain under it. Its rules call a way a bridge only when
`bridge` is `yes` or `1`. A bascule bridge tagged `bridge=movable`, a
`viaduct` or a `boardwalk` is then graded from what lies below the deck. A
surface model holds the deck, so that went unnoticed. A terrain model such
as USGS 3DEP holds the water or the ground under it: on 2026-11-26 the
Michigan Avenue bridge in Chicago read 12% down and up.

The pinned image carries the rules, graph.lua, inside valhalla_build_tiles.
This writes them out with one line changed, so that every `bridge` value but
`no` is a bridge, and build_graph.py --all-bridges points Valhalla at the
result. The rules are checked against the SHA-256 of the image they were
read from, so another image stops the build until the change is reviewed
for it.

    python3 graph_lua.py /usr/local/bin/valhalla_build_tiles /work/graph.lua

It runs inside the build container, with the image's own Python.
"""

import hashlib
import sys
from pathlib import Path

# graph.lua of ghcr.io/valhalla/valhalla-scripted@sha256:b523b803..., Valhalla 3.9.2.
GRAPH_LUA_SHA256 = "e594750d6dd407a55d627a5165da0901b7c1900411de96326bf2d4c1e7b2fe6e"
BRIDGE_RULE = b'  kv["bridge"] = bridge[kv["bridge"]] or "false"\n'
# The table still answers yes, 1 and no; any other value that is present counts as a bridge.
ALL_BRIDGES_RULE = b'  kv["bridge"] = bridge[kv["bridge"]] or (kv["bridge"] and "true") or "false"\n'


def embedded_lua(binary):
    """The rules as the binary holds them: one NUL-terminated string."""
    at = binary.find(BRIDGE_RULE)
    if at < 0:
        raise ValueError("the binary holds no graph.lua with the known bridge rule")
    return binary[binary.rfind(b"\0", 0, at) + 1:binary.index(b"\0", at)]


def all_bridges_lua(binary, expected_sha256=GRAPH_LUA_SHA256):
    lua = embedded_lua(binary)
    found = hashlib.sha256(lua).hexdigest()
    if found != expected_sha256:
        raise ValueError(f"graph.lua is {found}, not the {expected_sha256} this change was written for")
    if lua.count(BRIDGE_RULE) != 1:
        raise ValueError("graph.lua holds the bridge rule more than once")
    return lua.replace(BRIDGE_RULE, ALL_BRIDGES_RULE)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: graph_lua.py VALHALLA_BUILD_TILES OUT")
    lua = all_bridges_lua(Path(sys.argv[1]).read_bytes())
    with open(sys.argv[2], "xb") as stream:
        stream.write(lua)
    print(f"graph.lua with every bridge: {len(lua)} bytes, sha256 {hashlib.sha256(lua).hexdigest()}", flush=True)


if __name__ == "__main__":
    main()
