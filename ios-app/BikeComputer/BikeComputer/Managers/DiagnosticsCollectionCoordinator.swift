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
    private weak var recorder: RideDiagnosticsRecorder?
    private weak var bleManager: BLEManager?
    private var task: Task<Void, Never>?
    private var canCollect: () -> Bool = { false }
    private var automaticRetryAllowed = true
    private var restoreFinished = false
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
        guard !restoreFinished else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                manifest = try await store.manifests().last(where: {
                    $0.phase != .complete && $0.phase != .cancelled
                })
                if manifest != nil { status = "Interrupted collection retained; waiting for the original device." }
                restoreFinished = true
                resumeIfPossible()
            } catch {
                status = "The collection journal cannot be read. Existing evidence was left unchanged."
                automaticRetryAllowed = false
                restoreFinished = true
            }
        }
    }

    var allowsNonRidingDiagnostics: Bool { canCollect() }

    func resumeIfPossible() {
        guard restoreFinished, automaticRetryAllowed, manifest != nil else { return }
        start(newCutoff: false, automatic: true)
    }

    func start(newCutoff: Bool = false, automatic: Bool = false) {
        guard !isRunning, let recorder, let bleManager else { return }
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
        isRunning = true
        automaticRetryAllowed = !automatic // one retry per foreground/reconnect; no network retry storm
        task = Task { [weak self] in
            guard let self else { return }
            defer { isRunning = false; task = nil }
            do {
                if manifest == nil || manifest?.deliveryComplete == true || newCutoff {
                    manifest = try await store.create(deviceDigest: digest, captureID: recorder.currentCaptureID)
                }
                guard let id = manifest?.id else { return }
                _ = try await DeviceDiagnosticsTransferManager().downloadDeviceLogs(
                    bleManager: bleManager, recorder: recorder,
                    acquisitionStore: store, acquisitionID: id,
                    status: { [weak self] in self?.status = $0 })
                manifest = try await store.load(id)
                status = "Device evidence verified for the saved cutoff. Export the support bundle for Codex."
            } catch {
                if let id = manifest?.id {
                    do {
                        try await store.interrupt(id, cancelled: Task.isCancelled,
                            code: Task.isCancelled ? "cancelled" : "transfer_failed")
                        manifest = try await store.load(id)
                    } catch {
                        status = "Collection journal write failed; completeness is unknown."
                        automaticRetryAllowed = false
                        return
                    }
                }
                status = manifest?.deliveryComplete == true
                    ? "Evidence was verified, but transfer cleanup needs attention. Reconnect before another operation."
                    : "Partial evidence retained. Resume with the original device: \(error.localizedDescription)"
                // Retry is deliberate after an error; do not repeatedly switch Wi-Fi.
                automaticRetryAllowed = false
            }
        }
    }

    /// One portable handoff wraps the byte-for-byte v1 bundle and acquisition
    /// receipts. The v1 reader remains supported; the v2 CLI independently checks
    /// receipt claims against actual archive bytes before reporting completeness.
    func exportForCodex(recorder: RideDiagnosticsRecorder) async throws -> URL {
        let evidenceURL = try await recorder.exportBundleAsync()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let acquisitions = try await store.manifests()
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
        automaticRetryAllowed = false
        status = "Cancelling collection and releasing its transport…"
        task?.cancel()
    }
}
