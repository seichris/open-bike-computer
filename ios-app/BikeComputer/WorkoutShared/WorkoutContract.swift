import Foundation

nonisolated struct WorkoutSchemaVersion: Codable, Equatable, Sendable {
    static let current = Self(major: 1, minor: 3)

    let major: UInt16
    let minor: UInt16
}

nonisolated enum WorkoutTerminalOutcomeV1: String, Codable, Sendable {
    case saved
    case discarded
}

nonisolated enum WorkoutMessageKind: String, Codable, Sendable {
    case snapshot
    case control
    case acknowledgement
    case error
}

nonisolated enum WorkoutSessionStateV1: String, Codable, Sendable {
    case idle
    case starting
    case running
    case paused
    case ending
    case ended
    case failed

    var isActive: Bool {
        switch self {
        case .starting, .running, .paused, .ending:
            true
        case .idle, .ended, .failed:
            false
        }
    }

    var requiresStartDate: Bool {
        switch self {
        case .starting, .running, .paused, .ending, .ended:
            true
        case .idle, .failed:
            false
        }
    }

    func canTransition(to candidate: Self) -> Bool {
        switch self {
        case .idle:
            true
        case .starting:
            candidate != .idle
        case .running:
            [.running, .paused, .ending, .ended, .failed].contains(candidate)
        case .paused:
            [.paused, .running, .ending, .ended, .failed].contains(candidate)
        case .ending:
            [.ending, .ended, .failed].contains(candidate)
        case .ended:
            candidate == .ended
        case .failed:
            candidate == .failed
        }
    }
}

nonisolated struct WorkoutMetricV1: Codable, Equatable, Sendable {
    let value: Double
    let unit: WorkoutMetricUnitV1
    let capturedAt: Date
    let source: WorkoutMetricSourceV1?

    init(
        value: Double,
        unit: WorkoutMetricUnitV1,
        capturedAt: Date,
        source: WorkoutMetricSourceV1? = nil
    ) {
        self.value = value
        self.unit = unit
        self.capturedAt = capturedAt
        self.source = source
    }
}

nonisolated struct WorkoutZoneDurationsV1: Codable, Equatable, Sendable {
    let capturedAt: Date
    let secondsByZone: [Double]
}

nonisolated struct WorkoutLocationV1: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
    let horizontalAccuracy: Double
    let altitude: Double?
    let verticalAccuracy: Double?
    let course: Double?
    let speed: Double?
}

nonisolated enum WorkoutSafeErrorCodeV1: String, Codable, Sendable {
    case authorizationDenied
    case anotherWorkoutActive
    case watchUnavailable
    case setupRequired
    case finalSummaryUnavailable
    case terminalChoiceConflict
    case terminalChoiceUnconfirmed
    case sessionFailed
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum WorkoutDiscardDisclosureV1 {
    enum Choice: Sendable {
        case cancel
        case confirmDiscard
    }

    static let title = "Discard Workout?"
    static let message = "This can’t be undone. This ride will not be saved to Health."
    static let cancelTitle = "Keep Riding"
    static let confirmTitle = "Discard Workout"

    private static func perform(_ choice: Choice, discard: () -> Void) {
        guard case .confirmDiscard = choice else { return }
        discard()
    }

    static func perform(
        _ choice: Choice,
        expectedSessionID: UUID,
        currentSessionID: UUID?,
        discard: () -> Void
    ) {
        guard expectedSessionID == currentSessionID else { return }
        perform(choice, discard: discard)
    }
}

nonisolated struct WorkoutSnapshotV1: Codable, Equatable, Sendable {
    let state: WorkoutSessionStateV1
    let startDate: Date?
    let elapsedTime: WorkoutMetricV1?
    let currentHeartRate: WorkoutMetricV1?
    let averageHeartRate: WorkoutMetricV1?
    let activeEnergy: WorkoutMetricV1?
    let cyclingDistance: WorkoutMetricV1?
    let currentSpeed: WorkoutMetricV1?
    let cyclingPower: WorkoutMetricV1?
    let cyclingCadence: WorkoutMetricV1?
    let currentHeartRateZone: UInt8?
    let heartRateZoneCount: UInt8?
    let heartRateZoneDurations: WorkoutZoneDurationsV1?
    let location: WorkoutLocationV1?
    let availability: WorkoutAvailabilityMaskV1
    let errorCode: WorkoutSafeErrorCodeV1?
    let terminalOutcome: WorkoutTerminalOutcomeV1?

    init(
        state: WorkoutSessionStateV1,
        startDate: Date? = nil,
        elapsedTime: WorkoutMetricV1? = nil,
        currentHeartRate: WorkoutMetricV1? = nil,
        averageHeartRate: WorkoutMetricV1? = nil,
        activeEnergy: WorkoutMetricV1? = nil,
        cyclingDistance: WorkoutMetricV1? = nil,
        currentSpeed: WorkoutMetricV1? = nil,
        cyclingPower: WorkoutMetricV1? = nil,
        cyclingCadence: WorkoutMetricV1? = nil,
        currentHeartRateZone: UInt8? = nil,
        heartRateZoneCount: UInt8? = nil,
        heartRateZoneDurations: WorkoutZoneDurationsV1? = nil,
        location: WorkoutLocationV1? = nil,
        availability: WorkoutAvailabilityMaskV1 = [],
        errorCode: WorkoutSafeErrorCodeV1? = nil,
        terminalOutcome: WorkoutTerminalOutcomeV1? = nil
    ) {
        self.state = state
        self.startDate = startDate
        self.elapsedTime = elapsedTime
        self.currentHeartRate = currentHeartRate
        self.averageHeartRate = averageHeartRate
        self.activeEnergy = activeEnergy
        self.cyclingDistance = cyclingDistance
        self.currentSpeed = currentSpeed
        self.cyclingPower = cyclingPower
        self.cyclingCadence = cyclingCadence
        self.currentHeartRateZone = currentHeartRateZone
        self.heartRateZoneCount = heartRateZoneCount
        self.heartRateZoneDurations = heartRateZoneDurations
        self.location = location
        self.availability = availability
        self.errorCode = errorCode
        self.terminalOutcome = terminalOutcome
    }
}

nonisolated enum WorkoutControlV1: String, Codable, Sendable {
    case pause
    case resume
    case endAndSave
    case discard
    case requestCurrentSnapshot
}

nonisolated struct WorkoutAcknowledgementV1: Codable, Equatable, Sendable {
    let control: WorkoutControlV1
    let resultingState: WorkoutSessionStateV1
    let acknowledgedSequence: UInt64
}

nonisolated struct WorkoutErrorV1: Codable, Equatable, Sendable {
    let code: WorkoutSafeErrorCodeV1
}

nonisolated struct WorkoutEnvelopeV1: Codable, Equatable, Sendable {
    let schemaVersion: WorkoutSchemaVersion
    let kind: WorkoutMessageKind
    let sessionID: UUID
    let sessionToken: UInt16
    let transportGenerationID: UUID?
    let sequence: UInt64
    let capturedAt: Date
    /// Identifies one iPhone process' control sequence space. A fresh process
    /// gets a fresh identifier so Watch can retire the old replay watermark
    /// without weakening replay protection for delayed controls.
    let controlSenderID: UUID?
    let snapshot: WorkoutSnapshotV1?
    let control: WorkoutControlV1?
    let acknowledgement: WorkoutAcknowledgementV1?
    let error: WorkoutErrorV1?

    init(
        schemaVersion: WorkoutSchemaVersion = .current,
        kind: WorkoutMessageKind,
        sessionID: UUID,
        sessionToken: UInt16,
        transportGenerationID: UUID? = nil,
        sequence: UInt64,
        capturedAt: Date,
        controlSenderID: UUID? = nil,
        snapshot: WorkoutSnapshotV1? = nil,
        control: WorkoutControlV1? = nil,
        acknowledgement: WorkoutAcknowledgementV1? = nil,
        error: WorkoutErrorV1? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sessionID = sessionID
        self.sessionToken = sessionToken
        self.transportGenerationID = transportGenerationID
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.controlSenderID = controlSenderID
        self.snapshot = snapshot
        self.control = control
        self.acknowledgement = acknowledgement
        self.error = error
    }
}

nonisolated enum WorkoutContractError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedSchemaMajor(UInt16)
    case emptySessionID
    case zeroSessionToken
    case invalidEnvelopePayload
    case invalidDate
    case invalidMetric
    case invalidZone
    case invalidLocation

    var description: String {
        switch self {
        case .unsupportedSchemaMajor(let major):
            "Unsupported workout schema major version: \(major)"
        case .emptySessionID:
            "Workout session ID must not be empty"
        case .zeroSessionToken:
            "Workout session token must not be zero"
        case .invalidEnvelopePayload:
            "Workout envelope kind and payload do not match"
        case .invalidDate:
            "Workout envelope contains an invalid date"
        case .invalidMetric:
            "Workout envelope contains an invalid metric"
        case .invalidZone:
            "Workout envelope contains invalid heart-rate zone data"
        case .invalidLocation:
            "Workout envelope contains an invalid location"
        }
    }
}

nonisolated enum WorkoutContractCodec {
    static func encode(_ envelope: WorkoutEnvelopeV1) throws -> Data {
        try validate(envelope)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> WorkoutEnvelopeV1 {
        let envelope = try PropertyListDecoder().decode(WorkoutEnvelopeV1.self, from: data)
        try validate(envelope)
        return envelope
    }

    static func validate(_ envelope: WorkoutEnvelopeV1) throws {
        guard envelope.schemaVersion.major == WorkoutSchemaVersion.current.major else {
            throw WorkoutContractError.unsupportedSchemaMajor(envelope.schemaVersion.major)
        }
        guard envelope.sessionID != emptyUUID else {
            throw WorkoutContractError.emptySessionID
        }
        guard envelope.sessionToken != 0 else {
            throw WorkoutContractError.zeroSessionToken
        }
        if envelope.controlSenderID == emptyUUID {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        guard envelope.transportGenerationID != emptyUUID else {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        guard envelope.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkoutContractError.invalidDate
        }

        let populatedPayloads = [
            envelope.snapshot != nil,
            envelope.control != nil,
            envelope.acknowledgement != nil,
            envelope.error != nil,
        ].filter { $0 }.count
        guard populatedPayloads == 1 else {
            throw WorkoutContractError.invalidEnvelopePayload
        }

        switch envelope.kind {
        case .snapshot:
            guard let snapshot = envelope.snapshot,
                  envelope.controlSenderID == nil,
                  envelope.control == nil,
                  envelope.acknowledgement == nil,
                  envelope.error == nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
            try validate(snapshot, envelopeCapturedAt: envelope.capturedAt)
        case .control:
            guard envelope.snapshot == nil,
                  envelope.control != nil,
                  envelope.acknowledgement == nil,
                  envelope.error == nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
        case .acknowledgement:
            guard envelope.snapshot == nil,
                  envelope.controlSenderID == nil,
                  envelope.control == nil,
                  envelope.acknowledgement != nil,
                  envelope.error == nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
        case .error:
            guard envelope.snapshot == nil,
                  envelope.controlSenderID == nil,
                  envelope.control == nil,
                  envelope.acknowledgement == nil,
                  envelope.error != nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
        }
    }

    private static func validate(
        _ snapshot: WorkoutSnapshotV1,
        envelopeCapturedAt: Date
    ) throws {
        if snapshot.state.requiresStartDate && snapshot.startDate == nil {
            throw WorkoutContractError.invalidDate
        }
        if snapshot.terminalOutcome != nil, snapshot.state != .ended {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if let startDate = snapshot.startDate {
            guard startDate.timeIntervalSinceReferenceDate.isFinite,
                  startDate <= envelopeCapturedAt else {
                throw WorkoutContractError.invalidDate
            }
        }

        let earliestComponentDate = snapshot.startDate
        try validate(
            snapshot.elapsedTime,
            expectedUnit: .seconds,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt
        )
        try validate(
            snapshot.currentHeartRate,
            expectedUnit: .beatsPerMinute,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt,
            requiresPositiveValue: true
        )
        try validate(
            snapshot.averageHeartRate,
            expectedUnit: .beatsPerMinute,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt,
            requiresPositiveValue: true
        )
        try validate(
            snapshot.activeEnergy,
            expectedUnit: .kilocalories,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt
        )
        try validate(
            snapshot.cyclingDistance,
            expectedUnit: .meters,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt,
            allowedSources: [.healthKit, .watchRoute, .iPhoneNavigation]
        )
        try validate(
            snapshot.currentSpeed,
            expectedUnit: .metersPerSecond,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt,
            allowedSources: [.pairedCyclingSensor, .watchLocation, .iPhoneLocation]
        )
        try validate(
            snapshot.cyclingPower,
            expectedUnit: .watts,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt
        )
        try validate(
            snapshot.cyclingCadence,
            expectedUnit: .revolutionsPerMinute,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt
        )

        let hasZonePayload = snapshot.heartRateZoneCount != nil
            || snapshot.currentHeartRateZone != nil
            || snapshot.heartRateZoneDurations != nil
        if hasZonePayload {
            guard let zoneCount = snapshot.heartRateZoneCount, zoneCount > 0 else {
                throw WorkoutContractError.invalidZone
            }
        }
        if let currentZone = snapshot.currentHeartRateZone {
            guard let zoneCount = snapshot.heartRateZoneCount,
                  currentZone > 0,
                  currentZone <= zoneCount else {
                throw WorkoutContractError.invalidZone
            }
        }
        if let durations = snapshot.heartRateZoneDurations {
            guard let zoneCount = snapshot.heartRateZoneCount,
                  isWithinComponentWindow(
                    durations.capturedAt,
                    earliest: earliestComponentDate,
                    latest: envelopeCapturedAt
                  ),
                  !durations.secondsByZone.isEmpty,
                  durations.secondsByZone.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  Int(zoneCount) == durations.secondsByZone.count else {
                throw WorkoutContractError.invalidZone
            }
        }

        if let location = snapshot.location {
            guard location.latitude.isFinite,
                  (-90.0...90.0).contains(location.latitude),
                  location.longitude.isFinite,
                  (-180.0...180.0).contains(location.longitude),
                  isWithinComponentWindow(
                    location.capturedAt,
                    earliest: earliestComponentDate,
                    latest: envelopeCapturedAt
                  ),
                  location.horizontalAccuracy.isFinite,
                  location.horizontalAccuracy >= 0,
                  isFinite(location.altitude),
                  isFiniteAndNonnegative(location.verticalAccuracy),
                  isFiniteAndInRange(location.course, range: 0..<360),
                  isFiniteAndNonnegative(location.speed) else {
                throw WorkoutContractError.invalidLocation
            }
            if (location.altitude == nil) != (location.verticalAccuracy == nil) {
                throw WorkoutContractError.invalidLocation
            }
        }

        guard snapshot.availability.intersection(knownAvailabilityBits)
                == expectedAvailability(for: snapshot) else {
            throw WorkoutContractError.invalidMetric
        }
    }

    private static let emptyUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static let knownAvailabilityBits: WorkoutAvailabilityMaskV1 = [
        .elapsedTime,
        .currentHeartRate,
        .averageHeartRate,
        .activeEnergy,
        .cyclingDistance,
        .currentSpeed,
        .cyclingPower,
        .cyclingCadence,
        .heartRateZone,
        .location,
        .altitude,
    ]

    private static func validate(
        _ metric: WorkoutMetricV1?,
        expectedUnit: WorkoutMetricUnitV1,
        earliestCapturedAt: Date?,
        latestCapturedAt: Date,
        allowedSources: [WorkoutMetricSourceV1]? = nil,
        requiresPositiveValue: Bool = false
    ) throws {
        guard let metric else { return }
        guard metric.unit == expectedUnit,
              metric.value.isFinite,
              metric.value >= 0,
              !requiresPositiveValue || metric.value > 0,
              isWithinComponentWindow(
                metric.capturedAt,
                earliest: earliestCapturedAt,
                latest: latestCapturedAt
              ) else {
            throw WorkoutContractError.invalidMetric
        }
        if let allowedSources {
            guard let source = metric.source, allowedSources.contains(source) else {
                throw WorkoutContractError.invalidMetric
            }
        }
    }

    private static func expectedAvailability(
        for snapshot: WorkoutSnapshotV1
    ) -> WorkoutAvailabilityMaskV1 {
        var result: WorkoutAvailabilityMaskV1 = []
        if snapshot.elapsedTime != nil { result.insert(.elapsedTime) }
        if snapshot.currentHeartRate != nil { result.insert(.currentHeartRate) }
        if snapshot.averageHeartRate != nil { result.insert(.averageHeartRate) }
        if snapshot.activeEnergy != nil { result.insert(.activeEnergy) }
        if snapshot.cyclingDistance != nil { result.insert(.cyclingDistance) }
        if snapshot.currentSpeed != nil { result.insert(.currentSpeed) }
        if snapshot.cyclingPower != nil { result.insert(.cyclingPower) }
        if snapshot.cyclingCadence != nil { result.insert(.cyclingCadence) }
        if snapshot.heartRateZoneCount != nil
            || snapshot.currentHeartRateZone != nil
            || snapshot.heartRateZoneDurations != nil {
            result.insert(.heartRateZone)
        }
        if snapshot.location != nil { result.insert(.location) }
        if snapshot.location?.altitude != nil { result.insert(.altitude) }
        return result
    }

    private static func isFinite(_ value: Double?) -> Bool {
        value?.isFinite ?? true
    }

    private static func isFiniteAndNonnegative(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0
    }

    private static func isFiniteAndInRange(_ value: Double?, range: Range<Double>) -> Bool {
        guard let value else { return true }
        return value.isFinite && range.contains(value)
    }

    private static func isWithinComponentWindow(
        _ date: Date,
        earliest: Date?,
        latest: Date
    ) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date <= latest else {
            return false
        }
        return earliest.map { date >= $0 } ?? true
    }
}

nonisolated struct WorkoutEnvelopeSequenceGate: Sendable {
    private(set) var highestSequenceBySession: [UUID: UInt64] = [:]
    private(set) var sessionTokenBySession: [UUID: UInt16] = [:]
    private(set) var transportGenerationBySession: [UUID: UUID] = [:]
    private(set) var seenTransportGenerationsBySession: [UUID: Set<UUID>] = [:]
    private(set) var startDateBySession: [UUID: Date] = [:]
    private(set) var latestCapturedAtBySession: [UUID: Date] = [:]
    private(set) var currentSnapshotEnvelope: WorkoutEnvelopeV1?
    private var retiredSessionIDs: Set<UUID> = []

    mutating func ingest(_ envelope: WorkoutEnvelopeV1) throws -> Bool {
        try WorkoutContractCodec.validate(envelope)
        guard !retiredSessionIDs.contains(envelope.sessionID) else {
            return false
        }
        let canonicalToken = sessionTokenBySession[envelope.sessionID]
        let canonicalGeneration = transportGenerationBySession[envelope.sessionID]
        if canonicalGeneration != nil,
           envelope.transportGenerationID == nil {
            return false
        }
        let tokenChanged = canonicalToken != nil
            && canonicalToken != envelope.sessionToken
        let explicitGenerationChanged = canonicalToken != nil
            && envelope.transportGenerationID != nil
            && canonicalGeneration != envelope.transportGenerationID
        let transportIdentityChanged = tokenChanged || explicitGenerationChanged
        let isGenerationReset: Bool
        if transportIdentityChanged {
            isGenerationReset = canAcceptGenerationReset(envelope)
        } else {
            isGenerationReset = false
        }
        if transportIdentityChanged, !isGenerationReset {
            return false
        }
        if let snapshot = envelope.snapshot,
           snapshot.state != .idle,
           let canonicalStartDate = startDateBySession[envelope.sessionID],
           snapshot.startDate != canonicalStartDate {
            return false
        }
        if !isGenerationReset,
           let highestSequence = highestSequenceBySession[envelope.sessionID],
           envelope.sequence <= highestSequence {
                return false
        }

        if let snapshot = envelope.snapshot,
           !canReplaceCurrentSession(with: snapshot, envelope: envelope) {
            return false
        }

        highestSequenceBySession[envelope.sessionID] = envelope.sequence
        sessionTokenBySession[envelope.sessionID] = envelope.sessionToken
        if let generation = envelope.transportGenerationID {
            transportGenerationBySession[envelope.sessionID] = generation
            seenTransportGenerationsBySession[envelope.sessionID, default: []]
                .insert(generation)
        }
        latestCapturedAtBySession[envelope.sessionID] = envelope.capturedAt
        if let snapshot = envelope.snapshot {
            if snapshot.state != .idle,
               startDateBySession[envelope.sessionID] == nil,
               let startDate = snapshot.startDate {
                startDateBySession[envelope.sessionID] = startDate
            }
            currentSnapshotEnvelope = envelope
        }
        return true
    }

    mutating func retireCurrentSession() {
        guard let sessionID = currentSnapshotEnvelope?.sessionID else { return }
        retiredSessionIDs.insert(sessionID)
        currentSnapshotEnvelope = nil
    }

    private func canAcceptGenerationReset(
        _ envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let snapshot = envelope.snapshot,
              snapshot.state.isActive || snapshot.state == .ended,
              let canonicalStartDate = startDateBySession[envelope.sessionID],
              snapshot.startDate == canonicalStartDate,
              let latestCapturedAt = latestCapturedAtBySession[envelope.sessionID],
              envelope.capturedAt > latestCapturedAt else {
            return false
        }
        if let generation = envelope.transportGenerationID {
            return generation
                    != transportGenerationBySession[envelope.sessionID]
                && !(seenTransportGenerationsBySession[envelope.sessionID] ?? [])
                    .contains(generation)
        }
        // Backward compatibility for v1.0 senders. v1.1 and later carry an
        // explicit generation on every snapshot, so reconnect can begin at
        // any sequence without reopening a retired generation.
        return transportGenerationBySession[envelope.sessionID] == nil
            && envelope.sequence == 1
    }

    mutating func ingestBatch(_ envelopes: [WorkoutEnvelopeV1]) -> WorkoutEnvelopeBatchResult {
        var latestAcceptedSnapshot: WorkoutEnvelopeV1?
        var acceptedEnvelopes: [WorkoutEnvelopeV1] = []
        var rejections: [WorkoutEnvelopeBatchRejection] = []
        for (index, envelope) in envelopes.enumerated() {
            do {
                if try ingest(envelope) {
                    acceptedEnvelopes.append(envelope)
                    if envelope.snapshot != nil {
                        latestAcceptedSnapshot = envelope
                    }
                }
            } catch let error as WorkoutContractError {
                rejections.append(WorkoutEnvelopeBatchRejection(index: index, error: error))
            } catch {
                rejections.append(
                    WorkoutEnvelopeBatchRejection(index: index, error: .invalidEnvelopePayload)
                )
            }
        }
        return WorkoutEnvelopeBatchResult(
            latestSnapshotEnvelope: latestAcceptedSnapshot,
            acceptedEnvelopes: acceptedEnvelopes,
            rejections: rejections
        )
    }

    private func canReplaceCurrentSession(
        with candidate: WorkoutSnapshotV1,
        envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let currentEnvelope = currentSnapshotEnvelope,
              let current = currentEnvelope.snapshot else {
            return true
        }
        if currentEnvelope.sessionID == envelope.sessionID {
            return current.state.canTransition(to: candidate.state)
        }

        guard candidate.state != .idle else {
            return false
        }

        if current.state == .idle || current.state == .failed {
            if candidate.state.isActive {
                return true
            }
            if candidate.state == .ended {
                return envelope.capturedAt > currentEnvelope.capturedAt
            }
        }

        let currentOrderDate = current.startDate ?? currentEnvelope.capturedAt
        let candidateOrderDate = candidate.startDate ?? envelope.capturedAt
        guard candidateOrderDate > currentOrderDate else {
            return false
        }

        // A failed start attempt must not hide a workout that is still active.
        return !(current.state.isActive && candidate.state == .failed)
    }
}

nonisolated struct WorkoutEnvelopeBatchRejection: Equatable, Sendable {
    let index: Int
    let error: WorkoutContractError
}

nonisolated struct WorkoutEnvelopeBatchResult: Equatable, Sendable {
    let latestSnapshotEnvelope: WorkoutEnvelopeV1?
    let acceptedEnvelopes: [WorkoutEnvelopeV1]
    let rejections: [WorkoutEnvelopeBatchRejection]
}
