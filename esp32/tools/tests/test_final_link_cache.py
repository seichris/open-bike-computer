"""Check the final-link policy at PlatformIO's resolved post-script phase."""

import ast
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from record_flash_plan import require_fresh_final_link


class FinalLinkCacheTests(unittest.TestCase):
    def run_policy(self, deterministic, profile, program="firmware"):
        env = Mock()
        env.subst.side_effect = {
            "$PIOENV": profile,
            "$BUILD_DIR/${PROGNAME}.elf": f"build/{program}.elf",
        }.__getitem__
        with patch.dict(os.environ, {"OPEN_BIKE_DETERMINISTIC_BUILD": deterministic}):
            require_fresh_final_link(env)
        return env

    def test_verified_profiles_disable_only_resolved_elf_cache(self):
        for profile in ("WAVESHARE_AMOLED_175_REMOTE_DEBUG", "WAVESHARE_AMOLED_206"):
            with self.subTest(profile=profile):
                env = self.run_policy("1", profile)
                env.NoCache.assert_called_once_with("build/firmware.elf")

    def test_policy_uses_final_program_name_not_prebuild_default(self):
        env = self.run_policy("1", "WAVESHARE_AMOLED_175", "custom-final-name")
        env.NoCache.assert_called_once_with("build/custom-final-name.elf")

    def test_other_builds_are_unchanged(self):
        for deterministic, profile in (("0", "WAVESHARE_AMOLED_175"), ("1", "OTHER")):
            with self.subTest(deterministic=deterministic, profile=profile):
                self.run_policy(deterministic, profile).NoCache.assert_not_called()

    def test_policy_runs_from_post_script_with_imported_environment(self):
        root = Path(__file__).resolve().parents[2]
        self.assertIn("post:tools/record_flash_plan.py", (root / "platformio.ini").read_text())
        tree = ast.parse((root / "tools/record_flash_plan.py").read_text())
        import_block = tree.body[-1]
        self.assertIsInstance(import_block, ast.Try)
        policy = Mock()
        record = Mock()
        env = object()
        namespace = {"env": env, "require_fresh_final_link": policy, "record_flash_plan": record}
        exec(compile(ast.Module(body=import_block.orelse, type_ignores=[]), "post-script", "exec"), namespace)
        policy.assert_called_once_with(env)
        record.assert_called_once_with(env)
