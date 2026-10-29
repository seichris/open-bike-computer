import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import firmware_ota_channels as channels

TARGETS = channels.TARGETS
LEGACY_LIMIT = channels.LEGACY.max_application_bytes
CURRENT_LIMIT = channels.CURRENT.max_application_bytes


def manifest(target, build, size):
    return json.dumps({"target": target, "build": build, "size": size,
                       "version": "0.4.0", "signature": "s"}).encode()


def release(build, sizes):
    return {target: manifest(target, build, size) for target, size in zip(TARGETS, sizes)}


def history(*releases):
    return [{"tag": f"v{build}", "build": build, "manifests": release(build, sizes)}
            for build, sizes in releases]


class OtaChannelTests(unittest.TestCase):
    def test_legacy_fitting_release_feeds_both_channels(self):
        current = release(110, (3_012_496, LEGACY_LIMIT))
        staged = channels.channel_manifests(current, None, maximum_build=110)
        for target in TARGETS:
            self.assertEqual(staged[target], {"legacy": current[target], "current": current[target]})

    def test_oversized_target_keeps_the_live_legacy_channel(self):
        current = release(120, (3_012_496, LEGACY_LIMIT + 1))
        published = history((105, (3_012_496, 3_005_808)), (110, (3_050_000, 3_060_000)),
                            (115, (3_070_000, LEGACY_LIMIT + 10)))
        live = {target: published[1]["manifests"][target] for target in TARGETS}
        staged = channels.channel_manifests(current, published, maximum_build=120, live_legacy=live)
        # One board can stay on its live legacy release while the other advances.
        self.assertEqual(staged[TARGETS[0]]["legacy"], current[TARGETS[0]])
        self.assertEqual(staged[TARGETS[1]]["legacy"], live[TARGETS[1]])
        self.assertEqual(staged[TARGETS[1]]["current"], current[TARGETS[1]])

    def test_a_rolled_back_release_is_never_re_advanced(self):
        # 112 fit but was rolled back to 110 with Pages recovery and stays
        # published. An oversized 120 must keep 110, not the newer 112.
        published = history((110, (3_000_000, 3_000_000)), (112, (3_010_000, 3_010_000)))
        live = {target: published[0]["manifests"][target] for target in TARGETS}
        staged = channels.channel_manifests(release(120, (LEGACY_LIMIT + 1,) * 2), published,
                                            maximum_build=120, live_legacy=live)
        self.assertEqual({json.loads(staged[t]["legacy"])["build"] for t in TARGETS}, {110})

    def test_recovery_never_points_the_legacy_channel_past_the_recovered_build(self):
        recovered = release(115, (LEGACY_LIMIT + 1, LEGACY_LIMIT + 1))
        published = history((110, (3_000_000, 3_000_000)), (125, (3_000_000, 3_000_000)))
        newer = {target: published[1]["manifests"][target] for target in TARGETS}
        with self.assertRaisesRegex(ValueError, "recover it explicitly"):
            channels.channel_manifests(recovered, published, maximum_build=115, live_legacy=newer)
        older = {target: published[0]["manifests"][target] for target in TARGETS}
        staged = channels.channel_manifests(recovered, published, maximum_build=115, live_legacy=older)
        self.assertEqual({json.loads(staged[t]["legacy"])["build"] for t in TARGETS}, {110})

    def test_unservable_states_fail_closed(self):
        oversized = release(120, (LEGACY_LIMIT + 1,) * 2)
        published = history((110, (LEGACY_LIMIT + 1,) * 2), (111, (3_000_000, 3_000_000)))
        unpublished = {target: manifest(target, 111, 3_000_000) + b" " for target in TARGETS}
        too_large = {target: published[0]["manifests"][target] for target in TARGETS}
        for live in (unpublished, too_large):
            with self.assertRaisesRegex(ValueError, "recover it explicitly"):
                channels.channel_manifests(oversized, published, maximum_build=120, live_legacy=live)
        with self.assertRaisesRegex(ValueError, "required"):
            channels.channel_manifests(oversized, published, maximum_build=120)
        with self.assertRaisesRegex(ValueError, "required"):
            channels.channel_manifests(oversized, None, maximum_build=120, live_legacy=unpublished)
        with self.assertRaisesRegex(ValueError, "slot reserve"):
            channels.channel_manifests(release(120, (CURRENT_LIMIT + 1, 1)), [], maximum_build=120)
        with self.assertRaisesRegex(ValueError, "build"):
            channels.channel_manifests(release(119, (1, 1)), [], maximum_build=120)
        swapped = release(120, (1, 1))
        swapped[TARGETS[0]] = manifest(TARGETS[1], 120, 1)
        with self.assertRaisesRegex(ValueError, "invalid"):
            channels.channel_manifests(swapped, [], maximum_build=120)

    def test_writes_both_channel_paths_create_only(self):
        current = release(110, (3_012_496, 3_005_808))
        staged = channels.channel_manifests(current, None, maximum_build=110)
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            written = channels.write_channels(public, staged)
            self.assertEqual(sorted(p.relative_to(public).as_posix() for p in written), sorted(
                f"{target}/{suffix}" for target in TARGETS
                for suffix in ("manifest.json", "dual4m/manifest.json")))
            self.assertEqual((public / TARGETS[0] / "manifest.json").read_bytes(), current[TARGETS[0]])
            with self.assertRaisesRegex(ValueError, "create-only"):
                channels.write_channels(public, staged)

    def test_main_reads_history_and_live_channel_only_when_needed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = root / "assets"
            assets.mkdir()
            for target, data in release(110, (3_000_000, 3_000_000)).items():
                (assets / f"{target}.manifest.json").write_bytes(data)
            argv = ["firmware_ota_channels.py", "--repository", "owner/repo",
                    "--release-assets", str(assets), "--public-dir", str(root / "public")]
            with patch.object(sys, "argv", argv), patch.object(channels, "published_manifests") as fetch, \
                    patch.object(channels, "live_legacy_manifests") as live:
                self.assertEqual(channels.main(), 0)
                fetch.assert_not_called()
                live.assert_not_called()
            (assets / f"{TARGETS[1]}.manifest.json").write_bytes(manifest(TARGETS[1], 110, LEGACY_LIMIT + 1))
            argv[-1] = str(root / "public-2")
            published = history((105, (3_000_000, 3_000_000)))
            with patch.object(sys, "argv", argv), patch.object(
                    channels, "published_manifests", return_value=published) as fetch, \
                    patch.object(channels, "live_legacy_manifests",
                                 return_value=published[0]["manifests"]) as live:
                self.assertEqual(channels.main(), 0)
                fetch.assert_called_once_with("owner/repo")
                live.assert_called_once_with(channels.PAGES_URL)
            self.assertEqual(json.loads((root / "public-2" / TARGETS[1] / "manifest.json").read_bytes())["build"], 105)


if __name__ == "__main__":
    unittest.main()
