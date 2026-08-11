from __future__ import annotations

import hashlib
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from firmware_runtime import (
    FirmwareRuntimeError,
    RuntimeLock,
    RuntimeTarget,
    _verify_runtime_tree,
    ensure_runtime_handoff,
    ensure_shared_runtime,
    extract_verified_bundle,
    host_target_id,
    load_lock,
    repair_runtime,
    select_target,
)


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


class FirmwareRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_bundle(self, *, extra_member: tuple[str, bytes, str] | None = None) -> tuple[Path, int, str]:
        files = {
            "bin/pio": b"#!/bin/sh\nexit 0\n",
            "bin/uv": b"#!/bin/sh\nexit 0\n",
            "python/bin/python3": b"#!/bin/sh\nexit 0\n",
            "requirements/pioarduino-root.txt": b"unit-test==1\n",
            "requirements/esp-idf.txt": b"unit-test==1\n",
            "wheelhouse/unit_test-1-py3-none-any.whl": b"not executed in verifier tests",
            "wheelhouse/esptool-5.1.0-py3-none-any.whl": b"not executed in verifier tests",
        }
        inventory = {
            "schema": 1,
            "files": [
                {
                    "path": name,
                    "size": len(contents),
                    "sha256": hashlib.sha256(contents).hexdigest(),
                    "executable": name.startswith(("bin/", "python/bin/")),
                }
                for name, contents in sorted(files.items())
            ],
        }
        bundle = self.root / "bundle.tar.gz"
        with tarfile.open(bundle, "w:gz") as archive:
            inventory_bytes = canonical(inventory)
            info = tarfile.TarInfo("inventory.json")
            info.size = len(inventory_bytes)
            archive.addfile(info, io.BytesIO(inventory_bytes))
            for name, contents in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(contents)
                info.mode = 0o755
                archive.addfile(info, io.BytesIO(contents))
            if extra_member is not None:
                name, contents, kind = extra_member
                info = tarfile.TarInfo(name)
                info.size = len(contents)
                if kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/tmp/escape"
                    info.size = 0
                    archive.addfile(info)
                else:
                    archive.addfile(info, io.BytesIO(contents))
        return bundle, bundle.stat().st_size, hashlib.sha256(bundle.read_bytes()).hexdigest()

    def make_lock(self, bundle: Path, size: int, digest: str, *, accepted: bool = True) -> Path:
        unit_wheel = b"not executed in verifier tests"
        esptool_wheel = b"not executed in verifier tests"
        unit_filename = "unit_test-1-py3-none-any.whl"
        esptool_filename = "esptool-5.1.0-py3-none-any.whl"
        def distribution_digest(members):
            return hashlib.sha256(canonical(sorted(members))).hexdigest()
        contents = {
            "platformioVersion": "6.1.18",
            "wheels": [
                {
                    "filename": unit_filename,
                    "normalizedName": "unit-test",
                    "version": "1",
                    "tags": ["py3-none-any"],
                    "size": len(unit_wheel),
                    "sha256": hashlib.sha256(unit_wheel).hexdigest(),
                    "sourceUrl": "https://example.invalid/unit.whl",
                    "sourceSha256": hashlib.sha256(unit_wheel).hexdigest(),
                    "group": "top-level",
                },
                {
                    "filename": esptool_filename,
                    "normalizedName": "esptool",
                    "version": "5.1.0",
                    "tags": ["py3-none-any"],
                    "size": len(esptool_wheel),
                    "sha256": hashlib.sha256(esptool_wheel).hexdigest(),
                    "sourceUrl": "https://example.invalid/esptool.whl",
                    "sourceSha256": hashlib.sha256(esptool_wheel).hexdigest(),
                    "group": "esptool",
                },
            ],
            "distributionSets": {
                "topLevel": {"sha256": distribution_digest([unit_filename]), "wheels": [unit_filename]},
                "pioarduinoRoot": {"sha256": distribution_digest([unit_filename]), "wheels": [unit_filename]},
                "espIdf": {"sha256": distribution_digest([unit_filename]), "wheels": [unit_filename]},
                "uv": {"sha256": distribution_digest([unit_filename]), "wheels": [unit_filename]},
                "esptool": {"sha256": distribution_digest([esptool_filename]), "wheels": [esptool_filename]},
            },
            "platform": {"archiveSha256": "e" * 64, "packagesSha256": "f" * 64},
        }
        value = {
            "schema": 1,
            "lockSetId": "unit-test-lock",
            "generator": {
                "version": "1",
                "commit": "a" * 40,
                "refreshInputsSha256": "b" * 64,
                "licensesSha256": "c" * 64,
            },
            "targets": [
                {
                    "id": "macos-arm64-cp313",
                    "os": "macos",
                    "architecture": "arm64",
                    "pythonVersion": "3.13.15",
                    "abi": "cp313",
                    "minimumPlatformTag": "macosx_11_0_arm64",
                    "accepted": accepted,
                    "python": {"url": "https://example.invalid/python.tar.gz", "size": 1, "sha256": "d" * 64},
                    "bundle": None if not accepted else {"url": "https://example.invalid/runtime.tar.gz", "size": size, "sha256": digest},
                    "contents": None if not accepted else contents,
                }
            ],
        }
        path = self.root / "lock.json"
        path.write_bytes(canonical(value))
        return path

    def test_strict_canonical_lock_and_duplicate_key_rejection(self) -> None:
        bundle, size, digest = self.make_bundle()
        path = self.make_lock(bundle, size, digest)
        lock = load_lock(path)
        self.assertEqual(lock.lock_set_id, "unit-test-lock")
        path.write_text('{"schema":1,"schema":1}\n')
        with self.assertRaisesRegex(FirmwareRuntimeError, "duplicate JSON key"):
            load_lock(path)
        path.write_text(json.dumps({"schema": 1}) + "\n")
        with self.assertRaisesRegex(FirmwareRuntimeError, "canonical|missing"):
            load_lock(path)

    def test_target_selection_and_unsupported_host_fail_before_bundle_use(self) -> None:
        bundle, size, digest = self.make_bundle()
        lock = load_lock(self.make_lock(bundle, size, digest))
        self.assertEqual(select_target(lock, "macos-arm64-cp313").abi, "cp313")
        with self.assertRaisesRegex(FirmwareRuntimeError, "unsupported.*supported targets"):
            select_target(lock, "linux-arm64-cp313")
        self.assertEqual(host_target_id(system="Darwin", machine="arm64"), "macos-arm64-cp313")
        self.assertEqual(host_target_id(system="Linux", machine="x86_64"), "linux-x86_64-cp313")

    def test_unaccepted_target_fails_closed(self) -> None:
        bundle, size, digest = self.make_bundle()
        lock = load_lock(self.make_lock(bundle, size, digest, accepted=False))
        with self.assertRaisesRegex(FirmwareRuntimeError, "no accepted bundle"):
            select_target(lock, "macos-arm64-cp313")

    def test_safe_extract_rejects_traversal_symlink_and_extra_files(self) -> None:
        for extra in (("../escape", b"x", "file"), ("link", b"", "symlink"), ("extra", b"x", "file")):
            with self.subTest(extra=extra[0]):
                bundle, _, _ = self.make_bundle(extra_member=extra)
                destination = self.root / f"out-{extra[0].replace('/', '_')}"
                with self.assertRaises(FirmwareRuntimeError):
                    extract_verified_bundle(bundle, destination)

    def test_shared_runtime_is_inventory_verified_and_mutation_fails(self) -> None:
        bundle, size, digest = self.make_bundle()
        lock = load_lock(self.make_lock(bundle, size, digest))
        target = select_target(lock, "macos-arm64-cp313")
        cache = self.root / "cache"
        base = cache / "locks" / lock.lock_set_id / target.target_id
        base.mkdir(parents=True)
        cached_bundle = base / f"{digest}.tar.gz"
        cached_bundle.write_bytes(bundle.read_bytes())
        accepted = ensure_shared_runtime(lock, target, cache_root=cache)
        provenance = _verify_runtime_tree(accepted, target)
        self.assertEqual(provenance.bundle_sha256, digest)
        victim = accepted / "bin/pio"
        victim.chmod(0o755)
        victim.write_bytes(b"tampered")
        with self.assertRaisesRegex(FirmwareRuntimeError, "changed"):
            ensure_shared_runtime(lock, target, cache_root=cache)

    def test_publication_renames_a_writable_root_then_locks_and_repairs_it(self) -> None:
        bundle, size, digest = self.make_bundle()
        lock = load_lock(self.make_lock(bundle, size, digest))
        target = select_target(lock, "macos-arm64-cp313")
        cache = self.root / "cache"
        base = cache / "locks" / lock.lock_set_id / target.target_id
        base.mkdir(parents=True)
        (base / f"{digest}.tar.gz").write_bytes(bundle.read_bytes())
        real_replace = os.replace

        def require_writable_root(source, destination):
            self.assertNotEqual(Path(source).stat().st_mode & 0o200, 0)
            return real_replace(source, destination)

        with mock.patch("firmware_runtime.os.replace", require_writable_root):
            accepted = ensure_shared_runtime(lock, target, cache_root=cache)
        self.assertEqual(accepted.stat().st_mode & 0o200, 0)

        repair_runtime(lock, target, self.root / "project", cache_root=cache)
        self.assertFalse(accepted.exists())
        self.assertFalse((base / f"{digest}.tar.gz").exists())

    def test_handoff_uses_only_verified_private_python(self) -> None:
        bundle, size, digest = self.make_bundle()
        lock_path = self.make_lock(bundle, size, digest)
        lock = load_lock(lock_path)
        target = select_target(lock, "macos-arm64-cp313")
        cache = self.root / "cache"
        base = cache / "locks" / lock.lock_set_id / target.target_id
        base.mkdir(parents=True)
        (base / f"{digest}.tar.gz").write_bytes(bundle.read_bytes())
        project = self.root / "project"
        (project / "tools").mkdir(parents=True)
        calls = []

        def capture(executable, command, environment):
            calls.append((executable, tuple(command), dict(environment)))
            raise RuntimeError("captured")

        real_replace = os.replace

        def require_writable_private_root(source, destination):
            if "host-runtime" in str(destination):
                self.assertNotEqual(Path(source).stat().st_mode & 0o200, 0)
            return real_replace(source, destination)

        with mock.patch(
            "firmware_runtime.host_target_id", return_value="macos-arm64-cp313"
        ), mock.patch("firmware_runtime.os.replace", require_writable_private_root):
            with self.assertRaisesRegex(RuntimeError, "captured"):
                ensure_runtime_handoff(
                    ("WAVESHARE_AMOLED_175",), project,
                    lock_path=lock_path, cache_root=cache, execve=capture,
                )
        self.assertIn("host-runtime", calls[0][0])
        self.assertTrue(Path(calls[0][0]).is_relative_to(project))
        self.assertEqual(calls[0][2]["PYTHONNOUSERSITE"], "1")
        self.assertNotIn(str(Path.home() / ".local/bin"), calls[0][2]["PATH"])

    def test_recovery_bootstrap_matches_tracked_python_artifacts(self) -> None:
        project = Path(__file__).resolve().parents[2]
        lock = load_lock(project / "tools/firmware-runtime/lock-v1.json")
        recovery = (project / "tools/build_firmware_bootstrap.sh").read_text(
            encoding="utf-8"
        )
        for target in lock.targets:
            self.assertIn(target.target_id, recovery)
            self.assertIn(str(target.python.size), recovery)
            self.assertIn(target.python.sha256, recovery)
            self.assertIn(target.python.url, recovery)


if __name__ == "__main__":
    unittest.main()
