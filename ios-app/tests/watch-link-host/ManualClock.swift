import Foundation

/// Controllable time and cancellation; never sleeps in wall-clock time.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Duration = .zero
    private var sleepers: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []

    var pending: Int { lock.withLock { sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let wasCancelled = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    sleepers[id] = (now + duration, continuation)
                    return false
                }
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                if let (_, continuation) = self.sleepers.removeValue(forKey: id) { return continuation }
                self.cancelled.insert(id)
                return nil as CheckedContinuation<Void, Error>?
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = lock.withLock {
            now += duration
            let ids = sleepers.keys.filter { sleepers[$0]!.0 <= now }
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.1 }
        }
        for continuation in ready { continuation.resume() }
    }

    func cancelAll() {
        let pending = lock.withLock {
            let result = sleepers.values.map(\.1)
            sleepers.removeAll()
            return result
        }
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}
