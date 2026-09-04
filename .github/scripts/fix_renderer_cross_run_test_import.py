from pathlib import Path

path = Path("esp32/tools/tests/test_renderer_benchmark_cross_run_memory.py")
text = path.read_text(encoding="utf-8")
old = "import json\nfrom pathlib import Path\n\nROOT = Path(__file__).resolve().parents[2]\n"
new = "import json\nfrom pathlib import Path\nimport sys\n\nROOT = Path(__file__).resolve().parents[2]\nsys.path.insert(0, str(ROOT / \"tools\"))\n"
if text.count(old) != 1:
    raise SystemExit("unexpected renderer cross-run test import block")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
