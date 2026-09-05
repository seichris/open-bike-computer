"""Exercise the prebuild final-link policy without starting PlatformIO."""

import ast
from pathlib import Path
import unittest
from unittest.mock import Mock


class PrebuildLinkCacheTests(unittest.TestCase):
    def run_link_policy(self, deterministic, target):
        source = Path(__file__).resolve().parents[2] / "prebuild.py"
        tree = ast.parse(source.read_text())
        blocks = [
            node for node in tree.body
            if isinstance(node, ast.If)
            and any(
                isinstance(child, ast.Call)
                and isinstance(child.func, ast.Attribute)
                and child.func.attr == "AddPreAction"
                for child in ast.walk(node)
            )
        ]
        self.assertEqual(len(blocks), 1)
        env = Mock()
        namespace = {
            "deterministic_build": deterministic,
            "firmware_target": target,
            "env": env,
            "record_link_start": object(),
            "record_link_finish": object(),
        }
        exec(compile(ast.Module(body=blocks, type_ignores=[]), str(source), "exec"), namespace)
        return env, namespace

    def test_verified_waveshare_links_cannot_be_retrieved_without_map(self):
        for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
            with self.subTest(target=target):
                env, namespace = self.run_link_policy(True, target)
                link_target = "$BUILD_DIR/${PROGNAME}.elf"
                env.NoCache.assert_called_once_with(link_target)
                env.AddPreAction.assert_called_once_with(link_target, namespace["record_link_start"])
                env.AddPostAction.assert_called_once_with(link_target, namespace["record_link_finish"])
                self.assertEqual(env.method_calls[0][0], "NoCache")

    def test_unverified_build_policy_is_unchanged(self):
        env, _ = self.run_link_policy(False, "WAVESHARE_AMOLED_175")
        self.assertEqual(env.method_calls, [])

    def test_other_board_policy_is_unchanged(self):
        env, _ = self.run_link_policy(True, "OTHER_BOARD")
        self.assertEqual(env.method_calls, [])
