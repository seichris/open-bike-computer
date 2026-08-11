from __future__ import annotations

import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from device_registry import (
    DeviceRegistryError,
    default_registry_path,
    environment_matches_family,
    load_registry,
    main,
    resolve_device_name,
)


class DeviceRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name).resolve() / "config/devices.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_cli(self, *arguments: str) -> tuple[int, str, str]:
        output = StringIO()
        error = StringIO()
        with redirect_stdout(output), redirect_stderr(error):
            status = main(("--registry", str(self.path), *arguments))
        return status, output.getvalue(), error.getvalue()

    def test_add_list_show_rename_and_remove_are_atomic_and_private(self) -> None:
        status, output, _ = self.run_cli(
            "add", "desk-175", "WAVESHARE_AMOLED_175", "abc-123", "--note", "desk"
        )
        self.assertEqual(status, 0)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any(self.path.parent.glob(".devices.json.*")))
        changed = json.loads(output)
        self.assertEqual(changed["device"]["serialNumber"], "ABC-123")
        self.assertEqual(resolve_device_name("DESK-175", self.path).nickname, "desk-175")

        status, _, _ = self.run_cli("rename", "desk-175", "road-175")
        self.assertEqual(status, 0)
        self.assertEqual(resolve_device_name("road-175", self.path).serial, "ABC-123")

        status, output, _ = self.run_cli("list")
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output)["devices"][0]["nickname"], "road-175")

        status, output, _ = self.run_cli("remove", "road-175")
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output)["device"]["nickname"], "road-175")
        self.assertEqual(load_registry(self.path), ())

    def test_rejects_casefold_duplicate_names_and_serials(self) -> None:
        self.assertEqual(
            self.run_cli("add", "Desk", "WAVESHARE_AMOLED_175", "serial-1")[0], 0
        )
        self.assertEqual(
            self.run_cli("add", "desk", "WAVESHARE_AMOLED_206", "serial-2")[0], 1
        )
        self.assertEqual(
            self.run_cli("add", "other", "WAVESHARE_AMOLED_206", "SERIAL-1")[0], 1
        )

    def test_interrupted_update_preserves_the_previous_registry(self) -> None:
        self.assertEqual(
            self.run_cli(
                "add", "desk", "WAVESHARE_AMOLED_175", "serial-1"
            )[0],
            0,
        )
        before = self.path.read_bytes()
        with patch(
            "device_registry.os.replace",
            side_effect=OSError("injected replacement failure"),
        ):
            status, _, error = self.run_cli("rename", "desk", "road")
        self.assertEqual(status, 1)
        self.assertIn("could not update", error)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(any(self.path.parent.glob(".devices.json.*")))

    def test_rejects_duplicate_json_keys_and_unknown_schema(self) -> None:
        self.path.parent.mkdir(parents=True)
        self.path.write_text('{"schema":1,"schema":1,"devices":[]}\n', encoding="utf-8")
        self.path.chmod(0o600)
        with self.assertRaisesRegex(DeviceRegistryError, "duplicate JSON key"):
            load_registry(self.path)
        self.path.write_text('{"schema":2,"devices":[]}\n', encoding="utf-8")
        with self.assertRaisesRegex(DeviceRegistryError, "unsupported.*schema"):
            load_registry(self.path)

    def test_rejects_noncanonical_entries_and_non_timestamp_dates(self) -> None:
        self.path.parent.mkdir(parents=True)
        for field, value in (
            ("nickname", " desk"),
            ("serialNumber", "serial-1"),
            ("note", " padded "),
            ("updatedAt", "2026-08-10Z"),
        ):
            with self.subTest(field=field):
                entry = {
                    "nickname": "desk",
                    "boardFamily": "WAVESHARE_AMOLED_175",
                    "serialNumber": "SERIAL-1",
                    "note": "desk",
                    "updatedAt": "2026-08-10T00:00:00Z",
                }
                entry[field] = value
                self.path.write_text(
                    json.dumps({"schema": 1, "devices": [entry]}) + "\n",
                    encoding="utf-8",
                )
                self.path.chmod(0o600)
                with self.assertRaises(DeviceRegistryError):
                    load_registry(self.path)

    def test_rejects_symlink_and_unsafe_permissions(self) -> None:
        external = Path(self.temporary.name) / "external.json"
        external.write_text('{"schema":1,"devices":[]}\n', encoding="utf-8")
        external.chmod(0o600)
        self.path.parent.mkdir(parents=True)
        self.path.symlink_to(external)
        with self.assertRaisesRegex(DeviceRegistryError, "non-symlink"):
            load_registry(self.path)
        self.path.unlink()
        self.path.write_text('{"schema":1,"devices":[]}\n', encoding="utf-8")
        self.path.chmod(0o644)
        with self.assertRaisesRegex(DeviceRegistryError, "permissions"):
            load_registry(self.path)
        self.path.chmod(0o400)
        with self.assertRaisesRegex(DeviceRegistryError, "permissions"):
            load_registry(self.path)

    def test_rejects_hard_linked_registry(self) -> None:
        external = Path(self.temporary.name) / "external.json"
        external.write_text('{"schema":1,"devices":[]}\n', encoding="utf-8")
        external.chmod(0o600)
        self.path.parent.mkdir(parents=True)
        os.link(external, self.path)
        with self.assertRaisesRegex(DeviceRegistryError, "hard-linked"):
            load_registry(self.path)

    def test_relative_xdg_config_home_cannot_place_registry_in_checkout(self) -> None:
        with (
            patch("device_registry.sys.platform", "linux"),
            patch("device_registry.Path.home", return_value=Path("/safe/home")),
            patch.dict(os.environ, {"XDG_CONFIG_HOME": "relative-config"}),
        ):
            self.assertEqual(
                default_registry_path(),
                Path("/safe/home/.config/open-bike-computer/devices.json"),
            )

    def test_rejects_symlinked_parent_and_wrong_owner(self) -> None:
        real_parent = Path(self.temporary.name).resolve() / "real-config"
        real_parent.mkdir()
        linked_parent = Path(self.temporary.name).resolve() / "linked-config"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        linked_registry = linked_parent / "devices.json"
        linked_registry.write_text('{"schema":1,"devices":[]}\n', encoding="utf-8")
        linked_registry.chmod(0o600)
        with self.assertRaisesRegex(DeviceRegistryError, "symlinked directory"):
            load_registry(linked_registry)

        nested_registry = linked_parent / "new/config/devices.json"
        status, _, error = self.run_cli(
            "--registry",
            str(nested_registry),
            "add",
            "desk",
            "WAVESHARE_AMOLED_175",
            "SERIAL-1",
        )
        self.assertEqual(status, 1)
        self.assertIn("unsafe directory", error)
        self.assertFalse((real_parent / "new").exists())

        self.path.parent.mkdir(parents=True)
        self.path.write_text('{"schema":1,"devices":[]}\n', encoding="utf-8")
        self.path.chmod(0o600)
        if hasattr(os, "getuid"):
            with patch("device_registry.os.getuid", return_value=os.getuid() + 1):
                with self.assertRaisesRegex(DeviceRegistryError, "wrong owner"):
                    load_registry(self.path)

    def test_family_matching_accepts_profiles_but_not_other_board(self) -> None:
        self.assertTrue(
            environment_matches_family(
                "WAVESHARE_AMOLED_175_PRODUCTION", "WAVESHARE_AMOLED_175"
            )
        )
        self.assertFalse(
            environment_matches_family(
                "WAVESHARE_AMOLED_206", "WAVESHARE_AMOLED_175"
            )
        )


if __name__ == "__main__":
    unittest.main()
