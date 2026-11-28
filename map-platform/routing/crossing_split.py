#!/usr/bin/env python3
"""Grade the road over a crossing from its ends, as Valhalla grades a bridge.

A lidar terrain model holds the ground under a bridge deck and may cut a
stream's channel through the fill a road crosses it on, so a road reads a
false step where it leaves a bridge or crosses a culvert (see
crossing_steps.py). Valhalla grades a bridge, tunnel or ferry edge from the
terrain at its two ends and clamps its grade to 3%; every other edge it
samples every 60 m. This step makes the stretch of road over the low point
such an edge.

For every site of crossing_steps.py's site files, the road's profile is
read from `--elevation` as Valhalla reads it and bridged as
crossing_steps.py bridges it: the upper convex hull. A site is fixed where
the road reads a false step (30% or more over 30 m near it, 20% or less
bridged within 75 m), or where it reads at least 12%, at least 8 points less
bridged and at most 20%, bridged within 75 m of a bridge's ends or 45 m of a
crossing without one; in both cases the line must lift it by at least 2 m
somewhere (crossing_steps.fix_reach). Its road is then cut at new nodes where the line
meets solid ground on either side, and the stretch between them, from the
crossing or the bridge's end out to that ground, is tagged `bridge=yes` and
`bicino:interpolated=crossing`. The terrain itself is not changed, so a road
that passes under the bridge or along the stream keeps the ground's heights.

A cut way keeps its id for its first piece; the others take new ids from
WAY_BASE, and new nodes from NODE_BASE. Every relation that holds a cut way
holds all its pieces in its place, except a turn restriction, which keeps
the one piece that holds its via node or an end of its via way. No cut
falls on a restriction's via node or the end of its via way, and a via way
is never cut, so that piece is always one. The changes are written as an
osmChange file and applied with `osmium apply-changes`, so that a planet
is rewritten by osmium, not by Python. Modified objects get the next
version, so that the change wins.

    python crossing_split.py --roads "$scratch/pittsburgh/roads.osm.pbf" --sites "$scratch/pittsburgh/sites.npz" \\
        --elevation "$scratch/dem/pittsburgh/hybrid" --out "$scratch/pittsburgh/roads-crossings.osm.pbf"

build_graph.py --crossings runs it on the roads it builds from.
"""

import argparse
import hashlib
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.sax.saxutils import quoteattr

ROUTING = Path(__file__).resolve().parent
sys.path.insert(0, str(ROUTING))

import crossing_steps  # noqa: E402

SCHEMA = "bicino-crossing-split-v1"
TAG = "bicino:interpolated"
TAG_VALUE = "crossing"
# New objects take ids far above OpenStreetMap's: nodes are near 1.4e10, ways near 1.5e9 (2026).
NODE_BASE = 900_000_000_000
WAY_BASE = 9_000_000_000
# A cut point further than this from its way is not on it; one this close to a node cuts there.
CUT_DISTANCE = 5.0
ON_NODE = 1.0
# A piece whose middle lies this close to a bridged stretch is graded from its ends.
INSIDE = 3.0


def metres(lon, lat, lat0):
    return (lon * crossing_steps.METRES_PER_DEGREE_LONGITUDE * math.cos(math.radians(lat0)),
            lat * crossing_steps.METRES_PER_DEGREE_LATITUDE)


def stretches(site_files, source, rule, jobs=6, log=print):
    """The stretches to grade from their ends: one per side of every fixed site.

    Each is (way ids, lons, lats, starts at a node): the side's points from the crossing or the bridge's
    end out to the first point on solid ground, and the OSM way each lies on.
    """
    import numpy as np

    loaded, lons, lats, flags, ways, total = [], [], [], [], [], 0
    for path in site_files:
        meta, site_lons, site_lats, site_flags, site_ways, offsets = crossing_steps.load_sites(path)
        if site_ways is None:
            raise ValueError(f"{path} names no ways: write it again with crossing_steps.py sites")
        loaded.append((meta, offsets, total))
        lons.append(site_lons)
        lats.append(site_lats)
        flags.append(site_flags)
        ways.append(site_ways)
        total += len(site_lons)
    if not total:
        # No site anywhere, as in a sample with no crossing: nothing to grade.
        return [], []
    lons, lats, flags, ways = (np.concatenate(values) for values in (lons, lats, flags, ways))
    heights, _ = crossing_steps.sample_heights(source, lons, lats, jobs=jobs, log=log)
    found, fixed, seen = [], [], set()
    for meta, offsets, base in loaded:
        for record in meta["sites"]:
            key = crossing_steps.site_key(record)
            if key in seen:
                continue
            seen.add(key)
            side = record["sideA"]
            a = slice(base + offsets[side], base + offsets[side + 1])
            b = slice(base + offsets[side + 1], base + offsets[side + 2])
            lift = crossing_steps.site_lift(record, heights[a], heights[b], flags[a], flags[b], **rule)
            if lift is None:
                continue
            fixed.append({key_: record.get(key_) for key_ in ("kind", "way", "lon", "lat", "name", "group")}
                         | {key_: lift[2][key_] for key_ in ("grade", "bridgedGrade", "dip")})
            crossing = record["span"] == crossing_steps.SPAN_NONE
            for part, lifted in ((a, lift[0]), (b, lift[1])):
                where = np.flatnonzero(~np.isnan(lifted))
                if not len(where) and not crossing:
                    continue
                # A crossing lifted on one side only is cut at the crossing itself on the other.
                anchor = min(int(where[-1]) + 1, len(lifted) - 1) if len(where) else 0
                index = np.arange(part.start, part.stop)[:anchor + 1]
                if not ways[index].any():
                    # A side of one point where the road ends at the crossing: nothing to cut on it.
                    continue
                found.append((ways[index], lons[index], lats[index], record["span"] != crossing_steps.SPAN_NONE))
    return found, fixed


def plan_ways(found):
    """Per way: the points to cut it at, and the bridged stretches it lies on."""
    plans = {}
    for way_ids, lons, lats, at_node in found:
        stretch = (lons, lats)
        for way in {int(way) for way in way_ids if way}:
            plans.setdefault(way, {"cuts": [], "stretches": []})["stretches"].append(stretch)
        # The stretch ends on solid ground: its way is cut there.
        if way_ids[-1]:
            plans[int(way_ids[-1])]["cuts"].append((float(lons[-1]), float(lats[-1])))
        # A bridge's end is a node; where its approach runs on past it, the approach is cut there too.
        # A crossing's first point lies between nodes and is no cut.
        if at_node and way_ids[0]:
            plans[int(way_ids[0])]["cuts"].append((float(lons[0]), float(lats[0])))
    return plans


def project(coords, point):
    """(segment, fraction, metres) of the point's projection on the polyline."""
    lat0 = point[1]
    px, py = metres(point[0], point[1], lat0)
    best = None
    for i in range(len(coords) - 1):
        x0, y0 = metres(coords[i][0], coords[i][1], lat0)
        x1, y1 = metres(coords[i + 1][0], coords[i + 1][1], lat0)
        dx, dy = x1 - x0, y1 - y0
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / length))
        distance = math.hypot(x0 + t * dx - px, y0 + t * dy - py)
        if best is None or distance < best[2]:
            best = (i, t, distance)
    return best


def near_stretch(point, stretch, limit=INSIDE):
    import numpy as np

    lat0 = point[1]
    px, py = metres(point[0], point[1], lat0)
    xs, ys = metres(np.asarray(stretch[0]), np.asarray(stretch[1]), lat0)
    if len(xs) == 1:
        return math.hypot(xs[0] - px, ys[0] - py) <= limit
    dx, dy = np.diff(xs), np.diff(ys)
    lengths = dx * dx + dy * dy
    with np.errstate(invalid="ignore", divide="ignore"):
        t = np.clip(((px - xs[:-1]) * dx + (py - ys[:-1]) * dy) / lengths, 0, 1)
    t = np.nan_to_num(t)
    return bool(np.min(np.hypot(xs[:-1] + t * dx - px, ys[:-1] + t * dy - py)) <= limit)


class Ids:
    def __init__(self):
        self.node, self.way = NODE_BASE, WAY_BASE

    def next_node(self):
        self.node += 1
        return self.node

    def next_way(self):
        self.way += 1
        return self.way


def split_way(way_id, nodes, tags, plan, ids, guarded=frozenset()):
    """The way's pieces as (id, node refs, tags) and the nodes made for its cuts as (ref, lon, lat).

    A bridge or tunnel is graded from its ends already, and is never cut. Nor is a way at a node of `guarded`,
    the via nodes of turn restrictions and the ends of their via ways (see restriction_guards).
    """
    if crossing_steps.is_bridge(tags) or crossing_steps.is_tunnel(tags):
        return [(way_id, [ref for ref, _, _ in nodes], dict(tags))], []
    coords = [(lon, lat) for _, lon, lat in nodes]
    refs = [ref for ref, _, _ in nodes]
    inserted, cut_at = {}, set()
    for point in plan["cuts"]:
        segment, fraction, distance = project(coords, point)
        if distance > CUT_DISTANCE:
            continue
        lat0 = point[1]
        x, y = metres(point[0], point[1], lat0)
        for vertex in (segment, segment + 1):
            vx, vy = metres(coords[vertex][0], coords[vertex][1], lat0)
            if math.hypot(vx - x, vy - y) <= ON_NODE:
                if refs[vertex] not in guarded:
                    cut_at.add(vertex)
                break
        else:
            inserted.setdefault(segment, []).append(fraction)
    new_refs, new_coords, cuts, made = [], [], set(), []
    for i, (ref, coord) in enumerate(zip(refs, coords)):
        if i in cut_at:
            cuts.add(len(new_refs))
        new_refs.append(ref)
        new_coords.append(coord)
        for fraction in sorted(inserted.get(i, [])):
            ref_new = ids.next_node()
            point = (coord[0] + (coords[i + 1][0] - coord[0]) * fraction,
                     coord[1] + (coords[i + 1][1] - coord[1]) * fraction)
            cuts.add(len(new_refs))
            new_refs.append(ref_new)
            new_coords.append(point)
            made.append((ref_new, point[0], point[1]))
    bounds = [0] + sorted(cut for cut in cuts if 0 < cut < len(new_refs) - 1) + [len(new_refs) - 1]
    pieces = []
    for number, (first, last) in enumerate(zip(bounds, bounds[1:])):
        middle = point_along(new_coords[first:last + 1])
        piece_tags = dict(tags)
        if any(near_stretch(middle, stretch) for stretch in plan["stretches"]):
            piece_tags["bridge"] = "yes"
            piece_tags[TAG] = TAG_VALUE
        pieces.append((way_id if number == 0 else ids.next_way(), new_refs[first:last + 1], piece_tags))
    return pieces, made


def point_along(coords):
    """The point halfway along a polyline."""
    if len(coords) == 1:
        return coords[0]
    lat0 = coords[0][1]
    lengths = []
    for a, b in zip(coords, coords[1:]):
        ax, ay = metres(a[0], a[1], lat0)
        bx, by = metres(b[0], b[1], lat0)
        lengths.append(math.hypot(bx - ax, by - ay))
    half, travelled = sum(lengths) / 2, 0.0
    for (a, b), length in zip(zip(coords, coords[1:]), lengths):
        if travelled + length >= half and length > 0:
            share = (half - travelled) / length
            return (a[0] + (b[0] - a[0]) * share, a[1] + (b[1] - a[1]) * share)
        travelled += length
    return coords[-1]


def is_restriction(relation):
    return relation["tags"].get("type", "").startswith("restriction")


def restriction_guards(relations, via_ways):
    """(nodes, ways) no cut may fall on: every restriction's via nodes and the ends of its via ways, which are
    not cut at all. A restriction's from and to ways must meet its via, and one piece of each must still do so.
    `via_ways` gives the node refs of the via ways."""
    nodes, ways = set(), set()
    for relation in relations:
        if not is_restriction(relation):
            continue
        for kind, ref, role in relation["members"]:
            if role != "via":
                continue
            if kind == "n":
                nodes.add(ref)
            elif kind == "w":
                ways.add(ref)
                refs = via_ways.get(ref)
                if refs:
                    nodes.update((refs[0], refs[-1]))
    return nodes, ways


def members_after(relation, replacement, via_ways=None):
    """The relation's members with every cut way replaced by its pieces; None when none was cut.

    A restriction keeps one piece of a cut from or to way: the one that holds its via node, or an end of its via
    way. When no piece does, as when the restriction was broken before, it keeps the piece with the way's id.
    """
    members, changed = [], False
    restriction = is_restriction(relation)
    meets = {ref for kind, ref, role in relation["members"] if kind == "n" and role == "via"}
    for kind, ref, role in relation["members"]:
        if kind == "w" and role == "via":
            refs = (via_ways or {}).get(ref)
            if refs:
                meets.update((refs[0], refs[-1]))
    for kind, ref, role in relation["members"]:
        if kind != "w" or ref not in replacement:
            members.append((kind, ref, role))
            continue
        changed = True
        pieces = replacement[ref]
        if restriction:
            touching = [piece for piece in pieces if meets & set(piece[1])]
            pieces = touching[:1] or [piece for piece in pieces if piece[0] == ref][:1] or pieces[:1]
        members.extend(("w", piece[0], role) for piece in pieces)
    return members if changed else None


def read_objects(roads, way_ids, work):
    """The ways to cut, with node locations, and every relation that holds one of them."""
    import osmium

    listing = work / "cut-ways.txt"
    listing.write_text("".join(f"w{way}\n" for way in sorted(way_ids)))
    ways_file, parents_file = work / "cut-ways.osm.pbf", work / "cut-parents.osm.pbf"
    subprocess.run(["osmium", "getid", "--add-referenced", str(roads), "-i", str(listing), "-o", str(ways_file),
                    "--overwrite"], check=True)
    subprocess.run(["osmium", "getparents", str(roads), "-i", str(listing), "-o", str(parents_file), "--overwrite"],
                   check=True)
    ways = {}
    for item in osmium.FileProcessor(str(ways_file), osmium.osm.NODE | osmium.osm.WAY).with_locations():
        if item.is_way():
            ways[item.id] = {"version": item.version or 1, "tags": dict(item.tags),
                             "nodes": [(node.ref, node.location.lon, node.location.lat) for node in item.nodes]}
    relations = []
    for item in osmium.FileProcessor(str(parents_file), osmium.osm.RELATION):
        relations.append({"id": item.id, "version": item.version or 1, "tags": dict(item.tags),
                          "members": [(member.type, member.ref, member.role) for member in item.members]})
    # The via ways of their restrictions, for their ends.
    wanted = {ref for relation in relations if is_restriction(relation)
              for kind, ref, role in relation["members"] if kind == "w" and role == "via"}
    via_ways = {way_id: [ref for ref, _, _ in way["nodes"]] for way_id, way in ways.items() if way_id in wanted}
    if wanted - set(via_ways):
        listing = work / "via-ways.txt"
        listing.write_text("".join(f"w{way}\n" for way in sorted(wanted - set(via_ways))))
        via_file = work / "via-ways.osm.pbf"
        subprocess.run(["osmium", "getid", str(roads), "-i", str(listing), "-o", str(via_file), "--overwrite"],
                       check=True)
        for item in osmium.FileProcessor(str(via_file), osmium.osm.WAY):
            via_ways[item.id] = [node.ref for node in item.nodes]
    return ways, relations, via_ways


def tag_xml(tags):
    return "".join(f"<tag k={quoteattr(key)} v={quoteattr(value)}/>" for key, value in sorted(tags.items()))


def change_xml(nodes, created, modified, relations):
    """An osmChange document: new nodes and ways created, cut ways and their relations modified."""
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<osmChange version="0.6" generator="crossing_split">',
             "<create>"]
    for ref, lon, lat in nodes:
        lines.append(f'<node id="{ref}" version="1" lat="{lat:.7f}" lon="{lon:.7f}"/>')
    for way_id, refs, tags, version in created:
        nds = "".join(f'<nd ref="{ref}"/>' for ref in refs)
        lines.append(f'<way id="{way_id}" version="{version}">{nds}{tag_xml(tags)}</way>')
    lines += ["</create>", "<modify>"]
    for way_id, refs, tags, version in modified:
        nds = "".join(f'<nd ref="{ref}"/>' for ref in refs)
        lines.append(f'<way id="{way_id}" version="{version}">{nds}{tag_xml(tags)}</way>')
    for relation in relations:
        members = "".join(f'<member type="{ {"n": "node", "w": "way", "r": "relation"}[kind] }" ref="{ref}" '
                          f'role={quoteattr(role)}/>' for kind, ref, role in relation["members"])
        lines.append(f'<relation id="{relation["id"]}" version="{relation["version"]}">{members}'
                     f'{tag_xml(relation["tags"])}</relation>')
    lines += ["</modify>", "</osmChange>", ""]
    return "\n".join(lines)


def file_identity(path):
    with Path(path).open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"file": Path(path).name, "bytes": Path(path).stat().st_size, "sha256": sha256}


def rule_of(rule):
    return {"kinds": list(crossing_steps.FIX_KINDS), **rule, "windowMetres": crossing_steps.WINDOW,
            "nearMetres": crossing_steps.NEAR, "bridgeReachMetres": crossing_steps.BRIDGE_REACH,
            "crossingReachMetres": crossing_steps.CROSSING_REACH, "liftMetres": crossing_steps.LIFT,
            "line": "upper convex hull of the road's profile", "tag": {TAG: TAG_VALUE, "bridge": "yes"}}


def run(roads, site_files, elevation, out, rule=None, work=None, jobs=6, log=print, roads_identity=None):
    """Write `out`, the roads with every fixed site's stretch graded from its ends; returns the record.

    The record names the roads, the elevation tiles and `out` by size and SHA-256, so that a graph
    build can take `out` only from the inputs it was made of. `roads_identity` saves hashing a planet
    whose SHA-256 the caller has already checked.
    """
    rule = rule or {"steep": crossing_steps.FIX_STEEP, "plausible": crossing_steps.FIX_PLAUSIBLE,
                    "drop": crossing_steps.FIX_DROP, "dip": crossing_steps.FIX_DIP}
    with tempfile.TemporaryDirectory(dir=work) as scratch:
        scratch = Path(scratch)
        found, fixed = stretches(site_files, crossing_steps.TileDirectory(elevation), rule, jobs=jobs, log=log)
        plans = plan_ways(found)
        ways, relations, via_ways = read_objects(roads, set(plans), scratch) if plans else ({}, [], {})
        guarded_nodes, guarded_ways = restriction_guards(relations, via_ways)
        ids, made, created, modified, replacement = Ids(), [], [], [], {}
        graded = 0
        for way_id in sorted(ways):
            if way_id in guarded_ways:
                continue
            way = ways[way_id]
            pieces, nodes = split_way(way_id, way["nodes"], way["tags"], plans[way_id], ids, guarded_nodes)
            if len(pieces) == 1 and pieces[0][2] == way["tags"]:
                continue
            made.extend(nodes)
            graded += sum(1 for piece in pieces if piece[2].get(TAG) == TAG_VALUE)
            modified.append((pieces[0][0], pieces[0][1], pieces[0][2], way["version"] + 1))
            created.extend((piece_id, refs, tags, 1) for piece_id, refs, tags in pieces[1:])
            replacement[way_id] = pieces
        changed_relations = []
        for relation in relations:
            members = members_after(relation, replacement, via_ways)
            if members is not None:
                changed_relations.append({**relation, "members": members, "version": relation["version"] + 1})
        change = Path(out).with_name(Path(out).name.split(".")[0] + ".osc")
        change.write_text(change_xml(made, created, modified, changed_relations))
        subprocess.run(["osmium", "apply-changes", str(roads), str(change), "-o", str(out), "--overwrite"],
                       check=True)
    sources = []
    for path in site_files:
        meta = crossing_steps.load_sites(path)[0]
        sources.append({**file_identity(path), "region": meta.get("region"), "source": meta.get("source"),
                        "sourceSha256": meta.get("sourceSha256")})
    record = {
        "schema": SCHEMA,
        "roads": roads_identity or file_identity(roads),
        "elevation": file_identity(Path(elevation) / "elevation-manifest.json"),
        "out": file_identity(out),
        "sites": sources, "rule": rule_of(rule),
        # Ways the plan names that the roads do not hold: the site files were written from another extract.
        "waysNotFound": len(set(plans) - set(ways)),
        "fixedSites": len(fixed), "waysChanged": len(replacement),
        "waysCut": sum(1 for pieces in replacement.values() if len(pieces) > 1),
        "piecesGradedFromEnds": graded, "newNodes": len(made), "newWays": len(created),
        "relationsChanged": len(changed_relations), "change": file_identity(change),
    }
    log(f"{len(fixed)} sites fixed: {graded} pieces of {len(replacement)} ways graded from their ends, "
        f"{len(made)} new nodes, {len(created)} new ways, {len(changed_relations)} relations changed")
    return record, fixed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--roads", required=True, type=Path, help="The OSM roads Valhalla builds from")
    parser.add_argument("--sites", required=True, nargs="+", type=Path, help="Site files of crossing_steps.py")
    parser.add_argument("--elevation", required=True, type=Path, help="The tiles the graph is graded with")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--steep", type=float, default=crossing_steps.FIX_STEEP)
    parser.add_argument("--plausible", type=float, default=crossing_steps.FIX_PLAUSIBLE)
    parser.add_argument("--drop", type=float, default=crossing_steps.FIX_DROP)
    parser.add_argument("--dip", type=float, default=crossing_steps.FIX_DIP)
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args(argv)
    rule = {"steep": args.steep, "plausible": args.plausible, "drop": args.drop, "dip": args.dip}
    record, fixed = run(args.roads, args.sites, args.elevation, args.out, rule, jobs=args.jobs)
    args.out.with_suffix(".json").write_text(json.dumps({**record, "fixed": fixed}, indent=1) + "\n")


if __name__ == "__main__":
    main()
