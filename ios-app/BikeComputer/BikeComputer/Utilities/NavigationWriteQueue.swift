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
    static let schemaVersion = 3

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
    var currentBytes = 0
    var maxBytes = 0
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

    /// Combine completed diagnostic intervals without changing live gauges.
    func accumulating(_ earlier: Self) -> Self {
        var result = self
        result.enqueuedFrames += earlier.enqueuedFrames
        result.flushedFrames += earlier.flushedFrames
        result.droppedFrames += earlier.droppedFrames
        result.rejectedFrames += earlier.rejectedFrames
        result.coalescedFrames += earlier.coalescedFrames
        result.clearedFrames += earlier.clearedFrames
        result.retrySchedules += earlier.retrySchedules
        result.backpressureStops += earlier.backpressureStops
        result.maxDepth = max(maxDepth, earlier.maxDepth)
        result.maxBytes = max(maxBytes, earlier.maxBytes)
        for writeClass in NavigationWriteClass.allCases {
            result.droppedFramesByClass[writeClass, default: 0] +=
                earlier.droppedFrames(for: writeClass)
            result.coalescedFramesByClass[writeClass, default: 0] +=
                earlier.coalescedFrames(for: writeClass)
        }
        return result
    }
}

#if DEBUG || HOST_TESTING
nonisolated enum BLEWriteSubmissionStage: String, Codable, Sendable {
    case prepared
    case callingCoreBluetooth = "calling_corebluetooth"
    case submitted
    case rejectedBeforeSubmission = "rejected_before_submission"
}

/// App monotonic clock only. Delegate entry is the Swift callback boundary,
/// not the time an ATT response reached the radio or the iOS Bluetooth host.
nonisolated struct RendererATTWriteTiming: Codable, Equatable, Sendable {
    let writeID: UInt64
    let connectionGeneration: UInt64
    let writeClass: String
    let preparedAtUptimeMs: UInt64
    let apiEntryAtUptimeMs: UInt64?
    let apiReturnAtUptimeMs: UInt64?
    let delegateEntryAtUptimeMs: UInt64?
    let completedAtUptimeMs: UInt64
    let outcome: String

    var durationMs: UInt64 {
        completedAtUptimeMs >= preparedAtUptimeMs ?
            completedAtUptimeMs - preparedAtUptimeMs : 0
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
    // Optional additions preserve decoding of earlier schema-1 archives.
    var inFlightWriteID: UInt64? = nil
    var inFlightSubmissionStage: BLEWriteSubmissionStage? = nil
    var lastTimedOutWriteID: UInt64? = nil
    var lastTimedOutSubmissionStage: BLEWriteSubmissionStage? = nil
    var ignoredWriteCallbacks: UInt64? = nil
    var lastWriteTiming: RendererATTWriteTiming? = nil
    var slowestWriteTiming: RendererATTWriteTiming? = nil
}
#endif

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?
    let onWriteFailure: (() -> Void)?
    let transportCanSend: (() -> Bool)?
    let transportExpectsWriteResponse: Bool?
    /// The actual CoreBluetooth characteristic used by `transportWrite`.
    /// `nil` means the queue's fallback navigation endpoint.
    let transportCharacteristicUUIDString: String?
    /// Identifies a capability-gated idempotent application command. This is
    /// metadata only; payload bytes remain opaque to the queue.
    let applicationCommandID: UUID?
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
        transportCharacteristicUUIDString: String? = nil,
        applicationCommandID: UUID? = nil,
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
        self.transportCharacteristicUUIDString =
            transportCharacteristicUUIDString
        self.applicationCommandID = applicationCommandID
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
            transportCharacteristicUUIDString:
                transportCharacteristicUUIDString,
            applicationCommandID: applicationCommandID,
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
            transportCharacteristicUUIDString:
                transportCharacteristicUUIDString,
            applicationCommandID: applicationCommandID,
            writeClass: writeClass,
            coalescingKey: coalescingKey,
            protectedFromEviction: protectedFromEviction,
            enqueuedAtUptime: uptime
        )
    }
}

struct NavigationWriteQueue {
    static let maximumFrameBytes = 576

    let maxCount: Int
    let priorityMaxCount: Int
    let maxPendingBytes: Int
    let priorityMaxPendingBytes: Int
    private var pendingWrites: [NavigationWrite] = []
    private var pendingPriorityWrites: [NavigationWrite] = []
    private var diagnosticMetrics = NavigationWriteQueueMetrics()
    private var completedDiagnosticIntervals = NavigationWriteQueueMetrics()
    private var retryStartedAtUptime: TimeInterval?
    private let now: () -> TimeInterval

    var count: Int {
        pendingPriorityWrites.count + pendingWrites.count
    }

    var pendingByteCount: Int {
        regularPendingByteCount + priorityPendingByteCount
    }

    var remainingCapacity: Int {
        max(maxCount - pendingWrites.count, 0)
    }

    var remainingByteCapacity: Int {
        max(maxPendingBytes - regularPendingByteCount, 0)
    }

    var metrics: NavigationWriteQueueMetrics {
        var snapshot = diagnosticMetrics
        snapshot.currentDepth = count
        snapshot.currentBytes = pendingByteCount
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
        completedDiagnosticIntervals = snapshot.accumulating(
            completedDiagnosticIntervals
        )
        diagnosticMetrics = NavigationWriteQueueMetrics()
        diagnosticMetrics.currentDepth = count
        diagnosticMetrics.maxDepth = count
        diagnosticMetrics.currentBytes = pendingByteCount
        diagnosticMetrics.maxBytes = pendingByteCount
#endif
        return snapshot
    }

    var cumulativeMetrics: NavigationWriteQueueMetrics {
        metrics.accumulating(completedDiagnosticIntervals)
    }

    init(
        maxCount: Int,
        priorityMaxCount: Int = 1,
        maxPendingBytes: Int? = nil,
        priorityMaxPendingBytes: Int? = nil,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        let normalizedMaxCount = max(1, maxCount)
        let normalizedPriorityMaxCount = max(1, priorityMaxCount)
        self.maxCount = normalizedMaxCount
        self.priorityMaxCount = normalizedPriorityMaxCount
        self.maxPendingBytes = max(
            maxPendingBytes ??
                normalizedMaxCount * Self.maximumFrameBytes,
            1
        )
        self.priorityMaxPendingBytes = max(
            priorityMaxPendingBytes ??
                normalizedPriorityMaxCount * Self.maximumFrameBytes,
            1
        )
        self.now = now
    }

    @discardableResult
    mutating func enqueue(_ write: NavigationWrite) -> Bool {
        beginEnqueueIfEmpty()
        pendingWrites.append(write.enqueued(at: now()))
        recordEnqueuedFrames(1)
        guard pendingWrites.count > maxCount ||
                regularPendingByteCount > maxPendingBytes else {
            recordDepth()
            return false
        }

        // Never split a logical message that was accepted atomically. Drop
        // ordinary writes oldest-first until both ceilings hold. If only a
        // protected batch remains, the newly appended ordinary write drops.
        while pendingWrites.count > maxCount ||
                regularPendingByteCount > maxPendingBytes {
            let droppedIndex = pendingWrites.firstIndex {
                !$0.protectedFromEviction
            } ?? pendingWrites.startIndex
            let droppedWrite = pendingWrites.remove(at: droppedIndex)
            droppedWrite.onDrop?()
            recordDropped(write: droppedWrite)
        }
        recordDepth()
        return true
    }

    /// Enqueues a logical multi-frame message without evicting older traffic
    /// or exposing only a prefix of the message to the transport.
    @discardableResult
    mutating func enqueueAtomically(_ writes: [NavigationWrite]) -> Bool {
        let writeBytes = writes.reduce(0) { $0 + $1.data.count }
        guard writes.count <= remainingCapacity,
              writeBytes <= remainingByteCapacity,
              writes.allSatisfy({
                  $0.data.count <= Self.maximumFrameBytes
              }) else {
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
        let writeBytes = writes.reduce(0) { $0 + $1.data.count }
        guard !writes.isEmpty,
              writes.count <= priorityMaxCount,
              writeBytes <= priorityMaxPendingBytes,
              writes.allSatisfy({
                  $0.data.count <= Self.maximumFrameBytes
              }) else {
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
            let replacedBytes = replacementIndices.reduce(0) {
                $0 + pendingPriorityWrites[$1].data.count
            }
            let retainedBytes = priorityPendingByteCount - replacedBytes
            guard retainedCount + writes.count <= priorityMaxCount,
                  retainedBytes + writeBytes <= priorityMaxPendingBytes else {
                recordRejectedFrames(writes.count)
                return false
            }
            for index in replacementIndices {
                let removed = pendingPriorityWrites.remove(at: index)
                recordCoalesced(write: removed)
                removed.onDrop?()
            }
        }

        if pendingPriorityWrites.count + writes.count > priorityMaxCount ||
            priorityPendingByteCount + writeBytes >
                priorityMaxPendingBytes {
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

    /// Replaces only an unsent, complete route snapshot. Unlike ordinary
    /// coalescing, this never evicts unrelated traffic or weakens the admitted
    /// frame's protection. Application-command members and route-clear/state
    /// boundaries are not replaceable. The outstanding ATT slot is untouched.
    @discardableResult
    mutating func enqueueLatestRouteSnapshot(_ write: NavigationWrite) -> Bool {
        guard write.writeClass == .route,
              write.applicationCommandID == nil,
              let key = write.coalescingKey, !key.isEmpty,
              !write.data.isEmpty,
              write.data.count <= Self.maximumFrameBytes,
              !pendingPriorityWrites.contains(where: {
                  $0.coalescingKey == key
              }) else {
            recordRejectedFrames(1)
            return false
        }
        // Do not move an old snapshot across a clear or a command boundary.
        let boundary = pendingWrites.lastIndex(where: {
            $0.writeClass == .route &&
                ($0.applicationCommandID != nil || $0.coalescingKey != key)
        }) ?? -1
        let matches = pendingWrites.indices.filter {
            $0 > boundary && pendingWrites[$0].writeClass == .route &&
                pendingWrites[$0].applicationCommandID == nil &&
                pendingWrites[$0].coalescingKey == key
        }
        let replacedBytes = matches.reduce(0) {
            $0 + pendingWrites[$1].data.count
        }
        guard pendingWrites.count - matches.count + 1 <= maxCount,
              regularPendingByteCount - replacedBytes + write.data.count <=
                maxPendingBytes else {
            // Reject transactionally: retain the previous admitted snapshot.
            recordRejectedFrames(1)
            return false
        }
        beginEnqueueIfEmpty()
        var removed: [NavigationWrite] = []
        for index in matches.reversed() {
            removed.append(pendingWrites.remove(at: index))
        }
        pendingWrites.append(write.enqueued(at: now()).protectingAtomicBatch())
        recordEnqueuedFrames(1)
        for old in removed { recordCoalesced(write: old) }
        recordDepth()
        for old in removed { old.onDrop?() }
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

        guard write.data.count <= Self.maximumFrameBytes else {
            recordRejectedFrames(1)
            return false
        }
        if prioritized {
            let retainedPriorityWrites = pendingPriorityWrites.filter {
                $0.coalescingKey != key
            }
            guard retainedPriorityWrites.count + 1 <= priorityMaxCount,
                  retainedPriorityWrites.reduce(0, {
                      $0 + $1.data.count
                  }) + write.data.count <= priorityMaxPendingBytes else {
                recordRejectedFrames(1)
                return false
            }
        } else {
            var admissionCandidate = pendingWrites.filter {
                $0.coalescingKey != key
            }
            admissionCandidate.append(write)
            var newWriteSurvives = true
            while admissionCandidate.count > maxCount ||
                    admissionCandidate.reduce(0, {
                        $0 + $1.data.count
                    }) > maxPendingBytes {
                let droppedIndex = admissionCandidate.firstIndex {
                    !$0.protectedFromEviction
                } ?? admissionCandidate.startIndex
                if droppedIndex == admissionCandidate.index(
                    before: admissionCandidate.endIndex
                ) {
                    newWriteSurvives = false
                }
                admissionCandidate.remove(at: droppedIndex)
            }
            guard newWriteSurvives else {
                // Replacement is transactional: a rejected larger value must
                // not erase the last admitted value for the same state key.
                recordRejectedFrames(1)
                return false
            }
        }

        beginEnqueueIfEmpty()
        removePendingWrites(
            withCoalescingKey: key,
            resetRetryWhenEmpty: false
        )
        if prioritized {
            guard pendingPriorityWrites.count < priorityMaxCount,
                  priorityPendingByteCount + write.data.count <=
                    priorityMaxPendingBytes,
                  write.data.count <= Self.maximumFrameBytes else {
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
        guard pendingWrites.count > maxCount ||
                regularPendingByteCount > maxPendingBytes else {
            recordEnqueuedFrames(1)
            recordDepth()
            return true
        }
        var rejectedNewWrite = false
        while pendingWrites.count > maxCount ||
                regularPendingByteCount > maxPendingBytes {
            let droppedIndex = pendingWrites.firstIndex {
                !$0.protectedFromEviction
            } ?? pendingWrites.startIndex
            let droppedNewWrite = droppedIndex ==
                pendingWrites.index(before: pendingWrites.endIndex)
            let droppedWrite = pendingWrites.remove(at: droppedIndex)
            if droppedNewWrite {
                // The caller owns retry scheduling. Avoid firing onDrop for a
                // write never admitted behind a protected atomic batch.
                rejectedNewWrite = true
                recordRejectedFrames(1)
            } else {
                droppedWrite.onDrop?()
                recordDropped(write: droppedWrite)
            }
        }
        if rejectedNewWrite {
            recordDepth()
            return false
        }
        recordEnqueuedFrames(1)
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

    mutating func removePendingWrites(ofClass writeClass: NavigationWriteClass) {
        let priorityMatches = pendingPriorityWrites.indices.reversed().filter {
            pendingPriorityWrites[$0].writeClass == writeClass
        }
        for index in priorityMatches {
            let removed = pendingPriorityWrites.remove(at: index)
            recordCoalesced(write: removed)
            removed.onDrop?()
        }

        let regularMatches = pendingWrites.indices.reversed().filter {
            pendingWrites[$0].writeClass == writeClass
        }
        for index in regularMatches {
            let removed = pendingWrites.remove(at: index)
            recordCoalesced(write: removed)
            removed.onDrop?()
        }
        if count == 0 {
            retryStartedAtUptime = nil
        }
        recordDepth()
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
        if retryStartedAtUptime == nil, count > 0 {
            retryStartedAtUptime = now()
        }
#endif
    }

    private mutating func recordEnqueuedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.enqueuedFrames += count
#endif
    }

    private mutating func recordFlushedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.flushedFrames += count
#endif
    }

    private mutating func recordDropped(write: NavigationWrite) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.droppedFrames += 1
        diagnosticMetrics.droppedFramesByClass[write.writeClass, default: 0] += 1
#endif
    }

    private mutating func recordRejectedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.rejectedFrames += count
#endif
    }

    private mutating func recordCoalesced(write: NavigationWrite) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.coalescedFrames += 1
        diagnosticMetrics.coalescedFramesByClass[write.writeClass, default: 0] += 1
#endif
    }

    private mutating func recordClearedFrames(_ count: Int) {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.clearedFrames += count
#endif
    }

    private mutating func recordBackpressureStop() {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.backpressureStops += 1
#endif
    }

    private mutating func recordDepth() {
#if DEBUG || HOST_TESTING
        diagnosticMetrics.currentDepth = count
        diagnosticMetrics.maxDepth = max(diagnosticMetrics.maxDepth, count)
        diagnosticMetrics.currentBytes = pendingByteCount
        diagnosticMetrics.maxBytes = max(
            diagnosticMetrics.maxBytes,
            pendingByteCount
        )
#endif
    }

    private var regularPendingByteCount: Int {
        pendingWrites.reduce(0) { $0 + $1.data.count }
    }

    private var priorityPendingByteCount: Int {
        pendingPriorityWrites.reduce(0) { $0 + $1.data.count }
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
