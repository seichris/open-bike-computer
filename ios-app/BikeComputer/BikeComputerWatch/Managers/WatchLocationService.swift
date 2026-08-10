import Combine
import CoreLocation
import Foundation

/// The sole Core Location owner in the Watch process. Workout recording and
/// navigation hold independent demands, so ending either lifecycle cannot
/// accidentally stop location delivery for the other.
@MainActor
final class WatchLocationService: NSObject, ObservableObject {
    enum Consumer: Hashable {
        case workout
        case navigation
    }

    typealias Handler = @MainActor ([CLLocation]) -> Void

    @Published private(set) var authorizationState:
        WatchRouteRecorder.AuthorizationState
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var lastErrorCode: CLError.Code?

    private let manager: CLLocationManager
    private var handlers: [Consumer: Handler] = [:]
    private var backgroundActivitySession: CLBackgroundActivitySession?

    override convenience init() {
        self.init(manager: CLLocationManager())
    }

    init(manager: CLLocationManager) {
        self.manager = manager
        authorizationState = WatchRouteRecorder.mapAuthorization(
            manager.authorizationStatus
        )
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
    }

    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else {
            authorizationState = WatchRouteRecorder.mapAuthorization(
                manager.authorizationStatus
            )
            reconcileUpdates()
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    func setConsumer(
        _ consumer: Consumer,
        active: Bool,
        handler: Handler? = nil
    ) {
        if active {
            guard let handler else { return }
            handlers[consumer] = handler
        } else {
            handlers.removeValue(forKey: consumer)
        }
        reconcileUpdates()
    }

    func removeAllConsumers() {
        handlers.removeAll()
        reconcileUpdates()
    }

    private func reconcileUpdates() {
        let hasDemand = !handlers.isEmpty
        if handlers[.navigation] != nil {
            if #available(watchOS 10.0, *),
               backgroundActivitySession == nil,
               authorizationState == .authorized {
                backgroundActivitySession = CLBackgroundActivitySession()
            }
        } else {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }
        guard hasDemand, authorizationState == .authorized else {
            manager.stopUpdatingLocation()
            if !hasDemand {
                latestLocation = nil
                lastErrorCode = nil
            }
            return
        }
        manager.startUpdatingLocation()
    }

    private func receive(_ locations: [CLLocation]) {
        guard !handlers.isEmpty, !locations.isEmpty else { return }
        latestLocation = locations.last
        lastErrorCode = nil
        let currentHandlers = Array(handlers.values)
        for handler in currentHandlers {
            handler(locations)
        }
    }
}

extension WatchLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationState = WatchRouteRecorder.mapAuthorization(status)
            reconcileUpdates()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            self?.receive(locations)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        let code = (error as? CLError)?.code
        Task { @MainActor [weak self] in
            self?.latestLocation = nil
            self?.lastErrorCode = code
            guard let self else { return }
            let currentHandlers = Array(handlers.values)
            for handler in currentHandlers {
                handler([])
            }
        }
    }
}

#if !WORKOUT_CONTRACT_XCTEST
extension WatchLocationService: WatchNavigationLocationProviding {
    func setNavigationConsumer(
        active: Bool,
        handler: (@MainActor ([CLLocation]) -> Void)?
    ) {
        setConsumer(.navigation, active: active, handler: handler)
    }
}
#endif
