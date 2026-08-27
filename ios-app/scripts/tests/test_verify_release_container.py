import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
IOS_ROOT = REPO_ROOT / "ios-app"
VERIFY_SCRIPT = IOS_ROOT / "scripts" / "verify-release-container.sh"
DEVELOPMENT_VERIFY_SCRIPT = (
    IOS_ROOT / "scripts" / "verify-development-container.sh"
)


class ReleaseContainerVerifierTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> Path:
        app = root / "BikeComputer.app"
        watch = app / "Watch" / "BikeComputerWatch.app"
        complication = watch / "PlugIns" / "BikeComputerWatchComplications.appex"
        live_activity = app / "PlugIns" / "BikeComputerLiveActivity.appex"
        watch.mkdir(parents=True)
        complication.mkdir(parents=True)
        live_activity.mkdir(parents=True)

        for path in [
            app / "BikeComputer",
            watch / "BikeComputerWatch",
            watch / "Assets.car",
            complication / "BikeComputerWatchComplications",
            live_activity / "BikeComputerLiveActivity",
        ]:
            path.write_bytes(b"fixture")

        shutil.copyfile(
            IOS_ROOT / "BikeComputer" / "BikeComputer" / "PrivacyInfo.xcprivacy",
            app / "PrivacyInfo.xcprivacy",
        )
        shutil.copyfile(
            IOS_ROOT / "BikeComputer" / "BikeComputerWatch" / "PrivacyInfo.xcprivacy",
            watch / "PrivacyInfo.xcprivacy",
        )
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "LetItRide.BikeComputer",
                    "CFBundleDisplayName": "Bicino",
                    "CFBundleIcons": {
                        "CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}
                    },
                    "BicinoURLScheme": "bikecomputer",
                    "CFBundleURLTypes": [
                        {"CFBundleURLSchemes": ["bikecomputer"]}
                    ],
                    "LSApplicationQueriesSchemes": ["strava"],
                    "NSSupportsLiveActivities": True,
                },
                handle,
            )
        with (watch / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "LetItRide.BikeComputer.watchkitapp",
                    "CFBundleDisplayName": "Bicino",
                    "BicinoURLScheme": "bikecomputer",
                    "WKCompanionAppBundleIdentifier": "LetItRide.BikeComputer",
                    "CFBundleURLTypes": [
                        {"CFBundleURLSchemes": ["another-scheme"]},
                        {"CFBundleURLSchemes": ["bikecomputer"]},
                    ],
                    "WKBackgroundModes": ["workout-processing"],
                    "CFBundleIcons": {
                        "CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}
                    },
                },
                handle,
            )
        with (complication / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": (
                        "LetItRide.BikeComputer.watchkitapp.complications"
                    ),
                    "CFBundleDisplayName": "Start Ride",
                    "BicinoURLScheme": "bikecomputer",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                    },
                },
                handle,
            )
        with (live_activity / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": (
                        "LetItRide.BikeComputer.WorkoutLiveActivity"
                    ),
                    "CFBundleDisplayName": "Bicino",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": (
                            "com.apple.widgetkit-extension"
                        )
                    },
                },
                handle,
            )
        return app

    def make_development_fixture(self, root: Path) -> Path:
        app = self.make_fixture(root)
        watch = app / "Watch" / "BikeComputerWatch.app"
        complication = watch / "PlugIns" / "BikeComputerWatchComplications.appex"
        live_activity = app / "PlugIns" / "BikeComputerLiveActivity.appex"

        replacements = [
            (
                app / "Info.plist",
                {
                    "CFBundleIdentifier": "LetItRide.BikeComputer.dev",
                    "CFBundleDisplayName": "Bicino Dev",
                    "CFBundleIcons": {
                        "CFBundlePrimaryIcon": {
                            "CFBundleIconName": "AppIconDev"
                        }
                    },
                    "BicinoURLScheme": "bikecomputer-dev",
                    "CFBundleURLTypes": [
                        {"CFBundleURLSchemes": ["bikecomputer-dev"]}
                    ],
                    "LSApplicationQueriesSchemes": ["strava"],
                    "NSSupportsLiveActivities": True,
                },
            ),
            (
                watch / "Info.plist",
                {
                    "CFBundleIdentifier": (
                        "LetItRide.BikeComputer.dev.watchkitapp"
                    ),
                    "CFBundleDisplayName": "Bicino Dev",
                    "BicinoURLScheme": "bikecomputer-dev",
                    "WKCompanionAppBundleIdentifier": (
                        "LetItRide.BikeComputer.dev"
                    ),
                    "CFBundleURLTypes": [
                        {"CFBundleURLSchemes": ["bikecomputer-dev"]}
                    ],
                },
            ),
            (
                complication / "Info.plist",
                {
                    "CFBundleIdentifier": (
                        "LetItRide.BikeComputer.dev.watchkitapp.complications"
                    ),
                    "CFBundleDisplayName": "Start Ride Dev",
                    "BicinoURLScheme": "bikecomputer-dev",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": (
                            "com.apple.widgetkit-extension"
                        )
                    },
                },
            ),
            (
                live_activity / "Info.plist",
                {
                    "CFBundleIdentifier": (
                        "LetItRide.BikeComputer.dev.WorkoutLiveActivity"
                    ),
                    "CFBundleDisplayName": "Bicino Dev",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": (
                            "com.apple.widgetkit-extension"
                        )
                    },
                },
            ),
        ]
        for plist_path, payload in replacements:
            with plist_path.open("wb") as handle:
                plistlib.dump(payload, handle)
        return app

    def run_verifier(self, app: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(VERIFY_SCRIPT), str(app)],
            check=False,
            capture_output=True,
            text=True,
        )

    def run_development_verifier(
        self, app: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(DEVELOPMENT_VERIFY_SCRIPT), str(app)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_complete_release_container_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            result = self.run_verifier(app)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_complete_development_container_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_development_fixture(Path(temporary))
            result = self.run_development_verifier(app)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_development_verifier_rejects_production_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            result = self.run_development_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_development_verifier_rejects_production_url_scheme(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_development_fixture(Path(temporary))
            watch_info = app / "Watch" / "BikeComputerWatch.app" / "Info.plist"
            with watch_info.open("rb") as handle:
                payload = plistlib.load(handle)
            payload["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append(
                "BikeComputer"
            )
            with watch_info.open("wb") as handle:
                plistlib.dump(payload, handle)

            result = self.run_development_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_release_verifier_rejects_development_url_scheme(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            watch_info = app / "Watch" / "BikeComputerWatch.app" / "Info.plist"
            with watch_info.open("rb") as handle:
                payload = plistlib.load(handle)
            payload["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append(
                "BikeComputer-Dev"
            )
            with watch_info.open("wb") as handle:
                plistlib.dump(payload, handle)

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_watch_bundle_without_primary_icon_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            watch_info = app / "Watch" / "BikeComputerWatch.app" / "Info.plist"
            with watch_info.open("rb") as handle:
                payload = plistlib.load(handle)
            del payload["CFBundleIcons"]
            with watch_info.open("wb") as handle:
                plistlib.dump(payload, handle)

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_watch_bundle_without_complication_extension(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            complication = (
                app
                / "Watch"
                / "BikeComputerWatch.app"
                / "PlugIns"
                / "BikeComputerWatchComplications.appex"
            )
            shutil.rmtree(complication)

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_watch_bundle_without_complication_url_scheme(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            watch_info = app / "Watch" / "BikeComputerWatch.app" / "Info.plist"
            with watch_info.open("rb") as handle:
                payload = plistlib.load(handle)
            del payload["CFBundleURLTypes"]
            with watch_info.open("wb") as handle:
                plistlib.dump(payload, handle)

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_container_without_live_activity_extension(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            shutil.rmtree(
                app / "PlugIns" / "BikeComputerLiveActivity.appex"
            )

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
