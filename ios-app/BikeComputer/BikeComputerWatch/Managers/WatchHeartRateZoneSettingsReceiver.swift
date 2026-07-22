import Foundation
import WatchConnectivity

protocol WatchHeartRateZoneConnectivitySession: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var receivedApplicationContext: [String: Any] { get }

    func activate()
}

extension WCSession: WatchHeartRateZoneConnectivitySession {}

@MainActor
final class WatchHeartRateZoneSettingsReceiver: NSObject {
    private let session: WatchHeartRateZoneConnectivitySession?
    private let applyMaximumHeartRateBPM: @MainActor (Int) -> Void

    convenience init(
        applyMaximumHeartRateBPM: @escaping @MainActor (Int) -> Void
    ) {
        self.init(
            session: WCSession.isSupported() ? WCSession.default : nil,
            applyMaximumHeartRateBPM: applyMaximumHeartRateBPM
        )
    }

    init(
        session: WatchHeartRateZoneConnectivitySession?,
        applyMaximumHeartRateBPM: @escaping @MainActor (Int) -> Void
    ) {
        self.session = session
        self.applyMaximumHeartRateBPM = applyMaximumHeartRateBPM
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func activationDidComplete(
        _ activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil,
              activationState == .activated,
              let session else {
            return
        }
        apply(session.receivedApplicationContext)
    }

    func receiveApplicationContext(_ applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    private func apply(_ applicationContext: [String: Any]) {
        guard let maximumHeartRateBPM = WorkoutHeartRateZoneSyncContext
            .maximumHeartRateBPM(from: applicationContext) else {
            return
        }
        applyMaximumHeartRateBPM(maximumHeartRateBPM)
    }
}

extension WatchHeartRateZoneSettingsReceiver: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.activationDidComplete(activationState, error: error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.receiveApplicationContext(applicationContext)
        }
    }
}
