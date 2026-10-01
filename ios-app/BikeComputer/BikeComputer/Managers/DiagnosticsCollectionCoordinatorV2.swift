import Combine
import CryptoKit
import Foundation

nonisolated struct DiagnosticsCollectionJobV2: Codable, Equatable, Sendable {
    let schema: Int
    let id: UUID
    let captureID: UUID?
    let deviceDigest: String
    let createdAt: Date
    var state: String
    var updatedAt: Date
    var failureCode: String?
}

/// Application-owned: navigation away from Settings never cancels a job.
/// Interruption is resumable; no promise of unlimited iOS background execution.
@MainActor
final class DiagnosticsCollectionCoordinatorV2: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var isCollecting = false
    @Published private(set) var latestBundle: URL?
    @Published private(set) var job: DiagnosticsCollectionJobV2?
    @Published private(set) var captureReceipt: DeviceDiagnosticsStatusV2?
    @Published private(set) var incidentStatus = ""
    private let recorder: RideDiagnosticsRecorder
    private let bleManager: BLEManager
    private var task: Task<URL, Error>?
    private var cancellables = Set<AnyCancellable>()
    private var applicationActive = true
    private var rideActive = false

    init(recorder: RideDiagnosticsRecorder, bleManager: BLEManager) {
        self.recorder = recorder; self.bleManager = bleManager
        let url = recorder.controlRootURL.appendingPathComponent("collection-job.json")
        if let count = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           count <= 16 * 1024, let data = try? Data(contentsOf: url),
           var saved = try? JSONDecoder().decode(DiagnosticsCollectionJobV2.self, from: data),
           saved.schema == 2, DiagnosticsAcquisitionV2.validDigest(saved.deviceDigest) {
            if saved.state == "collecting" { saved.state = "interrupted"; saved.failureCode = "process_restarted" }
            job = saved
            status = saved.state == "delivered" ? "Previous collection delivered" : "Collection retained; resume when connected"
        }
        bleManager.$isNavigationReady.removeDuplicates().sink { [weak self] ready in
            if ready { Task { @MainActor [weak self] in self?.resumeIfPossible() } }
        }.store(in: &cancellables)
    }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        if active { resumeIfPossible() }
    }
    func setRideActive(_ active: Bool) {
        rideActive = active
        if active && isCollecting { task?.cancel(); status = "Collection deferred while riding" }
        if !active { resumeIfPossible() }
    }
    func cancel() { task?.cancel() }

    func start(captureID: UUID? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await collect(captureID: captureID) }
            catch { /* run() publishes its bounded failure state. */ }
        }
    }

    func completedBundle(for id: UUID) -> URL? {
        guard job?.id == id, job?.state == "delivered" else { return nil }
        let url = recorder.controlRootURL.appendingPathComponent("handoff")
            .appendingPathComponent("bicino-\(id.uuidString.lowercased()).zip")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func collect(captureID: UUID? = nil, collectionID: UUID? = nil) async throws -> URL {
        if let collectionID, let existing = completedBundle(for: collectionID), job?.captureID == captureID { return existing }
        if let task {
            guard job?.captureID == captureID, collectionID == nil || job?.id == collectionID else { throw DiagnosticsPolicyError.invalidPolicy }
            return try await task.value
        }
        guard !rideActive, bleManager.isNavigationReady, let deviceID = bleManager.connectedDeviceID else {
            status = "Connect the expected Bicino and finish the ride before collecting"
            throw DiagnosticsPolicyError.deviceChanged
        }
        let digest = recorder.deviceDigest(for: deviceID)
        let selected: DiagnosticsCollectionJobV2
        if let retained = job, retained.state != "delivered", retained.captureID == captureID,
           collectionID == nil || retained.id == collectionID {
            guard retained.deviceDigest == digest else { throw DiagnosticsAcquisitionError.wrongDevice }
            selected = retained
        } else {
            selected = DiagnosticsCollectionJobV2(schema: 2, id: collectionID ?? UUID(), captureID: captureID,
                deviceDigest: digest, createdAt: Date(), state: "collecting", updatedAt: Date())
        }
        var current = selected; current.state = "collecting"; current.failureCode = nil; current.updatedAt = Date()
        try persist(current); job = current; isCollecting = true
        let work = Task { @MainActor [self] () throws -> URL in
            do {
                _ = try await DeviceDiagnosticsTransferManager().downloadDeviceLogs(
                    bleManager: bleManager, recorder: recorder, status: { [weak self] in self?.status = $0 },
                    collectionID: selected.id, captureID: selected.captureID)
                status = "Preparing verified handoff bundle"
                let v1 = try await recorder.exportBundleAsync()
                let acquisitionURL = recorder.controlRootURL.appendingPathComponent("acquisitions")
                    .appendingPathComponent(selected.id.uuidString.lowercased() + ".json")
                let output = recorder.controlRootURL.appendingPathComponent("handoff", isDirectory: true)
                let policy = recorder.currentPolicyV2
                let counters = recorder.policyCountersV2
                let result = try await Task.detached(priority: .utility) {
                    try Self.makeHandoff(v1: v1, acquisitionURL: acquisitionURL, output: output,
                                         id: selected.id, policy: policy, policyCounters: counters)
                }.value
                var finished = selected; finished.state = "delivered"; finished.updatedAt = Date()
                try persist(finished); job = finished; latestBundle = result
                status = "Bundle ready. Delivery and recording coverage are reported separately."
                isCollecting = false; task = nil
                return result
            } catch {
                var interrupted = selected; interrupted.state = "interrupted"; interrupted.updatedAt = Date()
                interrupted.failureCode = error is CancellationError ? "cancelled" : "collection_failed"
                try? persist(interrupted); job = interrupted
                status = error is CancellationError ? "Collection paused; verified progress retained" : "Collection interrupted; retry preserves verified progress"
                isCollecting = false; task = nil
                throw error
            }
        }
        task = work
        return try await work.value
    }

    func startCapture(profile: String, durationSeconds: UInt32,
                      captureID: UUID = UUID(), generation: UInt32 = 1,
                      levels: [String: String]? = nil, createdAt: Date = Date()) async throws -> DeviceDiagnosticsStatusV2 {
        let policy = try DiagnosticsCapturePolicyV2(captureID: captureID, generation: generation,
            profile: profile, durationSeconds: durationSeconds, levels: levels, now: createdAt)
        try recorder.applyCapturePolicyV2(policy)
        captureReceipt = nil
        status = "iPhone recording; waiting for Bicino policy acknowledgement"
        let receipt = try await bleManager.applyDiagnosticsPolicyV2(policy)
        captureReceipt = receipt
        status = "Both sources acknowledged capture; firmware persistence is \(receipt.policyPersisted ? "confirmed" : "pending")"
        return receipt
    }

    func mark(_ code: RideIssueCode) -> UUID? {
        let id = UUID()
        guard recorder.markIncidentV2(code, incidentID: id) else {
            incidentStatus = "iPhone marker could not be persisted"; return nil
        }
        if let sequence = bleManager.sendDiagnosticsIncidentV2(code, incidentID: id) {
            incidentStatus = "iPhone saved; Bicino marker \(sequence) queued, persistence not yet acknowledged"
        } else if bleManager.sendDiagnosticsIssueMarker(code) {
            incidentStatus = "iPhone saved; legacy Bicino marker queued without a shared incident ID"
        } else {
            incidentStatus = "iPhone saved; Bicino unavailable"
        }
        return id
    }

    private func resumeIfPossible() {
        guard applicationActive, !rideActive, task == nil, let job,
              job.state != "delivered", job.failureCode != "cancelled",
              bleManager.isNavigationReady, let id = bleManager.connectedDeviceID,
              recorder.deviceDigest(for: id) == job.deviceDigest else { return }
        start(captureID: job.captureID)
    }
    private func persist(_ value: DiagnosticsCollectionJobV2) throws {
        try FileManager.default.createDirectory(at: recorder.controlRootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        let url = recorder.controlRootURL.appendingPathComponent("collection-job.json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated private static func makeHandoff(v1: URL, acquisitionURL: URL, output: URL,
        id: UUID, policy: DiagnosticsCapturePolicyV2?, policyCounters: [String: Int]) throws -> URL {
        let acquisition = try Data(contentsOf: acquisitionURL)
        let receipt = try JSONDecoder().decode(DiagnosticsAcquisitionV2.self, from: acquisition)
        guard receipt.valid, receipt.deliveryComplete else { throw DiagnosticsAcquisitionError.invalidManifest }
        let oldSize = try v1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard oldSize > 0, oldSize <= 100 * 1024 * 1024 else { throw DiagnosticsAcquisitionError.capacityExceeded }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var entries: [(String, Data)] = [
            ("evidence/v1.zip", try Data(contentsOf: v1, options: [.mappedIfSafe])),
            ("acquisition.json", acquisition),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let policy { entries.append(("capture-policy.json", try encoder.encode(policy))) }
        let coverage: [String: Any] = [
            "schema": 2, "deliveryState": "complete_for_inventory", "recordingCoverage": "requires_analysis",
            "policyCounters": policyCounters, "firmwareDrops": receipt.index.stats.dropped,
            "firmwareStorageErrors": receipt.index.stats.storageErrors,
            "capabilityReceiptAvailable": receipt.capabilities != nil,
            "note": "Transfer completion is not proof that every relevant provider or interval was recorded.",
        ]
        entries.append(("coverage.json", try JSONSerialization.data(withJSONObject: coverage, options: [.sortedKeys])))
        let manifest: [String: Any] = ["schema": 2, "kind": "bicino-diagnostics-handoff", "id": id.uuidString.lowercased(),
            "eventWireSchema": 1, "contractSHA256": DiagnosticsContractV2.sha256,
            "members": entries.map(\.0), "privacy": "sanitized-local-only"]
        entries.append(("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])))
        let sums = entries.map { name, data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "  " + name + "\n"
        }.joined()
        entries.append(("checksums.sha256", Data(sums.utf8)))
        let destination = output.appendingPathComponent("bicino-\(id.uuidString.lowercased()).zip")
        let temporary = output.appendingPathComponent(".\(id.uuidString.lowercased()).tmp")
        try RideDiagnosticsStoredZipWriter.write(entries: entries, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try? FileManager.default.removeItem(at: v1)
        return destination
    }
}
