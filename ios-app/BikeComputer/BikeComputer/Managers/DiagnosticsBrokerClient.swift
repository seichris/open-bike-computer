import Combine
import CryptoKit
import Foundation
import Security

nonisolated enum DiagnosticsBrokerKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Bicino") + ".diagnostics-broker-v2",
         kSecAttrAccount as String: "pairing"]
    }
    static func read() throws -> DiagnosticsBrokerPairing? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096 else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        return try JSONDecoder().decode(DiagnosticsBrokerPairing.self, from: data)
    }
    static func save(_ pairing: DiagnosticsBrokerPairing) throws {
        let data = try JSONEncoder().encode(pairing)
        var attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        attributes.merge(query) { old, _ in old }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
    }
    static func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
    }
}

nonisolated private enum DiagnosticsBrokerHTTP {
    enum Failure: Error { case unavailable, invalidResponse, authorizationDenied }
    static func request(_ pairing: DiagnosticsBrokerPairing, method: String, path: String,
                        body: Data? = nil, file: URL? = nil, digest: String? = nil) async throws -> Data {
        guard pairing.valid(), let base = pairing.baseURL else { throw Failure.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = file == nil ? 20 : 120
        guard let session = DeviceTransferPinnedSessionFactory.make(configuration: configuration,
            baseURL: base, certificateSHA256: pairing.certificateSHA256) else { throw Failure.unavailable }
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        let credential: String
        if path == "v3/enroll" {
            guard let enrollment = pairing.enrollment else { throw Failure.unavailable }
            credential = enrollment.token
        } else {
            guard pairing.enrollment == nil else { throw Failure.unavailable }
            credential = pairing.token
        }
        request.setValue(credential, forHTTPHeaderField: "X-Bicino-Diagnostics-Token")
        request.setValue(file == nil ? "application/json" : "application/zip", forHTTPHeaderField: "Content-Type")
        if let digest { request.setValue(digest, forHTTPHeaderField: "X-Content-SHA256") }
        if let file {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 104 * 1024 * 1024 else { throw Failure.invalidResponse }
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            // Stream request AND response. upload(for:fromFile:) accumulates an
            // unbounded response Data before returning; a paired peer is still
            // an untrusted input. No redirects/re-authentication are followed,
            // so a consumed body stream is retried as a fresh idempotent upload.
            guard let input = InputStream(url: file) else { throw Failure.invalidResponse }
            request.httpBodyStream = input
        } else {
            request.httpBody = body
            request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
        }
        let (stream, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw Failure.authorizationDenied }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= 64 * 1024 else { throw Failure.invalidResponse }
        var data = Data()
        for try await byte in stream {
            guard data.count < 64 * 1024 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return data
    }
}

/// An explicitly paired LAN handoff, independent of the local flight recorder.
/// No polling while suspended; a durable outbox retries during future foreground
/// sessions. No arbitrary remote code, UI control, reset, flash or raw log access.
@MainActor
final class DiagnosticsBrokerClient: ObservableObject {
    static let shared = DiagnosticsBrokerClient()
    @Published private(set) var isPaired = false
    @Published private(set) var status = "No Mac paired. Logs stay on this iPhone."
    private weak var recorder: RideDiagnosticsRecorder?
    private weak var bleManager: BLEManager?
    private var pairing: DiagnosticsBrokerPairing?
    private var active = false
    private var loop: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let root: URL
    private var journals: [String: DiagnosticsBrokerCommandJournal] = [:]
    private var loopGeneration: UInt64 = 0
    private let phoneID: UUID
    private struct LiveLease {
        let deadline: TimeInterval
        var phoneAfter: Int = -1
        var firmwareBoot: UInt32 = 0
        var firmwareAfter: UInt32 = 0
    }
    private var liveLeases: [String: LiveLease] = [:]

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BicinoDiagnosticsOutbox/v2", isDirectory: true)
        let saved = try? DiagnosticsBrokerKeychain.read()
        let key = "diagnostics.broker.phone-id.v2"
        if let existing = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: existing) {
            phoneID = id
        } else {
            phoneID = saved?.phoneID ?? UUID()
            UserDefaults.standard.set(phoneID.uuidString, forKey: key)
        }
        do {
            pairing = try DiagnosticsBrokerKeychain.read()
            isPaired = pairing?.valid() == true && (pairing?.phoneID == nil || pairing?.phoneID == phoneID)
            if pairing != nil { status = isPaired ? "Mac pairing loaded. Waiting for the app to be active." : "Mac pairing is unavailable or expired; retained logs are unaffected." }
        } catch {
            status = "Mac pairing is unavailable. No credentials were sent."
        }
    }

    func configure(recorder: RideDiagnosticsRecorder, bleManager: BLEManager) {
        self.recorder = recorder
        self.bleManager = bleManager
        guard cancellables.isEmpty else { return }
        DiagnosticsCollectionCoordinator.shared.$manifest
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id && $0.phase == $1.phase }
            .filter(\.deliveryComplete)
            .sink { [weak self] manifest in self?.enqueueExport(acquisitionID: manifest.id) }
            .store(in: &cancellables)
    }

    func pair(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        let data = try Data(contentsOf: url)
        struct Version: Decodable { let schema: Int }
        let version = try JSONDecoder().decode(Version.self, from: data)
        let candidate: DiagnosticsBrokerPairing
        if version.schema == 3 {
            let enrollment = try JSONDecoder().decode(DiagnosticsBrokerEnrollment.self, from: data)
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DiagnosticsAcquisitionStore.Failure.invalidManifest
            }
            candidate = try enrollment.pairing(phoneID: phoneID,
                credential: bytes.map { String(format: "%02x", $0) }.joined(), credentialID: UUID(), existing: pairing)
        } else {
            candidate = try JSONDecoder().decode(DiagnosticsBrokerPairing.self, from: data)
        }
        guard candidate.valid() else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        try DiagnosticsBrokerKeychain.save(candidate)
        loopGeneration &+= 1
        loop?.cancel()
        loop = nil
        pairing = candidate
        liveLeases.removeAll()
        isPaired = true
        if let expiry = candidate.expiresAt {
            status = "Temporary Mac pairing until \(Date(timeIntervalSince1970: Double(expiry)).formatted())."
        } else {
            status = candidate.enrollment == nil ? "Mac paired until you unpair or revoke it." : "Mac enrollment queued. Open the app on the Mac's LAN to finish pairing."
        }
        setActive(active)
    }

    func unpair() async throws {
        let previous = pairing
        try DiagnosticsBrokerKeychain.remove()
        pairing = nil
        liveLeases.removeAll()
        isPaired = false
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel(); loop = nil
        status = "Mac unpaired locally. Local logs and pending handoffs were preserved."
        guard let previous, previous.schema == 3,
              let credentialID = previous.credentialID, let phoneID = previous.phoneID else { return }
        // A pending enrollment may already have committed and lost its reply.
        // Use its persisted phone secret only to revoke; never enroll on Unpair.
        let revocation = DiagnosticsBrokerPairing(schema: 3, origin: previous.origin,
            certificateSHA256: previous.certificateSHA256, token: previous.token,
            brokerID: previous.brokerID, phoneID: phoneID, credentialID: credentialID,
            enrollmentID: previous.enrollmentID)
        let body: [String: Any] = ["schema":3, "credentialID":credentialID.uuidString, "phoneID":phoneID.uuidString]
        var revoked = false
        do {
            _ = try await DiagnosticsBrokerHTTP.request(revocation, method: "POST", path: "v3/unpair",
                body: JSONSerialization.data(withJSONObject: body))
            revoked = true
        } catch DiagnosticsBrokerHTTP.Failure.authorizationDenied {
            revoked = true // The pinned broker has no active credential to revoke.
        } catch { }
        guard loopGeneration == generation, pairing == nil else { return }
        status = revoked ? "Mac unpaired. Local logs and pending handoffs were preserved."
            : "Unpaired on this iPhone. Mac unavailable; check and revoke its phone credential on the Mac. Local logs were preserved."
    }

    func setActive(_ value: Bool) {
        active = value
        if !value || !isPaired { loopGeneration &+= 1; loop?.cancel(); loop = nil; return }
        guard loop == nil else { return }
        loopGeneration &+= 1
        let generation = loopGeneration
        loop = Task { [weak self] in
            defer {
                if self?.loopGeneration == generation { self?.loop = nil }
            }
            while !Task.isCancelled {
                guard let self, active, let candidate = pairing else { return }
                guard candidate.valid(), candidate.phoneID == nil || candidate.phoneID == phoneID else {
                    isPaired = false; status = "Temporary Mac pairing expired. Local logs and pending handoffs are retained."; return
                }
                do {
                    let confirmed: DiagnosticsBrokerPairing
                    if let enrollment = candidate.enrollmentRequest {
                        let response = try await DiagnosticsBrokerHTTP.request(candidate, method: "POST", path: "v3/enroll",
                            body: JSONEncoder().encode(enrollment))
                        try checkOwner(candidate, generation: generation)
                        confirmed = try candidate.confirmed(by: JSONDecoder().decode(DiagnosticsBrokerEnrollmentReceipt.self, from: response))
                        // The same phone-created credential remains in Keychain
                        // across lost replies, process loss and enrollment expiry.
                        try DiagnosticsBrokerKeychain.save(confirmed)
                        pairing = confirmed
                    } else { confirmed = candidate }
                    try await poll(confirmed, generation: generation)
                    status = "Mac connected. Local recording remains independent."
                } catch DiagnosticsBrokerHTTP.Failure.authorizationDenied {
                    if !Task.isCancelled, loopGeneration == generation {
                        isPaired = false
                        status = "Mac enrollment expired or pairing was revoked. Import a fresh enrollment file; retained logs are unaffected."
                    }
                    return
                } catch {
                    if !Task.isCancelled, loopGeneration == generation { status = "Mac unavailable; local logs and pending handoffs are retained." }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func checkOwner(_ expected: DiagnosticsBrokerPairing, generation: UInt64) throws {
        try Task.checkCancellation()
        guard active, loopGeneration == generation, pairing == expected else { throw CancellationError() }
    }

    private func poll(_ pairing: DiagnosticsBrokerPairing, generation: UInt64) async throws {
        guard let recorder, let bleManager else { return }
        let journal: DiagnosticsBrokerCommandJournal
        if let existing = journals[pairing.certificateSHA256] {
            journal = existing
        } else {
            journal = DiagnosticsBrokerCommandJournal(root: recipientRoot(pairing).appendingPathComponent("commands.json"))
            journals[pairing.certificateSHA256] = journal
        }
        let encoder = JSONEncoder()
        var policy: Any = NSNull()
        if let current = bleManager.diagnosticsCaptureStatus {
            policy = try JSONSerialization.jsonObject(with: encoder.encode(current))
        }
        var phonePolicy: Any = NSNull()
        if let current = recorder.requestedCapturePolicy {
            phonePolicy = try JSONSerialization.jsonObject(with: encoder.encode(current))
        }
        let deviceDigest: Any
        if let id = bleManager.connectedDeviceID { deviceDigest = recorder.deviceDigest(for: id) }
        else { deviceDigest = NSNull() }
        let observed: [String: Any] = [
            "schema": 2, "phoneID": phoneID.uuidString.lowercased(),
            "registryDigest": DiagnosticsSchema.digest,
            "deviceDigest": deviceDigest,
            "firmwarePolicy": policy, "phonePolicy": phonePolicy,
            "collectionRunning": DiagnosticsCollectionCoordinator.shared.isRunning,
        ]
        _ = try await DiagnosticsBrokerHTTP.request(pairing, method: "POST", path: "v2/phone",
            body: JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys]))
        try checkOwner(pairing, generation: generation)
        let commands = try await DiagnosticsBrokerHTTP.request(pairing, method: "GET", path: "v2/commands")
        try checkOwner(pairing, generation: generation)
        struct Batch: Decodable { let schema: Int; let commands: [DiagnosticsBrokerCommand] }
        let batch = try JSONDecoder().decode(Batch.self, from: commands)
        guard batch.schema == 2, batch.commands.count <= 8 else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        for command in batch.commands {
            try Task.checkCancellation()
            let claim = try await journal.claim(command)
            try checkOwner(pairing, generation: generation)
            let acknowledgement: DiagnosticsBrokerAcknowledgement
            if !claim.shouldExecute {
                acknowledgement = claim.receipt
            } else {
                acknowledgement = execute(command, recorder: recorder, bleManager: bleManager)
                try await journal.complete(command, receipt: acknowledgement)
            }
            try checkOwner(pairing, generation: generation)
            _ = try await DiagnosticsBrokerHTTP.request(pairing, method: "POST", path: "v2/ack",
                body: encoder.encode(acknowledgement))
            try checkOwner(pairing, generation: generation)
        }
        try checkOwner(pairing, generation: generation)
        try await publishLive(pairing, generation: generation)
        try checkOwner(pairing, generation: generation)
        try await uploadPending(pairing, generation: generation)
    }

    private func execute(_ command: DiagnosticsBrokerCommand, recorder: RideDiagnosticsRecorder,
                         bleManager: BLEManager) -> DiagnosticsBrokerAcknowledgement {
        func result(_ state: String, _ code: String) -> DiagnosticsBrokerAcknowledgement {
            DiagnosticsBrokerAcknowledgement(id: command.id, state: state, code: code)
        }
        guard command.valid() else { return result("rejected", "invalid_or_expired") }
        if command.requiresFirmware {
            guard let id = bleManager.connectedDeviceID,
                  recorder.deviceDigest(for: id) == command.target,
                  bleManager.isNavigationReady else { return result("rejected", "target_unavailable") }
        }
        switch command.kind {
        case "live":
            guard let seconds = command.parameters.durationSeconds,
                  liveLeases[command.target] != nil || liveLeases.count < 2 else {
                return result("rejected", "live_limit")
            }
            liveLeases[command.target] = LiveLease(deadline: ProcessInfo.processInfo.systemUptime + Double(seconds))
            return result("accepted", "bounded_live_observation_started")
        case "stop_live":
            liveLeases.removeValue(forKey: command.target)
            return result("accepted", "live_observation_stopped")
        case "capture":
            guard let mask = command.parameters.mask, let level = command.parameters.minimumLevel,
                  let seconds = command.parameters.durationSeconds, let budget = command.parameters.budgetBytes else {
                return result("rejected", "invalid_policy")
            }
            if command.requiresFirmware {
                guard let remote = bleManager.diagnosticsCaptureStatus,
                      remote.valid, remote.schemaDigest == DiagnosticsSchema.digest,
                      mask & ~remote.supportedMask == 0 else { return result("rejected", "provider_unavailable") }
            }
            guard let request = recorder.beginTargetedCapture(mask: mask, minimumLevel: level,
                seconds: seconds, budgetBytes: budget) else { return result("rejected", "invalid_policy") }
            if command.requiresFirmware {
                return bleManager.sendDiagnosticsCapturePolicy(request)
                    ? result("accepted", "awaiting_device_ack") : result("rejected", "device_policy_not_queued")
            }
            return result("accepted", "phone_policy_applied")
        case "stop_capture":
            guard let request = recorder.beginTargetedCapture(mask: DiagnosticsSchema.instrumentedMask,
                minimumLevel: 2, seconds: 1, budgetBytes: 1024) else { return result("rejected", "stop_failed") }
            if command.requiresFirmware {
                return bleManager.sendDiagnosticsCapturePolicy(request)
                    ? result("accepted", "awaiting_device_ack") : result("rejected", "device_policy_not_queued")
            }
            return result("accepted", "phone_baseline_applied")
        case "mark":
            guard let code = command.parameters.code.flatMap(RideIssueCode.init(rawValue:)),
                  recorder.markIssue(code, incidentID: command.id) else { return result("rejected", "phone_marker_failed") }
            if command.requiresFirmware {
                return bleManager.sendDiagnosticsIssueMarker(code, incidentID: command.id)
                    ? result("accepted", "device_marker_queued") : result("accepted", "phone_only_marker")
            }
            return result("accepted", "phone_marker_saved")
        case "collect":
            guard command.requiresFirmware else {
                return enqueueExport(acquisitionID: nil)
                    ? result("accepted", "local_snapshot_handoff_requested") : result("rejected", "handoff_not_started")
            }
            let collector = DiagnosticsCollectionCoordinator.shared
            guard !collector.isRunning else { return result("rejected", "collection_busy") }
            collector.start()
            return collector.isRunning
                ? result("accepted", "collection_requested") : result("rejected", "collection_not_started")
        case "export":
            return enqueueExport(acquisitionID: nil)
                ? result("accepted", "handoff_requested") : result("rejected", "handoff_not_started")
        default: return result("rejected", "unsupported_command")
        }
    }

    private func publishLive(_ pairing: DiagnosticsBrokerPairing, generation: UInt64) async throws {
        guard let recorder, let bleManager else { return }
        let now = ProcessInfo.processInfo.systemUptime
        liveLeases = liveLeases.filter { $0.value.deadline > now }
        for target in Array(liveLeases.keys) {
            guard var lease = liveLeases[target] else { continue }
            var batch: [String: Any]
            if target == "iphone" {
                let retained = recorder.recentEvents
                let selected = Array(retained.filter { $0.sequence > lease.phoneAfter }.prefix(16))
                guard !selected.isEmpty else { continue }
                let events = try selected.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                }
                let first = retained.first?.sequence ?? 0
                batch = ["schema": 2, "source": "ios", "device": "iphone",
                    "streamId": recorder.processId.uuidString.lowercased(), "events": events,
                    "oldestAvailableSequence": first, "latestAvailableSequence": retained.last?.sequence ?? 0,
                    "nextSequence": selected.last!.sequence,
                    "gap": lease.phoneAfter >= 0 && first > lease.phoneAfter + 1,
                    "durability": "observed_not_durable"]
                lease.phoneAfter = selected.last!.sequence
            } else {
                // Bulk/debug observations never compete with a ride's control
                // traffic. Recording continues locally and is collected later.
                guard DiagnosticsCollectionCoordinator.shared.allowsNonRidingDiagnostics,
                      let connected = bleManager.connectedDeviceID,
                      recorder.deviceDigest(for: connected) == target else { continue }
                if let tail = bleManager.diagnosticsLiveTail,
                   tail.bootSequence != lease.firmwareBoot || tail.nextSequence > lease.firmwareAfter,
                   let object = try JSONSerialization.jsonObject(with: tail.bytes) as? [String: Any] {
                    batch = ["schema": 2, "source": "firmware", "device": target,
                        "streamId": "boot:\(tail.bootSequence)", "events": object["events"] ?? [],
                        "oldestAvailableSequence": object["firstSequence"] ?? 0,
                        "latestAvailableSequence": object["lastSequence"] ?? 0,
                        "nextSequence": tail.nextSequence, "gap": object["gap"] ?? false,
                        "durability": "observed_not_durable"]
                    lease.firmwareBoot = tail.bootSequence
                    lease.firmwareAfter = tail.nextSequence
                } else {
                    _ = bleManager.requestDiagnosticsLiveTail(boot: lease.firmwareBoot, after: lease.firmwareAfter)
                    continue
                }
            }
            let bytes = try JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys])
            guard bytes.count <= 48 * 1024 else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
            _ = try await DiagnosticsBrokerHTTP.request(pairing, method: "POST", path: "v2/live", body: bytes)
            try checkOwner(pairing, generation: generation)
            // Cancellation/stop during await must not revive a previous lease.
            if liveLeases[target]?.deadline == lease.deadline { liveLeases[target] = lease }
            if target != "iphone", !Task.isCancelled,
               let connected = bleManager.connectedDeviceID,
               recorder.deviceDigest(for: connected) == target {
                _ = bleManager.requestDiagnosticsLiveTail(boot: lease.firmwareBoot, after: lease.firmwareAfter)
            }
        }
    }

    private func recipientRoot(_ pairing: DiagnosticsBrokerPairing) -> URL {
        root.appendingPathComponent(pairing.certificateSHA256, isDirectory: true)
    }

    @discardableResult
    func enqueueExport(acquisitionID: UUID?) -> Bool {
        guard isPaired, exportTask == nil, let recorder, let pairing, pairing.valid() else { return false }
        let root = recipientRoot(pairing)
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exportTask = nil }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
                let marker = root.appendingPathComponent("last-acquisition.txt")
                if let acquisitionID,
                   (try? String(contentsOf: marker, encoding: .utf8)) == acquisitionID.uuidString { return }
                let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
                    .filter { $0.pathExtension == "zip" }
                let bytes = existing.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                guard existing.count < 8, bytes < 400 * 1024 * 1024 else {
                    status = "Mac handoff outbox is full. Retained evidence was not deleted."
                    return
                }
                let prepared = try await DiagnosticsCollectionCoordinator.shared.exportForCodex(recorder: recorder)
                defer { try? FileManager.default.removeItem(at: prepared) }
                let preparedBytes = try prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard DiagnosticsOutboxAdmission.allows(existingCount: existing.count,
                        existingBytes: bytes, additionalBytes: preparedBytes) else {
                    status = "Mac handoff would exceed the outbox budget. Source evidence was retained."
                    return
                }
                let destination = root.appendingPathComponent(UUID().uuidString.lowercased() + ".zip")
                try FileManager.default.moveItem(at: prepared, to: destination)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var excludedRoot = root; try excludedRoot.setResourceValues(values)
                if let acquisitionID { try Data(acquisitionID.uuidString.utf8).write(to: marker, options: .atomic) }
                status = "Verified-evidence handoff queued for the paired Mac."
            } catch {
                status = "Handoff could not be prepared. Source logs were left unchanged."
            }
        }
        return true
    }

    private func uploadPending(_ pairing: DiagnosticsBrokerPairing, generation: UInt64) async throws {
        let root = recipientRoot(pairing)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 8 else { throw DiagnosticsAcquisitionStore.Failure.storageFull }
        for file in files.prefix(1) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw DiagnosticsAcquisitionStore.Failure.invalidManifest
            }
            guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes > 0, bytes <= 104 * 1024 * 1024 else {
                throw DiagnosticsAcquisitionStore.Failure.invalidManifest
            }
            let hash = try await Task.detached(priority: .utility) {
                SHA256.hash(data: try Data(contentsOf: file, options: [.mappedIfSafe]))
                    .map { String(format: "%02x", $0) }.joined()
            }.value
            try checkOwner(pairing, generation: generation)
            let response = try await DiagnosticsBrokerHTTP.request(pairing, method: "PUT",
                path: "v2/uploads/\(id.uuidString.lowercased())", file: file, digest: hash)
            try checkOwner(pairing, generation: generation)
            struct Receipt: Decodable { let schema: Int; let id: UUID; let sha256: String; let accepted: Bool }
            let receipt = try JSONDecoder().decode(Receipt.self, from: response)
            guard receipt.schema == 2, receipt.id == id, receipt.sha256 == hash, receipt.accepted else {
                throw DiagnosticsAcquisitionStore.Failure.invalidManifest
            }
            try FileManager.default.removeItem(at: file)
        }
    }
}
