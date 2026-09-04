from pathlib import Path

path = Path(
    "esp32/lib/renderer_diagnostics/renderer_diagnostics_policy.hpp"
)
text = path.read_text(encoding="utf-8")

old_close = '''  uint32_t cryptoOperationFailures = 0;
}

enum class MemoryObservationPhase'''
new_close = '''  uint32_t cryptoOperationFailures = 0;
};

enum class MemoryObservationPhase'''
if text.count(old_close) != 1:
    raise SystemExit("unexpected MemorySample insertion boundary")
text = text.replace(old_close, new_close, 1)

old_stray = '''  bool frameTransferActive = false;
};
;

struct TimingSummary'''
new_stray = '''  bool frameTransferActive = false;
};

struct TimingSummary'''
if text.count(old_stray) != 1:
    raise SystemExit("unexpected attribution trailing semicolon")
text = text.replace(old_stray, new_stray, 1)

path.write_text(text, encoding="utf-8")
