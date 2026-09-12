import Foundation

/// Owns the bounded publication lifecycle, not WCSession. The existing Watch
/// connectivity coordinator supplies the activated session and merged write.
@MainActor
final class WatchCyclingSensorObservationPublisher {
    private let isActivated: () -> Bool
    private let publish: (WatchCyclingSensorObservationV1) -> Bool
    private let now: () -> Date
    private var publication = WatchCyclingSensorPublicationV1()
    private var pendingTask: Task<Void, Never>?
    private var retryNotBefore: Date?
    private var retryDelay: TimeInterval = 2

    init(
        isActivated: @escaping () -> Bool,
        publish: @escaping (WatchCyclingSensorObservationV1) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.isActivated = isActivated
        self.publish = publish
        self.now = now
    }

    deinit {
        pendingTask?.cancel()
    }

    func offer(_ observation: WatchCyclingSensorObservationV1) {
        publication.offer(observation)
        flush()
    }

    /// Also called after activation/foregrounding. Context delivery does not
    /// require reachability; a failed write keeps the latest pending value.
    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard isActivated(), let latest = publication.latest,
            let publicationDelay = publication.publicationDelay(at: now())
        else { return }
        let date = now()
        let delay = max(
            publicationDelay,
            retryNotBefore?.timeIntervalSince(date) ?? 0
        )
        if delay > 0 {
            schedule(after: delay)
            return
        }
        if publish(latest) {
            publication.didPublish(at: date)
            retryNotBefore = nil
            retryDelay = 2
        } else {
            // New samples cannot defeat the retry deadline or create an
            // unbounded queue. Persistent transport errors back off to 30s.
            retryNotBefore = date.addingTimeInterval(retryDelay)
            schedule(after: retryDelay)
            retryDelay = min(30, retryDelay * 2)
        }
    }

    private func schedule(after delay: TimeInterval) {
        let nanoseconds = UInt64(min(max(0, delay), 30) * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
