from __future__ import annotations

from pathlib import Path
import ast
import re

ROOT = Path.cwd()


def swift_block(text: str, marker: str):
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
    raise RuntimeError(f"unclosed Swift block: {marker}")


def owner_before(text: str, position: int) -> str:
    candidates = []
    expression = re.compile(
        r"(?m)^\s*(?:(?:private|internal|public|fileprivate)\s+)?"
        r"(?:enum|struct|class)\s+(\w+)[^{]*\{"
    )
    for match in expression.finditer(text[:position]):
        brace = text.find("{", match.start(), match.end() + 2)
        if brace < 0:
            continue
        depth = 0
        end = None
        for index in range(brace, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is not None and end >= position:
            candidates.append((brace, end, match.group(1)))
    if not candidates:
        raise RuntimeError("Swift owner type not found")
    return max(candidates, key=lambda item: item[0])[2]


def parse_swift_parameters(signature: str):
    inside = signature[signature.index("(") + 1:signature.rindex(")")]
    parts = []
    start = 0
    depth = 0
    for index, character in enumerate(inside):
        if character in "([<":
            depth += 1
        elif character in ")]>":
            depth -= 1
        elif character == "," and depth == 0:
            parts.append(inside[start:index].strip())
            start = index + 1
    parts.append(inside[start:].strip())
    result = []
    for part in parts:
        names = part.split(":", 1)[0].strip().split()
        if len(names) == 1:
            result.append((names[0], names[0]))
        else:
            result.append((names[-2], names[-1]))
    return result


def call_argument(label: str, expression: str) -> str:
    return expression if label == "_" else f"{label}: {expression}"


# Swift evaluator: terminal current heap values test retained state. Existing
# per-window minima continue to enforce the unchanged absolute memory floors.
swift_path = ROOT / (
    "ios-app/BikeComputer/BikeComputer/Utilities/"
    "SecureRendererBenchmarkProtocol.swift"
)
text = swift_path.read_text(encoding="utf-8")
start, brace, end = swift_block(text, "func monotonicDecline")
signature = text[start:brace].rstrip()
owner = owner_before(text, start)
parameters = parse_swift_parameters(signature)
if len(parameters) < 2:
    raise RuntimeError(f"unexpected monotonicDecline signature: {signature}")
values_name = parameters[0][1]
allowance_name = parameters[1][1]
signature = re.sub(
    r"\bprivate\s+static\s+func\s+monotonicDecline",
    "static func monotonicDecline",
    signature,
    count=1,
)
body = f'''{{
        guard {values_name}.count >= 3 else {{ return false }}
        let normalized = {values_name}.map {{ Int64($0) }}
        let allowed = max(Int64(0), Int64({allowance_name}))
        let continuationNoise = max(Int64(1), allowed / 4)
        var downwardSteps: [Int64] = []
        downwardSteps.reserveCapacity(normalized.count - 1)
        for index in 1..<normalized.count {{
            let delta = normalized[index - 1] - normalized[index]
            if delta < -continuationNoise {{ return false }}
            downwardSteps.append(max(Int64(0), delta))
        }}
        guard normalized[0] - normalized[normalized.count - 1] > allowed,
              let largestStep = downwardSteps.max() else {{
            return false
        }}
        // A single cache/allocation transition is not progressive leakage.
        // Require continued decline beyond the largest one-time step.
        let continuedDecline = downwardSteps.reduce(Int64(0), +) - largestStep
        return continuedDecline > continuationNoise
    }}'''
text = text[:start] + signature + " " + body + text[end:]

apply_start, _, apply_end = swift_block(text, "func applyCrossRunMemoryGates")
apply_body = text[apply_start:apply_end]
replacements = {
    ".summary.minimumInternalFree": ".finalSnapshot.memory.internalHeap.free",
    ".summary.minimumInternalLargest": ".finalSnapshot.memory.internalHeap.largestBlock",
    ".summary.minimumPsramFree": ".finalSnapshot.memory.psram.free",
    ".summary.minimumPsramLargest": ".finalSnapshot.memory.psram.largestBlock",
    ".summary.minimumDmaFree": ".finalSnapshot.memory.dmaHeap.free",
    ".summary.minimumDmaLargest": ".finalSnapshot.memory.dmaHeap.largestBlock",
}
replaced = 0
for old, new in replacements.items():
    count = apply_body.count(old)
    apply_body = apply_body.replace(old, new)
    replaced += count
if replaced < 2:
    raise RuntimeError("cross-run Swift minimum-series references not found")
text = text[:apply_start] + apply_body + text[apply_end:]
swift_path.write_text(text, encoding="utf-8")

# Preserve the new firmware phase attribution in evidence without making it
# mandatory for older diagnostics schemas.
text = swift_path.read_text(encoding="utf-8")
structs = []
expression = re.compile(
    r"(?m)^\s*(?:(?:private|internal|public|fileprivate)\s+)?"
    r"struct\s+(\w+)[^{]*\{"
)
for match in expression.finditer(text):
    struct_brace = text.index("{", match.start())
    depth = 0
    for index in range(struct_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                struct_body = text[struct_brace:index + 1]
                if (
                    "windowMinimumFree" in struct_body
                    and "windowMinimumLargestBlock" in struct_body
                    and "minimumEverFree" in struct_body
                ):
                    structs.append(
                        (index + 1 - match.start(), match.group(1),
                         match.start(), struct_brace, index + 1, struct_body)
                    )
                break
if not structs:
    raise RuntimeError("DMA heap model not found")
dma_structs = [item for item in structs if "dma" in item[1].lower()]
_, dma_name, _, dma_brace, _, dma_body = min(
    dma_structs or structs, key=lambda item: item[0]
)
if "windowMinimumFreeAttribution" not in dma_body:
    nested = '''
        struct MinimumAttribution: Codable, Equatable {
            let phase: String
            let observedAtMs: UInt32
            let value: Int
            let frameTransferActive: Bool
        }

'''
    text = text[:dma_brace + 1] + nested + text[dma_brace + 1:]
    # Locate the same smallest DMA struct again after insertion.
    selected = None
    for match in expression.finditer(text):
        if match.group(1) != dma_name:
            continue
        candidate_brace = text.index("{", match.start())
        depth = 0
        for index in range(candidate_brace, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    candidate = text[candidate_brace:index + 1]
                    if "windowMinimumFree" in candidate:
                        selected = (candidate_brace, index + 1, candidate)
                        break
        if selected is not None:
            break
    if selected is None:
        raise RuntimeError("DMA heap model disappeared after insertion")
    dma_brace, _, dma_body = selected
    property_match = re.search(
        r"(?m)^(\s*)let\s+windowMinimumLargestBlock\s*:\s*[^\n]+$",
        dma_body,
    )
    if property_match is None:
        raise RuntimeError("DMA largest minimum property not found")
    absolute = dma_brace + property_match.end()
    indent = property_match.group(1)
    properties = (
        f"\n{indent}var windowMinimumFreeAttribution: MinimumAttribution? = nil"
        f"\n{indent}var windowMinimumLargestBlockAttribution: MinimumAttribution? = nil"
    )
    text = text[:absolute] + properties + text[absolute:]
swift_path.write_text(text, encoding="utf-8")

# Python mirror.
python_path = ROOT / "esp32/tools/renderer_benchmark.py"
python_text = python_path.read_text(encoding="utf-8")
tree = ast.parse(python_text)
node = next(
    item for item in tree.body
    if isinstance(item, ast.FunctionDef) and item.name == "monotonic_decline"
)
arguments = [argument.arg for argument in node.args.args]
if len(arguments) < 2:
    raise RuntimeError("unexpected Python monotonic_decline signature")
lines = python_text.splitlines(keepends=True)
indent = " " * node.col_offset
signature_line = lines[node.lineno - 1].rstrip("\n")
new_lines = [
    signature_line,
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
python_replacements = {
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
python_replaced = 0
for old, new in python_replacements.items():
    count = apply_text.count(old)
    apply_text = apply_text.replace(old, new)
    python_replaced += count
if python_replaced < 2:
    raise RuntimeError("cross-run Python minimum-series references not found")
lines[apply_node.lineno - 1:apply_node.end_lineno] = [apply_text]
python_text = "".join(lines)
ast.parse(python_text)
python_path.write_text(python_text, encoding="utf-8")

# Permanent Python policy regression.
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

# Gate copies must stay byte-identical and retain the physically attested 0.3
# metrics-sample calibration.
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

# Add direct Swift sequence tests to the existing command-line test harness.
test_path = ROOT / "ios-app/BikeComputerTests/NavigationProtocolTests.swift"
test_text = test_path.read_text(encoding="utf-8")
main = re.search(r"(?m)^\s*static func main\(\)(?:\s+async)?\s*\{", test_text)
if main is None:
    raise RuntimeError("Swift navigation test main not found")

def swift_call(values, allowance):
    return owner + ".monotonicDecline(" + ", ".join([
        call_argument(parameters[0][0], "[" + ",".join(map(str, values)) + "]"),
        call_argument(parameters[1][0], str(allowance)),
    ]) + ")"

assertions = '''
        // Distinguish a progressive retained trend from a one-time transition.
        assert(%s, "progressive retained decline is rejected")
        assert(!%s, "one-time step followed by plateau is accepted")
        assert(!%s, "stable memory with small jitter is accepted")
        assert(!%s, "physical high-profile values are step plus plateau")
''' % (
    swift_call([40000, 39000, 38000], 1024),
    swift_call([40000, 38000, 38000], 1024),
    swift_call([40000, 39920, 40010], 1024),
    swift_call([39307, 37803, 37779], 1024),
)
test_text = test_text[:main.end()] + assertions + test_text[main.end():]
test_path.write_text(test_text, encoding="utf-8")
