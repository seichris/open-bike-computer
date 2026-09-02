import Foundation

enum NavigationWriteClass: String, CaseIterable, Equatable {
    case navigationSnapshot = "navigation"
    case gpsPosition = "gps"
    case route
    case settingsControl = "settings"
    case transfer
    case workoutTelemetry = "workout"
    case other
}

struct NavigationWriteQueueMetrics: Equatable {
    static let schemaVersion = 2

    var enqueuedFrames = 0
    var flushedFrames = 0
    var droppedFrames = 0
    var rejectedFrames = 0
    var coalescedFrames = 0
    var clearedFrames = 0
    var retrySchedules = 0
    var backpressureStops = 0
    var currentDepth = 0
    var maxDepth = 0
    var oldestPendingAgeMs = 0
    var retryAgeMs = 0
    var droppedFramesByClass: [NavigationWriteClass: Int] = [:]
    var coalescedFramesByClass: [NavigationWriteClass: Int] = [:]

    func droppedFrames(for writeClass: NavigationWriteClass) -> Int {
        droppedFramesByClass[writeClass, default: 0]
    }

    func coalescedFrames(for writeClass: NavigationWriteClass) -> Int {
        coalescedFramesByClass[writeClass, default: 0]
    }
}

nonisolated struct RendererBenchmarkBLETransportEvidence: Codable,
                                                              Equatable,
                                                              Sendable {
    let schema: Int
    let capturedAtUptimeMs: UInt64
    let queueDepth: Int
    let queueMaximumDepth: Int
    let oldestPendingAgeMs: Int
    let retryAgeMs: Int
    let enqueuedFrames: Int
    let flushedFrames: Int
    let droppedFrames: Int
    let rejectedFrames: Int
    let coalescedFrames: Int
    let retrySchedules: Int
    let backpressureStops: Int
    let gpsCoalescedFrames: Int
    let routeCoalescedFrames: Int
    let settingsCoalescedFrames: Int
    let inFlightClass: String?
    let inFlightAgeMs: Int
    let acknowledgementCompletions: UInt64
    let acknowledgementErrors: UInt64
    let acknowledgementTimeouts: UInt64
    let lastAcknowledgementMs: Int
    let maximumAcknowledgementMs: Int
}

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?
    let onWriteFailure: (() -> Void)?
    let transportCanSend: (() -> Bool)?
    let transportExpectsWriteResponse: Bool?
    let writeClass: NavigationWriteClass
    fileprivate let coalescingKey: String?
    fileprivate let protectedFromEviction: Bool
    fileprivate let enqueuedAtUptime: TimeInterval?

    init(
        data: Data,
        label: String,
        transportWrite: ((Data) -> Void)? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        onWriteFailure: (() -> Void)? = nil,
        transportCanSend: (() -> Bool)? = nil,
        transportExpectsWriteResponse: Bool? = nil,
        writeClass: NavigationWriteClass = .other,
        coalescingKey: String? = nil,
        protectedFromEviction: Bool = false,
        enqueuedAtUptime: TimeInterval? = nil
    ) {
        self.data = data
        self.label = label
        self.transportWrite = transportWrite
        self.onWrite = onWrite
        self.onDrop = onDrop
        self.onWriteFailure = onWriteFailure
        self.transportCanSend = transportCanSend
        self.transportExpectsWriteResponse = transportExpectsWriteResponse
        self.writeClass = writeClass
        self.coalescingKey = coalescingKey
        self.protectedFromEviction = protectedFromEviction
        self.enqueuedAtUptime = enqueuedAtUptime
    }

    func perform(using fallbackWrite: (Data) -> Void) {
        if let transportWrite {
            transportWrite(data)
        } else {
            fallbackWrite(data)
        }
        onWrite?()
    }

    fileprivate func protectingAtomicBatch() -> NavigationWrite {
        NavigationWrite(
            data: data,
            label: label,
            transportWrite: transportWrite,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure,
            transportCanSend: transportCanSend,
            transportExpectsWriteResponse: transportExpectsWriteResponse,
            writeClass: writeClass,
            coalescingKey: coalescingKey,
            protectedFromEviction: true,
            enqueuedAtUptime: enqueuedAtUptime
        )
    }

    fileprivate func enqueued(at uptime: TimeInterval) -> NavigationWrite {
        NavigationWrite(
            data: data,
            label: label,
            transportWrite: transportWrite,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure,
            transportCanSend: transportCanSend,
            transportExpectsWriteResponse: transportExpectsWriteResponse,
            writeClass: writeClass,
            coalescingKey: coalescingKey,
            protectedFromEviction: protectedFromEviction,
            enqueuedAtUptime: uptime
        )
    }
}

struct NavigationWriteQueue {
    let maxCount: Int
    let priorityMaxCount: Int
    private var pendingWrites: [NavigationWrite] = []
    private var pendingPriorityWrites: [NavigationWrite] = []
    private var diagnosticMetrics = NavigationWriteQueueMetrics()
    private var cumulativeDiagnosticMetrics = NavigationWriteQueueMetrics()
    private var retryStartedAtUptime: TimeInterval?
    private let now: () -> TimeInterval

    var count: Int {
        pendingPriorityWrites.count + pendingWrites.count
    }

    var remainingCapacity: Int {
        max(maxCount - pendingWrites.count, 0)
    }

    var metrics: NavigationWriteQueueMetrics {
        metricsSnapshot(from: diagnosticMetrics)
    }

    var cumulativeMetrics: NavigationWriteQueueMetrics {
        metricsSnapshot(from: cumulativeDiagnosticMetrics)
    }

    private func metricsSnapshot(
        from source: NavigationWriteQueueMetrics
    ) -> NavigationWriteQueueMetrics {
        var snapshot = source
        snapshot.currentDepth = count
        let currentUptime = now()
        let oldestEnqueueUptime = (pendingPriorityWrites + pendingWrites)
            .compactMap(\.enqueuedAtUptime)
            .min()
        snapshot.oldestPendingAgeMs = ageMilliseconds(
            since: oldestEnqueueUptime,
            at: currentUptime
        )
        snapshot.retryAgeMs = ageMilliseconds(
            since: retryStartedAtUptime,
            at: currentUptime
        )
        return snapshot
    }

    mutating func snapshotMetricsAndReset() -> NavigationWriteQueueMetrics {
        let snapshot = metrics
#if DEBUG || HOST_TESTING
        diagnosticMetrics = NavigationWriteQueueMetrics()
        diagnosticMetrics.currentDepth = count
        diagnosticMetrics.maxDepth = count
#endif
        return snapshot
    }

    init(
        maxCount: Int,
        priorityMaxCount: Int = 1,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.maxCount = max(1, maxCount)
        self.priorityMaxCount = max(1, priorityMaxCount)
        self.now = now
    }

    @discardableResult
    mutating func enqueue(_ write: NavigationWrite) -> Bool {
        beginEnqueueIfEmpty()
        pendingWrites.append(write.enqueued(at: now()))
        recordEnqueuedFrames(1)
        guard pendingWrites.count > maxCount else {
            recordDepth()
            return false
        }

        // Never split a logical message that was accepted atomically. If the
        // queue consists only of protected chunks, the newly appended regular
        // write is the eviction candidate.
        let droppedIndex = pendingWrites.firstIndex { !$0.protectedFromEviction }
            ?? pendingWrites.startIndex
        let droppedWrite = pendingWrites.remove(at: droppedIndex)
        droppedWrite.onDrop?()
        recordDropped(write: droppedWrite)
        recordDepth()
        return true
    }

    /// Enqueues a logical multi-frame message without evicting older traffic
    /// or exposing only a prefix of the message to the transport.
    @discardableResult
    mutating func enqueueAtomically(_ writes: [NavigationWrite]) -> Bool {
        guard writes.count <= remainingCapacity else {
            recordRejectedFrames(writes.count)
            return false
        }
        beginEnqueueIfEmpty()
        let enqueuedAt = now()
        pendingWrites.append(contentsOf: writes.map {
            $0.enqueued(at: enqueuedAt).protectingAtomicBatch()
        })
        recordEnqueuedFrames(writes.count)
        recordDepth()
        return true
    }

    /// Inserts a small control response into a separate bounded lane ahead of
    /// bulk traffic. A newer complete response replaces the older priority
    /// message, without consuming or evicting regular/catalog capacity.
    @discardableResult
    mutating func enqueuePrioritizedAtomically(_ writes: [NavigationWrite]) -> Bool {
        guard !writes.isEmpty, writes.count <= priorityMaxCount else {
            recordRejectedFrames(writes.count)
            return false
        }

        let replacementKeys = Set(writes.compactMap(\.coalescingKey))
        if !replacementKeys.isEmpty {
            let replacementIndices = pendingPriorityWrites.indices.reversed().filter {
                guard let key = pendingPriorityWrites[$0].coalescingKey else {
                    return false
                }
                return replacementKeys.contains(key)
            }
            let retainedCount = pendingPriorityWrites.count - replacementIndices.count
            guard retainedCount + writes.count <= priorityMaxCount else {
                recordRejectedFrames(writes.count)
                return false
            }
            for index in replacementIndices {
                let removed = pendingPriorityWrites.remove(at: index)
                recordCoalesced(write: removed)
                removed.onDrop?()
            }
        }

        if pendingPriorityWrites.count + writes.count > priorityMaxCount {
            recordRejectedFrames(writes.count)
            return false
        }
        beginEnqueueIfEmpty()
        let enqueuedAt = now()
        pendingPriorityWrites.append(contentsOf: writes.map {
            $0.enqueued(at: enqueuedAt).protectingAtomicBatch()
        })
        recordEnqueuedFrames(writes.count)
        recordDepth()
        return true
    }

    /// Replaces older pending writes for the same logical state without
    /// disturbing unrelated priority traffic. This keeps high-rate state
    /// relays from replaying obsolete values after a newer state transition.
    @discardableResult
    mutating func enqueueCoalescing(
        _ write: NavigationWrite,
        prioritized: Bool
    ) -> Bool {
        guard let key = write.coalescingKey, !key.isEmpty else {
            if prioritized {
                return enqueuePrioritizedAtomically([write])
            }
            _ = enqueue(write)
            return true
        }

        removePendingWrites(
            withCoalescingKey: key,
            resetRetryWhenEmpty: false
        )
        if prioritized {
            guard pendingPriorityWrites.count < priorityMaxCount else {
                recordRejectedFrames(1)
                return false
            }
            pendingPriorityWrites.append(
                write.enqueued(at: now()).protectingAtomicBatch()
            )
            recordEnqueuedFrames(1)
            recordDepth()
            return true
        }

        pendingWrites.append(write.enqueued(at: now()))
        guard pendingWrites.count > maxCount else {
            recordEnqueuedFrames(1)
            recordDepth()
            return true
        }
        let droppedIndex = pendingWrites.firstIndex { !$0.protectedFromEviction }
            ?? pendingWrites.startIndex
        let rejectedNewWrite = droppedIndex == pendingWrites.index(before: pendingWrites.endIndex)
        let droppedWrite = pendingWrites.remove(at: droppedIndex)
        if rejectedNewWrite {
            // The caller receives `false` and owns retry scheduling. Invoking
            // onDrop here would schedule a second immediate retry and can spin
            // while a protected atomic batch keeps the queue full.
            recordRejectedFrames(1)
            recordDepth()
            return false
        }
        droppedWrite.onDrop?()
        recordEnqueuedFrames(1)
        recordDropped(write: droppedWrite)
        recordDepth()
        return true
    }

    mutating func removeAll() {
        recordClearedFrames(count)
        pendingPriorityWrites.removeAll()
        pendingWrites.removeAll()
        retryStartedAtUptime = nil
        recordDepth()
    }

    mutating func removePendingWrites(withCoalescingKey key: String) {
        removePendingWrites(
            withCoalescingKey: key,
            resetRetryWhenEmpty: true
        )
    }

    private mutating func removePendingWrites(
        withCoalescingKey key: String,
        resetRetryWhenEmpty: Bool
    ) {
        let priorityMatches = pendingPriorityWrites.indices.reversed().filter {
            pendingPriorityWrites[$0].coalescingKey == key
        }
        for index in priorityMatches {
            let removed = pendingPriorityWrites.remove(at: index)
            recordCoalesced(write: removed)
            removed.onDrop?()
        }

        let regularMatches = pendingWrites.indices.reversed().filter {
            pendingWrites[$0].coalescingKey == key
        }
        for index in regularMatches {
            let removed = pendingWrites.remove(at: index)
            recordCoalesced(write: removed)
            removed.onDrop?()
        }
        if resetRetryWhenEmpty, count == 0 {
            retryStartedAtUptime = nil
        }
        recordDepth()
    }

    mutating func flush(
        canSend: () -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        flush(
            canSend: { _ in canSend() },
            maxWrites: maxWrites,
            write: write
        )
    }

    mutating func flush(
        canSend: (NavigationWrite) -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        var writesRemaining = max(0, maxWrites)
        while writesRemaining > 0 && count > 0 {
            let nextWrite = pendingPriorityWrites.first ?? pendingWrites.first!
            guard canSend(nextWrite) else {
                recordBackpressureStop()
                break
            }
            let dequeued = pendingPriorityWrites.isEmpty
                ? pendingWrites.removeFirst()
                : pendingPriorityWrites.removeFirst()
            recordFlushedFrames(1)
            recordDepth()
            write(dequeued)
            writesRemaining -= 1
        }
        if count == 0 {
            retryStartedAtUptime = nil
        }
    }

    mutating func noteRetryScheduled() {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.retrySchedules += 1
        cumulativeDiagnosticMetrics.retrySchedules += 1
        if retryStartedAtUptime == nil, count > 0 {
            retryStartedAtUptime = now()
        }
#endif
    }

    private mutating func recordEnqueuedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.enqueuedFrames += count
        cumulativeDiagnosticMetrics.enqueuedFrames += count
#endif
    }

    private mutating func recordFlushedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.flushedFrames += count
        cumulativeDiagnosticMetrics.flushedFrames += count
#endif
    }

    private mutating func recordDropped(write: NavigationWrite) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.droppedFrames += 1
        diagnosticMetrics.droppedFramesByClass[write.writeClass, default: 0] += 1
        cumulativeDiagnosticMetrics.droppedFrames += 1
        cumulativeDiagnosticMetrics.droppedFramesByClass[
            write.writeClass,
            default: 0
        ] += 1
#endif
    }

    private mutating func recordRejectedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.rejectedFrames += count
        cumulativeDiagnosticMetrics.rejectedFrames += count
#endif
    }

    private mutating func recordCoalesced(write: NavigationWrite) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.coalescedFrames += 1
        diagnosticMetrics.coalescedFramesByClass[write.writeClass, default: 0] += 1
        cumulativeDiagnosticMetrics.coalescedFrames += 1
        cumulativeDiagnosticMetrics.coalescedFramesByClass[
            write.writeClass,
            default: 0
        ] += 1
#endif
    }

    private mutating func recordClearedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.clearedFrames += count
        cumulativeDiagnosticMetrics.clearedFrames += count
#endif
    }

    private mutating func recordBackpressureStop() {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.backpressureStops += 1
        cumulativeDiagnosticMetrics.backpressureStops += 1
#endif
    }

    private mutating func recordDepth() {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.currentDepth = count
        diagnosticMetrics.maxDepth = max(diagnosticMetrics.maxDepth, count)
        cumulativeDiagnosticMetrics.currentDepth = count
        cumulativeDiagnosticMetrics.maxDepth = max(
            cumulativeDiagnosticMetrics.maxDepth,
            count
        )
#endif
    }

    private mutating func beginEnqueueIfEmpty() {
        if count == 0 {
            retryStartedAtUptime = nil
        }
    }

    private func ageMilliseconds(
        since startUptime: TimeInterval?,
        at currentUptime: TimeInterval
    ) -> Int {
        guard let startUptime else { return 0 }
        return Int(max(0, (currentUptime - startUptime) * 1_000).rounded())
    }
}
