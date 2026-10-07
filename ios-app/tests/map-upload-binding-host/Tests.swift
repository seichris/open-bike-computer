import Foundation

enum OfflineMapPlatformError: Error { case invalidResponse }
enum MapTransferDeviceClient {
    static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw OfflineMapPlatformError.invalidResponse
        }
    }
}
@MainActor enum DeviceTransferManager {
    static var released: [UUID] = []
    static func releaseNetworkClaim(_ claim: UUID) { released.append(claim) }
}
nonisolated final class DeviceMapOperationStore: @unchecked Sendable {
    enum StoreError: Error { case conflict }
    static let shared = DeviceMapOperationStore()
    func completeUpload(operationID: UUID, deviceID: String, appNamespace: String,
        mapID: String, sessionID: String, uploadAttemptID: UUID, responseBody: Data,
        httpStatus: Int?, errorCode: Int?) throws -> Bool { true }
}
final class ControlledUploadTask: URLSessionUploadTask, @unchecked Sendable {
    let identity: Int
    var cancellations = 0
    var starts = 0
    var onCancel: (() -> Void)?
    var taskState: URLSessionTask.State = .suspended
    var taskResponse: URLResponse?
    var sentBytes: Int64 = 0
    init(_ identity: Int) { self.identity = identity; super.init() }
    override var taskIdentifier: Int { identity }
    override var state: URLSessionTask.State { taskState }
    override var response: URLResponse? { taskResponse }
    override var countOfBytesSent: Int64 { sentBytes }
    override var countOfBytesExpectedToSend: Int64 { 100 }
    override func resume() { starts += 1; taskState = .running }
    override func cancel() { cancellations += 1; onCancel?() }
}

extension BackgroundMapUploadCoordinator {
    @MainActor static func runBindingRegressions() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<1500 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            preconditionFailure("upload did not settle after invalidating its BLE binding")
        }
        let key = "offlineMap.backgroundUploads.v1"
        let original = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let c = BackgroundMapUploadCoordinator()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func prepare(_ task: ControlledUploadTask, attempt: UUID? = UUID()) throws -> BackgroundMapUploadDescriptor {
            let descriptor = BackgroundMapUploadDescriptor(mapID: "map", sessionID: "session",
                protocolVersion: 2, streamFormatVersion: 1, artifactFilename: "map.bmap",
                deviceID: "original-device", uploadAttemptID: attempt, appNamespace: "test", connectionEpoch: 1)
            task.taskDescription = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
            BackgroundMapUploadStateStore.markStarted(taskID: task.identity, descriptor: descriptor, expectedBytes: 100)
            task.taskResponse = HTTPURLResponse(url: URL(string: "https://device.test/upload")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)
            task.onCancel = {
                Task { @MainActor in
                    task.taskState = .completed
                    c.urlSession(session, task: task,
                        didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                }
            }
            return descriptor
        }
        // This is the observed 82% case: OS transport never completes on its
        // own after a device reboot. The original BLE binding is invalidated.
        let a = ControlledUploadTask(1), da = try prepare(a)
        let claim = UUID()
        var bindingCurrent = true, completions = 0
        let call = Task { @MainActor in
            defer { completions += 1 }
            try await c.wait(for: a, descriptor: da, claim: claim, expectedBytes: 100,
                isBindingCurrent: { bindingCurrent }, progress: { _, _ in })
        }
        await settle { a.starts == 1 }
        a.sentBytes = 82
        BackgroundMapUploadStateStore.markProgress(taskID: 1, completedBytes: 82,
            descriptor: da, expectedBytes: 100)
        expect(a.cancellations == 0, "valid binding keeps the upload alive")
        bindingCurrent = false
        await settle { completions == 1 }
        do { try await call.value; preconditionFailure("lost binding reported success") }
        catch { expect((error as NSError).code == NSURLErrorCancelled, "transport cancellation reaches caller") }
        let record = BackgroundMapUploadStateStore.latest(mapID: "map", sessionID: "session")!
        expect(record.completedAt != nil && record.succeeded == false && record.percentage == 82,
            "cancellation persists transport failure without inventing device success")
        await settle { DeviceTransferManager.released.contains(claim) }
        expect(a.cancellations == 1 && c.pendingUploads.isEmpty, "waiter and upload claim complete once")

        // A stale monitor must not cancel another attempt for the same map,
        // including an OS task whose numeric identifier has been reused.
        let b = ControlledUploadTask(1), db = try prepare(b)
        c.completedTaskIDs.remove(1)
        var bCompleted = false
        let callB = Task { @MainActor in
            defer { bCompleted = true }
            try await c.wait(for: b, descriptor: db, claim: nil, expectedBytes: 100,
                isBindingCurrent: { true }, progress: { _, _ in })
        }
        await settle { b.starts == 1 }
        expect(!c.cancelForegroundUpload(b, descriptor: da) && b.cancellations == 0,
            "attempt identity rejects stale cancellation despite reused task ID")
        expect(!c.cancelForegroundUpload(a, descriptor: da) && b.cancellations == 0,
            "completed task cannot cancel its replacement")
        b.taskState = .completed
        c.urlSession(session, task: b, didCompleteWithError: nil)
        try await callB.value
        expect(bCompleted && b.cancellations == 0, "successful completion wins without cancellation")

        // No in-memory waiter means a restored OS upload has no authority to
        // bind itself to a new connection or to cancel another persisted job.
        let restored = ControlledUploadTask(3), dr = try prepare(restored)
        restored.taskState = .running
        expect(!c.cancelForegroundUpload(restored, descriptor: dr) && restored.cancellations == 0,
            "restored job requires separate durable reconciliation")

        // The binding may be invalid before waiter registration, or completion
        // may already have arrived. Neither ordering may strand a continuation.
        let early = ControlledUploadTask(4), de = try prepare(early)
        do {
            try await c.wait(for: early, descriptor: de, claim: nil, expectedBytes: 100,
                isBindingCurrent: { false }, progress: { _, _ in })
            preconditionFailure("early lost binding reported success")
        } catch { expect(early.cancellations == 1, "pre-registration invalidation cancels once") }
        let completed = ControlledUploadTask(5), dc = try prepare(completed)
        completed.taskState = .completed
        c.urlSession(session, task: completed, didCompleteWithError: NSError(domain: NSURLErrorDomain,
            code: NSURLErrorCancelled))
        let earlyClaim = UUID()
        do {
            try await c.wait(for: completed, descriptor: dc, claim: earlyClaim, expectedBytes: 100,
                isBindingCurrent: { false }, progress: { _, _ in })
            preconditionFailure("already completed task installed a waiter")
        } catch is CancellationError {} catch { preconditionFailure("wrong early completion error") }
        await settle { DeviceTransferManager.released.contains(earlyClaim) }
        expect(c.pendingUploads.isEmpty && completed.starts == 0, "early completion leaves no orphan waiter")
        print("PASS map upload BLE binding regressions (\(checks) checks)")
    }
}
@main struct UploadBindingTests {
    static func main() async throws { try await BackgroundMapUploadCoordinator.runBindingRegressions() }
}
