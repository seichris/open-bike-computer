import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

import generated_sdkconfig as core
from shared_firmware_cache import publish_shared_core, restore_shared_core
if __package__:
    from . import test_generated_sdkconfig as fixtures
else:
    import test_generated_sdkconfig as fixtures


class SharedCoreCacheTests(unittest.TestCase):
    environment = "WAVESHARE_AMOLED_175"

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.fixture = fixtures.GeneratedSdkconfigTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        override = patch.dict(os.environ, {"OPEN_BIKE_FIRMWARE_BUILD_CACHE": str(self.root / "transport")})
        override.start()
        self.addCleanup(override.stop)

    def project(self, name):
        project = self.root / name
        project.mkdir()
        (project / "platformio.ini").write_text(f"[env:{self.environment}]\nplatform = test\n")
        (project / "sdkconfig.defaults").write_text(fixtures.GENERATED_CONFIG)
        return project

    def publish(self, project):
        core.record_generated_sdkconfig_defaults(project, self.environment)
        publish_shared_core(project, self.environment)

    def test_restores_without_origin_worktree_or_generated_sidecars(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin) as installed:
            uploader = installed / "penv/bin/esptool"
            uploader.write_text(f"#!{installed}/penv/bin/python\norigin={origin}\n")
            binary = installed / "packages/framework-arduinoespressif32-libs/esp32s3/qio_opi/libcore.a"
            binary.write_bytes(b"\x00" + os.fsencode(str(origin)))
            self.publish(origin)
        unavailable = self.root / "unavailable"
        origin.rename(unavailable)
        target = self.project("consumer with spaces")
        with self.fixture.fake_core(target) as installed:
            (target / "sdkconfig.defaults").unlink()
            self.assertTrue(restore_shared_core(target, self.environment))
            self.assertIn(str(target), (installed / "penv/bin/esptool").read_text())
            self.assertNotIn(str(origin), (installed / "penv/bin/esptool").read_text())
            binary = installed / "packages/framework-arduinoespressif32-libs/esp32s3/qio_opi/libcore.a"
            self.assertEqual(binary.read_bytes(), b"\x00" + os.fsencode(str(origin)))
            self.assertTrue(core.prepare_generated_sdkconfigs(target, self.environment))

    def test_config_change_is_a_miss(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        target = self.project("consumer")
        with self.fixture.fake_core(target):
            (target / "platformio.ini").write_text(f"[env:{self.environment}]\nplatform = different\n")
            self.assertFalse(restore_shared_core(target, self.environment))

    def test_corrupt_archive_is_rejected_before_hydration(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        archive = next((self.root / "transport").rglob("core-artifacts.tar"))
        archive.chmod(0o644)
        archive.write_bytes(b"corrupt")
        archive.chmod(0o444)
        target = self.project("consumer")
        with self.fixture.fake_core(target) as installed:
            before = (installed / "penv/bin/esptool").read_bytes()
            with self.assertRaisesRegex(core.GeneratedSdkconfigError, "digest"):
                restore_shared_core(target, self.environment)
            self.assertEqual(before, (installed / "penv/bin/esptool").read_bytes())

    def test_transport_manifest_tampering_is_rejected(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        metadata = next((self.root / "transport").rglob("transport.json"))
        data = json.loads(metadata.read_text())
        data["files"]["manifest.json"] = "0" * 64
        metadata.chmod(0o644)
        metadata.write_text(json.dumps(data))
        metadata.chmod(0o444)
        with self.fixture.fake_core(self.project("consumer")):
            with self.assertRaisesRegex(core.GeneratedSdkconfigError, "digest"):
                restore_shared_core(self.root / "consumer", self.environment)

    def test_user_sdkconfig_is_preserved(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        target = self.project("consumer")
        with self.fixture.fake_core(target):
            (target / "sdkconfig.defaults").write_text("user configuration\n")
            with self.assertRaisesRegex(core.GeneratedSdkconfigError, "user SDK"):
                restore_shared_core(target, self.environment)
            self.assertEqual((target / "sdkconfig.defaults").read_text(), "user configuration\n")

    def test_dirty_build_does_not_publish(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            core.record_generated_sdkconfig_defaults(origin, self.environment)
            with patch("generated_sdkconfig.current_source_identity", return_value="dirty-" + "a" * 40):
                publish_shared_core(origin, self.environment)
        self.assertFalse((self.root / "transport").exists())

    def test_symlinked_shared_root_is_rejected(self):
        target = self.project("consumer")
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "transport").symlink_to(outside, target_is_directory=True)
        with self.fixture.fake_core(target):
            with self.assertRaisesRegex(Exception, "unsafe runtime cache"):
                restore_shared_core(target, self.environment)
        self.assertEqual(list(outside.iterdir()), [])

    def test_concurrent_publication_keeps_one_valid_entry(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            core.record_generated_sdkconfig_defaults(origin, self.environment)
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = [pool.submit(publish_shared_core, origin, self.environment) for _ in range(2)]
                for result in results:
                    result.result(timeout=20)
            self.assertEqual(len(list((self.root / "transport").rglob("transport.json"))), 1)
