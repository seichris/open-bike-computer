import Foundation

/// Sendable weak handoff used only to route framework completion callbacks
/// onto MainActor without retaining either app-lifetime manager.
nonisolated final class WorkoutWeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
}

/// Produces iPhone-to-Watch controls in the same monotonic sequence space used
/// by the current Watch snapshot. Basing every control on the newest received
/// Watch sequence makes a newly launched iPhone process advance beyond the
/// Watch's retained replay watermark without persisting workout identity.
nonisolated struct WorkoutControlEnvelopeSequencer: Sendable {
    let controlSenderID: UUID
    private(set) var sessionID: UUID?
    private(set) var highestSequence: UInt64 = 0

    init(controlSenderID: UUID = UUID()) {
        self.controlSenderID = controlSenderID
    }

    mutating func makeEnvelope(
        control: WorkoutControlV1,
        currentEnvelope: WorkoutEnvelopeV1,
        capturedAt: Date
    ) -> WorkoutEnvelopeV1? {
        guard currentEnvelope.snapshot != nil else { return nil }
        if sessionID != currentEnvelope.sessionID {
            sessionID = currentEnvelope.sessionID
            highestSequence = currentEnvelope.sequence
        } else {
            highestSequence = max(highestSequence, currentEnvelope.sequence)
        }
        guard highestSequence < UInt64.max else { return nil }
        highestSequence += 1

        let envelope = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: currentEnvelope.sessionID,
            sessionToken: currentEnvelope.sessionToken,
            transportGenerationID: currentEnvelope.transportGenerationID,
            sequence: highestSequence,
            capturedAt: capturedAt,
            controlSenderID: controlSenderID,
            control: control
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else {
            return nil
        }
        return envelope
    }

    mutating func reset() {
        sessionID = nil
        highestSequence = 0
    }
}

/// Replay gate for iPhone-to-Watch controls. Sequences are monotonic within one
/// iPhone process. A newly launched process uses a fresh sender ID and may
/// advance the generation only once; retired sender IDs can never resume.
nonisolated struct WorkoutRemoteControlSequenceGate: Sendable {
    static let maximumFutureCaptureSkew: TimeInterval = 2

    struct Checkpoint: Codable, Equatable, Sendable {
        let currentSenderID: UUID?
        let highestSequence: UInt64
        let seenSenderIDs: Set<UUID>
        let latestCapturedAt: Date?
        let legacyHighestSequence: UInt64

        var isValid: Bool {
            guard latestCapturedAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true,
                  !seenSenderIDs.contains(Self.zeroUUID) else {
                return false
            }
            if let currentSenderID {
                return currentSenderID != Self.zeroUUID
                    && seenSenderIDs.contains(currentSenderID)
                    && highestSequence > 0
            }
            return highestSequence == 0 && seenSenderIDs.isEmpty
        }

        private static let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
    }

    private(set) var currentSenderID: UUID?
    private(set) var highestSequence: UInt64 = 0
    private(set) var seenSenderIDs: Set<UUID> = []
    private(set) var latestCapturedAt: Date?
    private(set) var legacyHighestSequence: UInt64 = 0

    init(checkpoint: Checkpoint? = nil) {
        guard let checkpoint, checkpoint.isValid else { return }
        currentSenderID = checkpoint.currentSenderID
        highestSequence = checkpoint.highestSequence
        seenSenderIDs = checkpoint.seenSenderIDs
        latestCapturedAt = checkpoint.latestCapturedAt
        legacyHighestSequence = checkpoint.legacyHighestSequence
    }

    var checkpoint: Checkpoint {
        Checkpoint(
            currentSenderID: currentSenderID,
            highestSequence: highestSequence,
            seenSenderIDs: seenSenderIDs,
            latestCapturedAt: latestCapturedAt,
            legacyHighestSequence: legacyHighestSequence
        )
    }

    mutating func ingest(
        _ envelope: WorkoutEnvelopeV1,
        receivedAt: Date? = nil
    ) throws -> Bool {
        try WorkoutContractCodec.validate(envelope)
        if let receivedAt {
            guard receivedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw WorkoutContractError.invalidDate
            }
            guard envelope.capturedAt <= receivedAt.addingTimeInterval(
                Self.maximumFutureCaptureSkew
            ) else {
                return false
            }
        }
        guard envelope.kind == .control, envelope.control != nil else {
            throw WorkoutContractError.invalidEnvelopePayload
        }

        guard let senderID = envelope.controlSenderID else {
            // Once a modern sender has been observed, a delayed legacy control
            // cannot reopen the retired process' replay space.
            guard currentSenderID == nil,
                  envelope.sequence > legacyHighestSequence else {
                return false
            }
            legacyHighestSequence = envelope.sequence
            latestCapturedAt = later(latestCapturedAt, envelope.capturedAt)
            return true
        }

        if let currentSenderID {
            if senderID == currentSenderID {
                guard envelope.sequence > highestSequence else { return false }
            } else {
                guard !seenSenderIDs.contains(senderID),
                      latestCapturedAt.map({ envelope.capturedAt > $0 }) ?? true else {
                    return false
                }
                self.currentSenderID = senderID
                highestSequence = 0
            }
        } else {
            guard latestCapturedAt.map({ envelope.capturedAt > $0 }) ?? true else {
                return false
            }
            currentSenderID = senderID
        }

        guard envelope.sequence > highestSequence else { return false }
        highestSequence = envelope.sequence
        seenSenderIDs.insert(senderID)
        latestCapturedAt = later(latestCapturedAt, envelope.capturedAt)
        return true
    }

    mutating func reset() {
        self = Self()
    }

    private func later(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}

nonisolated enum WorkoutMirrorConnectionStateV1: String, Equatable, Sendable {
    case unsupported
    case idle
    case launchingWatch
    case awaitingFirstSnapshot
    case connected
    case stale
    case disconnected
    case ended
    case failed
}

nonisolated enum WorkoutErrorCopyContextV1: Equatable, Sendable {
    case general
    case activeWorkout
    case workoutLaunch
}

nonisolated enum WorkoutErrorCopyV1 {
    static func title(_ code: WorkoutSafeErrorCodeV1?) -> String {
        switch code {
        case .authorizationDenied, .setupRequired:
            return "Finish setup on Apple Watch"
        case .anotherWorkoutActive:
            return "Workout session changed"
        case .watchUnavailable:
            return "Apple Watch unavailable"
        case .finalSummaryUnavailable:
            return "Final Watch summary unavailable"
        case .terminalChoiceConflict:
            return "Finish choice not applied"
        case .terminalChoiceUnconfirmed:
            return "Finish choice unconfirmed"
        case .segmentMarkFailed:
            return "Segment wasn’t marked"
        case .segmentMarkUnconfirmed:
            return "Segment confirmation pending"
        case .segmentFinalizationPending:
            return "Segment is delaying save"
        case .sessionFailed, .unknown, nil:
            return "Workout needs attention"
        }
    }

    static func detail(
        _ code: WorkoutSafeErrorCodeV1?,
        context: WorkoutErrorCopyContextV1 = .general
    ) -> String {
        switch code {
        case .authorizationDenied, .setupRequired:
            return "Open BikeComputer on Apple Watch and allow Health access, then try again."
        case .anotherWorkoutActive:
            return "Another app may now own the workout session. Check your Apple Watch before starting or resuming a ride."
        case .watchUnavailable:
            switch context {
            case .activeWorkout:
                return "Keep your paired Apple Watch nearby, unlocked, and wearing BikeComputer. A current workout continues on Watch."
            case .workoutLaunch:
                return "BikeComputer could not reach Apple Watch, so the workout did not start. Open BikeComputer on Watch and try again."
            case .general:
                return "BikeComputer could not communicate with Apple Watch. Check BikeComputer on Watch and verify the workout state."
            }
        case .finalSummaryUnavailable:
            return "Apple Watch reported that the ride ended, but the final saved or discarded result was not received. Check BikeComputer on Watch or Health before dismissing."
        case .terminalChoiceConflict:
            return "Apple Watch had already committed the other finish choice. The saved or discarded result shown above is authoritative."
        case .terminalChoiceUnconfirmed:
            return "BikeComputer could not confirm whether your Save or Discard choice was applied. Check BikeComputer on Apple Watch; if the ride ended, verify the result in Health."
        case .segmentMarkFailed:
            return "Apple Watch couldn’t add that segment to the workout. The ride is still running, so you can try again."
        case .segmentMarkUnconfirmed:
            return "Apple Watch is still confirming that segment. You can pause or end the ride, but wait before marking another segment."
        case .segmentFinalizationPending:
            return "Open BikeComputer on Apple Watch to retry the pending segment or save the ride anyway."
        case .sessionFailed, .unknown, nil:
            return "Check BikeComputer on Apple Watch. No workout is saved or ended by iPhone alone."
        }
    }

    static func context(
        for presentation: WorkoutMirrorPresentationV1
    ) -> WorkoutErrorCopyContextV1 {
        if presentation.isWorkoutActive,
           presentation.sessionID != nil
                || presentation.confirmedSessionState == .running
                || presentation.confirmedSessionState == .paused
                || presentation.confirmedSessionState == .ending {
            return .activeWorkout
        }
        if presentation.connectionState == .failed,
           presentation.sessionID == nil,
           presentation.confirmedSessionState == nil {
            return .workoutLaunch
        }
        return .general
    }
}

nonisolated struct WorkoutIPhoneTelemetryV1: Equatable, Sendable {
    var isNavigating = false
    var capturedAt: Date?
    var navigationDistanceMeters: Double?
    var routeRemainingDistanceMeters: Double?
    var routeRemainingTime: TimeInterval?
    var instruction: String?
    var location: WorkoutLocationV1?

    static let empty = Self()
}

nonisolated struct WorkoutNavigationContextV1: Equatable, Sendable {
    let routeRemainingDistanceMeters: Double?
    let routeRemainingTime: TimeInterval?
    let instruction: String?

    static let empty = Self(
        routeRemainingDistanceMeters: nil,
        routeRemainingTime: nil,
        instruction: nil
    )
}

nonisolated struct WorkoutMirrorPresentationV1: Equatable, Sendable {
    let connectionState: WorkoutMirrorConnectionStateV1
    let snapshot: WorkoutSnapshotV1
    let sessionID: UUID?
    let capturedAt: Date?
    let receivedAt: Date?
    let confirmedSessionState: WorkoutSessionStateV1?
    let errorCode: WorkoutSafeErrorCodeV1?
    let pendingControl: WorkoutControlV1?
    let finalSnapshot: WorkoutSnapshotV1?
    let navigation: WorkoutNavigationContextV1

    static let idle = Self(
        connectionState: .idle,
        snapshot: WorkoutSnapshotV1(state: .idle),
        sessionID: nil,
        capturedAt: nil,
        receivedAt: nil,
        confirmedSessionState: nil,
        errorCode: nil,
        pendingControl: nil,
        finalSnapshot: nil,
        navigation: .empty
    )

    var sessionState: WorkoutSessionStateV1 {
        confirmedSessionState ?? snapshot.state
    }

    var isWorkoutActive: Bool {
        sessionState.isActive
    }

    var canStartNewWorkout: Bool {
        guard !isWorkoutActive, pendingControl == nil else { return false }
        switch connectionState {
        case .idle, .failed, .disconnected, .unsupported:
            return true
        case .launchingWatch, .awaitingFirstSnapshot, .connected, .stale, .ended:
            return false
        }
    }

    var shouldAutomaticallyResetAfterDiscard: Bool {
        guard connectionState == .ended,
              pendingControl == nil,
              errorCode == nil else {
            return false
        }
        return (finalSnapshot ?? snapshot).terminalOutcome == .discarded
    }

    func captureAge(at date: Date) -> TimeInterval? {
        capturedAt.map { max(0, date.timeIntervalSince($0)) }
    }
}

nonisolated enum WorkoutIPhoneTelemetryMerge {
    static let phoneLocationMaximumAge: TimeInterval = 10

    static func presentation(
        _ base: WorkoutMirrorPresentationV1,
        phone: WorkoutIPhoneTelemetryV1,
        at referenceDate: Date
    ) -> WorkoutMirrorPresentationV1 {
        let navigation = phone.isNavigating
            ? WorkoutNavigationContextV1(
                routeRemainingDistanceMeters: nonnegative(
                    phone.routeRemainingDistanceMeters
                ),
                routeRemainingTime: nonnegative(phone.routeRemainingTime),
                instruction: phone.instruction?.isEmpty == false
                    ? phone.instruction
                    : nil
            )
            : .empty
        let mergedSnapshot = base.isWorkoutActive
            ? mergeSnapshot(
                base.snapshot,
                phone: phone,
                at: referenceDate
            )
            : base.snapshot
        return WorkoutMirrorPresentationV1(
            connectionState: base.connectionState,
            snapshot: mergedSnapshot,
            sessionID: base.sessionID,
            capturedAt: base.capturedAt,
            receivedAt: base.receivedAt,
            confirmedSessionState: base.confirmedSessionState,
            errorCode: base.errorCode,
            pendingControl: base.pendingControl,
            finalSnapshot: base.finalSnapshot,
            navigation: navigation
        )
    }

    private static func mergeSnapshot(
        _ watch: WorkoutSnapshotV1,
        phone: WorkoutIPhoneTelemetryV1,
        at referenceDate: Date
    ) -> WorkoutSnapshotV1 {
        guard watch.state.isActive else { return watch }
        let capturedAt = validCaptureDate(
            phone.capturedAt,
            notBefore: watch.startDate
        ) ?? validCaptureDate(
            phone.location?.capturedAt,
            notBefore: watch.startDate
        )
        let phoneLocation = valid(
            phone.location,
            notBefore: watch.startDate,
            at: referenceDate,
            maximumAge: phoneLocationMaximumAge
        ) ? phone.location : nil

        let distance: WorkoutMetricV1?
        if let watchDistance = watch.cyclingDistance {
            distance = watchDistance
        } else if phone.isNavigating,
                  let value = nonnegative(phone.navigationDistanceMeters),
                  let capturedAt {
            distance = WorkoutMetricV1(
                value: value,
                unit: .meters,
                capturedAt: capturedAt,
                source: .iPhoneNavigation
            )
        } else {
            distance = nil
        }

        let speed: WorkoutMetricV1?
        if let watchSpeed = watch.currentSpeed {
            speed = watchSpeed
        } else if let value = nonnegative(phoneLocation?.speed),
                  let capturedAt = phoneLocation?.capturedAt {
            speed = WorkoutMetricV1(
                value: value,
                unit: .metersPerSecond,
                capturedAt: capturedAt,
                source: .iPhoneLocation
            )
        } else {
            speed = nil
        }

        let location = mergeLocation(
            watch.location,
            phoneLocation
        )
        var availability = watch.availability
        if distance != nil { availability.insert(.cyclingDistance) }
        if speed != nil { availability.insert(.currentSpeed) }
        if location != nil { availability.insert(.location) }
        if location?.altitude != nil { availability.insert(.altitude) }

        return WorkoutSnapshotV1(
            state: watch.state,
            startDate: watch.startDate,
            elapsedTime: watch.elapsedTime,
            currentHeartRate: watch.currentHeartRate,
            averageHeartRate: watch.averageHeartRate,
            activeEnergy: watch.activeEnergy,
            cyclingDistance: distance,
            currentSpeed: speed,
            cyclingPower: watch.cyclingPower,
            cyclingCadence: watch.cyclingCadence,
            currentHeartRateZone: watch.currentHeartRateZone,
            heartRateZoneCount: watch.heartRateZoneCount,
            heartRateZoneDurations: watch.heartRateZoneDurations,
            location: location,
            lastCompletedSegment: watch.lastCompletedSegment,
            availability: availability,
            errorCode: watch.errorCode,
            terminalOutcome: watch.terminalOutcome
        )
    }

    private static func mergeLocation(
        _ watch: WorkoutLocationV1?,
        _ phone: WorkoutLocationV1?
    ) -> WorkoutLocationV1? {
        guard let watch else { return valid(phone) ? phone : nil }
        guard watch.altitude == nil,
              let phone,
              valid(phone),
              let altitude = phone.altitude,
              let verticalAccuracy = phone.verticalAccuracy,
              abs(phone.capturedAt.timeIntervalSince(watch.capturedAt)) <= 5,
              coordinateDistanceMeters(watch, phone) <= max(
                  100,
                  watch.horizontalAccuracy + phone.horizontalAccuracy
              ) else {
            return watch
        }
        return WorkoutLocationV1(
            latitude: watch.latitude,
            longitude: watch.longitude,
            capturedAt: min(watch.capturedAt, phone.capturedAt),
            horizontalAccuracy: watch.horizontalAccuracy,
            altitude: altitude,
            verticalAccuracy: verticalAccuracy,
            course: watch.course,
            speed: watch.speed
        )
    }

    private static func valid(
        _ location: WorkoutLocationV1?,
        notBefore: Date? = nil,
        at referenceDate: Date? = nil,
        maximumAge: TimeInterval? = nil
    ) -> Bool {
        guard let location else { return false }
        return location.latitude.isFinite
            && (-90...90).contains(location.latitude)
            && location.longitude.isFinite
            && (-180...180).contains(location.longitude)
            && location.horizontalAccuracy.isFinite
            && location.horizontalAccuracy >= 0
            && location.capturedAt.timeIntervalSinceReferenceDate.isFinite
            && (location.speed.map { $0.isFinite && $0 >= 0 } ?? true)
            && (location.altitude.map(\.isFinite) ?? true)
            && (location.verticalAccuracy.map { $0.isFinite && $0 >= 0 } ?? true)
            && ((location.altitude == nil) == (location.verticalAccuracy == nil))
            && validCaptureDate(
                location.capturedAt,
                notBefore: notBefore
            ) != nil
            && freshIfRequired(
                location.capturedAt,
                at: referenceDate,
                maximumAge: maximumAge
            )
    }

    private static func validCaptureDate(
        _ value: Date?,
        notBefore: Date?
    ) -> Date? {
        guard let value,
              value.timeIntervalSinceReferenceDate.isFinite,
              notBefore.map({ value >= $0 }) ?? true else {
            return nil
        }
        return value
    }

    private static func freshIfRequired(
        _ capturedAt: Date,
        at referenceDate: Date?,
        maximumAge: TimeInterval?
    ) -> Bool {
        guard let referenceDate, let maximumAge else { return true }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              maximumAge.isFinite,
              maximumAge >= 0 else { return false }
        let age = referenceDate.timeIntervalSince(capturedAt)
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    private static func coordinateDistanceMeters(
        _ lhs: WorkoutLocationV1,
        _ rhs: WorkoutLocationV1
    ) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lhsLatitude = lhs.latitude * .pi / 180
        let rhsLatitude = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(lhsLatitude) * cos(rhsLatitude)
                * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// Pure state machine for the iPhone side of a Watch-owned mirrored workout.
/// HealthKit callbacks and timers are converted to these methods by
/// WorkoutMetricsStore, which publishes each resulting presentation atomically.
nonisolated struct WorkoutMirrorStateReducer: Sendable {
    static let defaultStartTimeout: TimeInterval = 15
    static let defaultStaleAfter: TimeInterval = 10
    static let maximumFutureCaptureSkew: TimeInterval = 2

    private(set) var connectionState: WorkoutMirrorConnectionStateV1 = .idle
    private(set) var latestEnvelope: WorkoutEnvelopeV1?
    private(set) var lastReceivedAt: Date?
    private(set) var confirmedSessionState: WorkoutSessionStateV1?
    private(set) var errorCode: WorkoutSafeErrorCodeV1?
    private(set) var commandErrorCode: WorkoutSafeErrorCodeV1?
    private(set) var pendingControl: WorkoutControlV1?
    private(set) var pendingControlSequence: UInt64?
    private var unconfirmedSegmentControlSequence: UInt64?
    private var timedOutTerminalControl: WorkoutControlV1?
    private var timedOutTerminalControlSequence: UInt64?
    private(set) var finalSnapshot: WorkoutSnapshotV1?
    private(set) var activeLaunchID: UUID?
    private(set) var launchDeadline: Date?
    private(set) var hasMirroredSession = false
    private(set) var sessionStateConfirmedAt: Date?

    private var sequenceGate = WorkoutEnvelopeSequenceGate()

    var presentation: WorkoutMirrorPresentationV1 {
        WorkoutMirrorPresentationV1(
            connectionState: connectionState,
            snapshot: latestEnvelope?.snapshot ?? WorkoutSnapshotV1(state: .idle),
            sessionID: latestEnvelope?.sessionID,
            capturedAt: latestEnvelope?.capturedAt,
            receivedAt: lastReceivedAt,
            confirmedSessionState: confirmedSessionState,
            errorCode: errorCode == .anotherWorkoutActive
                || latestEnvelope?.snapshot?.errorCode
                    == .anotherWorkoutActive
                ? .anotherWorkoutActive
                : latestEnvelope?.snapshot?.errorCode
                    ?? commandErrorCode
                    ?? errorCode,
            pendingControl: pendingControl,
            finalSnapshot: finalSnapshot,
            navigation: .empty
        )
    }

    var canResetTerminalPresentation: Bool {
        guard !presentation.isWorkoutActive,
              pendingControl == nil else { return false }
        guard connectionState == .ended else { return true }
        return finalSnapshot != nil
            || commandErrorCode == .terminalChoiceUnconfirmed
            || commandErrorCode == .finalSummaryUnavailable
    }

    var isSegmentConfirmationPending: Bool {
        unconfirmedSegmentControlSequence != nil
    }

    var currentUnconfirmedSegmentControlSequence: UInt64? {
        unconfirmedSegmentControlSequence
    }

    mutating func markUnsupported() {
        connectionState = .unsupported
        hasMirroredSession = false
        activeLaunchID = nil
        launchDeadline = nil
        errorCode = .watchUnavailable
        commandErrorCode = nil
        pendingControl = nil
        pendingControlSequence = nil
        unconfirmedSegmentControlSequence = nil
        clearTimedOutTerminalControl()
    }

    @discardableResult
    mutating func beginWatchLaunch(
        id: UUID,
        at date: Date,
        timeout: TimeInterval = Self.defaultStartTimeout
    ) -> Bool {
        guard presentation.canStartNewWorkout,
              timeout.isFinite,
              timeout > 0,
              connectionState != .launchingWatch else {
            return false
        }
        activeLaunchID = id
        launchDeadline = date.addingTimeInterval(timeout)
        connectionState = .launchingWatch
        hasMirroredSession = false
        latestEnvelope = nil
        lastReceivedAt = nil
        errorCode = nil
        commandErrorCode = nil
        pendingControl = nil
        pendingControlSequence = nil
        unconfirmedSegmentControlSequence = nil
        clearTimedOutTerminalControl()
        confirmedSessionState = .starting
        sessionStateConfirmedAt = date
        finalSnapshot = nil
        return true
    }

    @discardableResult
    mutating func completeWatchLaunch(
        id: UUID,
        succeeded: Bool,
        error: WorkoutSafeErrorCodeV1?
    ) -> Bool {
        guard activeLaunchID == id, !hasMirroredSession else { return false }
        guard succeeded else {
            activeLaunchID = nil
            launchDeadline = nil
            confirmedSessionState = nil
            sessionStateConfirmedAt = nil
            connectionState = .failed
            errorCode = error ?? .watchUnavailable
            return true
        }
        // Successful launch only means watchOS accepted the wake request. The
        // workout is not live until HealthKit delivers the mirrored session.
        connectionState = .launchingWatch
        return true
    }

    @discardableResult
    mutating func timeOutWatchLaunch(id: UUID, at date: Date) -> Bool {
        guard activeLaunchID == id,
              !hasMirroredSession,
              let launchDeadline,
              date >= launchDeadline else {
            return false
        }
        activeLaunchID = nil
        self.launchDeadline = nil
        confirmedSessionState = nil
        sessionStateConfirmedAt = nil
        connectionState = .failed
        errorCode = .setupRequired
        return true
    }

    mutating func attachMirroredSession(at date: Date) {
        let hasNativeActiveEvidence = confirmedSessionState == .running
            || confirmedSessionState == .paused
            || confirmedSessionState == .ending
        let isReconnectingActiveWorkout = presentation.isWorkoutActive
            && (latestEnvelope?.snapshot?.state.isActive == true
                || hasNativeActiveEvidence)
        if !isReconnectingActiveWorkout, activeLaunchID == nil {
            latestEnvelope = nil
            lastReceivedAt = nil
            confirmedSessionState = nil
            sessionStateConfirmedAt = nil
            finalSnapshot = nil
            pendingControl = nil
            pendingControlSequence = nil
            unconfirmedSegmentControlSequence = nil
            clearTimedOutTerminalControl()
        }
        hasMirroredSession = true
        activeLaunchID = nil
        launchDeadline = nil
        errorCode = nil
        if timedOutTerminalControl == nil,
           unconfirmedSegmentControlSequence == nil {
            commandErrorCode = nil
        }
        connectionState = .awaitingFirstSnapshot
    }

    @discardableResult
    mutating func timeOutFirstSnapshot() -> Bool {
        guard hasMirroredSession,
              connectionState == .awaitingFirstSnapshot else {
            return false
        }
        activeLaunchID = nil
        launchDeadline = nil
        let hasAuthoritativeActiveEvidence =
            latestEnvelope?.snapshot?.state.isActive == true
            || confirmedSessionState == .running
            || confirmedSessionState == .paused
            || confirmedSessionState == .ending
        if hasAuthoritativeActiveEvidence {
            // Native HealthKit state is authoritative evidence that the
            // Watch-owned workout exists even when the custom metric stream is
            // silent. Keep the transport attached so a late snapshot can
            // recover naturally, while withholding credentialed controls.
            connectionState = .disconnected
            errorCode = .watchUnavailable
        } else {
            hasMirroredSession = false
            confirmedSessionState = nil
            sessionStateConfirmedAt = nil
            connectionState = .failed
            errorCode = .setupRequired
        }
        return true
    }

    @discardableResult
    mutating func ingestBatch(
        _ envelopes: [WorkoutEnvelopeV1],
        receivedAt: Date
    ) -> WorkoutEnvelopeBatchResult {
        let latestAcceptedCaptureDate = receivedAt.addingTimeInterval(
            Self.maximumFutureCaptureSkew
        )
        var latestAcceptedSnapshot: WorkoutEnvelopeV1?
        var acceptedEnvelopes: [WorkoutEnvelopeV1] = []
        var rejections: [WorkoutEnvelopeBatchRejection] = []
        for (index, envelope) in envelopes.enumerated() {
            guard envelope.capturedAt <= latestAcceptedCaptureDate else {
                rejections.append(
                    WorkoutEnvelopeBatchRejection(
                        index: index,
                        error: .invalidDate
                    )
                )
                continue
            }
            do {
                if try sequenceGate.ingest(envelope) {
                    acceptedEnvelopes.append(envelope)
                    if envelope.snapshot != nil {
                        latestAcceptedSnapshot = envelope
                    }
                }
            } catch let error as WorkoutContractError {
                rejections.append(
                    WorkoutEnvelopeBatchRejection(index: index, error: error)
                )
            } catch {
                rejections.append(
                    WorkoutEnvelopeBatchRejection(
                        index: index,
                        error: .invalidEnvelopePayload
                    )
                )
            }
        }
        let result = WorkoutEnvelopeBatchResult(
            latestSnapshotEnvelope: latestAcceptedSnapshot,
            acceptedEnvelopes: acceptedEnvelopes,
            rejections: rejections
        )

        for envelope in result.acceptedEnvelopes {
            if let acknowledgement = envelope.acknowledgement,
               acknowledgementConfirmsPendingControl(
                   acknowledgement,
                   envelope: envelope
            ) {
                pendingControl = nil
                pendingControlSequence = nil
                if let acknowledgementError = acknowledgement.errorCode {
                    commandErrorCode = acknowledgementError
                    if acknowledgement.control == .markSegment,
                       acknowledgementError == .segmentMarkUnconfirmed {
                        unconfirmedSegmentControlSequence =
                            acknowledgement.acknowledgedSequence
                    } else if acknowledgement.control == .markSegment {
                        unconfirmedSegmentControlSequence = nil
                    }
                } else {
                    if timedOutTerminalControl == nil,
                       unconfirmedSegmentControlSequence == nil {
                        commandErrorCode = nil
                    }
                    if acknowledgement.control == .markSegment {
                        unconfirmedSegmentControlSequence = nil
                    }
                }
            } else if let acknowledgement = envelope.acknowledgement,
                      acknowledgementResolvesUnconfirmedSegmentControl(
                          acknowledgement,
                          envelope: envelope
                      ) {
                unconfirmedSegmentControlSequence = nil
                commandErrorCode = acknowledgement.errorCode
            } else if let acknowledgement = envelope.acknowledgement,
                      acknowledgementResolvesTimedOutTerminalControl(
                          acknowledgement,
                          envelope: envelope
                      ) {
                clearTimedOutTerminalControl()
                commandErrorCode = nil
            }
            if let remoteError = envelope.error {
                errorCode = WorkoutTerminalErrorPolicy.resolve(
                    summaryError: remoteError.code,
                    persistedFinishError: errorCode
                )
            }
        }

        guard let envelope = result.latestSnapshotEnvelope,
              let snapshot = envelope.snapshot else {
            return result
        }

        let previousSessionID = latestEnvelope?.sessionID
        if let previousSessionID, previousSessionID != envelope.sessionID {
            confirmedSessionState = nil
            sessionStateConfirmedAt = nil
            commandErrorCode = nil
            pendingControl = nil
            pendingControlSequence = nil
            unconfirmedSegmentControlSequence = nil
            clearTimedOutTerminalControl()
            finalSnapshot = nil
        }
        latestEnvelope = envelope
        lastReceivedAt = receivedAt
        if errorCode == .anotherWorkoutActive
            || snapshot.errorCode == .anotherWorkoutActive {
            errorCode = .anotherWorkoutActive
        } else {
            errorCode = snapshot.errorCode
        }

        let hasConfirmedTerminalState = confirmedSessionState == .ended
            || confirmedSessionState == .failed
        if snapshot.state == .ended || snapshot.state == .failed {
            // The Watch's terminal envelope is the authoritative outcome even
            // when iPhone first received a native session-failure callback.
            confirmedSessionState = snapshot.state
            sessionStateConfirmedAt = envelope.capturedAt
        } else if !hasConfirmedTerminalState,
           sessionStateConfirmedAt.map({ envelope.capturedAt >= $0 }) ?? true {
            confirmedSessionState = snapshot.state
            sessionStateConfirmedAt = envelope.capturedAt
        }
        clearConfirmedControlIfNeeded(
            for: presentation.sessionState,
            terminalOutcome: snapshot.terminalOutcome
        )
        reconcileTimedOutTerminalControl(
            for: presentation.sessionState,
            terminalOutcome: snapshot.terminalOutcome
        )

        switch snapshot.state {
        case .idle:
            connectionState = .idle
        case .starting, .running, .paused, .ending:
            refreshFreshness(at: receivedAt)
        case .ended:
            connectionState = .ended
            finalSnapshot = snapshot
            if commandErrorCode == .finalSummaryUnavailable {
                commandErrorCode = nil
            }
        case .failed:
            connectionState = .failed
            pendingControl = nil
            pendingControlSequence = nil
            clearTimedOutTerminalControl()
            errorCode = WorkoutTerminalErrorPolicy.resolve(
                summaryError: snapshot.errorCode ?? .sessionFailed,
                persistedFinishError: errorCode
            )
        }
        return result
    }

    mutating func clearTerminalFailureForNewSession() {
        errorCode = latestEnvelope?.snapshot?.errorCode
    }

    mutating func confirmSessionState(
        _ state: WorkoutSessionStateV1,
        at date: Date
    ) {
        guard sessionStateConfirmedAt.map({ date >= $0 }) ?? true else { return }
        confirmedSessionState = state
        sessionStateConfirmedAt = date
        clearConfirmedControlIfNeeded(for: state, terminalOutcome: nil)
        if (state == .running || state == .paused),
           timedOutTerminalControl == nil,
           unconfirmedSegmentControlSequence == nil {
            commandErrorCode = nil
        }

        switch state {
        case .ended:
            if latestEnvelope == nil
                || latestEnvelope?.snapshot?.state == .failed {
                // A mirrored session ending without a successful workout
                // snapshot is not evidence that a workout was saved. Preserve
                // the actionable failure instead of inventing a finished ride.
                confirmedSessionState = .failed
                connectionState = .failed
                pendingControl = nil
                pendingControlSequence = nil
                clearTimedOutTerminalControl()
                errorCode = latestEnvelope?.snapshot?.errorCode
                    ?? errorCode
                    ?? .sessionFailed
            } else {
                connectionState = .ended
                if timedOutTerminalControl != nil {
                    commandErrorCode = .terminalChoiceUnconfirmed
                }
            }
        case .failed:
            connectionState = .failed
            pendingControl = nil
            pendingControlSequence = nil
            clearTimedOutTerminalControl()
            errorCode = errorCode ?? .sessionFailed
        case .starting, .running, .paused, .ending:
            if hasMirroredSession {
                refreshFreshness(at: date)
            }
        case .idle:
            connectionState = .idle
        }
    }

    mutating func markPendingControl(
        _ control: WorkoutControlV1,
        sequence: UInt64? = nil
    ) -> Bool {
        guard pendingControl == nil,
              control != .markSegment
                || unconfirmedSegmentControlSequence == nil else {
            return false
        }
        pendingControl = control
        pendingControlSequence = sequence
        if control == .endAndSave || control == .discard {
            clearTimedOutTerminalControl()
            commandErrorCode = nil
        } else if timedOutTerminalControl == nil {
            commandErrorCode = nil
        }
        errorCode = nil
        return true
    }

    mutating func failPendingControl(
        _ control: WorkoutControlV1,
        sequence: UInt64? = nil,
        error: WorkoutSafeErrorCodeV1
    ) {
        guard pendingControl == control,
              pendingControlSequence == sequence else { return }
        if control == .endAndSave || control == .discard {
            timedOutTerminalControl = control
            timedOutTerminalControlSequence = sequence
        }
        pendingControl = nil
        pendingControlSequence = nil
        if control == .markSegment,
           error == .segmentMarkUnconfirmed {
            unconfirmedSegmentControlSequence = sequence
        }
        let preservesTimedOutTerminalChoice = timedOutTerminalControl != nil
            && control != .endAndSave
            && control != .discard
        if !preservesTimedOutTerminalChoice {
            if (control == .endAndSave || control == .discard),
               presentation.sessionState == .ended {
                commandErrorCode = .terminalChoiceUnconfirmed
            } else {
                commandErrorCode = error
            }
        }
        if !hasMirroredSession, presentation.sessionState != .ended {
            connectionState = .disconnected
        }
    }

    mutating func disconnect(error: WorkoutSafeErrorCodeV1?) {
        hasMirroredSession = false
        activeLaunchID = nil
        launchDeadline = nil
        if presentation.sessionState == .ended {
            connectionState = .ended
        } else if connectionState == .failed
                    || presentation.sessionState == .failed {
            connectionState = .failed
            errorCode = errorCode ?? error ?? .sessionFailed
        } else {
            connectionState = .disconnected
            errorCode = error ?? .watchUnavailable
        }
    }

    mutating func failSession(error: WorkoutSafeErrorCodeV1) {
        hasMirroredSession = false
        activeLaunchID = nil
        launchDeadline = nil
        pendingControl = nil
        pendingControlSequence = nil
        unconfirmedSegmentControlSequence = nil
        clearTimedOutTerminalControl()
        connectionState = .failed
        errorCode = error
        commandErrorCode = nil
        confirmedSessionState = .failed
    }

    mutating func awaitTerminalSnapshotAfterFailure(
        error: WorkoutSafeErrorCodeV1,
        at date: Date
    ) {
        activeLaunchID = nil
        launchDeadline = nil
        pendingControl = nil
        pendingControlSequence = nil
        unconfirmedSegmentControlSequence = nil
        clearTimedOutTerminalControl()
        connectionState = .connected
        errorCode = error
        commandErrorCode = nil
        confirmedSessionState = .ending
        sessionStateConfirmedAt = date
        hasMirroredSession = true
    }

    mutating func refreshFreshness(
        at date: Date,
        staleAfter: TimeInterval = Self.defaultStaleAfter
    ) {
        guard staleAfter.isFinite, staleAfter >= 0 else { return }
        guard hasMirroredSession,
              presentation.isWorkoutActive,
              let envelope = latestEnvelope,
              envelope.snapshot?.state.isActive == true else {
            return
        }
        connectionState = date.timeIntervalSince(envelope.capturedAt) > staleAfter
            ? .stale
            : .connected
    }

    @discardableResult
    mutating func timeOutFinalSnapshot() -> Bool {
        guard connectionState == .ended,
              finalSnapshot == nil,
              pendingControl == nil else { return false }
        commandErrorCode = .finalSummaryUnavailable
        return true
    }

    @discardableResult
    mutating func resetTerminalPresentation() -> Bool {
        guard canResetTerminalPresentation else { return false }
        sequenceGate.retireCurrentSession()
        connectionState = .idle
        latestEnvelope = nil
        lastReceivedAt = nil
        confirmedSessionState = nil
        sessionStateConfirmedAt = nil
        errorCode = nil
        commandErrorCode = nil
        pendingControl = nil
        pendingControlSequence = nil
        unconfirmedSegmentControlSequence = nil
        clearTimedOutTerminalControl()
        finalSnapshot = nil
        activeLaunchID = nil
        launchDeadline = nil
        hasMirroredSession = false
        return true
    }

    private func acknowledgementConfirmsPendingControl(
        _ acknowledgement: WorkoutAcknowledgementV1,
        envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let current = latestEnvelope,
              envelope.sessionID == current.sessionID,
              envelope.sessionToken == current.sessionToken,
              envelope.transportGenerationID
                == current.transportGenerationID,
              acknowledgement.control == pendingControl,
              acknowledgement.acknowledgedSequence
                == pendingControlSequence else {
            return false
        }
        switch acknowledgement.control {
        case .pause:
            return acknowledgement.errorCode == nil
                && acknowledgement.resultingState == .paused
        case .resume:
            return acknowledgement.errorCode == nil
                && acknowledgement.resultingState == .running
        case .markSegment:
            return [
                WorkoutSessionStateV1.running,
                .paused,
                .ending,
                .ended,
            ].contains(acknowledgement.resultingState)
                && (acknowledgement.errorCode == nil
                    || acknowledgement.errorCode == .segmentMarkFailed
                    || acknowledgement.errorCode == .segmentMarkUnconfirmed)
        case .endAndSave, .discard:
            return acknowledgement.errorCode == nil
                && (acknowledgement.resultingState == .ending
                    || acknowledgement.resultingState == .ended)
        case .requestCurrentSnapshot:
            return acknowledgement.errorCode == nil
        }
    }

    private func acknowledgementResolvesUnconfirmedSegmentControl(
        _ acknowledgement: WorkoutAcknowledgementV1,
        envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let current = latestEnvelope,
              envelope.sessionID == current.sessionID,
              envelope.sessionToken == current.sessionToken,
              envelope.transportGenerationID
                == current.transportGenerationID,
              acknowledgement.control == .markSegment,
              acknowledgement.acknowledgedSequence
                == unconfirmedSegmentControlSequence else {
            return false
        }
        return acknowledgement.errorCode == nil
            || acknowledgement.errorCode == .segmentMarkFailed
    }

    private func acknowledgementResolvesTimedOutTerminalControl(
        _ acknowledgement: WorkoutAcknowledgementV1,
        envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let current = latestEnvelope,
              envelope.sessionID == current.sessionID,
              envelope.sessionToken == current.sessionToken,
              envelope.transportGenerationID
                == current.transportGenerationID,
              acknowledgement.control == timedOutTerminalControl,
              acknowledgement.acknowledgedSequence
                == timedOutTerminalControlSequence else {
            return false
        }
        return acknowledgement.resultingState == .ending
            || acknowledgement.resultingState == .ended
    }

    private mutating func clearConfirmedControlIfNeeded(
        for state: WorkoutSessionStateV1,
        terminalOutcome: WorkoutTerminalOutcomeV1?
    ) {
        switch (pendingControl, state, terminalOutcome) {
        case (.pause?, .paused, _),
             (.pause?, .ended, _),
             (.resume?, .running, _),
             (.resume?, .ended, _),
             (.endAndSave?, .ended, .saved?),
             (.discard?, .ended, .discarded?),
             (.requestCurrentSnapshot?, _, _):
            pendingControl = nil
            pendingControlSequence = nil
            if timedOutTerminalControl == nil {
                if unconfirmedSegmentControlSequence == nil {
                    commandErrorCode = nil
                }
            }
        case (.endAndSave?, .ended, .discarded?),
             (.discard?, .ended, .saved?):
            pendingControl = nil
            pendingControlSequence = nil
            commandErrorCode = .terminalChoiceConflict
        default:
            break
        }
    }

    private mutating func reconcileTimedOutTerminalControl(
        for state: WorkoutSessionStateV1,
        terminalOutcome: WorkoutTerminalOutcomeV1?
    ) {
        guard state == .ended,
              let timedOutTerminalControl,
              let terminalOutcome else {
            return
        }
        switch (timedOutTerminalControl, terminalOutcome) {
        case (.endAndSave, .saved), (.discard, .discarded):
            commandErrorCode = nil
        case (.endAndSave, .discarded), (.discard, .saved):
            commandErrorCode = .terminalChoiceConflict
        default:
            return
        }
        clearTimedOutTerminalControl()
    }

    private mutating func clearTimedOutTerminalControl() {
        timedOutTerminalControl = nil
        timedOutTerminalControlSequence = nil
    }
}

/// Keeps at most one in-flight Watch-to-iPhone envelope, coalesces pending
/// snapshots to the newest complete value, and retains ordered control
/// acknowledgements so snapshots cannot starve command confirmation.
nonisolated struct WorkoutLatestEnvelopeBuffer: Equatable, Sendable {
    private(set) var inFlight: WorkoutEnvelopeV1?
    private var pendingSnapshot: WorkoutEnvelopeV1?
    private var pendingMessages: [WorkoutEnvelopeV1] = []

    var pending: WorkoutEnvelopeV1? {
        nextPendingEnvelope
    }

    mutating func offer(_ envelope: WorkoutEnvelopeV1) {
        guard inFlight.map({ envelope.sequence > $0.sequence }) ?? true else {
            return
        }
        if envelope.snapshot != nil {
            guard isNewerSnapshot(envelope, than: pendingSnapshot) else {
                return
            }
            pendingSnapshot = envelope
        } else if !pendingMessages.contains(where: {
            $0.sessionID == envelope.sessionID
                && $0.sequence == envelope.sequence
        }) {
            pendingMessages.append(envelope)
            pendingMessages.sort { $0.sequence < $1.sequence }
        }
    }

    mutating func beginNext() -> WorkoutEnvelopeV1? {
        guard inFlight == nil, let next = nextPendingEnvelope else { return nil }
        if pendingSnapshot == next {
            pendingSnapshot = nil
        } else if let index = pendingMessages.firstIndex(of: next) {
            pendingMessages.remove(at: index)
        }
        inFlight = next
        return next
    }

    mutating func complete(succeeded: Bool) {
        guard let completed = inFlight else { return }
        inFlight = nil
        if !succeeded {
            offer(completed)
        }
    }

    mutating func interruptInFlight() {
        guard let interrupted = inFlight else { return }
        inFlight = nil
        offer(interrupted)
    }

    /// Abandons older live traffic so the final ended/failed snapshot is the
    /// envelope actually handed to HealthKit during the bounded shutdown
    /// window. Any eventual completion for the superseded send is ignored by
    /// the manager's attempt identifier.
    @discardableResult
    mutating func prioritizeShutdownEnvelope(
        _ envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard envelope.snapshot.map({
            $0.state == .ended || $0.state == .failed
        }) == true else {
            return false
        }
        if inFlight == envelope {
            pendingSnapshot = nil
            pendingMessages.removeAll()
            return false
        }
        let abandonedInFlight = inFlight != nil
        inFlight = nil
        pendingSnapshot = nil
        pendingMessages.removeAll()
        offer(envelope)
        return abandonedInFlight
    }

    mutating func reset() {
        inFlight = nil
        pendingSnapshot = nil
        pendingMessages.removeAll()
    }

    private var nextPendingEnvelope: WorkoutEnvelopeV1? {
        [pendingSnapshot, pendingMessages.first]
            .compactMap { $0 }
            .min { $0.sequence < $1.sequence }
    }

    private func isNewerSnapshot(
        _ candidate: WorkoutEnvelopeV1,
        than current: WorkoutEnvelopeV1?
    ) -> Bool {
        guard let current else { return true }
        if candidate.capturedAt != current.capturedAt {
            return candidate.capturedAt > current.capturedAt
        }
        return candidate.sequence > current.sequence
    }
}
