#!/usr/bin/env python
"""Index explicit OSM type=building outline/part relationships."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import osmium


def member_key(member) -> str:
    return f"{member.type}{member.ref}"


class BuildingRelationHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.part_parents: dict[str, str] = {}
        self.relations = 0
        self.ambiguous_parts = 0

    def relation(self, relation) -> None:
        if relation.tags.get("type") != "building":
            return
        outlines = sorted(
            member_key(member)
            for member in relation.members
            if member.role == "outline" and member.type in {"w", "r"}
        )
        parts = sorted(
            member_key(member)
            for member in relation.members
            if member.role == "part" and member.type in {"w", "r"}
        )
        if not outlines or not parts:
            return
        self.relations += 1
        parent = outlines[0]
        for part in parts:
            existing = self.part_parents.get(part)
            if existing is not None and existing != parent:
                self.ambiguous_parts += 1
                self.part_parents[part] = min(existing, parent)
            else:
                self.part_parents[part] = parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pbf")
    parser.add_argument("output")
    args = parser.parse_args()
    handler = BuildingRelationHandler()
    handler.apply_file(args.pbf, locations=False)
    result = {
        "schemaVersion": 1,
        "partParents": dict(sorted(handler.part_parents.items())),
        "relations": handler.relations,
        "ambiguousParts": handler.ambiguous_parts,
    }
    Path(args.output).write_text(
        json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
