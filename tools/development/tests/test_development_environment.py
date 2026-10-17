import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import tomllib
except ImportError:  # Python 3.10
    tomllib = None

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


environment = load("development_environment", ROOT / "tools/development/environment.py")
SPEC = environment.Environment("test", ".venv", ("-r", "requirements.txt"), ("requirements.txt",))


class DevelopmentEnvironmentTests(unittest.TestCase):
    def temporary_root(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def test_fingerprint_follows_nested_requirement_files(self):
        root = self.temporary_root()
        (root / "nested").mkdir()
        (root / "requirements.txt").write_text("-r nested/pins.txt  # shared pins\ncryptography==50.0.0\n")
        (root / "nested/pins.txt").write_text("Pillow==11.3.0\n")
        self.assertEqual(environment.requirement_files(root / "requirements.txt"),
                         [root / "requirements.txt", (root / "nested/pins.txt").resolve()])
        before = environment.fingerprint(SPEC, root)
        (root / "nested/pins.txt").write_text("Pillow==11.3.1\n")
        self.assertNotEqual(environment.fingerprint(SPEC, root), before)

    def test_hung_broken_and_unsupported_interpreters_are_skipped(self):
        with patch.object(environment.subprocess, "run", side_effect=subprocess.TimeoutExpired("python", 20)):
            self.assertIsNone(environment.probe("python3"))
        with patch.object(environment.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "3.9.18\n", "")
            self.assertIsNone(environment.probe("python3"))
        versions = {"/bin/python3.13": None, "/bin/python3.12": (3, 12, 4)}
        with patch.dict(os.environ, {}, clear=False), \
             patch.object(environment.shutil, "which", side_effect=lambda name: f"/bin/{name}"), \
             patch.object(environment.os.path, "realpath", side_effect=lambda path: path), \
             patch.object(environment, "probe", side_effect=lambda path: versions.get(path)):
            os.environ.pop("OPEN_BIKE_PYTHON", None)
            self.assertEqual(environment.choose_interpreter(), ("/bin/python3.12", (3, 12, 4)))
        with patch.dict(os.environ, {"OPEN_BIKE_PYTHON": "/broken/python"}), \
             patch.object(environment, "probe", return_value=None):
            with self.assertRaisesRegex(environment.SetupError, "OPEN_BIKE_PYTHON"):
                environment.choose_interpreter()

    @unittest.skipUnless(environment.probe(sys.executable), "needs a Python with venv and ensurepip")
    def test_setup_is_idempotent_and_updates_in_place_when_inputs_change(self):
        root = self.temporary_root()
        (root / "requirements.txt").write_text("# no packages\n")
        installs = []
        with patch.object(environment, "choose_interpreter", return_value=(sys.executable, sys.version_info[:3])), \
             patch.object(environment, "pip_install", side_effect=lambda *args, **kwargs: installs.append(args)):
            self.assertIn("created", environment.ensure(SPEC, root=root))
            (root / ".venv/kept").write_text("kept")
            self.assertIn("up to date", environment.ensure(SPEC, root=root))
            self.assertEqual(len(installs), 1)
            (root / "requirements.txt").write_text("qrcode==8.2\n")
            self.assertEqual(environment.state(SPEC, root)[0], "stale")
            self.assertIn("updated", environment.ensure(SPEC, root=root))
        self.assertEqual(len(installs), 2)
        self.assertTrue((root / ".venv/kept").exists())
        self.assertEqual(environment.state(SPEC, root)[0], "ready")

    def test_broken_environment_is_reported_then_moved_aside_never_deleted(self):
        root = self.temporary_root()
        (root / "requirements.txt").write_text("")
        (root / ".venv/bin").mkdir(parents=True)
        (root / ".venv/bin/python").write_text("not an interpreter")
        self.assertEqual(environment.state(SPEC, root), ("broken", None))
        with self.assertRaisesRegex(environment.SetupError, "--recreate"):
            environment.ensure(SPEC, root=root)
        with patch.object(environment, "state", return_value=("broken", None)), \
             patch.object(environment, "choose_interpreter", return_value=(sys.executable, sys.version_info[:3])), \
             patch.object(environment.subprocess, "run", side_effect=lambda command, **kwargs: Path(command[-1]).mkdir()), \
             patch.object(environment, "pip_install"), \
             contextlib.redirect_stdout(io.StringIO()):
            environment.ensure(SPEC, root=root, recreate=True)
        kept = [path for path in root.iterdir() if path.name.startswith(".venv.previous-")]
        self.assertEqual(len(kept), 1)
        self.assertEqual((kept[0] / "bin/python").read_text(), "not an interpreter")

    def test_setup_lock_is_exclusive_and_lives_in_the_worktree_git_directory(self):
        path = self.temporary_root() / "setup.lock"
        with environment.acquire_lock(path):
            with self.assertRaises(BlockingIOError):
                environment.acquire_lock(path, wait=False)
        environment.acquire_lock(path, wait=False).close()
        git_dir = subprocess.check_output(["git", "rev-parse", "--absolute-git-dir"], cwd=ROOT, text=True).strip()
        self.assertEqual(environment.lock_path().parent, Path(git_dir).resolve())

    def test_run_refuses_unready_environments_and_prefixes_ready_ones(self):
        arguments = type("Arguments", (), {"map_backend": False, "command": ["python3", "-V"]})
        for status in ("missing", "broken", "stale"):
            with self.subTest(status=status), patch.object(environment, "state", return_value=(status, None)), \
                 patch.object(environment.os, "execvpe") as execute, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(environment.run(arguments), 3)
                execute.assert_not_called()
        with patch.object(environment, "state", return_value=("ready", "3.13.0")), \
             patch.object(environment.os, "execvpe") as execute, \
             patch.dict(os.environ, {"VIRTUAL_ENV": "/elsewhere", "PYTHONHOME": "/elsewhere"}):
            environment.run(arguments)
        variables = execute.call_args.args[2]
        self.assertTrue(variables["PATH"].startswith(str(ROOT / ".venv/bin") + os.pathsep))
        # esp32/tools/build_firmware.py rejects both as ambient build overrides.
        self.assertNotIn("VIRTUAL_ENV", variables)
        self.assertNotIn("PYTHONHOME", variables)

    def test_blocked_summary_comes_from_the_registry_runner(self):
        def plan(command, **kwargs):
            report = Path(command[command.index("--report") + 1])
            report.write_text(json.dumps({"checks": [
                {"id": "firmware-build", "status": "blocked",
                 "reasons": ["select the identified board with --board 175 or --board 206"]},
                {"id": "map-backend-tests", "status": "blocked", "reasons": ["missing Python module: fastapi"]},
                {"id": "esp32-host-device-ownership-crypto-host-tests", "status": "blocked",
                 "reasons": ["prerequisite probe failed: pkg-config --exists mbedcrypto"]},
                {"id": "development-tools", "status": "planned", "reasons": []}]}))
            self.assertEqual(command[2:5], ["--plan", "--suite", "all"])
            return subprocess.CompletedProcess(command, 0, "", "")
        with patch.object(environment.subprocess, "run", side_effect=plan):
            blocked = environment.blocked_checks(environment.HOST, "all")
        self.assertEqual([check["id"] for check in blocked], ["esp32-host-device-ownership-crypto-host-tests"])

    @unittest.skipIf(tomllib is None, "tomllib requires Python 3.11")
    def test_codex_environment_uses_the_app_schema_and_shared_setup(self):
        config = tomllib.loads((ROOT / ".codex/environments/environment.toml").read_text())
        self.assertLessEqual(set(config), {"version", "name", "setup", "cleanup", "actions"})
        self.assertEqual(config["version"], 1)
        self.assertIn("tools/dev-setup", config["setup"]["script"])
        self.assertNotIn("board", config["setup"]["script"])
        for action in config["actions"]:
            with self.subTest(action=action["name"]):
                self.assertLessEqual(set(action), {"name", "icon", "command", "platform"})
                self.assertIn(action.get("icon"), {"tool", "run", "debug", "test", None})
                self.assertRegex(action["command"], r"tools/dev-(setup|env)")
                for forbidden in ("upload", "--device", "devicectl", "deploy"):
                    self.assertNotIn(forbidden, action["command"])
                if "firmware" in action["command"]:
                    self.assertRegex(action["command"], r"--board (175|206)$")

    def test_claude_adapters_share_setup_instructions_and_skills(self):
        settings = json.loads((ROOT / ".claude/settings.json").read_text())
        commands = [hook["command"] for entry in settings["hooks"]["SessionStart"] for hook in entry["hooks"]]
        self.assertEqual(commands, ['"$CLAUDE_PROJECT_DIR"/tools/dev-setup --quiet'])
        self.assertIn("\n@AGENTS.md\n", (ROOT / "CLAUDE.md").read_text())
        self.assertEqual((ROOT / ".claude/skills").resolve(), (ROOT / ".agents/skills").resolve())
        for name, action in (("dev-setup", "setup"), ("dev-env", "run")):
            entry = ROOT / "tools" / name
            self.assertTrue(os.access(entry, os.X_OK))
            self.assertIn(f'/development/environment.py" {action} "$@"', entry.read_text())


if __name__ == "__main__":
    unittest.main()
