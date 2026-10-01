import Combine
import CryptoKit
import Foundation
import Security

nonisolated enum DiagnosticsBrokerClientError: Error {
    case invalidEnrollment, permissionDenied, invalidCommand, invalidResponse, unavailable, uploadMismatch
}

/// Opt-in, app-owned outgoing client. No inbound phone HTTP server, public relay,
/// automatic pairing, shell command, firmware flash or device reset is exposed.
@MainActor
final class DiagnosticsBrokerClientV2: ObservableObject {
    @Published private(set) var paired = false
    @Published private(set) var status = "Not paired with a Mac"
    private let recorder: RideDiagnosticsRecorder
    private let ble: BLEManager
    private let collection: DiagnosticsCollectionCoordinatorV2
    private var enrollment: DiagnosticsBrokerEnrollmentV2?
    private var session: URLSession?
    private var pumpTask: Task<Void, Never>?
    private var active = false
    private var rideActive = false
    private var family: String { Bundle.main.bundleIdentifier ?? "unknown" }
    private var stateURL: URL { recorder.controlRootURL.appendingPathComponent("broker", isDirectory: true) }

    init(recorder: RideDiagnosticsRecorder, ble: BLEManager, collection: DiagnosticsCollectionCoordinatorV2) {
        self.recorder = recorder; self.ble = ble; self.collection = collection
        var query = keychainQuery()
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, data.count <= 16 * 1024,
           let value = try? JSONDecoder().decode(DiagnosticsBrokerEnrollmentV2.self, from: data), value.valid(for: family) {
            configure(value)
        }
    }

    func importEnrollment(_ data: Data, allowCapture: Bool, allowCollection: Bool) throws {
        guard data.count <= 16 * 1024,
              var value = try? JSONDecoder().decode(DiagnosticsBrokerEnrollmentV2.self, from: data), value.valid(for: family) else {
            throw DiagnosticsBrokerClientError.invalidEnrollment
        }
        value.permissions = value.permissions.filter {
            $0 == "read" || ($0 == "capture" && allowCapture) || ($0 == "collect" && allowCollection)
        }
        let raw = try JSONEncoder().encode(value)
        let query = keychainQuery()
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: raw] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = raw
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DiagnosticsBrokerClientError.unavailable }
        } else if updated != errSecSuccess { throw DiagnosticsBrokerClientError.unavailable }
        configure(value)
        if active { startPump() }
    }

    func revoke() {
        pumpTask?.cancel(); pumpTask = nil
        session?.invalidateAndCancel(); session = nil
        enrollment = nil; paired = false; status = "Mac access revoked on this iPhone"
        SecItemDelete(keychainQuery() as CFDictionary)
    }
    func setApplicationActive(_ value: Bool) {
        active = value
        if value { startPump() } else { pumpTask?.cancel(); pumpTask = nil }
    }
    func setRideActive(_ value: Bool) { rideActive = value }

    private func configure(_ value: DiagnosticsBrokerEnrollmentV2) {
        pumpTask?.cancel(); pumpTask = nil; session?.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]; config.allowsCellularAccess = false
        config.waitsForConnectivity = false; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        session = DeviceTransferPinnedSessionFactory.make(configuration: config, baseURL: value.baseURL,
                                                          certificateSHA256: value.certificateSHA256)
        enrollment = value; paired = session != nil; status = paired ? "Paired; waiting for the Mac" : "Unable to configure secure Mac connection"
    }
    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(family).diagnostics-broker.v2",
         kSecAttrAccount as String: "enrollment", kSecAttrSynchronizable as String: false]
    }
    private func startPump() {
        guard pumpTask == nil, paired, active else { return }
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { break }
                do {
                    try await self.tick()
                    self.status = "Mac connected; retained logs stay local until collection is requested"
                } catch is CancellationError { break }
                catch { self.status = "Mac unavailable; recording and retained evidence are unaffected" }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
    }

    private func tick() async throws {
        guard let enrollment, enrollment.valid(for: family) else { throw DiagnosticsBrokerClientError.invalidEnrollment }
        var heartbeat: [String: Any] = ["schema": 2, "appFamily": family, "foreground": active, "rideActive": rideActive,
            "iphone": ["contractSHA256": DiagnosticsContractV2.sha256, "levels": DiagnosticsContractV2.levels,
                       "domains": DiagnosticsContractV2.domains, "retainedBytes": recorder.retainedBytes,
                       "droppedEvents": recorder.droppedEventCount,
                       "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                       "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"]]
        if let deviceID = ble.connectedDeviceID { heartbeat["deviceDigest"] = recorder.deviceDigest(for: deviceID) }
        let encoder = JSONEncoder()
        if let device = ble.diagnosticsStatusV2 { heartbeat["device"] = try JSONSerialization.jsonObject(with: encoder.encode(device)) }
        if let capture = recorder.currentPolicyV2 { heartbeat["capture"] = try JSONSerialization.jsonObject(with: encoder.encode(capture)) }
        heartbeat["tail"] = try JSONSerialization.jsonObject(with: encoder.encode(Array(recorder.recentEvents.suffix(32))))
        _ = try await request("v2/heartbeat", method: "POST", body: try JSONSerialization.data(withJSONObject: heartbeat))
        let next = try await request("v2/next")
        guard let command = next["command"] as? [String: Any] else { return }
        try await execute(command)
    }

    private func execute(_ command: [String: Any]) async throws {
        guard let idString = command["id"] as? String, let id = UUID(uuidString: idString),
              let kind = command["kind"] as? String, let arguments = command["arguments"] as? [String: Any],
              let digest = command["deviceDigest"] as? String, DiagnosticsAcquisitionV2.validDigest(digest),
              let expiry = command["expiresAtEpoch"] as? Int, TimeInterval(expiry) > Date().timeIntervalSince1970,
              Set(command.keys) == Set(["id", "kind", "arguments", "deviceDigest", "expiresAtEpoch"]) else { throw DiagnosticsBrokerClientError.invalidCommand }
        let permission = kind == "collect" ? "collect" : (kind == "observe" ? "read" : "capture")
        guard ["capture.start", "capture.end", "mark", "collect", "observe"].contains(kind),
              enrollment?.permissions.contains(permission) == true else {
            _ = try await request("v2/jobs/\(id.uuidString.lowercased())", method: "POST", json: ["ok": false, "code": "permission_denied"])
            return
        }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let receiptURL = stateURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
        if let size = try? receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024,
           let receipt = try? Data(contentsOf: receiptURL) {
            _ = try await request("v2/jobs/\(id.uuidString.lowercased())", method: "POST", body: receipt)
            return
        }
        // Durable job identity allows an already collected bundle to upload
        // after the Bicino powers off. New hardware actions require exact peer.
        let alreadyCollected = collection.completedBundle(for: id) != nil
        guard (kind == "collect" && alreadyCollected) || (ble.connectedDeviceID.map(recorder.deviceDigest(for:)) == digest && ble.isNavigationReady) else {
            return // Keep queued, do not guess another connected board.
        }
        if kind == "collect" && (rideActive || (collection.isCollecting && collection.job?.id != id)) { return }
        let result: [String: Any]
        do {
            switch kind {
            case "capture.start":
                guard Set(arguments.keys) == Set(["captureID", "generation", "profile", "durationSeconds", "createdAtEpoch", "levels"]),
                      let capture = arguments["captureID"] as? String, let captureID = UUID(uuidString: capture),
                      let generation = arguments["generation"] as? UInt32,
                      let profile = arguments["profile"] as? String,
                      let duration = arguments["durationSeconds"] as? UInt32,
                      let created = arguments["createdAtEpoch"] as? Int,
                      let levels = arguments["levels"] as? [String: String],
                      TimeInterval(created) + TimeInterval(duration) > Date().timeIntervalSince1970 else { throw DiagnosticsBrokerClientError.invalidCommand }
                let acknowledged = try await collection.startCapture(profile: profile, durationSeconds: duration,
                    captureID: captureID, generation: generation, levels: levels, createdAt: Date(timeIntervalSince1970: TimeInterval(created)))
                result = ["ok": true, "captureID": captureID.uuidString.lowercased(), "receipt": try JSONSerialization.jsonObject(with: JSONEncoder().encode(acknowledged))]
            case "capture.end":
                guard Set(arguments.keys) == Set(["captureID"]), let capture = arguments["captureID"] as? String,
                      let current = recorder.currentPolicyV2, current.captureID.uuidString.lowercased() == capture,
                      current.generation < UInt32.max else { throw DiagnosticsBrokerClientError.invalidCommand }
                let policy = try DiagnosticsCapturePolicyV2(captureID: current.captureID, generation: current.generation + 1,
                                                            profile: "baseline", durationSeconds: 0)
                try recorder.applyCapturePolicyV2(policy)
                let acknowledgement = try await ble.applyDiagnosticsPolicyV2(policy)
                result = ["ok": true, "captureID": capture, "receipt": try JSONSerialization.jsonObject(with: JSONEncoder().encode(acknowledgement))]
            case "mark":
                guard Set(arguments.keys) == Set(["code"]), let raw = arguments["code"] as? String,
                      let code = RideIssueCode(rawValue: raw), let marker = collection.mark(code) else { throw DiagnosticsBrokerClientError.invalidCommand }
                result = ["ok": true, "incidentID": marker.uuidString.lowercased(), "devicePersistence": "pending_or_unavailable"]
            case "observe":
                guard Set(arguments.keys) == Set(["bootSequence", "after", "limit"]),
                      let boot = arguments["bootSequence"] as? UInt32, let after = arguments["after"] as? UInt32,
                      let limit = arguments["limit"] as? UInt32 else { throw DiagnosticsBrokerClientError.invalidCommand }
                let raw = try await ble.readDiagnosticsTailV2(boot: boot, after: after, limit: limit)
                result = ["ok": true, "tail": try JSONSerialization.jsonObject(with: raw)]
            case "collect":
                guard Set(arguments.keys).isSubset(of: ["captureID"]) else { throw DiagnosticsBrokerClientError.invalidCommand }
                let capture = (arguments["captureID"] as? String).flatMap(UUID.init(uuidString:))
                if arguments["captureID"] != nil && capture == nil { throw DiagnosticsBrokerClientError.invalidCommand }
                let bundle = try await collection.collect(captureID: capture, collectionID: id)
                try Task.checkCancellation()
                let hash = try await upload(bundle, commandID: id)
                result = ["ok": true, "artifactSHA256": hash, "collectionID": id.uuidString.lowercased()]
            default: throw DiagnosticsBrokerClientError.invalidCommand
            }
        } catch is CancellationError { throw CancellationError() }
        catch DiagnosticsBrokerClientError.invalidCommand { result = ["ok": false, "code": "invalid_command"] }
        catch DiagnosticsPolicyError.unsupported { result = ["ok": false, "code": "firmware_capability_unavailable", "iphoneCaptureMayBeActive": true] }
        catch DiagnosticsPolicyError.acknowledgementTimeout { result = ["ok": false, "code": "firmware_policy_acknowledgement_missing", "iphoneCaptureMayBeActive": true] }
        catch { throw error } // Transport/interruption remains retryable, never a false completion.
        let raw = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try raw.write(to: receiptURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        _ = try await request("v2/jobs/\(id.uuidString.lowercased())", method: "POST", body: raw)
    }

    private func upload(_ file: URL, commandID: UUID) async throws -> String {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 110 * 1024 * 1024 else { throw DiagnosticsBrokerClientError.uploadMismatch }
        let digest = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        let path = "v2/uploads/\(commandID.uuidString.lowercased())"
        let existing = try await request(path)
        var offset = existing["received"] as? Int ?? 0
        guard offset >= 0, offset <= size,
              existing["sha256"] == nil || existing["sha256"] as? String == digest else { throw DiagnosticsBrokerClientError.uploadMismatch }
        if existing["complete"] as? Bool == true { return digest }
        guard offset < size else { throw DiagnosticsBrokerClientError.uploadMismatch }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        while offset < size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: min(1024 * 1024, size - offset)), !bytes.isEmpty else { throw DiagnosticsBrokerClientError.uploadMismatch }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let result = try await request("\(path)/\(digest)/\(size)/\(offset)", method: "POST", body: bytes,
                                           headers: ["X-Bicino-Chunk-SHA256": hash])
            guard let received = result["received"] as? Int, received == offset + bytes.count else { throw DiagnosticsBrokerClientError.uploadMismatch }
            offset = received
            if offset == size && result["complete"] as? Bool != true { throw DiagnosticsBrokerClientError.uploadMismatch }
        }
        return digest
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                         body: Data? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let enrollment, enrollment.valid(for: family), let session else { throw DiagnosticsBrokerClientError.invalidEnrollment }
        var request = URLRequest(url: enrollment.baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = try body ?? json.map { try JSONSerialization.data(withJSONObject: $0) }
        request.setValue("Bearer " + enrollment.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= 128 * 1024 else { throw DiagnosticsBrokerClientError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1024 else { throw DiagnosticsBrokerClientError.invalidResponse }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiagnosticsBrokerClientError.invalidResponse }
        return object
    }
}
