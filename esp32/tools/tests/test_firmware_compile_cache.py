import tempfile
import subprocess
import sys
import unittest
import os
import shutil
from pathlib import Path
from unittest.mock import Mock

from build_firmware import _application_build_cache_identity
from firmware_compile_cache import configure_metadata_identity, relocate_core_text


class FirmwareCompileCacheTests(unittest.TestCase):
    def test_relocated_platformio_file_location_stays_a_raw_filesystem_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "producer"
            target = root / "consumer with a longer path"
            target.mkdir()
            metadata = target / ".piopm"
            metadata.write_text('{"uri":"file://' + str(origin / "platform-staging") + '"}')
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            self.assertIn("file://" + str(target / "platform-staging"), metadata.read_text())
            self.assertNotIn("%20", metadata.read_text())

    @unittest.skipUnless(shutil.which("cc"), "host C compiler is unavailable")
    def test_compiler_clock_is_independent_of_commit_epoch_and_source_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
            clock = project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_compile_clock.h"
            source = project / "clock.c"
            source.write_text('const char *clock = __DATE__ " " __TIME__ " " __TIMESTAMP__;\n')
            outputs = []
            for epoch in (0, 1790859494):
                os.utime(source, (epoch, epoch))
                result = subprocess.run(
                    [shutil.which("cc"), "-E", "-P", "-Werror=date-time", "-include", str(clock), str(source)],
                    env={**os.environ, "SOURCE_DATE_EPOCH": str(epoch)},
                    check=True, capture_output=True, text=True,
                )
                outputs.append(result.stdout)
            self.assertEqual(outputs[0], outputs[1])
            self.assertIn('"Jan  1 1970" " " "00:00:00"', outputs[0])

    def test_rebases_percent_encoded_package_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "old producer"
            target = root / "new consumer"
            target.mkdir()
            metadata = target / ".piopm"
            metadata.write_text('{"uri":"' + (origin / "platform-staging").as_uri() + '"}')
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            self.assertIn((target / "platform-staging").as_uri(), metadata.read_text())

    def test_relocated_python_launcher_executes_in_path_with_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "producer"
            target = root / "consumer with 'quotes'"
            (target / "bin").mkdir(parents=True)
            (target / "bin/python").symlink_to(sys.executable)
            launcher = target / "bin/launch"
            launcher.write_text(f"#!{origin}/bin/python\nprint('relocated')\n")
            launcher.chmod(0o755)
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            result = subprocess.run([str(launcher)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout, "relocated\n")

    def test_source_commit_keeps_library_namespace_but_core_change_does_not(self):
        project = Path("/project")
        first = _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "a" * 40, "1" * 64)
        self.assertEqual(first, _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "b" * 40, "1" * 64))
        self.assertNotEqual(first, _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "a" * 40, "2" * 64))

    def test_identity_header_changes_only_metadata_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
            callback = env.AddBuildMiddleware.call_args.args[0]
            metadata = Mock()
            metadata.srcnode.return_value.get_abspath.return_value = str(project / "lib/firmware_metadata/firmware_metadata.cpp")
            unrelated = Mock()
            unrelated.srcnode.return_value.get_abspath.return_value = str(project / "lib/lvgl/lvgl.cpp")
            env.Object.return_value = [Mock()]
            self.assertIs(callback(env, unrelated), env.Object.return_value[0])
            env.Depends.assert_called_once_with(env.Object.return_value, str(project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_compile_clock.h"))
            env.Clone.assert_not_called()
            env.Clone.return_value.Object.return_value = [Mock()]
            self.assertIs(callback(env, metadata), env.Clone.return_value.Object.return_value[0])
            clone = env.Clone.return_value
            self.assertEqual(clone.Depends.call_count, 2)
            header = Path(clone.Depends.call_args.args[1])
            before = header.read_text()
            configure_metadata_identity(env, "b" * 40, "2026-10-02T00:00:00Z")
            after = header.read_text()
            self.assertIn("a" * 40, before)
            self.assertNotIn("a" * 40, after)
            self.assertIn("b" * 40, after)
            self.assertIn("2026-10-02T00:00:00Z", after)

    def test_symlinked_identity_header_is_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            header = project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_identity.h"
            header.parent.mkdir(parents=True)
            outside = project / "outside"
            outside.write_text("preserved")
            header.symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "unsafe firmware identity"):
                configure_metadata_identity(env, "a" * 40, "time")
            self.assertEqual(outside.read_text(), "preserved")
