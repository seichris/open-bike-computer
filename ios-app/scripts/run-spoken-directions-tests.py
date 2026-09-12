#!/usr/bin/env python3
"""Isolated real shared speech policy/wire tests for Swift and C++."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpp-only", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="bicino-spoken-policy-") as output:
        target = Path(output)
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        ROOT / "esp32/tools/tests/test_spoken_session.cpp", "-o", target / "cpp"], check=True)
        subprocess.run([target / "cpp"], check=True)
        if args.cpp_only:
            return
        shared = ROOT / "ios-app/BikeComputer/RideShared"
        sources = ["RideBLEProtocol.generated.swift", "NavigationRouteContract.swift",
                   "RouteCoordinateNormalization.swift", "RouteProviderContract.swift", "NavigationGeometry.swift",
                   "NavigationRuntime.swift", "SpokenDirectionsContract.swift", "SpokenManeuverClassifier.swift",
                   "SpokenCueScheduler.swift", "SpokenDirectionsController.swift", "SpokenDirectionsPreferences.swift"]
        compiler = ["xcrun", "swiftc"] if os.uname().sysname == "Darwin" else ["swiftc"]
        subprocess.run(compiler + ["-parse-as-library", "-warnings-as-errors", "-o", target / "swift"] +
                       [shared / name for name in sources] +
                       [ROOT / "ios-app/BikeComputerTests/SpokenDirectionsTests.swift"], check=True)
        subprocess.run([target / "swift"], check=True)


if __name__ == "__main__": main()
