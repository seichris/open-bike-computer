from __future__ import annotations

from pathlib import Path
import ast
import subprocess

ROOT = Path.cwd()
PHYSICAL_BASE = "7fd3e2d5628d81e386046e0048d58d635d4ff664"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def replace_python_function(text: str, name: str, replacement: str) -> str:
    tree = ast.parse(text)
    node = next(
        item for item in tree.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        and item.name == name
    )
    lines = text.splitlines(keepends=True)
    lines[node.lineno - 1:node.end_lineno] = [replacement.rstrip() + "\n"]
    result = "".join(lines)
    ast.parse(result)
    return result


# The first attribution bootstrap reused the within-window trend helper for a
# different cross-run question. Restore that mature helper exactly, then add a
# separate retained-state rule.
python_path = ROOT / "esp32/tools/renderer_benchmark.py"
text = python_path.read_text(encoding="utf-8")
physical = subprocess.check_output(
    ["git", "show", f"{PHYSICAL_BASE}:esp32/tools/renderer_benchmark.py"],
    text=True,
)
physical_tree = ast.parse(physical)
physical_node = next(
    item for item in physical_tree.body
    if isinstance(item, ast.FunctionDef) and item.name == "monotonic_decline"
)
physical_lines = physical.splitlines(keepends=True)
original_monotonic = "".join(
    physical_lines[physical_node.lineno - 1:physical_node.end_lineno]
)
text = replace_python_function(text, "monotonic_decline", original_monotonic)

progressive = '''def progressive_cross_run_decline(
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
    # Discount one bounded session/cache transition. A retained leak or
    # fragmentation trend must continue after that largest one-time step.
    largest_step = max(downward_steps)
    return sum(downward_steps) - largest_step > continuation_noise
'''
apply = '''def apply_cross_run_memory_gates(
    runs: list[dict[str, Any]], gates: dict[str, Any]
) -> None:
    trend = gates["trend"]
    # Window minima retain their unchanged absolute-floor role. Cross-run
    # retention compares standardized terminal current heap state; minima mix
    # render, periodic, metrics and frame-transfer phases and cannot prove that
    # memory remained allocated.
    checks = (
        (lambda run: run["finalSnapshot"]["memory"]["internalHeap"]["free"],
         "crossRunInternalAllowedDeclineBytes", "cross_run_internal_decline"),
        (lambda run: run["finalSnapshot"]["memory"]["internalHeap"]["largestBlock"],
         "crossRunInternalAllowedDeclineBytes", "cross_run_internal_largest_decline"),
        (lambda run: run["finalSnapshot"]["memory"]["psram"]["free"],
         "crossRunPsramAllowedDeclineBytes", "cross_run_psram_decline"),
        (lambda run: run["finalSnapshot"]["memory"]["psram"]["largestBlock"],
         "crossRunPsramAllowedDeclineBytes", "cross_run_psram_largest_decline"),
        (lambda run: run["finalSnapshot"]["memory"]["dmaHeap"]["free"],
         "crossRunDmaAllowedDeclineBytes", "cross_run_dma_decline"),
        (lambda run: run["finalSnapshot"]["memory"]["dmaHeap"]["largestBlock"],
         "crossRunDmaAllowedDeclineBytes", "cross_run_dma_largest_decline"),
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
text = replace_python_function(text, "apply_cross_run_memory_gates", apply)
marker = "\ndef apply_cross_run_memory_gates("
if "def progressive_cross_run_decline(" not in text:
    text = replace_once(
        text, marker, "\n" + progressive + "\n\n" + marker.lstrip("\n"),
        "progressive cross-run helper",
    )
ast.parse(text)
python_path.write_text(text, encoding="utf-8")

# Include snapshot wait, CRC and TLS body time in the bounded frame-active tag;
# no credentials or payload bytes are logged.
http_path = ROOT / "esp32/lib/device_debug/device_debug_http.cpp"
http = http_path.read_text(encoding="utf-8")
old = '''  FrameSnapshot snapshot;
  const uint32_t snapshotWaitStartedUs = micros();
'''
new = '''  RendererFrameTransferScope frameTransferScope;
  FrameSnapshot snapshot;
  const uint32_t snapshotWaitStartedUs = micros();
'''
http = replace_once(http, old, new, "frame activity start")
http = replace_once(
    http,
    '''  RendererFrameTransferScope frameTransferScope;
  const uint32_t responseStartedAtMs = millis();
''',
    '''  const uint32_t responseStartedAtMs = millis();
''',
    "remove late frame activity start",
)
http_path.write_text(http, encoding="utf-8")

# Focused mirror tests. Import the command-line module with its tools directory
# on sys.path, as it imports sibling modules.
test_path = ROOT / "esp32/tools/tests/test_renderer_benchmark_cross_run_memory.py"
test_path.write_text('''#!/usr/bin/env python3
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
    (ROOT / "tools" / "renderer_benchmark_gates.json").read_text()
)


def run(profile, repeat, *, minimum, current,
        minimum_largest=22000, current_largest=28660):
    return {
        "profile": profile, "repeat": repeat, "passed": True, "failures": [],
        "summary": {
            "minimumInternalFree": 60000, "minimumInternalLargest": 40000,
            "minimumPsramFree": 2500000, "minimumPsramLargest": 1800000,
            "minimumDmaFree": minimum, "minimumDmaLargest": minimum_largest,
        },
        "finalSnapshot": {"memory": {
            "internalHeap": {"free": 70000, "largestBlock": 50000},
            "psram": {"free": 2700000, "largestBlock": 1900000},
            "dmaHeap": {
                "free": current, "minimumEverFree": min(minimum, current),
                "largestBlock": current_largest,
                "windowMinimumFree": minimum,
                "windowMinimumLargestBlock": minimum_largest,
            },
        }},
    }


def evaluated(rows):
    result = copy.deepcopy(rows)
    MODULE.apply_cross_run_memory_gates(result, GATES)
    return result


def failures(rows, profile="high"):
    return [failure for row in rows if row["profile"] == profile
            for failure in row.get("failures", [])]


def main():
    allowed = GATES["trend"]["crossRunDmaAllowedDeclineBytes"]
    assert MODULE.progressive_cross_run_decline(
        [46000, 44500, 43000], allowed_decline=allowed)
    assert not MODULE.progressive_cross_run_decline(
        [46000, 44000, 43990], allowed_decline=allowed)
    assert not MODULE.progressive_cross_run_decline(
        [46000, 45920, 46010], allowed_decline=allowed)
    assert not MODULE.progressive_cross_run_decline(
        [39307, 37803, 37779], allowed_decline=allowed)

    leak = [run("high", 1, minimum=39000, current=46000),
            run("high", 2, minimum=37500, current=44500),
            run("high", 3, minimum=36000, current=43000)]
    assert "cross_run_dma_decline" in failures(evaluated(leak))

    plateau = [run("high", 1, minimum=39307, current=46000),
               run("high", 2, minimum=37803, current=44000),
               run("high", 3, minimum=37779, current=43990)]
    assert not failures(evaluated(plateau))

    jitter = [run("high", 1, minimum=39000, current=46000),
              run("high", 2, minimum=38900, current=45920),
              run("high", 3, minimum=39100, current=46010)]
    assert not failures(evaluated(jitter))

    transient = [run("high", 1, minimum=39000, current=46000),
                 run("high", 2, minimum=37000, current=45950),
                 run("high", 3, minimum=35000, current=46020)]
    assert not failures(evaluated(transient))

    physical = [run("high", 1, minimum=39307, current=45251,
                    minimum_largest=23540, current_largest=28660),
                run("high", 2, minimum=37803, current=44983,
                    minimum_largest=21492, current_largest=28660),
                run("high", 3, minimum=37779, current=44907,
                    minimum_largest=21492, current_largest=28660)]
    assert not failures(evaluated(physical))

    fragmented = [run("high", 1, minimum=39000, current=46000,
                      current_largest=26000),
                  run("high", 2, minimum=39000, current=46000,
                      current_largest=24500),
                  run("high", 3, minimum=39000, current=46000,
                      current_largest=23000)]
    assert "cross_run_dma_largest_decline" in failures(
        evaluated(fragmented))

    interleaved = [physical[2],
                   run("flat", 2, minimum=41000, current=47000),
                   physical[0],
                   run("current", 1, minimum=40000, current=46500),
                   physical[1]]
    assert not failures(evaluated(interleaved))
    print("renderer cross-run retained-memory policy tests passed")


if __name__ == "__main__":
    main()
''', encoding="utf-8")

contract = ROOT / "esp32/tools/tests/test_renderer_dma_attribution_contract.py"
contract.write_text('''#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
policy = (ROOT / "lib/renderer_diagnostics/renderer_diagnostics_policy.hpp").read_text()
implementation = (ROOT / "lib/renderer_diagnostics/renderer_diagnostics.cpp").read_text()
http = (ROOT / "lib/device_debug/device_debug_http.cpp").read_text()
for marker in (
    "MemoryObservationPhase::SessionStart",
    "MemoryObservationPhase::SessionEnd",
    "MemoryObservationPhase::WindowStart",
    "MemoryObservationPhase::Periodic",
    "MemoryObservationPhase::RenderComplete",
    "MemoryObservationPhase::MetricsSnapshot",
):
    assert marker in implementation, marker
assert "windowMinimumFreeAttribution" in implementation
assert "windowMinimumLargestBlockAttribution" in implementation
assert "frameTransferActive" in policy
assert http.index("RendererFrameTransferScope frameTransferScope") < http.index(
    "frameStore().acquireSnapshot")
print("renderer DMA attribution source contract passed")
''', encoding="utf-8")
