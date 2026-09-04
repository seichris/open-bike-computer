from __future__ import annotations

from pathlib import Path
import ast
import re
import subprocess

ROOT = Path.cwd()
CALIBRATION = "b60df2b02ad0a66b00340039c94173eb7fcee703"


def block(text: str, marker: str):
    position = text.index(marker)
    start = text.rfind("\n", 0, position) + 1
    brace = text.index("{", position)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return start, brace, index + 1
    raise RuntimeError(f"unclosed block: {marker}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


policy_path = ROOT / (
    "esp32/lib/renderer_diagnostics/renderer_diagnostics_policy.hpp"
)
text = policy_path.read_text(encoding="utf-8")
_, _, memory_sample_end = block(text, "struct MemorySample")
if "enum class MemoryObservationPhase" not in text:
    text = text[:memory_sample_end] + '''

enum class MemoryObservationPhase : uint8_t {
  Unknown = 0,
  SessionStart,
  WindowStart,
  Periodic,
  RenderComplete,
  MetricsSnapshot,
};

inline const char *memoryObservationPhaseName(MemoryObservationPhase phase) {
  switch (phase) {
  case MemoryObservationPhase::SessionStart:
    return "session_start";
  case MemoryObservationPhase::WindowStart:
    return "window_start";
  case MemoryObservationPhase::Periodic:
    return "periodic";
  case MemoryObservationPhase::RenderComplete:
    return "render_complete";
  case MemoryObservationPhase::MetricsSnapshot:
    return "metrics_snapshot";
  case MemoryObservationPhase::Unknown:
  default:
    return "unknown";
  }
}

struct MemoryMinimumAttribution {
  MemoryObservationPhase phase = MemoryObservationPhase::Unknown;
  uint32_t observedAtMs = 0;
  uint32_t value = 0;
  bool frameTransferActive = false;
};
''' + text[memory_sample_end:]

snapshot_fields = '''  uint32_t windowMinimumDmaFree = 0;
  uint32_t windowMinimumDmaLargest = 0;
'''
text = replace_once(
    text,
    snapshot_fields,
    snapshot_fields + '''  MemoryMinimumAttribution windowMinimumDmaFreeAttribution{};
  MemoryMinimumAttribution windowMinimumDmaLargestAttribution{};
''',
    "snapshot attribution fields",
)

note_start, _, note_end = block(text, "  void noteMemory(")
text = text[:note_start] + '''  void noteMemory(
      const MemorySample &sample,
      MemoryObservationPhase phase = MemoryObservationPhase::Unknown,
      uint32_t nowMs = 0, bool frameTransferActive = false) {
    memory_ = sample;
    const MemoryMinimumAttribution freeAttribution{
        phase, nowMs, sample.dmaFree, frameTransferActive};
    const MemoryMinimumAttribution largestAttribution{
        phase, nowMs, sample.dmaLargest, frameTransferActive};
    if (!memoryObserved_) {
      cryptoHeadroomRejectionsBaseline_ = sample.cryptoHeadroomRejections;
      cryptoOperationFailuresBaseline_ = sample.cryptoOperationFailures;
      windowMinimumInternalFree_ = sample.internalFree;
      windowMinimumInternalLargest_ = sample.internalLargest;
      windowMinimumPsramFree_ = sample.psramFree;
      windowMinimumPsramLargest_ = sample.psramLargest;
      windowMinimumDmaFree_ = sample.dmaFree;
      windowMinimumDmaLargest_ = sample.dmaLargest;
      windowMinimumDmaFreeAttribution_ = freeAttribution;
      windowMinimumDmaLargestAttribution_ = largestAttribution;
      memoryObserved_ = true;
      return;
    }
    windowMinimumInternalFree_ =
        std::min(windowMinimumInternalFree_, sample.internalFree);
    windowMinimumInternalLargest_ =
        std::min(windowMinimumInternalLargest_, sample.internalLargest);
    windowMinimumPsramFree_ =
        std::min(windowMinimumPsramFree_, sample.psramFree);
    windowMinimumPsramLargest_ =
        std::min(windowMinimumPsramLargest_, sample.psramLargest);
    if (sample.dmaFree < windowMinimumDmaFree_) {
      windowMinimumDmaFree_ = sample.dmaFree;
      windowMinimumDmaFreeAttribution_ = freeAttribution;
    }
    if (sample.dmaLargest < windowMinimumDmaLargest_) {
      windowMinimumDmaLargest_ = sample.dmaLargest;
      windowMinimumDmaLargestAttribution_ = largestAttribution;
    }
  }''' + text[note_end:]

copy_marker = '''    result.windowMinimumDmaFree = windowMinimumDmaFree_;
    result.windowMinimumDmaLargest = windowMinimumDmaLargest_;
'''
text = replace_once(
    text,
    copy_marker,
    copy_marker + '''    result.windowMinimumDmaFreeAttribution =
        windowMinimumDmaFreeAttribution_;
    result.windowMinimumDmaLargestAttribution =
        windowMinimumDmaLargestAttribution_;
''',
    "snapshot attribution copy",
)

reset_marker = '''    windowMinimumDmaFree_ = 0;
    windowMinimumDmaLargest_ = 0;
'''
text = replace_once(
    text,
    reset_marker,
    reset_marker + '''    windowMinimumDmaFreeAttribution_ = {};
    windowMinimumDmaLargestAttribution_ = {};
''',
    "attribution reset",
)

state_marker = '''  uint32_t windowMinimumDmaFree_ = 0;
  uint32_t windowMinimumDmaLargest_ = 0;
'''
text = replace_once(
    text,
    state_marker,
    state_marker + '''  MemoryMinimumAttribution windowMinimumDmaFreeAttribution_{};
  MemoryMinimumAttribution windowMinimumDmaLargestAttribution_{};
''',
    "attribution state fields",
)
policy_path.write_text(text, encoding="utf-8")

header_path = ROOT / "esp32/lib/renderer_diagnostics/renderer_diagnostics.hpp"
text = header_path.read_text(encoding="utf-8")
text = replace_once(
    text,
    '''void noteRemoteDebug(const RemoteDebugOverhead &overhead);
Snapshot snapshot();
''',
    '''void noteRemoteDebug(const RemoteDebugOverhead &overhead);
void setFrameTransferActive(bool active);
Snapshot snapshot();
''',
    "frame-active declaration",
)
text = replace_once(
    text,
    '''inline void noteRemoteDebug(const RemoteDebugOverhead &) {}
inline Snapshot snapshot() { return {}; }
''',
    '''inline void noteRemoteDebug(const RemoteDebugOverhead &) {}
inline void setFrameTransferActive(bool) {}
inline Snapshot snapshot() { return {}; }
''',
    "frame-active no-op",
)
header_path.write_text(text, encoding="utf-8")

implementation_path = ROOT / (
    "esp32/lib/renderer_diagnostics/renderer_diagnostics.cpp"
)
text = implementation_path.read_text(encoding="utf-8")
if "#include <atomic>" not in text:
    text = replace_once(
        text, "#include <algorithm>\n",
        "#include <algorithm>\n#include <atomic>\n", "atomic include"
    )
text = replace_once(
    text,
    "uint32_t lastPeriodicMemorySampleMs = 0;\n",
    "uint32_t lastPeriodicMemorySampleMs = 0;\n"
    "std::atomic<bool> frameTransferActive{false};\n",
    "frame-active state",
)
helper_start, _, helper_end = block(text, "void noteCurrentMemory(")
text = text[:helper_start] + '''void noteCurrentMemory(MemoryObservationPhase phase, uint32_t nowMs) {
  const MemorySample sample = memorySample();
  const bool frameActive = frameTransferActive.load(std::memory_order_acquire);
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteMemory(sample, phase, nowMs, frameActive);
  portEXIT_CRITICAL(&diagnosticsMux);
}''' + text[helper_end:]

# Classify all existing memory-observation call sites without changing their
# cadence or allocation behavior.
text = text.replace(
    "noteCurrentMemory();",
    "noteCurrentMemory(MemoryObservationPhase::SessionStart, nowMs);",
    1,
)
end_start, _, end_end = block(text, "void endSession(")
end_body = text[end_start:end_end].replace(
    "noteCurrentMemory();",
    "noteCurrentMemory(MemoryObservationPhase::SessionStart, nowMs);",
)
text = text[:end_start] + end_body + text[end_end:]
text = text.replace(
    "noteCurrentMemory();",
    "noteCurrentMemory(MemoryObservationPhase::WindowStart, nowMs);",
    1,
)
text = text.replace(
    "noteCurrentMemory();",
    "noteCurrentMemory(MemoryObservationPhase::Periodic, nowMs);",
    1,
)
if "noteCurrentMemory();" in text:
    raise RuntimeError("unclassified noteCurrentMemory call remains")

text = replace_once(
    text,
    '''  if (accepted)
    diagnosticsState->noteMemory(memory);
''',
    '''  if (accepted)
    diagnosticsState->noteMemory(
        memory, MemoryObservationPhase::RenderComplete, millis(),
        frameTransferActive.load(std::memory_order_acquire));
''',
    "render-complete attribution",
)
text = replace_once(
    text,
    '''    diagnosticsState->noteMemory(memory);
    // Capture the envelope timestamp under the same lock that protects the
''',
    '''    const uint32_t nowMs = millis();
    diagnosticsState->noteMemory(
        memory, MemoryObservationPhase::MetricsSnapshot, nowMs,
        frameTransferActive.load(std::memory_order_acquire));
    // Capture the envelope timestamp under the same lock that protects the
''',
    "metrics attribution",
)
text = text.replace(
    '''    const uint32_t nowMs = millis();
    value = diagnosticsState->snapshot(nowMs);
''',
    '''    value = diagnosticsState->snapshot(nowMs);
''',
    1,
)
text = replace_once(
    text,
    "Snapshot snapshot() {\n",
    '''void setFrameTransferActive(bool active) {
  frameTransferActive.store(active, std::memory_order_release);
}

Snapshot snapshot() {
''',
    "frame-active setter",
)

json_marker = '''       << ",\\\"windowMinimumLargestBlock\\\":"
       << value.windowMinimumDmaLargest
       << ",\\\"cryptoCountersScope\\\":\\\"window\\\""
'''
json_replacement = '''       << ",\\\"windowMinimumLargestBlock\\\":"
       << value.windowMinimumDmaLargest
       << ",\\\"windowMinimumFreeAttribution\\\":{\\\"phase\\\":\\\""
       << memoryObservationPhaseName(
              value.windowMinimumDmaFreeAttribution.phase)
       << "\\\",\\\"observedAtMs\\\":"
       << value.windowMinimumDmaFreeAttribution.observedAtMs
       << ",\\\"value\\\":"
       << value.windowMinimumDmaFreeAttribution.value
       << ",\\\"frameTransferActive\\\":"
       << (value.windowMinimumDmaFreeAttribution.frameTransferActive
               ? "true" : "false")
       << "},\\\"windowMinimumLargestBlockAttribution\\\":{\\\"phase\\\":\\\""
       << memoryObservationPhaseName(
              value.windowMinimumDmaLargestAttribution.phase)
       << "\\\",\\\"observedAtMs\\\":"
       << value.windowMinimumDmaLargestAttribution.observedAtMs
       << ",\\\"value\\\":"
       << value.windowMinimumDmaLargestAttribution.value
       << ",\\\"frameTransferActive\\\":"
       << (value.windowMinimumDmaLargestAttribution.frameTransferActive
               ? "true" : "false")
       << "}"
       << ",\\\"cryptoCountersScope\\\":\\\"window\\\""
'''
text = replace_once(
    text, json_marker, json_replacement, "DMA attribution JSON"
)
implementation_path.write_text(text, encoding="utf-8")

http_path = ROOT / "esp32/lib/device_debug/device_debug_http.cpp"
text = http_path.read_text(encoding="utf-8")
if "class RendererFrameTransferScope" not in text:
    namespace = text.index("namespace {") + len("namespace {")
    scope = '''

class RendererFrameTransferScope {
public:
  RendererFrameTransferScope() {
    renderer_diagnostics::setFrameTransferActive(true);
  }
  ~RendererFrameTransferScope() {
    renderer_diagnostics::setFrameTransferActive(false);
  }
  RendererFrameTransferScope(const RendererFrameTransferScope &) = delete;
  RendererFrameTransferScope &
  operator=(const RendererFrameTransferScope &) = delete;
};
'''
    text = text[:namespace] + scope + text[namespace:]
frame_start, _, frame_end = block(text, "bool DeviceDebugHttp::handleFrame")
frame = text[frame_start:frame_end]
marker = "const uint32_t responseStartedAtMs = millis();"
if marker not in frame:
    raise RuntimeError("frame response start marker not found")
frame = frame.replace(
    marker,
    "RendererFrameTransferScope frameTransferScope;\n  " + marker,
    1,
)
text = text[:frame_start] + frame + text[frame_end:]
http_path.write_text(text, encoding="utf-8")

# Firmware policy regression for event/phase attribution.
test_path = ROOT / "esp32/tools/tests/test_renderer_diagnostics.cpp"
text = test_path.read_text(encoding="utf-8")
marker = "  state.endSession();\n"
case = '''  State attributionState;
  attributionState.beginSession(true);
  assert(attributionState.beginWindow(
      77, runIdentity(kRouteHash), Profile::High, 5000, 0));
  attributionState.noteMemory(
      {50000, 49000, 30000, 2800000, 1900000, 40000, 39000, 24000,
       0, 0},
      MemoryObservationPhase::WindowStart, 5000, false);
  attributionState.noteMemory(
      {50000, 49000, 30000, 2800000, 1900000, 38000, 37000, 22000,
       0, 0},
      MemoryObservationPhase::RenderComplete, 5100, true);
  const Snapshot attributed = attributionState.snapshot(5200);
  assert(attributed.windowMinimumDmaFreeAttribution.phase ==
         MemoryObservationPhase::RenderComplete);
  assert(attributed.windowMinimumDmaFreeAttribution.observedAtMs == 5100);
  assert(attributed.windowMinimumDmaFreeAttribution.value == 38000);
  assert(attributed.windowMinimumDmaFreeAttribution.frameTransferActive);
  assert(attributed.windowMinimumDmaLargestAttribution.phase ==
         MemoryObservationPhase::RenderComplete);
  assert(attributed.windowMinimumDmaLargestAttribution.value == 22000);

'''
text = replace_once(text, marker, case + marker, "attribution policy test")
test_path.write_text(text, encoding="utf-8")

# Python evaluator mirror: terminal current memory represents retained state;
# window minima remain unchanged absolute floor evidence.
python_path = ROOT / "esp32/tools/renderer_benchmark.py"
python_text = python_path.read_text(encoding="utf-8")
tree = ast.parse(python_text)
node = next(
    item for item in tree.body
    if isinstance(item, ast.FunctionDef) and item.name == "monotonic_decline"
)
arguments = [argument.arg for argument in node.args.args]
lines = python_text.splitlines(keepends=True)
indent = " " * node.col_offset
signature = lines[node.lineno - 1].rstrip("\n")
new_lines = [
    signature,
    f"{indent}    if len({arguments[0]}) < 3:",
    f"{indent}        return False",
    f"{indent}    normalized = [int(value) for value in {arguments[0]}]",
    f"{indent}    allowed = max(0, int({arguments[1]}))",
    f"{indent}    continuation_noise = max(1, allowed // 4)",
    f"{indent}    downward_steps = []",
    f"{indent}    for previous, current in zip(normalized, normalized[1:]):",
    f"{indent}        delta = previous - current",
    f"{indent}        if delta < -continuation_noise:",
    f"{indent}            return False",
    f"{indent}        downward_steps.append(max(0, delta))",
    f"{indent}    if normalized[0] - normalized[-1] <= allowed:",
    f"{indent}        return False",
    f"{indent}    largest_step = max(downward_steps, default=0)",
    f"{indent}    return sum(downward_steps) - largest_step > continuation_noise",
]
lines[node.lineno - 1:node.end_lineno] = [line + "\n" for line in new_lines]
python_text = "".join(lines)
tree = ast.parse(python_text)
apply_node = next(
    item for item in tree.body
    if isinstance(item, ast.FunctionDef)
    and item.name == "apply_cross_run_memory_gates"
)
lines = python_text.splitlines(keepends=True)
apply_text = "".join(lines[apply_node.lineno - 1:apply_node.end_lineno])
replacements = {
    '["summary"]["minimumInternalFree"]': '["finalSnapshot"]["memory"]["internalHeap"]["free"]',
    '["summary"]["minimumInternalLargest"]': '["finalSnapshot"]["memory"]["internalHeap"]["largestBlock"]',
    '["summary"]["minimumPsramFree"]': '["finalSnapshot"]["memory"]["psram"]["free"]',
    '["summary"]["minimumPsramLargest"]': '["finalSnapshot"]["memory"]["psram"]["largestBlock"]',
    '["summary"]["minimumDmaFree"]': '["finalSnapshot"]["memory"]["dmaHeap"]["free"]',
    '["summary"]["minimumDmaLargest"]': '["finalSnapshot"]["memory"]["dmaHeap"]["largestBlock"]',
    "['summary']['minimumInternalFree']": "['finalSnapshot']['memory']['internalHeap']['free']",
    "['summary']['minimumInternalLargest']": "['finalSnapshot']['memory']['internalHeap']['largestBlock']",
    "['summary']['minimumPsramFree']": "['finalSnapshot']['memory']['psram']['free']",
    "['summary']['minimumPsramLargest']": "['finalSnapshot']['memory']['psram']['largestBlock']",
    "['summary']['minimumDmaFree']": "['finalSnapshot']['memory']['dmaHeap']['free']",
    "['summary']['minimumDmaLargest']": "['finalSnapshot']['memory']['dmaHeap']['largestBlock']",
}
changed = 0
for old, new in replacements.items():
    count = apply_text.count(old)
    apply_text = apply_text.replace(old, new)
    changed += count
if changed < 2:
    raise RuntimeError("Python cross-run series references not found")
lines[apply_node.lineno - 1:apply_node.end_lineno] = [apply_text]
python_text = "".join(lines)
ast.parse(python_text)
python_path.write_text(python_text, encoding="utf-8")

# Synchronize both gate copies from the intentionally calibrated app-stack
# commit instead of creating a hybrid configuration.
for relative in (
    "esp32/tools/renderer_benchmark_gates.json",
    "ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-gates-v1.json",
):
    data = subprocess.check_output(["git", "show", f"{CALIBRATION}:{relative}"])
    (ROOT / relative).write_bytes(data)

(ROOT / "esp32/tools/tests/test_renderer_benchmark_cross_run_memory.py").write_text(
'''#!/usr/bin/env python3
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
GATES = json.loads((ROOT / "tools" / "renderer_benchmark_gates.json").read_text())


def run(profile, repeat, *, minimum, current,
        minimum_largest=22000, current_largest=24000):
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


def evaluated(runs):
    candidate = copy.deepcopy(runs)
    result = MODULE.apply_cross_run_memory_gates(candidate, GATES)
    return candidate if result is None else result


def failures(rows, profile="high"):
    return [failure for row in rows if row["profile"] == profile
            for failure in row.get("failures", [])]


def main():
    assert MODULE.monotonic_decline([40000, 39000, 38000], 1024)
    assert not MODULE.monotonic_decline([40000, 38000, 38000], 1024)
    assert not MODULE.monotonic_decline([40000, 39920, 40010], 1024)
    assert not MODULE.monotonic_decline([39307, 37803, 37779], 1024)
    leak = [run("high", 1, minimum=39000, current=46000),
            run("high", 2, minimum=37500, current=45000),
            run("high", 3, minimum=36000, current=44000)]
    assert any("dma" in value and "decline" in value
               for value in failures(evaluated(leak)))
    plateau = [run("high", 1, minimum=39307, current=45251),
               run("high", 2, minimum=37803, current=43700),
               run("high", 3, minimum=37779, current=43690)]
    assert not failures(evaluated(plateau))
    physical = [run("high", 1, minimum=39307, current=45251,
                    minimum_largest=23540, current_largest=25588),
                run("high", 2, minimum=37803, current=44983,
                    minimum_largest=21492, current_largest=25588),
                run("high", 3, minimum=37779, current=44907,
                    minimum_largest=21492, current_largest=25588)]
    assert not failures(evaluated(physical))
    transient = [run("high", 1, minimum=39000, current=46000),
                 run("high", 2, minimum=37000, current=45950),
                 run("high", 3, minimum=35000, current=46020)]
    assert not failures(evaluated(transient))
    fragmented = [run("high", 1, minimum=39000, current=46000,
                      current_largest=26000),
                  run("high", 2, minimum=39000, current=46000,
                      current_largest=25000),
                  run("high", 3, minimum=39000, current=46000,
                      current_largest=24000)]
    assert any("dma" in value and "decline" in value
               for value in failures(evaluated(fragmented)))
    interleaved = [physical[0], run("flat", 1, minimum=41000, current=47000),
                   physical[1], run("current", 1, minimum=40000, current=46500),
                   physical[2]]
    assert not failures(evaluated(interleaved))
    print("renderer cross-run memory policy tests passed")


if __name__ == "__main__":
    main()
''', encoding="utf-8")

(ROOT / "esp32/tools/tests/test_renderer_benchmark_gate_parity.py").write_text(
'''#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[3]
firmware = root / "esp32/tools/renderer_benchmark_gates.json"
app = root / "ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-gates-v1.json"
a = firmware.read_bytes()
b = app.read_bytes()
assert a == b, (hashlib.sha256(a).hexdigest(), hashlib.sha256(b).hexdigest())
config = json.loads(a)

def find(value, key):
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = find(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find(child, key)
            if found is not None:
                return found
    return None

assert find(config, "minimumMetricsSampleFraction") == 0.3
print("renderer benchmark gate copies are canonical and byte-identical")
''', encoding="utf-8")
