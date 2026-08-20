import CryptoKit
import Foundation

@main
enum RideDiagnosticsHostTests {
    static func main() throws {
        var now = Date()
        let defaultsSuite = "ride-diagnostics-host-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RideDiagnosticsRecorder(
            rootURL: root,
            now: { now },
            userDefaults: defaults
        )

        let stableIdentifier = "28:84:85:3A:D7:80"
        let saltedDigest = recorder.deviceDigest(for: stableIdentifier)
        let plainDigest = SHA256.hash(data: Data(stableIdentifier.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        precondition(saltedDigest.count == 16)
        precondition(saltedDigest != String(plainDigest.prefix(16)))
        let reloadRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-host-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reloadRoot) }
        let reloadedRecorder = RideDiagnosticsRecorder(
            rootURL: reloadRoot,
            now: { now },
            userDefaults: defaults
        )
        precondition(
            reloadedRecorder.deviceDigest(for: stableIdentifier) == saltedDigest
        )
        _ = reloadedRecorder.health

        recorder.record(category: .ble, event: "connected", fields: [
            "rssiBucket": "good",
        ])
        recorder.beginDetailedTrace()
        let detailedHealth = recorder.health
        precondition(detailedHealth.detailedTraceEnabled)
        let expiry = try require(detailedHealth.detailedTraceExpiresAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsedExpiry = try require(formatter.date(from: expiry))
        precondition(
            abs(parsedExpiry.timeIntervalSince(now.addingTimeInterval(4 * 60 * 60))) < 0.001
        )

        recorder.endDetailedTrace(reason: "test")
        precondition(!recorder.health.detailedTraceEnabled)

        let recoverableLine = Data(
            "{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"boot\",\"event\":\"recoverable\"}\n".utf8
        )
        let recoverableHash = SHA256.hash(data: recoverableLine).map {
            String(format: "%02x", $0)
        }.joined()
        let recoverableURL = try recorder.importDeviceChunk(
            deviceDigest: "fedcba9876543210",
            bootSequence: 1,
            chunk: 1,
            data: recoverableLine,
            sha256: recoverableHash,
            enforceRetention: false
        )
        try Data("truncated".utf8).write(to: recoverableURL)
        _ = try recorder.importDeviceChunk(
            deviceDigest: "fedcba9876543210",
            bootSequence: 1,
            chunk: 1,
            data: recoverableLine,
            sha256: recoverableHash,
            enforceRetention: false
        )
        let recoveredData = try Data(contentsOf: recoverableURL)
        precondition(
            recoveredData == recoverableLine,
            "a validated re-download replaces a corrupt cached chunk"
        )

        for boot in 1...21 {
            let capture = String(format: "00000000-0000-0000-0000-%012d", boot)
            let line = "{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"captureId\":\"\(capture)\",\"fields\":{\"bootSequence\":\(boot),\"firmwareFingerprint\":\"A1B2C3D4\"}}\n"
            let data = Data(line.utf8)
            let hash = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            _ = try recorder.importDeviceChunk(
                deviceDigest: "0123456789abcdef",
                bootSequence: UInt32(boot),
                chunk: 1,
                data: data,
                sha256: hash,
                enforceRetention: false
            )
            let recorderHealth = Data(
                "{\"schema\":1,\"bootSequence\":\(boot),\"stats\":{\"written\":1}}".utf8
            )
            try recorder.importDeviceRecorderHealth(
                deviceDigest: "0123456789abcdef",
                bootSequence: UInt32(boot),
                data: recorderHealth,
                enforceRetention: false
            )
            now.addTimeInterval(1)
        }
        try recorder.enforceRetention()

        let retained = recorder.health
        precondition(retained.retainedBytes > 0)
        precondition(
            retained.retainedCaptureCount <=
                RideDiagnosticsRecorder.retainedCaptureLimit
        )
        let retainedHealthFiles = FileManager.default.enumerator(
            at: root.appendingPathComponent("imported-device"),
            includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL)?.lastPathComponent }
            .filter { $0 == "recorder-health.json" } ?? []
        precondition(!retainedHealthFiles.isEmpty)
        precondition(retainedHealthFiles.count <= RideDiagnosticsRecorder.retainedCaptureLimit)
        let bundle = try recorder.exportBundle()
        precondition(FileManager.default.fileExists(atPath: bundle.path))
        print(bundle.path)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw RideDiagnosticsError.unavailable("Expected a non-nil test value")
        }
        return value
    }
}
