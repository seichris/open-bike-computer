import Foundation

enum RideBLEATTWriteClassV1: Equatable, Sendable {
    case authentication
    case criticalApplication
    case transferControl
    case replaceableSnapshot
    case other
}

enum RideBLEATTTimeoutRecoveryV1: Equatable, Sendable {
    /// Discard connection-scoped protected bytes, reconnect, reauthenticate,
    /// reacquire the lease, and regenerate retained logical state.
    case reconnectAndResynchronize
    /// Authentication has no safe ride-state resync boundary; fail the current
    /// handshake and begin a fresh connection generation.
    case restartAuthentication
}

/// Conservative production bounds shared by the owner iPhone and scoped
/// Watch. These values are intentionally visible and diagnostic latency is
/// recorded so physical evidence can tune them without reintroducing an
/// unbounded wait or an unsafe same-generation retry.
struct RideBLEATTWatchdogPolicyV1 {
    static let minimumTimeoutSeconds: TimeInterval = 5
    static let maximumTimeoutSeconds: TimeInterval = 15

    static func timeoutSeconds(
        for writeClass: RideBLEATTWriteClassV1
    ) -> TimeInterval {
        switch writeClass {
        case .authentication: return 10
        case .criticalApplication: return 8
        case .transferControl: return maximumTimeoutSeconds
        case .replaceableSnapshot, .other: return minimumTimeoutSeconds
        }
    }

    static func recovery(
        for writeClass: RideBLEATTWriteClassV1
    ) -> RideBLEATTTimeoutRecoveryV1 {
        writeClass == .authentication
            ? .restartAuthentication
            : .reconnectAndResynchronize
    }
}

enum RideBLEControllerRoleV1: String, Equatable, Sendable {
    case ownerPhone
    case scopedWatch
}

enum RideBLETransportPhaseV1: String, Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case negotiating
    case ready
    case stopping
    case recovering
}

/// Shutdown is a connection-lifecycle boundary, not a second adapter Boolean.
/// The old peripheral must finish cancellation before a successor can reuse it.
enum RideBLEStopStageV1: Equatable, Sendable {
    case releasingLease
    case awaitingDisconnect
}

enum RideBLEWriterStateV1: Equatable, Sendable {
    case idle
    case waitingForWithoutResponseReadiness
    case waitingForATTResponse(writeID: UInt64)
    case waitingForApplicationAcknowledgement(commandID: UUID)
    case recovering(reason: RideBLETransportFailureReasonV1)
}

enum RideBLETransportFailureReasonV1: String, Equatable, Sendable {
    case radioUnavailable
    case connectionFailed
    case authenticationFailed
    case leaseBusy
    case leaseLost
    case capabilityRejected
    case attTimeout
    case writeBackpressure
    case applicationTimeout
    case applicationRejected
    case criticalAdmissionFailed
    case remoteDisconnect
}

enum RideBLETransportEventV1: Equatable, Sendable {
    case beginConnection
    case linkConnected(generation: UInt64)
    case authenticated(generation: UInt64)
    case leaseAccepted(generation: UInt64, leaseGeneration: UInt32)
    case capabilitiesAccepted(generation: UInt64, schemaVersion: UInt8)
    case writerChanged(generation: UInt64, state: RideBLEWriterStateV1)
    case stopRequested(generation: UInt64)
    case leaseReleased(generation: UInt64)
    case disconnectRequested(generation: UInt64)
    case failed(generation: UInt64, reason: RideBLETransportFailureReasonV1)
    case disconnected(generation: UInt64)
}

enum RideBLETransportTransitionV1: Equatable, Sendable {
    case applied
    case becameReady
    case leftReady
    case ignoredStaleGeneration
    case rejectedInvalidTransition
}

/// Pure connection/readiness reducer shared by the owner iPhone and scoped
/// Watch adapters. CoreBluetooth objects, clocks, persistence, and UI state stay
/// outside this type; all asynchronous callbacks must carry the generation
/// captured when their operation began.
struct RideBLETransportStateMachineV1: Equatable, Sendable {
    let role: RideBLEControllerRoleV1
    private(set) var generation: UInt64 = 0
    private(set) var phase: RideBLETransportPhaseV1 = .idle
    private(set) var stopStage: RideBLEStopStageV1?
    private(set) var isLinkConnected = false
    private(set) var isAuthenticated = false
    private(set) var leaseGeneration: UInt32?
    private(set) var capabilitySchemaVersion: UInt8?
    private(set) var writerState: RideBLEWriterStateV1 = .idle
    private(set) var lastFailure: RideBLETransportFailureReasonV1?

    var isReady: Bool {
        phase == .ready && isLinkConnected && isAuthenticated &&
            leaseGeneration != nil && capabilitySchemaVersion != nil &&
            !writerIsRecovering
    }

    var acceptsReadinessCallbacks: Bool {
        phase == .negotiating || phase == .ready
    }

    var acceptsWriterCallbacks: Bool {
        phase != .idle && phase != .recovering &&
            stopStage != .awaitingDisconnect
    }

    private var writerIsRecovering: Bool {
        if case .recovering = writerState { return true }
        return false
    }

    init(role: RideBLEControllerRoleV1) {
        self.role = role
    }

    @discardableResult
    mutating func reduce(
        _ event: RideBLETransportEventV1
    ) -> RideBLETransportTransitionV1 {
        let wasReady = isReady
        let applied: Bool
        switch event {
        case .beginConnection:
            guard phase != .stopping else {
                return .rejectedInvalidTransition
            }
            generation &+= 1
            resetConnectionState(phase: .connecting)
            applied = true

        case .linkConnected(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard phase == .connecting else {
                return .rejectedInvalidTransition
            }
            isLinkConnected = true
            phase = .authenticating
            applied = true

        case .authenticated(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard isLinkConnected,
                  phase == .authenticating else {
                return .rejectedInvalidTransition
            }
            isAuthenticated = true
            phase = .negotiating
            applied = true

        case .leaseAccepted(let eventGeneration, let leaseGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard acceptsReadinessCallbacks,
                  isAuthenticated, leaseGeneration != 0,
                  phase != .ready || self.leaseGeneration == leaseGeneration else {
                return .rejectedInvalidTransition
            }
            self.leaseGeneration = leaseGeneration
            applied = true

        case .capabilitiesAccepted(
            let eventGeneration,
            let schemaVersion
        ):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard acceptsReadinessCallbacks,
                  isAuthenticated,
                  leaseGeneration != nil,
                  schemaVersion != 0 else {
                return .rejectedInvalidTransition
            }
            capabilitySchemaVersion = schemaVersion
            phase = .ready
            applied = true

        case .writerChanged(let eventGeneration, let state):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard acceptsWriterCallbacks else {
                return .rejectedInvalidTransition
            }
            writerState = state
            if case .recovering(let reason) = state {
                phase = .recovering
                stopStage = nil
                lastFailure = reason
            }
            applied = true

        case .stopRequested(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            // Phone preparation and scanning can need shutdown even before
            // a BLE connection exists. Repeated stops must not rewind an
            // in-progress peripheral cancellation.
            if phase != .stopping {
                phase = .stopping
                stopStage = .releasingLease
            }
            applied = true

        case .leaseReleased(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard phase == .stopping, stopStage == .releasingLease else {
                return .rejectedInvalidTransition
            }
            leaseGeneration = nil
            applied = true

        case .disconnectRequested(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard phase == .stopping else {
                return .rejectedInvalidTransition
            }
            stopStage = .awaitingDisconnect
            applied = true

        case .failed(let eventGeneration, let reason):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            guard phase != .idle else {
                return .rejectedInvalidTransition
            }
            phase = .recovering
            stopStage = nil
            writerState = .recovering(reason: reason)
            lastFailure = reason
            applied = true

        case .disconnected(let eventGeneration):
            guard eventGeneration == generation else {
                return .ignoredStaleGeneration
            }
            generation &+= 1
            resetConnectionState(phase: .idle)
            applied = true
        }
        guard applied else { return .rejectedInvalidTransition }
        if !wasReady && isReady { return .becameReady }
        if wasReady && !isReady { return .leftReady }
        return .applied
    }

    private mutating func resetConnectionState(
        phase: RideBLETransportPhaseV1
    ) {
        self.phase = phase
        stopStage = nil
        isLinkConnected = false
        isAuthenticated = false
        leaseGeneration = nil
        capabilitySchemaVersion = nil
        writerState = .idle
        lastFailure = nil
    }
}
