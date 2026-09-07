#!/usr/bin/env python3
"""Compile the immutable pre-388 decoder and exercise current Watch output.

Requires that commit locally (no fetch/network and no changes to a checkout).
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LEGACY = "fe73e43431ed76c39159de7624c4cd9ede509434"
SOURCES = ["WorkoutMetricUnits.swift", "WorkoutHeartRateZones.swift", "WorkoutValueFormatter.swift",
           "RideAutomationContract.swift", "WorkoutContract.swift"]

with tempfile.TemporaryDirectory(prefix="legacy-workout-decoder-") as directory:
    temp = Path(directory)
    env = dict(os.environ, WORKOUT_LEGACY_FIXTURE_DIR=directory,
               RAUT_POLICY_FRAME_PATH=str(temp / "policy.bin"))
    policy = temp / "policy-test"
    subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "esp32/tools/tests/test_ride_automation_policy.cpp"),
                    "-o", str(policy)], check=True)
    subprocess.run([str(policy)], env=env, check=True)
    subprocess.run([str(ROOT / "ios-app/scripts/run-workout-contract-tests.sh")],
                   cwd=ROOT, env=env, check=True)
    for source in SOURCES:
        content = subprocess.check_output(
            ["git", "show", f"{LEGACY}:ios-app/BikeComputer/WorkoutShared/{source}"], cwd=ROOT)
        (temp / source).write_bytes(content)
    (temp / "Driver.swift").write_text('''import Foundation
@main enum LegacyDecoderProbe {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let projected = try WorkoutContractCodec.decode(Data(contentsOf:
            directory.appendingPathComponent("projected.plist")))
        precondition(projected.snapshot?.state == .paused)
        precondition(projected.snapshot?.pauseOrigin == .unknown)
        precondition(projected.snapshot?.location != nil)
        precondition(projected.snapshot?.currentSpeed == nil)
        do {
            _ = try WorkoutContractCodec.decode(Data(contentsOf:
                directory.appendingPathComponent("current.plist")))
            fatalError("legacy decoder unexpectedly accepted unsupported values")
        } catch { }
        print("Actual main decoder accepts projected Watch snapshot; rejects unprojected snapshot")
    }
}
''')
    runner = temp / "probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-o", str(runner),
                    *[str(temp / source) for source in SOURCES], str(temp / "Driver.swift")], check=True)
    subprocess.run([str(runner), directory], check=True)
