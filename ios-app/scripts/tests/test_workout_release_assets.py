import json
import plistlib
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
IOS_PROJECT = REPO_ROOT / "ios-app" / "BikeComputer"
PRIVACY_POLICY_URL = (
    "https://github.com/seichris/open-bike-computer/blob/main/PRIVACY_POLICY.md"
)


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def project_object(project: str, object_id: str) -> str:
    match = re.search(
        rf"^\t\t{re.escape(object_id)} /\* [^\n]+ \*/ = \{{\n"
        rf"(?P<body>.*?)^\t\t\}};$",
        project,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing Xcode project object {object_id}")
    return match.group("body")


def target_build_configurations(project: str, target_name: str) -> dict[str, str]:
    target_matches = re.finditer(
        rf"^\t\t[A-F0-9]+ /\* {re.escape(target_name)} \*/ = \{{\n"
        rf"(?P<body>.*?)^\t\t\}};$",
        project,
        re.MULTILINE | re.DOTALL,
    )
    target_body = next(
        (
            match.group("body")
            for match in target_matches
            if "isa = PBXNativeTarget;" in match.group("body")
        ),
        None,
    )
    if target_body is None:
        raise AssertionError(f"missing Xcode target {target_name}")

    configuration_list_match = re.search(
        r"buildConfigurationList = ([A-F0-9]+) /\*", target_body
    )
    if configuration_list_match is None:
        raise AssertionError(f"missing configuration list for {target_name}")

    configuration_list = project_object(
        project, configuration_list_match.group(1)
    )
    configuration_ids = re.findall(
        r"^\s+([A-F0-9]+) /\* (Debug|Release) \*/,$",
        configuration_list,
        re.MULTILINE,
    )
    if {name for _, name in configuration_ids} != {"Debug", "Release"}:
        raise AssertionError(
            f"expected Debug and Release configurations for {target_name}"
        )
    return {
        name: project_object(project, configuration_id)
        for configuration_id, name in configuration_ids
    }


class WorkoutReleaseAssetsTests(unittest.TestCase):
    def test_release_identity_advances_the_distributed_app(self):
        project = (
            IOS_PROJECT / "BikeComputer.xcodeproj" / "project.pbxproj"
        ).read_text()
        release_notes = (
            REPO_ROOT
            / "docs"
            / "releases"
            / "watchos-workout-companion.md"
        ).read_text()

        targets = {
            "BikeComputer": "LetItRide.BikeComputer",
            "BikeComputerWatch": "LetItRide.BikeComputer.watchkitapp",
        }
        for target_name, bundle_identifier in targets.items():
            configurations = target_build_configurations(project, target_name)
            for configuration_name, settings in configurations.items():
                with self.subTest(
                    target=target_name, configuration=configuration_name
                ):
                    self.assertIn("CURRENT_PROJECT_VERSION = 7;", settings)
                    self.assertIn("MARKETING_VERSION = 1.1;", settings)
                    self.assertIn(
                        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_identifier};",
                        settings,
                    )
        self.assertIn("Release candidate: **1.1 (7)**", release_notes)

    def test_privacy_policy_is_reachable_and_covers_release_obligations(self):
        shared_policy = (
            IOS_PROJECT / "WorkoutShared" / "AppPrivacyPolicy.swift"
        ).read_text()
        ios_settings = (
            IOS_PROJECT / "BikeComputer" / "Views" / "SettingsView.swift"
        ).read_text()
        public_policy = (REPO_ROOT / "PRIVACY_POLICY.md").read_text()
        normalized_policy = " ".join(public_policy.split())
        disclosures = (
            REPO_ROOT / "docs" / "app-store-privacy-disclosures.md"
        ).read_text()

        self.assertIn(PRIVACY_POLICY_URL, shared_policy)
        self.assertIn("AppPrivacyPolicy.url", ios_settings)
        self.assertIn("same or equivalent privacy protection", normalized_policy)
        self.assertIn("30 days after a map job becomes ready", normalized_policy)
        self.assertIn("renaming or downloading a map does not extend", normalized_policy)
        self.assertIn("scheduled maintenance process", normalized_policy)
        self.assertIn("until you request its deletion", normalized_policy)
        self.assertIn(PRIVACY_POLICY_URL, disclosures)

    def test_watch_settings_exposes_the_installed_app_version(self):
        watch_root = (
            IOS_PROJECT
            / "BikeComputerWatch"
            / "Views"
            / "WatchWorkoutRootView.swift"
        ).read_text()
        watch_start = (
            IOS_PROJECT
            / "BikeComputerWatch"
            / "Views"
            / "WorkoutStartView.swift"
        ).read_text()
        watch_settings = (
            IOS_PROJECT
            / "BikeComputerWatch"
            / "Views"
            / "WatchSettingsView.swift"
        ).read_text()

        self.assertIn("NavigationStack", watch_root)
        self.assertIn("WatchSettingsView()", watch_start)
        self.assertIn('Image(systemName: "gearshape")', watch_start)
        self.assertIn('accessibilityLabel("Settings")', watch_start)
        self.assertNotIn("AppPrivacyPolicy.url", watch_start)
        self.assertIn('LabeledContent("Version"', watch_settings)
        self.assertIn('"CFBundleShortVersionString"', watch_settings)
        self.assertIn('"CFBundleVersion"', watch_settings)

    def test_permission_copy_and_entitlements_match_workout_ownership(self):
        ios_info = load_plist(IOS_PROJECT / "BikeComputer" / "Info.plist")
        watch_info = load_plist(IOS_PROJECT / "BikeComputerWatch" / "Info.plist")
        ios_entitlements = load_plist(
            IOS_PROJECT / "BikeComputer" / "BikeComputer.entitlements"
        )
        watch_entitlements = load_plist(
            IOS_PROJECT
            / "BikeComputerWatch"
            / "BikeComputerWatch.entitlements"
        )

        self.assertIn("Apple Watch", ios_info["NSHealthShareUsageDescription"])
        self.assertIn("HealthKit", ios_info["NSHealthUpdateUsageDescription"])
        self.assertIn("cycling workouts", watch_info["NSHealthUpdateUsageDescription"])
        self.assertIn("cycling metrics", watch_info["NSHealthShareUsageDescription"])
        self.assertIn("route", watch_info["NSLocationWhenInUseUsageDescription"])
        self.assertIn("workout-processing", watch_info["WKBackgroundModes"])
        self.assertTrue(watch_info["WKRunsIndependentlyOfCompanionApp"])
        self.assertEqual(
            watch_info["WKCompanionAppBundleIdentifier"],
            "LetItRide.BikeComputer",
        )
        self.assertTrue(ios_entitlements["com.apple.developer.healthkit"])
        self.assertTrue(watch_entitlements["com.apple.developer.healthkit"])

    def test_privacy_manifests_distinguish_backend_collection_from_healthkit(self):
        ios_privacy = load_plist(
            IOS_PROJECT / "BikeComputer" / "PrivacyInfo.xcprivacy"
        )
        watch_privacy = load_plist(
            IOS_PROJECT / "BikeComputerWatch" / "PrivacyInfo.xcprivacy"
        )

        self.assertFalse(ios_privacy["NSPrivacyTracking"])
        self.assertEqual(ios_privacy["NSPrivacyTrackingDomains"], [])
        collected = {
            entry["NSPrivacyCollectedDataType"]: entry
            for entry in ios_privacy["NSPrivacyCollectedDataTypes"]
        }
        self.assertEqual(
            set(collected),
            {
                "NSPrivacyCollectedDataTypePreciseLocation",
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypeOtherUserContent",
                "NSPrivacyCollectedDataTypeProductInteraction",
            },
        )
        for entry in collected.values():
            self.assertTrue(entry["NSPrivacyCollectedDataTypeLinked"])
            self.assertFalse(entry["NSPrivacyCollectedDataTypeTracking"])
            self.assertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
            )

        accessed = {
            entry["NSPrivacyAccessedAPIType"]: set(
                entry["NSPrivacyAccessedAPITypeReasons"]
            )
            for entry in ios_privacy["NSPrivacyAccessedAPITypes"]
        }
        self.assertEqual(
            accessed,
            {
                "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
                "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
            },
        )
        self.assertFalse(watch_privacy["NSPrivacyTracking"])
        self.assertEqual(watch_privacy["NSPrivacyCollectedDataTypes"], [])
        self.assertEqual(watch_privacy["NSPrivacyAccessedAPITypes"], [])

    def test_watch_app_has_a_platform_icon_and_release_assets(self):
        icon_contents = json.loads(
            (
                IOS_PROJECT
                / "BikeComputer"
                / "Assets.xcassets"
                / "AppIcon.appiconset"
                / "Contents.json"
            ).read_text()
        )
        watch_icons = [
            image
            for image in icon_contents["images"]
            if image.get("platform") == "watchos"
        ]
        self.assertEqual(len(watch_icons), 1)
        self.assertEqual(watch_icons[0]["size"], "1024x1024")
        self.assertTrue(watch_icons[0].get("filename"))

        project = (
            IOS_PROJECT / "BikeComputer.xcodeproj" / "project.pbxproj"
        ).read_text()
        self.assertIn("Assets.xcassets in Resources", project)
        self.assertEqual(
            project.count(
                "CODE_SIGN_ENTITLEMENTS = "
                "BikeComputer/BikeComputer.entitlements;"
            ),
            2,
            "iPhone Debug and Release must both reference HealthKit entitlements",
        )
        self.assertEqual(
            project.count(
                "CODE_SIGN_ENTITLEMENTS = "
                "BikeComputerWatch/BikeComputerWatch.entitlements;"
            ),
            2,
            "Watch Debug and Release must both reference HealthKit entitlements",
        )
        self.assertGreaterEqual(
            project.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"),
            3,
        )

        required_files = [
            REPO_ROOT / "PRIVACY_POLICY.md",
            REPO_ROOT / "ios-app" / "README.md",
            REPO_ROOT / "docs" / "app-store-privacy-disclosures.md",
            REPO_ROOT
            / "docs"
            / "releases"
            / "watchos-workout-companion.md",
            REPO_ROOT
            / "ios-app"
            / "AppStoreScreenshots"
            / "public"
            / "screenshots"
            / "watch"
            / "watch-live-workout.jpg",
        ]
        for path in required_files:
            self.assertTrue(path.is_file(), path)

        validation_issue_url = (
            "https://github.com/seichris/open-bike-computer/issues/117"
        )
        self.assertIn(
            validation_issue_url,
            (REPO_ROOT / "ios-app" / "README.md").read_text(),
        )
        self.assertIn(
            validation_issue_url,
            (
                REPO_ROOT
                / "docs"
                / "releases"
                / "watchos-workout-companion.md"
            ).read_text(),
        )

    def test_screenshot_release_package_is_available_for_manual_verification(self):
        screenshot_root = REPO_ROOT / "ios-app" / "AppStoreScreenshots"
        provenance = json.loads(
            (
                screenshot_root
                / "exports"
                / "app-store-screenshots"
                / "_provenance.json"
            ).read_text()
        )
        source_paths = {entry["path"] for entry in provenance["sources"]}
        self.assertEqual(provenance["schemaVersion"], 1)
        self.assertIn("src/app/page.tsx", source_paths)
        self.assertIn("src/app/styles.css", source_paths)
        self.assertIn(
            "public/screenshots/watch/watch-live-workout.jpg",
            source_paths,
        )
        self.assertIn("scripts/export-playwright.ts", source_paths)
        self.assertIn("scripts/release-package.ts", source_paths)

        package = json.loads((screenshot_root / "package.json").read_text())
        self.assertEqual(
            package["scripts"]["verify:release"],
            "tsx scripts/release-package.ts",
        )
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertNotIn("app-store-screenshots:", workflow)


if __name__ == "__main__":
    unittest.main()
