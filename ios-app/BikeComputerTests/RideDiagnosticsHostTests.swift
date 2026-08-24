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
        precondition(RideDiagnosticsRideLifecyclePolicy.isRideActive(
            navigating: true,
            workoutActive: false
        ))
        precondition(RideDiagnosticsRideLifecyclePolicy.isRideActive(
            navigating: false,
            workoutActive: true
        ))
        precondition(RideDiagnosticsRideLifecyclePolicy.didEndRide(
            previous: true,
            current: false
        ))
        precondition(!RideDiagnosticsRideLifecyclePolicy.didEndRide(
            previous: true,
            current: true
        ))

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

        let initialStandardCapture = try require(recorder.currentCaptureID)
            .uuidString.lowercased()
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

        now.addTimeInterval(4 * 60 * 60 + 1)
        recorder.record(
            category: .lifecycle,
            event: "expiry_probe"
        )
        precondition(!recorder.health.detailedTraceEnabled)
        let standardCapture = try require(recorder.currentCaptureID)
            .uuidString.lowercased()
        precondition(
            standardCapture != initialStandardCapture,
            "four-hour expiry must end detailed mode and start a fresh standard capture"
        )

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

        var mixedCaptureURL: URL?
        for boot in 1...21 {
            let capture = String(format: "00000000-0000-0000-0000-%012d", boot)
            let newestCapture = "00000000-0000-0000-0000-000000000021"
            let firstLine = "{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"captureId\":\"\(capture)\",\"fields\":{\"bootSequence\":\(boot),\"firmwareFingerprint\":\"A1B2C3D4\"}}\n"
            let mixedLine = boot == 1
                ? "{\"schema\":1,\"source\":\"firmware\",\"sequence\":1,\"level\":\"info\",\"category\":\"transfer\",\"event\":\"capture_bound\",\"captureId\":\"\(newestCapture)\",\"fields\":{\"bootSequence\":1,\"firmwareFingerprint\":\"A1B2C3D4\",\"active\":false}}\n"
                : ""
            let line = firstLine + mixedLine
            let data = Data(line.utf8)
            let hash = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            let importedURL = try recorder.importDeviceChunk(
                deviceDigest: "0123456789abcdef",
                bootSequence: UInt32(boot),
                chunk: 1,
                data: data,
                sha256: hash,
                enforceRetention: false
            )
            if boot == 1 { mixedCaptureURL = importedURL }
            let recorderHealth = Data(
                "{\"activeChunk\":1,\"bootSequence\":\(boot),\"chunks\":[{\"bootSequence\":\(boot),\"bytes\":\(data.count),\"chunk\":1,\"sha256\":\"\(hash)\"}],\"schema\":1,\"source\":\"firmware\",\"stats\":{\"dropped\":0,\"enqueued\":1,\"storageErrors\":0,\"written\":1}}".utf8
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
        precondition(
            mixedCaptureURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true,
            "a mixed component may remain when other old captures satisfy the cap"
        )

        let oversizedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-oversized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let oversizedRecorder = RideDiagnosticsRecorder(
            rootURL: oversizedRoot,
            now: { now },
            userDefaults: defaults
        )
        let oversizedData = Data((1...21).map { index in
            let capture = String(
                format: "00000000-0000-0000-0000-%012d",
                index
            )
            return "{\"schema\":1,\"source\":\"firmware\",\"sequence\":\(index),\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"captureId\":\"\(capture)\",\"fields\":{\"bootSequence\":1,\"firmwareFingerprint\":\"A1B2C3D4\"}}\n"
        }.joined().utf8)
        let oversizedHash = SHA256.hash(data: oversizedData).map {
            String(format: "%02x", $0)
        }.joined()
        let oversizedURL = try oversizedRecorder.importDeviceChunk(
            deviceDigest: "abcdef0123456789",
            bootSequence: 1,
            chunk: 1,
            data: oversizedData,
            sha256: oversizedHash,
            enforceRetention: false
        )
        try oversizedRecorder.enforceRetention()
        precondition(
            !FileManager.default.fileExists(atPath: oversizedURL.path),
            "one oversized mixed component must not defeat the hard capture cap"
        )

        var ageNow = Date()
        let ageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-age-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ageRoot) }
        let ageRecorder = RideDiagnosticsRecorder(
            rootURL: ageRoot,
            now: { ageNow },
            userDefaults: defaults
        )
        let orphanAppDirectory = ageRoot
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(
                "20000000-0000-0000-0000-000000000001",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: orphanAppDirectory,
            withIntermediateDirectories: true
        )
        let orphanAppManifest = orphanAppDirectory
            .appendingPathComponent("manifest.json")
        try Data("{\"schema\":1}\n".utf8).write(to: orphanAppManifest)
        let ageCapture = "10000000-0000-0000-0000-000000000001"
        func ageChunk(sequence: Int) -> Data {
            Data("{\"schema\":1,\"source\":\"firmware\",\"sequence\":\(sequence),\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"captureId\":\"\(ageCapture)\",\"fields\":{\"bootSequence\":1,\"firmwareFingerprint\":\"A1B2C3D4\"}}\n".utf8)
        }
        var ageURLs: [URL] = []
        for chunk in 1...2 {
            let data = ageChunk(sequence: chunk - 1)
            let hash = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            ageURLs.append(try ageRecorder.importDeviceChunk(
                deviceDigest: "1111111111111111",
                bootSequence: 1,
                chunk: UInt32(chunk),
                data: data,
                sha256: hash,
                enforceRetention: false
            ))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: ageNow.addingTimeInterval(
                -RideDiagnosticsRecorder.retentionAge - 60 * 60
            )],
            ofItemAtPath: ageURLs[0].path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: ageNow.addingTimeInterval(
                -RideDiagnosticsRecorder.retentionAge + 60 * 60
            )],
            ofItemAtPath: ageURLs[1].path
        )
        try ageRecorder.enforceRetention()
        precondition(
            !FileManager.default.fileExists(atPath: orphanAppManifest.path),
            "an app manifest without retained chunks must be pruned"
        )
        precondition(
            ageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
            "age pruning must retain a whole capture while its newest chunk is in range"
        )
        ageNow.addTimeInterval(2 * 60 * 60 + 1)
        try ageRecorder.enforceRetention()
        precondition(
            ageURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "age pruning must remove an expired capture atomically"
        )

        func firstAppStream(under root: URL) throws -> URL {
            let stream = FileManager.default.enumerator(
                at: root.appendingPathComponent("app"),
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }
                .first { $0.pathExtension == "jsonl" }
            return try require(stream)
        }
        let corruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptRecorder = RideDiagnosticsRecorder(
            rootURL: corruptRoot,
            now: { ageNow },
            userDefaults: defaults
        )
        _ = corruptRecorder.health
        let corruptStream = try firstAppStream(under: corruptRoot)
        let validBytes = try Data(contentsOf: corruptStream)
        try (validBytes + Data("\n".utf8)).write(to: corruptStream)
        do {
            _ = try corruptRecorder.exportBundle()
            preconditionFailure("a blank complete record must fail export")
        } catch {
            // Expected: the iPhone must never announce a bundle that the Mac
            // canonical validator will reject.
        }

        let firmwareCorruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-firmware-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: firmwareCorruptRoot) }
        let firmwareCorruptRecorder = RideDiagnosticsRecorder(
            rootURL: firmwareCorruptRoot,
            now: { ageNow },
            userDefaults: defaults
        )
        _ = firmwareCorruptRecorder.health
        let firmwareCorruptStream = try firstAppStream(
            under: firmwareCorruptRoot
        )
        let invalidFirmware = Data(
            "{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"storage\",\"event\":\"invalid\",\"fields\":{\"available\":1}}\n".utf8
        )
        try invalidFirmware.write(to: firmwareCorruptStream)
        do {
            _ = try firmwareCorruptRecorder.exportBundle()
            preconditionFailure(
                "firmware evidence without typed boot identity must fail export"
            )
        } catch {
            // Expected canonical-parity failure.
        }

        func expectCorruptExportRejected(
            _ label: String,
            configure: (RideDiagnosticsRecorder, URL) throws -> Void
        ) throws {
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ride-diagnostics-export-parity-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: testRoot) }
            let testRecorder = RideDiagnosticsRecorder(
                rootURL: testRoot,
                now: { ageNow },
                userDefaults: defaults
            )
            _ = testRecorder.health
            try configure(testRecorder, testRoot)
            do {
                _ = try testRecorder.exportBundle()
                preconditionFailure(label)
            } catch {
                // Expected canonical-parity failure.
            }
        }

        try expectCorruptExportRejected(
            "an app stream with a firmware source must fail export"
        ) { _, testRoot in
            let stream = try firstAppStream(under: testRoot)
            let firmware = Data(
                "{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"fields\":{\"bootSequence\":1,\"firmwareFingerprint\":\"A1B2C3D4\"}}\n".utf8
            )
            try firmware.write(to: stream)
        }

        try expectCorruptExportRejected(
            "a non-increasing app sequence must fail export"
        ) { _, testRoot in
            let stream = try firstAppStream(under: testRoot)
            let first = try require(
                Data(contentsOf: stream).split(separator: 0x0a).first
            )
            try (Data(first) + Data("\n".utf8) + Data(first) + Data("\n".utf8))
                .write(to: stream)
        }

        try expectCorruptExportRejected(
            "a noncanonical retained stream path must fail export"
        ) { _, testRoot in
            let stream = try firstAppStream(under: testRoot)
            let rogueDirectory = testRoot
                .appendingPathComponent("app", isDirectory: true)
                .appendingPathComponent("rogue", isDirectory: true)
            try FileManager.default.createDirectory(
                at: rogueDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: stream,
                to: rogueDirectory.appendingPathComponent("events-000001.jsonl")
            )
        }

        try expectCorruptExportRejected(
            "an app sidecar with undeclared fields must fail export"
        ) { _, testRoot in
            let stream = try firstAppStream(under: testRoot)
            let rogueProcess = UUID().uuidString.lowercased()
            let rogueDirectory = testRoot
                .appendingPathComponent("app", isDirectory: true)
                .appendingPathComponent(rogueProcess, isDirectory: true)
            try FileManager.default.createDirectory(
                at: rogueDirectory,
                withIntermediateDirectories: true
            )
            let manifest = rogueDirectory.appendingPathComponent("manifest.json")
            var object = try require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: stream.deletingLastPathComponent()
                        .appendingPathComponent("manifest.json"))
                ) as? [String: Any]
            )
            object["processId"] = rogueProcess
            object["wifi"] = "hunter2"
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: manifest)
        }

        func importFirmwareChunk(
            _ testRecorder: RideDiagnosticsRecorder,
            boot: UInt32,
            chunk: UInt32,
            sequence: Int,
            fingerprint: String
        ) throws {
            let data = Data(
                "{\"schema\":1,\"source\":\"firmware\",\"sequence\":\(sequence),\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"fields\":{\"bootSequence\":\(boot),\"firmwareFingerprint\":\"\(fingerprint)\"}}\n".utf8
            )
            let hash = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            _ = try testRecorder.importDeviceChunk(
                deviceDigest: "2222222222222222",
                bootSequence: boot,
                chunk: chunk,
                data: data,
                sha256: hash,
                enforceRetention: false
            )
        }

        try expectCorruptExportRejected(
            "firmware identity cannot change across chunks in one boot"
        ) { testRecorder, _ in
            try importFirmwareChunk(
                testRecorder, boot: 7, chunk: 1, sequence: 0,
                fingerprint: "A1B2C3D4"
            )
            try importFirmwareChunk(
                testRecorder, boot: 7, chunk: 2, sequence: 1,
                fingerprint: "DEADBEEF"
            )
        }

        try expectCorruptExportRejected(
            "firmware sequences cannot overlap across chunks"
        ) { testRecorder, _ in
            try importFirmwareChunk(
                testRecorder, boot: 8, chunk: 1, sequence: 4,
                fingerprint: "A1B2C3D4"
            )
            try importFirmwareChunk(
                testRecorder, boot: 8, chunk: 2, sequence: 4,
                fingerprint: "A1B2C3D4"
            )
        }

        try expectCorruptExportRejected(
            "duplicate firmware chunk numbers must fail export"
        ) { testRecorder, _ in
            try importFirmwareChunk(
                testRecorder, boot: 9, chunk: 1, sequence: 0,
                fingerprint: "A1B2C3D4"
            )
            try importFirmwareChunk(
                testRecorder, boot: 9, chunk: 1, sequence: 1,
                fingerprint: "A1B2C3D4"
            )
        }

        do {
            try recorder.importDeviceRecorderHealth(
                deviceDigest: "0123456789abcdef",
                bootSequence: 22,
                data: Data(
                    "{\"schema\":1,\"source\":\"firmware\",\"bootSequence\":22,\"activeChunk\":1,\"stats\":{\"written\":1},\"chunks\":[]}".utf8
                )
            )
            preconditionFailure(
                "structurally incomplete recorder health must be rejected"
            )
        } catch {
            // Expected canonical sidecar rejection at import time.
        }

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

#if HOST_TESTING
        let sourceStreams = try recorder.exportSourceStreamPathsForTesting()
        precondition(sourceStreams.contains(where: { $0.hasPrefix("app/") }))
        precondition(sourceStreams.contains(where: { $0.hasPrefix("device/") }))
#endif
        let bundle = try recorder.exportBundle()
        precondition(FileManager.default.fileExists(atPath: bundle.path))
        let firstExport = try Data(contentsOf: bundle)
        let repeatedBundle = try recorder.exportBundle()
        let repeatedExport = try Data(contentsOf: repeatedBundle)
        precondition(
            firstExport == repeatedExport,
            "fixed evidence and clock must produce a deterministic stored ZIP"
        )

        now.addTimeInterval(RideDiagnosticsRecorder.retentionAge + 1)
        try recorder.enforceRetention()
        let activeStandardEvidence = FileManager.default.enumerator(
            at: root.appendingPathComponent("app"),
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n") ?? ""
        precondition(
            activeStandardEvidence.contains(standardCapture),
            "the active standard capture remains protected at the age boundary"
        )
        precondition(
            !activeStandardEvidence.contains(initialStandardCapture),
            "a completed standard capture must not remain process-lifetime protected"
        )
        precondition(
            activeStandardEvidence.contains("chunk_rotated"),
            "rotation outcomes are durable evidence"
        )
        print(bundle.path)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw RideDiagnosticsError.unavailable("Expected a non-nil test value")
        }
        return value
    }
}
