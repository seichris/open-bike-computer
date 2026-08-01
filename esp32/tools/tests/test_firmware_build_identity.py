from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from firmware_build_identity import firmware_git_identity


class FirmwareBuildIdentityTests(unittest.TestCase):
    def git(self, root: Path, *args: str) -> str:
        return subprocess.check_output(
            ["git", *args],
            cwd=root,
            text=True,
        ).strip()

    def test_clean_commit_uses_full_sha_and_dirty_tree_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.git(root, "init", "-q")
            self.git(root, "config", "user.email", "test@example.invalid")
            self.git(root, "config", "user.name", "Test")
            source = root / "firmware.cpp"
            source.write_text("clean\n", encoding="utf-8")
            self.git(root, "add", "firmware.cpp")
            self.git(root, "commit", "-qm", "candidate")

            full_sha = self.git(root, "rev-parse", "HEAD")
            self.assertEqual(len(full_sha), 40)
            self.assertEqual(firmware_git_identity(root), full_sha)

            source.write_text("dirty\n", encoding="utf-8")
            self.assertEqual(firmware_git_identity(root), f"dirty-{full_sha}")

    def test_allows_only_explicit_generated_untracked_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.git(root, "init", "-q")
            self.git(root, "config", "user.email", "test@example.invalid")
            self.git(root, "config", "user.name", "Test")
            source = root / "firmware.cpp"
            source.write_text("clean\n", encoding="utf-8")
            self.git(root, "add", "firmware.cpp")
            self.git(root, "commit", "-qm", "candidate")
            full_sha = self.git(root, "rev-parse", "HEAD")

            generated = root / "sdkconfig.TEST"
            generated.write_text("generated\n", encoding="utf-8")
            self.assertEqual(firmware_git_identity(root), f"dirty-{full_sha}")
            self.assertEqual(
                firmware_git_identity(
                    root,
                    allowed_untracked_paths=(generated,),
                ),
                full_sha,
            )

            (root / "manual.txt").write_text("dirty\n", encoding="utf-8")
            self.assertEqual(
                firmware_git_identity(
                    root,
                    allowed_untracked_paths=(generated,),
                ),
                f"dirty-{full_sha}",
            )


if __name__ == "__main__":
    unittest.main()
