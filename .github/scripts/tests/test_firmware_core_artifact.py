import contextlib
import datetime as dt
import io
import json
import os
import stat
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import firmware_core_artifact as cores

KEY = "a" * 64
NOW = dt.datetime(2026, 10, 26, 12, 0, tzinfo=dt.timezone.utc)
REPOSITORY = 1001


def artifact(**overrides):
    value = {
        "id": 7, "name": "firmware-core-Linux-X64-WAVESHARE_AMOLED_175-" + "b" * 64, "expired": False,
        "created_at": "2026-10-25T12:00:00Z",
        "workflow_run": {"id": 42, "head_branch": "main", "repository_id": REPOSITORY, "head_repository_id": REPOSITORY},
    }
    run = overrides.pop("workflow_run", {})
    value.update(overrides)
    if run is not None:
        value["workflow_run"] = {**value["workflow_run"], **run}
    else:
        value["workflow_run"] = None
    return value


def select(*artifacts, max_age=dt.timedelta(days=7)):
    return cores.select_artifact(artifacts, name=artifact()["name"], repository_id=REPOSITORY, branch="main",
                                 now=NOW, max_age=max_age)


class SelectArtifactTests(unittest.TestCase):
    def test_newest_main_artifact_is_chosen_and_fresh(self):
        older = artifact(id=5, created_at="2026-10-18T12:00:00Z", workflow_run={"id": 40})
        chosen = select(older, artifact())
        self.assertEqual({"run_id": 42, "artifact_id": 7, "created_at": "2026-10-25T12:00:00+00:00", "fresh": True}, chosen)
        self.assertEqual({"run_id": 40, "artifact_id": 5, "created_at": "2026-10-18T12:00:00+00:00", "fresh": False}, select(older))
        self.assertTrue(select(older, max_age=dt.timedelta(days=8))["fresh"])

    def test_other_sources_are_never_consumed(self):
        rejected = (
            artifact(workflow_run={"head_repository_id": 2002}),   # fork run uploading the same name
            artifact(workflow_run={"repository_id": 2002}),
            artifact(workflow_run={"head_branch": "feature/main"}),
            artifact(workflow_run={"head_branch": "refs/heads/main"}),
            artifact(workflow_run=None),
            artifact(expired=True),
            artifact(expired=None),
            artifact(name="firmware-core-other"),
            artifact(id="7"),
            artifact(workflow_run={"id": "42"}),
            artifact(created_at="yesterday"),
            artifact(created_at="2026-10-25T12:00:00"),
        )
        for item in rejected:
            with self.subTest(item=item):
                self.assertIsNone(select(item))
        self.assertEqual(7, select(*rejected, artifact())["artifact_id"])

    def test_cli_reports_outputs_for_github(self):
        stale = artifact(created_at="2020-01-01T00:00:00Z")
        with patch.object(cores, "list_artifacts", return_value=[stale]) as listed:
            output = self.run_cli("select", "--repository", "owner/repo", "--repository-id", str(REPOSITORY),
                                  "--name", artifact()["name"], "--max-age-days", "1")
        listed.assert_called_once_with("owner/repo", artifact()["name"])
        self.assertIn("found=true\n", output)
        self.assertIn("run-id=42\n", output)
        self.assertIn("fresh=false\n", output)
        with patch.object(cores, "list_artifacts", return_value=[stale]):
            output = self.run_cli("select", "--repository", "owner/repo", "--repository-id", str(REPOSITORY),
                                  "--name", artifact()["name"], "--max-age-days", "100000")
        self.assertIn("fresh=true\n", output)
        with patch.object(cores, "list_artifacts", return_value=[]):
            output = self.run_cli("select", "--repository", "owner/repo", "--repository-id", str(REPOSITORY), "--name", "x")
        self.assertIn("found=false\n", output)
        self.assertIn("run-id=\n", output)
        with self.assertRaises(SystemExit):
            self.run_cli("select", "--repository", "owner/repo", "--repository-id", "1", "--name", "bad name")

    def run_cli(self, *argv):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cores.main(list(argv))
        return output.getvalue()


class EntryTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "producer/cores-v1/WAVESHARE_AMOLED_175"
        entry = self.root / KEY
        (entry / "core").mkdir(parents=True)
        (entry / "transport.json").write_text(json.dumps({"requestKey": KEY}))
        (entry / "core/core-artifacts.tar").write_bytes(b"\x00" * 4096)
        (entry / "core/manifest.json").write_text("{}")
        for path in sorted(entry.rglob("*"), reverse=True):
            path.chmod(0o555 if path.is_dir() else 0o444)
        entry.chmod(0o555)
        self.archive = Path(self.temporary.name) / "firmware-core-entry.tar"

    def tearDown(self):
        for path in Path(self.temporary.name).rglob("*"):
            if path.is_dir():
                path.chmod(0o755)

    def modes(self, root):
        return {str(p.relative_to(root)): oct(stat.S_IMODE(p.stat().st_mode)) for p in sorted(root.rglob("*"))}

    def test_pack_and_install_round_trip_keeps_read_only_entry(self):
        packed = cores.main(["pack", "--root", str(self.root), "--key", KEY, "--output", str(self.archive)])
        self.assertEqual(0, packed)
        consumer = Path(self.temporary.name) / "consumer/cores-v1/WAVESHARE_AMOLED_175"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cores.main(["install", "--archive", str(self.archive), "--root", str(consumer)])
        self.assertIn("installed=true\n", output.getvalue())
        self.assertIn(f"core-input-key={KEY}\n", output.getvalue())
        self.assertEqual(self.modes(self.root), self.modes(consumer))
        self.assertEqual({f"{KEY}": "0o555", f"{KEY}/core": "0o555", f"{KEY}/core/core-artifacts.tar": "0o444",
                          f"{KEY}/core/manifest.json": "0o444", f"{KEY}/transport.json": "0o444"}, self.modes(consumer))
        self.assertEqual(b"\x00" * 4096, (consumer / KEY / "core/core-artifacts.tar").read_bytes())
        for parent in (consumer, consumer.parent):
            self.assertEqual(0, parent.stat().st_mode & 0o022)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cores.main(["install", "--archive", str(self.archive), "--root", str(consumer)])
        self.assertIn("installed=false\n", output.getvalue())

    def test_pack_requires_a_complete_entry(self):
        with self.assertRaises(SystemExit):
            cores.main(["pack", "--root", str(self.root), "--key", "b" * 64, "--output", str(self.archive)])
        with self.assertRaises(SystemExit):
            cores.main(["pack", "--root", str(self.root), "--key", "../x", "--output", str(self.archive)])

    def test_install_rejects_foreign_archive_members(self):
        def archive_with(members):
            path = Path(self.temporary.name) / "bad.tar"
            with tarfile.open(path, "w:") as archive:
                for name, kind in members:
                    info = tarfile.TarInfo(name)
                    if kind == "dir":
                        info.type = tarfile.DIRTYPE
                    elif kind == "link":
                        info.type = tarfile.SYMTYPE
                        info.linkname = "/etc/passwd"
                    else:
                        info.size = 0
                    archive.addfile(info, io.BytesIO(b"") if kind == "file" else None)
            return path

        entry = [(KEY, "dir"), (f"{KEY}/transport.json", "file"), (f"{KEY}/core", "dir"), (f"{KEY}/core/core-artifacts.tar", "file")]
        bad = {
            "symlink": entry + [(f"{KEY}/core/link", "link")],
            "second entry": entry + [("b" * 64, "dir")],
            "extra top-level file": entry + [(f"{KEY}/extra", "file")],
            "nested core directory": entry + [(f"{KEY}/core/nested", "dir"), (f"{KEY}/core/nested/file", "file")],
            "parent traversal": [("../" + KEY, "dir")],
            "absolute": [("/" + KEY, "dir")],
            "not a key": [("entry", "dir")],
            "transport as directory": [(KEY, "dir"), (f"{KEY}/transport.json", "dir")],
        }
        for label, members in bad.items():
            with self.subTest(label=label):
                consumer = Path(self.temporary.name) / f"consumer-{abs(hash(label))}/cores-v1/WAVESHARE_AMOLED_175"
                with self.assertRaises(SystemExit):
                    cores.main(["install", "--archive", str(archive_with(members)), "--root", str(consumer)])
                self.assertFalse((consumer / KEY).exists())
        incomplete = archive_with([(KEY, "dir"), (f"{KEY}/transport.json", "file")])
        consumer = Path(self.temporary.name) / "consumer-incomplete/cores-v1/WAVESHARE_AMOLED_175"
        with self.assertRaises(SystemExit):
            cores.main(["install", "--archive", str(incomplete), "--root", str(consumer)])


class IdentityTests(unittest.TestCase):
    def test_identity_reads_the_attested_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            manifest = project / ".pio/open-bike-build/builds/WAVESHARE_AMOLED_175/current.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"environment": "WAVESHARE_AMOLED_175", "uploadEligible": True,
                                            "coreInputKey": KEY, "coreCache": "miss"}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                cores.main(["identity", "--project", str(project), "--environment", "WAVESHARE_AMOLED_175"])
            self.assertEqual(f"core-input-key={KEY}\ncore-cache=miss\n", output.getvalue())
            manifest.write_text(json.dumps({"environment": "WAVESHARE_AMOLED_175", "uploadEligible": True,
                                            "coreInputKey": KEY}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                cores.main(["identity", "--project", str(project), "--environment", "WAVESHARE_AMOLED_175"])
            self.assertEqual(f"core-input-key={KEY}\ncore-cache=unknown\n", output.getvalue())
            for broken in ({"uploadEligible": False}, {"environment": "WAVESHARE_AMOLED_206"},
                           {"coreInputKey": "short"}):
                manifest.write_text(json.dumps({"environment": "WAVESHARE_AMOLED_175", "uploadEligible": True,
                                                "coreInputKey": KEY, "coreCache": "hit", **broken}))
                with self.subTest(broken=broken), self.assertRaises(SystemExit):
                    cores.main(["identity", "--project", str(project), "--environment", "WAVESHARE_AMOLED_175"])


if __name__ == "__main__":
    unittest.main()
