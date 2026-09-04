from pathlib import Path

root = Path.cwd()
policy = root / "esp32/lib/renderer_diagnostics/renderer_diagnostics_policy.hpp"
implementation = root / "esp32/lib/renderer_diagnostics/renderer_diagnostics.cpp"
test = root / "esp32/tools/tests/test_renderer_diagnostics.cpp"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


text = policy.read_text(encoding="utf-8")
text = replace_once(
    text,
    "  SessionStart,\n  WindowStart,\n",
    "  SessionStart,\n  SessionEnd,\n  WindowStart,\n",
    "session-end enum",
)
text = replace_once(
    text,
    '''  case MemoryObservationPhase::SessionStart:
    return "session_start";
  case MemoryObservationPhase::WindowStart:
''',
    '''  case MemoryObservationPhase::SessionStart:
    return "session_start";
  case MemoryObservationPhase::SessionEnd:
    return "session_end";
  case MemoryObservationPhase::WindowStart:
''',
    "session-end name",
)
policy.write_text(text, encoding="utf-8")

text = implementation.read_text(encoding="utf-8")
start = text.index("void endSession(uint32_t nowMs)")
end = text.index("\n}\n", start) + 3
block = text[start:end]
block = replace_once(
    block,
    "MemoryObservationPhase::SessionStart",
    "MemoryObservationPhase::SessionEnd",
    "end-session attribution",
)
implementation.write_text(text[:start] + block + text[end:], encoding="utf-8")

text = test.read_text(encoding="utf-8")
marker = '  std::cout << "renderer diagnostics policy tests passed\\n";\n'
addition = '''  assert(std::strcmp(
             memoryObservationPhaseName(MemoryObservationPhase::SessionEnd),
             "session_end") == 0);
'''
text = replace_once(text, marker, addition + marker, "session-end test")
test.write_text(text, encoding="utf-8")
