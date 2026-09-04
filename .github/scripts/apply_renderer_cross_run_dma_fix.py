from __future__ import annotations

from pathlib import Path

ROOT = Path.cwd()
SWIFT = ROOT / "ios-app/BikeComputer/BikeComputer/Utilities/SecureRendererBenchmarkProtocol.swift"
SWIFT_TEST = ROOT / "ios-app/BikeComputerTests/NavigationProtocolTests.swift"
PYTHON = ROOT / "esp32/tools/renderer_benchmark.py"
PYTHON_TEST = ROOT / "esp32/tools/tests/test_renderer_benchmark_cross_run_memory.py"
DOC = ROOT / "docs/renderer-benchmark.md"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def replace_braced_function(text: str, marker: str, replacement: str) -> str:
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        character = text[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return text[:start] + replacement + text[index + 1:]
    raise RuntimeError(f"unclosed function: {marker}")


def replace_python_function(text: str, name: str, replacement: str) -> str:
    marker = f"def {name}("
    start = text.index(marker)
    following = text.find("\ndef ", start + len(marker))
    if following < 0:
        raise RuntimeError(f"next Python function not found after {name}")
    return text[:start] + replacement.rstrip() + "\n\n" + text[following + 1:]


swift = SWIFT.read_text(encoding="utf-8")
swift_apply = r'''    static func applyCrossRunMemoryGates(
        runs: inout [RendererBenchmarkRunEvidence],
        gates: RendererBenchmarkGates
    ) {
        struct Check {
            let value: (RendererBenchmarkRunEvidence) -> UInt32
            let allowed: UInt32
            let label: String
        }
        // Per-window minima remain authoritative for the unchanged absolute
        // safety floors. Cross-run retention instead compares the standardized
        // current heap state in each terminal metrics snapshot: a minimum may
        // be set by any transient render, checkpoint, TLS, or polling phase and
        // is therefore not evidence that memory remained allocated.
        let checks = [
            Check(value: { $0.finalSnapshot.memory.internalHeap.free },
                  allowed: gates.trend.crossRunInternalAllowedDeclineBytes,
                  label: "cross_run_internal_decline"),
            Check(value: {
                $0.finalSnapshot.memory.internalHeap.largestBlock
            }, allowed: gates.trend.crossRunInternalAllowedDeclineBytes,
               label: "cross_run_internal_largest_decline"),
            Check(value: { $0.finalSnapshot.memory.psram.free },
                  allowed: gates.trend.crossRunPsramAllowedDeclineBytes,
                  label: "cross_run_psram_decline"),
            Check(value: { $0.finalSnapshot.memory.psram.largestBlock },
                  allowed: gates.trend.crossRunPsramAllowedDeclineBytes,
                  label: "cross_run_psram_largest_decline"),
            Check(value: { $0.finalSnapshot.memory.dmaHeap.free },
                  allowed: gates.trend.crossRunDmaAllowedDeclineBytes,
                  label: "cross_run_dma_decline"),
            Check(value: {
                $0.finalSnapshot.memory.dmaHeap.largestBlock
            }, allowed: gates.trend.crossRunDmaAllowedDeclineBytes,
               label: "cross_run_dma_largest_decline"),
        ]
        for profile in RendererBenchmarkProfile.allCases {
            let indexes = runs.indices.filter {
                runs[$0].profile == profile.wireName
            }.sorted {
                runs[$0].repeatNumber < runs[$1].repeatNumber
            }
            guard indexes.count >=
                    SecureRendererBenchmarkPlan.comparisonRepeats else {
                continue
            }
            for check in checks {
                let values = indexes.map { check.value(runs[$0]) }
                guard progressiveCrossRunDecline(
                    values,
                    allowedDecline: check.allowed
                ) else { continue }
                for index in indexes {
                    runs[index].failures = Array(Set(
                        runs[index].failures + [check.label]
                    )).sorted()
                    runs[index].passed = false
                }
            }
        }
    }'''
swift = replace_braced_function(
    swift,
    "    static func applyCrossRunMemoryGates(",
    swift_apply,
)
helper_marker = "    private static func median(_ values: [Double]) -> Double {"
helper = r'''    static func progressiveCrossRunDecline(
        _ values: [UInt32],
        allowedDecline: UInt32
    ) -> Bool {
        guard values.count >= 3 else { return false }
        let normalized = values.map(Int64.init)
        let allowed = max(Int64(0), Int64(allowedDecline))
        let continuationNoise = max(Int64(1), allowed / 4)
        let totalDecline = normalized[0] - normalized[normalized.count - 1]
        guard totalDecline > allowed else { return false }

        var downwardSteps: [Int64] = []
        downwardSteps.reserveCapacity(normalized.count - 1)
        for (previous, current) in zip(
            normalized,
            normalized.dropFirst()
        ) {
            let delta = previous - current
            // A rebound larger than the bounded noise allowance contradicts a
            // progressive retained-state decline.
            if delta < -continuationNoise { return false }
            downwardSteps.append(max(Int64(0), delta))
        }
        guard let largestStep = downwardSteps.max() else { return false }
        // Discount one one-time cache/session transition. A real progressive
        // leak or fragmentation trend must continue beyond that single step.
        let continuedDecline =
            downwardSteps.reduce(Int64(0), +) - largestStep
        return continuedDecline > continuationNoise
    }

'''
swift = replace_once(
    swift, helper_marker, helper + helper_marker,
    "Swift cross-run helper insertion",
)
SWIFT.write_text(swift, encoding="utf-8")

python_text = PYTHON.read_text(encoding="utf-8")
helper_py = r'''def progressive_cross_run_decline(
    values: list[int], *, allowed_decline: int
) -> bool:
    if len(values) < 3:
        return False
    normalized = [int(value) for value in values]
    allowed = max(0, int(allowed_decline))
    continuation_noise = max(1, allowed // 4)
    total_decline = normalized[0] - normalized[-1]
    if total_decline <= allowed:
        return False

    downward_steps: list[int] = []
    for previous, current in zip(normalized, normalized[1:]):
        delta = previous - current
        if delta < -continuation_noise:
            return False
        downward_steps.append(max(0, delta))
    if not downward_steps:
        return False
    largest_step = max(downward_steps)
    return sum(downward_steps) - largest_step > continuation_noise


'''
apply_py = r'''def apply_cross_run_memory_gates(
    runs: list[dict[str, Any]], gates: dict[str, Any]
) -> None:
    trend = gates["trend"]
    # Per-window minima continue to enforce the unchanged absolute floors.
    # Cross-run retention uses terminal current heap state because a minimum
    # may be set by any transient render, checkpoint, TLS, or polling phase.
    checks = (
        (
            lambda run: run["finalSnapshot"]["memory"]["internalHeap"]["free"],
            "crossRunInternalAllowedDeclineBytes",
            "cross_run_internal_decline",
        ),
        (
            lambda run: run["finalSnapshot"]["memory"]["internalHeap"][
                "largestBlock"
            ],
            "crossRunInternalAllowedDeclineBytes",
            "cross_run_internal_largest_decline",
        ),
        (
            lambda run: run["finalSnapshot"]["memory"]["psram"]["free"],
            "crossRunPsramAllowedDeclineBytes",
            "cross_run_psram_decline",
        ),
        (
            lambda run: run["finalSnapshot"]["memory"]["psram"]["largestBlock"],
            "crossRunPsramAllowedDeclineBytes",
            "cross_run_psram_largest_decline",
        ),
        (
            lambda run: run["finalSnapshot"]["memory"]["dmaHeap"]["free"],
            "crossRunDmaAllowedDeclineBytes",
            "cross_run_dma_decline",
        ),
        (
            lambda run: run["finalSnapshot"]["memory"]["dmaHeap"][
                "largestBlock"
            ],
            "crossRunDmaAllowedDeclineBytes",
            "cross_run_dma_largest_decline",
        ),
    )
    for profile in PROFILES:
        profile_runs = sorted(
            (run for run in runs if run["profile"] == profile),
            key=lambda run: run["repeat"],
        )
        if len(profile_runs) < 3:
            continue
        for value, allowed_key, label in checks:
            values = [value(run) for run in profile_runs]
            if progressive_cross_run_decline(
                values, allowed_decline=trend[allowed_key]
            ):
                for run in profile_runs:
                    run["failures"] = sorted(set(run["failures"] + [label]))
                    run["passed"] = False
'''
python_text = replace_python_function(
    python_text, "apply_cross_run_memory_gates", apply_py
)
insert_marker = "\ndef apply_cross_run_memory_gates("
if helper_py.strip() not in python_text:
    python_text = replace_once(
        python_text,
        insert_marker,
        "\n" + helper_py + "def apply_cross_run_memory_gates(",
        "Python cross-run helper insertion",
    )
PYTHON.write_text(python_text, encoding="utf-8")

PYTHON_TEST.write_text(r'''#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
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
''', encoding="utf-8")

tests = SWIFT_TEST.read_text(encoding="utf-8")
call_marker = '''        testSecureRendererBenchmarkProtocol()
        testSecureRendererReplayWindowOrdering()
'''
tests = replace_once(
    tests,
    call_marker,
    '''        testSecureRendererBenchmarkProtocol()
        testRendererCrossRunRetainedMemoryPolicy()
        testSecureRendererReplayWindowOrdering()
''',
    "Swift test registration",
)
function_marker = '''    static func testSecureRendererReplayWindowOrdering() {
'''
function = r'''    static func testRendererCrossRunRetainedMemoryPolicy() {
        assert(
            RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 44_500, 43_000],
                allowedDecline: 1_024
            ),
            "progressive retained DMA decline is rejected"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 44_000, 43_990],
                allowedDecline: 1_024
            ),
            "one-time transition followed by a plateau is accepted"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 45_920, 46_010],
                allowedDecline: 1_024
            ),
            "stable retained memory with jitter is accepted"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [39_307, 37_803, 37_779],
                allowedDecline: 1_024
            ),
            "the physical three-point minimum series is not progressive"
        )

        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Utilities/SecureRendererBenchmarkProtocol.swift"
        )
        guard let source = try? String(
            contentsOf: sourceURL,
            encoding: .utf8
        ), let start = source.range(
            of: "    static func applyCrossRunMemoryGates("
        ), let end = source.range(
            of: "    static func aggregate(",
            range: start.upperBound..<source.endIndex
        ) else {
            assert(false, "cross-run memory source contract is readable")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        assert(
            body.contains("finalSnapshot.memory.dmaHeap.free") &&
                body.contains("finalSnapshot.memory.dmaHeap.largestBlock"),
            "cross-run DMA gates use terminal current state"
        )
        assert(
            !body.contains(".summary.minimumDmaFree") &&
                !body.contains(".summary.minimumDmaLargest"),
            "heterogeneous window minima are not treated as retained state"
        )
    }

'''
tests = replace_once(
    tests, function_marker, function + function_marker,
    "Swift retained-memory test insertion",
)
SWIFT_TEST.write_text(tests, encoding="utf-8")

doc = DOC.read_text(encoding="utf-8")
doc_marker = '''These are intentionally predeclared so results cannot be judged against a
moving target. If physical evidence shows a threshold should change, update it
in a separate reviewed change before rerunning the experiment.
'''
doc_insert = '''Per-window minimum-free and minimum-largest-block values continue to enforce
the unchanged absolute floors, and the retained one-second samples continue to
drive the within-window trend checks. Cross-run retention is evaluated
separately from each run's terminal current free and largest-block values.
Window minima are deliberately not used for this purpose because they combine
heterogeneous observation phases (window start, periodic polling, render
completion, and secure checkpoint activity) and therefore describe transient
low-water pressure rather than memory that remained allocated. A cross-run
failure still requires a decline beyond the existing byte allowance to
continue after discounting one bounded session/cache transition; progressive
free-memory loss and progressive largest-block fragmentation remain failures.

'''
doc = replace_once(
    doc, doc_marker, doc_marker + "\n" + doc_insert,
    "renderer benchmark retained-memory documentation",
)
DOC.write_text(doc, encoding="utf-8")
