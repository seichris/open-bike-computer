import Combine
import Foundation
import WatchConnectivity

protocol WorkoutWatchConnectivitySession: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    var receivedApplicationContext: [String: Any] { get }

    func activate()
    func updateApplicationContext(
        _ applicationContext: [String: Any]
    ) throws
}

extension WCSession: WorkoutWatchConnectivitySession {}

struct WorkoutWatchConnectivityStateV1: Equatable {
    var isSupported = false
    var isActivated = false
    var activationFailed = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
    var healthSetupSnapshot: WorkoutHealthSetupSnapshotV1?
}

@MainActor
protocol WorkoutWatchConnectivityCoordinating: AnyObject {
    var workoutState: WorkoutWatchConnectivityStateV1 { get }
    var workoutStatePublisher:
        AnyPublisher<WorkoutWatchConnectivityStateV1, Never> { get }

    func activate()
    func updateApplicationContextMerging(
        _ fields: [String: Any],
        removingKeys: Set<String>
    ) throws
}

/// Publishes Apple Watch pairing and companion-app installation state for the
/// iPhone workout start surfaces. Reachability is intentionally informational:
/// HealthKit can wake an installed Watch app even when WatchConnectivity cannot
/// exchange an immediate foreground message.
@MainActor
final class WorkoutWatchAvailabilityMonitor: NSObject, ObservableObject {
    @Published private(set) var availability: WorkoutWatchAvailabilityV1
    @Published private(set) var healthSetupSnapshot:
        WorkoutHealthSetupSnapshotV1?
    @Published private(set) var maximumHeartRateBPM: Int

    private let session: WorkoutWatchConnectivitySession?
    private let connectivityCoordinator: WorkoutWatchConnectivityCoordinating?
    private let heartRateZoneDefaults: UserDefaults
    private let rideDetectionSettingsStore: RideDetectionSettingsStore?
    private let syncRetryScheduler: (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> Void
    private var activationFailed = false
    private var maximumHeartRateSyncPending = true
    private var rideDetectionSyncPending = true
    private var automaticStartSyncPending = false
    private var pendingAutomaticStartContext: WorkoutControlContextV1?
    private var confirmedRideDetectionSettings: RideDetectionSettings?
    private var confirmedRideDetectionGeneration: UInt32?
    private var syncRetryAttempt = 0
    private var nextSyncRetryID: UInt64 = 0
    private var scheduledSyncRetryID: UInt64?
    private var cancellables: Set<AnyCancellable> = []

    override convenience init() {
        self.init(
            heartRateZoneDefaults: .standard,
            rideDetectionSettingsStore: nil
        )
    }

    convenience init(
        heartRateZoneDefaults: UserDefaults,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil
    ) {
        let session: WorkoutWatchConnectivitySession?
        if #available(iOS 17.0, *) {
            session = WCSession.isSupported() ? WCSession.default : nil
        } else {
            session = nil
        }

        self.init(
            heartRateZoneDefaults: heartRateZoneDefaults,
            rideDetectionSettingsStore: rideDetectionSettingsStore,
            session: session,
            syncRetryScheduler: { delay, action in
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    action()
                }
            }
        )
    }

    convenience init(
        heartRateZoneDefaults: UserDefaults = .standard,
        connectivityCoordinator: WorkoutWatchConnectivityCoordinating,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil
    ) {
        self.init(
            heartRateZoneDefaults: heartRateZoneDefaults,
            rideDetectionSettingsStore: rideDetectionSettingsStore,
            session: nil,
            connectivityCoordinator: connectivityCoordinator,
            syncRetryScheduler: { delay, action in
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    action()
                }
            }
        )
    }

    init(
        heartRateZoneDefaults: UserDefaults,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil,
        session: WorkoutWatchConnectivitySession?,
        connectivityCoordinator: WorkoutWatchConnectivityCoordinating? = nil,
        syncRetryScheduler: @escaping (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void
    ) {
        self.session = session
        self.connectivityCoordinator = connectivityCoordinator
        self.heartRateZoneDefaults = heartRateZoneDefaults
        self.rideDetectionSettingsStore = rideDetectionSettingsStore
        self.syncRetryScheduler = syncRetryScheduler
        maximumHeartRateBPM = WorkoutHeartRateZoneSettings
            .maximumHeartRateBPM(from: heartRateZoneDefaults)
        healthSetupSnapshot = connectivityCoordinator?.workoutState
            .healthSetupSnapshot
        availability = WorkoutWatchAvailabilityPolicyV1.resolve(
            isSupported: session != nil,
            isActivated: false,
            isPaired: false,
            isCompanionAppInstalled: false,
            isReachable: false
        )
        super.init()
        rideDetectionSettingsStore?.$generation
            .dropFirst()
            .sink { [weak self] _ in
                self?.confirmedRideDetectionSettings = nil
                self?.confirmedRideDetectionGeneration = nil
                self?.rideDetectionSyncPending = true
                self?.syncApplicationContextToWatch()
            }
            .store(in: &cancellables)
        connectivityCoordinator?.workoutStatePublisher
            .sink { [weak self] state in
                self?.refreshSessionState(coordinatorState: state)
            }
            .store(in: &cancellables)
    }

    func setMaximumHeartRateBPM(_ value: Int) {
        let clamped = WorkoutHeartRateZoneProfile
            .clampedMaximumHeartRateBPM(value)
        if clamped != maximumHeartRateBPM {
            maximumHeartRateBPM = clamped
            WorkoutHeartRateZoneSettings.saveMaximumHeartRateBPM(
                clamped,
                to: heartRateZoneDefaults
            )
        }
        maximumHeartRateSyncPending = true
        rideDetectionSyncPending = true
        syncRetryAttempt = 0
        syncApplicationContextToWatch()
    }

    func activate() {
        if let connectivityCoordinator {
            maximumHeartRateSyncPending = true
            connectivityCoordinator.activate()
            publishAvailability()
            syncApplicationContextToWatch()
            return
        }
        guard let session else {
            publishAvailability()
            return
        }
        activationFailed = false
        session.delegate = self
        session.activate()
        maximumHeartRateSyncPending = true
        rideDetectionSyncPending = true
        publishAvailability()
        syncApplicationContextToWatch()
    }

    @discardableResult
    func setPendingAutomaticStartContext(
        _ context: WorkoutControlContextV1?
    ) -> Bool {
        pendingAutomaticStartContext = context
        automaticStartSyncPending = true
        return syncApplicationContextToWatch()
    }

    func setConfirmedRideDetectionSettings(
        _ settings: RideDetectionSettings?,
        generation: UInt32?
    ) {
        confirmedRideDetectionSettings = settings
        confirmedRideDetectionGeneration = generation
        rideDetectionSyncPending = true
        syncApplicationContextToWatch()
    }

    private func publishAvailability(
        coordinatorState: WorkoutWatchConnectivityStateV1? = nil
    ) {
        let availability: WorkoutWatchAvailabilityV1
        let healthSetupSnapshot: WorkoutHealthSetupSnapshotV1?
        if let connectivityCoordinator {
            let state = coordinatorState
                ?? connectivityCoordinator.workoutState
            availability = WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: state.isSupported,
                isActivated: state.isActivated,
                activationFailed: state.activationFailed,
                isPaired: state.isPaired,
                isCompanionAppInstalled: state.isWatchAppInstalled,
                isReachable: state.isReachable
            )
            healthSetupSnapshot = state.isWatchAppInstalled
                ? state.healthSetupSnapshot
                : nil
        } else if let session {
            let isActivated = session.activationState == .activated
            let isWatchAppInstalled = isActivated
                && session.isWatchAppInstalled
            availability = WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: isActivated,
                activationFailed: activationFailed,
                isPaired: isActivated ? session.isPaired : false,
                isCompanionAppInstalled: isWatchAppInstalled,
                isReachable: isActivated ? session.isReachable : false
            )
            healthSetupSnapshot = isWatchAppInstalled
                ? Self.healthSetupSnapshot(
                    from: session.receivedApplicationContext
                )
                : nil
        } else {
            availability = .unsupported
            healthSetupSnapshot = nil
        }

        self.healthSetupSnapshot = healthSetupSnapshot
        self.availability = availability
    }

    private static func healthSetupSnapshot(
        from applicationContext: [String: Any]
    ) -> WorkoutHealthSetupSnapshotV1? {
        guard let data = applicationContext[
            WorkoutHealthSetupSnapshotV1.applicationContextKey
        ] as? Data else {
            return nil
        }
        return try? WorkoutHealthSetupSnapshotV1.decode(data)
    }

    @discardableResult
    private func syncApplicationContextToWatch(
        coordinatorState: WorkoutWatchConnectivityStateV1? = nil
    ) -> Bool {
        guard maximumHeartRateSyncPending || rideDetectionSyncPending
                || automaticStartSyncPending,
              let context = pendingApplicationContext() else {
            return false
        }
        if let connectivityCoordinator {
            let state = coordinatorState
                ?? connectivityCoordinator.workoutState
            guard state.isActivated,
                  state.isPaired,
                  state.isWatchAppInstalled else {
                return false
            }
            do {
                try connectivityCoordinator.updateApplicationContextMerging(
                    context,
                    removingKeys: pendingApplicationContextRemovalKeys()
                )
                maximumHeartRateSyncPending = false
                rideDetectionSyncPending = false
                automaticStartSyncPending = false
                syncRetryAttempt = 0
                scheduledSyncRetryID = nil
                return true
            } catch {
                scheduleMaximumHeartRateSyncRetry()
                return false
            }
        }
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return false
        }
        do {
            try session.updateApplicationContext(context)
            maximumHeartRateSyncPending = false
            rideDetectionSyncPending = false
            automaticStartSyncPending = false
            syncRetryAttempt = 0
            scheduledSyncRetryID = nil
            return true
        } catch {
            scheduleMaximumHeartRateSyncRetry()
            return false
        }
    }

    private func pendingApplicationContext() -> [String: Any]? {
        guard maximumHeartRateSyncPending || rideDetectionSyncPending
                || automaticStartSyncPending else {
            return nil
        }
        var context = WorkoutHeartRateZoneSyncContext.applicationContext(
            maximumHeartRateBPM: maximumHeartRateBPM
        )
        if let confirmedRideDetectionSettings,
           let confirmedRideDetectionGeneration {
            context = RideDetectionSyncContext.adding(
                settings: confirmedRideDetectionSettings,
                generation: confirmedRideDetectionGeneration,
                to: context
            )
        }
        return RideDetectionSyncContext.addingPendingAutomaticStart(
            pendingAutomaticStartContext,
            to: context
        )
    }

    private func pendingApplicationContextRemovalKeys() -> Set<String> {
        var keys = Set<String>()
        if confirmedRideDetectionSettings == nil
            || confirmedRideDetectionGeneration == nil {
            keys.formUnion([
                RideDetectionSyncContext.schemaVersionKey,
                RideDetectionSyncContext.generationKey,
                RideDetectionSyncContext.startModeKey,
                RideDetectionSyncContext.autoPauseEnabledKey,
                RideDetectionSyncContext.alertModeKey,
            ])
        }
        if pendingAutomaticStartContext == nil {
            keys.formUnion([
                RideDetectionSyncContext.automaticStartRideGenerationKey,
                RideDetectionSyncContext.automaticStartDecisionSequenceKey,
                RideDetectionSyncContext.automaticStartProfileVersionKey,
            ])
        }
        return keys
    }

    private func scheduleMaximumHeartRateSyncRetry() {
        guard scheduledSyncRetryID == nil else { return }
        let delay = min(pow(2, Double(syncRetryAttempt)), 30)
        syncRetryAttempt += 1
        nextSyncRetryID &+= 1
        let retryID = nextSyncRetryID
        scheduledSyncRetryID = retryID
        syncRetryScheduler(delay) { [weak self] in
            guard let self,
                  self.scheduledSyncRetryID == retryID else {
                return
            }
            self.scheduledSyncRetryID = nil
            self.syncApplicationContextToWatch()
        }
    }

    private func refreshSessionState(
        activationFailed: Bool? = nil,
        coordinatorState: WorkoutWatchConnectivityStateV1? = nil
    ) {
        if let activationFailed {
            self.activationFailed = activationFailed
        }
        maximumHeartRateSyncPending = true
        rideDetectionSyncPending = true
        publishAvailability(coordinatorState: coordinatorState)
        syncApplicationContextToWatch(coordinatorState: coordinatorState)
    }
}

extension WorkoutWatchAvailabilityMonitor: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.refreshSessionState(
                activationFailed: error != nil
                    || activationState != .activated
            )
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshSessionState()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor [weak self] in
            self?.refreshSessionState(activationFailed: false)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshSessionState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshSessionState()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.refreshSessionState()
        }
    }
}

@MainActor
extension WorkoutWatchAvailabilityMonitor:
    RideAutomationWatchAvailabilityControlling {}
