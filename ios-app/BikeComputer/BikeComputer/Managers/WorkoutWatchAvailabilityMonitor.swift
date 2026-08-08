import Combine
import Foundation
import WatchConnectivity

protocol WorkoutWatchConnectivitySession: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }

    func activate()
    func updateApplicationContext(
        _ applicationContext: [String: Any]
    ) throws
}

extension WCSession: WorkoutWatchConnectivitySession {}

/// Publishes Apple Watch pairing and companion-app installation state for the
/// iPhone workout start surfaces. Reachability is intentionally informational:
/// HealthKit can wake an installed Watch app even when WatchConnectivity cannot
/// exchange an immediate foreground message.
@MainActor
final class WorkoutWatchAvailabilityMonitor: NSObject, ObservableObject {
    @Published private(set) var availability: WorkoutWatchAvailabilityV1
    @Published private(set) var maximumHeartRateBPM: Int

    private let session: WorkoutWatchConnectivitySession?
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

    init(
        heartRateZoneDefaults: UserDefaults,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil,
        session: WorkoutWatchConnectivitySession?,
        syncRetryScheduler: @escaping (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void
    ) {
        self.session = session
        self.heartRateZoneDefaults = heartRateZoneDefaults
        self.rideDetectionSettingsStore = rideDetectionSettingsStore
        self.syncRetryScheduler = syncRetryScheduler
        maximumHeartRateBPM = WorkoutHeartRateZoneSettings
            .maximumHeartRateBPM(from: heartRateZoneDefaults)
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

    private func publishAvailability() {
        let availability: WorkoutWatchAvailabilityV1
        if let session {
            let isActivated = session.activationState == .activated
            availability = WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: isActivated,
                activationFailed: activationFailed,
                isPaired: isActivated ? session.isPaired : false,
                isCompanionAppInstalled: isActivated
                    ? session.isWatchAppInstalled
                    : false,
                isReachable: isActivated ? session.isReachable : false
            )
        } else {
            availability = .unsupported
        }

        self.availability = availability
    }

    @discardableResult
    private func syncApplicationContextToWatch() -> Bool {
        guard maximumHeartRateSyncPending || rideDetectionSyncPending
                || automaticStartSyncPending,
              let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return false
        }

        do {
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
            context = RideDetectionSyncContext.addingPendingAutomaticStart(
                pendingAutomaticStartContext,
                to: context
            )
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
        activationFailed: Bool? = nil
    ) {
        if let activationFailed {
            self.activationFailed = activationFailed
        }
        maximumHeartRateSyncPending = true
        rideDetectionSyncPending = true
        publishAvailability()
        syncApplicationContextToWatch()
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
}
