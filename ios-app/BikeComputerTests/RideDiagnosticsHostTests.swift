import CryptoKit
import Foundation

@main
enum RideDiagnosticsHostTests {
    static func storedZIPChecksumsMatchKnownVectors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let padded = Data([0xff] + Array("123456789".utf8) + [0xff])
        let fixtures: [(String, Data, UInt32)] = [
            ("empty", Data(), 0),
            ("digits", padded[1..<10], 0xcbf4_3926),
            ("binary", Data((0..<256).map { UInt8($0) }), 0x2905_8c73),
        ]
        let url = root.appendingPathComponent("vectors.zip")
        try RideDiagnosticsStoredZipWriter.write(entries: fixtures.map { ($0.0, $0.1) }, to: url)
        let archive = try Data(contentsOf: url)
        func littleEndian32(at offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(archive[offset + $1]) << ($1 * 8) }
        }
        var offset = 0
        for (name, body, checksum) in fixtures {
            precondition(littleEndian32(at: offset) == 0x0403_4b50)
            precondition(littleEndian32(at: offset + 14) == checksum,
                         "local ZIP headers must retain the standard IEEE CRC")
            let payloadStart = offset + 30 + name.utf8.count
            precondition(archive[payloadStart..<(payloadStart + body.count)] == body)
            offset = payloadStart + body.count
        }
        for (name, _, checksum) in fixtures {
            precondition(littleEndian32(at: offset) == 0x0201_4b50)
            precondition(littleEndian32(at: offset + 16) == checksum,
                         "central ZIP headers must match the known checksum")
            offset += 46 + name.utf8.count
        }
    }

    static func oversizedAppSnapshotReportsCacheFull() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RideDiagnosticsRecorder(rootURL: root)
        recorder.record(category: .lifecycle, event: "snapshot_limit")
        recorder.flush()
        let capture = try require(recorder.currentCaptureID)
        let original = try await recorder.appEvidenceSnapshot(captureID: capture)
        let path = try require(original.keys.sorted().first)
        let data = try require(original[path])
        let directory = root.appendingPathComponent("app").appendingPathComponent(path).deletingLastPathComponent()
        // Valid, original-capture chunks reach the request-count bound before
        // the acquisition store or network can be entered.
        for chunk in 1...257 {
            try data.write(to: directory.appendingPathComponent(String(format: "events-%06d.jsonl", chunk)))
        }
        do {
            _ = try await recorder.appEvidenceSnapshot(captureID: capture)
            preconditionFailure("oversized app snapshot admitted")
        } catch {
            precondition((error as? DiagnosticsAcquisitionStore.Failure) == .storageFull)
            precondition(DiagnosticsAcquisitionFailureReporting.code(for: error) == "cache_full")
        }
        let retained = try Data(contentsOf: root.appendingPathComponent("app").appendingPathComponent(path))
        precondition(retained == data, "snapshot refusal must preserve original recorder evidence")
    }

    static func cacheAdmissionFailureIsRecorded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RideDiagnosticsRecorder(rootURL: root.appendingPathComponent("recorder"))
        recorder.record(category: .lifecycle, event: "before_admission")
        recorder.flush()
        let capture = try require(recorder.currentCaptureID)
        let store = DiagnosticsAcquisitionStore(root: root.appendingPathComponent("cache"), maximumEvidenceBytes: 1)
        let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: capture)
        let chunks = try await recorder.appEvidenceSnapshot(captureID: capture)
        do {
            try await store.retainAppEvidence(job.id, chunks: chunks)
            preconditionFailure("original app evidence should exceed this cache")
        } catch {
            precondition((error as? DiagnosticsAcquisitionStore.Failure) == .storageFull)
            // Use the same report as the coordinator before any transfer
            // manager is entered. Actual recorder output must retain the code.
            recorder.record(level: .warning, category: .transfer, event: "diagnostics_download_failed",
                fields: DiagnosticsAcquisitionFailureReporting.fields(for: error, acquisitionID: job.id, phase: "app_evidence"))
            try await store.interrupt(job.id, code: DiagnosticsAcquisitionFailureReporting.code(for: error))
        }
        recorder.flush()
        let events = try require(FileManager.default.enumerator(at: root.appendingPathComponent("recorder/app"), includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let records = try events.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(RideDiagnosticEvent.self, from: Data($0.utf8))
            }
        }
        let failure = try require(records.first { $0.event == "diagnostics_download_failed" })
        precondition(failure.fields["code"] == "cache_full" && failure.fields["reason"] == "cache_full")
        precondition(failure.fields["operationId"] == job.id.uuidString.lowercased())
        precondition(failure.fields["phase"] == "app_evidence")
        precondition(!failure.fields.values.contains { $0.contains(root.path) || $0.contains("http") })
        let persisted = try await store.load(job.id)
        precondition(persisted.failureCode == "cache_full" && persisted.indexData == nil && persisted.appEvidence == nil)
        // Failure reporting must not consume or remove the original recorder
        // history it failed to copy into the acquisition cache.
        for (path, data) in chunks {
            let original = try Data(contentsOf: root.appendingPathComponent("recorder/app").appendingPathComponent(path))
            precondition(original == data)
        }
    }

    /// Exercise the real queue, not a source-string assertion. The v1 sequence
    /// remains storage order; emissionSequence and occurrence time identify ingress.
    static func occurrenceTimeSurvivesWriterDelay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-clock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var wall = Date(timeIntervalSince1970: 1_790_000_000)
        var monotonic: TimeInterval = 100
        let recorder = RideDiagnosticsRecorder(rootURL: root, now: { wall }, uptime: { monotonic })
        recorder.flush()
        let capture = try require(recorder.currentCaptureID)
        recorder.suspendWriterForTesting()
        recorder.record(category: .ble, event: "before_delay")
        wall.addTimeInterval(90)
        monotonic += 90
        // Queued mode change cannot relabel the record already admitted.
        recorder.beginDetailedTrace()
        recorder.record(category: .ble, event: "after_delay")
        recorder.resumeWriterForTesting()
        recorder.flush()
        let urls = try require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let records = try urls.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(RideDiagnosticEvent.self, from: Data($0.utf8))
            }
        }
        let before = try require(records.first { $0.event == "before_delay" })
        let after = try require(records.first { $0.event == "after_delay" })
        precondition(before.uptimeMs == 0)
        precondition(after.uptimeMs == 90_000)
        precondition(before.captureId == capture.uuidString.lowercased())
        precondition(after.captureId == capture.uuidString.lowercased())
        precondition(before.fields["writerDelayMs"] == "90000")
        precondition(before.wallTime != after.wallTime)
        precondition(before.fields["emissionSequence"] != after.fields["emissionSequence"])
    }

    /// Reproduce a complete multi-boot acquisition followed by the ordinary
    /// 20-capture prune, then export the original cutoff after a store restart.
    static func acquisitionSurvivesCaptureRetention() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceRecorder = RideDiagnosticsRecorder(rootURL: base.appendingPathComponent("v1"))
        let storeRoot = base.appendingPathComponent("v2")
        let store = DiagnosticsAcquisitionStore(root: storeRoot)
        let device = "0123456789abcdef"
        sourceRecorder.record(category: .ble, event: "retained_capture")
        sourceRecorder.flush()
        let originalCapture = try require(sourceRecorder.currentCaptureID)
        var appEvidence = try await sourceRecorder.appEvidenceSnapshot(captureID: originalCapture)
        precondition(!appEvidence.isEmpty)
        // Simulate a previous process ending mid-record. Cache/export must
        // preserve the raw tail and its degraded-coverage result, not discard it.
        let crashedPath = appEvidence.keys.sorted()[0]
        appEvidence[crashedPath]!.append(Data("{\"schema".utf8))
        try appEvidence[crashedPath]!.write(to: base.appendingPathComponent("v1/app").appendingPathComponent(crashedPath))
        let job = try await store.create(deviceDigest: device, captureID: originalCapture)
        try await store.retainAppEvidence(job.id, chunks: appEvidence)
        let recorder = RideDiagnosticsRecorder(rootURL: base.appendingPathComponent("v1"))
        var expected: [DiagnosticsChunkReceipt] = []
        var bodies: [Data] = []
        var originals: [URL] = []
        for boot in 1...39 {
            let capture = boot == 1 ? originalCapture.uuidString.lowercased() : String(format: "00000000-0000-0000-0000-%012d", boot)
            let data = Data("{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,\"level\":\"info\",\"category\":\"boot\",\"event\":\"test\",\"captureId\":\"\(capture)\",\"fields\":{\"bootSequence\":\(boot),\"firmwareFingerprint\":\"A1B2C3D4\"}}\n".utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            expected.append(DiagnosticsChunkReceipt(bootSequence: UInt32(boot), chunk: 1, bytes: data.count, sha256: hash))
            bodies.append(data)
            originals.append(try recorder.importDeviceChunk(deviceDigest: device, bootSequence: UInt32(boot),
                chunk: 1, data: data, sha256: hash, enforceRetention: false))
        }
        let index: [String: Any] = ["schema": 1, "source": "firmware", "bootSequence": 39,
            "activeChunk": 2, "stats": ["enqueued": 39, "written": 39, "dropped": 0, "storageErrors": 0],
            "chunks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        _ = try await store.inventory(job.id, deviceDigest: device, index: indexData, chunks: expected)
        for (receipt, data) in zip(expected, bodies) {
            try await store.verified(job.id, receipt: receipt, data: data)
        }
        try await store.finish(job.id)
        try recorder.enforceRetention()
        precondition(originals.contains { !FileManager.default.fileExists(atPath: $0.path) },
            "fixture must actually prune original acquired chunks")
        // Simulate ordinary app retention removing every original member.
        // The acquisition cache must survive independently of those files.
        for path in appEvidence.keys {
            let source = base.appendingPathComponent("v1/app").appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        }
        let restarted = DiagnosticsAcquisitionStore(root: storeRoot)
        let snapshot = try await restarted.exportSnapshot()
        precondition(snapshot.manifests.first?.deliveryComplete == true && snapshot.chunks.count == 39)
        precondition(snapshot.appChunks == appEvidence)
        let archive = try recorder.exportBundle(additionalDeviceChunks: snapshot.chunks, additionalAppChunks: snapshot.appChunks)
        defer { try? FileManager.default.removeItem(at: archive) }
        let bytes = try Data(contentsOf: archive)
        for (relative, body) in snapshot.chunks {
            precondition(bytes.range(of: Data("device/\(relative)".utf8)) != nil)
            precondition(bytes.range(of: body) != nil, "every original chunk must be present byte-for-byte")
        }
        let receiptName = "acquisitions/\(job.id.uuidString.lowercased()).json"
        let envelope: [String: Any] = ["schema": 2, "eventFormatSchema": 1,
            "registryDigest": DiagnosticsSchema.digest, "evidenceArchive": "evidence-v1.zip",
            "evidenceSha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "acquisitions": [receiptName], "privacy": "diagnostic-no-raw-payloads"]
        var entries: [(String, Data)] = [
            ("manifest.json", try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])),
            ("evidence-v1.zip", bytes), (receiptName, try JSONEncoder().encode(snapshot.manifests[0]))]
        let checksums = entries.map { name, data in
            "\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())  \(name)\n"
        }.joined()
        entries.append(("checksums.sha256", Data(checksums.utf8)))
        let portable = base.appendingPathComponent("retained-acquisition.zip")
        try RideDiagnosticsStoredZipWriter.write(entries: entries, to: portable)
        // Exercise the real host consumer, including its closed envelope schema,
        // manifest validation and independently hashed delivery inventory.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/bicino")
        verify.arguments = ["diag", "verify", portable.path, "--acquisition", job.id.uuidString.lowercased(),
            "--require", "ios,firmware", "--require-complete", "--json"]
        let output = Pipe()
        verify.standardOutput = output
        try verify.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw RideDiagnosticsError.unavailable("Retention export failed host verification: \(String(decoding: result, as: UTF8.self))")
        }
        let report = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let delivery = (report["delivery"] as! [[String: Any]])[0]
        precondition(delivery["expectedChunks"] as? Int == 39 && delivery["state"] as? String == "complete")
        precondition((report["missingRequiredSources"] as? [String])?.isEmpty == true)
        precondition(report["recoverableTails"] as? Int == 1 && report["recordingCoverage"] as? String == "degraded")
        let stillPruned = originals.filter { !FileManager.default.fileExists(atPath: $0.path) }
        precondition(!stillPruned.isEmpty, "export must not resurrect evidence into ordinary retention")
    }

    static func main() async throws {
        try storedZIPChecksumsMatchKnownVectors()
        try await oversizedAppSnapshotReportsCacheFull()
        try await cacheAdmissionFailureIsRecorded()
        try await acquisitionSurvivesCaptureRetention()
        try occurrenceTimeSurvivesWriterDelay()
        precondition(RideDiagnosticsFieldPolicy.isAllowed("recorderReady"))
        precondition(RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "recorderReady", value: NSNumber(value: true)))
        precondition(!RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "recorderReady", value: NSNumber(value: 1)))
        // Match the bounded firmware resource producer's numeric/boolean/string
        // types; retain the existing importer privacy and field-count limits.
        for key in ["freeBytes", "largestBytes", "minimumFreeBytes",
                    "minimumLargestBytes", "tlsStackBytes", "ownerStackBytes",
                    "rendererStackBytes", "stackAvailableMask"] {
            precondition(RideDiagnosticsFieldPolicy.isAllowed(key))
            precondition(RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
                key: key, value: NSNumber(value: UInt32.max)))
            precondition(!RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
                key: key, value: NSNumber(value: true)))
            precondition(!RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
                key: key, value: "123"))
        }
        precondition(RideDiagnosticsFieldPolicy.isAllowed("cleanupFailed"))
        precondition(RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "cleanupFailed", value: NSNumber(value: false)))
        precondition(!RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "cleanupFailed", value: NSNumber(value: 0)))
        precondition(RideDiagnosticsFieldPolicy.isAllowed("operationId"))
        precondition(RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "operationId", value: "123456781234abcdABCD123456789abc"))
        precondition(!RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
            key: "operationId", value: NSNumber(value: 1)))
        for key in ["sessionToken", "password", "tlsCertificateSha256"] {
            precondition(!RideDiagnosticsFieldPolicy.isAllowed(key))
        }

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
