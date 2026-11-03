import contextlib
import errno
import importlib.util
import io
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

# The CI side of shared-core transport: firmware-core-warm packs entries, and
# pull-request builds install them before build_firmware.py restores them.
_ARTIFACT_SCRIPT = Path(__file__).resolve().parents[3] / ".github/scripts/firmware_core_artifact.py"
_spec = importlib.util.spec_from_file_location("firmware_core_artifact", _ARTIFACT_SCRIPT)
core_artifact = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core_artifact)


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
        archive = next((self.root / "transport").rglob("core-artifacts.tar"))
        self.assertEqual(archive.read_bytes()[:2], b"\x1f\x8b")
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

    def test_restores_into_the_worktree_that_published_the_entry(self):
        # Another profile's build replaced the generated sdkconfig files, so the
        # private-cache path is unavailable although this worktree still holds
        # the private entry the transport was published from. The import must
        # not relocate launchers onto their own path: that rewrite is not
        # idempotent, and the result no longer matched the private attestation.
        origin = self.project("producer")
        with self.fixture.fake_core(origin) as installed:
            launcher = installed / "penv/bin/esptool"
            launcher.write_text(f"#!{installed}/penv/bin/python\norigin={origin}\n")
            self.publish(origin)
            before = launcher.read_bytes()
            (origin / "sdkconfig.defaults").unlink()
            self.assertTrue(restore_shared_core(origin, self.environment))
            self.assertEqual(launcher.read_bytes(), before)
            self.assertTrue(core.prepare_generated_sdkconfigs(origin, self.environment))

    def test_same_path_import_keeps_launchers_byte_identical(self):
        # Without a private entry the transport is imported; a transport from
        # this very path needs no relocation.
        origin = self.project("producer")
        with self.fixture.fake_core(origin) as installed:
            launcher = installed / "penv/bin/esptool"
            launcher.write_text(f"#!{installed}/penv/bin/python\norigin={origin}\n")
            self.publish(origin)
            before = launcher.read_bytes()
            key = core.core_input_key(origin, self.environment)
            entry = core._core_cache_entry_dir(origin, self.environment, key)
            self.assertTrue(entry.is_dir())
            core._quarantine_core_cache_entry(origin, self.environment, key, "unit test")
            self.assertFalse(entry.exists())
            (origin / "sdkconfig.defaults").unlink()
            self.assertTrue(restore_shared_core(origin, self.environment))
            self.assertEqual(launcher.read_bytes(), before)
            self.assertTrue(entry.is_dir())
            self.assertTrue(core.prepare_generated_sdkconfigs(origin, self.environment))

    def test_identity_mismatch_after_import_publishes_no_private_entry(self):
        # The identity check runs before an import becomes a private entry:
        # later restores prefer a valid private entry over the transport, so
        # a mismatched import must leave nothing behind.
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        transport_manifest = next((self.root / "transport").rglob("manifest.json"))
        key = json.loads(transport_manifest.read_text())["coreInputKey"]
        target = self.project("consumer")
        with self.fixture.fake_core(target):
            (target / "sdkconfig.defaults").unlink()
            with patch.object(core, "core_input_key", return_value="0" * 64):
                with self.assertRaisesRegex(core.GeneratedSdkconfigError, "identity changed"):
                    restore_shared_core(target, self.environment)
            self.assertFalse(os.path.lexists(core._core_cache_entry_dir(target, self.environment, key)))
            environment_root = target / ".pio/open-bike-build/core-cache" / self.environment
            self.assertEqual([path.name for path in environment_root.iterdir()] if environment_root.exists() else [], [])

    def test_invalid_private_entry_is_quarantined_before_import(self):
        # A private entry that no longer validates must not be preferred over
        # the transport: it is quarantined and the transport imported instead.
        origin = self.project("producer")
        with self.fixture.fake_core(origin) as installed:
            launcher = installed / "penv/bin/esptool"
            launcher.write_text(f"#!{installed}/penv/bin/python\norigin={origin}\n")
            self.publish(origin)
            before = launcher.read_bytes()
            key = core.core_input_key(origin, self.environment)
            entry = core._core_cache_entry_dir(origin, self.environment, key)
            archive = entry / core.CORE_ARCHIVE_FILENAME
            entry.chmod(0o755)
            archive.chmod(0o644)
            archive.write_bytes(b"corrupt")
            archive.chmod(0o444)
            entry.chmod(0o555)
            with self.assertRaisesRegex(core.GeneratedSdkconfigError, "digest"):
                core._validate_core_cache_entry(origin, self.environment, key)
            (origin / "sdkconfig.defaults").unlink()
            self.assertTrue(restore_shared_core(origin, self.environment))
            quarantined = list((entry.parent / "quarantine").iterdir())
            self.assertEqual(len(quarantined), 1)
            self.assertTrue(quarantined[0].name.startswith(key))
            self.assertEqual((quarantined[0] / core.CORE_ARCHIVE_FILENAME).read_bytes(), b"corrupt")
            core._validate_core_cache_entry(origin, self.environment, key)
            self.assertEqual(launcher.read_bytes(), before)
            self.assertTrue(core.prepare_generated_sdkconfigs(origin, self.environment))

    def test_ci_artifact_restores_on_a_runner_without_the_producer_cache(self):
        def ci(*arguments):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                core_artifact.main(list(arguments))
            return dict(line.split("=", 1) for line in output.getvalue().splitlines())

        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            self.publish(origin)
        # The warm run knows only the attested manifest's core input key, while
        # the shared entry is named by the request key a consumer computes.
        key = ci("identity", "--project", str(origin), "--environment", self.environment)["core-input-key"]
        archive = self.root / "firmware-core-entry.tar"
        packed = ci("pack", "--root", str(self.root / "transport/cores-v1" / self.environment),
                    "--key", key, "--output", str(archive))
        self.assertNotEqual(packed["request-key"], key)
        runner = self.root / "pull-request-runner"
        ci("install", "--archive", str(archive), "--root", str(runner / "cores-v1" / self.environment))
        target = self.project("consumer")
        with self.fixture.fake_core(target), patch.dict(os.environ, {"OPEN_BIKE_FIRMWARE_BUILD_CACHE": str(runner)}):
            (target / "sdkconfig.defaults").unlink()
            self.assertEqual(core.core_request_key(target, self.environment), packed["request-key"])
            self.assertTrue(restore_shared_core(target, self.environment))
            self.assertEqual(core.core_input_key(target, self.environment), key)

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

    def test_full_disk_skips_the_transport_and_the_next_clean_build_publishes_it(self):
        origin = self.project("producer")
        transport_root = self.root / "transport" / "cores-v1" / self.environment
        with self.fixture.fake_core(origin):
            core.record_generated_sdkconfig_defaults(origin, self.environment)
            output = io.StringIO()
            with (
                patch(
                    "shared_firmware_cache.shutil.copyfileobj",
                    side_effect=OSError(errno.ENOSPC, "No space left on device"),
                ),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(publish_shared_core(origin, self.environment), "skipped")
            # The skip leaves no temporary entry behind and names its numbers.
            self.assertEqual(sorted(path.name for path in transport_root.iterdir()), [".lock"])
            status = [
                line for line in output.getvalue().splitlines()
                if line.startswith("FIRMWARE_SHARED_CORE_CACHE ")
            ]
            self.assertEqual(len(status), 1)
            self.assertRegex(
                status[0],
                r"^FIRMWARE_SHARED_CORE_CACHE schema=1 status=skipped reason=enospc "
                rf"environment={self.environment} archiveBytes=[1-9][0-9]* freeBytes=[0-9]+$",
            )
            # The private entry is intact, so the next clean build publishes.
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(publish_shared_core(origin, self.environment), "published")
                self.assertEqual(publish_shared_core(origin, self.environment), "present")
            self.assertEqual(len(list(transport_root.rglob("transport.json"))), 1)

    def test_other_transport_write_errors_still_fail_publication(self):
        origin = self.project("producer")
        with self.fixture.fake_core(origin):
            core.record_generated_sdkconfig_defaults(origin, self.environment)
            with patch(
                "shared_firmware_cache.shutil.copyfileobj",
                side_effect=OSError(errno.EACCES, "Permission denied"),
            ):
                with self.assertRaises(OSError):
                    publish_shared_core(origin, self.environment)
        self.assertEqual(list((self.root / "transport").rglob("transport.json")), [])

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
