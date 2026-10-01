import Foundation

@main
struct DeviceMapOperationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "") throws {
        if try !condition() { fatalError(message) }
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.json")
        let store = DeviceMapOperationStore(url: url)
        let deviceID = String(repeating: "a", count: 32)
        let record = DeviceMapOperationRecord(
            schemaVersion: 1, deviceID: deviceID, operationID: UUID(),
            sessionID: "session", mapID: "map", manifestReceipt: String(repeating: "b", count: 64),
            signedManifestReceipt: String(repeating: "c", count: 64),
            streamSHA256: String(repeating: "d", count: 64), streamBytes: 123,
            artifactFilename: "map.bmap", appNamespace: "test.dev", createdAt: Date(timeIntervalSince1970: 1),
            connectionEpoch: 7, observation: "in_progress", cleanup: "pending", usesDurableProtocol: true,
            lastReceipt: nil, admissionEpoch: String(repeating: "e", count: 32), admissionRevision: 42
        )
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
        try store.save(record)
        try check(try DeviceMapOperationStore(url: url).records() == [record], "atomic record survives relaunch")
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
