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
    private let syncRetryScheduler: (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> Void
    private var activationFailed = false
    private var maximumHeartRateSyncPending = true
    private var syncRetryAttempt = 0
    private var nextSyncRetryID: UInt64 = 0
    private var scheduledSyncRetryID: UInt64?

    override convenience init() {
        self.init(heartRateZoneDefaults: .standard)
    }

    convenience init(heartRateZoneDefaults: UserDefaults) {
        let session: WorkoutWatchConnectivitySession?
        if #available(iOS 17.0, *) {
            session = WCSession.isSupported() ? WCSession.default : nil
        } else {
            session = nil
        }

        self.init(
            heartRateZoneDefaults: heartRateZoneDefaults,
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
        session: WorkoutWatchConnectivitySession?,
        syncRetryScheduler: @escaping (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void
    ) {
        self.session = session
        self.heartRateZoneDefaults = heartRateZoneDefaults
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
        syncRetryAttempt = 0
        syncMaximumHeartRateToWatch()
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
        publishAvailability()
        syncMaximumHeartRateToWatch()
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

    private func syncMaximumHeartRateToWatch() {
        guard maximumHeartRateSyncPending,
              let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return
        }

        do {
            try session.updateApplicationContext(
                WorkoutHeartRateZoneSyncContext.applicationContext(
                    maximumHeartRateBPM: maximumHeartRateBPM
                )
            )
            maximumHeartRateSyncPending = false
            syncRetryAttempt = 0
            scheduledSyncRetryID = nil
        } catch {
            scheduleMaximumHeartRateSyncRetry()
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
            self.syncMaximumHeartRateToWatch()
        }
    }

    private func refreshSessionState(
        activationFailed: Bool? = nil
    ) {
        if let activationFailed {
            self.activationFailed = activationFailed
        }
        maximumHeartRateSyncPending = true
        publishAvailability()
        syncMaximumHeartRateToWatch()
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
