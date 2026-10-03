import Foundation

@main
struct DeviceMapOperationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "") throws {
        if try !condition() { fatalError(message) }
    }
    static func main() throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "completion-crash" {
            let operationURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let responseURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let crashBeforeWrite = CommandLine.arguments[4] == "before"
            let store = DeviceMapOperationStore(url: operationURL)
            let record = try store.records()[0]
            let barrier = DeviceMapUploadCompletionBarrier()
            barrier.complete(persist: {
                barrier.finishEvents { fatalError("OS completion crossed crash boundary") }
                if crashBeforeWrite { exit(71) }
                guard try store.completeUpload(operationID: record.operationID, deviceID: record.deviceID,
                    appNamespace: record.appNamespace, mapID: record.mapID, sessionID: record.sessionID,
                    uploadAttemptID: record.uploadAttemptID!, responseBody: Data(contentsOf: responseURL),
                    httpStatus: 200, errorCode: nil) else { fatalError("crash fixture identity mismatch") }
                exit(72) // process dies after durable ingest, before continuation or OS acknowledgement
            }, publish: { _ in fatalError("client publication crossed crash boundary") })
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.json")
        let store = DeviceMapOperationStore(url: url)
        let deviceID = String(repeating: "a", count: 32)
        func makeRecord() -> DeviceMapOperationRecord {
            DeviceMapOperationRecord(
            schemaVersion: 1, deviceID: deviceID, operationID: UUID(),
            sessionID: "session", mapID: "map", manifestReceipt: String(repeating: "b", count: 64),
            signedManifestReceipt: String(repeating: "c", count: 64),
            streamSHA256: String(repeating: "d", count: 64), streamBytes: 123,
            artifactFilename: "map.bmap", appNamespace: "test.dev", createdAt: Date(timeIntervalSince1970: 1),
            connectionEpoch: 7, observation: "in_progress", cleanup: "pending", usesDurableProtocol: true,
            lastReceipt: nil, admissionEpoch: String(repeating: "e", count: 32), admissionRevision: 42
        )
        }
        let record = makeRecord()
        func receipt(_ phase: String, _ revision: UInt64, overrides: [String: Any] = [:]) throws -> DeviceMapOperationReceipt {
            var json: [String: Any] = ["schemaVersion": 1, "deviceID": record.deviceID,
                "operationID": record.wireOperationID, "sessionID": record.sessionID, "mapID": record.mapID,
                "manifestReceipt": record.manifestReceipt, "signedManifestReceipt": record.signedManifestReceipt,
                "streamSHA256": record.streamSHA256, "streamBytes": record.streamBytes,
                "phase": phase, "revision": revision]
            json.merge(overrides) { _, new in new }
            return try JSONDecoder().decode(DeviceMapOperationReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func expectFailure(_ operation: () throws -> Void, _ label: String) {
            do { try operation(); fatalError(label) } catch { }
        }
        let completionURL = directory.appendingPathComponent("completion.json")
        let completionStore = DeviceMapOperationStore(url: completionURL)
        try completionStore.save(record)
        let completionAttempt = UUID()
        try completionStore.beginUpload(operationID: record.operationID, deviceID: deviceID,
            appNamespace: record.appNamespace, uploadAttemptID: completionAttempt)
        let responseBody = try JSONSerialization.data(withJSONObject: ["operation":
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt("prepared", 2)))])
        let completionBarrier = DeviceMapUploadCompletionBarrier()
        var callbackOrder: [String] = []
        completionBarrier.complete(persist: {
            callbackOrder.append("ingest")
            completionBarrier.finishEvents { callbackOrder.append("OS") }
            try check(try completionStore.completeUpload(operationID: record.operationID, deviceID: deviceID,
                appNamespace: record.appNamespace, mapID: record.mapID, sessionID: record.sessionID,
                uploadAttemptID: completionAttempt, responseBody: responseBody, httpStatus: 200, errorCode: nil))
            try check(callbackOrder == ["ingest"], "OS delivery cannot race persistence")
        }, publish: { error in
            precondition(error == nil)
            precondition((try? DeviceMapOperationStore(url: completionURL).records()[0].lastReceipt?.phase) == "prepared")
            callbackOrder.append("continuation")
        })
        try check(callbackOrder == ["ingest", "continuation", "OS"], "real completion barrier orders durable ingest and both deliveries")

        let failedWriteURL = directory.appendingPathComponent("completion-write-failure.json")
        let goodWriter = DeviceMapOperationStore(url: failedWriteURL)
        try goodWriter.save(record)
        try goodWriter.beginUpload(operationID: record.operationID, deviceID: deviceID,
            appNamespace: record.appNamespace, uploadAttemptID: completionAttempt)
        let beforeFailure = try Data(contentsOf: failedWriteURL)
        let failingWriter = DeviceMapOperationStore(url: failedWriteURL, atomicWriter: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        var failedDelivery = false
        var failedOSDelivery = false
        completionBarrier.complete(persist: {
            completionBarrier.finishEvents {
                precondition(failedDelivery)
                failedOSDelivery = true
            }
            _ = try failingWriter.completeUpload(operationID: record.operationID, deviceID: deviceID,
                appNamespace: record.appNamespace, mapID: record.mapID, sessionID: record.sessionID,
                uploadAttemptID: completionAttempt, responseBody: responseBody, httpStatus: 200, errorCode: nil)
        }, publish: { error in failedDelivery = error != nil })
        let afterFailure = try Data(contentsOf: failedWriteURL)
        try check(failedDelivery && failedOSDelivery && afterFailure == beforeFailure,
                  "atomic-write failure delivers an error and preserves unresolved durable intent")

        let responseURL = directory.appendingPathComponent("completion-response.json")
        try responseBody.write(to: responseURL)
        for mode in ["before", "after"] {
            let crashURL = directory.appendingPathComponent("crash-\(mode).json")
            try beforeFailure.write(to: crashURL)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["completion-crash", crashURL.path, responseURL.path, mode]
            try child.run()
            child.waitUntilExit()
            try check(child.terminationStatus == (mode == "before" ? 71 : 72), "fault probe reaches intended process-death boundary")
            let recovered = try DeviceMapOperationStore(url: crashURL).records()[0]
            if mode == "before" {
                try check(recovered.lastReceipt == nil && recovered.uploadCompletedAt == nil,
                          "death before ingest retains exact unresolved attempt")
            } else {
                try check(recovered.lastReceipt?.phase == "prepared" && recovered.uploadCompletedAt != nil,
                          "death before callbacks preserves durable Prepared receipt for same-ID recovery")
            }
        }
        try store.save(record)
        try check(try DeviceMapOperationStore(url: url).records() == [record], "atomic record survives relaunch")
        let snapshotProcess = DeviceMapOperationStore.observationProcessID
        let priorSelection = DeviceMapConfirmedSelectionSnapshot(deviceID: deviceID,
            mapID: "previous-map", sessionID: "previous-content-session",
            manifestReceipt: String(repeating: "e", count: 64), root: "/maps/previous",
            operationID: String(repeating: "f", count: 32),
            healthBootID: String(repeating: "a", count: 32), healthRevision: 8,
            connectionEpoch: 7, observationProcessID: snapshotProcess,
            observedAt: Date(timeIntervalSince1970: 0))
        func capturePrevious(device: String? = nil, epoch: UInt64 = 7,
                             process: UUID? = nil, fresh: Bool = true,
                             confirmed: Bool = true, unconfirmed: Bool = false) -> DeviceMapConfirmedSelectionSnapshot? {
            DeviceMapConfirmedSelectionSnapshot.capture(priorSelection,
                currentDeviceID: device ?? deviceID, currentEpoch: epoch, currentProcessID: process ?? snapshotProcess,
                hasFreshStatus: fresh, isConfirmed: confirmed, isUnconfirmed: unconfirmed)
        }
        try check(capturePrevious() == priorSelection)
        try check(capturePrevious(device: "other-device") == nil, "prior selection must belong to operation device")
        try check(capturePrevious(epoch: 8) == nil && capturePrevious(process: UUID()) == nil,
                  "previous connection/process observations cannot be captured as current")
        try check(capturePrevious(fresh: false) == nil && capturePrevious(confirmed: false) == nil &&
                  capturePrevious(unconfirmed: true) == nil, "stale, pending and unconfirmed selections are excluded")
        var withPrevious = makeRecord()
        withPrevious.observationProcessID = snapshotProcess
        withPrevious.previousConfirmedSelection = capturePrevious()
        let snapshotURL = directory.appendingPathComponent("previous-selection.json")
        let snapshotStore = DeviceMapOperationStore(url: snapshotURL)
        try snapshotStore.save(withPrevious)
        let reloadedPrevious = try DeviceMapOperationStore(url: snapshotURL).records()[0]
        try check(reloadedPrevious.previousConfirmedSelection == priorSelection,
                  "per-operation previous identity and health context survive relaunch")
        try check(!reloadedPrevious.isTerminal && reloadedPrevious.nextControlAction == .query &&
                  reloadedPrevious.lastReceipt == nil, "previous selection never proves this operation installed")
        var replacementPrevious = reloadedPrevious
        replacementPrevious.previousConfirmedSelection = nil
        expectFailure({ try snapshotStore.save(replacementPrevious) }, "later callbacks cannot erase the intent snapshot")
        var migratedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        migratedJSON.removeValue(forKey: "previousConfirmedSelection")
        let migrated = try JSONDecoder().decode(DeviceMapOperationRecord.self,
            from: JSONSerialization.data(withJSONObject: migratedJSON))
        try check(migrated.previousConfirmedSelection == nil && migrated == record,
                  "older journals decode without inventing previous-selection evidence")
        for (key, value) in [("deviceID", String(repeating: "e", count: 32)), ("operationID", String(repeating: "e", count: 32)),
                             ("sessionID", "other"), ("mapID", "other"), ("manifestReceipt", String(repeating: "e", count: 64)),
                             ("signedManifestReceipt", String(repeating: "e", count: 64)), ("streamSHA256", String(repeating: "e", count: 64))] {
            try check(try store.ingest(receipt("installed", 1, overrides: [key: value])) == nil, "wrong identity rejected: \(key)")
        }
        try check(try store.ingest(receipt("installed", 1, overrides: ["streamBytes": 124])) == nil)
        try check(try store.ingest(receipt("installed", 1, overrides: ["schemaVersion": 99])) == nil)
        try check(try store.ingest(receipt("invented", 1)) == nil)
        try check(try store.ingest(receipt("installed", 0)) == nil)
        let missing = try JSONDecoder().decode(DeviceMapOperationReceipt.self, from: Data("""
        {"schemaVersion":1,"deviceID":"\(deviceID)","operationID":"\(record.wireOperationID)","status":"result_unavailable"}
        """.utf8))
        try check(try store.ingest(missing) == nil, "missing receipt cannot confer success")

        let replayStore = DeviceMapOperationStore(url: directory.appendingPathComponent("replay.json"))
        try replayStore.save(record)
        let interruptedAttempt = UUID()
        try replayStore.beginUpload(operationID: record.operationID, deviceID: deviceID,
                                    appNamespace: record.appNamespace, uploadAttemptID: interruptedAttempt)
        let originalAdmission = DeviceMapOperationAdmission(schemaVersion: 1, deviceID: deviceID,
            admissionRevision: 42, admissionEpoch: String(repeating: "e", count: 32))
        let rebootAdmission = DeviceMapOperationAdmission(schemaVersion: 1, deviceID: deviceID,
            admissionRevision: 42, admissionEpoch: String(repeating: "f", count: 32))
        expectFailure({ _ = try replayStore.prepareReplayAfterUnavailable(operationID: record.operationID,
                                                                         admission: rebootAdmission) },
                      "rebooted missing operation cannot obtain a new admission")
        let advancedAdmission = DeviceMapOperationAdmission(schemaVersion: 1, deviceID: deviceID,
            admissionRevision: 43, admissionEpoch: String(repeating: "e", count: 32))
        expectFailure({ _ = try replayStore.prepareReplayAfterUnavailable(operationID: record.operationID,
                                                                         admission: advancedAdmission) },
                      "evicted absent identity cannot replay at a new revision")
        let recovered = try replayStore.prepareReplayAfterUnavailable(operationID: record.operationID,
                                                                     admission: originalAdmission)
        try check(recovered.uploadCompletedAt != nil && !recovered.isTerminal,
                  "same-boot truncated pregrant upload remains unknown and replayable")
        try replayStore.beginUpload(operationID: record.operationID, deviceID: deviceID,
                                    appNamespace: record.appNamespace, uploadAttemptID: UUID())
        try check(try replayStore.records()[0].admissionEpoch == record.admissionEpoch,
                  "retry persists the original admission epoch")
        expectFailure({ try replayStore.save(record) }, "stale save cannot erase an upload attempt")

        let firstAttempt = UUID()
        try store.beginUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", uploadAttemptID: firstAttempt)
        expectFailure({ try store.beginUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", uploadAttemptID: UUID()) }, "overlapping upload must fail")
        try check(try !store.completeUpload(operationID: record.operationID, deviceID: "foreign", appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: firstAttempt, responseBody: Data(), httpStatus: 200, errorCode: nil))
        try check(try store.completeUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: firstAttempt, responseBody: Data("{\"status\":\"ready\"}".utf8), httpStatus: 200, errorCode: nil))
        var persisted = try DeviceMapOperationStore(url: url).records()[0]
        try check(!persisted.isTerminal && persisted.uploadHTTPStatus == 200, "HTTP ready persists but is not installation")
        let secondAttempt = UUID()
        try store.beginUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", uploadAttemptID: secondAttempt)
        try check(try !store.completeUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: firstAttempt, responseBody: Data(), httpStatus: 500, errorCode: nil), "old callback cannot replace retry")
        let foreignBody = try JSONSerialization.data(withJSONObject: ["operation": ["schemaVersion": 1, "deviceID": "foreign", "operationID": record.wireOperationID, "phase": "installed", "revision": 1]])
        expectFailure({ _ = try store.completeUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: secondAttempt, responseBody: foreignBody, httpStatus: 200, errorCode: nil) }, "foreign receipt in matching callback must fail")
        expectFailure({ _ = try store.completeUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: secondAttempt, responseBody: Data(repeating: 0, count: 4097), httpStatus: 200, errorCode: nil) }, "oversized response must fail")
        let receiving = try receipt("receiving", 1)
        try check(try store.ingest(receiving) != nil)
        try check(try store.ingest(receiving) != nil, "exact duplicate is idempotent")
        try check(try store.ingest(receipt("prepared", 1)) == nil, "same-revision conflict fails closed")
        try check(try store.ingest(receipt("accepted", 3)) != nil)
        try check(try store.ingest(receipt("prepared", 2)) == nil, "stale status rejected")
        try check(try store.ingest(receipt("receiving", 4)) == nil, "higher revision cannot regress acceptance")
        try check(try store.ingest(receipt("cancelled", 4)) == nil, "accepted work is no longer cancellable")
        expectFailure({ try store.beginUpload(operationID: record.operationID, deviceID: deviceID, appNamespace: "test.dev", uploadAttemptID: UUID()) }, "accepted work must never upload again")
        let acceptedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt("accepted", 3)))
        let acceptedBody = try JSONSerialization.data(withJSONObject: ["operation": acceptedObject])
        try check(try store.completeUpload(operationID: record.operationID, deviceID: deviceID,
            appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: secondAttempt,
            responseBody: acceptedBody, httpStatus: 200, errorCode: nil))
        try check(try DeviceMapOperationStore(url: url).records()[0].observation == "commit_accepted",
                  "background accepted receipt and transport body persist before delivery without installed success")
        try check(try store.completeUpload(operationID: record.operationID, deviceID: deviceID,
            appNamespace: "test.dev", mapID: "map", sessionID: "session", uploadAttemptID: secondAttempt,
            responseBody: Data(), httpStatus: 500, errorCode: -1), "duplicate callback is idempotent")
        try check(try store.records()[0].uploadHTTPStatus == 200, "duplicate completion cannot rewrite durable transport outcome")
        try check(try store.ingest(receipt("installed", 5))?.observation == "installed_confirmed")
        try check(try store.ingest(receipt("failed", 6)) == nil, "terminal cannot be replaced")
        expectFailure({ try store.save(record) }, "stale whole-record save must fail")
        persisted = try store.records()[0]
        var changedAdmission = persisted
        changedAdmission.admissionRevision = 43
        expectFailure({ try store.save(changedAdmission) }, "original admission is immutable")
        try check(try DeviceMapOperationStore(url: url).records()[0] == persisted)

        // Deterministic cancellation/commit linearization: the older prepared
        // continuation must re-read durable intent before any network send.
        let cancelStore = DeviceMapOperationStore(url: directory.appendingPathComponent("cancel.json"))
        try cancelStore.save(record)
        _ = try cancelStore.ingest(receipt("prepared", 2))
        let stalePrepared = try cancelStore.records()[0]
        try check(stalePrepared.nextControlAction == .commit && !stalePrepared.isTerminal)
        try check(stalePrepared.permitsPrecommitSessionRecovery(after: receipt("prepared", 2)),
                  "fresh exact Prepared evidence permits re-establishing a stopped transport")
        try check(!stalePrepared.permitsPrecommitSessionRecovery(after: receipt("prepared", 2,
            overrides: ["deviceID": "foreign"])), "another device cannot authorize precommit session recovery")
        try check(!stalePrepared.permitsPrecommitSessionRecovery(after: receipt("receiving", 1)),
                  "stale precommit state cannot authorize recovery")
        var sentCommitCount = 0
        _ = try cancelStore.requestCancellation(operationID: record.operationID)
        expectFailure({
            _ = try cancelStore.requestCommit(operationID: record.operationID)
            sentCommitCount += 1
        }, "cancel-first must fence an older prepared commit continuation")
        try check(sentCommitCount == 0)
        expectFailure({ try cancelStore.save(stalePrepared) }, "stale prepared snapshot cannot erase cancellation")
        let restartedCancelStore = DeviceMapOperationStore(url: directory.appendingPathComponent("cancel.json"))
        try check(try restartedCancelStore.records()[0].nextControlAction == .cancel,
                  "cancel intent survives app termination using the same operation ID")
        _ = try restartedCancelStore.ingest(receipt("cancelled", 3))
        try check(try restartedCancelStore.records()[0].observation == "cancelled_before_commit")

        let commitURL = directory.appendingPathComponent("commit.json")
        let commitStore = DeviceMapOperationStore(url: commitURL)
        try commitStore.save(record)
        _ = try commitStore.ingest(receipt("prepared", 2))
        let restoredPrepared = DeviceMapOperationStore(url: commitURL)
        try check(try restoredPrepared.records()[0].nextControlAction == .commit,
                  "termination between prepared upload and commit resumes control without upload")
        _ = try restoredPrepared.requestCommit(operationID: record.operationID,
                                               now: Date(timeIntervalSince1970: 123))
        try check(try DeviceMapOperationStore(url: commitURL).records()[0].commitRequestedAt != nil,
                  "commit intent is durable before transport sends the request")
        try restoredPrepared.markControlResponseUnknown(operationID: record.operationID)
        try check(try restoredPrepared.records()[0].observation == "result_unknown",
                  "lost commit response is unknown, never cancelled or installed")
        _ = try restoredPrepared.requestCancellation(operationID: record.operationID)
        _ = try restoredPrepared.ingest(receipt("accepted", 3))
        let grantWon = try restoredPrepared.records()[0]
        try check(grantWon.observation == "commit_accepted" && grantWon.nextControlAction == .query,
                  "grant-first wins over cancel intent; only terminal query is allowed")
        try check(!grantWon.permitsPrecommitSessionRecovery(after: receipt("prepared", 2)),
                  "a retained accepted grant cannot be erased by precommit recovery")
        try check(try restoredPrepared.ingest(receipt("cancelled", 4)) == nil,
                  "late cancellation cannot change accepted work to cancelled")
        expectFailure({ _ = try restoredPrepared.requestCommit(operationID: record.operationID) },
                      "accepted operation never starts another commit attempt")
        _ = try restoredPrepared.ingest(receipt("installed", 4))
        try check(try restoredPrepared.records()[0].isTerminal)

        let premanifest = DeviceMapOperationStore(url: directory.appendingPathComponent("premanifest.json"))
        try premanifest.save(record)
        _ = try premanifest.requestCancellation(operationID: record.operationID)
        try check(try premanifest.records()[0].nextControlAction == .cancel,
                  "pre-manifest cancellation sends full saved identity rather than a new upload")
        expectFailure({ try premanifest.beginUpload(operationID: record.operationID, deviceID: deviceID,
            appNamespace: record.appNamespace, uploadAttemptID: UUID()) }, "cancel intent fences upload retry")
        _ = try premanifest.ingest(receipt("cancelled", 1))
        try check(try premanifest.records()[0].isTerminal)

        let history = DeviceMapOperationStore(url: directory.appendingPathComponent("history.json"))
        let now = Date()
        for index in 0..<70 {
            var terminal = makeRecord()
            try check(terminal.apply(receipt("installed", 5, overrides: ["operationID": terminal.wireOperationID])))
            terminal.acknowledgedAt = now.addingTimeInterval(Double(index - 100))
            terminal.cleanup = "complete"
            terminal.uploadResponseBody = Data(repeating: 1, count: 100)
            try history.save(terminal)
        }
        let fullHistory = try history.records()
        try check(fullHistory.filter { $0.retiredAt == nil }.count <= 64,
                  "acknowledged cleaned terminal history has a bounded full-record window")
        try check(fullHistory.count == 70, "compaction retains exact-ID tombstones")
        try check(fullHistory.filter { $0.retiredAt != nil }.allSatisfy { $0.uploadResponseBody == nil })
        var unacknowledged = makeRecord()
        try check(unacknowledged.apply(receipt("installed", 5, overrides: ["operationID": unacknowledged.wireOperationID])))
        unacknowledged.cleanup = "complete"
        try history.save(unacknowledged)
        var transportPending = makeRecord()
        try check(transportPending.apply(receipt("installed", 5, overrides: ["operationID": transportPending.wireOperationID])))
        transportPending.cleanup = "complete"
        transportPending.acknowledgedAt = now
        transportPending.uploadAttemptID = UUID()
        try history.save(transportPending)
        let protectedUnknown = makeRecord()
        try history.save(protectedUnknown)
        try history.pruneAcknowledgedHistory(now: now.addingTimeInterval(31 * 24 * 60 * 60))
        try check(try history.records().contains { $0.operationID == protectedUnknown.operationID },
                  "history expiry never removes unresolved work")
        try check(try history.records().contains { $0.operationID == unacknowledged.operationID && $0.retiredAt == nil },
                  "terminal receipt without confirmed device ACK is never pruned")
        try check(try history.records().contains { $0.operationID == transportPending.operationID && $0.retiredAt == nil },
                  "terminal receipt cannot prune an active or missing OS transport callback")
        try check(try history.records().filter { $0.retiredAt != nil }.isEmpty,
                  "expired tombstones leave room for later operations")
        let legacyHistory = DeviceMapOperationStore(url: directory.appendingPathComponent("legacy-history.json"))
        let legacyProcess = DeviceMapOperationStore.observationProcessID
        func legacyRecord() -> DeviceMapOperationRecord {
            var value = makeRecord()
            value.usesDurableProtocol = false
            value.observationProcessID = legacyProcess
            return value
        }
        var mismatchedLegacy = legacyRecord()
        try check(!mismatchedLegacy.confirmLegacyTerminal(outcome: "installed_confirmed",
            deviceID: "other", connectionEpoch: 7, processID: legacyProcess), "legacy proof requires exact device")
        try check(!mismatchedLegacy.confirmLegacyTerminal(outcome: "installed_confirmed",
            deviceID: deviceID, connectionEpoch: 8, processID: legacyProcess), "legacy proof requires original epoch")
        try check(!mismatchedLegacy.confirmLegacyTerminal(outcome: "installed_confirmed",
            deviceID: deviceID, connectionEpoch: 7, processID: UUID()), "legacy proof cannot survive unconfirmed relaunch")
        try check(mismatchedLegacy.legacyTerminalConfirmedAt == nil && !mismatchedLegacy.isTerminal)
        for index in 0..<150 {
            var completed = legacyRecord()
            try legacyHistory.save(completed)
            try check(completed.confirmLegacyTerminal(
                outcome: index.isMultiple(of: 2) ? "installed_confirmed" : "failed_or_rolled_back",
                deviceID: deviceID, connectionEpoch: 7, processID: legacyProcess,
                now: now.addingTimeInterval(Double(index - 200))))
            try legacyHistory.save(completed)
            try legacyHistory.markCleanupComplete(operationID: completed.operationID)
        }
        let relaunchedLegacy = DeviceMapOperationStore(url: directory.appendingPathComponent("legacy-history.json"))
        let legacyRecords = try relaunchedLegacy.records()
        try check(legacyRecords.count == 150 && legacyRecords.filter { $0.retiredAt == nil }.count <= 64,
                  "more than 128 confirmed cleaned legacy installs retain local tombstones without exhausting admission")
        try check(legacyRecords.allSatisfy { $0.lastReceipt == nil && $0.acknowledgedAt == nil },
                  "legacy compaction never fabricates a device receipt or ACK")
        var unconfirmedLegacy = legacyRecord()
        unconfirmedLegacy.observation = "installed_confirmed"
        unconfirmedLegacy.cleanup = "complete"
        try legacyHistory.save(unconfirmedLegacy)
        var activeLegacy = legacyRecord()
        try check(activeLegacy.confirmLegacyTerminal(outcome: "installed_confirmed", deviceID: deviceID,
            connectionEpoch: 7, processID: legacyProcess))
        activeLegacy.cleanup = "complete"
        activeLegacy.uploadAttemptID = UUID()
        try legacyHistory.save(activeLegacy)
        try legacyHistory.pruneAcknowledgedHistory(now: now.addingTimeInterval(31 * 24 * 60 * 60))
        try check(try legacyHistory.records().contains { $0.operationID == unconfirmedLegacy.operationID && $0.retiredAt == nil },
                  "legacy terminal label without original observation proof is never compacted")
        try check(try legacyHistory.records().contains { $0.operationID == activeLegacy.operationID && $0.retiredAt == nil },
                  "legacy proof cannot compact an outstanding upload callback")
        let saturatedLegacy = DeviceMapOperationStore(url: directory.appendingPathComponent("legacy-saturated.json"))
        for _ in 0..<128 { try saturatedLegacy.save(legacyRecord()) }
        expectFailure({ try saturatedLegacy.save(legacyRecord()) }, "128 unresolved legacy operations still refuse admission")
        try check(try saturatedLegacy.records().count == 128)

        let saturated = DeviceMapOperationStore(url: directory.appendingPathComponent("saturated.json"))
        for _ in 0..<128 { try saturated.save(makeRecord()) }
        expectFailure({ try saturated.save(makeRecord()) }, "128 unresolved records must refuse new admission")
        try check(try saturated.records().count == 128)

        let failedDestination = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: failedDestination, withIntermediateDirectories: false)
        expectFailure({ try DeviceMapOperationStore(url: failedDestination).save(record) }, "IO failure must propagate")
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: corruptURL)
        expectFailure({ try DeviceMapOperationStore(url: corruptURL).save(record) }, "corrupt journal cannot be silently replaced")
        try check(try Data(contentsOf: corruptURL) == corrupt)
        print("Device map operation identity, replay, durability, admission, and IO tests passed")
    }
}
