import Foundation

/// Discovery evidence only. The Watch owns the accessory; this is neither an
/// accessory identity nor another transport for numeric workout metrics.
nonisolated struct WatchCyclingSensorObservationV1: Codable, Equatable, Sendable
{
    static let applicationContextKey = "watchCyclingSensorObservation.v1"
    static let maximumEncodedBytes = 2_048
    static let discoveryFreshness: TimeInterval = 5
    static let reportingFreshness: TimeInterval = 10

    let version: Int
    let sessionID: UUID?
    let sessionStartedAt: Date?
    let capturedAt: Date
    let isWorkoutActive: Bool
    let cadenceObservedAt: Date?
    let powerObservedAt: Date?

    init(
        version: Int = 1,
        sessionID: UUID?,
        sessionStartedAt: Date?,
        capturedAt: Date,
        isWorkoutActive: Bool,
        cadenceObservedAt: Date? = nil,
        powerObservedAt: Date? = nil
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.capturedAt = capturedAt
        self.isWorkoutActive = isWorkoutActive
        self.cadenceObservedAt = cadenceObservedAt
        self.powerObservedAt = powerObservedAt
    }

    static func inactive(at date: Date) -> Self {
        Self(
            sessionID: nil, sessionStartedAt: nil,
            capturedAt: date, isWorkoutActive: false
        )
    }

    var isValid: Bool {
        guard version == 1, capturedAt.timeIntervalSinceReferenceDate.isFinite,
            sessionID != nil || sessionStartedAt == nil
        else { return false }
        if isWorkoutActive && (sessionID == nil || sessionStartedAt == nil) {
            return false
        }
        if !isWorkoutActive
            && (cadenceObservedAt != nil || powerObservedAt != nil)
        {
            return false
        }
        if let start = sessionStartedAt {
            guard start.timeIntervalSinceReferenceDate.isFinite,
                start <= capturedAt
            else { return false }
        }
        return [cadenceObservedAt, powerObservedAt].compactMap { $0 }.allSatisfy
        { date in
            date.timeIntervalSinceReferenceDate.isFinite && date <= capturedAt
                && (sessionStartedAt.map { date >= $0 } ?? false)
        }
    }

    func encoded() throws -> Data {
        guard isValid else { throw CodingError.invalidObservation }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw CodingError.invalidObservation
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw CodingError.invalidObservation
        }
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        guard value.isValid else { throw CodingError.invalidObservation }
        return value
    }

    func merging(into context: [String: Any]) throws -> [String: Any] {
        var merged = context
        merged[Self.applicationContextKey] = try encoded()
        return merged
    }

    static func isFresh(_ date: Date?, at now: Date, maximumAge: TimeInterval)
        -> Bool
    {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    enum CodingError: Error { case invalidObservation }
}

/// Source-independent session/replay policy shared by discovery and its host
/// tests. Losing the mirror is not a workout-end event. Only an explicit
/// Watch/HealthKit terminal observation closes the selected session.
nonisolated struct CyclingSensorObservationReducer {
    enum Source: Hashable { case mirror, watch }

    private(set) var sessionID: UUID?
    private var sessionStartedAt: Date?
    private var isClosed = false
    private var inactiveBarrier: Date?
    private var latestCapturedAt: Date?
    private var watermarks: [Source: Date] = [:]
    private var observations: [Source: WatchCyclingSensorObservationV1] = [:]

    mutating func setUnavailable(_ source: Source) {
        observations.removeValue(forKey: source)
    }

    @discardableResult
    mutating func ingest(
        _ observation: WatchCyclingSensorObservationV1,
        from source: Source,
        at now: Date
    ) -> Bool {
        guard observation.isValid, now.timeIntervalSinceReferenceDate.isFinite,
            observation.capturedAt <= now
        else { return false }
        // Old cached activity is not evidence of a currently running workout.
        if observation.isWorkoutActive
            && !WatchCyclingSensorObservationV1.isFresh(
                observation.capturedAt, at: now,
                maximumAge: WatchCyclingSensorObservationV1.discoveryFreshness
            )
        {
            return false
        }

        guard let incomingID = observation.sessionID else {
            // Only Watch can assert that recovery completed with no workout.
            guard source == .watch,
                latestCapturedAt.map({ observation.capturedAt >= $0 }) ?? true,
                inactiveBarrier.map({ observation.capturedAt >= $0 }) ?? true
            else {
                return false
            }
            inactiveBarrier = observation.capturedAt
            latestCapturedAt = observation.capturedAt
            isClosed = true
            observations.removeAll()
            return true
        }
        if let inactiveBarrier, observation.capturedAt <= inactiveBarrier {
            return false
        }
        // Check ordering before mutating the selected session. A rejected
        // packet must not clear another source's live observations.
        if !observation.isWorkoutActive || incomingID != sessionID {
            if let latestCapturedAt, observation.capturedAt < latestCapturedAt {
                return false
            }
        }
        if incomingID != sessionID {
            if let currentStart = sessionStartedAt {
                guard let incomingStart = observation.sessionStartedAt,
                    incomingStart > currentStart
                else { return false }
            } else if let latestCapturedAt,
                observation.capturedAt <= latestCapturedAt
            {
                return false
            }
            sessionID = incomingID
            sessionStartedAt = observation.sessionStartedAt
            isClosed = false
            watermarks.removeAll()
            observations.removeAll()
        } else if isClosed {
            return false
        }
        if let previous = watermarks[source], observation.capturedAt < previous
        {
            return false
        }
        watermarks[source] = observation.capturedAt
        latestCapturedAt = max(
            latestCapturedAt ?? observation.capturedAt, observation.capturedAt)
        if observation.isWorkoutActive {
            // Freshness is based on the original HealthKit sample, never the
            // context delivery time. Newly delivered stale samples cannot make
            // an enrolled profile report; previously admitted evidence gets
            // the reporting grace period without being re-dated.
            observations[source] = WatchCyclingSensorObservationV1(
                sessionID: incomingID,
                sessionStartedAt: observation.sessionStartedAt,
                capturedAt: observation.capturedAt,
                isWorkoutActive: true,
                cadenceObservedAt: admitted(
                    observation.cadenceObservedAt, at: now),
                powerObservedAt: admitted(observation.powerObservedAt, at: now)
            )
        } else {
            isClosed = true
            observations.removeAll()
        }
        return true
    }

    func hasActiveWorkout(at now: Date) -> Bool {
        !activeObservations(at: now).isEmpty
    }

    func cadenceObservedAt(at now: Date) -> Date? {
        freshMaximum(
            activeObservations(at: now).compactMap(\.cadenceObservedAt), at: now
        )
    }

    func powerObservedAt(at now: Date) -> Date? {
        freshMaximum(
            activeObservations(at: now).compactMap(\.powerObservedAt), at: now)
    }

    func nextExpiry(after now: Date) -> Date? {
        observations.values.flatMap { observation in
            [
                observation.capturedAt, observation.cadenceObservedAt,
                observation.powerObservedAt,
            ]
            .compactMap { $0 }
            .map {
                $0.addingTimeInterval(
                    WatchCyclingSensorObservationV1.reportingFreshness + 0.001)
            }
        }.filter { $0 > now }.min()
    }

    private func activeObservations(at now: Date)
        -> [WatchCyclingSensorObservationV1]
    {
        guard !isClosed else { return [] }
        return observations.values.filter {
            $0.isWorkoutActive
                && WatchCyclingSensorObservationV1.isFresh(
                    $0.capturedAt, at: now,
                    maximumAge: WatchCyclingSensorObservationV1
                        .reportingFreshness
                )
        }
    }

    private func admitted(_ date: Date?, at now: Date) -> Date? {
        WatchCyclingSensorObservationV1.isFresh(
            date, at: now,
            maximumAge: WatchCyclingSensorObservationV1.discoveryFreshness
        ) ? date : nil
    }

    private func freshMaximum(_ dates: [Date], at now: Date) -> Date? {
        dates.filter {
            WatchCyclingSensorObservationV1.isFresh(
                $0, at: now,
                maximumAge: WatchCyclingSensorObservationV1.reportingFreshness
            )
        }.max()
    }
}

/// A one-slot outbox: lifecycle/capability changes are immediate, timestamp
/// refreshes are coalesced, and failed submissions never advance the watermark.
nonisolated struct WatchCyclingSensorPublicationV1 {
    static let minimumInterval: TimeInterval = 2
    private(set) var latest: WatchCyclingSensorObservationV1?
    private var lifecycle = CyclingSensorObservationReducer()
    private var published: WatchCyclingSensorObservationV1?
    private var publishedAt: Date?

    mutating func offer(_ observation: WatchCyclingSensorObservationV1) {
        // Apply the same lifecycle gate at the sender. Otherwise a late
        // active callback could overwrite an undelivered terminal context
        // before a cold-started phone had an opportunity to see it.
        guard
            lifecycle.ingest(
                observation, from: .watch, at: observation.capturedAt
            )
        else { return }
        latest = observation
    }

    func publicationDelay(at now: Date) -> TimeInterval? {
        guard let latest else { return nil }
        guard let published, let publishedAt else { return 0 }
        if latest.sessionID != published.sessionID
            || latest.isWorkoutActive != published.isWorkoutActive
            || (latest.cadenceObservedAt != nil)
                != (published.cadenceObservedAt != nil)
            || (latest.powerObservedAt != nil)
                != (published.powerObservedAt != nil)
        {
            return 0
        }
        guard
            latest.cadenceObservedAt != published.cadenceObservedAt
                || latest.powerObservedAt != published.powerObservedAt
        else { return nil }
        return max(0, Self.minimumInterval - now.timeIntervalSince(publishedAt))
    }

    mutating func didPublish(at now: Date) {
        published = latest
        publishedAt = now
    }
}
