import Foundation

nonisolated struct WorkoutSchemaVersion: Codable, Equatable, Sendable {
    static let current = Self(major: 1, minor: 6)
    static let rideAutomationControlContextMinor: UInt16 = 5
    static let watchGPSMotionEvidenceMinor: UInt16 = 6

    let major: UInt16
    let minor: UInt16

    var supportsRideAutomationControlContext: Bool {
        major == Self.current.major
            && minor >= Self.rideAutomationControlContextMinor
    }

    var supportsWatchGPSMotionEvidence: Bool {
        major == Self.current.major
            && minor >= Self.watchGPSMotionEvidenceMinor
    }
}

nonisolated enum WorkoutTransitionOrigin: UInt8, Codable, Sendable {
    case unknown = 0
    case manual
    case automatic
    case system
}

nonisolated enum WorkoutAutomaticReasonV1: String, Codable, Sendable {
    case rideDetection
}

nonisolated struct WorkoutControlContextV1: Codable, Equatable, Sendable {
    let origin: WorkoutTransitionOrigin
    let automaticReason: WorkoutAutomaticReasonV1?
    let rideGeneration: UInt32?
    let decisionSequence: UInt32?
    let detectorProfileVersion: UInt16?
    let evidenceMask: UInt16?
    let sourceHealthMask: UInt16?
    let candidateBeganSeconds: UInt32?
    let decidedAtSeconds: UInt32?

    init(
        origin: WorkoutTransitionOrigin,
        automaticReason: WorkoutAutomaticReasonV1? = nil,
        rideGeneration: UInt32? = nil,
        decisionSequence: UInt32? = nil,
        detectorProfileVersion: UInt16? = nil,
        evidenceMask: UInt16? = nil,
        sourceHealthMask: UInt16? = nil,
        candidateBeganSeconds: UInt32? = nil,
        decidedAtSeconds: UInt32? = nil
    ) {
        self.origin = origin
        self.automaticReason = automaticReason
        self.rideGeneration = rideGeneration
        self.decisionSequence = decisionSequence
        self.detectorProfileVersion = detectorProfileVersion
        self.evidenceMask = evidenceMask
        self.sourceHealthMask = sourceHealthMask
        self.candidateBeganSeconds = candidateBeganSeconds
        self.decidedAtSeconds = decidedAtSeconds
    }
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
    let maximumHeartRateBPM: Int?

    init(
        capturedAt: Date,
        secondsByZone: [Double],
        maximumHeartRateBPM: Int? = nil
    ) {
        self.capturedAt = capturedAt
        self.secondsByZone = secondsByZone
        self.maximumHeartRateBPM = maximumHeartRateBPM
    }
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
    /// Per-location producer identity used by device ride automation. The
    /// epoch changes whenever Watch location production is restarted; the
    /// sequence changes only for a newly accepted Core Location sample.
    let motionSampleEpoch: UInt16?
    let motionSampleSequence: UInt32?

    init(
        latitude: Double,
        longitude: Double,
        capturedAt: Date,
        horizontalAccuracy: Double,
        altitude: Double?,
        verticalAccuracy: Double?,
        course: Double?,
        speed: Double?,
        motionSampleEpoch: UInt16? = nil,
        motionSampleSequence: UInt32? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.capturedAt = capturedAt
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.course = course
        self.speed = speed
        self.motionSampleEpoch = motionSampleEpoch
        self.motionSampleSequence = motionSampleSequence
    }
}

nonisolated enum WorkoutSafeErrorCodeV1: String, Codable, Sendable {
    case authorizationDenied
    case anotherWorkoutActive
    case watchUnavailable
    case setupRequired
    case finalSummaryUnavailable
    case terminalChoiceConflict
    case terminalChoiceUnconfirmed
    case segmentMarkFailed
    case segmentMarkUnconfirmed
    case segmentFinalizationPending
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

    static let title = "Discard Ride?"
    static let message = "Discarding can't be undone."
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

nonisolated struct WorkoutCompletedSegmentV1: Codable, Equatable, Sendable {
    let index: UInt32
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let distanceMeters: Double?
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
    let lastCompletedSegment: WorkoutCompletedSegmentV1?
    let availability: WorkoutAvailabilityMaskV1
    let errorCode: WorkoutSafeErrorCodeV1?
    let terminalOutcome: WorkoutTerminalOutcomeV1?
    /// Meaningful only while `state == .paused`.
    let pauseOrigin: WorkoutTransitionOrigin?
    let lastTransitionOrigin: WorkoutTransitionOrigin?
    let lastTransitionAt: Date?
    /// Wall-clock duration from confirmed start, including pauses. The legacy
    /// `elapsedTime` remains HealthKit-active/moving time.
    let wallElapsedTime: WorkoutMetricV1?
    let detectorProfileVersion: UInt16?

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
        lastCompletedSegment: WorkoutCompletedSegmentV1? = nil,
        availability: WorkoutAvailabilityMaskV1 = [],
        errorCode: WorkoutSafeErrorCodeV1? = nil,
        terminalOutcome: WorkoutTerminalOutcomeV1? = nil,
        pauseOrigin: WorkoutTransitionOrigin? = nil,
        lastTransitionOrigin: WorkoutTransitionOrigin? = nil,
        lastTransitionAt: Date? = nil,
        wallElapsedTime: WorkoutMetricV1? = nil,
        detectorProfileVersion: UInt16? = nil
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
        self.lastCompletedSegment = lastCompletedSegment
        self.availability = availability
        self.errorCode = errorCode
        self.terminalOutcome = terminalOutcome
        self.pauseOrigin = pauseOrigin
        self.lastTransitionOrigin = lastTransitionOrigin
        self.lastTransitionAt = lastTransitionAt
        self.wallElapsedTime = wallElapsedTime
        self.detectorProfileVersion = detectorProfileVersion
    }

    var currentSegmentIndex: UInt32 {
        guard let lastCompletedSegment else { return 1 }
        return lastCompletedSegment.index == .max
            ? .max
            : lastCompletedSegment.index + 1
    }
}

nonisolated enum WorkoutControlV1: String, Codable, Sendable {
    case pause
    case resume
    case markSegment
    case endAndSave
    case discard
    case requestCurrentSnapshot
}

nonisolated struct WorkoutAcknowledgementV1: Codable, Equatable, Sendable {
    let control: WorkoutControlV1
    let resultingState: WorkoutSessionStateV1
    let acknowledgedSequence: UInt64
    let errorCode: WorkoutSafeErrorCodeV1?

    init(
        control: WorkoutControlV1,
        resultingState: WorkoutSessionStateV1,
        acknowledgedSequence: UInt64,
        errorCode: WorkoutSafeErrorCodeV1? = nil
    ) {
        self.control = control
        self.resultingState = resultingState
        self.acknowledgedSequence = acknowledgedSequence
        self.errorCode = errorCode
    }
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
    let controlContext: WorkoutControlContextV1?
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
        controlContext: WorkoutControlContextV1? = nil,
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
        self.controlContext = controlContext
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
    /// Unknown peers receive the last compatible vocabulary. Optional new
    /// fields alone do not protect older decoders from new enum/source values.
    static func encodeForPhone(
        _ envelope: WorkoutEnvelopeV1,
        peerVersion: WorkoutSchemaVersion?
    ) throws -> Data {
        let data = try encode(envelope)
        guard peerVersion?.supportsWatchGPSMotionEvidence != true else { return data }
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        plist["schemaVersion"] = ["major": 1, "minor": 5]
        if var snapshot = plist["snapshot"] as? [String: Any] {
            if envelope.snapshot?.currentSpeed?.source == .healthKit {
                snapshot.removeValue(forKey: "currentSpeed")
                // Availability describes the projected metric, not its source.
                if let availability = envelope.snapshot?.availability {
                    snapshot["availability"] = availability.subtracting(.currentSpeed).rawValue
                }
            }
            for key in ["pauseOrigin", "lastTransitionOrigin"] {
                if (snapshot[key] as? NSNumber)?.uint8Value == WorkoutTransitionOrigin.system.rawValue {
                    snapshot[key] = WorkoutTransitionOrigin.unknown.rawValue
                }
            }
            if var location = snapshot["location"] as? [String: Any] {
                location.removeValue(forKey: "motionSampleEpoch")
                location.removeValue(forKey: "motionSampleSequence")
                snapshot["location"] = location
            }
            plist["snapshot"] = snapshot
        }
        if var context = plist["controlContext"] as? [String: Any] {
            if let mask = context["sourceHealthMask"] as? NSNumber {
                context["sourceHealthMask"] = mask.uint16Value & 0x000F
            }
            plist["controlContext"] = context
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

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
                  envelope.controlContext == nil,
                  envelope.control == nil,
                  envelope.acknowledgement == nil,
                  envelope.error == nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
            if snapshot.location?.motionSampleEpoch != nil,
               !envelope.schemaVersion.supportsWatchGPSMotionEvidence {
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
            try validateControlContext(
                envelope.controlContext,
                control: envelope.control
            )
        case .acknowledgement:
            guard envelope.snapshot == nil,
                  envelope.controlSenderID == nil,
                  envelope.controlContext == nil,
                  envelope.control == nil,
                  let acknowledgement = envelope.acknowledgement,
                  envelope.error == nil else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
            if let errorCode = acknowledgement.errorCode {
                guard acknowledgement.control == .markSegment,
                      errorCode == .segmentMarkFailed
                        || errorCode == .segmentMarkUnconfirmed else {
                    throw WorkoutContractError.invalidEnvelopePayload
                }
            }
        case .error:
            guard envelope.snapshot == nil,
                  envelope.controlSenderID == nil,
                  envelope.controlContext == nil,
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
        if snapshot.pauseOrigin != nil, snapshot.state != .paused {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if (snapshot.lastTransitionOrigin == nil)
            != (snapshot.lastTransitionAt == nil) {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if snapshot.detectorProfileVersion == 0 {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if snapshot.pauseOrigin == .automatic
                || snapshot.lastTransitionOrigin == .automatic,
           snapshot.detectorProfileVersion == nil {
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
            snapshot.wallElapsedTime,
            expectedUnit: .seconds,
            earliestCapturedAt: earliestComponentDate,
            latestCapturedAt: envelopeCapturedAt
        )
        if let wallElapsedTime = snapshot.wallElapsedTime?.value,
           let movingTime = snapshot.elapsedTime?.value,
           wallElapsedTime + 0.001 < movingTime {
            throw WorkoutContractError.invalidMetric
        }
        if let transitionAt = snapshot.lastTransitionAt,
           !isWithinComponentWindow(
             transitionAt,
             earliest: earliestComponentDate,
             latest: envelopeCapturedAt
           ) {
            throw WorkoutContractError.invalidDate
        }
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
            allowedSources: [
                .healthKit,
                .pairedCyclingSensor,
                .watchLocation,
                .iPhoneLocation,
            ]
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
            if let maximumHeartRateBPM = durations.maximumHeartRateBPM,
               !WorkoutHeartRateZoneProfile.supportedMaximumHeartRateBPM
                    .contains(maximumHeartRateBPM) {
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
            if (location.motionSampleEpoch == nil) !=
                (location.motionSampleSequence == nil) ||
                location.motionSampleEpoch == 0 ||
                location.motionSampleSequence == 0 {
                throw WorkoutContractError.invalidLocation
            }
        }
        if let segment = snapshot.lastCompletedSegment {
            guard segment.index > 0,
                  segment.index < UInt32.max,
                  segment.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  segment.endedAt.timeIntervalSinceReferenceDate.isFinite,
                  segment.startedAt <= segment.endedAt,
                  snapshot.startDate.map({ segment.startedAt >= $0 }) ?? false,
                  segment.endedAt <= envelopeCapturedAt,
                  segment.duration.isFinite,
                  segment.duration >= 0,
                  segment.duration
                    <= segment.endedAt.timeIntervalSince(segment.startedAt)
                        + 1,
                  segment.distanceMeters.map({
                      $0.isFinite && $0 >= 0
                  }) ?? true else {
                throw WorkoutContractError.invalidMetric
            }
        }

        guard snapshot.availability.intersection(knownAvailabilityBits)
                == expectedAvailability(for: snapshot) else {
            throw WorkoutContractError.invalidMetric
        }
    }

    private static func validateControlContext(
        _ context: WorkoutControlContextV1?,
        control: WorkoutControlV1?
    ) throws {
        guard let context else { return }
        guard control == .pause || control == .resume
                || control == .requestCurrentSnapshot,
              context.origin == .manual || context.origin == .automatic else {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if control == .requestCurrentSnapshot,
           context.origin != .automatic {
            throw WorkoutContractError.invalidEnvelopePayload
        }
        if context.origin == .automatic {
            guard context.automaticReason == .rideDetection,
                  context.rideGeneration.map({ $0 > 0 }) == true,
                  context.decisionSequence.map({ $0 > 0 }) == true,
                  context.detectorProfileVersion.map({ $0 > 0 }) == true,
                  context.sourceHealthMask.map({
                    $0 & ~RideAutomationSourceHealth.mask == 0
                  }) ?? true,
                  [
                    context.evidenceMask != nil,
                    context.sourceHealthMask != nil,
                    context.candidateBeganSeconds != nil,
                    context.decidedAtSeconds != nil,
                  ].allSatisfy({ $0 })
                    || [
                        context.evidenceMask == nil,
                        context.sourceHealthMask == nil,
                        context.candidateBeganSeconds == nil,
                        context.decidedAtSeconds == nil,
                    ].allSatisfy({ $0 }) else {
                throw WorkoutContractError.invalidEnvelopePayload
            }
        } else if context.automaticReason != nil
                    || context.rideGeneration != nil
                    || context.decisionSequence != nil
                    || context.detectorProfileVersion != nil
                    || context.evidenceMask != nil
                    || context.sourceHealthMask != nil
                    || context.candidateBeganSeconds != nil
                    || context.decidedAtSeconds != nil {
            throw WorkoutContractError.invalidEnvelopePayload
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
