import Combine
import Foundation

/// Drives `RouteElevationDeliveryPlannerV1` from BLE session state. It only
/// observes the device link; navigation and the elevation service push the
/// active route, its content and the rider's progress.
@MainActor
final class RouteElevationDeviceSync {
    typealias Planner = RouteElevationDeliveryPlannerV1

    private weak var bleManager: BLEManager?
    private var planner = Planner()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var linked = false
    private let uptime: () -> TimeInterval
    var onStatusChange: ((Planner.Status, Bool) -> Void)?

    init(
        bleManager: BLEManager,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.bleManager = bleManager
        self.uptime = uptime
        bleManager.onRouteElevationAcknowledgement = { [weak self] data in
            guard let acknowledgement = RouteElevationDeviceProtocolV1.decodeAcknowledgement(data) else { return }
            self?.planner.receive(acknowledgement)
            self?.pump()
        }
        Publishers.CombineLatest(bleManager.$isNavigationReady, bleManager.$supportsRouteElevation)
            .map { $0 && $1 }
            .removeDuplicates()
            // @Published emits from willSet; read the committed session next turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] linked in self?.linkChanged(linked) }
            .store(in: &cancellables)
    }

    var status: Planner.Status { planner.status }
    var isLinked: Bool { planner.isConnected }

    func update(route: Planner.RouteKey?, content: Planner.Content?) {
        planner.update(route: route, content: content)
        pump()
    }

    func update(progress: Planner.Progress?) {
        planner.update(progress: progress)
        pump()
    }

    /// Every new session starts empty on the device, so a rising edge always
    /// reconnects the planner with a fresh token.
    private func linkChanged(_ linked: Bool) {
        self.linked = linked
        if planner.isConnected { planner.disconnect() }
        pump()
    }

    private func pump() {
        let manager = bleManager
        // The protected endpoint may be installed a turn after the flags.
        if linked, !planner.isConnected, let length = manager?.routeElevationMaximumWriteLength {
            planner.connect(maximumWriteLength: length)
        } else if planner.isConnected, manager?.routeElevationMaximumWriteLength == nil {
            planner.disconnect()
        }
        planner.tick(now: uptime()) { frames, coalescible in
            manager?.sendRouteElevationFrames(frames, coalescible: coalescible) ?? false
        }
        onStatusChange?(planner.status, planner.isConnected)
        let needsTimer = (planner.isConnected || linked) && (planner.hasRoute || planner.hasWork)
        if needsTimer, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pump() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needsTimer {
            timer?.invalidate()
            timer = nil
        }
    }
}
