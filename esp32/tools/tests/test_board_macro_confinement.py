#!/usr/bin/env python3
"""Keep firmware-target macros out of shared sources.

Board differences belong in lib/board/boards/<target>.hpp as data, or in a
source file that exists for one board family and is gated as a whole. Shared
code must not test WAVESHARE_AMOLED_175 or the other target macros. Every
remaining use is frozen per file in board_macro_baseline.json; a change may
only lower those counts. Run from esp32/:

    python tools/tests/test_board_macro_confinement.py
    python tools/tests/test_board_macro_confinement.py --list
    python tools/tests/test_board_macro_confinement.py --update-baseline

docs/plans/board-support-architecture-plan.md describes the layout this
test protects.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = Path(__file__).resolve().with_name("board_macro_baseline.json")
SCAN_DIRS = ("src", "lib", "include")
SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp", ".inc", ".ino"}
# Board definitions and the panel selector are where target macros belong.
EXEMPT_PREFIXES = ("lib/board/",)
EXEMPT_FILES = {"lib/panel/panelSelect.hpp"}

CONDITIONAL = re.compile(r"^\s*#\s*(?:if|ifdef|ifndef|elif)\b")
OPENING = re.compile(r"^\s*#\s*(?:if|ifdef|ifndef)\b")
ENDIF = re.compile(r"^\s*#\s*endif\b")


def firmware_targets() -> list[str]:
    ini = (ROOT / "platformio.ini").read_text(encoding="utf-8")
    targets = sorted(set(re.findall(r"^custom_firmware_target\s*=\s*(\S+)", ini, re.M)))
    if not targets:
        raise SystemExit("platformio.ini defines no custom_firmware_target")
    return targets


def logical_lines(text: str) -> list[str]:
    """Source lines without comments, with backslash continuations joined."""
    text = re.sub(
        r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), text, flags=re.S
    )
    joined: list[str] = []
    pending = ""
    for line in text.split("\n"):
        line = re.sub(r"//.*", "", line)
        if line.rstrip().endswith("\\"):
            pending += line.rstrip()[:-1] + " "
            continue
        joined.append(pending + line)
        pending = ""
    if pending:
        joined.append(pending)
    return joined


def target_directive_lines(lines: list[str], macro: re.Pattern) -> list[int]:
    return [i for i, line in enumerate(lines) if CONDITIONAL.match(line) and macro.search(line)]


def gates_whole_file(lines: list[str], hits: list[int]) -> bool:
    """True when the file's only target conditional wraps all of its code."""
    if len(hits) != 1:
        return False
    first = hits[0]
    for line in lines[:first]:
        stripped = line.strip()
        if stripped and not stripped.startswith(("#pragma once", "#include")):
            return False
    depth = 0
    for index in range(first, len(lines)):
        if OPENING.match(lines[index]):
            depth += 1
        elif ENDIF.match(lines[index]):
            depth -= 1
            if depth == 0:
                return all(not line.strip() for line in lines[index + 1:])
    return False


def scan(targets: list[str]) -> tuple[dict[str, int], dict[str, str]]:
    """Return baseline-relevant counts and the exemption reason per file."""
    macro = re.compile(r"\b(?:" + "|".join(map(re.escape, targets)) + r")\b")
    counts: dict[str, int] = {}
    exempt: dict[str, str] = {}
    for scan_dir in SCAN_DIRS:
        for path in sorted((ROOT / scan_dir).rglob("*")):
            if path.suffix not in SUFFIXES or not path.is_file():
                continue
            relative = path.relative_to(ROOT).as_posix()
            lines = logical_lines(path.read_text(encoding="utf-8", errors="replace"))
            hits = target_directive_lines(lines, macro)
            if not hits:
                continue
            if relative.startswith(EXEMPT_PREFIXES) or relative in EXEMPT_FILES:
                exempt[relative] = "board definition or panel selector"
            elif gates_whole_file(lines, hits):
                exempt[relative] = "gated as a whole file"
            else:
                counts[relative] = len(hits)
    return counts, exempt


def load_baseline() -> dict:
    if not BASELINE_PATH.exists():
        return {"targets": [], "files": {}}
    return json.loads(BASELINE_PATH.read_text(encoding="utf-8"))


def write_baseline(targets: list[str], counts: dict[str, int]) -> None:
    payload = {
        "comment": (
            "Target-macro conditionals per shared source file. Only lower these "
            "counts; new board differences go into lib/board/boards or a file "
            "gated as a whole. Update with --update-baseline."
        ),
        "targets": targets,
        "files": dict(sorted(counts.items())),
    }
    BASELINE_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def compare(targets: list[str], counts: dict[str, int], baseline: dict) -> list[str]:
    problems: list[str] = []
    if baseline.get("targets") != targets:
        problems.append(
            f"firmware targets changed: baseline {baseline.get('targets')} but "
            f"platformio.ini has {targets}; rerun with --update-baseline"
        )
    recorded: dict[str, int] = baseline.get("files", {})
    for path in sorted(set(counts) | set(recorded)):
        now, before = counts.get(path, 0), recorded.get(path, 0)
        if now > before:
            problems.append(
                f"{path}: {now} target-macro conditionals, baseline {before}. "
                "Put the board difference into lib/board/boards or a board-specific "
                "file gated as a whole instead of raising the baseline."
            )
        elif now < before:
            problems.append(
                f"{path}: {now} target-macro conditionals, baseline {before}. "
                "Lower the baseline with --update-baseline so the count cannot grow back."
            )
    return problems


def main(argv: list[str]) -> int:
    targets = firmware_targets()
    counts, exempt = scan(targets)
    if "--list" in argv:
        for path, reason in sorted(exempt.items()):
            print(f"exempt  {path}: {reason}")
        for path, count in sorted(counts.items()):
            print(f"{count:6d}  {path}")
        print(f"{sum(counts.values())} conditionals in {len(counts)} shared files")
        return 0
    if "--update-baseline" in argv:
        before = load_baseline().get("files", {})
        write_baseline(targets, counts)
        for path in sorted(set(before) | set(counts)):
            if before.get(path, 0) != counts.get(path, 0):
                print(f"{path}: {before.get(path, 0)} -> {counts.get(path, 0)}")
        print(f"wrote {BASELINE_PATH.relative_to(ROOT)}")
        return 0
    problems = compare(targets, counts, load_baseline())
    for problem in problems:
        print(problem)
    if problems:
        return 1
    print(
        f"board macro confinement: {sum(counts.values())} conditionals in "
        f"{len(counts)} shared files, within baseline"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
