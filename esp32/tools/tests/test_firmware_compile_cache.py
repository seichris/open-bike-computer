import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from build_firmware import _application_build_cache_identity
from firmware_compile_cache import configure_metadata_identity


class FirmwareCompileCacheTests(unittest.TestCase):
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
            self.assertIs(callback(env, unrelated), unrelated)
            env.Clone.assert_not_called()
            callback(env, metadata)
            clone = env.Clone.return_value
            clone.Depends.assert_called_once()
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
