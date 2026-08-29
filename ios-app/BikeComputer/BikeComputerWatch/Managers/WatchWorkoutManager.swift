import Combine
import CoreLocation
import Foundation
import HealthKit
import WatchKit

enum WatchWorkoutSetupState: Equatable {
    case checking
    case needsAuthorization
    case authorizing
    case ready
    case denied
    case unavailable
    case failed
}

enum WatchWorkoutFinishRequestError: Equatable {
    case persistenceFailed
    case terminalErrorPersistenceFailed
    case saveFailed
    case reconciliationFailed
    case identityMetadataFailed
    case segmentConfirmationPending
}

enum WatchWorkoutCleanupState: Equatable {
    case none
    case delivering
    case retrying
    case retryRequired
}

enum WatchWorkoutSegmentError: Equatable {
    case unavailable
    case healthKitWriteFailed
    case confirmationPending
}

struct WatchWorkoutSummary: Equatable {
    enum Outcome: Equatable {
        case saved
        case discarded
    }

    let outcome: Outcome
    let endedAt: Date
    let duration: TimeInterval?
    let distanceMeters: Double?
    let activeEnergyKilocalories: Double?
    let averageHeartRate: Double?
    let routeStatus: WorkoutRouteSaveStatus
    let terminalErrorCode: WorkoutSafeErrorCodeV1?

    init(
        outcome: Outcome,
        endedAt: Date,
        duration: TimeInterval?,
        distanceMeters: Double?,
        activeEnergyKilocalories: Double?,
        averageHeartRate: Double?,
        routeStatus: WorkoutRouteSaveStatus,
        terminalErrorCode: WorkoutSafeErrorCodeV1? = nil
    ) {
        self.outcome = outcome
        self.endedAt = endedAt
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.averageHeartRate = averageHeartRate
        self.routeStatus = routeStatus
        self.terminalErrorCode = terminalErrorCode
    }
}

struct RecoveredSaveResolution {
    let action: WorkoutRecoveredSaveAction
    let workout: HKWorkout?
}

struct WatchRecoveredWorkoutIdentityAdapter {
    let metadata: () -> [String: Any]
    let startDate: Date
    let sessionState: () -> HKWorkoutSessionState
    let endDate: () -> Date?
    let attachMetadata: ([String: Any]) async throws -> Void

    init(
        metadata: @escaping () -> [String: Any],
        startDate: Date,
        sessionState: @escaping () -> HKWorkoutSessionState,
        endDate: @escaping () -> Date? = { nil },
        attachMetadata: @escaping ([String: Any]) async throws -> Void
    ) {
        self.metadata = metadata
        self.startDate = startDate
        self.sessionState = sessionState
        self.endDate = endDate
        self.attachMetadata = attachMetadata
    }
}

struct WatchRecoveredDiscardSessionAdapter {
    let stopSession: (Date) -> Void
    let finalizeStoppedSession: (Date) -> Void
}

struct WatchRecoveredDiscardFinalizationAdapter {
    let metadata: () -> [String: Any]
    let discardWorkout: () -> Void
    let discardRoute: () -> Void
    let endSession: () -> Void

    init(
        metadata: @escaping () -> [String: Any] = { [:] },
        discardWorkout: @escaping () -> Void,
        discardRoute: @escaping () -> Void,
        endSession: @escaping () -> Void
    ) {
        self.metadata = metadata
        self.discardWorkout = discardWorkout
        self.discardRoute = discardRoute
        self.endSession = endSession
    }
}

struct WatchRecoveredSaveRuntimeAdapter {
    let session: HKWorkoutSession
    let builder: HKLiveWorkoutBuilder
    let sessionState: () -> HKWorkoutSessionState
    let externalUUID: (() -> String?)?
    let builderCollectionEnded: (() -> Bool)?

    init(
        session: HKWorkoutSession,
        builder: HKLiveWorkoutBuilder,
        sessionState: @escaping () -> HKWorkoutSessionState,
        externalUUID: (() -> String?)? = nil,
        builderCollectionEnded: (() -> Bool)? = nil
    ) {
        self.session = session
        self.builder = builder
        self.sessionState = sessionState
        self.externalUUID = externalUUID
        self.builderCollectionEnded = builderCollectionEnded
    }
}

/// The only transitions available while retiring a terminal-tombstoned
/// HealthKit session. The adapter exposes no builder-save API; a retained
/// discard disposition is handled by the completion path only.
struct WatchTerminalSessionCleanupAdapter {
    let stopSession: (Date) -> Void
    let completeSession: (WorkoutFinishDisposition) -> Void
}

/// Testable production boundary for a recovered HealthKit session that may
/// already have a terminal tombstone. It intentionally exposes no save API.
struct WatchRecoveredTerminalSessionAdapter {
    let metadata: () -> [String: Any]
    let startDate: Date?
    let sessionState: () -> HKWorkoutSessionState
    let attachRuntime: () -> Void
    let stopSession: (Date) -> Void
    let discardWorkout: () -> Void
    let endSession: () -> Void
    let releaseSession: () -> Void
}

struct WatchWorkoutSetupProgress: Equatable {
    private(set) var collectionStarted = false
    private(set) var identityMetadataAttached = false

    var canFinalize: Bool {
        collectionStarted && identityMetadataAttached
    }

    mutating func markCollectionStarted() {
        collectionStarted = true
    }

    mutating func markIdentityMetadataAttached() {
        guard collectionStarted else { return }
        identityMetadataAttached = true
    }
}

enum WatchWorkoutIdentityMetadataOutcome {
    case ready
    case failStart(Error)
    case retainForFinishRetry(Error)
}

/// Owns the asynchronous identity-metadata boundary. The lifecycle is read
/// only after the HealthKit call completes, so a quick End action that occurs
/// while that call is suspended cannot be mistaken for an ordinary startup
/// failure.
struct WatchWorkoutIdentityMetadataCoordinator {
    static func attach(
        collectionStarted: Bool,
        attachMetadata: () async throws -> Void,
        lifecycleState: () -> WorkoutSessionStateV1,
        finishDisposition: () -> WorkoutFinishDisposition?
    ) async -> WatchWorkoutIdentityMetadataOutcome {
        do {
            try await attachMetadata()
            return .ready
        } catch {
            guard collectionStarted,
                  lifecycleState() == .ending else {
                return .failStart(error)
            }
            switch finishDisposition() {
            case .save, .discard:
                return .retainForFinishRetry(error)
            case nil:
                return .failStart(error)
            }
        }
    }
}

struct WatchWorkoutIdentityMetadataRetryAdapter {
    let attachMetadata: () async throws -> Void
    let isContextCurrent: () -> Bool
    let resumeFinalization: () -> Void
}

struct WatchRecoverySignalQueue: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isPendingWhileSessionAttached = false

    mutating func recordSignal(hasAttachedSession: Bool) -> Bool {
        generation &+= 1
        if hasAttachedSession {
            isPendingWhileSessionAttached = true
            return false
        }
        return true
    }

    mutating func consumeAfterSessionRelease() -> Bool {
        guard isPendingWhileSessionAttached else { return false }
        isPendingWhileSessionAttached = false
        return true
    }
}

struct WatchFinishFailureRollbackCoordinator {
    static func persistBeforeRetry(
        isPending: inout Bool,
        markFinishFailed: () throws -> Void
    ) -> Bool {
        guard isPending else { return true }
        do {
            try markFinishFailed()
            isPending = false
            return true
        } catch {
            return false
        }
    }
}

struct WatchTerminalPublicationCoordinator {
    @discardableResult
    static func perform(
        publishTerminal: () -> Bool,
        archiveIdentity: () -> Void
    ) -> Bool {
        guard publishTerminal() else { return false }
        archiveIdentity()
        return true
    }
}

struct WatchRecoveredSaveReconciliationGate: Equatable {
    private(set) var isInProgress = false

    var allowsFinalization: Bool { !isInProgress }

    mutating func begin() -> Bool {
        guard !isInProgress else { return false }
        isInProgress = true
        return true
    }

    mutating func end() {
        isInProgress = false
    }
}

typealias WatchMirrorStartOperation = @MainActor (
    HKWorkoutSession,
    @escaping @Sendable (Bool, Error?) -> Void
) -> Void

typealias WatchMirrorSendOperation = @MainActor (
    HKWorkoutSession,
    Data,
    @escaping @Sendable (Bool, Error?) -> Void
) -> Void

typealias WatchSegmentEventOperation = @MainActor (
    HKWorkoutEvent
) async throws -> Void

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    private static let maxTerminalCleanupRetryAttempts = 3
    private static let defaultWorkoutLaunchRequestLifetime: TimeInterval = 30

    private enum RideDetectionMirrorKey {
        static let payload = "rideDetection.watchMirror.v1"
        static let generation = "rideDetection.watchMirrorGeneration.v1"
    }
    private enum SegmentMetadataKey {
        static let origin = "com.openbikecomputer.workout.segment.origin"
        static let index = "com.openbikecomputer.workout.segment.index"
        static let activeDuration =
            "com.openbikecomputer.workout.segment.activeDuration"
        static let distanceMeters =
            "com.openbikecomputer.workout.segment.distanceMeters"
        static let cumulativeElapsed =
            "com.openbikecomputer.workout.segment.cumulativeElapsed"
        static let cumulativeDistance =
            "com.openbikecomputer.workout.segment.cumulativeDistance"
        static let cumulativeDistanceSource =
            "com.openbikecomputer.workout.segment.cumulativeDistanceSource"
        static let eventID =
            "com.openbikecomputer.workout.segment.eventID"
        static let controlSenderID =
            "com.openbikecomputer.workout.segment.controlSenderID"
        static let controlSequence =
            "com.openbikecomputer.workout.segment.controlSequence"
        static let originValue = "BikeComputer"
    }

    private enum RideTransitionMetadataKey {
        static let marker = "com.openbikecomputer.workout.rideTransition"
        static let schema = "com.openbikecomputer.workout.rideTransition.schema"
        static let transition =
            "com.openbikecomputer.workout.rideTransition.transition"
        static let origin =
            "com.openbikecomputer.workout.rideTransition.origin"
        static let rideGeneration =
            "com.openbikecomputer.workout.rideTransition.rideGeneration"
        static let decisionSequence =
            "com.openbikecomputer.workout.rideTransition.decisionSequence"
        static let profileVersion =
            "com.openbikecomputer.workout.rideTransition.profileVersion"
    }

    private enum SegmentEventWriteOutcome: Equatable, Sendable {
        case success
        case failure
    }

    private struct RemoteSegmentControlContext {
        let envelope: WorkoutEnvelopeV1
    }

    private enum ConfirmedTerminalCompletion {
        case saved(summary: WatchWorkoutSummary, at: Date)
        case discarded(summary: WatchWorkoutSummary, at: Date)
    }

    @Published private(set) var setupState: WatchWorkoutSetupState = .checking {
        didSet {
            if [.denied, .unavailable, .failed].contains(setupState) {
                clearPendingWorkoutLaunchRequest()
            }
        }
    }
    @Published private(set) var canWriteWorkoutRoute = false
    @Published private(set) var snapshot = WorkoutSnapshotV1(state: .idle)
    @Published private(set) var latestEnvelope: WorkoutEnvelopeV1?
    @Published private(set) var summary: WatchWorkoutSummary?
    @Published private(set) var locationAuthorizationState: WatchRouteRecorder.AuthorizationState
    @Published private(set) var isRecovering = true
    @Published private(set) var finishRequestError: WatchWorkoutFinishRequestError? = nil
    @Published private(set) var isTerminalArchivePending = false
    @Published private(set) var isTerminalPublicationPending = false
    @Published private(set) var isTerminalMirrorDeliveryPending = false
    @Published private(set) var isStartFailureMirrorDeliveryPending = false
    @Published private(set) var isTerminalCleanupRetrying = false
    @Published private(set) var maximumHeartRateBPM: Int
    @Published private(set) var rideDetectionSettings: RideDetectionSettings
    @Published private(set) var rideDetectionSettingsGeneration: UInt32
    @Published private(set) var rideDetectionSettingsConfirmed = false
    @Published private(set) var isMarkingSegment = false
    @Published private(set) var segmentError: WatchWorkoutSegmentError?
    @Published private(set) var pendingWorkoutLaunchRequest:
        PendingWorkoutLaunchRequest? = nil
    @Published private(set) var rejectedWorkoutLaunchURLCount: UInt64 = 0

    private let healthStore: HKHealthStore
    private let routeRecorder: WatchRouteRecorder
    private let recoveryStore: WatchWorkoutRecoveryStore
    private let heartRateZoneDefaults: UserDefaults
    private let injectedRecoveryOperation: (
        @MainActor () async -> (session: HKWorkoutSession?, error: Error?)
    )?
    private let injectedAuthorizationRequestOperation:
        (@MainActor () async throws -> Void)?
    private let injectedAuthorizationRefreshOperation: (@MainActor () async -> Void)?
    private let injectedAuthorizationRefreshState: WatchWorkoutSetupState?
    private let injectedDetachedRecoveryPause: (@MainActor () async -> Void)?
    private let injectedIdentityMetadataRetryAdapter:
        WatchWorkoutIdentityMetadataRetryAdapter?
    private let injectedRecoveredSaveRuntimeAdapter:
        WatchRecoveredSaveRuntimeAdapter?
    private let injectedRecoveredSaveResolver: (
        @MainActor (
            HKLiveWorkoutBuilder,
            WatchWorkoutRecoveryStore.Identity
        ) async -> RecoveredSaveResolution
    )?
    private let injectedSavedWorkoutLookup: (
        @MainActor (String, Date) async throws -> HKWorkout?
    )?
    private let injectedBuilderElapsedTime:
        (@MainActor (HKLiveWorkoutBuilder?) -> TimeInterval)?
    private let injectedFinalizationClaimObserver:
        ((WorkoutSaveFinalizationMode?) -> Void)?
    private let injectedRecoveredDiscardFinalizationAdapter:
        WatchRecoveredDiscardFinalizationAdapter?
    private let injectedWorkoutConfigurationHandler:
        (@MainActor (HKWorkoutConfiguration) -> Void)?
    private let injectedComplicationStartOperation:
        (@MainActor () async -> Void)?
    private let injectedRemotePauseOperation:
        (@MainActor (HKWorkoutSession) -> Void)?
    private let injectedRemoteResumeOperation:
        (@MainActor (HKWorkoutSession) -> Void)?
    private let injectedSegmentEventOperation: WatchSegmentEventOperation?
    private let injectedRideTransitionEventOperation:
        WatchSegmentEventOperation?
    private let injectedEndCollectionOperation:
        (@MainActor (HKLiveWorkoutBuilder, Date) async throws -> Void)?
    private let injectedFinishWorkoutOperation:
        (@MainActor (HKLiveWorkoutBuilder) async throws -> Void)?
    private let segmentNow: @MainActor () -> Date
    private let segmentWriteTimeout: TimeInterval
    private let injectedMirrorStartOperation: WatchMirrorStartOperation?
    private let injectedMirrorSendOperation: WatchMirrorSendOperation?
    private let injectedMirrorShutdownEndSession: (
        @MainActor (HKWorkoutSession) -> Void
    )?
    private let mirrorRetryDelay: TimeInterval
    private let mirrorShutdownDeliveryTimeout: TimeInterval
    private let terminalCleanupRetryDelay: TimeInterval
    private let workoutLaunchRequestLifetime: TimeInterval
    private var cancellables: Set<AnyCancellable> = []

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var lifecycle = WorkoutLifecycleReducer()
    private var identity: WatchWorkoutRecoveryStore.Identity?
    private var periodicSnapshotTask: Task<Void, Never>?
    private var coalescedSnapshotTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var mirrorRetryTask: Task<Void, Never>?
    private var mirrorShutdownWatchdogTask: Task<Void, Never>?
    private var complicationStartTask: Task<Void, Never>?
    private var workoutLaunchRequestExpiryTask: Task<Void, Never>?
    private var authorizationRefreshTask: Task<Void, Never>?
    private var segmentOperationTask: Task<Void, Never>?
    private var segmentOperationTimeoutTask: Task<Void, Never>?
    private var segmentOperationAttemptID: UUID?
    private var finalSegmentOperationTask: Task<Void, Never>?
    private var finalSegmentOperationAttemptID: UUID?
    private var hasAttemptedFinalSegmentClosure = false
    private var allowsSavingWithUnconfirmedSegment = false
    private var authoritativeFinalizationEndDate: Date?
    private var isBuilderReadyForFinalization = false
    private var isIdentityMetadataRetryPending = false
    private var requiresRecoveredSaveReconciliation = false
    private var recoveredSaveMode: WorkoutSaveFinalizationMode?
    private var reconciledSavedWorkout: HKWorkout?
    private var preparedRouteForFinalization: WorkoutPreparedRoute?
    private var terminalCleanupSessionID: UUID?
    private var terminalCleanupDisposition: WorkoutFinishDisposition?
    private var confirmedTerminalSummarySessionID: UUID?
    private var confirmedTerminalSnapshot: WorkoutSnapshotV1?
    private var recoverySignalQueue = WatchRecoverySignalQueue()
    private var recoveredSaveReconciliationGate =
        WatchRecoveredSaveReconciliationGate()
    private var isRecoveryLoopRunning = false
    private var isDetachedSaveReconciliationInProgress = false
    private var isFinishFailureRollbackPending = false
    private var lastSnapshotPublishedAt = Date.distantPast
    private var lastErrorCode: WorkoutSafeErrorCodeV1?
    private var mirrorEnvelopeBuffer = WorkoutLatestEnvelopeBuffer()
    private var isMirroring = false
    private var isMirrorStartInFlight = false
    private var mirrorStartAttemptID: UUID?
    private var mirrorSendAttemptID: UUID?
    private var remoteControlGate = WorkoutRemoteControlSequenceGate()
    private var pendingRemoteStateAcknowledgement: (
        control: WorkoutControlV1,
        sequence: UInt64,
        context: WorkoutControlContextV1?
    )?
    private var pendingAutomaticStartAnnotation: WorkoutControlContextV1?
    private var pendingAutomaticTransitionAnnotation:
        WorkoutControlContextV1?
    private var localStartOriginPending = false
    private var suppliedConfigurationStartOriginPending = false
    private var suppliedConfigurationStartOriginTask: Task<Void, Never>?
    private var pendingLaunchAutomaticStartContext:
        WorkoutControlContextV1?
    private var pendingLaunchAutomaticStartExpiryTask: Task<Void, Never>?
    private var activeLaunchAutomaticStartContext:
        WorkoutControlContextV1?
    private var lastConsumedAutomaticStartContext:
        WorkoutControlContextV1?
    private var manualTransitionOverridePending = false
    private var manualTransitionOverrideGeneration: UInt64 = 0
    private var manualTransitionOverrideTimeoutTask: Task<Void, Never>?
    private var lastProcessedManualTransitionRequestAt = Date.distantPast
    private var remoteSegmentControlContext: RemoteSegmentControlContext?
    private var terminalCleanupRetryTask: Task<Void, Never>?
    private var terminalCleanupRetryAttemptCount = 0
    private var shutdownMirrorFailureRetryCount = 0
    private var pendingWorkoutConfiguration: HKWorkoutConfiguration?
    private var pendingTerminalErrorPersistence: (
        code: WorkoutSafeErrorCodeV1,
        endDate: Date
    )?
    private var pendingTerminalErrorCodeForNextFinish:
        WorkoutSafeErrorCodeV1?
    private var pendingTerminalCauseConfirmedCompletion:
        ConfirmedTerminalCompletion?

    private var currentHeartRate: WorkoutMetricV1?
    private var averageHeartRate: WorkoutMetricV1?
    private var activeEnergy: WorkoutMetricV1?
    private var healthKitDistance: WorkoutMetricCandidate?
    private var pairedSensorSpeed: WorkoutMetricCandidate?
    private var cyclingPower: WorkoutMetricV1?
    private var cyclingCadence: WorkoutMetricV1?
    private var terminalRouteDistance: WorkoutMetricCandidate?
    private var segmentAccumulator = WorkoutSegmentAccumulator()
    private var heartRateZoneDurationAccumulator =
        WorkoutHeartRateZoneDurationAccumulator()
    private var heartRateZoneCheckpointPersistenceGate =
        WorkoutHeartRateZoneCheckpointPersistenceGate()
    private var heartRateZoneRuntimeSessionID: UUID?
    private var heartRateZoneRuntimeMaximumHeartRateBPM: Int?

    override convenience init() {
        self.init(locationService: WatchLocationService())
    }

    convenience init(locationService: WatchLocationService) {
#if DEBUG
        let isAppStoreScreenshotPreview = ProcessInfo.processInfo.arguments
            .contains("--app-store-screenshot-live-workout")
#else
        let isAppStoreScreenshotPreview = false
#endif
        self.init(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(
                locationService: locationService
            ),
            recoveryStore: WatchWorkoutRecoveryStore(),
            recoverActiveWorkoutSession: nil,
            requestAuthorization: nil,
            refreshAuthorization: nil,
            authorizationRefreshState: nil,
            pauseDetachedRecovery: nil,
            identityMetadataRetryAdapter: nil,
            recoveredSaveRuntimeAdapter: nil,
            recoveredSaveResolver: nil,
            savedWorkoutLookup: nil,
            builderElapsedTime: nil,
            initialFinishFailureRollbackPending: false,
            finalizationClaimObserver: nil,
            recoveredDiscardFinalizationAdapter: nil,
            workoutConfigurationHandler: nil,
            complicationStartOperation: nil,
            remotePauseOperation: nil,
            remoteResumeOperation: nil,
            segmentEventOperation: nil,
            rideTransitionEventOperation: nil,
            segmentWriteTimeout: 10,
            mirrorStartOperation: nil,
            mirrorSendOperation: nil,
            mirrorShutdownEndSession: nil,
            mirrorRetryDelay: 5,
            mirrorShutdownDeliveryTimeout: 10,
            terminalCleanupRetryDelay: 1,
            workoutLaunchRequestLifetime:
                Self.defaultWorkoutLaunchRequestLifetime,
            initializeOnLaunch: !isAppStoreScreenshotPreview
        )
#if DEBUG
        if isAppStoreScreenshotPreview {
            configureAppStoreScreenshotPreview()
        }
#endif
    }

    init(
        healthStore: HKHealthStore,
        routeRecorder: WatchRouteRecorder,
        recoveryStore: WatchWorkoutRecoveryStore,
        recoverActiveWorkoutSession: (
            @MainActor () async -> (session: HKWorkoutSession?, error: Error?)
        )? = nil,
        requestAuthorization: (@MainActor () async throws -> Void)? = nil,
        refreshAuthorization: (@MainActor () async -> Void)? = nil,
        authorizationRefreshState: WatchWorkoutSetupState? = nil,
        pauseDetachedRecovery: (@MainActor () async -> Void)? = nil,
        identityMetadataRetryAdapter:
            WatchWorkoutIdentityMetadataRetryAdapter? = nil,
        recoveredSaveRuntimeAdapter:
            WatchRecoveredSaveRuntimeAdapter? = nil,
        recoveredSaveResolver: (
            @MainActor (
                HKLiveWorkoutBuilder,
                WatchWorkoutRecoveryStore.Identity
            ) async -> RecoveredSaveResolution
        )? = nil,
        savedWorkoutLookup: (
            @MainActor (String, Date) async throws -> HKWorkout?
        )? = nil,
        builderElapsedTime:
            (@MainActor (HKLiveWorkoutBuilder?) -> TimeInterval)? = nil,
        initialFinishFailureRollbackPending: Bool = false,
        finalizationClaimObserver:
            ((WorkoutSaveFinalizationMode?) -> Void)? = nil,
        recoveredDiscardFinalizationAdapter:
            WatchRecoveredDiscardFinalizationAdapter? = nil,
        workoutConfigurationHandler:
            (@MainActor (HKWorkoutConfiguration) -> Void)? = nil,
        complicationStartOperation:
            (@MainActor () async -> Void)? = nil,
        remotePauseOperation:
            (@MainActor (HKWorkoutSession) -> Void)? = nil,
        remoteResumeOperation:
            (@MainActor (HKWorkoutSession) -> Void)? = nil,
        segmentEventOperation: WatchSegmentEventOperation? = nil,
        rideTransitionEventOperation: WatchSegmentEventOperation? = nil,
        endCollectionOperation:
            (@MainActor (HKLiveWorkoutBuilder, Date) async throws -> Void)?
                = nil,
        finishWorkoutOperation:
            (@MainActor (HKLiveWorkoutBuilder) async throws -> Void)? = nil,
        segmentNow: @MainActor @escaping () -> Date = Date.init,
        segmentWriteTimeout: TimeInterval = 10,
        mirrorStartOperation: WatchMirrorStartOperation? = nil,
        mirrorSendOperation: WatchMirrorSendOperation? = nil,
        mirrorShutdownEndSession:
            (@MainActor (HKWorkoutSession) -> Void)? = nil,
        mirrorRetryDelay: TimeInterval = 5,
        mirrorShutdownDeliveryTimeout: TimeInterval = 10,
        terminalCleanupRetryDelay: TimeInterval = 1,
        workoutLaunchRequestLifetime: TimeInterval = 30,
        initializeOnLaunch: Bool = true,
        heartRateZoneDefaults: UserDefaults = .standard
    ) {
        self.healthStore = healthStore
        self.routeRecorder = routeRecorder
        self.recoveryStore = recoveryStore
        self.heartRateZoneDefaults = heartRateZoneDefaults
        self.maximumHeartRateBPM = WorkoutHeartRateZoneSettings
            .maximumHeartRateBPM(from: heartRateZoneDefaults)
        if let data = heartRateZoneDefaults.data(
            forKey: RideDetectionMirrorKey.payload
        ), var settings = try? PropertyListDecoder().decode(
            RideDetectionSettings.self,
            from: data
        ) {
            settings.normalize()
            rideDetectionSettings = settings
        } else {
            rideDetectionSettings = RideDetectionSettings()
        }
        rideDetectionSettingsGeneration = UInt32(
            truncatingIfNeeded: heartRateZoneDefaults.integer(
                forKey: RideDetectionMirrorKey.generation
            )
        )
        self.injectedRecoveryOperation = recoverActiveWorkoutSession
        self.injectedAuthorizationRequestOperation = requestAuthorization
        self.injectedAuthorizationRefreshOperation = refreshAuthorization
        self.injectedAuthorizationRefreshState = authorizationRefreshState
        self.injectedDetachedRecoveryPause = pauseDetachedRecovery
        self.injectedIdentityMetadataRetryAdapter = identityMetadataRetryAdapter
        self.injectedRecoveredSaveRuntimeAdapter = recoveredSaveRuntimeAdapter
        self.injectedRecoveredSaveResolver = recoveredSaveResolver
        self.injectedSavedWorkoutLookup = savedWorkoutLookup
        self.injectedBuilderElapsedTime = builderElapsedTime
        self.injectedFinalizationClaimObserver = finalizationClaimObserver
        self.injectedRecoveredDiscardFinalizationAdapter =
            recoveredDiscardFinalizationAdapter
        self.injectedWorkoutConfigurationHandler = workoutConfigurationHandler
        self.injectedComplicationStartOperation = complicationStartOperation
        self.injectedRemotePauseOperation = remotePauseOperation
        self.injectedRemoteResumeOperation = remoteResumeOperation
        self.injectedSegmentEventOperation = segmentEventOperation
        self.injectedRideTransitionEventOperation =
            rideTransitionEventOperation
        self.injectedEndCollectionOperation = endCollectionOperation
        self.injectedFinishWorkoutOperation = finishWorkoutOperation
        self.segmentNow = segmentNow
        self.segmentWriteTimeout = segmentWriteTimeout.isFinite
            ? min(max(0.01, segmentWriteTimeout), 60)
            : 10
        self.injectedMirrorStartOperation = mirrorStartOperation
        self.injectedMirrorSendOperation = mirrorSendOperation
        self.injectedMirrorShutdownEndSession = mirrorShutdownEndSession
        self.mirrorRetryDelay = mirrorRetryDelay
        self.mirrorShutdownDeliveryTimeout = mirrorShutdownDeliveryTimeout
        self.terminalCleanupRetryDelay = terminalCleanupRetryDelay.isFinite
            ? min(max(0, terminalCleanupRetryDelay), 60)
            : 1
        self.workoutLaunchRequestLifetime =
            workoutLaunchRequestLifetime.isFinite
            ? min(max(0.01, workoutLaunchRequestLifetime), 300)
            : Self.defaultWorkoutLaunchRequestLifetime
        self.locationAuthorizationState = routeRecorder.authorizationState
        super.init()

        if let recoveredSaveRuntimeAdapter {
            session = recoveredSaveRuntimeAdapter.session
            builder = recoveredSaveRuntimeAdapter.builder
            if let workoutStart = recoveryStore.recoveredIdentity?.startDate
                ?? recoveredSaveRuntimeAdapter.builder.startDate {
                restoreSegmentAccumulator(
                    from: recoveredSaveRuntimeAdapter.builder,
                    workoutStart: workoutStart
                )
                seedManualTransitionRequestWatermark(
                    from: recoveredSaveRuntimeAdapter.builder,
                    workoutStart: workoutStart
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await restoreRideTransition(
                        from: recoveredSaveRuntimeAdapter.builder,
                        sessionState: recoveredSaveRuntimeAdapter.sessionState(),
                        workoutStart: workoutStart
                    )
                    publishSnapshotImmediately()
                }
            }
            isBuilderReadyForFinalization = true
        }
        isFinishFailureRollbackPending = initialFinishFailureRollbackPending
        if initialFinishFailureRollbackPending {
            finishRequestError = .saveFailed
        }

        routeRecorder.$authorizationState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.locationAuthorizationState = state
            }
            .store(in: &cancellables)

        if initializeOnLaunch {
            Task { [weak self] in
                await self?.initialize()
            }
        } else {
            isRecovering = false
        }
    }

    deinit {
        periodicSnapshotTask?.cancel()
        coalescedSnapshotTask?.cancel()
        finalizationTask?.cancel()
        mirrorRetryTask?.cancel()
        mirrorShutdownWatchdogTask?.cancel()
        terminalCleanupRetryTask?.cancel()
        complicationStartTask?.cancel()
        workoutLaunchRequestExpiryTask?.cancel()
        authorizationRefreshTask?.cancel()
        segmentOperationTask?.cancel()
        segmentOperationTimeoutTask?.cancel()
        finalSegmentOperationTask?.cancel()
        suppliedConfigurationStartOriginTask?.cancel()
        pendingLaunchAutomaticStartExpiryTask?.cancel()
        manualTransitionOverrideTimeoutTask?.cancel()
    }

    var state: WorkoutSessionStateV1 { lifecycle.state }
    var isWorkoutActive: Bool { lifecycle.state.isActive }
    var activeSessionID: UUID? {
        guard isWorkoutActive else { return nil }
        return recoveryStore.recoveredIdentity?.sessionID ?? identity?.sessionID
    }
    var activeSessionToken: UInt16? {
        guard isWorkoutActive else { return nil }
        return recoveryStore.recoveredIdentity?.sessionToken
            ?? identity?.sessionToken
    }

    var isTerminalCleanupDeliveryInFlight: Bool {
        isTerminalMirrorDeliveryPending
            || isStartFailureMirrorDeliveryPending
            || (session != nil
                && (isTerminalPublicationPending || isTerminalArchivePending))
    }

    private var hasDetachedRecoveryCleanup: Bool {
        guard session == nil else { return false }
        return recoveryStore.recoveredIdentity?.finishRequest?.disposition
                == .discard
            || recoveryStore.recoveredIdentity?.finishRequest?.phase
                == .workoutSaved
            || reconciledSavedWorkout != nil
    }

    private var hasDurableTerminalCleanupRetry: Bool {
        guard session == nil,
              !isTerminalCleanupDeliveryInFlight else {
            return false
        }
        return isTerminalPublicationPending
            || isTerminalArchivePending
    }

    var isTerminalCleanupRetryRequired: Bool {
        guard !isTerminalCleanupDeliveryInFlight,
              !isTerminalCleanupRetrying else {
            return false
        }
        return hasDurableTerminalCleanupRetry || hasDetachedRecoveryCleanup
    }

    var terminalCleanupState: WatchWorkoutCleanupState {
        if isTerminalCleanupDeliveryInFlight {
            return .delivering
        }
        if isTerminalCleanupRetrying {
            return .retrying
        }
        if isTerminalCleanupRetryRequired {
            return .retryRequired
        }
        return .none
    }

    var isAwaitingDetachedSessionCleanup: Bool {
        if isTerminalPublicationPending
            || isTerminalMirrorDeliveryPending
            || isStartFailureMirrorDeliveryPending {
            return true
        }
        guard session == nil else { return false }
        return isTerminalArchivePending
            || recoveryStore.recoveredIdentity?.finishRequest?.disposition == .discard
            || recoveryStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved
            || reconciledSavedWorkout != nil
    }
    var isDiscarding: Bool {
        lifecycle.state == .ending && lifecycle.finishDisposition == .discard
    }
    var hasCorruptRecoveryState: Bool {
        recoveryStore.loadState == .corrupt
    }
    var hasUnavailableRecoveryState: Bool {
        recoveryStore.loadState == .unavailable
    }
    var hasPendingWorkoutRecovery: Bool {
        recoveryStore.recoveredIdentity != nil
    }

    func requestAuthorization() {
        Task { [weak self] in
            await self?.authorizeHealthKit()
        }
    }

    /// Re-reads HealthKit authorization after the user returns from the
    /// system's Health settings. This deliberately never presents a new
    /// authorization sheet, so a previously denied request remains a
    /// settings-only recovery path.
    func refreshAuthorizationIfNeeded() {
        guard !isWorkoutActive,
              !isRecovering,
              !isRecoveryLoopRunning,
              session == nil,
              setupState != .authorizing,
              authorizationRefreshTask == nil else {
            return
        }

        authorizationRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.authorizationRefreshTask = nil
                self.reconcilePendingWorkoutLaunchRequest()
            }
            await self.refreshAuthorizationState()
        }
    }

    func retrySetup() {
        guard WorkoutRecoverySingleFlightPolicy.canStartRetry(
            isWorkoutActive: isWorkoutActive,
            isRecovering: isRecovering
        ) else { return }
        isRecovering = true
        setupState = .checking
        Task { [weak self] in
            await self?.initialize()
        }
    }

    func confirmResetCorruptRecovery() {
        guard !isWorkoutActive,
              session == nil,
              !isRecovering,
              recoveryStore.loadState == .corrupt else {
            return
        }
        do {
            try recoveryStore.quarantineCorruptState()
        } catch {
            setupState = .failed
            return
        }
        retrySetup()
    }

    func handleActiveWorkoutRecovery() {
        guard recoverySignalQueue.recordSignal(
            hasAttachedSession: session != nil
        ) else { return }
        startRecoveryLoopIfNeeded()
    }

    func handleLaunchURL(_ url: URL, now: Date = Date()) {
        guard WatchWorkoutLaunchRequest(url: url) == .startOutdoorCycling else {
            if rejectedWorkoutLaunchURLCount < UInt64.max {
                rejectedWorkoutLaunchURLCount += 1
            }
            return
        }
        guard !isWorkoutActive,
              complicationStartTask == nil,
              ![.denied, .unavailable, .failed].contains(setupState) else {
            return
        }
        let request = PendingWorkoutLaunchRequest(
            workoutType: .outdoorCycling,
            source: .complicationURL,
            createdAt: now,
            expiresAt: now.addingTimeInterval(workoutLaunchRequestLifetime)
        )
        workoutLaunchRequestExpiryTask?.cancel()
        pendingWorkoutLaunchRequest = request
        workoutLaunchRequestExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        (self?.workoutLaunchRequestLifetime ?? 0)
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            self?.expirePendingWorkoutLaunchRequest(
                id: request.id,
                now: request.expiresAt
            )
        }
    }

    var canConfirmPendingWorkoutLaunchRequest: Bool {
        guard let request = pendingWorkoutLaunchRequest,
              !request.isExpired(at: Date()) else {
            return false
        }
        return canAdmitConfirmedWorkoutLaunch
    }

    func confirmPendingWorkoutLaunchRequest() {
        guard pendingWorkoutLaunchRequest != nil,
              canConfirmPendingWorkoutLaunchRequest,
              complicationStartTask == nil else {
            reconcilePendingWorkoutLaunchRequest()
            return
        }
        clearPendingWorkoutLaunchRequest()
        complicationStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { complicationStartTask = nil }
            guard canAdmitConfirmedWorkoutLaunch else { return }
            if let injectedComplicationStartOperation {
                await injectedComplicationStartOperation()
            } else {
                await startOutdoorCyclingWorkout()
            }
        }
    }

    func cancelPendingWorkoutLaunchRequest() {
        clearPendingWorkoutLaunchRequest()
    }

    func startOutdoorCycling() {
        Task { [weak self] in
            await self?.startOutdoorCyclingWorkout()
        }
    }

    func requestDirectRideAutomationTransition(
        _ frame: RideAutomationFrame,
        deviceID: String,
        requestedAt: Date = Date()
    ) -> RideAutomationResult {
        guard frame.kind == .decision,
              frame.origin == .automatic,
              let frameSessionID = frame.sessionID,
              frameSessionID == activeSessionID,
              let session,
              let durableIdentity = recoveryStore.recoveredIdentity
                ?? identity else {
            return .sessionMismatch
        }
        let context = WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence,
            detectorProfileVersion: frame.profileVersion
        )
        let paused: Bool
        switch frame.transition {
        case .pause:
            if lifecycle.state == .paused,
               durableIdentity.pauseOrigin == .automatic,
               durableIdentity.detectorProfileVersion
                    == frame.profileVersion {
                return .accepted
            }
            guard lifecycle.state == .running else { return .stale }
            if durableIdentity.lastTransitionOrigin == .manual,
               let transitionAt = durableIdentity.lastTransitionAt,
               requestedAt.timeIntervalSince(transitionAt) < 15 {
                return .stale
            }
            paused = true
        case .resume:
            if lifecycle.state == .running,
               durableIdentity.lastTransitionOrigin == .automatic,
               durableIdentity.detectorProfileVersion
                    == frame.profileVersion {
                return .accepted
            }
            guard lifecycle.state == .paused,
                  durableIdentity.pauseOrigin == .automatic else {
                return .stale
            }
            paused = false
        case .none, .start:
            return .watchUnavailable
        }

        do {
            if durableIdentity.pendingTransitionContext != context
                || durableIdentity.rideAutomationDeviceID != deviceID
                || durableIdentity.rideAutomationRideGeneration
                    != frame.rideGeneration
                || durableIdentity.rideAutomationDecisionWatermark
                    != frame.decisionSequence {
                try recoveryStore.persistAutomaticTransitionRequest(
                    context: context,
                    paused: paused,
                    requestedAt: requestedAt,
                    deviceID: deviceID
                )
                if let persistedIdentity = recoveryStore.recoveredIdentity {
                    identity = persistedIdentity
                }
            }
        } catch {
            return .rejected
        }
        if pendingAutomaticTransitionAnnotation != nil {
            return .accepted
        }
        if paused {
            if let injectedRemotePauseOperation {
                injectedRemotePauseOperation(session)
            } else {
                session.pause()
            }
        } else if let injectedRemoteResumeOperation {
            injectedRemoteResumeOperation(session)
        } else {
            session.resume()
        }
        return .accepted
    }

    func directRideAutomationDecisionWatermark(
        deviceID: String,
        rideGeneration: UInt32
    ) -> UInt32 {
        recoveryStore.rideAutomationDecisionWatermark(
            deviceID: deviceID,
            rideGeneration: rideGeneration
        )
    }

    /// Replays only the exact durable automatic transition that was persisted
    /// before HealthKit was mutated. This closes the relaunch window between
    /// persisting a detector decision and calling pause()/resume() without
    /// allowing an arbitrary duplicate watermark to control the workout.
    func retryPendingDirectRideAutomationTransition(
        _ frame: RideAutomationFrame,
        deviceID: String,
        requestedAt: Date = Date()
    ) -> RideAutomationResult? {
        guard frame.kind == .decision,
              frame.origin == .automatic,
              let frameSessionID = frame.sessionID,
              frameSessionID == activeSessionID,
              let durableIdentity = recoveryStore.recoveredIdentity
                ?? identity else {
            return nil
        }
        let context = WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence,
            detectorProfileVersion: frame.profileVersion
        )
        let expectedPaused: Bool
        switch frame.transition {
        case .pause:
            expectedPaused = true
        case .resume:
            expectedPaused = false
        case .none, .start:
            return nil
        }
        guard durableIdentity.pendingTransitionContext == context,
              durableIdentity.pendingTransitionPaused == expectedPaused,
              durableIdentity.rideAutomationDeviceID == deviceID,
              durableIdentity.rideAutomationRideGeneration
                == frame.rideGeneration,
              durableIdentity.rideAutomationDecisionWatermark
                == frame.decisionSequence else {
            return nil
        }

        if (expectedPaused && lifecycle.state == .paused)
            || (!expectedPaused && lifecycle.state == .running) {
            // HealthKit reached the target before the process exited. Recovery
            // will make the durable marker authoritative; do not issue the
            // native transition twice while that reconciliation is in flight.
            return .accepted
        }
        return requestDirectRideAutomationTransition(
            frame,
            deviceID: deviceID,
            requestedAt: requestedAt
        )
    }

    @discardableResult
    func recordDirectRideAutomationDecision(
        deviceID: String,
        rideGeneration: UInt32,
        decisionSequence: UInt32
    ) -> Bool {
        do {
            try recoveryStore.persistRideAutomationDecisionWatermark(
                deviceID: deviceID,
                rideGeneration: rideGeneration,
                decisionSequence: decisionSequence
            )
            if let persistedIdentity = recoveryStore.recoveredIdentity {
                identity = persistedIdentity
            }
            return true
        } catch {
            return false
        }
    }

    func setMaximumHeartRateBPM(_ value: Int) {
        let clamped = WorkoutHeartRateZoneProfile
            .clampedMaximumHeartRateBPM(value)
        guard clamped != maximumHeartRateBPM else { return }
        maximumHeartRateBPM = clamped
        WorkoutHeartRateZoneSettings.saveMaximumHeartRateBPM(
            clamped,
            to: heartRateZoneDefaults
        )
        if isWorkoutActive {
            publishSnapshotImmediately()
        }
    }

    func setRideDetectionSettings(
        _ value: RideDetectionSettings,
        generation: UInt32
    ) {
        var normalized = value
        normalized.normalize()
        guard !rideDetectionSettingsConfirmed
                || generation == rideDetectionSettingsGeneration
                || RideAutomationSerialNumber.isNewer(
                    generation,
                    than: rideDetectionSettingsGeneration
                ) else {
            return
        }
        guard generation != rideDetectionSettingsGeneration
                || normalized != rideDetectionSettings
                || !rideDetectionSettingsConfirmed else {
            return
        }
        rideDetectionSettings = normalized
        rideDetectionSettingsGeneration = generation
        rideDetectionSettingsConfirmed = true
        if let data = try? PropertyListEncoder().encode(normalized) {
            heartRateZoneDefaults.set(
                data,
                forKey: RideDetectionMirrorKey.payload
            )
        }
        heartRateZoneDefaults.set(
            Int(generation),
            forKey: RideDetectionMirrorKey.generation
        )
    }

    func clearRideDetectionSettings() {
        rideDetectionSettings = RideDetectionSettings()
        rideDetectionSettingsGeneration = 0
        rideDetectionSettingsConfirmed = false
        heartRateZoneDefaults.removeObject(
            forKey: RideDetectionMirrorKey.payload
        )
        heartRateZoneDefaults.removeObject(
            forKey: RideDetectionMirrorKey.generation
        )
    }

    func handleWorkoutConfiguration(_ configuration: HKWorkoutConfiguration) {
        guard configuration.activityType == .cycling,
              configuration.locationType == .outdoor else {
            setupState = .failed
            return
        }
        pendingWorkoutConfiguration = configuration
        drainPendingWorkoutConfigurationIfPossible()
    }

    func pause() {
        guard lifecycle.state == .running, let session else { return }
        do {
            try beginManualTransitionOverride()
        } catch {
            lastErrorCode = .sessionFailed
            return
        }
        session.pause()
    }

    func resume() {
        guard lifecycle.state == .paused, let session else { return }
        do {
            try beginManualTransitionOverride()
        } catch {
            lastErrorCode = .sessionFailed
            return
        }
        session.resume()
    }

    func markSegment() {
        guard lifecycle.state == .running else {
            segmentError = .unavailable
            return
        }
        guard !isMarkingSegment else { return }
        beginSegmentMark(remoteContext: nil)
    }

    func endAndSave() {
        requestEnd(.save, explicitRiderChoice: true)
    }

    func discard() {
        requestEnd(.discard, explicitRiderChoice: true)
    }

    func retryFinalization() {
        let isRetryingSegmentFinalization =
            finishRequestError == .segmentConfirmationPending
        guard finishRequestError == .reconciliationFailed
                || finishRequestError == .saveFailed
                || finishRequestError == .identityMetadataFailed
                || isRetryingSegmentFinalization
                || finishRequestError == .terminalErrorPersistenceFailed,
              lifecycle.state == .ending,
              finalizationTask == nil else {
            return
        }
        var terminalCauseRetryEndDate: Date?
        if let pendingTerminalErrorPersistence {
            let retryEndDate = pendingTerminalErrorPersistence.endDate
            let hasRetainedCompletion =
                pendingTerminalCauseConfirmedCompletion != nil
            authoritativeFinalizationEndDate =
                authoritativeFinalizationEndDate ?? retryEndDate
            guard persistTerminalErrorForCurrentFinish(
                pendingTerminalErrorPersistence.code,
                endDate: retryEndDate
            ) else {
                publishSnapshotImmediately()
                return
            }
            if hasRetainedCompletion { return }
            terminalCauseRetryEndDate = retryEndDate
        }
        finishRequestError = nil
        if isRetryingSegmentFinalization,
           lastErrorCode == .segmentFinalizationPending {
            lastErrorCode = nil
        }
        Task { [weak self] in
            guard let self else { return }
            if isIdentityMetadataRetryPending {
                await retryIdentityMetadataAttachmentForFinalization()
            } else if let terminalCauseRetryEndDate,
                      let session,
                      !Self.canRetryFinalization(
                        sessionState: injectedRecoveredSaveRuntimeAdapter?
                            .sessionState() ?? session.state
                      ) {
                stopSessionForFinalization(
                    session,
                    at: terminalCauseRetryEndDate
                )
            } else if lifecycle.finishDisposition == .discard,
                      session != nil
                        || injectedRecoveredDiscardFinalizationAdapter != nil {
                beginFinalizationAfterStop(
                    at: recoveryStore.recoveredIdentity?.finishRequest?.requestedAt
                        ?? Date()
                )
            } else if session == nil {
                if lifecycle.finishDisposition == .discard {
                    finishRequestError = .reconciliationFailed
                    handleActiveWorkoutRecovery()
                } else {
                    await reconcileDetachedSave()
                }
            } else {
                await resumeRecoveredStoppedSaveFinalization()
            }
        }
    }

    func setPendingAutomaticStartContext(
        _ context: WorkoutControlContextV1?
    ) {
        guard let context else {
            pendingLaunchAutomaticStartContext = nil
            pendingLaunchAutomaticStartExpiryTask?.cancel()
            pendingLaunchAutomaticStartExpiryTask = nil
            return
        }
        switch RideAutomationStartContextPolicy.disposition(
            sessionState: lifecycle.state,
            awaitingSuppliedStartOrigin:
                suppliedConfigurationStartOriginPending,
            hasConfirmedStartOrigin: identity?.lastTransitionOrigin != nil,
            matchesLastConsumedContext:
                context == lastConsumedAutomaticStartContext
        ) {
        case .queueForNextStart:
            pendingLaunchAutomaticStartContext = context
            pendingLaunchAutomaticStartExpiryTask?.cancel()
            pendingLaunchAutomaticStartExpiryTask = Task { @MainActor
                [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 35_000_000_000)
                } catch {
                    return
                }
                guard let self,
                      pendingLaunchAutomaticStartContext == context else {
                    return
                }
                pendingLaunchAutomaticStartContext = nil
                pendingLaunchAutomaticStartExpiryTask = nil
            }
        case .applyToCurrentSuppliedStart:
            lastConsumedAutomaticStartContext = context
            pendingLaunchAutomaticStartContext = nil
            pendingLaunchAutomaticStartExpiryTask?.cancel()
            pendingLaunchAutomaticStartExpiryTask = nil
            activeLaunchAutomaticStartContext = context
            suppliedConfigurationStartOriginPending = false
            suppliedConfigurationStartOriginTask?.cancel()
            suppliedConfigurationStartOriginTask = nil
            if lifecycle.state == .running {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let confirmed = await confirmLaunchAutomaticStart(
                        context: context,
                        at: identity?.startDate ?? Date()
                    )
                    publishSnapshotImmediately()
                    if confirmed {
                        publishPendingRemoteStateAcknowledgementIfConfirmed()
                    }
                }
            }
        case .ignore:
            break
        }
    }

    func saveWithoutUnconfirmedSegment() {
        guard finishRequestError == .segmentConfirmationPending,
              lifecycle.state == .ending else {
            return
        }
        allowsSavingWithUnconfirmedSegment = true
        retryFinalization()
    }

    func dismissSummary() {
        guard !isAwaitingDetachedSessionCleanup else { return }
        guard lifecycle.apply(.reset) else { return }
        finishRequestError = nil
        summary = nil
        pendingTerminalErrorPersistence = nil
        pendingTerminalErrorCodeForNextFinish = nil
        pendingTerminalCauseConfirmedCompletion = nil
        snapshot = WorkoutSnapshotV1(state: .idle)
        latestEnvelope = nil
        routeRecorder.discardRoute()
        clearMetrics()
    }

    func retryPendingTerminalCleanupIfPossible() {
        guard hasDurableTerminalCleanupRetry else { return }
        if terminalCleanupRetryTask == nil,
           terminalCleanupRetryAttemptCount
                >= Self.maxTerminalCleanupRetryAttempts {
            terminalCleanupRetryAttemptCount = 0
        }
        scheduleTerminalCleanupRetryIfNeeded()
    }

    func retryDetachedSessionCleanup() {
        guard hasDurableTerminalCleanupRetry || hasDetachedRecoveryCleanup else {
            return
        }
        cancelTerminalCleanupRetry(resetAttemptCount: true)
        guard hasDurableTerminalCleanupRetry else {
            handleActiveWorkoutRecovery()
            return
        }
        runTerminalCleanupRetryAttempt()
    }

    private func performTerminalCleanupRetry() {
        if isTerminalPublicationPending {
            retryTerminalPublicationAndArchive()
            return
        }
        if isTerminalArchivePending {
            guard let request = recoveryStore.recoveredIdentity?.finishRequest else {
                finishRequestError = .reconciliationFailed
                return
            }
            switch request.disposition {
            case .save:
                archiveConfirmedSave(at: summary?.endedAt ?? Date())
            case .discard:
                archiveConfirmedDiscard(at: summary?.endedAt ?? Date())
            }
            if isTerminalArchivePending {
                finishRequestError = .reconciliationFailed
            } else {
                finishRequestError = nil
            }
            return
        }
        handleActiveWorkoutRecovery()
    }

    private func scheduleTerminalCleanupRetryIfNeeded() {
        guard hasDurableTerminalCleanupRetry,
              !isTerminalCleanupRetrying,
              terminalCleanupRetryTask == nil,
              terminalCleanupRetryAttemptCount
                < Self.maxTerminalCleanupRetryAttempts else {
            return
        }
        let nextAttempt = terminalCleanupRetryAttemptCount + 1
        let delay = min(
            terminalCleanupRetryDelay
                * pow(2, Double(max(0, nextAttempt - 1))),
            30
        )
        isTerminalCleanupRetrying = true
        terminalCleanupRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self else { return }
            self.terminalCleanupRetryTask = nil
            self.runTerminalCleanupRetryAttempt()
        }
    }

    private func runTerminalCleanupRetryAttempt() {
        terminalCleanupRetryTask = nil
        guard hasDurableTerminalCleanupRetry else {
            isTerminalCleanupRetrying = false
            terminalCleanupRetryAttemptCount = 0
            return
        }
        terminalCleanupRetryAttemptCount += 1
        isTerminalCleanupRetrying = true
        performTerminalCleanupRetry()
        isTerminalCleanupRetrying = false
        if hasDurableTerminalCleanupRetry {
            scheduleTerminalCleanupRetryIfNeeded()
        } else {
            terminalCleanupRetryAttemptCount = 0
        }
    }

    private func cancelTerminalCleanupRetry(resetAttemptCount: Bool) {
        terminalCleanupRetryTask?.cancel()
        terminalCleanupRetryTask = nil
        isTerminalCleanupRetrying = false
        if resetAttemptCount {
            terminalCleanupRetryAttemptCount = 0
        }
    }

    private func startRecoveryLoopIfNeeded() {
        guard !isRecovering, session == nil else { return }
        isRecovering = true
        setupState = .checking
        Task { [weak self] in
            await self?.initialize()
        }
    }

    private func handleAttachedSessionRelease() {
        guard session == nil else { return }
        if recoverySignalQueue.consumeAfterSessionRelease(),
           !isRecoveryLoopRunning {
            isRecovering = false
            startRecoveryLoopIfNeeded()
        }
        drainPendingWorkoutConfigurationIfPossible()
        reconcilePendingWorkoutLaunchRequest()
    }

    private func initialize() async {
        isRecoveryLoopRunning = true
        defer {
            isRecoveryLoopRunning = false
            drainPendingWorkoutConfigurationIfPossible()
            reconcilePendingWorkoutLaunchRequest()
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            setupState = .unavailable
            isRecovering = false
            return
        }
        recoveryStore.reload()
        guard [.missing, .valid].contains(recoveryStore.loadState) else {
            // Unknown bytes may contain a discard request, a commit-unknown
            // save, or terminal tombstones. Never clear or begin over them.
            setupState = .failed
            isRecovering = false
            return
        }

        while true {
            let requestGeneration = recoverySignalQueue.generation
            let recoveryOutcome = await recoverActiveWorkoutIfPresent()
            if requestGeneration != recoverySignalQueue.generation,
               session == nil {
                continue
            }
            if WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(
                after: recoveryOutcome
            ) {
                await refreshAuthorizationState()
                guard requestGeneration == recoverySignalQueue.generation else {
                    continue
                }
                if recoveryStore.hasCorruptResetProtection,
                   recoveryStore.recoveredIdentity != nil {
                    // A separate corrupt-reset authorization may coexist with
                    // a newer ordinary ride. A nil query is not permission to
                    // expose Start while that ride can still arrive through a
                    // late watchOS recovery callback.
                    setupState = .failed
                } else if !recoveryStore.hasCorruptResetProtection {
                    do {
                        try recoveryStore.clear()
                    } catch {
                        setupState = .failed
                    }
                }
            } else if recoveryOutcome == .failed {
                setupState = .failed
            }
            break
        }
        isRecovering = terminalCleanupSessionID != nil
    }

    private func drainPendingWorkoutConfigurationIfPossible() {
        guard let configuration = pendingWorkoutConfiguration else { return }
        if let session, isWorkoutActive {
            pendingWorkoutConfiguration = nil
            startMirroringIfNeeded(for: session)
            publishSnapshotImmediately()
            return
        }
        guard !isRecovering,
              !isRecoveryLoopRunning,
              session == nil,
              !isAwaitingDetachedSessionCleanup,
              [.missing, .valid].contains(recoveryStore.loadState) else {
            return
        }
        pendingWorkoutConfiguration = nil
        if let injectedWorkoutConfigurationHandler {
            injectedWorkoutConfigurationHandler(configuration)
            return
        }
        Task { [weak self] in
            await self?.startOutdoorCyclingWorkout(
                configuration: configuration
            )
        }
    }

    private func clearPendingWorkoutLaunchRequest() {
        workoutLaunchRequestExpiryTask?.cancel()
        workoutLaunchRequestExpiryTask = nil
        pendingWorkoutLaunchRequest = nil
    }

    private func expirePendingWorkoutLaunchRequest(id: UUID, now: Date) {
        guard let request = pendingWorkoutLaunchRequest,
              request.id == id,
              request.isExpired(at: now) else {
            return
        }
        clearPendingWorkoutLaunchRequest()
    }

    private func reconcilePendingWorkoutLaunchRequest(now: Date = Date()) {
        guard let request = pendingWorkoutLaunchRequest else { return }
        if request.isExpired(at: now)
            || isWorkoutActive
            || [.denied, .unavailable, .failed].contains(setupState) {
            clearPendingWorkoutLaunchRequest()
        }
    }

    private var canAdmitConfirmedWorkoutLaunch: Bool {
        !isRecovering
            && !isRecoveryLoopRunning
            && [.ready, .needsAuthorization].contains(setupState)
            && session == nil
            && !isAwaitingDetachedSessionCleanup
            && !hasPendingWorkoutRecovery
            && [.missing, .valid].contains(recoveryStore.loadState)
    }

    private func refreshAuthorizationState() async {
        if let injectedAuthorizationRefreshOperation {
            await injectedAuthorizationRefreshOperation()
            if let injectedAuthorizationRefreshState {
                canWriteWorkoutRoute =
                    injectedAuthorizationRefreshState == .ready
                setupState = injectedAuthorizationRefreshState
            }
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            canWriteWorkoutRoute = false
            setupState = .unavailable
            return
        }

        canWriteWorkoutRoute = healthStore.authorizationStatus(
            for: HKSeriesType.workoutRoute()
        ) == .sharingAuthorized
        let requiredShareStatuses = Self.requiredTypesToShare.map(
            healthStore.authorizationStatus(for:)
        )
        if requiredShareStatuses.contains(.sharingDenied) {
            setupState = .denied
            return
        }

        do {
            let requestStatus = try await authorizationRequestStatus()
            setupState = Self.resolveSetupState(
                requiredShareStatuses: requiredShareStatuses,
                requestStatus: requestStatus
            ) ?? .failed
        } catch {
            setupState = .failed
        }
    }

    private func authorizeHealthKit() async {
        defer { reconcilePendingWorkoutLaunchRequest() }
        guard !isWorkoutActive,
              setupState != .denied,
              setupState != .authorizing else {
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            setupState = .unavailable
            return
        }
        setupState = .authorizing
        do {
            if let injectedAuthorizationRequestOperation {
                try await injectedAuthorizationRequestOperation()
            } else {
                try await healthStore.requestAuthorization(
                    toShare: Self.typesToShare,
                    read: Self.typesToRead
                )
                routeRecorder.requestAuthorizationIfNeeded()
            }
            await refreshAuthorizationState()
        } catch {
            setupState = Self.isAuthorizationError(error) ? .denied : .failed
        }
    }

    func startOutdoorCyclingWorkout(
        configuration suppliedConfiguration: HKWorkoutConfiguration? = nil
    ) async {
        let admissionRecoveryGeneration = recoverySignalQueue.generation
        guard !isRecovering,
              !isWorkoutActive,
              session == nil,
              !isAwaitingDetachedSessionCleanup else {
            return
        }
        guard !hasPendingWorkoutRecovery else {
            setupState = .failed
            return
        }
        if setupState != .ready {
            guard setupState != .denied else { return }
            await authorizeHealthKit()
        }
        guard setupState == .ready,
              admissionRecoveryGeneration == recoverySignalQueue.generation,
              !isRecovering,
              !isWorkoutActive,
              session == nil,
              !isAwaitingDetachedSessionCleanup,
              !hasPendingWorkoutRecovery else {
            return
        }
        clearPendingWorkoutLaunchRequest()
        guard lifecycle.apply(.requestStart) else { return }
        let automaticStartContext = suppliedConfiguration == nil
            ? nil
            : pendingLaunchAutomaticStartContext
        if let automaticStartContext {
            lastConsumedAutomaticStartContext = automaticStartContext
            pendingLaunchAutomaticStartContext = nil
            pendingLaunchAutomaticStartExpiryTask?.cancel()
            pendingLaunchAutomaticStartExpiryTask = nil
        }
        activeLaunchAutomaticStartContext = automaticStartContext
        localStartOriginPending = suppliedConfiguration == nil
        suppliedConfigurationStartOriginPending =
            suppliedConfiguration != nil && automaticStartContext == nil
        suppliedConfigurationStartOriginTask?.cancel()
        suppliedConfigurationStartOriginTask = nil

        summary = nil
        finishRequestError = nil
        pendingTerminalErrorPersistence = nil
        pendingTerminalErrorCodeForNextFinish = nil
        pendingTerminalCauseConfirmedCompletion = nil
        clearMetrics()
        lastErrorCode = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        preparedRouteForFinalization = nil
        let startDate = Date()
        segmentAccumulator.reset(workoutStart: startDate)
        segmentError = nil
        isMarkingSegment = false
        remoteSegmentControlContext = nil
        hasAttemptedFinalSegmentClosure = false
        allowsSavingWithUnconfirmedSegment = false

        let configuration: HKWorkoutConfiguration
        if let suppliedConfiguration {
            guard suppliedConfiguration.activityType == .cycling,
                  suppliedConfiguration.locationType == .outdoor else {
                setupState = .failed
                _ = lifecycle.apply(.fail)
                return
            }
            configuration = suppliedConfiguration
        } else {
            let outdoorCycling = HKWorkoutConfiguration()
            outdoorCycling.activityType = .cycling
            outdoorCycling.locationType = .outdoor
            configuration = outdoorCycling
        }

        do {
            let workoutIdentity = try recoveryStore.begin(
                startDate: startDate,
                heartRateZoneMaximumHeartRateBPM: maximumHeartRateBPM
            )
            adoptRecoveredIdentityForRuntime(workoutIdentity)
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            restoreSegmentAccumulator(
                from: builder,
                workoutStart: startDate
            )
            let routeBuilder = canWriteWorkoutRoute
                ? builder.seriesBuilder(
                    for: HKSeriesType.workoutRoute()
                ) as? HKWorkoutRouteBuilder
                : nil
            routeRecorder.begin(
                routeBuilder: routeBuilder,
                startDate: startDate
            ) { [weak self] in
                self?.scheduleCoalescedSnapshot()
            }
            startMirroringIfNeeded(for: session)
            publishSnapshotImmediately()

            session.startActivity(with: startDate)
            var setupProgress = WatchWorkoutSetupProgress()
            do {
                try await builder.beginCollection(at: startDate)
                setupProgress.markCollectionStarted()
            } catch {
                // No builder collection exists, even if the asynchronous
                // session-running callback arrived first. Saving is invalid.
                handleStartFailure(error)
                return
            }
            guard let identity else {
                handleStartFailure(WorkoutFinalizationError.managerReleased)
                return
            }
            let metadataOutcome = await WatchWorkoutIdentityMetadataCoordinator.attach(
                collectionStarted: setupProgress.collectionStarted,
                attachMetadata: {
                    try await builder.addMetadata(
                        Self.workoutIdentityMetadata(sessionID: identity.sessionID)
                    )
                },
                lifecycleState: { [weak self] in
                    self?.lifecycle.state ?? .failed
                },
                finishDisposition: { [weak self] in
                    self?.lifecycle.finishDisposition
                }
            )
            guard self.builder === builder,
                  self.session === session else {
                return
            }
            switch metadataOutcome {
            case .ready:
                setupProgress.markIdentityMetadataAttached()
                isIdentityMetadataRetryPending = false
            case .failStart(let error):
                handleStartFailure(error)
                return
            case .retainForFinishRetry(let error):
                // The user's durable finish request wins over startup cleanup.
                // Keep the collected builder, stopped session, route, and
                // identity intact until metadata attachment can be retried.
                guard retainCollectedFinishForIdentityMetadataRetry(error) else {
                    handleStartFailure(error)
                    return
                }
                return
            }
            guard self.builder === builder,
                  self.session === session,
                  lifecycle.state.isActive else {
                return
            }
            isBuilderReadyForFinalization = setupProgress.canFinalize
            if lifecycle.state == .ending {
                stopSessionForFinalization(
                    session,
                    at: authoritativeFinalizationEndDate ?? Date()
                )
            }
        } catch {
            handleStartFailure(error)
        }
    }

    /// Applies the manager-level retention contract used by the suspended
    /// metadata-attachment catch. Kept internal so the Watch test target can
    /// prove that the durable finish request and ending lifecycle survive.
    @discardableResult
    func retainCollectedFinishForIdentityMetadataRetry(_ error: Error?) -> Bool {
        guard lifecycle.state == .ending,
              let disposition = lifecycle.finishDisposition,
              recoveryStore.recoveredIdentity?.finishRequest?.disposition
                == disposition else {
            return false
        }
        isIdentityMetadataRetryPending = true
        isBuilderReadyForFinalization = false
        finishRequestError = .identityMetadataFailed
        lastErrorCode = Self.safeErrorCode(for: error)
        publishSnapshotImmediately()
        return true
    }

    private func requestEnd(
        _ disposition: WorkoutFinishDisposition,
        requestedAt: Date = Date(),
        explicitRiderChoice: Bool = false,
        terminalErrorCode: WorkoutSafeErrorCodeV1? = nil
    ) {
        guard [.starting, .running, .paused].contains(lifecycle.state) else { return }
        guard persistFinishRequest(
            disposition: disposition,
            requestedAt: requestedAt,
            explicitRiderChoice: explicitRiderChoice,
            terminalErrorCode: terminalErrorCode
        ) else { return }
        beginPersistedFinishRequest(requestedAt: requestedAt)
    }

    private func beginPersistedFinishRequest(requestedAt: Date) {
        guard let durableDisposition = recoveryStore.recoveredIdentity?
                .finishRequest?.disposition,
              lifecycle.apply(.requestEnd(durableDisposition)) else { return }
        authoritativeFinalizationEndDate = requestedAt
        routeRecorder.stopLocationUpdates()
        publishSnapshotImmediately()
        if let session {
            stopSessionForFinalization(session, at: requestedAt)
        } else {
            handleStartFailure(nil)
        }
    }

    @discardableResult
    func persistFinishRequest(
        disposition: WorkoutFinishDisposition,
        requestedAt: Date,
        explicitRiderChoice: Bool = true,
        terminalErrorCode: WorkoutSafeErrorCodeV1? = nil
    ) -> Bool {
        let effectiveTerminalErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: terminalErrorCode,
            persistedFinishError: pendingTerminalErrorCodeForNextFinish
        )
        do {
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: requestedAt,
                explicitRiderChoice: explicitRiderChoice,
                terminalErrorCode: effectiveTerminalErrorCode
            )
            if effectiveTerminalErrorCode != nil {
                pendingTerminalErrorCodeForNextFinish = nil
            }
            finishRequestError = nil
            return true
        } catch {
            if let effectiveTerminalErrorCode {
                pendingTerminalErrorCodeForNextFinish =
                    effectiveTerminalErrorCode
            }
            finishRequestError = .persistenceFailed
            return false
        }
    }

    private func stopSessionForFinalization(
        _ workoutSession: HKWorkoutSession,
        at requestedAt: Date
    ) {
        authoritativeFinalizationEndDate = authoritativeFinalizationEndDate ?? requestedAt
        switch workoutSession.state {
        case .stopped, .ended:
            beginFinalizationAfterStop(
                at: workoutSession.endDate ?? requestedAt
            )
        case .notStarted, .prepared, .running, .paused:
            workoutSession.stopActivity(with: requestedAt)
        @unknown default:
            workoutSession.stopActivity(with: requestedAt)
        }
    }

    private func handleStartFailure(_ error: Error?) {
        suppliedConfigurationStartOriginTask?.cancel()
        suppliedConfigurationStartOriginTask = nil
        suppliedConfigurationStartOriginPending = false
        localStartOriginPending = false
        activeLaunchAutomaticStartContext = nil
        finishRequestError = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        routeRecorder.discardRoute()
        builder?.discardWorkout()
        builder = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        isFinishFailureRollbackPending = false
        isTerminalArchivePending = false
        lastErrorCode = Self.safeErrorCode(for: error)
        if lastErrorCode == .authorizationDenied {
            setupState = .denied
        }
        _ = lifecycle.apply(.fail)
        let didPublish = publishFailureSnapshot()
        if didPublish,
           let shutdownSession = session,
           mirrorEnvelopeBuffer.inFlight != nil
                || mirrorEnvelopeBuffer.pending != nil {
            isStartFailureMirrorDeliveryPending = true
            shutdownMirrorFailureRetryCount = 0
            beginBoundedShutdownMirrorDelivery(for: shutdownSession)
            return
        }
        finishStartFailureRuntime()
    }

    private func finishStartFailureRuntime() {
        mirrorShutdownWatchdogTask?.cancel()
        mirrorShutdownWatchdogTask = nil
        let failedSession = session
        if let failedSession {
            endMirrorShutdownSession(failedSession)
        }
        resetMirrorTransport()
        session = nil
        identity = nil
        try? recoveryStore.clear()
        handleAttachedSessionRelease()
    }

    private func retryIdentityMetadataAttachmentForFinalization() async {
        guard lifecycle.state == .ending,
              let disposition = lifecycle.finishDisposition,
              let durableIdentity = recoveryStore.recoveredIdentity ?? identity,
              durableIdentity.finishRequest?.disposition == disposition else {
            finishRequestError = .reconciliationFailed
            return
        }

        if let injectedIdentityMetadataRetryAdapter {
            await performIdentityMetadataRetry(
                durableIdentity: durableIdentity,
                adapter: injectedIdentityMetadataRetryAdapter
            )
            return
        }

        guard let workoutSession = session,
              let workoutBuilder = builder else {
            finishRequestError = .reconciliationFailed
            return
        }

        await performIdentityMetadataRetry(
            durableIdentity: durableIdentity,
            adapter: WatchWorkoutIdentityMetadataRetryAdapter(
                attachMetadata: {
                    try await workoutBuilder.addMetadata(
                        Self.workoutIdentityMetadata(
                            sessionID: durableIdentity.sessionID
                        )
                    )
                },
                isContextCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.session === workoutSession
                        && self.builder === workoutBuilder
                        && self.lifecycle.state == .ending
                        && self.lifecycle.finishDisposition == disposition
                },
                resumeFinalization: { [weak self] in
                    guard let self else { return }
                    self.stopSessionForFinalization(
                        workoutSession,
                        at: self.authoritativeFinalizationEndDate
                            ?? workoutSession.endDate
                            ?? durableIdentity.finishRequest?.requestedAt
                            ?? Date()
                    )
                }
            )
        )
    }

    private func performIdentityMetadataRetry(
        durableIdentity: WatchWorkoutRecoveryStore.Identity,
        adapter: WatchWorkoutIdentityMetadataRetryAdapter
    ) async {
        do {
            try await adapter.attachMetadata()
            guard adapter.isContextCurrent() else {
                return
            }
            identity = recoveryStore.recoveredIdentity ?? durableIdentity
            isIdentityMetadataRetryPending = false
            isBuilderReadyForFinalization = true
            finishRequestError = nil
            lastErrorCode = nil
            adapter.resumeFinalization()
        } catch {
            guard adapter.isContextCurrent() else {
                return
            }
            _ = retainCollectedFinishForIdentityMetadataRetry(error)
        }
    }

    private func recoverActiveWorkoutIfPresent() async -> WorkoutRecoveryAttemptOutcome {
        let result = await recoverActiveWorkoutSession()
        if result.error != nil {
            return .failed
        }
        guard let recoveredSession = result.session else {
            return await recoverDetachedFinalizationIfPresent()
        }
        guard recoveredSession.type == .primary else { return .none }
        if session == nil, lifecycle.state == .ending {
            lifecycle = WorkoutLifecycleReducer()
            finishRequestError = nil
        }
        let wasEndedBeforeMetadataRepair = recoveredSession.state == .ended

        let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
        if let terminalOutcome = recoverTerminalTombstoneSessionIfPresent(
            using: WatchRecoveredTerminalSessionAdapter(
                metadata: { recoveredBuilder.metadata },
                startDate: recoveredSession.startDate,
                sessionState: { recoveredSession.state },
                attachRuntime: { [weak self] in
                    guard let self else { return }
                    recoveredSession.delegate = self
                    self.session = recoveredSession
                    self.builder = recoveredBuilder
                },
                stopSession: { date in
                    recoveredSession.stopActivity(with: date)
                },
                discardWorkout: {
                    recoveredBuilder.discardWorkout()
                },
                endSession: {
                    recoveredSession.end()
                },
                releaseSession: { [weak self] in
                    guard let self, self.session === recoveredSession else {
                        return
                    }
                    self.session = nil
                    self.builder = nil
                }
            )
        ) {
            return terminalOutcome
        }
        recoveredBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: recoveredSession.workoutConfiguration
        )

        let startDate = recoveredSession.startDate
            ?? recoveryStore.recoveredIdentity?.startDate
            ?? Date()
        guard var recoveredIdentity = await recoverWorkoutIdentity(
            using: WatchRecoveredWorkoutIdentityAdapter(
                metadata: { recoveredBuilder.metadata },
                startDate: startDate,
                sessionState: { recoveredSession.state },
                endDate: { recoveredSession.endDate },
                attachMetadata: { metadata in
                    try await recoveredBuilder.addMetadata(metadata)
                }
            )
        ) else {
            return .failed
        }
        let isEndedAfterMetadataRepair = recoveredSession.state == .ended
        recoveredSession.delegate = self
        recoveredBuilder.delegate = self
        let recoveredState = recoveredSession.state
        let adoptionAction = WorkoutRecoveredSessionAdoptionPolicy.action(
            wasEndedBeforeMetadataRepair: wasEndedBeforeMetadataRepair,
            isEndedAfterMetadataRepair: isEndedAfterMetadataRepair,
            isStoppedAfterMetadataRepair: recoveredState == .stopped,
            pendingDisposition: recoveredIdentity.finishRequest?.disposition
        )
        if [.stopped, .ended].contains(recoveredState),
           recoveredIdentity.finishRequest == nil {
            let disposition: WorkoutFinishDisposition
            if recoveredIdentity.corruptResetPendingFinishChoice == true {
                disposition = .discard
            } else {
                switch adoptionAction {
                case .adoptStopped(let terminalDisposition),
                     .adoptEnded(let terminalDisposition):
                    disposition = terminalDisposition
                case .adopt:
                    disposition = .save
                }
            }
            do {
                try recoveryStore.markFinishing(
                    disposition: disposition,
                    requestedAt: recoveredSession.endDate ?? Date(),
                    explicitRiderChoice: false
                )
                guard let updatedIdentity = recoveryStore.recoveredIdentity else {
                    return .failed
                }
                recoveredIdentity = updatedIdentity
            } catch {
                recoveredSession.delegate = nil
                recoveredBuilder.delegate = nil
                return .failed
            }
        }
        adoptRecoveredIdentityForRuntime(recoveredIdentity)
        let recoveredFinishRequest = recoveredIdentity.finishRequest
        session = recoveredSession
        builder = recoveredBuilder
        restoreSegmentAccumulator(
            from: recoveredBuilder,
            workoutStart: recoveredIdentity.startDate
        )
        seedManualTransitionRequestWatermark(
            from: recoveredBuilder,
            workoutStart: recoveredIdentity.startDate
        )
        await restoreRideTransition(
            from: recoveredBuilder,
            sessionState: recoveredState,
            workoutStart: recoveredIdentity.startDate
        )
        isBuilderReadyForFinalization = true
        isIdentityMetadataRetryPending = false
        isTerminalPublicationPending = false
        _ = lifecycle.apply(.requestStart)
        switch recoveredState {
        case .running:
            _ = lifecycle.apply(.sessionRunning)
        case .paused:
            _ = lifecycle.apply(.sessionRunning)
            _ = lifecycle.apply(.sessionPaused)
        case .ended:
            _ = lifecycle.apply(.sessionRunning)
        case .stopped:
            _ = lifecycle.apply(.sessionRunning)
        case .notStarted, .prepared:
            break
        @unknown default:
            handleStartFailure(nil)
            return .failed
        }

        if recoveredState == .stopped {
            _ = lifecycle.apply(
                .requestEnd(recoveredFinishRequest?.disposition ?? .save)
            )
            authoritativeFinalizationEndDate = recoveredSession.endDate
                ?? recoveredFinishRequest?.requestedAt
        } else if let recoveredFinishRequest {
            _ = lifecycle.apply(.requestEnd(recoveredFinishRequest.disposition))
            authoritativeFinalizationEndDate = recoveredFinishRequest.requestedAt
        }

        updateAllMetrics(from: recoveredBuilder, capturedAt: Date())
        resumePersistedRemoteSegmentIntentIfNeeded()
        setupState = .ready
        startMirroringIfNeeded(for: recoveredSession)
        publishSnapshotImmediately()

        if [.stopped, .ended].contains(recoveredState),
           (recoveredFinishRequest?.disposition ?? .save) == .save {
            await resumeRecoveredStoppedSaveFinalization()
            return .recovered
        }

        attachRecoveredRouteBuilder(
            recoveredBuilder,
            startDate: startDate
        )
        if lifecycle.state == .paused {
            routeRecorder.setPaused(true, at: Date())
        }
        if lifecycle.state == .ending {
            routeRecorder.stopLocationUpdates()
            let recoveryEndDate = authoritativeFinalizationEndDate
                ?? recoveredSession.endDate
                ?? Date()
            if recoveredIdentity.corruptResetPendingFinishChoice == true,
               recoveredFinishRequest?.disposition == .discard {
                handleRecoveredDiscardSessionState(
                    recoveredState,
                    transitionDate: recoveryEndDate,
                    adapter: WatchRecoveredDiscardSessionAdapter(
                        stopSession: { date in
                            recoveredSession.stopActivity(with: date)
                        },
                        finalizeStoppedSession: { [weak self] date in
                            self?.beginFinalizationAfterStop(at: date)
                        }
                    )
                )
            } else {
                stopSessionForFinalization(
                    recoveredSession,
                    at: recoveryEndDate
                )
            }
        } else {
            startPeriodicSnapshots()
        }
        return .recovered
    }

    func handleRecoveredDiscardSessionState(
        _ state: HKWorkoutSessionState,
        transitionDate: Date,
        adapter: WatchRecoveredDiscardSessionAdapter
    ) {
        switch state {
        case .stopped, .ended:
            adapter.finalizeStoppedSession(transitionDate)
        case .running, .paused, .notStarted, .prepared:
            adapter.stopSession(transitionDate)
        @unknown default:
            adapter.stopSession(transitionDate)
        }
    }

    /// Owns the exact local-store/HealthKit identity adoption boundary used by
    /// active-session recovery. The adapter lets Watch tests execute the
    /// production manager path without synthesizing HealthKit session objects.
    func recoverWorkoutIdentity(
        using adapter: WatchRecoveredWorkoutIdentityAdapter
    ) async -> WatchWorkoutRecoveryStore.Identity? {
        let metadata = adapter.metadata()
        let containsIdentityMetadata = Self.containsWorkoutIdentityMetadata(
            metadata
        )
        let builderSessionID = Self.workoutIdentitySessionID(from: metadata)
        let isCorruptResetAuthorized = recoveryStore
            .authorizesCorruptResetRecovery(startDate: adapter.startDate)
        let resetProtectedIdentity = recoveryStore.recoveredIdentity.map {
            $0.corruptResetPendingFinishChoice == true
                && $0.finishRequest?.disposition == .discard
        } ?? false
        guard !containsIdentityMetadata
                || builderSessionID != nil
                || isCorruptResetAuthorized
                || resetProtectedIdentity else {
            return nil
        }

        let hasDurableIdentity = recoveryStore.recoveredIdentity != nil
        var discardTerminalAt: Date?
        if !hasDurableIdentity {
            // The builder UUID cannot reconstruct a lost finish disposition or
            // terminal tombstones. Ordinary adoption is allowed only when the
            // store was confirmed absent and the HealthKit session is active.
            // A rider-confirmed corrupt reset carries a durable one-shot
            // authorization that additionally permits stopped/ended adoption,
            // but only with a prewritten discard disposition.
            let sessionState = adapter.sessionState()
            if isCorruptResetAuthorized {
                guard [.running, .paused, .stopped, .ended]
                    .contains(sessionState) else {
                    return nil
                }
                if builderSessionID == nil {
                    return try? recoveryStore.useCorruptResetDiscardIdentity(
                        startDate: adapter.startDate,
                        requestedAt: adapter.endDate() ?? Date()
                    )
                }
                if [.stopped, .ended].contains(sessionState) {
                    discardTerminalAt = adapter.endDate() ?? Date()
                } else if !Self.canAdoptRecoveredIdentity(
                    sessionState: sessionState
                ) {
                    return nil
                }
            } else {
                guard recoveryStore.loadState == .missing,
                      builderSessionID != nil,
                      Self.canAdoptRecoveredIdentity(
                          sessionState: sessionState
                      ) else {
                    return nil
                }
            }
        }

        do {
            var recoveredIdentity = try recoveryStore.useRecoveredIdentity(
                startDate: adapter.startDate,
                stableSessionID: builderSessionID,
                discardTerminalAt: discardTerminalAt
            )
            if let builderSessionID {
                guard builderSessionID
                        == (recoveredIdentity.healthKitSessionID
                            ?? recoveredIdentity.sessionID) else {
                    return nil
                }
            } else if resetProtectedIdentity,
                      recoveredIdentity.finishRequest?.disposition == .discard {
                // Rider-authorized metadata-less cleanup deliberately never
                // attaches a synthetic UUID to a builder that will be discarded.
            } else {
                let identityMetadata = Self.workoutIdentityMetadata(
                    sessionID: recoveredIdentity.sessionID
                )
                try await adapter.attachMetadata(identityMetadata)
                guard Self.workoutIdentitySessionID(from: adapter.metadata())
                        == recoveredIdentity.sessionID else {
                    return nil
                }
            }
            if recoveredIdentity.corruptResetPendingFinishChoice == true,
               recoveredIdentity.finishRequest == nil,
               [.stopped, .ended].contains(adapter.sessionState()) {
                try recoveryStore.markFinishing(
                    disposition: .discard,
                    requestedAt: adapter.endDate() ?? Date(),
                    explicitRiderChoice: false
                )
                guard let updatedIdentity = recoveryStore.recoveredIdentity else {
                    return nil
                }
                recoveredIdentity = updatedIdentity
            }
            return recoveredIdentity
        } catch {
            return nil
        }
    }

    private func recoverDetachedFinalizationIfPresent() async -> WorkoutRecoveryAttemptOutcome {
        guard let recoveredIdentity = recoveryStore.recoveredIdentity,
              let request = recoveredIdentity.finishRequest else {
            return .none
        }

        if lifecycle.state == .ended,
           confirmedTerminalSummarySessionID == recoveredIdentity.sessionID,
           summary != nil,
           isTerminalPublicationPending || isTerminalArchivePending {
            // The HealthKit result and rich summary were already confirmed in
            // this process. A queued no-session recovery signal must retry
            // only durable publication/archival, never replace that summary
            // with the intentionally lossy relaunch reconstruction.
            identity = recoveredIdentity
            setupState = .ready
            if isTerminalPublicationPending {
                retryTerminalPublicationAndArchive()
            } else {
                retryDetachedSessionCleanup()
            }
            return .recovered
        }

        guard restoreDetachedFinalizationLifecycle(from: recoveredIdentity) else {
            return .failed
        }
        setupState = .ready
        publishSnapshotImmediately()
        if let injectedDetachedRecoveryPause {
            await injectedDetachedRecoveryPause()
        }

        if request.disposition == .discard {
            if recoveredIdentity.corruptResetPendingFinishChoice == true {
                // A reset-protected identity may represent a metadata-less
                // session, so a synthetic tombstone cannot match a late
                // callback. Keep the durable discard attached until the real
                // session is recovered and its builder is actually discarded.
                finishRequestError = .reconciliationFailed
                return .recovered
            }
            // Move completed no-session discards into a bounded tombstone.
            // This releases the UI while preserving an explicit discard-only
            // instruction for any genuinely late matching HealthKit builder.
            completeDetachedDiscardFinalization(
                summary: makeSummary(
                    outcome: .discarded,
                    endDate: request.requestedAt,
                    routeDistanceMeters: nil,
                    routeStatus: .unavailable
                )
            )
            return .recovered
        }

        switch request.phase {
        case .workoutSaved, .finishAttempted:
            await reconcileDetachedSave()
        case .requested, .collectionEnded:
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
        }
        return .recovered
    }

    @discardableResult
    func restoreDetachedFinalizationLifecycle(
        from recoveredIdentity: WatchWorkoutRecoveryStore.Identity
    ) -> Bool {
        guard let request = recoveredIdentity.finishRequest else { return false }
        if lifecycle.state == .ending {
            guard lifecycle.finishDisposition == request.disposition else {
                return false
            }
            adoptRecoveredIdentityForRuntime(recoveredIdentity)
            return true
        }
        guard lifecycle.apply(.requestStart),
              lifecycle.apply(.sessionRunning),
              lifecycle.apply(.requestEnd(request.disposition)) else {
            return false
        }
        adoptRecoveredIdentityForRuntime(recoveredIdentity)
        return true
    }

    func reconcileDetachedSave() async {
        guard !isDetachedSaveReconciliationInProgress,
              session == nil,
              let identity = recoveryStore.recoveredIdentity ?? identity,
              let request = identity.finishRequest,
              request.disposition == .save else {
            finishRequestError = .reconciliationFailed
            return
        }
        let expectedPhase = request.phase
        guard expectedPhase == .workoutSaved
                || expectedPhase == .finishAttempted else {
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
            return
        }
        isDetachedSaveReconciliationInProgress = true
        defer { isDetachedSaveReconciliationInProgress = false }
        let expectedSessionID = identity.sessionID
        let expectedStartDate = identity.startDate
        do {
            let workout = try await savedWorkout(
                externalUUID: identity.sessionID.uuidString,
                startDate: identity.startDate
            )
            guard session == nil,
                  lifecycle.state == .ending,
                  let currentIdentity = recoveryStore.recoveredIdentity,
                  currentIdentity.sessionID == expectedSessionID,
                  abs(
                      currentIdentity.startDate.timeIntervalSince(expectedStartDate)
                  ) <= 2,
                  currentIdentity.finishRequest?.disposition == .save,
                  currentIdentity.finishRequest?.phase == expectedPhase else {
                finishRequestError = .reconciliationFailed
                return
            }
            guard let workout else {
                if expectedPhase == .workoutSaved {
                    completeDetachedFinalization(
                        summary: makeDetachedSavedSummary(identity: identity)
                    )
                    return
                }
                // Query visibility is not authoritative evidence that a prior
                // finishWorkout call failed. Keep commit-unknown recovery
                // reconciliation-only to prevent a duplicate HealthKit save.
                finishRequestError = .reconciliationFailed
                publishSnapshotImmediately()
                return
            }
            reconciledSavedWorkout = workout
            if expectedPhase == .finishAttempted {
                try? recoveryStore.markWorkoutSaved()
            }
            if let durableIdentity = recoveryStore.recoveredIdentity {
                self.identity = durableIdentity
            }
            completeDetachedFinalization(
                summary: makeSummary(
                    from: workout,
                    routeStatus: request.routeStatus ?? .unknown
                )
            )
        } catch {
            if expectedPhase == .workoutSaved {
                completeDetachedFinalization(
                    summary: makeDetachedSavedSummary(identity: identity)
                )
                return
            }
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
        }
    }

    private func completeDetachedFinalization(summary: WatchWorkoutSummary) {
        completeConfirmedSave(
            summary: summary,
            savedAt: summary.endedAt
        )
        routeRecorder.completeAfterWorkoutAlreadySaved()
    }

    private func completeDetachedDiscardFinalization(
        summary: WatchWorkoutSummary
    ) {
        completeConfirmedDiscard(
            summary: summary,
            discardedAt: summary.endedAt
        )
        routeRecorder.discardRoute()
    }

    func recoverTerminalTombstoneSessionIfPresent(
        using adapter: WatchRecoveredTerminalSessionAdapter,
        transitionDate: Date = Date()
    ) -> WorkoutRecoveryAttemptOutcome? {
        guard let tombstone = terminalTombstoneForRecoveredSession(
            metadata: adapter.metadata(),
            startDate: adapter.startDate
        ) else {
            return nil
        }
        adapter.attachRuntime()
        terminalCleanupSessionID = tombstone.sessionID
        terminalCleanupDisposition = tombstone.disposition
        setupState = .ready

        handleTerminalTombstoneSessionState(
            adapter.sessionState(),
            transitionDate: transitionDate,
            disposition: tombstone.disposition,
            adapter: WatchTerminalSessionCleanupAdapter(
                stopSession: { date in
                    adapter.stopSession(date)
                },
                completeSession: { [weak self] _ in
                    self?.completeTerminalTombstoneCleanup(
                        sessionID: tombstone.sessionID,
                        disposition: tombstone.disposition,
                        discardWorkout: adapter.discardWorkout,
                        endSession: adapter.endSession,
                        releaseSession: adapter.releaseSession
                    )
                }
            )
        )
        return .recovered
    }

    func terminalTombstoneForRecoveredSession(
        metadata: [String: Any],
        startDate: Date?
    ) -> WatchWorkoutRecoveryStore.TerminalTombstone? {
        recoveryStore.terminalTombstone(
            externalUUID: metadata[HKMetadataKeyExternalUUID] as? String,
            recoveredSessionStartDate: startDate
        )
    }

    func handleTerminalTombstoneSessionState(
        _ state: HKWorkoutSessionState,
        transitionDate: Date,
        disposition: WorkoutFinishDisposition,
        adapter: WatchTerminalSessionCleanupAdapter
    ) {
        switch state {
        case .stopped, .ended, .notStarted, .prepared:
            adapter.completeSession(disposition)
        case .running, .paused:
            adapter.stopSession(transitionDate)
        @unknown default:
            adapter.stopSession(transitionDate)
        }
    }

    func completeTerminalTombstoneSessionCleanup(
        _ recoveredSession: HKWorkoutSession,
        builder recoveredBuilder: HKLiveWorkoutBuilder,
        sessionID: UUID,
        disposition: WorkoutFinishDisposition
    ) {
        recoveredSession.delegate = nil
        completeTerminalTombstoneCleanup(
            sessionID: sessionID,
            disposition: disposition,
            discardWorkout: {
                recoveredBuilder.discardWorkout()
            },
            endSession: {
                recoveredSession.end()
            },
            releaseSession: { [weak self] in
                guard let self, self.session === recoveredSession else { return }
                self.session = nil
                self.builder = nil
            }
        )
    }

    func completeTerminalTombstoneCleanup(
        sessionID: UUID,
        disposition: WorkoutFinishDisposition,
        discardWorkout: () -> Void,
        endSession: () -> Void,
        releaseSession: () -> Void
    ) {
        if disposition == .discard {
            discardWorkout()
        }
        endSession()
        try? recoveryStore.removeTerminalTombstone(sessionID: sessionID)
        releaseSession()
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        setupState = .ready
        let hasCurrentActiveIdentity = recoveryStore.recoveredIdentity != nil
        let hasQueuedRecovery = recoverySignalQueue.consumeAfterSessionRelease()
        if hasCurrentActiveIdentity {
            _ = recoverySignalQueue.recordSignal(hasAttachedSession: false)
        }
        if hasCurrentActiveIdentity || hasQueuedRecovery {
            if !isRecoveryLoopRunning {
                isRecovering = false
                startRecoveryLoopIfNeeded()
            }
        } else {
            isRecovering = false
        }
        drainPendingWorkoutConfigurationIfPossible()
        reconcilePendingWorkoutLaunchRequest()
    }

    private func attachRecoveredRouteBuilder(
        _ recoveredBuilder: HKLiveWorkoutBuilder,
        startDate: Date
    ) {
        let routeBuilder = recoveredBuilder.seriesBuilder(
            for: HKSeriesType.workoutRoute()
        ) as? HKWorkoutRouteBuilder
        routeRecorder.begin(
            routeBuilder: routeBuilder,
            startDate: startDate,
            mayContainExistingRouteData: true
        ) { [weak self] in
            self?.scheduleCoalescedSnapshot()
        }
    }

    func resumeRecoveredStoppedSaveFinalization() async {
        let runtimeAdapter: WatchRecoveredSaveRuntimeAdapter
        if let injectedRecoveredSaveRuntimeAdapter {
            runtimeAdapter = injectedRecoveredSaveRuntimeAdapter
        } else if let workoutSession = session,
                  let workoutBuilder = builder {
            runtimeAdapter = WatchRecoveredSaveRuntimeAdapter(
                session: workoutSession,
                builder: workoutBuilder,
                sessionState: { workoutSession.state }
            )
        } else {
            finishRequestError = .reconciliationFailed
            return
        }
        let workoutSession = runtimeAdapter.session
        let workoutBuilder = runtimeAdapter.builder
        guard lifecycle.state == .ending,
              finalizationTask == nil,
              Self.canRetryFinalization(
                  sessionState: runtimeAdapter.sessionState()
              ) else {
            finishRequestError = .reconciliationFailed
            return
        }
        guard var durableIdentity = recoveryStore.recoveredIdentity ?? identity else {
            finishRequestError = .reconciliationFailed
            return
        }
        let hadPendingRollback = isFinishFailureRollbackPending
        guard WatchFinishFailureRollbackCoordinator.persistBeforeRetry(
            isPending: &isFinishFailureRollbackPending,
            markFinishFailed: { [recoveryStore] in
                try recoveryStore.markFinishFailed()
            }
        ) else {
            finishRequestError = .saveFailed
            return
        }
        if hadPendingRollback {
            guard let rolledBackIdentity = recoveryStore.recoveredIdentity else {
                finishRequestError = .saveFailed
                return
            }
            durableIdentity = rolledBackIdentity
            identity = rolledBackIdentity
        }
        identity = durableIdentity
        let expectedSessionID = durableIdentity.sessionID
        let expectedStartDate = durableIdentity.startDate
        requiresRecoveredSaveReconciliation = true

        await performRecoveredSaveReconciliation(
            resolve: { [self] in
                if let injectedRecoveredSaveResolver {
                    return await injectedRecoveredSaveResolver(
                        workoutBuilder,
                        durableIdentity
                    )
                }
                return await resolveRecoveredSave(
                    builder: workoutBuilder,
                    identity: durableIdentity
                )
            },
            isContextCurrent: { [self] in
                session === workoutSession
                    && builder === workoutBuilder
                    && lifecycle.state == .ending
                    && finalizationTask == nil
                    && Self.canRetryFinalization(
                        sessionState: runtimeAdapter.sessionState()
                    )
                    && isBuilderReadyForFinalization
                    && recoveryStore.recoveredIdentity.map {
                        $0.sessionID == expectedSessionID
                            && abs(
                                $0.startDate.timeIntervalSince(expectedStartDate)
                            ) <= 2
                            && $0.finishRequest?.disposition == .save
                    } == true
            },
            apply: { [self] resolution in
                applyRecoveredSaveResolution(
                    resolution,
                    durableIdentity: durableIdentity,
                    workoutBuilder: workoutBuilder,
                    workoutSession: workoutSession
                )
            }
        )
    }

    /// Runs the saved-workout query while holding the same gate consulted by
    /// session callbacks, then applies the selected mode synchronously after
    /// post-await context validation and gate release.
    func performRecoveredSaveReconciliation(
        resolve: () async -> RecoveredSaveResolution,
        isContextCurrent: () -> Bool,
        apply: (RecoveredSaveResolution) -> Void
    ) async {
        guard recoveredSaveReconciliationGate.begin() else { return }
        var reconciliationGateHeld = true
        defer {
            if reconciliationGateHeld {
                recoveredSaveReconciliationGate.end()
            }
        }

        let resolution = await resolve()
        guard isContextCurrent() else {
            finishRequestError = .reconciliationFailed
            return
        }
        recoveredSaveReconciliationGate.end()
        reconciliationGateHeld = false
        apply(resolution)
    }

    private func applyRecoveredSaveResolution(
        _ resolution: RecoveredSaveResolution,
        durableIdentity originalIdentity: WatchWorkoutRecoveryStore.Identity,
        workoutBuilder: HKLiveWorkoutBuilder,
        workoutSession: HKWorkoutSession
    ) {
        var durableIdentity = originalIdentity
        switch resolution.action {
        case .retryReconciliation:
            finishRequestError = .reconciliationFailed
            return
        case .finalize(let mode):
            if !persistQueryConfirmedSaveBeforeTerminalization(
                resolution.workout != nil
            ) {
                finishRequestError = .reconciliationFailed
                return
            }
            if resolution.workout != nil {
                guard let confirmedIdentity = recoveryStore.recoveredIdentity else {
                    finishRequestError = .reconciliationFailed
                    return
                }
                durableIdentity = confirmedIdentity
                identity = confirmedIdentity
            }
            finishRequestError = nil
            reconciledSavedWorkout = resolution.workout
            if mode == .full,
               preparedRouteForFinalization == nil {
                attachRecoveredRouteBuilder(
                    workoutBuilder,
                    startDate: durableIdentity.startDate
                )
                routeRecorder.stopLocationUpdates()
            }
            beginRecoveredSaveFinalization(
                mode: mode,
                at: workoutSession.endDate
                    ?? durableIdentity.finishRequest?.requestedAt
                    ?? Date()
            )
        }
    }

    func beginRecoveredSaveFinalization(
        mode: WorkoutSaveFinalizationMode,
        at endDate: Date
    ) {
        requiresRecoveredSaveReconciliation = false
        recoveredSaveMode = mode
        beginFinalizationAfterStop(at: endDate)
    }

    private func resolveRecoveredSave(
        builder: HKLiveWorkoutBuilder,
        identity: WatchWorkoutRecoveryStore.Identity
    ) async -> RecoveredSaveResolution {
        if let reconciledSavedWorkout {
            return RecoveredSaveResolution(
                action: .finalize(.alreadySaved),
                workout: reconciledSavedWorkout
            )
        }
        let phase = identity.finishRequest?.phase ?? .requested
        if phase == .workoutSaved {
            return RecoveredSaveResolution(
                action: .finalize(.alreadySaved),
                workout: nil
            )
        }

        let externalUUID = injectedRecoveredSaveRuntimeAdapter?
            .externalUUID?()
            ?? builder.metadata[HKMetadataKeyExternalUUID] as? String
        let builderCollectionEnded = injectedRecoveredSaveRuntimeAdapter?
            .builderCollectionEnded?()
            ?? (builder.endDate != nil)
        guard let externalUUID,
              externalUUID == identity.sessionID.uuidString else {
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: .unavailable
                ),
                workout: nil
            )
        }

        do {
            let workout = try await savedWorkout(
                externalUUID: externalUUID,
                startDate: identity.startDate
            )
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: workout == nil ? .notFound : .found
                ),
                workout: workout
            )
        } catch {
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: .queryFailed
                ),
                workout: nil
            )
        }
    }

    private func beginFinalizationAfterStop(at endDate: Date) {
        guard recoveredSaveReconciliationGate.allowsFinalization,
              !requiresRecoveredSaveReconciliation,
              !isFinishFailureRollbackPending,
              pendingTerminalErrorPersistence == nil else {
            return
        }
        if let injectedFinalizationClaimObserver {
            guard finalizationTask == nil,
                  lifecycle.claimFinalization() != nil else {
                return
            }
            injectedFinalizationClaimObserver(recoveredSaveMode)
            return
        }
        guard isBuilderReadyForFinalization
                || injectedRecoveredDiscardFinalizationAdapter != nil,
              finalizationTask == nil,
              let disposition = lifecycle.claimFinalization() else {
            return
        }
        let resolvedEndDate = WorkoutFinalizationEndDatePolicy.resolve(
            authoritativeEndDate: authoritativeFinalizationEndDate,
            callbackDate: endDate
        )
        authoritativeFinalizationEndDate = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            await finalize(disposition: disposition, endDate: resolvedEndDate)
            finalizationTask = nil
        }
    }

    func handleSessionReadyForFinalization(at endDate: Date) {
        switch WorkoutSessionFailurePolicy.action(for: lifecycle.state) {
        case .failStart:
            handleStartFailure(nil)
        case .savePartialWorkout:
            requestEnd(.save, requestedAt: endDate)
        case .finishRequestedDisposition:
            beginFinalizationAfterStop(at: endDate)
        case .ignore:
            break
        }
    }

    /// A reset-authorized cleanup can be adopted before HealthKit exposes its
    /// stable metadata. Re-read it at the final non-destructive boundary so a
    /// queued recovery callback can match the terminal tombstone by the real
    /// builder UUID. A failed bind keeps the stopped builder and session for
    /// an explicit retry.
    private func bindRecoveredDiscardIdentityBeforeFinalization(
        metadata: [String: Any]
    ) -> Bool {
        guard let currentIdentity = recoveryStore.recoveredIdentity,
              currentIdentity.finishRequest?.disposition == .discard,
              currentIdentity.corruptResetPendingFinishChoice == true,
              currentIdentity.corruptResetSyntheticCleanupIdentity == true,
              currentIdentity.healthKitSessionID == nil,
              let stableSessionID = Self.workoutIdentitySessionID(from: metadata) else {
            return true
        }

        do {
            let reboundIdentity = try recoveryStore.useRecoveredIdentity(
                startDate: currentIdentity.startDate,
                stableSessionID: stableSessionID
            )
            guard reboundIdentity.sessionID == currentIdentity.sessionID,
                  reboundIdentity.healthKitSessionID == stableSessionID
                    || reboundIdentity.sessionID == stableSessionID else {
                lifecycle.releaseFinalizationClaimForRetry()
                finishRequestError = .reconciliationFailed
                lastErrorCode = .sessionFailed
                return false
            }
            identity = reboundIdentity
            return true
        } catch {
            lifecycle.releaseFinalizationClaimForRetry()
            finishRequestError = .reconciliationFailed
            lastErrorCode = .sessionFailed
            return false
        }
    }

    private func finalize(
        disposition: WorkoutFinishDisposition,
        endDate: Date
    ) async {
        if disposition == .save,
           !allowsSavingWithUnconfirmedSegment {
            let segmentResolved =
                await waitForSegmentOperationBeforeFinalization()
            guard segmentResolved else {
                lifecycle.releaseFinalizationClaimForRetry()
                finishRequestError = .segmentConfirmationPending
                segmentError = .confirmationPending
                lastErrorCode = .segmentFinalizationPending
                publishSnapshotImmediately()
                return
            }
        }
        if disposition == .discard {
            let metadata = injectedRecoveredDiscardFinalizationAdapter?
                .metadata()
                ?? builder?.metadata
                ?? [:]
            guard bindRecoveredDiscardIdentityBeforeFinalization(
                metadata: metadata
            ) else {
                return
            }
        }
        if disposition == .discard,
           let adapter = injectedRecoveredDiscardFinalizationAdapter {
            do {
                let outcome = try await WorkoutFinalizationOrchestrator.run(
                    disposition: .discard,
                    discardWorkout: {
                        adapter.discardWorkout()
                    },
                    discardRoute: {
                        adapter.discardRoute()
                    },
                    prepareRoute: {
                        WorkoutPreparedRoute(
                            routeStatus: .unavailable,
                            distanceMeters: nil
                        )
                    },
                    endCollection: {},
                    finishWorkout: {},
                    endSession: {
                        adapter.endSession()
                    }
                )
                guard outcome == .discarded else { return }
                completeConfirmedDiscard(
                    summary: makeSummary(
                        outcome: .discarded,
                        endDate: endDate,
                        routeDistanceMeters: nil,
                        routeStatus: .unavailable
                    ),
                    discardedAt: endDate
                )
            } catch {
                lifecycle.releaseFinalizationClaimForRetry()
                finishRequestError = .saveFailed
            }
            return
        }
        guard let builder, session != nil else {
            handleStartFailure(nil)
            return
        }

        do {
            let saveMode = recoveredSaveMode ?? .full
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: disposition,
                saveMode: saveMode,
                discardWorkout: {
                    builder.discardWorkout()
                },
                discardRoute: { [routeRecorder] in
                    routeRecorder.discardRoute()
                },
                completeAlreadySavedRoute: { [routeRecorder] in
                    routeRecorder.completeAfterWorkoutAlreadySaved()
                },
                prepareRoute: { [routeRecorder] in
                    if let preparedRouteForFinalization = self.preparedRouteForFinalization {
                        return preparedRouteForFinalization
                    }
                    let route = await routeRecorder.prepareForWorkoutFinalization()
                    self.preparedRouteForFinalization = route
                    return route
                },
                recoveredRouteStatus: identity?.finishRequest?.routeStatus ?? .unknown,
                markPreparedRoute: { [recoveryStore] status in
                    try recoveryStore.markPreparedRoute(status)
                },
                endCollection: { [weak self] in
                    guard let self else { throw WorkoutFinalizationError.managerReleased }
                    guard await closeFinalSegmentIfNeeded(
                        in: builder,
                        at: endDate
                    ) else {
                        throw WorkoutSegmentWriteError.finalizationPending
                    }
                    try await endCollection(builder, at: endDate)
                    updateAllMetrics(from: builder, capturedAt: endDate)
                },
                markCollectionEnded: { [recoveryStore] in
                    try recoveryStore.markCollectionEnded()
                },
                markFinishAttempted: { [recoveryStore] in
                    try recoveryStore.markFinishAttempted()
                },
                finishWorkout: { [weak self] in
                    guard let self else { throw WorkoutFinalizationError.managerReleased }
                    try await finishWorkout(builder)
                },
                markFinishFailed: { [recoveryStore] in
                    try recoveryStore.markFinishFailed()
                },
                markWorkoutSaved: { [recoveryStore] in
                    try recoveryStore.markWorkoutSaved()
                },
                workoutSavedPersistenceFailed: { [weak self] in
                    self?.isTerminalArchivePending = true
                },
                // The primary session is ended only after the final full
                // snapshot has been handed to HealthKit's mirror transport.
                endSession: {}
            )
            switch outcome {
            case .discarded:
                let summary = makeSummary(
                    outcome: .discarded,
                    endDate: endDate,
                    routeDistanceMeters: nil,
                    routeStatus: .unavailable
                )
                completeConfirmedDiscard(
                    summary: summary,
                    discardedAt: endDate
                )
            case .saved(let route):
                let summary: WatchWorkoutSummary
                if let reconciledSavedWorkout {
                    summary = makeSummary(
                        from: reconciledSavedWorkout,
                        routeStatus: route.routeStatus
                    )
                } else {
                    let route = preparedRouteForFinalization ?? route
                    terminalRouteDistance = WorkoutTerminalRouteDistancePolicy.candidate(
                        distanceMeters: route.distanceMeters,
                        capturedAt: endDate
                    )
                    summary = makeSummary(
                        outcome: .saved,
                        endDate: endDate,
                        routeDistanceMeters: route.distanceMeters,
                        routeStatus: route.routeStatus
                    )
                }
                completeConfirmedSave(
                    summary: summary,
                    savedAt: endDate
                )
            }
        } catch {
            handleFinalizationFailure(error)
        }
    }

    func handleFinalizationFailure(_ error: Error) {
        if case WorkoutSegmentWriteError.finalizationPending = error {
            lifecycle.releaseFinalizationClaimForRetry()
            finishRequestError = .segmentConfirmationPending
            if segmentError == nil {
                segmentError = .confirmationPending
            }
            lastErrorCode = .segmentFinalizationPending
            publishSnapshotImmediately()
            return
        }
        if case WorkoutFinalizationPersistenceError
            .finishFailureRollbackPending = error {
            isFinishFailureRollbackPending = true
        }
        lastErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: pendingTerminalErrorPersistence?.code,
            persistedFinishError: durableTerminalErrorCode
        ) ?? .sessionFailed
        lifecycle.releaseFinalizationClaimForRetry()
        finishRequestError = pendingTerminalErrorPersistence == nil
            ? .saveFailed
            : .terminalErrorPersistenceFailed
        publishSnapshotImmediately()
    }

    func completeConfirmedSave(
        summary: WatchWorkoutSummary,
        savedAt: Date
    ) {
        if pendingTerminalErrorPersistence != nil {
            pendingTerminalCauseConfirmedCompletion = .saved(
                summary: summary,
                at: savedAt
            )
            finishRequestError = .terminalErrorPersistenceFailed
            return
        }
        identity = identity ?? recoveryStore.recoveredIdentity
        let didPublish = WatchTerminalPublicationCoordinator.perform(
            publishTerminal: { [self] in
                completeFinalization(summary: summary)
            },
            archiveIdentity: { [self] in
                archiveConfirmedSave(at: savedAt)
            }
        )
        finishTerminalRuntimeAfterPublication(didPublish)
    }

    func completeConfirmedDiscard(
        summary: WatchWorkoutSummary,
        discardedAt: Date
    ) {
        if pendingTerminalErrorPersistence != nil {
            pendingTerminalCauseConfirmedCompletion = .discarded(
                summary: summary,
                at: discardedAt
            )
            finishRequestError = .terminalErrorPersistenceFailed
            return
        }
        identity = identity ?? recoveryStore.recoveredIdentity
        let didPublish = WatchTerminalPublicationCoordinator.perform(
            publishTerminal: { [self] in
                completeFinalization(summary: summary)
            },
            archiveIdentity: { [self] in
                archiveConfirmedDiscard(at: discardedAt)
            }
        )
        finishTerminalRuntimeAfterPublication(didPublish)
    }

    @discardableResult
    func persistQueryConfirmedSaveBeforeTerminalization(
        _ isConfirmed: Bool
    ) -> Bool {
        guard isConfirmed else { return true }
        do {
            // A stable-ID HealthKit match is authoritative even when the
            // local phase predates finishAttempted.
            try recoveryStore.markWorkoutSaved()
            identity = recoveryStore.recoveredIdentity
            return identity != nil
        } catch {
            return false
        }
    }

    private func archiveConfirmedSave(at savedAt: Date) {
        do {
            _ = try recoveryStore.archiveConfirmedSavedIdentity(at: savedAt)
            isTerminalArchivePending = false
            isTerminalPublicationPending = false
            confirmedTerminalSummarySessionID = nil
            confirmedTerminalSnapshot = nil
            identity = nil
            reconciledSavedWorkout = nil
        } catch {
            // HealthKit's successful finish callback is authoritative. Keep
            // the finish-attempt identity until its terminal tombstone can be
            // persisted; do not make another save call.
            isTerminalArchivePending = true
            isTerminalPublicationPending = false
            identity = recoveryStore.recoveredIdentity
        }
    }

    private func archiveConfirmedDiscard(at discardedAt: Date) {
        do {
            _ = try recoveryStore.archiveConfirmedDiscardedIdentity(
                at: discardedAt
            )
            isTerminalArchivePending = false
            isTerminalPublicationPending = false
            confirmedTerminalSummarySessionID = nil
            confirmedTerminalSnapshot = nil
            identity = nil
        } catch {
            isTerminalArchivePending = true
            isTerminalPublicationPending = false
            identity = recoveryStore.recoveredIdentity
        }
    }

    @discardableResult
    private func completeFinalization(
        summary: WatchWorkoutSummary
    ) -> Bool {
        guard pendingTerminalErrorPersistence == nil else {
            finishRequestError = .terminalErrorPersistenceFailed
            return false
        }
        let durableErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: summary.terminalErrorCode,
            persistedFinishError: recoveryStore.recoveredIdentity?
                .finishRequest?.terminalErrorCode
                ?? identity?.finishRequest?.terminalErrorCode
        )
        let terminalSummary = WatchWorkoutSummary(
            outcome: summary.outcome,
            endedAt: summary.endedAt,
            duration: summary.duration,
            distanceMeters: summary.distanceMeters,
            activeEnergyKilocalories: summary.activeEnergyKilocalories,
            averageHeartRate: summary.averageHeartRate,
            routeStatus: summary.routeStatus,
            terminalErrorCode: durableErrorCode
        )
        finishRequestError = nil
        pendingTerminalErrorPersistence = nil
        pendingTerminalErrorCodeForNextFinish = nil
        pendingTerminalCauseConfirmedCompletion = nil
        lastErrorCode = durableErrorCode
        confirmedTerminalSummarySessionID = (
            recoveryStore.recoveredIdentity ?? identity
        )?.sessionID
        self.summary = terminalSummary
        _ = lifecycle.apply(.sessionEnded)
        let terminalCapturedAt = max(Date(), terminalSummary.endedAt)
        let terminalSnapshot = makeTerminalSnapshot(
            summary: terminalSummary,
            capturedAt: terminalCapturedAt
        )
        confirmedTerminalSnapshot = terminalSnapshot
        guard publishSnapshotImmediately(
            snapshotOverride: terminalSnapshot,
            envelopeCapturedAt: terminalCapturedAt
        ) else {
            // Keep the durable identity until a transportable terminal
            // envelope exists. HealthKit finalization is already complete,
            // so release only its runtime objects and expose cleanup retry.
            isTerminalPublicationPending = true
            finishRequestError = .reconciliationFailed
            releaseHealthKitObjectsAfterTerminalPublicationFailure()
            return false
        }
        isTerminalPublicationPending = false
        return true
    }

    private func makeTerminalSnapshot(
        summary: WatchWorkoutSummary,
        capturedAt: Date
    ) -> WorkoutSnapshotV1 {
        if session == nil,
           !heartRateZoneDurationAccumulator.hasCompleteTerminalDurations(
             elapsedTime: summary.duration
           ) {
            // A detached checkpoint can lag the final workout or predate an
            // unpersisted zone transition. Do not present partial bins as an
            // exact ended-workout breakdown.
            heartRateZoneDurationAccumulator.reset()
        }
        let base = makeSnapshot(capturedAt: capturedAt)
        var availability = base.availability

        let elapsedTime = summary.duration.flatMap { value in
            guard value.isFinite, value >= 0 else { return nil }
            availability.insert(.elapsedTime)
            return WorkoutMetricV1(
                value: value,
                unit: .seconds,
                capturedAt: capturedAt,
                source: .healthKit
            )
        } ?? base.elapsedTime
        let summaryAverageHeartRate = summary.averageHeartRate.flatMap {
            positiveMetric(
                $0,
                unit: .beatsPerMinute,
                capturedAt: capturedAt
            )
        }
        if summaryAverageHeartRate != nil {
            availability.insert(.averageHeartRate)
        }
        let averageHeartRate = summaryAverageHeartRate
            ?? base.averageHeartRate
        let summaryActiveEnergy = summary.activeEnergyKilocalories.flatMap {
            nonnegativeMetric(
                $0,
                unit: .kilocalories,
                capturedAt: capturedAt
            )
        }
        if summaryActiveEnergy != nil {
            availability.insert(.activeEnergy)
        }
        let activeEnergy = summaryActiveEnergy ?? base.activeEnergy
        let summaryCyclingDistance = summary.distanceMeters.flatMap {
            nonnegativeMetric(
                $0,
                unit: .meters,
                capturedAt: capturedAt
            )
        }
        if summaryCyclingDistance != nil {
            availability.insert(.cyclingDistance)
        }
        let cyclingDistance = reconciledSavedWorkout == nil
            ? base.cyclingDistance ?? summaryCyclingDistance
            : summaryCyclingDistance ?? base.cyclingDistance
        let terminalWallElapsedTime = base.startDate.flatMap { startDate in
            let value = summary.endedAt.timeIntervalSince(startDate)
            guard value.isFinite, value >= 0 else {
                return base.wallElapsedTime
            }
            return WorkoutMetricV1(
                value: value,
                unit: .seconds,
                capturedAt: summary.endedAt
            )
        } ?? base.wallElapsedTime

        return WorkoutSnapshotV1(
            state: base.state,
            startDate: base.startDate,
            elapsedTime: elapsedTime,
            currentHeartRate: base.currentHeartRate,
            averageHeartRate: averageHeartRate,
            activeEnergy: activeEnergy,
            cyclingDistance: cyclingDistance,
            currentSpeed: base.currentSpeed,
            cyclingPower: base.cyclingPower,
            cyclingCadence: base.cyclingCadence,
            currentHeartRateZone: base.currentHeartRateZone,
            heartRateZoneCount: base.heartRateZoneCount,
            heartRateZoneDurations: base.heartRateZoneDurations,
            location: base.location,
            lastCompletedSegment: base.lastCompletedSegment,
            availability: availability,
            errorCode: base.errorCode,
            terminalOutcome: base.terminalOutcome,
            pauseOrigin: base.pauseOrigin,
            lastTransitionOrigin: base.lastTransitionOrigin,
            lastTransitionAt: base.lastTransitionAt,
            wallElapsedTime: terminalWallElapsedTime,
            detectorProfileVersion: base.detectorProfileVersion
        )
    }

    private func finishTerminalRuntimeAfterPublication(_ didPublish: Bool) {
        guard didPublish else { return }
        if session != nil,
           mirrorEnvelopeBuffer.inFlight != nil
                || mirrorEnvelopeBuffer.pending != nil {
            isTerminalMirrorDeliveryPending = true
            shutdownMirrorFailureRetryCount = 0
            if let shutdownSession = session {
                beginBoundedShutdownMirrorDelivery(for: shutdownSession)
            }
            return
        }
        finishDeferredTerminalRuntime()
    }

    private func finishDeferredTerminalRuntime() {
        guard !isTerminalMirrorDeliveryPending
                || mirrorEnvelopeBuffer.inFlight == nil else {
            return
        }
        isTerminalMirrorDeliveryPending = false
        mirrorShutdownWatchdogTask?.cancel()
        mirrorShutdownWatchdogTask = nil
        let terminalSession = session
        if let terminalSession {
            endMirrorShutdownSession(terminalSession)
        }
        if isTerminalArchivePending {
            releaseHealthKitObjectsAfterTerminalPublicationFailure(
                endSession: false
            )
        } else {
            clearActiveObjects()
        }
    }

    private func retryTerminalPublicationAndArchive() {
        guard let terminalSummary = summary,
              let terminalSnapshot = confirmedTerminalSnapshot,
              let durableIdentity = recoveryStore.recoveredIdentity ?? identity,
              let request = durableIdentity.finishRequest else {
            finishRequestError = .reconciliationFailed
            return
        }
        identity = durableIdentity
        finishRequestError = nil
        lastErrorCode = nil
        guard publishSnapshotImmediately(
            snapshotOverride: terminalSnapshot,
            envelopeCapturedAt: max(Date(), terminalSummary.endedAt)
        ) else {
            isTerminalPublicationPending = true
            finishRequestError = .reconciliationFailed
            return
        }

        isTerminalPublicationPending = false
        switch request.disposition {
        case .save:
            archiveConfirmedSave(at: terminalSummary.endedAt)
        case .discard:
            archiveConfirmedDiscard(at: terminalSummary.endedAt)
        }
        finishRequestError = isTerminalArchivePending
            ? .reconciliationFailed
            : nil
        finishTerminalRuntimeAfterPublication(true)
    }

    private func releaseHealthKitObjectsAfterTerminalPublicationFailure(
        endSession: Bool = true
    ) {
        if endSession {
            session?.end()
        }
        resetMirrorTransport()
        session = nil
        builder = nil
        authoritativeFinalizationEndDate = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        recoveredSaveMode = nil
        preparedRouteForFinalization = nil
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        segmentOperationTask?.cancel()
        segmentOperationTask = nil
        segmentOperationTimeoutTask?.cancel()
        segmentOperationTimeoutTask = nil
        segmentOperationAttemptID = nil
        finalSegmentOperationTask?.cancel()
        finalSegmentOperationTask = nil
        finalSegmentOperationAttemptID = nil
        hasAttemptedFinalSegmentClosure = false
        allowsSavingWithUnconfirmedSegment = false
        isMarkingSegment = false
        segmentError = nil
        remoteSegmentControlContext = nil
        segmentAccumulator = WorkoutSegmentAccumulator()
        handleAttachedSessionRelease()
        scheduleTerminalCleanupRetryIfNeeded()
    }

    private func clearActiveObjects() {
        cancelTerminalCleanupRetry(resetAttemptCount: true)
        resetMirrorTransport()
        session = nil
        builder = nil
        identity = nil
        authoritativeFinalizationEndDate = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        recoveredSaveMode = nil
        reconciledSavedWorkout = nil
        preparedRouteForFinalization = nil
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        confirmedTerminalSummarySessionID = nil
        confirmedTerminalSnapshot = nil
        terminalRouteDistance = nil
        isFinishFailureRollbackPending = false
        isDetachedSaveReconciliationInProgress = false
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        segmentOperationTask?.cancel()
        segmentOperationTask = nil
        segmentOperationTimeoutTask?.cancel()
        segmentOperationTimeoutTask = nil
        segmentOperationAttemptID = nil
        finalSegmentOperationTask?.cancel()
        finalSegmentOperationTask = nil
        finalSegmentOperationAttemptID = nil
        hasAttemptedFinalSegmentClosure = false
        allowsSavingWithUnconfirmedSegment = false
        isMarkingSegment = false
        segmentError = nil
        remoteSegmentControlContext = nil
        segmentAccumulator = WorkoutSegmentAccumulator()
        handleAttachedSessionRelease()
    }

    private func beginSegmentMark(
        remoteContext: RemoteSegmentControlContext?,
        recoveredCandidate: WorkoutSegmentCandidate? = nil
    ) {
        let canWriteRecoveredBoundary = recoveredCandidate != nil
            && [.running, .paused, .ending].contains(lifecycle.state)
        guard lifecycle.state == .running || canWriteRecoveredBoundary,
              segmentOperationAttemptID == nil,
              builder != nil || injectedSegmentEventOperation != nil else {
            let errorCode: WorkoutSafeErrorCodeV1
            if segmentOperationAttemptID != nil {
                if remoteContext == nil {
                    segmentError = .confirmationPending
                }
                errorCode = remoteContext == nil
                    ? .segmentMarkUnconfirmed
                    : .segmentMarkFailed
            } else {
                segmentError = .unavailable
                errorCode = .segmentMarkFailed
            }
            if let remoteContext {
                publishAcknowledgement(
                    for: .markSegment,
                    acknowledgedSequence: remoteContext.envelope.sequence,
                    errorCode: errorCode
                )
            }
            return
        }

        let candidate: WorkoutSegmentCandidate?
        if let recoveredCandidate {
            candidate = recoveredCandidate
        } else {
            candidate = makeCurrentSegmentCandidate()
        }
        guard let candidate else {
            segmentError = .unavailable
            if let remoteContext {
                publishAcknowledgement(
                    for: .markSegment,
                    acknowledgedSequence: remoteContext.envelope.sequence,
                    errorCode: .segmentMarkFailed
                )
            }
            return
        }
        var validationAccumulator = segmentAccumulator
        guard validationAccumulator.commit(candidate) else {
            segmentError = .healthKitWriteFailed
            if let remoteContext {
                let didClear = clearPersistedRemoteSegmentIntent(
                    matching: remoteContext.envelope
                )
                publishAcknowledgement(
                    for: .markSegment,
                    acknowledgedSequence: remoteContext.envelope.sequence,
                    errorCode: didClear
                        ? .segmentMarkFailed
                        : .segmentMarkUnconfirmed
                )
            }
            return
        }

        let event = makeSegmentEvent(
            candidate,
            remoteEnvelope: remoteContext?.envelope
        )
        isMarkingSegment = true
        segmentError = nil
        remoteSegmentControlContext = remoteContext
        let attemptID = UUID()
        segmentOperationAttemptID = attemptID
        let targetBuilder = builder
        let injectedOperation = injectedSegmentEventOperation
        segmentOperationTask = Task { @MainActor [weak self] in
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: targetBuilder,
                injectedOperation: injectedOperation
            )
            self?.completeSegmentMark(
                attemptID: attemptID,
                candidate: candidate,
                outcome: outcome
            )
        }
        let timeout = segmentWriteTimeout
        segmentOperationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
            } catch {
                return
            }
            self?.timeOutSegmentMark(attemptID: attemptID)
        }
    }

    private func makeCurrentSegmentCandidate() -> WorkoutSegmentCandidate? {
        let endedAt = segmentNow()
        let currentSnapshot = makeSnapshot(capturedAt: endedAt)
        guard let cumulativeElapsedTime =
                currentSnapshot.elapsedTime?.value else {
            return nil
        }
        return segmentAccumulator.candidate(
            endedAt: endedAt,
            cumulativeElapsedTime: cumulativeElapsedTime,
            cumulativeDistanceMeters:
                currentSnapshot.cyclingDistance?.value,
            cumulativeDistanceSource:
                currentSnapshot.cyclingDistance?.source
        )
    }

    private func timeOutSegmentMark(attemptID: UUID) {
        guard attemptID == segmentOperationAttemptID else { return }
        isMarkingSegment = false
        segmentError = .confirmationPending
        if let remoteContext = remoteSegmentControlContext {
            publishAcknowledgement(
                for: .markSegment,
                acknowledgedSequence: remoteContext.envelope.sequence,
                errorCode: .segmentMarkUnconfirmed
            )
        }
    }

    private func completeSegmentMark(
        attemptID: UUID,
        candidate: WorkoutSegmentCandidate,
        outcome: SegmentEventWriteOutcome
    ) {
        guard attemptID == segmentOperationAttemptID else { return }
        let remoteContext = remoteSegmentControlContext
        let didCommit = outcome == .success
            && segmentAccumulator.commit(candidate)
        if didCommit {
            segmentError = nil
            publishSnapshotImmediately()
        } else {
            segmentError = .healthKitWriteFailed
        }
        if let remoteContext {
            let didClear = clearPersistedRemoteSegmentIntent(
                matching: remoteContext.envelope
            )
            publishAcknowledgement(
                for: .markSegment,
                acknowledgedSequence: remoteContext.envelope.sequence,
                errorCode: didCommit
                    ? nil
                    : didClear
                        ? .segmentMarkFailed
                        : .segmentMarkUnconfirmed
            )
        }
        remoteSegmentControlContext = nil
        isMarkingSegment = false
        segmentOperationAttemptID = nil
        segmentOperationTimeoutTask?.cancel()
        segmentOperationTimeoutTask = nil
        segmentOperationTask = nil
    }

    private func waitForSegmentOperationBeforeFinalization() async -> Bool {
        guard let attemptID = segmentOperationAttemptID,
              segmentOperationTask != nil else {
            return true
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .nanoseconds(
                Int64(segmentWriteTimeout * 1_000_000_000)
            )
        )
        while segmentOperationAttemptID == attemptID,
              clock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        return segmentOperationAttemptID != attemptID
    }

    private func commitRemoteSegmentControl(
        _ envelope: WorkoutEnvelopeV1,
        candidate: WorkoutSegmentCandidate
    ) -> Bool {
        var candidateGate = remoteControlGate
        guard (try? candidateGate.ingest(envelope)) == true else {
            return false
        }
        let intent = WatchWorkoutRecoveryStore.RemoteSegmentIntent(
            controlSenderID: envelope.controlSenderID,
            acknowledgedSequence: envelope.sequence,
            capturedAt: envelope.capturedAt,
            completedSegment: candidate.completedSegment,
            cumulativeElapsedTime: candidate.cumulativeElapsedTime,
            cumulativeDistanceMeters: candidate.cumulativeDistanceMeters,
            cumulativeDistanceSource: candidate.cumulativeDistanceSource
        )
        do {
            try recoveryStore.persistRemoteSegmentControl(
                checkpoint: candidateGate.checkpoint,
                intent: intent
            )
            if let persistedIdentity = recoveryStore.recoveredIdentity {
                identity = persistedIdentity
            }
        } catch {
            // Do not start HealthKit work until the replay checkpoint and
            // original boundary are durable as one transaction.
            return false
        }
        remoteControlGate = candidateGate
        return true
    }

    private func commitRemoteSegmentRejection(
        _ envelope: WorkoutEnvelopeV1
    ) -> Bool {
        var candidateGate = remoteControlGate
        guard (try? candidateGate.ingest(envelope)) == true else {
            return false
        }
        do {
            _ = try recoveryStore.persistRemoteControlCheckpoint(
                candidateGate.checkpoint
            )
            if let persistedIdentity = recoveryStore.recoveredIdentity {
                identity = persistedIdentity
            }
        } catch {
            return false
        }
        remoteControlGate = candidateGate
        return true
    }

    @discardableResult
    private func clearPersistedRemoteSegmentIntent(
        matching envelope: WorkoutEnvelopeV1
    ) -> Bool {
        do {
            try recoveryStore.clearRemoteSegmentIntent(matching: envelope)
            if let persistedIdentity = recoveryStore.recoveredIdentity {
                identity = persistedIdentity
            }
            return true
        } catch {
            // Event metadata remains the authoritative completion evidence.
            // A later exact replay will reconcile it and retry this cleanup.
            return false
        }
    }

    private static func segmentCandidate(
        from intent: WatchWorkoutRecoveryStore.RemoteSegmentIntent
    ) -> WorkoutSegmentCandidate {
        WorkoutSegmentCandidate(
            completedSegment: intent.completedSegment,
            cumulativeElapsedTime: intent.cumulativeElapsedTime,
            cumulativeDistanceMeters: intent.cumulativeDistanceMeters,
            cumulativeDistanceSource: intent.cumulativeDistanceSource
        )
    }

    private func resumePersistedRemoteSegmentIntentIfNeeded() {
        guard segmentOperationAttemptID == nil,
              let identity,
              let intent = recoveryStore.recoveredIdentity?
                .remoteSegmentIntent else {
            return
        }
        let envelope = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: intent.acknowledgedSequence,
            capturedAt: intent.capturedAt,
            controlSenderID: intent.controlSenderID,
            control: .markSegment
        )
        if containsSegmentEvent(matching: envelope) {
            clearPersistedRemoteSegmentIntent(matching: envelope)
            return
        }
        beginSegmentMark(
            remoteContext: RemoteSegmentControlContext(envelope: envelope),
            recoveredCandidate: Self.segmentCandidate(from: intent)
        )
    }

    private func makeSegmentEvent(
        _ candidate: WorkoutSegmentCandidate,
        remoteEnvelope: WorkoutEnvelopeV1?
    ) -> HKWorkoutEvent {
        var metadata: [String: Any] = [
            SegmentMetadataKey.origin: SegmentMetadataKey.originValue,
            SegmentMetadataKey.index:
                NSNumber(value: candidate.completedSegment.index),
            SegmentMetadataKey.activeDuration:
                NSNumber(value: candidate.completedSegment.duration),
            SegmentMetadataKey.cumulativeElapsed:
                NSNumber(value: candidate.cumulativeElapsedTime),
            SegmentMetadataKey.eventID: UUID().uuidString,
        ]
        if let distance = candidate.completedSegment.distanceMeters {
            metadata[SegmentMetadataKey.distanceMeters] = NSNumber(
                value: distance
            )
        }
        if let cumulativeDistance = candidate.cumulativeDistanceMeters {
            metadata[SegmentMetadataKey.cumulativeDistance] = NSNumber(
                value: cumulativeDistance
            )
        }
        if let cumulativeDistanceSource =
                candidate.cumulativeDistanceSource {
            metadata[SegmentMetadataKey.cumulativeDistanceSource] =
                cumulativeDistanceSource.rawValue
        }
        if let senderID = remoteEnvelope?.controlSenderID {
            metadata[SegmentMetadataKey.controlSenderID] = senderID.uuidString
        }
        if let sequence = remoteEnvelope?.sequence {
            metadata[SegmentMetadataKey.controlSequence] = NSNumber(
                value: sequence
            )
        }
        return HKWorkoutEvent(
            type: .segment,
            dateInterval: DateInterval(
                start: candidate.completedSegment.startedAt,
                end: candidate.completedSegment.endedAt
            ),
            metadata: metadata
        )
    }

    private static func segmentEventWriteOutcome(
        _ event: HKWorkoutEvent,
        to builder: HKLiveWorkoutBuilder?,
        injectedOperation: WatchSegmentEventOperation?
    ) async -> SegmentEventWriteOutcome {
        do {
            try await performSegmentEventWrite(
                event,
                to: builder,
                injectedOperation: injectedOperation
            )
            return .success
        } catch {
            return .failure
        }
    }

    private static func performSegmentEventWrite(
        _ event: HKWorkoutEvent,
        to builder: HKLiveWorkoutBuilder?,
        injectedOperation: WatchSegmentEventOperation?
    ) async throws {
        if let injectedOperation {
            try await injectedOperation(event)
            return
        }
        guard let builder else {
            throw WorkoutSegmentWriteError.builderUnavailable
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            builder.addWorkoutEvents([event]) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: WorkoutSegmentWriteError.writeFailed
                    )
                }
            }
        }
    }

    private func closeFinalSegmentIfNeeded(
        in builder: HKLiveWorkoutBuilder?,
        at endDate: Date
    ) async -> Bool {
        if allowsSavingWithUnconfirmedSegment {
            return true
        }
        guard segmentAccumulator.hasCompletedSegments,
              segmentOperationAttemptID == nil else {
            return segmentOperationAttemptID == nil
        }
        if let attemptID = finalSegmentOperationAttemptID {
            return await waitForFinalSegmentOperation(attemptID)
        }
        guard !hasAttemptedFinalSegmentClosure else {
            return true
        }
        let currentSnapshot = makeSnapshot(capturedAt: endDate)
        guard let cumulativeElapsedTime =
                currentSnapshot.elapsedTime?.value,
              let candidate = segmentAccumulator.candidate(
                  endedAt: endDate,
                  cumulativeElapsedTime: cumulativeElapsedTime,
                  cumulativeDistanceMeters:
                    currentSnapshot.cyclingDistance?.value,
                  cumulativeDistanceSource:
                    currentSnapshot.cyclingDistance?.source
              ),
              candidate.completedSegment.duration > 0 else {
            return true
        }
        hasAttemptedFinalSegmentClosure = true
        let attemptID = UUID()
        finalSegmentOperationAttemptID = attemptID
        let event = makeSegmentEvent(candidate, remoteEnvelope: nil)
        let injectedOperation = injectedSegmentEventOperation
        finalSegmentOperationTask = Task { @MainActor [weak self] in
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation: injectedOperation
            )
            self?.completeFinalSegmentWrite(
                attemptID: attemptID,
                candidate: candidate,
                outcome: outcome
            )
        }
        return await waitForFinalSegmentOperation(attemptID)
    }

    private func waitForFinalSegmentOperation(_ attemptID: UUID) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .nanoseconds(
                Int64(segmentWriteTimeout * 1_000_000_000)
            )
        )
        while finalSegmentOperationAttemptID == attemptID,
              clock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        if finalSegmentOperationAttemptID == attemptID {
            segmentError = .confirmationPending
            return false
        }
        return hasAttemptedFinalSegmentClosure
    }

    private func completeFinalSegmentWrite(
        attemptID: UUID,
        candidate: WorkoutSegmentCandidate,
        outcome: SegmentEventWriteOutcome
    ) {
        guard attemptID == finalSegmentOperationAttemptID else { return }
        if outcome == .success, segmentAccumulator.commit(candidate) {
            segmentError = nil
            publishSnapshotImmediately()
        } else {
            hasAttemptedFinalSegmentClosure = false
            segmentError = .healthKitWriteFailed
        }
        finalSegmentOperationAttemptID = nil
        finalSegmentOperationTask = nil
    }

    private func restoreSegmentAccumulator(
        from builder: HKLiveWorkoutBuilder,
        workoutStart: Date
    ) {
        let restored = builder.workoutEvents.compactMap {
            completedSegment(from: $0, workoutStart: workoutStart)
        }.max { lhs, rhs in
            lhs.segment.index < rhs.segment.index
        }
        segmentAccumulator.restore(
            workoutStart: workoutStart,
            lastCompletedSegment: restored?.segment,
            cumulativeElapsedTime: restored?.cumulativeElapsedTime,
            cumulativeDistanceMeters: restored?.cumulativeDistanceMeters,
            cumulativeDistanceSource: restored?.cumulativeDistanceSource
        )
    }

    private func seedManualTransitionRequestWatermark(
        from builder: HKLiveWorkoutBuilder,
        workoutStart: Date
    ) {
        lastProcessedManualTransitionRequestAt = builder.workoutEvents
            .filter {
                $0.type == .pauseOrResumeRequest
                    && $0.dateInterval.start >= workoutStart
            }
            .map(\.dateInterval.start)
            .max() ?? .distantPast
    }

    private func restoreRideTransition(
        from builder: HKLiveWorkoutBuilder,
        sessionState: HKWorkoutSessionState,
        workoutStart: Date
    ) async {
        guard sessionState == .running || sessionState == .paused else {
            return
        }
        let paused = sessionState == .paused
        let expectedTransitions: Set<String> = paused
            ? ["pause"]
            : ["start", "resume"]
        let latestMarker = builder.workoutEvents.compactMap { event -> (
            origin: WorkoutTransitionOrigin,
            at: Date,
            profileVersion: UInt16?
        )? in
            guard event.type == .marker,
                  event.dateInterval.start >= workoutStart,
                  let metadata = event.metadata,
                  metadata[RideTransitionMetadataKey.marker] as? Bool == true,
                  let schemaNumber = metadata[
                    RideTransitionMetadataKey.schema
                  ] as? NSNumber,
                  Self.exactUnsignedMetadata(
                    schemaNumber,
                    as: UInt8.self
                  ) == 1,
                  let transition = metadata[
                    RideTransitionMetadataKey.transition
                  ] as? String,
                  expectedTransitions.contains(transition),
                  let originValue = metadata[
                    RideTransitionMetadataKey.origin
                  ] as? String else {
                return nil
            }
            let origin: WorkoutTransitionOrigin
            switch originValue {
            case "automatic": origin = .automatic
            case "manual": origin = .manual
            default: return nil
            }
            let profile = (
                metadata[RideTransitionMetadataKey.profileVersion]
                    as? NSNumber
            ).flatMap {
                Self.exactUnsignedMetadata($0, as: UInt16.self)
            }
            if origin == .automatic, profile == nil || profile == 0 {
                return nil
            }
            return (origin, event.dateInterval.start, profile)
        }.max { $0.at < $1.at }
        let pendingRequestedAt = identity?.pendingTransitionContext == nil
            ? nil
            : identity?.pendingTransitionRequestedAt
        let marker = latestMarker.flatMap { candidate in
            RideAutomationRecoveryControlPolicy
                .markerConfirmsPendingTransition(
                    markerAt: candidate.at,
                    pendingRequestedAt: pendingRequestedAt
                )
                ? candidate
                : nil
        }
        if marker == nil,
           let context = identity?.pendingTransitionContext,
           identity?.pendingTransitionPaused == paused {
            let date = identity?.pendingTransitionRequestedAt
                ?? workoutStart
            let event = makeRideTransitionMarker(
                paused: paused,
                origin: .automatic,
                context: context,
                at: date
            )
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation: injectedRideTransitionEventOperation
            )
            guard outcome == .success else {
                lastErrorCode = .sessionFailed
                return
            }
            do {
                try recoveryStore.confirmRideTransition(
                    origin: .automatic,
                    paused: paused,
                    at: date,
                    detectorProfileVersion: context.detectorProfileVersion
                )
                identity = recoveryStore.recoveredIdentity ?? identity
            } catch {
                lastErrorCode = .sessionFailed
            }
            return
        }
        guard let marker,
              identity?.lastTransitionAt.map({ marker.at >= $0 }) ?? true else {
            return
        }
        do {
            try recoveryStore.confirmRideTransition(
                origin: marker.origin,
                paused: paused,
                at: marker.at,
                detectorProfileVersion: marker.profileVersion
            )
            identity = recoveryStore.recoveredIdentity ?? identity
        } catch {
            lastErrorCode = .sessionFailed
        }
    }

    private func completedSegment(
        from event: HKWorkoutEvent,
        workoutStart: Date
    ) -> (
        segment: WorkoutCompletedSegmentV1,
        cumulativeElapsedTime: TimeInterval,
        cumulativeDistanceMeters: Double?,
        cumulativeDistanceSource: WorkoutMetricSourceV1?
    )? {
        guard event.type == .segment,
              let metadata = event.metadata,
              metadata[SegmentMetadataKey.origin] as? String
                == SegmentMetadataKey.originValue,
              let index = (
                  metadata[SegmentMetadataKey.index] as? NSNumber
              )?.uint32Value,
              index > 0,
              index < UInt32.max,
              let duration = (
                  metadata[SegmentMetadataKey.activeDuration] as? NSNumber
              )?.doubleValue,
              duration.isFinite,
              duration >= 0,
              event.dateInterval.start >= workoutStart,
              duration <= event.dateInterval.duration + 1,
              let cumulativeElapsed = (
                  metadata[SegmentMetadataKey.cumulativeElapsed] as? NSNumber
              )?.doubleValue,
              cumulativeElapsed.isFinite,
              cumulativeElapsed >= duration else {
            return nil
        }
        let distance = (
            metadata[SegmentMetadataKey.distanceMeters] as? NSNumber
        )?.doubleValue
        let cumulativeDistance = (
            metadata[SegmentMetadataKey.cumulativeDistance] as? NSNumber
        )?.doubleValue
        let cumulativeDistanceSource = (
            metadata[SegmentMetadataKey.cumulativeDistanceSource] as? String
        ).flatMap(WorkoutMetricSourceV1.init(rawValue:))
        let distanceIsWithinCumulative: Bool
        if let distance, let cumulativeDistance {
            distanceIsWithinCumulative = distance <= cumulativeDistance
        } else {
            distanceIsWithinCumulative = true
        }
        guard distance.map({ $0.isFinite && $0 >= 0 }) ?? true,
              cumulativeDistance.map({
                  $0.isFinite && $0 >= 0
              }) ?? true,
              distanceIsWithinCumulative else {
            return nil
        }
        return (
            WorkoutCompletedSegmentV1(
                index: index,
                startedAt: event.dateInterval.start,
                endedAt: event.dateInterval.end,
                duration: duration,
                distanceMeters: distance
            ),
            cumulativeElapsed,
            cumulativeDistance,
            cumulativeDistanceSource
        )
    }

    private func containsSegmentEvent(
        matching envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let senderID = envelope.controlSenderID else { return false }
        return builder?.workoutEvents.contains { event in
            guard event.type == .segment,
                  let metadata = event.metadata,
                  metadata[SegmentMetadataKey.controlSenderID] as? String
                    == senderID.uuidString,
                  let sequence = (
                      metadata[SegmentMetadataKey.controlSequence] as? NSNumber
                  )?.uint64Value else {
                return false
            }
            return sequence == envelope.sequence
        } ?? false
    }

    private func isPendingSegmentControl(
        _ envelope: WorkoutEnvelopeV1
    ) -> Bool {
        guard let pending = remoteSegmentControlContext?.envelope else {
            return false
        }
        return pending.sessionID == envelope.sessionID
            && pending.sessionToken == envelope.sessionToken
            && pending.controlSenderID == envelope.controlSenderID
            && pending.sequence == envelope.sequence
    }

    private func updateMetrics(
        from builder: HKLiveWorkoutBuilder,
        collectedTypes: Set<HKSampleType>,
        capturedAt: Date
    ) {
        for sampleType in collectedTypes {
            guard let quantityType = sampleType as? HKQuantityType,
                  let statistics = builder.statistics(for: quantityType) else {
                continue
            }
            updateMetric(
                identifier: quantityType.identifier,
                statistics: statistics,
                capturedAt: capturedAt
            )
        }
        scheduleCoalescedSnapshot()
    }

    private func updateAllMetrics(
        from builder: HKLiveWorkoutBuilder,
        capturedAt: Date
    ) {
        for (quantityType, statistics) in builder.allStatistics {
            updateMetric(
                identifier: quantityType.identifier,
                statistics: statistics,
                capturedAt: capturedAt
            )
        }
    }

    private func updateMetric(
        identifier: String,
        statistics: HKStatistics,
        capturedAt: Date
    ) {
        switch identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            let unit = HKUnit.count().unitDivided(by: .minute())
            if let quantity = statistics.mostRecentQuantity() {
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                currentHeartRate = positiveMetric(
                    quantity.doubleValue(for: unit),
                    unit: .beatsPerMinute,
                    capturedAt: min(date, capturedAt)
                )
            }
            if let quantity = statistics.averageQuantity() {
                averageHeartRate = positiveMetric(
                    quantity.doubleValue(for: unit),
                    unit: .beatsPerMinute,
                    capturedAt: capturedAt
                )
            }
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            if let quantity = statistics.sumQuantity() {
                activeEnergy = nonnegativeMetric(
                    quantity.doubleValue(for: .kilocalorie()),
                    unit: .kilocalories,
                    capturedAt: capturedAt
                )
            }
        case HKQuantityTypeIdentifier.distanceCycling.rawValue:
            if let quantity = statistics.sumQuantity() {
                let value = quantity.doubleValue(for: .meter())
                healthKitDistance = WorkoutMetricCandidate(
                    value: value,
                    capturedAt: capturedAt,
                    source: .healthKit
                )
            }
        case HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let unit = HKUnit.meter().unitDivided(by: .second())
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                pairedSensorSpeed = WorkoutMetricCandidate(
                    value: quantity.doubleValue(for: unit),
                    capturedAt: min(date, capturedAt),
                    source: .pairedCyclingSensor
                )
            }
        case HKQuantityTypeIdentifier.cyclingPower.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                cyclingPower = nonnegativeMetric(
                    quantity.doubleValue(for: .watt()),
                    unit: .watts,
                    capturedAt: min(date, capturedAt)
                )
            }
        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let unit = HKUnit.count().unitDivided(by: .minute())
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                cyclingCadence = nonnegativeMetric(
                    quantity.doubleValue(for: unit),
                    unit: .revolutionsPerMinute,
                    capturedAt: min(date, capturedAt)
                )
            }
        default:
            break
        }
    }

    private func startMirroringIfNeeded(for workoutSession: HKWorkoutSession) {
        guard session === workoutSession,
              lifecycle.state.isActive,
              !isMirroring,
              !isMirrorStartInFlight else {
            return
        }
        mirrorRetryTask?.cancel()
        mirrorRetryTask = nil
        isMirrorStartInFlight = true
        let attemptID = UUID()
        mirrorStartAttemptID = attemptID
        let callbackReference = WorkoutWeakReference(self)
        let completion: @Sendable (Bool, Error?) -> Void = { success, _ in
            Task { @MainActor in
                guard let manager = callbackReference.value,
                      manager.session === workoutSession,
                      manager.mirrorStartAttemptID == attemptID else { return }
                manager.mirrorStartAttemptID = nil
                manager.isMirrorStartInFlight = false
                manager.isMirroring = success
                if success {
                    if let latestEnvelope = manager.latestEnvelope {
                        manager.mirrorEnvelopeBuffer.offer(latestEnvelope)
                    }
                    manager.drainMirrorEnvelopeBuffer()
                } else {
                    manager.scheduleMirrorRetry(for: workoutSession)
                }
            }
        }
        if let injectedMirrorStartOperation {
            injectedMirrorStartOperation(workoutSession, completion)
        } else {
            workoutSession.startMirroringToCompanionDevice(
                completion: completion
            )
        }
    }

    private func scheduleMirrorRetry(for workoutSession: HKWorkoutSession) {
        guard mirrorRetryTask == nil,
              session === workoutSession,
              lifecycle.state.isActive else {
            return
        }
        let retryDelay = mirrorRetryDelay.isFinite
            ? min(max(0, mirrorRetryDelay), 60)
            : 5
        mirrorRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        max(0, retryDelay) * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self, self.session === workoutSession else { return }
            self.mirrorRetryTask = nil
            self.startMirroringIfNeeded(for: workoutSession)
        }
    }

    private func scheduleMirrorShutdownWatchdog(
        for workoutSession: HKWorkoutSession?
    ) {
        guard let workoutSession else { return }
        mirrorShutdownWatchdogTask?.cancel()
        let delay = mirrorShutdownDeliveryTimeout.isFinite
            ? min(max(0, mirrorShutdownDeliveryTimeout), 60)
            : 10
        mirrorShutdownWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  session === workoutSession,
                  isTerminalMirrorDeliveryPending
                    || isStartFailureMirrorDeliveryPending else {
                return
            }
            // HealthKit accepted an attempt but provided neither completion
            // nor disconnect. Invalidate any eventual callback and release
            // the primary session after the bounded delivery attempt.
            mirrorShutdownWatchdogTask = nil
            mirrorSendAttemptID = nil
            mirrorEnvelopeBuffer.interruptInFlight()
            if isStartFailureMirrorDeliveryPending {
                finishStartFailureRuntime()
            } else {
                finishDeferredTerminalRuntime()
            }
        }
    }

    private func beginBoundedShutdownMirrorDelivery(
        for workoutSession: HKWorkoutSession
    ) {
        guard session === workoutSession,
              let shutdownEnvelope = latestEnvelope,
              shutdownEnvelope.snapshot.map({
                  $0.state == .ended || $0.state == .failed
              }) == true else {
            return
        }
        if mirrorEnvelopeBuffer.prioritizeShutdownEnvelope(shutdownEnvelope) {
            // The older HealthKit send cannot be cancelled, but it must not
            // own the buffer or mutate state after the final attempt begins.
            mirrorSendAttemptID = nil
        }
        if mirrorEnvelopeBuffer.inFlight == nil {
            drainMirrorEnvelopeBuffer(forceAttempt: true)
        }
        guard session === workoutSession,
              isTerminalMirrorDeliveryPending
                || isStartFailureMirrorDeliveryPending else {
            return
        }
        // Start the bound only after the ended/failed envelope has been
        // submitted, so an older hung live send cannot consume this window.
        scheduleMirrorShutdownWatchdog(for: workoutSession)
    }

    private func offerEnvelopeToMirror(_ envelope: WorkoutEnvelopeV1) {
        mirrorEnvelopeBuffer.offer(envelope)
        drainMirrorEnvelopeBuffer()
    }

    private func drainMirrorEnvelopeBuffer(forceAttempt: Bool = false) {
        guard isMirroring || forceAttempt,
              let workoutSession = session,
              let envelope = mirrorEnvelopeBuffer.beginNext() else {
            return
        }
        let data: Data
        do {
            data = try WorkoutContractCodec.encode(envelope)
        } catch {
            mirrorEnvelopeBuffer.complete(succeeded: true)
            if mirrorEnvelopeBuffer.pending != nil {
                drainMirrorEnvelopeBuffer(
                    forceAttempt: isTerminalMirrorDeliveryPending
                        || isStartFailureMirrorDeliveryPending
                )
            } else if isStartFailureMirrorDeliveryPending {
                finishStartFailureRuntime()
            } else if isTerminalMirrorDeliveryPending {
                finishDeferredTerminalRuntime()
            }
            return
        }
        let callbackReference = WorkoutWeakReference(self)
        let attemptID = UUID()
        mirrorSendAttemptID = attemptID
        let completion: @Sendable (Bool, Error?) -> Void = { success, _ in
            Task { @MainActor in
                guard let manager = callbackReference.value,
                      manager.mirrorSendAttemptID == attemptID else { return }
                manager.mirrorSendAttemptID = nil
                let isShutdownEnvelope = envelope.snapshot.map {
                    [.ended, .failed].contains($0.state)
                } ?? false
                let shouldRetryShutdownEnvelope = !success
                    && isShutdownEnvelope
                    && (manager.isTerminalMirrorDeliveryPending
                        || manager.isStartFailureMirrorDeliveryPending)
                    && manager.shutdownMirrorFailureRetryCount < 1
                if shouldRetryShutdownEnvelope {
                    manager.shutdownMirrorFailureRetryCount += 1
                }
                manager.mirrorEnvelopeBuffer.complete(
                    succeeded: success
                        || (isShutdownEnvelope
                            && !shouldRetryShutdownEnvelope)
                )
                guard manager.session === workoutSession else { return }
                if manager.isStartFailureMirrorDeliveryPending {
                    if manager.mirrorEnvelopeBuffer.pending != nil {
                        manager.drainMirrorEnvelopeBuffer(forceAttempt: true)
                    } else {
                        manager.finishStartFailureRuntime()
                    }
                    return
                }
                if manager.isTerminalMirrorDeliveryPending {
                    if manager.mirrorEnvelopeBuffer.pending != nil {
                        manager.drainMirrorEnvelopeBuffer(forceAttempt: true)
                    } else {
                        manager.finishDeferredTerminalRuntime()
                    }
                    return
                }
                if success {
                    manager.drainMirrorEnvelopeBuffer()
                } else {
                    manager.isMirroring = false
                    manager.scheduleMirrorRetry(for: workoutSession)
                }
            }
        }
        if let injectedMirrorSendOperation {
            injectedMirrorSendOperation(workoutSession, data, completion)
        } else {
            workoutSession.sendToRemoteWorkoutSession(
                data: data,
                completion: completion
            )
        }
    }

    private func endMirrorShutdownSession(_ workoutSession: HKWorkoutSession) {
        if let injectedMirrorShutdownEndSession {
            injectedMirrorShutdownEndSession(workoutSession)
        } else {
            workoutSession.end()
        }
    }

    func handleMirrorDisconnect(from workoutSession: HKWorkoutSession) {
        guard session === workoutSession else { return }
        isMirroring = false
        isMirrorStartInFlight = false
        mirrorStartAttemptID = nil
        mirrorSendAttemptID = nil
        mirrorEnvelopeBuffer.interruptInFlight()
        // A shutdown envelope was already handed to HealthKit before this
        // disconnect. There is no active lifecycle in which to restart
        // mirroring, so abandon only the transport retry and release the
        // primary session instead of wedging workout admission forever.
        if isStartFailureMirrorDeliveryPending {
            finishStartFailureRuntime()
            return
        }
        if isTerminalMirrorDeliveryPending {
            finishDeferredTerminalRuntime()
            return
        }
        scheduleMirrorRetry(for: workoutSession)
    }

#if DEBUG
    private func configureAppStoreScreenshotPreview() {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

        lifecycle = WorkoutLifecycleReducer()
        _ = lifecycle.apply(.requestStart)
        _ = lifecycle.apply(.sessionRunning)
        setupState = .ready
        isRecovering = false
        snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: capturedAt.addingTimeInterval(-2_863),
            elapsedTime: WorkoutMetricV1(
                value: 2_863,
                unit: .seconds,
                capturedAt: capturedAt,
                source: .healthKit
            ),
            currentHeartRate: WorkoutMetricV1(
                value: 148,
                unit: .beatsPerMinute,
                capturedAt: capturedAt,
                source: .healthKit
            ),
            averageHeartRate: WorkoutMetricV1(
                value: 143,
                unit: .beatsPerMinute,
                capturedAt: capturedAt,
                source: .healthKit
            ),
            activeEnergy: WorkoutMetricV1(
                value: 487,
                unit: .kilocalories,
                capturedAt: capturedAt,
                source: .healthKit
            ),
            cyclingDistance: WorkoutMetricV1(
                value: 8_420,
                unit: .meters,
                capturedAt: capturedAt,
                source: .healthKit
            ),
            currentSpeed: WorkoutMetricV1(
                value: 8.3,
                unit: .metersPerSecond,
                capturedAt: capturedAt,
                source: .pairedCyclingSensor
            ),
            cyclingPower: WorkoutMetricV1(
                value: 238,
                unit: .watts,
                capturedAt: capturedAt,
                source: .pairedCyclingSensor
            ),
            cyclingCadence: WorkoutMetricV1(
                value: 91,
                unit: .revolutionsPerMinute,
                capturedAt: capturedAt,
                source: .pairedCyclingSensor
            ),
            currentHeartRateZone: 3,
            heartRateZoneCount: 5,
            location: WorkoutLocationV1(
                latitude: 35.6762,
                longitude: 139.6503,
                capturedAt: capturedAt,
                horizontalAccuracy: 4.2,
                altitude: 42,
                verticalAccuracy: 2.4,
                course: 82,
                speed: 8.3
            ),
            availability: [
                .elapsedTime,
                .currentHeartRate,
                .averageHeartRate,
                .activeEnergy,
                .cyclingDistance,
                .currentSpeed,
                .cyclingPower,
                .cyclingCadence,
                .heartRateZone,
            ]
        )
    }

    func configureMirrorRuntimeForTesting(
        session: HKWorkoutSession,
        identity: WatchWorkoutRecoveryStore.Identity,
        state: WorkoutSessionStateV1
    ) {
        resetMirrorTransport()
        self.session = session
        adoptRecoveredIdentityForRuntime(identity)
        lifecycle = WorkoutLifecycleReducer()
        _ = lifecycle.apply(.requestStart)
        if state == .running || state == .paused || state == .ending {
            _ = lifecycle.apply(.sessionRunning)
        }
        if state == .paused {
            _ = lifecycle.apply(.sessionPaused)
        }
        if state == .ending {
            _ = lifecycle.apply(
                .requestEnd(identity.finishRequest?.disposition ?? .save)
            )
        }
        snapshot = WorkoutSnapshotV1(
            state: state,
            startDate: identity.startDate
        )
        segmentAccumulator.reset(workoutStart: identity.startDate)
        resumePersistedRemoteSegmentIntentIfNeeded()
    }

    func startMirroringForTesting() {
        guard let session else { return }
        startMirroringIfNeeded(for: session)
    }

    @discardableResult
    func publishMirrorSnapshotForTesting() -> Bool {
        publishSnapshotImmediately()
    }

    func setCurrentHeartRateForTesting(
        _ beatsPerMinute: Double,
        capturedAt: Date
    ) {
        currentHeartRate = positiveMetric(
            beatsPerMinute,
            unit: .beatsPerMinute,
            capturedAt: capturedAt
        )
    }

    func setCumulativeMetricsForTesting(
        averageHeartRateBPM: Double,
        activeEnergyKilocalories: Double,
        distanceMeters: Double,
        capturedAt: Date
    ) {
        averageHeartRate = positiveMetric(
            averageHeartRateBPM,
            unit: .beatsPerMinute,
            capturedAt: capturedAt
        )
        activeEnergy = nonnegativeMetric(
            activeEnergyKilocalories,
            unit: .kilocalories,
            capturedAt: capturedAt
        )
        healthKitDistance = WorkoutMetricCandidate(
            value: distanceMeters,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }

    func closeFinalSegmentForTesting(at endDate: Date) async -> Bool {
        await closeFinalSegmentIfNeeded(in: builder, at: endDate)
    }

    func waitForSegmentOperationBeforeFinalizationForTesting() async -> Bool {
        await waitForSegmentOperationBeforeFinalization()
    }

    func finalizeForTesting(
        disposition: WorkoutFinishDisposition,
        endDate: Date
    ) async {
        await finalize(disposition: disposition, endDate: endDate)
    }

    var allowsSavingWithUnconfirmedSegmentForTesting: Bool {
        allowsSavingWithUnconfirmedSegment
    }

    func markMirrorShutdownDeliveryPendingForTesting(startFailure: Bool) {
        let didPublish: Bool
        if startFailure {
            _ = lifecycle.apply(.fail)
            lastErrorCode = .sessionFailed
            isStartFailureMirrorDeliveryPending = true
            didPublish = publishFailureSnapshot()
        } else {
            _ = lifecycle.apply(.requestEnd(.save))
            _ = lifecycle.apply(.sessionEnded)
            isTerminalMirrorDeliveryPending = true
            didPublish = publishSnapshotImmediately()
        }
        if didPublish, let session {
            beginBoundedShutdownMirrorDelivery(for: session)
        }
    }

    var hasAttachedSessionForTesting: Bool { session != nil }
    var mirrorSendIsInFlightForTesting: Bool {
        mirrorEnvelopeBuffer.inFlight != nil
    }
#endif

    private func adoptRecoveredIdentityForRuntime(
        _ recoveredIdentity: WatchWorkoutRecoveryStore.Identity
    ) {
        identity = recoveredIdentity
        if heartRateZoneRuntimeSessionID != recoveredIdentity.sessionID {
            heartRateZoneRuntimeSessionID = recoveredIdentity.sessionID
            heartRateZoneRuntimeMaximumHeartRateBPM =
                recoveredIdentity.heartRateZoneMaximumHeartRateBPM
                    ?? maximumHeartRateBPM
        }
        heartRateZoneDurationAccumulator.restore(
            sessionID: recoveredIdentity.sessionID,
            checkpoint: recoveredIdentity.heartRateZoneCheckpoint
        )
        heartRateZoneCheckpointPersistenceGate.reset()
        remoteControlGate = WorkoutRemoteControlSequenceGate(
            checkpoint: recoveredIdentity.remoteControlCheckpoint
        )
    }

    private func resetMirrorTransport() {
        mirrorRetryTask?.cancel()
        mirrorRetryTask = nil
        mirrorShutdownWatchdogTask?.cancel()
        mirrorShutdownWatchdogTask = nil
        isMirroring = false
        isMirrorStartInFlight = false
        mirrorStartAttemptID = nil
        mirrorSendAttemptID = nil
        mirrorEnvelopeBuffer.reset()
        remoteControlGate.reset()
        pendingRemoteStateAcknowledgement = nil
        isTerminalMirrorDeliveryPending = false
        isStartFailureMirrorDeliveryPending = false
        shutdownMirrorFailureRetryCount = 0
    }

    func handleRemoteWorkoutEnvelopes(
        _ envelopes: [WorkoutEnvelopeV1],
        from workoutSession: HKWorkoutSession
    ) {
        guard session === workoutSession,
              let identity else {
            return
        }
        let expectedGeneration = identity.transportGenerationID
            ?? identity.sessionID
        let receivedAt = Date()

        for envelope in envelopes {
            guard envelope.sessionID == identity.sessionID,
                  envelope.sessionToken == identity.sessionToken,
                  envelope.transportGenerationID == expectedGeneration,
                  envelope.kind == .control,
                  let control = envelope.control else {
                continue
            }
            let requestedTerminalDisposition: WorkoutFinishDisposition?
            if [.starting, .running, .paused].contains(lifecycle.state) {
                switch control {
                case .endAndSave:
                    requestedTerminalDisposition = .save
                case .discard:
                    requestedTerminalDisposition = .discard
                case .requestCurrentSnapshot, .pause, .resume, .markSegment:
                    requestedTerminalDisposition = nil
                }
            } else {
                requestedTerminalDisposition = nil
            }
            let persistedTerminalDisposition: WorkoutFinishDisposition?
            let pendingTerminalErrorCode = requestedTerminalDisposition == nil
                ? nil
                : pendingTerminalErrorCodeForNextFinish
            let controlDisposition = Self.finishDisposition(for: control)
            let durableFinishDisposition = recoveryStore.recoveredIdentity?
                .finishRequest?.disposition ?? identity.finishRequest?.disposition
            let shouldPersistTerminalAcknowledgement = controlDisposition.map {
                requestedTerminalDisposition == $0
                    || ([.ending, .ended].contains(lifecycle.state)
                        && durableFinishDisposition == $0)
            } ?? false
            var issuedNativeStateChange = false
            do {
                var candidateGate = remoteControlGate
                guard try candidateGate.ingest(
                    envelope,
                    receivedAt: receivedAt
                ) else {
                    if control == .requestCurrentSnapshot,
                       let context = envelope.controlContext {
                        if isAutomaticStartConfirmed(context: context) {
                            publishAcknowledgement(
                                for: control,
                                acknowledgedSequence: envelope.sequence
                            )
                            publishSnapshotImmediately()
                        } else if pendingAutomaticStartAnnotation == nil {
                            // The gate checkpoint is intentionally durable
                            // before the HealthKit marker. Retrying the same
                            // sequence must therefore retry the marker write,
                            // not silently strand the decision.
                            beginAutomaticStartConfirmation(
                                context: context,
                                acknowledgedSequence: envelope.sequence,
                                at: receivedAt
                            )
                        }
                    }
                    if (control == .pause || control == .resume),
                       let context = envelope.controlContext,
                       context.origin == .automatic {
                        let transition = control == .pause
                            ? "pause"
                            : "resume"
                        let isAtTarget = control == .pause
                            ? lifecycle.state == .paused
                            : lifecycle.state == .running
                        if isAtTarget,
                           containsRideTransitionMarker(
                            context: context,
                            transition: transition
                           ) {
                            publishAcknowledgement(
                                for: control,
                                acknowledgedSequence: envelope.sequence
                            )
                            publishSnapshotImmediately()
                        } else if identity.pendingTransitionContext
                                    == context {
                            retryAutomaticTransitionConfirmation(
                                for: envelope,
                                context: context,
                                at: receivedAt
                            )
                        }
                    }
                    if control == .markSegment {
                        let wasWritten = containsSegmentEvent(
                            matching: envelope
                        )
                        if wasWritten {
                            clearPersistedRemoteSegmentIntent(
                                matching: envelope
                            )
                            publishAcknowledgement(
                                for: .markSegment,
                                acknowledgedSequence: envelope.sequence
                            )
                        } else if isPendingSegmentControl(envelope) {
                            publishAcknowledgement(
                                for: .markSegment,
                                acknowledgedSequence: envelope.sequence,
                                errorCode: .segmentMarkUnconfirmed
                            )
                        } else if let intent = recoveryStore
                            .recoveredIdentity?.remoteSegmentIntent,
                                  intent.matches(envelope) {
                            beginSegmentMark(
                                remoteContext: RemoteSegmentControlContext(
                                    envelope: envelope
                                ),
                                recoveredCandidate:
                                    Self.segmentCandidate(from: intent)
                            )
                        } else {
                            publishAcknowledgement(
                                for: .markSegment,
                                acknowledgedSequence: envelope.sequence,
                                errorCode: .segmentMarkFailed
                            )
                        }
                    }
                    _ = publishDurableTerminalAcknowledgement(
                        matching: envelope
                    )
                    continue
                }
                if control == .markSegment {
                    let context = RemoteSegmentControlContext(
                        envelope: envelope
                    )
                    if containsSegmentEvent(matching: envelope) {
                        publishAcknowledgement(
                            for: .markSegment,
                            acknowledgedSequence: envelope.sequence
                        )
                        continue
                    }
                    guard lifecycle.state == .running,
                          segmentOperationAttemptID == nil,
                          builder != nil
                            || injectedSegmentEventOperation != nil else {
                        let didPersistRejection =
                            commitRemoteSegmentRejection(envelope)
                        publishAcknowledgement(
                            for: .markSegment,
                            acknowledgedSequence: envelope.sequence,
                            errorCode: didPersistRejection
                                ? .segmentMarkFailed
                                : .segmentMarkUnconfirmed
                        )
                        continue
                    }
                    guard let candidate = makeCurrentSegmentCandidate() else {
                        let didPersistRejection =
                            commitRemoteSegmentRejection(envelope)
                        publishAcknowledgement(
                            for: .markSegment,
                            acknowledgedSequence: envelope.sequence,
                            errorCode: didPersistRejection
                                ? .segmentMarkFailed
                                : .segmentMarkUnconfirmed
                        )
                        continue
                    }
                    guard commitRemoteSegmentControl(
                        envelope,
                        candidate: candidate
                    ) else {
                        segmentError = .healthKitWriteFailed
                        publishAcknowledgement(
                            for: .markSegment,
                            acknowledgedSequence: envelope.sequence,
                            errorCode: .segmentMarkUnconfirmed
                        )
                        continue
                    }
                    beginSegmentMark(
                        remoteContext: context,
                        recoveredCandidate: candidate
                    )
                    continue
                }
                let terminalAcknowledgement:
                    WatchWorkoutRecoveryStore.RemoteTerminalAcknowledgement?
                if shouldPersistTerminalAcknowledgement {
                    guard let acknowledgementSequence =
                            recoveryStore.nextSequence() else {
                        finishRequestError = .persistenceFailed
                        continue
                    }
                    terminalAcknowledgement = .init(
                        control: control,
                        controlSenderID: envelope.controlSenderID,
                        acknowledgedSequence: envelope.sequence,
                        capturedAt: envelope.capturedAt,
                        envelopeSequence: acknowledgementSequence,
                        envelopeCapturedAt: Date()
                    )
                } else {
                    terminalAcknowledgement = nil
                }
                if (control == .pause || control == .resume),
                   envelope.controlContext?.origin == .automatic {
                    let durableIdentity =
                        recoveryStore.recoveredIdentity ?? identity
                    if control == .resume,
                       durableIdentity.pauseOrigin != .automatic {
                        publishAcknowledgement(
                            for: control,
                            acknowledgedSequence: envelope.sequence,
                            errorCode: .sessionFailed
                        )
                        continue
                    }
                    if control == .pause,
                       durableIdentity.lastTransitionOrigin == .manual,
                       let transitionAt =
                            durableIdentity.lastTransitionAt,
                       receivedAt.timeIntervalSince(transitionAt) < 15 {
                        publishAcknowledgement(
                            for: control,
                            acknowledgedSequence: envelope.sequence,
                            errorCode: .sessionFailed
                        )
                        continue
                    }
                    // Make automatic provenance durable before asking
                    // HealthKit to mutate the session. A crash between the
                    // request and callback can then recover the correct origin.
                    _ = try recoveryStore.persistRemoteControlCheckpoint(
                        candidateGate.checkpoint,
                        pendingTransitionContext: envelope.controlContext,
                        pendingTransitionPaused: control == .pause,
                        pendingTransitionRequestedAt: receivedAt
                    )
                    remoteControlGate = candidateGate
                    if let persistedIdentity = recoveryStore.recoveredIdentity {
                        self.identity = persistedIdentity
                    }
                } else if control == .pause || control == .resume {
                    try beginManualTransitionOverride()
                }
                switch control {
                case .pause where lifecycle.state == .running:
                    pendingRemoteStateAcknowledgement = (
                        control,
                        envelope.sequence,
                        envelope.controlContext
                    )
                    issuedNativeStateChange = true
                    if let injectedRemotePauseOperation {
                        injectedRemotePauseOperation(workoutSession)
                    } else {
                        workoutSession.pause()
                    }
                case .resume where lifecycle.state == .paused:
                    pendingRemoteStateAcknowledgement = (
                        control,
                        envelope.sequence,
                        envelope.controlContext
                    )
                    issuedNativeStateChange = true
                    if let injectedRemoteResumeOperation {
                        injectedRemoteResumeOperation(workoutSession)
                    } else {
                        workoutSession.resume()
                    }
                case .requestCurrentSnapshot, .pause, .resume,
                     .markSegment, .endAndSave, .discard:
                    break
                }
                persistedTerminalDisposition = try recoveryStore
                    .persistRemoteControlCheckpoint(
                        candidateGate.checkpoint,
                        finishing: requestedTerminalDisposition,
                        requestedAt: requestedTerminalDisposition == nil
                            ? nil
                            : receivedAt,
                        explicitRiderChoice: true,
                        terminalErrorCode: pendingTerminalErrorCode,
                        terminalAcknowledgement: terminalAcknowledgement
                    )
                if persistedTerminalDisposition != nil {
                    finishRequestError = nil
                    if pendingTerminalErrorCode != nil {
                        pendingTerminalErrorCodeForNextFinish = nil
                    }
                }
                remoteControlGate = candidateGate
                if let persistedIdentity = recoveryStore.recoveredIdentity {
                    self.identity = persistedIdentity
                }
            } catch {
                if requestedTerminalDisposition != nil {
                    finishRequestError = .persistenceFailed
                }
                continue
            }

            switch control {
            case .requestCurrentSnapshot:
                if let context = envelope.controlContext,
                   context.origin == .automatic {
                    beginAutomaticStartConfirmation(
                        context: context,
                        acknowledgedSequence: envelope.sequence,
                        at: receivedAt
                    )
                } else {
                    publishSnapshotImmediately()
                }
            case .pause:
                if issuedNativeStateChange { break }
                if lifecycle.state == .paused {
                    if let context = envelope.controlContext,
                       context.origin == .automatic {
                        retryAutomaticTransitionConfirmation(
                            for: envelope,
                            context: context,
                            at: receivedAt
                        )
                    } else {
                        publishAcknowledgement(
                            for: control,
                            acknowledgedSequence: envelope.sequence
                        )
                    }
                }
            case .resume:
                if issuedNativeStateChange { break }
                if lifecycle.state == .running {
                    if let context = envelope.controlContext,
                       context.origin == .automatic {
                        retryAutomaticTransitionConfirmation(
                            for: envelope,
                            context: context,
                            at: receivedAt
                        )
                    } else {
                        publishAcknowledgement(
                            for: control,
                            acknowledgedSequence: envelope.sequence
                        )
                    }
                }
            case .markSegment:
                break
            case .endAndSave:
                if persistedTerminalDisposition == .save {
                    _ = publishDurableTerminalAcknowledgement(
                        matching: envelope,
                        resultingState: .ending
                    )
                    beginPersistedFinishRequest(requestedAt: receivedAt)
                } else if lifecycle.state == .ending,
                   lifecycle.finishDisposition == .save {
                    _ = publishDurableTerminalAcknowledgement(
                        matching: envelope
                    )
                }
            case .discard:
                if persistedTerminalDisposition == .discard {
                    _ = publishDurableTerminalAcknowledgement(
                        matching: envelope,
                        resultingState: .ending
                    )
                    beginPersistedFinishRequest(requestedAt: receivedAt)
                } else if lifecycle.state == .ending,
                   lifecycle.finishDisposition == .discard {
                    _ = publishDurableTerminalAcknowledgement(
                        matching: envelope
                    )
                }
            }
        }
    }

    private static func finishDisposition(
        for control: WorkoutControlV1
    ) -> WorkoutFinishDisposition? {
        switch control {
        case .endAndSave:
            .save
        case .discard:
            .discard
        case .requestCurrentSnapshot, .pause, .resume, .markSegment:
            nil
        }
    }

    @discardableResult
    private func publishDurableTerminalAcknowledgement(
        matching envelope: WorkoutEnvelopeV1,
        resultingState: WorkoutSessionStateV1? = nil
    ) -> Bool {
        let acknowledgementState = resultingState ?? lifecycle.state
        guard [.ending, .ended].contains(acknowledgementState),
              let control = envelope.control,
              let durableIdentity = recoveryStore.recoveredIdentity ?? identity,
              let record = durableIdentity.remoteTerminalAcknowledgement,
              record.control == control,
              record.controlSenderID == envelope.controlSenderID,
              record.acknowledgedSequence == envelope.sequence,
              record.capturedAt == envelope.capturedAt,
              record.disposition == durableIdentity.finishRequest?.disposition
        else {
            return false
        }
        let acknowledgementSequence: UInt64
        let acknowledgementCapturedAt: Date
        if let latestEnvelope,
           record.envelopeSequence <= latestEnvelope.sequence {
            guard let currentSequence = recoveryStore.nextSequence(),
                  currentSequence > latestEnvelope.sequence else {
                return false
            }
            acknowledgementSequence = currentSequence
            acknowledgementCapturedAt = Date()
        } else {
            acknowledgementSequence = record.envelopeSequence
            acknowledgementCapturedAt = record.envelopeCapturedAt
        }
        let acknowledgementEnvelope = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: durableIdentity.sessionID,
            sessionToken: durableIdentity.sessionToken,
            transportGenerationID:
                durableIdentity.transportGenerationID
                    ?? durableIdentity.sessionID,
            sequence: acknowledgementSequence,
            capturedAt: acknowledgementCapturedAt,
            acknowledgement: WorkoutAcknowledgementV1(
                control: record.control,
                resultingState: acknowledgementState,
                acknowledgedSequence: record.acknowledgedSequence
            )
        )
        guard (try? WorkoutContractCodec.validate(
            acknowledgementEnvelope
        )) != nil else {
            return false
        }
        offerEnvelopeToMirror(acknowledgementEnvelope)
        return true
    }

    private func publishAcknowledgement(
        for control: WorkoutControlV1,
        acknowledgedSequence: UInt64,
        errorCode: WorkoutSafeErrorCodeV1? = nil
    ) {
        guard let identity,
              let sequence = recoveryStore.nextSequence() else {
            return
        }
        let capturedAt = Date()
        let envelope = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: sequence,
            capturedAt: capturedAt,
            acknowledgement: WorkoutAcknowledgementV1(
                control: control,
                resultingState: lifecycle.state,
                acknowledgedSequence: acknowledgedSequence,
                errorCode: errorCode
            )
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else {
            return
        }
        offerEnvelopeToMirror(envelope)
    }

    private func publishPendingRemoteStateAcknowledgementIfConfirmed() {
        guard let pendingRemoteStateAcknowledgement else { return }
        if let context = pendingRemoteStateAcknowledgement.context,
           context.origin == .automatic {
            guard identity?.pendingTransitionContext == nil,
                  identity?.lastTransitionOrigin == .automatic,
                  identity?.detectorProfileVersion
                    == context.detectorProfileVersion else {
                return
            }
        }
        let isConfirmed: Bool
        switch pendingRemoteStateAcknowledgement.control {
        case .pause:
            isConfirmed = lifecycle.state == .paused
        case .resume:
            isConfirmed = lifecycle.state == .running
        case .markSegment:
            isConfirmed = true
        case .endAndSave, .discard:
            isConfirmed = lifecycle.state == .ending
                || lifecycle.state == .ended
        case .requestCurrentSnapshot:
            isConfirmed = true
        }
        guard isConfirmed else { return }
        self.pendingRemoteStateAcknowledgement = nil
        publishAcknowledgement(
            for: pendingRemoteStateAcknowledgement.control,
            acknowledgedSequence: pendingRemoteStateAcknowledgement.sequence
        )
    }

    @discardableResult
    private func confirmRideTransition(
        paused: Bool,
        at date: Date,
        remoteContext: WorkoutControlContextV1?
    ) async -> Bool {
        let persistedContext = identity?.pendingTransitionContext
        let automaticContext = manualTransitionOverridePending
            ? nil
            : [remoteContext, persistedContext]
                .compactMap { $0 }
                .first(where: { $0.origin == .automatic })
        let origin: WorkoutTransitionOrigin = automaticContext == nil
            ? .manual
            : .automatic
        let profileVersion = automaticContext?.detectorProfileVersion

        if let automaticContext {
            guard pendingAutomaticTransitionAnnotation == nil else {
                return false
            }
            let transition = paused ? "pause" : "resume"
            if !containsRideTransitionMarker(
                context: automaticContext,
                transition: transition
            ) {
                guard let builder else {
                    lastErrorCode = .sessionFailed
                    return false
                }
                let event = makeRideTransitionMarker(
                    paused: paused,
                    origin: .automatic,
                    context: automaticContext,
                    at: date
                )
                pendingAutomaticTransitionAnnotation = automaticContext
                let outcome = await Self.segmentEventWriteOutcome(
                    event,
                    to: builder,
                    injectedOperation:
                        injectedRideTransitionEventOperation
                )
                guard pendingAutomaticTransitionAnnotation
                        == automaticContext else {
                    return false
                }
                pendingAutomaticTransitionAnnotation = nil
                guard outcome == .success else {
                    lastErrorCode = .sessionFailed
                    return false
                }
            }

            // A Watch-side rider action can arrive while the HealthKit marker
            // write is suspended. Manual intent is authoritative even if the
            // automatic marker completed first.
            guard !manualTransitionOverridePending,
                  (recoveryStore.recoveredIdentity ?? identity)?
                    .pendingTransitionContext == automaticContext else {
                return false
            }
        } else {
            guard let builder else {
                lastErrorCode = .sessionFailed
                return false
            }
            let event = makeRideTransitionMarker(
                paused: paused,
                origin: .manual,
                context: nil,
                at: date
            )
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation: injectedRideTransitionEventOperation
            )
            guard outcome == .success else {
                lastErrorCode = .sessionFailed
                clearManualTransitionOverride()
                return false
            }
        }

        var transitionPersisted = false
        do {
            try recoveryStore.confirmRideTransition(
                origin: origin,
                paused: paused,
                at: date,
                detectorProfileVersion: profileVersion
            )
            identity = recoveryStore.recoveredIdentity ?? identity
            transitionPersisted = true
        } catch {
            lastErrorCode = .sessionFailed
        }
        clearManualTransitionOverride()
        if origin == .automatic, transitionPersisted {
            playAutomaticTransitionFeedback()
        }
        return transitionPersisted
    }

    private func makeRideTransitionMarker(
        paused: Bool,
        origin: WorkoutTransitionOrigin,
        context: WorkoutControlContextV1?,
        at date: Date,
        transition: String? = nil
    ) -> HKWorkoutEvent {
        var metadata: [String: Any] = [
            RideTransitionMetadataKey.marker: true,
            RideTransitionMetadataKey.schema: 1,
            RideTransitionMetadataKey.transition:
                transition ?? (paused ? "pause" : "resume"),
            RideTransitionMetadataKey.origin:
                origin == .automatic ? "automatic" : "manual",
        ]
        if let rideGeneration = context?.rideGeneration {
            metadata[RideTransitionMetadataKey.rideGeneration] =
                NSNumber(value: rideGeneration)
        }
        if let decisionSequence = context?.decisionSequence {
            metadata[RideTransitionMetadataKey.decisionSequence] =
                NSNumber(value: decisionSequence)
        }
        if let profileVersion = context?.detectorProfileVersion {
            metadata[RideTransitionMetadataKey.profileVersion] =
                NSNumber(value: profileVersion)
        }
        let event = HKWorkoutEvent(
            type: .marker,
            dateInterval: DateInterval(start: date, end: date),
            metadata: metadata
        )
        return event
    }

    private func beginAutomaticStartConfirmation(
        context: WorkoutControlContextV1,
        acknowledgedSequence: UInt64,
        at date: Date
    ) {
        suppliedConfigurationStartOriginTask?.cancel()
        suppliedConfigurationStartOriginTask = nil
        suppliedConfigurationStartOriginPending = false
        localStartOriginPending = false
        guard context.origin == .automatic,
              pendingAutomaticStartAnnotation == nil,
              let builder else {
            return
        }
        if isAutomaticStartConfirmed(context: context) {
            publishAcknowledgement(
                for: .requestCurrentSnapshot,
                acknowledgedSequence: acknowledgedSequence
            )
            publishSnapshotImmediately()
            return
        }
        let event = makeRideTransitionMarker(
            paused: false,
            origin: .automatic,
            context: context,
            at: date,
            transition: "start"
        )
        pendingAutomaticStartAnnotation = context
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation:
                    self.injectedRideTransitionEventOperation
            )
            guard pendingAutomaticStartAnnotation == context else {
                return
            }
            pendingAutomaticStartAnnotation = nil
            guard outcome == .success,
                  persistAutomaticStartConfirmation(
                    context: context,
                    at: date
                  ) else {
                lastErrorCode = .sessionFailed
                publishSnapshotImmediately()
                return
            }
            playAutomaticTransitionFeedback()
            publishAcknowledgement(
                for: .requestCurrentSnapshot,
                acknowledgedSequence: acknowledgedSequence
            )
            publishSnapshotImmediately()
        }
    }

    private func persistAutomaticStartConfirmation(
        context: WorkoutControlContextV1,
        at date: Date
    ) -> Bool {
        do {
            try recoveryStore.confirmRideTransition(
                origin: .automatic,
                paused: false,
                at: date,
                detectorProfileVersion: context.detectorProfileVersion
            )
            identity = recoveryStore.recoveredIdentity ?? identity
            return true
        } catch {
            return false
        }
    }

    private func confirmLaunchAutomaticStart(
        context: WorkoutControlContextV1,
        at date: Date
    ) async -> Bool {
        guard let builder else { return false }
        if !containsRideTransitionMarker(
            context: context,
            transition: "start"
        ) {
            let event = makeRideTransitionMarker(
                paused: false,
                origin: .automatic,
                context: context,
                at: date,
                transition: "start"
            )
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation: injectedRideTransitionEventOperation
            )
            guard outcome == .success else {
                lastErrorCode = .sessionFailed
                return false
            }
        }
        guard persistAutomaticStartConfirmation(
            context: context,
            at: date
        ) else {
            lastErrorCode = .sessionFailed
            return false
        }
        activeLaunchAutomaticStartContext = nil
        playAutomaticTransitionFeedback()
        return true
    }

    private func confirmManualStart(at date: Date) async {
        guard localStartOriginPending else { return }
        guard let builder else {
            lastErrorCode = .sessionFailed
            return
        }
        let event = makeRideTransitionMarker(
            paused: false,
            origin: .manual,
            context: nil,
            at: date,
            transition: "start"
        )
        let outcome = await Self.segmentEventWriteOutcome(
            event,
            to: builder,
            injectedOperation: injectedRideTransitionEventOperation
        )
        guard outcome == .success else {
            lastErrorCode = .sessionFailed
            return
        }
        do {
            try recoveryStore.confirmRideTransition(
                origin: .manual,
                paused: false,
                at: date,
                detectorProfileVersion: nil
            )
            identity = recoveryStore.recoveredIdentity ?? identity
        } catch {
            lastErrorCode = .sessionFailed
            return
        }
        localStartOriginPending = false
    }

    private func scheduleSuppliedConfigurationManualStart(
        at transitionDate: Date
    ) {
        guard suppliedConfigurationStartOriginPending,
              suppliedConfigurationStartOriginTask == nil else { return }
        suppliedConfigurationStartOriginTask = Task { @MainActor [weak self] in
            do {
                // The iPhone's RAUT decision remains live for 30 seconds.
                // Wait beyond that window so a delayed application context or
                // exact mirrored start annotation cannot race a manual label.
                try await Task.sleep(nanoseconds: 35_000_000_000)
            } catch {
                return
            }
            guard let self,
                  suppliedConfigurationStartOriginPending,
                  lifecycle.state == .running,
                  identity?.lastTransitionOrigin == nil else { return }
            suppliedConfigurationStartOriginPending = false
            suppliedConfigurationStartOriginTask = nil
            localStartOriginPending = true
            await confirmManualStart(at: transitionDate)
            publishSnapshotImmediately()
        }
    }

    private func playAutomaticTransitionFeedback() {
        guard rideDetectionSettings.alertMode != 2 else { return }
        WKInterfaceDevice.current().play(.success)
    }

    private func isAutomaticStartConfirmed(
        context: WorkoutControlContextV1
    ) -> Bool {
        guard containsRideTransitionMarker(
            context: context,
            transition: "start"
        ) else {
            return false
        }
        if identity?.lastTransitionOrigin == .automatic,
           identity?.detectorProfileVersion == context.detectorProfileVersion {
            return true
        }
        return persistAutomaticStartConfirmation(context: context, at: Date())
    }

    private func containsRideTransitionMarker(
        context: WorkoutControlContextV1,
        transition: String
    ) -> Bool {
        guard let rideGeneration = context.rideGeneration,
              let decisionSequence = context.decisionSequence else {
            return false
        }
        return builder?.workoutEvents.contains { event in
            guard event.type == .marker,
                  let metadata = event.metadata,
                  metadata[RideTransitionMetadataKey.marker] as? Bool == true,
                  let schemaNumber = metadata[
                    RideTransitionMetadataKey.schema
                  ] as? NSNumber,
                  Self.exactUnsignedMetadata(
                    schemaNumber,
                    as: UInt8.self
                  ) == 1,
                  metadata[RideTransitionMetadataKey.transition] as? String
                    == transition,
                  metadata[RideTransitionMetadataKey.origin] as? String
                    == "automatic",
                  let generationNumber = metadata[
                    RideTransitionMetadataKey.rideGeneration
                  ] as? NSNumber,
                  Self.exactUnsignedMetadata(
                    generationNumber,
                    as: UInt32.self
                  ) == rideGeneration,
                  let sequenceNumber = metadata[
                    RideTransitionMetadataKey.decisionSequence
                  ] as? NSNumber,
                  Self.exactUnsignedMetadata(
                    sequenceNumber,
                    as: UInt32.self
                  ) == decisionSequence,
                  let profileNumber = metadata[
                    RideTransitionMetadataKey.profileVersion
                  ] as? NSNumber,
                  Self.exactUnsignedMetadata(
                    profileNumber,
                    as: UInt16.self
                  ) == context.detectorProfileVersion else {
                return false
            }
            return true
        } ?? false
    }

    private static func exactUnsignedMetadata<
        T: FixedWidthInteger & UnsignedInteger
    >(
        _ number: NSNumber,
        as type: T.Type
    ) -> T? {
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        return T(exactly: value)
    }

    private func retryAutomaticTransitionConfirmation(
        for envelope: WorkoutEnvelopeV1,
        context: WorkoutControlContextV1,
        at date: Date
    ) {
        guard pendingAutomaticTransitionAnnotation == nil,
              let control = envelope.control,
              control == .pause || control == .resume else {
            return
        }
        pendingRemoteStateAcknowledgement = (
            control,
            envelope.sequence,
            context
        )
        if control == .pause, lifecycle.state == .running,
           let session {
            if let injectedRemotePauseOperation {
                injectedRemotePauseOperation(session)
            } else {
                session.pause()
            }
            return
        }
        if control == .resume, lifecycle.state == .paused,
           let session {
            if let injectedRemoteResumeOperation {
                injectedRemoteResumeOperation(session)
            } else {
                session.resume()
            }
            return
        }
        guard (control == .pause && lifecycle.state == .paused)
                || (control == .resume && lifecycle.state == .running) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didConfirm = await confirmRideTransition(
                paused: control == .pause,
                at: date,
                remoteContext: context
            )
            publishSnapshotImmediately()
            if didConfirm {
                publishPendingRemoteStateAcknowledgementIfConfirmed()
            }
        }
    }

    /// A rider pause/resume must retire any durable detector intent before
    /// HealthKit is asked to change state. Otherwise a crash between the
    /// request and state callback could recover the rider's action as an
    /// automatic transition.
    private func beginManualTransitionOverride() throws {
        try recoveryStore.clearPendingAutomaticTransitionForManualRequest()
        identity = recoveryStore.recoveredIdentity ?? identity
        manualTransitionOverridePending = true
        manualTransitionOverrideGeneration &+= 1
        let generation = manualTransitionOverrideGeneration
        manualTransitionOverrideTimeoutTask?.cancel()
        manualTransitionOverrideTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self,
                  manualTransitionOverrideGeneration == generation else {
                return
            }
            manualTransitionOverridePending = false
            manualTransitionOverrideTimeoutTask = nil
        }
    }

    private func clearManualTransitionOverride() {
        manualTransitionOverridePending = false
        manualTransitionOverrideTimeoutTask?.cancel()
        manualTransitionOverrideTimeoutTask = nil
    }

    private func noteManualPauseOrResumeRequest(at date: Date) async {
        do {
            try beginManualTransitionOverride()
        } catch {
            lastErrorCode = .sessionFailed
            return
        }

        // HealthKit can deliver the marker callback immediately after the
        // state callback. Correct a same-transition automatic attribution so
        // the rider's Watch-button action always wins.
        if let lastTransitionAt = identity?.lastTransitionAt,
           abs(date.timeIntervalSince(lastTransitionAt)) <= 2 {
            guard let builder else {
                lastErrorCode = .sessionFailed
                return
            }
            let event = makeRideTransitionMarker(
                paused: lifecycle.state == .paused,
                origin: .manual,
                context: nil,
                at: date
            )
            let outcome = await Self.segmentEventWriteOutcome(
                event,
                to: builder,
                injectedOperation: injectedRideTransitionEventOperation
            )
            guard outcome == .success else {
                lastErrorCode = .sessionFailed
                return
            }
            do {
                try recoveryStore.confirmRideTransition(
                    origin: .manual,
                    paused: lifecycle.state == .paused,
                    at: date,
                    detectorProfileVersion: identity?.detectorProfileVersion
                )
                identity = recoveryStore.recoveredIdentity ?? identity
                clearManualTransitionOverride()
            } catch {
                lastErrorCode = .sessionFailed
            }
        }
    }

    private func startPeriodicSnapshots() {
        guard periodicSnapshotTask == nil else { return }
        periodicSnapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                scheduleCoalescedSnapshot()
            }
        }
    }

    private func scheduleCoalescedSnapshot() {
        guard lifecycle.state.isActive, coalescedSnapshotTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastSnapshotPublishedAt)
        if elapsed >= 1 {
            publishSnapshotImmediately()
            return
        }
        let delay = max(0, 1 - elapsed)
        coalescedSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            coalescedSnapshotTask = nil
            publishSnapshotImmediately()
        }
    }

    @discardableResult
    private func publishSnapshotImmediately(
        snapshotOverride: WorkoutSnapshotV1? = nil,
        envelopeCapturedAt: Date? = nil
    ) -> Bool {
        guard let identity else { return false }
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        let capturedAt = envelopeCapturedAt ?? Date()
        let snapshot = snapshotOverride ?? makeSnapshot(capturedAt: capturedAt)
        self.snapshot = snapshot
        lastSnapshotPublishedAt = capturedAt
        guard let sequence = recoveryStore.nextSequence() else {
            lastErrorCode = .sessionFailed
            return false
        }
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: snapshot
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else {
            return false
        }
        latestEnvelope = envelope
        offerEnvelopeToMirror(envelope)
        return true
    }

    @discardableResult
    private func publishFailureSnapshot() -> Bool {
        let capturedAt = Date()
        let failedSnapshot = WorkoutSnapshotV1(
            state: .failed,
            startDate: identity?.startDate ?? snapshot.startDate,
            availability: [],
            errorCode: lastErrorCode ?? .sessionFailed
        )
        snapshot = failedSnapshot
        lastSnapshotPublishedAt = capturedAt

        guard let identity,
              let sequence = recoveryStore.nextSequence() else {
            return false
        }
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: failedSnapshot
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else {
            return false
        }
        latestEnvelope = envelope
        offerEnvelopeToMirror(envelope)
        return true
    }

    private func makeSnapshot(capturedAt: Date) -> WorkoutSnapshotV1 {
        let elapsedTime = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: injectedBuilderElapsedTime?(builder)
                ?? builder?.elapsedTime
                ?? .nan,
            startDate: identity?.startDate,
            capturedAt: capturedAt
        )

        let currentHeartRate = WorkoutMetricFreshness.metric(
            self.currentHeartRate,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
        )
        let cyclingPower = WorkoutMetricFreshness.metric(
            self.cyclingPower,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        let cyclingCadence = WorkoutMetricFreshness.metric(
            self.cyclingCadence,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        let freshLocation = routeRecorder.latestLocation.flatMap { location in
            WorkoutMetricFreshness.isFresh(
                capturedAt: location.timestamp,
                now: capturedAt,
                maximumAge: WorkoutMetricFreshness.watchLocationMaximumAge
            ) ? location : nil
        }
        let location = makeLocation(
            from: freshLocation,
            capturedAt: capturedAt
        )
        let liveRouteDistance: WorkoutMetricCandidate? = routeRecorder.routeDistanceMeters.flatMap { value in
            guard let routeDistanceCapturedAt = routeRecorder.routeDistanceCapturedAt else {
                return nil
            }
            return WorkoutMetricCandidate(
                value: value,
                capturedAt: min(routeDistanceCapturedAt, capturedAt),
                source: .watchRoute
            )
        }
        let routeDistance = terminalRouteDistance ?? liveRouteDistance
        let distanceCandidate = WorkoutMetricPrecedence.cyclingDistance(
            healthKit: healthKitDistance,
            watchRoute: routeDistance
        )
        let distance = distanceCandidate.map {
            WorkoutMetricV1(
                value: $0.value,
                unit: .meters,
                capturedAt: min($0.capturedAt, capturedAt),
                source: $0.source
            )
        }

        let locationSpeed = freshLocation.flatMap { location -> WorkoutMetricCandidate? in
            guard location.speed.isFinite, location.speed >= 0 else { return nil }
            return WorkoutMetricCandidate(
                value: location.speed,
                capturedAt: min(location.timestamp, capturedAt),
                source: .watchLocation
            )
        }
        let speedCandidate = WorkoutMetricPrecedence.currentSpeed(
            pairedSensor: WorkoutMetricFreshness.candidate(
                pairedSensorSpeed,
                now: capturedAt,
                maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ),
            watchLocation: locationSpeed
        )
        let speed = speedCandidate.map {
            WorkoutMetricV1(
                value: $0.value,
                unit: .metersPerSecond,
                capturedAt: min($0.capturedAt, capturedAt),
                source: $0.source
            )
        }

        var availability: WorkoutAvailabilityMaskV1 = []
        if elapsedTime != nil { availability.insert(.elapsedTime) }
        if currentHeartRate != nil { availability.insert(.currentHeartRate) }
        if averageHeartRate != nil { availability.insert(.averageHeartRate) }
        if activeEnergy != nil { availability.insert(.activeEnergy) }
        if distance != nil { availability.insert(.cyclingDistance) }
        if speed != nil { availability.insert(.currentSpeed) }
        if cyclingPower != nil { availability.insert(.cyclingPower) }
        if cyclingCadence != nil { availability.insert(.cyclingCadence) }
        if location != nil { availability.insert(.location) }
        if location?.altitude != nil { availability.insert(.altitude) }

        let heartRateZoneMaximumHeartRateBPM =
            heartRateZoneRuntimeMaximumHeartRateBPM
                ?? identity?.heartRateZoneMaximumHeartRateBPM
                ?? maximumHeartRateBPM
        let currentHeartRateZone = WorkoutHeartRateZoneProfile(
            maximumHeartRateBPM: heartRateZoneMaximumHeartRateBPM
        ).zone(for: currentHeartRate?.value)
        let previousHeartRateZoneCheckpoint =
            heartRateZoneDurationAccumulator.checkpoint
        _ = heartRateZoneDurationAccumulator.update(
            sessionID: identity?.sessionID,
            elapsedTime: elapsedTime?.value,
            currentZone: currentHeartRateZone
        )
        heartRateZoneCheckpointPersistenceGate.observeTransition(
            from: previousHeartRateZoneCheckpoint,
            to: heartRateZoneDurationAccumulator.checkpoint
        )
        persistHeartRateZoneCheckpointIfNeeded(at: capturedAt)
        let heartRateZoneDurations =
            heartRateZoneDurationAccumulator.authoritativeDurations(
                capturedAt: capturedAt,
                maximumHeartRateBPM:
                    identity?.heartRateZoneMaximumHeartRateBPM
            )
        if currentHeartRateZone != nil || heartRateZoneDurations != nil {
            availability.insert(.heartRateZone)
        }

        let terminalOutcome: WorkoutTerminalOutcomeV1?
        switch summary?.outcome {
        case .saved? where lifecycle.state == .ended:
            terminalOutcome = .saved
        case .discarded? where lifecycle.state == .ended:
            terminalOutcome = .discarded
        default:
            terminalOutcome = nil
        }

        let wallElapsedTime: WorkoutMetricV1? = (identity?.startDate)
            .flatMap { startDate in
            let seconds = capturedAt.timeIntervalSince(startDate)
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return WorkoutMetricV1(
                value: seconds,
                unit: .seconds,
                capturedAt: capturedAt
            )
            }
        let hasPendingAutomaticTransition =
            identity?.pendingTransitionContext?.origin == .automatic

        return WorkoutSnapshotV1(
            state: lifecycle.state,
            startDate: identity?.startDate,
            elapsedTime: elapsedTime,
            currentHeartRate: currentHeartRate,
            averageHeartRate: averageHeartRate,
            activeEnergy: activeEnergy,
            cyclingDistance: distance,
            currentSpeed: speed,
            cyclingPower: cyclingPower,
            cyclingCadence: cyclingCadence,
            currentHeartRateZone: currentHeartRateZone,
            heartRateZoneCount:
                currentHeartRateZone == nil
                    && heartRateZoneDurations == nil
                ? nil
                : WorkoutHeartRateZoneProfile.zoneCount,
            heartRateZoneDurations: heartRateZoneDurations,
            location: location,
            lastCompletedSegment: segmentAccumulator.lastCompletedSegment,
            availability: availability,
            errorCode: lastErrorCode,
            terminalOutcome: terminalOutcome,
            pauseOrigin: lifecycle.state == .paused
                ? (hasPendingAutomaticTransition
                    ? .unknown
                    : identity?.pauseOrigin ?? .manual)
                : nil,
            lastTransitionOrigin: hasPendingAutomaticTransition
                ? .unknown
                : identity?.lastTransitionOrigin,
            lastTransitionAt: identity?.lastTransitionAt,
            wallElapsedTime: wallElapsedTime,
            detectorProfileVersion: hasPendingAutomaticTransition
                ? nil
                : identity?.detectorProfileVersion
        )
    }

    private func persistHeartRateZoneCheckpointIfNeeded(at capturedAt: Date) {
        guard let checkpoint = heartRateZoneDurationAccumulator.checkpoint,
              heartRateZoneCheckpointPersistenceGate.shouldAttempt(
                  at: capturedAt
              ) else {
            return
        }
        do {
            try recoveryStore.persistHeartRateZoneCheckpoint(checkpoint)
            identity = recoveryStore.recoveredIdentity ?? identity
            heartRateZoneCheckpointPersistenceGate.markSucceeded()
        } catch {
            // Zone time remains live in memory. Retry the durable checkpoint
            // after the bounded attempt interval.
        }
    }

    private func makeLocation(
        from location: CLLocation?,
        capturedAt: Date
    ) -> WorkoutLocationV1? {
        guard let location else { return nil }
        let hasAltitude = location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
        let course = location.course.isFinite && (0..<360).contains(location.course)
            ? location.course
            : nil
        let speed = location.speed.isFinite && location.speed >= 0 ? location.speed : nil
        return WorkoutLocationV1(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            capturedAt: min(location.timestamp, capturedAt),
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: hasAltitude ? location.altitude : nil,
            verticalAccuracy: hasAltitude ? location.verticalAccuracy : nil,
            course: course,
            speed: speed
        )
    }

    private func makeSummary(
        outcome: WatchWorkoutSummary.Outcome,
        endDate: Date,
        routeDistanceMeters: Double?,
        routeStatus: WorkoutRouteSaveStatus
    ) -> WatchWorkoutSummary {
        let routeDistance = routeDistanceMeters.map { value in
            WorkoutMetricCandidate(
                value: value,
                capturedAt: endDate,
                source: .watchRoute
            )
        }
        return WatchWorkoutSummary(
            outcome: outcome,
            endedAt: endDate,
            duration: max(0, builder?.elapsedTime ?? 0),
            distanceMeters: WorkoutMetricPrecedence.cyclingDistance(
                healthKit: healthKitDistance,
                watchRoute: routeDistance
            )?.value,
            activeEnergyKilocalories: activeEnergy?.value,
            averageHeartRate: averageHeartRate?.value,
            routeStatus: routeStatus,
            terminalErrorCode: durableTerminalErrorCode
        )
    }

    private func makeSummary(
        from workout: HKWorkout,
        routeStatus: WorkoutRouteSaveStatus
    ) -> WatchWorkoutSummary {
        let distance = HKObjectType.quantityType(forIdentifier: .distanceCycling)
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .meter()) }
            .flatMap { value in value.isFinite && value >= 0 ? value : nil }
        let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .kilocalorie()) }
            .flatMap { value in value.isFinite && value >= 0 ? value : nil }
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let averageHeartRate = HKObjectType.quantityType(forIdentifier: .heartRate)
            .flatMap { workout.statistics(for: $0)?.averageQuantity() }
            .map { $0.doubleValue(for: heartRateUnit) }
            .flatMap { value in value.isFinite && value > 0 ? value : nil }
        let duration = workout.duration
        return WatchWorkoutSummary(
            outcome: .saved,
            endedAt: workout.endDate,
            duration: duration.isFinite ? max(0, duration) : 0,
            distanceMeters: distance,
            activeEnergyKilocalories: energy,
            averageHeartRate: averageHeartRate,
            routeStatus: routeStatus,
            terminalErrorCode: durableTerminalErrorCode
        )
    }

    private func makeDetachedSavedSummary(
        identity: WatchWorkoutRecoveryStore.Identity
    ) -> WatchWorkoutSummary {
        let request = identity.finishRequest
        let endDate = request?.requestedAt ?? identity.startDate
        return WatchWorkoutSummary(
            outcome: .saved,
            endedAt: endDate,
            duration: nil,
            distanceMeters: nil,
            activeEnergyKilocalories: nil,
            averageHeartRate: nil,
            routeStatus: request?.routeStatus ?? .unknown,
            terminalErrorCode: request?.terminalErrorCode
        )
    }

    private var durableTerminalErrorCode: WorkoutSafeErrorCodeV1? {
        recoveryStore.recoveredIdentity?.finishRequest?.terminalErrorCode
            ?? identity?.finishRequest?.terminalErrorCode
    }

    @discardableResult
    private func persistTerminalErrorForCurrentFinish(
        _ terminalErrorCode: WorkoutSafeErrorCodeV1,
        endDate: Date
    ) -> Bool {
        let resolvedTerminalErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: terminalErrorCode,
            persistedFinishError: pendingTerminalErrorPersistence?.code
                ?? durableTerminalErrorCode
        ) ?? terminalErrorCode
        do {
            try recoveryStore.markTerminalError(resolvedTerminalErrorCode)
            identity = recoveryStore.recoveredIdentity ?? identity
            pendingTerminalErrorPersistence = nil
            if finishRequestError == .terminalErrorPersistenceFailed {
                finishRequestError = nil
            }
            if let confirmedCompletion = pendingTerminalCauseConfirmedCompletion {
                pendingTerminalCauseConfirmedCompletion = nil
                switch confirmedCompletion {
                case .saved(let summary, let savedAt):
                    completeConfirmedSave(summary: summary, savedAt: savedAt)
                case .discarded(let summary, let discardedAt):
                    completeConfirmedDiscard(
                        summary: summary,
                        discardedAt: discardedAt
                    )
                }
            }
            return true
        } catch {
            pendingTerminalErrorPersistence = (
                code: resolvedTerminalErrorCode,
                endDate: endDate
            )
            finishRequestError = .terminalErrorPersistenceFailed
            return false
        }
    }

    private func clearMetrics() {
        currentHeartRate = nil
        averageHeartRate = nil
        activeEnergy = nil
        healthKitDistance = nil
        pairedSensorSpeed = nil
        cyclingPower = nil
        cyclingCadence = nil
        terminalRouteDistance = nil
        heartRateZoneDurationAccumulator.reset()
        heartRateZoneCheckpointPersistenceGate.reset()
        heartRateZoneRuntimeSessionID = nil
        heartRateZoneRuntimeMaximumHeartRateBPM = nil
        lastErrorCode = nil
    }

    private func positiveMetric(
        _ value: Double,
        unit: WorkoutMetricUnitV1,
        capturedAt: Date
    ) -> WorkoutMetricV1? {
        guard value.isFinite, value > 0 else { return nil }
        return WorkoutMetricV1(
            value: value,
            unit: unit,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }

    private func nonnegativeMetric(
        _ value: Double,
        unit: WorkoutMetricUnitV1,
        capturedAt: Date
    ) -> WorkoutMetricV1? {
        guard value.isFinite, value >= 0 else { return nil }
        return WorkoutMetricV1(
            value: value,
            unit: unit,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }

    private func authorizationRequestStatus() async throws ->
        HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKAuthorizationRequestStatus, Error>) in
            healthStore.getRequestStatusForAuthorization(
                toShare: Self.typesToShare,
                read: Self.typesToRead
            ) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func recoverActiveWorkoutSession() async -> (
        session: HKWorkoutSession?,
        error: Error?
    ) {
        if let injectedRecoveryOperation {
            return await injectedRecoveryOperation()
        }
        return await withCheckedContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, error in
                continuation.resume(returning: (session, error))
            }
        }
    }

    private func savedWorkout(
        externalUUID: String,
        startDate: Date
    ) async throws -> HKWorkout? {
        if let injectedSavedWorkoutLookup {
            return try await injectedSavedWorkoutLookup(
                externalUUID,
                startDate
            )
        }
        let metadataPredicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            operatorType: .equalTo,
            value: externalUUID
        )
        let activityPredicate = HKQuery.predicateForWorkouts(
            with: .cycling
        )
        let startPredicate = HKQuery.predicateForSamples(
            withStart: startDate.addingTimeInterval(-2),
            end: startDate.addingTimeInterval(2),
            options: .strictStartDate
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            metadataPredicate,
            activityPredicate,
            startPredicate,
        ])

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKWorkout?, Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: samples?.first as? HKWorkout
                )
            }
            healthStore.execute(query)
        }
    }

    private func endCollection(
        _ builder: HKLiveWorkoutBuilder,
        at endDate: Date
    ) async throws {
        if let injectedEndCollectionOperation {
            try await injectedEndCollectionOperation(builder, endDate)
            return
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: endDate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: WorkoutFinalizationError.endCollectionFailed)
                }
            }
        }
    }

    private func finishWorkout(
        _ builder: HKLiveWorkoutBuilder
    ) async throws {
        if let injectedFinishWorkoutOperation {
            try await injectedFinishWorkoutOperation(builder)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                switch WorkoutFinishCallbackPolicy.outcome(
                    workoutReturned: workout != nil,
                    errorReturned: error != nil
                ) {
                case .saved:
                    continuation.resume(returning: ())
                case .failed:
                    guard let error else {
                        continuation.resume(
                            throwing: WorkoutFinalizationError.finishWorkoutFailed
                        )
                        return
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static var requiredTypesToShare: Set<HKSampleType> {
        [HKObjectType.workoutType()]
    }

    private static var optionalTypesToShare: Set<HKSampleType> {
        [HKSeriesType.workoutRoute()]
    }

    private static var typesToShare: Set<HKSampleType> {
        requiredTypesToShare.union(optionalTypesToShare)
    }

    private static var typesToRead: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .activeEnergyBurned,
        .distanceCycling,
        .cyclingSpeed,
        .cyclingPower,
        .cyclingCadence,
    ]

    private static func safeErrorCode(for error: Error?) -> WorkoutSafeErrorCodeV1 {
        guard let error = error as? HKError else { return .sessionFailed }
        switch error.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            return .authorizationDenied
        case .errorAnotherWorkoutSessionStarted:
            return .anotherWorkoutActive
        default:
            return .sessionFailed
        }
    }

    private static func isAuthorizationError(_ error: Error) -> Bool {
        guard let error = error as? HKError else { return false }
        return [
            .errorAuthorizationDenied,
            .errorAuthorizationNotDetermined,
            .errorRequiredAuthorizationDenied,
        ].contains(error.code)
    }

    static func resolveSetupState(
        requiredShareStatuses: [HKAuthorizationStatus],
        requestStatus: HKAuthorizationRequestStatus? = nil
    ) -> WatchWorkoutSetupState? {
        guard !requiredShareStatuses.isEmpty else { return nil }
        if requiredShareStatuses.contains(.sharingDenied) {
            return .denied
        }
        if requiredShareStatuses.contains(.notDetermined) {
            return .needsAuthorization
        }
        if let requestStatus,
           requestStatus != .unnecessary {
            return .needsAuthorization
        }
        if requiredShareStatuses.allSatisfy({
            $0 == .sharingAuthorized
        }) {
            return .ready
        }
        return nil
    }

    static func workoutIdentityMetadata(sessionID: UUID) -> [String: Any] {
        let identifier = sessionID.uuidString
        return [
            HKMetadataKeyExternalUUID: identifier,
            HKMetadataKeySyncIdentifier: "LetItRide.BikeComputer.workout.\(identifier)",
            HKMetadataKeySyncVersion: 1,
        ]
    }

    static func hasWorkoutIdentityMetadata(
        _ metadata: [String: Any],
        sessionID: UUID
    ) -> Bool {
        let identifier = sessionID.uuidString
        let syncVersion = (metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue
        return metadata[HKMetadataKeyExternalUUID] as? String == identifier
            && metadata[HKMetadataKeySyncIdentifier] as? String
                == "LetItRide.BikeComputer.workout.\(identifier)"
            && syncVersion == 1
    }

    static func workoutIdentitySessionID(
        from metadata: [String: Any]
    ) -> UUID? {
        guard let externalIdentifier = metadata[HKMetadataKeyExternalUUID] as? String,
              let sessionID = UUID(uuidString: externalIdentifier),
              hasWorkoutIdentityMetadata(metadata, sessionID: sessionID) else {
            return nil
        }
        return sessionID
    }

    static func containsWorkoutIdentityMetadata(
        _ metadata: [String: Any]
    ) -> Bool {
        metadata.keys.contains(HKMetadataKeyExternalUUID)
            || metadata.keys.contains(HKMetadataKeySyncIdentifier)
            || metadata.keys.contains(HKMetadataKeySyncVersion)
    }

    static func canRetryFinalization(
        sessionState: HKWorkoutSessionState
    ) -> Bool {
        [.stopped, .ended].contains(sessionState)
    }

    static func canAdoptRecoveredIdentity(
        sessionState: HKWorkoutSessionState
    ) -> Bool {
        [.running, .paused].contains(sessionState)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === session else { return }
            if let terminalCleanupSessionID,
               let terminalCleanupDisposition,
               let terminalBuilder = builder {
                handleTerminalTombstoneSessionState(
                    toState,
                    transitionDate: date,
                    disposition: terminalCleanupDisposition,
                    adapter: WatchTerminalSessionCleanupAdapter(
                        stopSession: { transitionDate in
                            workoutSession.stopActivity(with: transitionDate)
                        },
                        completeSession: { [weak self] disposition in
                            self?.completeTerminalTombstoneSessionCleanup(
                                workoutSession,
                                builder: terminalBuilder,
                                sessionID: terminalCleanupSessionID,
                                disposition: disposition
                            )
                        }
                    )
                )
                return
            }
            switch toState {
            case .running:
                switch WorkoutRunningCallbackPolicy.action(for: lifecycle.state) {
                case .enterRunning:
                    let resumedFromPause = fromState == .paused
                    let automaticContext = resumedFromPause
                        ? pendingRemoteStateAcknowledgement?.context
                        : nil
                    _ = lifecycle.apply(.sessionRunning)
                    routeRecorder.setPaused(false, at: date)
                    startPeriodicSnapshots()
                    let didConfirmTransition: Bool
                    if fromState == .paused {
                        didConfirmTransition = await confirmRideTransition(
                            paused: false,
                            at: date,
                            remoteContext: automaticContext
                        )
                    } else {
                        if let context = activeLaunchAutomaticStartContext {
                            didConfirmTransition =
                                await confirmLaunchAutomaticStart(
                                    context: context,
                                    at: date
                                )
                        } else if localStartOriginPending {
                            await confirmManualStart(at: date)
                            didConfirmTransition = true
                        } else {
                            scheduleSuppliedConfigurationManualStart(at: date)
                            didConfirmTransition = true
                        }
                    }
                    publishSnapshotImmediately()
                    if didConfirmTransition {
                        publishPendingRemoteStateAcknowledgementIfConfirmed()
                    }
                case .stopSession:
                    stopSessionForFinalization(
                        workoutSession,
                        at: authoritativeFinalizationEndDate ?? date
                    )
                case .ignore:
                    break
                }
            case .paused:
                if lifecycle.state == .ending {
                    stopSessionForFinalization(
                        workoutSession,
                        at: authoritativeFinalizationEndDate ?? date
                    )
                    return
                }
                let automaticContext =
                    pendingRemoteStateAcknowledgement?.context
                _ = lifecycle.apply(.sessionPaused)
                routeRecorder.setPaused(true, at: date)
                let didConfirmTransition = await confirmRideTransition(
                    paused: true,
                    at: date,
                    remoteContext: automaticContext
                )
                publishSnapshotImmediately()
                if didConfirmTransition {
                    publishPendingRemoteStateAcknowledgementIfConfirmed()
                }
            case .stopped, .ended:
                handleSessionReadyForFinalization(
                    at: workoutSession.endDate ?? date
                )
            case .notStarted, .prepared:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === session else { return }
            if let terminalCleanupSessionID,
               let terminalCleanupDisposition,
               let terminalBuilder = builder {
                completeTerminalTombstoneSessionCleanup(
                    workoutSession,
                    builder: terminalBuilder,
                    sessionID: terminalCleanupSessionID,
                    disposition: terminalCleanupDisposition
                )
                return
            }
            let safeErrorCode = Self.safeErrorCode(for: error)
            handleSessionFailure(
                workoutSession,
                error: error,
                safeErrorCode: safeErrorCode,
                failureEndDate: authoritativeFinalizationEndDate
                    ?? workoutSession.endDate
                    ?? Date()
            )
        }
    }

    func handleSessionFailure(
        _ workoutSession: HKWorkoutSession,
        error: Error? = nil,
        safeErrorCode: WorkoutSafeErrorCodeV1,
        failureEndDate: Date
    ) {
        guard workoutSession === session else { return }
        let resolvedErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: safeErrorCode,
            persistedFinishError: pendingTerminalErrorPersistence?.code
                ?? pendingTerminalErrorCodeForNextFinish
                ?? durableTerminalErrorCode
        ) ?? safeErrorCode
        lastErrorCode = resolvedErrorCode
        switch WorkoutSessionFailurePolicy.action(for: lifecycle.state) {
        case .failStart:
            handleStartFailure(error)
        case .savePartialWorkout:
            requestEnd(
                .save,
                requestedAt: failureEndDate,
                terminalErrorCode: resolvedErrorCode
            )
        case .finishRequestedDisposition:
            guard persistTerminalErrorForCurrentFinish(
                resolvedErrorCode,
                endDate: failureEndDate
            ) else {
                publishSnapshotImmediately()
                return
            }
            guard lifecycle.state == .ending else { return }
            publishSnapshotImmediately()
            stopSessionForFinalization(
                workoutSession,
                at: failureEndDate
            )
        case .ignore:
            break
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        let envelopes = data.compactMap { payload in
            try? WorkoutContractCodec.decode(payload)
        }
        guard !envelopes.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.handleRemoteWorkoutEnvelopes(
                envelopes,
                from: workoutSession
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleMirrorDisconnect(from: workoutSession)
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutBuilder === builder else { return }
            updateMetrics(
                from: workoutBuilder,
                collectedTypes: collectedTypes,
                capturedAt: Date()
            )
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutBuilder === builder else { return }
            if let request = workoutBuilder.workoutEvents
                .filter({ $0.type == .pauseOrResumeRequest })
                .max(by: {
                    $0.dateInterval.start < $1.dateInterval.start
                }),
               request.dateInterval.start
                    > lastProcessedManualTransitionRequestAt {
                lastProcessedManualTransitionRequestAt =
                    request.dateInterval.start
                await noteManualPauseOrResumeRequest(
                    at: request.dateInterval.start
                )
            }
            scheduleCoalescedSnapshot()
        }
    }
}

private enum WorkoutFinalizationError: Error {
    case endCollectionFailed
    case finishWorkoutFailed
    case managerReleased
}

private enum WorkoutSegmentWriteError: Error {
    case builderUnavailable
    case writeFailed
    case finalizationPending
}
