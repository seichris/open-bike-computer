"""A dependency refresh must not silently downgrade or change an unverified ABI."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "tools" / "repair_pillow_brotli.py"
spec = importlib.util.spec_from_file_location("repair_pillow_brotli", HELPER)
repair_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair_module)


@unittest.skipUnless(shutil.which("cc"), "native fixture requires a C compiler")
class PillowBrotliRepairTests(unittest.TestCase):
    def test_rejects_other_native_versions_without_changing_wheel(self):
        for version in (0x1002001, 0x1002002, 0x1001000):
            with self.subTest(version=hex(version)), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                libraries = root / "pillow.libs"
                libraries.mkdir()
                decoder = libraries / "libbrotlidec-fixture.so.1.2.0"
                common = libraries / "libbrotlicommon-fixture.so.1.2.0"
                source = root / "version.c"
                source.write_text(f"unsigned int BrotliDecoderVersion(void) {{ return {version}u; }}\n")
                subprocess.run(["cc", "-shared", "-fPIC", str(source), "-o", str(decoder)], check=True)
                common.write_bytes(b"original common library")
                original = {path: path.read_bytes() for path in (decoder, common)}
                distribution = SimpleNamespace(locate_file=lambda _: libraries)
                with patch.object(repair_module.importlib.metadata, "distribution", return_value=distribution):
                    with self.assertRaisesRegex(RuntimeError, "refusing to replace another version"):
                        repair_module.repair(root / "replacement")
                self.assertEqual(original, {path: path.read_bytes() for path in original})


if __name__ == "__main__":
    unittest.main()
