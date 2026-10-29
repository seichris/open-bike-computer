#!/usr/bin/env python3
"""Run production upload wait, cancellation, persistence and completion paths.

Controlled URLSession tasks isolate transport scheduling; the continuation and
descriptor/state-store code is extracted unchanged from the app sources.
"""
from pathlib import Path
import subprocess
import tempfile


def declaration(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1] + "\n"
    raise RuntimeError("unterminated declaration: " + signature)


def main():
    ios = Path(__file__).resolve().parents[1]
    source = (ios / "BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift").read_text()
    operation = (ios / "BikeComputer/BikeComputer/Models/DeviceMapOperation.swift").read_text()
    types = source[source.index("nonisolated struct BackgroundMapUploadDescriptor:"):
                   source.index("#if os(iOS)\nfinal class BackgroundMapUploadCoordinator:")]
    fields = source[source.index("    private struct PendingUpload {"):
                    source.index("    private lazy var session: URLSession = {")]
    coordinator = "final class BackgroundMapUploadCoordinator: NSObject {\n" + fields
    for signature in ("    private func wait(", "    private func cancelForegroundUpload(",
                      "    func urlSession(\n        _ session: URLSession,\n        task: URLSessionTask,\n        didCompleteWithError",
                      "    private static func descriptor(for task:",
                      "    private static func hasMatchingStateRecord("):
        coordinator += declaration(source, signature)
    coordinator += "}\n"
    fixtures = ios / "tests/map-upload-binding-host"
    with tempfile.TemporaryDirectory(prefix="bicino-upload-binding-") as temporary:
        directory = Path(temporary)
        production = directory / "Production.swift"
        production.write_text("import Foundation\n" + types +
            declaration(operation, "nonisolated final class DeviceMapUploadCompletionBarrier:") +
            coordinator)
        binary = directory / "binding-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
            "-default-isolation", "MainActor", "-whole-module-optimization", "-parse-as-library",
            "-Xfrontend", "-disable-access-control", str(production),
            str(fixtures / "Tests.swift"), "-o", str(binary)], check=True, timeout=180)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    main()
