import Combine
import Foundation
import Network

enum WatchNetworkAvailabilityV1: Equatable {
    case unknown
    case available
    case unavailable
}

@MainActor
final class WatchNetworkPathMonitor: ObservableObject {
    @Published private(set) var availability: WatchNetworkAvailabilityV1 =
        .unknown

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "com.bicino.watch-navigation-network"
    )
    private var isStarted = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let availability: WatchNetworkAvailabilityV1 =
                path.status == .satisfied ? .available : .unavailable
            Task { @MainActor [weak self] in
                self?.availability = availability
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

extension WatchNetworkPathMonitor: WatchNetworkAvailabilityProviding {
    var availabilityPublisher:
        AnyPublisher<WatchNetworkAvailabilityV1, Never> {
        $availability.eraseToAnyPublisher()
    }
}
