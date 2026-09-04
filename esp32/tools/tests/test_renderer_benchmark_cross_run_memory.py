#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
SPEC = importlib.util.spec_from_file_location(
    "renderer_benchmark", ROOT / "tools" / "renderer_benchmark.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)
GATES = json.loads(
    (ROOT / "tools" / "renderer_benchmark_gates.json").read_text(
        encoding="utf-8"
    )
)


def run(
    profile: str,
    repeat: int,
    *,
    minimum: int,
    current: int,
    minimum_largest: int = 22000,
    current_largest: int = 28660,
) -> dict:
    return {
        "profile": profile,
        "repeat": repeat,
        "passed": True,
        "failures": [],
        "summary": {
            "minimumInternalFree": 60000,
            "minimumInternalLargest": 40000,
            "minimumPsramFree": 2500000,
            "minimumPsramLargest": 1800000,
            "minimumDmaFree": minimum,
            "minimumDmaLargest": minimum_largest,
        },
        "finalSnapshot": {
            "memory": {
                "internalHeap": {"free": 70000, "largestBlock": 50000},
                "psram": {"free": 2700000, "largestBlock": 1900000},
                "dmaHeap": {
                    "free": current,
                    "minimumEverFree": min(minimum, current),
                    "largestBlock": current_largest,
                    "windowMinimumFree": minimum,
                    "windowMinimumLargestBlock": minimum_largest,
                },
            }
        },
    }


def evaluated(rows: list[dict]) -> list[dict]:
    result = copy.deepcopy(rows)
    MODULE.apply_cross_run_memory_gates(result, GATES)
    return result


def profile_failures(rows: list[dict], profile: str = "high") -> list[str]:
    return [
        failure
        for row in rows
        if row["profile"] == profile
        for failure in row.get("failures", [])
    ]


def main() -> None:
    allowed = GATES["trend"]["crossRunDmaAllowedDeclineBytes"]

    assert MODULE.progressive_cross_run_decline(
        [46000, 44500, 43000], allowed_decline=allowed
    )
    assert not MODULE.progressive_cross_run_decline(
        [46000, 44000, 43990], allowed_decline=allowed
    )
    assert not MODULE.progressive_cross_run_decline(
        [46000, 45920, 46010], allowed_decline=allowed
    )
    assert not MODULE.progressive_cross_run_decline(
        [39307, 37803, 37779], allowed_decline=allowed
    )

    leak = [
        run("high", 1, minimum=39000, current=46000),
        run("high", 2, minimum=37500, current=44500),
        run("high", 3, minimum=36000, current=43000),
    ]
    assert "cross_run_dma_decline" in profile_failures(evaluated(leak))

    plateau = [
        run("high", 1, minimum=39307, current=46000),
        run("high", 2, minimum=37803, current=44000),
        run("high", 3, minimum=37779, current=43990),
    ]
    assert not profile_failures(evaluated(plateau))

    jitter = [
        run("high", 1, minimum=39000, current=46000),
        run("high", 2, minimum=38900, current=45920),
        run("high", 3, minimum=39100, current=46010),
    ]
    assert not profile_failures(evaluated(jitter))

    transient = [
        run("high", 1, minimum=39000, current=46000),
        run("high", 2, minimum=37000, current=45950),
        run("high", 3, minimum=35000, current=46020),
    ]
    assert not profile_failures(evaluated(transient))

    physical = [
        run(
            "high", 1, minimum=39307, current=45251,
            minimum_largest=23540, current_largest=28660
        ),
        run(
            "high", 2, minimum=37803, current=44983,
            minimum_largest=21492, current_largest=28660
        ),
        run(
            "high", 3, minimum=37779, current=44907,
            minimum_largest=21492, current_largest=28660
        ),
    ]
    assert not profile_failures(evaluated(physical))

    fragmented = [
        run("high", 1, minimum=39000, current=46000,
            current_largest=26000),
        run("high", 2, minimum=39000, current=46000,
            current_largest=24500),
        run("high", 3, minimum=39000, current=46000,
            current_largest=23000),
    ]
    assert "cross_run_dma_largest_decline" in profile_failures(
        evaluated(fragmented)
    )

    interleaved = [
        physical[2],
        run("flat", 2, minimum=41000, current=47000),
        physical[0],
        run("current", 1, minimum=40000, current=46500),
        physical[1],
    ]
    assert not profile_failures(evaluated(interleaved))

    print("renderer cross-run retained-memory policy tests passed")


if __name__ == "__main__":
    main()
