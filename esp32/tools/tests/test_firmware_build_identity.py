from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from firmware_build_identity import (
    build_timestamp_from_source_date_epoch,
    firmware_git_identity,
    git_commit_source_date_epoch,
)


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

    def test_commit_time_is_a_stable_source_date_epoch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.git(root, "init", "-q")
            self.git(root, "config", "user.email", "test@example.invalid")
            self.git(root, "config", "user.name", "Test")
            (root / "firmware.cpp").write_text("clean\n", encoding="utf-8")
            self.git(root, "add", "firmware.cpp")
            environment = dict(os.environ)
            environment.update(
                {
                    "GIT_AUTHOR_DATE": "2024-04-05T19:34:38Z",
                    "GIT_COMMITTER_DATE": "2024-04-05T19:34:38Z",
                }
            )
            subprocess.run(
                ["git", "commit", "-qm", "candidate"],
                cwd=root,
                env=environment,
                check=True,
            )

            full_sha = self.git(root, "rev-parse", "HEAD")
            source_date_epoch = git_commit_source_date_epoch(root, full_sha)
            self.assertEqual(source_date_epoch, "1712345678")
            self.assertEqual(
                build_timestamp_from_source_date_epoch(source_date_epoch),
                "2024-04-05T19:34:38Z",
            )

    def test_source_date_epoch_validation_fails_closed(self):
        for invalid in ("", "-1", "+1", "01", "1.5", "not-a-time"):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "canonical nonnegative"):
                    build_timestamp_from_source_date_epoch(invalid)
        with self.assertRaisesRegex(ValueError, "full Git commit SHA"):
            git_commit_source_date_epoch(Path.cwd(), "dirty")

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

    def test_index_flags_cannot_hide_modified_tracked_sources(self):
        for index_flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(index_flag=index_flag):
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

                    self.git(root, "update-index", index_flag, "firmware.cpp")
                    source.write_text("hidden modification\n", encoding="utf-8")
                    self.assertEqual(
                        firmware_git_identity(root),
                        f"dirty-{full_sha}",
                    )


if __name__ == "__main__":
    unittest.main()
