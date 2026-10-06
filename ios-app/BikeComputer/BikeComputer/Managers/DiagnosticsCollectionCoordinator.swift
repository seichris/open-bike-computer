import Combine
import CryptoKit
import Foundation

/// App-owned collection lifetime. Views observe this job; leaving Settings
/// cannot cancel or destroy its progress. Re-entry after suspension reuses the
/// exact persisted cutoff and revalidates cached bytes before declaring success.
@MainActor
final class DiagnosticsCollectionCoordinator: ObservableObject {
    static let shared = DiagnosticsCollectionCoordinator()
    @Published private(set) var isRunning = false
    @Published private(set) var status = "No collection requested."
    @Published private(set) var manifest: DiagnosticsAcquisitionManifest?
    @Published private(set) var automaticPostRideCollection = UserDefaults.standard.bool(forKey: "diagnostics.post-ride-collection.v2")
    private weak var recorder: RideDiagnosticsRecorder?
    private weak var bleManager: BLEManager?
    private var task: Task<Void, Never>?
    private var canCollect: () -> Bool = { false }
    private var automaticRetryAllowed = true
    private var userCancelled = false
    private var restoreFinished = false
    private var restoreStarted = false
    private var restoreFailed = false
    private var selectionTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var rideIsActive = false
    private struct RideContext {
        let requestID: UUID
        let captureID: UUID
        let deviceDigest: String
    }
    // Original authenticated identities, retained even after BLE disconnects.
    // A ride may span capture rotations or deliberately change bike computers.
    private var rideContexts: [String: RideContext] = [:]
    private var rideJournalTask: Task<Void, Never>?
    private var rideJournalGeneration: UInt64 = 0
    let store: DiagnosticsAcquisitionStore
    let root: URL

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BicinoDiagnosticsAcquisitions/v2", isDirectory: true)
        store = DiagnosticsAcquisitionStore(root: root)
    }

    func configure(recorder: RideDiagnosticsRecorder, bleManager: BLEManager,
                   canCollect: @escaping () -> Bool) {
        self.recorder = recorder
        self.bleManager = bleManager
        self.canCollect = canCollect
        guard !restoreStarted else { return }
        restoreStarted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                manifest = try await store.manifests().first(where: { $0.phase.canResumeAutomatically })
                if manifest?.failureCode == "cache_full" {
                    status = DiagnosticsAcquisitionFailureReporting.status(for: DiagnosticsAcquisitionStore.Failure.storageFull)
                } else if manifest != nil {
                    status = "Interrupted collection retained; waiting for the original device."
                }
                restoreFinished = true
                resumeIfPossible()
            } catch {
                status = "The collection journal cannot be read. Existing evidence was left unchanged."
                restoreFailed = true
                automaticRetryAllowed = false
                restoreFinished = true
            }
        }
    }

    var allowsNonRidingDiagnostics: Bool { canCollect() }

    func setAutomaticPostRideCollection(_ enabled: Bool) {
        automaticPostRideCollection = enabled
        UserDefaults.standard.set(enabled, forKey: "diagnostics.post-ride-collection.v2")
        if enabled {
            observeConnectedDeviceDuringRide()
            resumeIfPossible()
        }
    }

    func observeConnectedDeviceDuringRide() {
        if rideIsActive { observeRide(active: true) }
    }

    /// Called for ride transitions and authenticated reconnect/capture changes.
    /// Recording itself never depends on this opt-in delivery convenience.
    func observeRide(active: Bool) {
        if active {
            if !rideIsActive {
                operationGeneration &+= 1
                selectionTask?.cancel()
                if isRunning {
                    status = "Pausing collection for the ride; partial evidence will be retained."
                    task?.cancel()
                }
            }
            rideIsActive = true
            guard automaticPostRideCollection, let recorder, let bleManager,
                  bleManager.isNavigationReady, let device = bleManager.connectedDeviceID,
                  let capture = recorder.currentCaptureID else { return }
            let digest = recorder.deviceDigest(for: device)
            let key = digest + ":" + capture.uuidString
            guard rideContexts[key] == nil else { return }
            guard rideContexts.count < 8 else {
                status = "Post-ride queue reached its eight-context limit. Other logs remain available for manual collection."
                return
            }
            rideContexts[key] = RideContext(requestID: UUID(), captureID: capture, deviceDigest: digest)
            return
        }
        guard rideIsActive else { return }
        rideIsActive = false
        // A manual job paused by riding must resume even when automatic
        // post-ride capture is disabled and there are no new ride contexts.
        // The caller may be inside Published.willSet: defer the canCollect
        // reread until navigation/workout state has actually been committed.
        Task { [weak self] in self?.resumeIfPossible() }
        let contexts = Array(rideContexts.values).sorted { $0.requestID.uuidString < $1.requestID.uuidString }
        rideContexts.removeAll()
        guard !contexts.isEmpty else { return }
        let preceding = rideJournalTask
        rideJournalGeneration &+= 1
        let generation = rideJournalGeneration
        rideJournalTask = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            defer { if rideJournalGeneration == generation { rideJournalTask = nil } }
            var savedRequestID: UUID?
            do {
                for context in contexts {
                    savedRequestID = nil
                    _ = try await store.create(deviceDigest: context.deviceDigest,
                        captureID: context.captureID, id: context.requestID, origin: .postRide)
                    savedRequestID = context.requestID
                    if let recorder {
                        let chunks = try await recorder.appEvidenceSnapshot(captureID: context.captureID)
                        try await store.retainAppEvidence(context.requestID, chunks: chunks)
                    }
                }
                if !isRunning {
                    status = "Post-ride collection queued durably; waiting for the original device and a non-riding foreground session."
                }
                // Enqueuing new work is deliberate; failed attempts otherwise
                // remain stopped until a manual retry, not a Wi-Fi retry loop.
                automaticRetryAllowed = true
                if automaticPostRideCollection { resumeIfPossible() }
            } catch {
                let failure = error
                if let savedRequestID {
                    do {
                        try await store.interrupt(savedRequestID,
                            code: DiagnosticsAcquisitionFailureReporting.code(for: failure))
                    } catch {
                        status = "Collection journal write failed; completeness is unknown."
                        automaticRetryAllowed = false
                        return
                    }
                }
                recorder?.record(level: .warning, category: .transfer, event: "diagnostics_download_failed",
                    fields: DiagnosticsAcquisitionFailureReporting.fields(for: failure,
                        acquisitionID: savedRequestID, phase: savedRequestID == nil ? "request" : "app_evidence"))
                status = DiagnosticsAcquisitionFailureReporting.status(for: failure)
            }
        }
    }

    func resumeIfPossible() {
        guard restoreFinished, !restoreFailed, automaticRetryAllowed, !isRunning,
              selectionTask == nil, canCollect(), let recorder, let bleManager,
              bleManager.isNavigationReady, let deviceID = bleManager.connectedDeviceID else { return }
        let digest = recorder.deviceDigest(for: deviceID)
        let generation = operationGeneration
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { selectionTask = nil }
            do {
                let entries = try await store.manifests()
                guard generation == operationGeneration, !isRunning, canCollect(),
                      bleManager.connectedDeviceID == deviceID else { return }
                // A completed/cancelled job never opens a new inventory. Only
                // independently persisted pending work can become runnable.
                guard let pending = entries.first(where: {
                    $0.canResumeAutomatically(postRideEnabled: automaticPostRideCollection) && $0.deviceDigest == digest
                }) else { return }
                recorder.record(category: .transfer, event: "diagnostics_resume_selected", fields: [
                    "operationId": pending.id.uuidString.lowercased(),
                    "phase": pending.phase.rawValue,
                    "origin": pending.origin?.rawValue ?? "manual",
                    "reason": pending.failureCode ?? "pending",
                ])
                manifest = pending
                start(newCutoff: false, automatic: true)
            } catch {
                status = "The collection journal cannot be read. No automatic transfer started."
                automaticRetryAllowed = false
            }
        }
    }

    func start(newCutoff: Bool = false, automatic: Bool = false) {
        guard restoreFinished, !restoreFailed else {
            if !automatic { status = "Collection journal is not ready. Existing evidence was left unchanged." }
            return
        }
        guard !isRunning, let recorder, let bleManager else { return }
        if automatic, manifest?.canResumeAutomatically(postRideEnabled: automaticPostRideCollection) != true { return }
        guard canCollect(), bleManager.isNavigationReady, bleManager.supportsRideDiagnostics,
              let deviceID = bleManager.connectedDeviceID else {
            if !automatic { status = "Stop the ride and connect the original Bicino before collecting." }
            return
        }
        let digest = recorder.deviceDigest(for: deviceID)
        if let manifest, !manifest.deliveryComplete, !newCutoff,
           manifest.deviceDigest != digest {
            status = "Waiting for the device that owns this collection."
            return
        }
        operationGeneration &+= 1
        isRunning = true
        userCancelled = false
        automaticRetryAllowed = !automatic // one retry per foreground/reconnect; no network retry storm
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                isRunning = false
                task = nil
                // Riding may already have ended while transport cleanup was
                // draining. Advance only eligible persisted jobs; retry and
                // cancellation guards still prevent an error retry loop.
                resumeIfPossible()
            }
            var acquisitionID: UUID?
            var failurePhase = "request"
            do {
                if manifest == nil || manifest?.deliveryComplete == true || newCutoff {
                    manifest = try await store.create(deviceDigest: digest, captureID: recorder.currentCaptureID)
                }
                guard let id = manifest?.id else { return }
                acquisitionID = id
                failurePhase = "app_evidence"
                if manifest?.appEvidence == nil, let capture = manifest?.captureID {
                    let chunks = try await recorder.appEvidenceSnapshot(captureID: capture)
                    try await store.retainAppEvidence(id, chunks: chunks)
                    manifest = try await store.load(id)
                }
                try Task.checkCancellation()
                guard canCollect(), bleManager.connectedDeviceID == deviceID,
                      bleManager.isNavigationReady else {
                    throw RideDiagnosticsError.unavailable("Collection conditions changed while saving capture evidence.")
                }
                failurePhase = "device_download"
                _ = try await DeviceDiagnosticsTransferManager().downloadDeviceLogs(
                    bleManager: bleManager, recorder: recorder,
                    acquisitionStore: store, acquisitionID: id,
                    status: { [weak self] in self?.status = $0 })
                manifest = try await store.load(id)
                automaticRetryAllowed = true
                status = "Device evidence verified for the saved cutoff. Export the support bundle for Codex."
            } catch {
                let failure = error
                if failurePhase != "device_download" {
                    recorder.record(level: .warning, category: .transfer, event: "diagnostics_download_failed",
                        fields: DiagnosticsAcquisitionFailureReporting.fields(for: failure,
                            acquisitionID: acquisitionID, phase: failurePhase))
                }
                if let id = acquisitionID {
                    do {
                        try await store.interrupt(id, cancelled: Task.isCancelled && userCancelled,
                            code: Task.isCancelled ? (userCancelled ? "cancelled" : "ride_started")
                                : DiagnosticsAcquisitionFailureReporting.code(for: failure))
                        manifest = try await store.load(id)
                    } catch {
                        status = "Collection journal write failed; completeness is unknown."
                        automaticRetryAllowed = false
                        return
                    }
                }
                status = manifest?.deliveryComplete == true
                    && DiagnosticsAcquisitionFailureReporting.code(for: failure) != "cache_full"
                    ? "Evidence was verified, but transfer cleanup needs attention. Reconnect before another operation."
                    : DiagnosticsAcquisitionFailureReporting.status(for: failure)
                // A ride interruption is resumable when riding stops; an
                // explicit cancellation or transport error requires user retry.
                automaticRetryAllowed = Task.isCancelled && !userCancelled
            }
        }
    }

    /// One portable handoff wraps the byte-for-byte v1 bundle and acquisition
    /// receipts. The v1 reader remains supported; the v2 CLI independently checks
    /// receipt claims against actual archive bytes before reporting completeness.
    func exportForCodex(recorder: RideDiagnosticsRecorder) async throws -> URL {
        let snapshot = try await store.exportSnapshot()
        let evidenceURL = try await recorder.exportBundleAsync(additionalDeviceChunks: snapshot.chunks, additionalAppChunks: snapshot.appChunks)
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let acquisitions = snapshot.manifests
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("bicino-diagnostics-\(UUID().uuidString).zip")
        return try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: evidenceURL) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let evidence = try Data(contentsOf: evidenceURL, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
            let manifest: [String: Any] = [
                "schema": 2, "eventFormatSchema": 1, "registryDigest": DiagnosticsSchema.digest,
                "evidenceArchive": "evidence-v1.zip", "evidenceSha256": digest,
                "acquisitions": acquisitions.map { "acquisitions/\($0.id.uuidString.lowercased()).json" },
                "privacy": "diagnostic-no-raw-payloads",
            ]
            var entries: [(String, Data)] = [
                ("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])),
                ("evidence-v1.zip", evidence),
            ]
            for acquisition in acquisitions {
                entries.append(("acquisitions/\(acquisition.id.uuidString.lowercased()).json", try encoder.encode(acquisition)))
            }
            let checksums = entries.map { path, data in
                "\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())  \(path)\n"
            }.joined()
            entries.append(("checksums.sha256", Data(checksums.utf8)))
            do {
                try RideDiagnosticsStoredZipWriter.write(entries: entries, to: output)
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }.value
    }

    func cancel() {
        userCancelled = true
        operationGeneration &+= 1
        selectionTask?.cancel()
        automaticRetryAllowed = false
        status = "Cancelling collection and releasing its transport…"
        task?.cancel()
    }
}
