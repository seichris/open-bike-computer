import Combine
import Foundation

@MainActor
final class WatchNavigationSettingsStore: ObservableObject {
    @Published private(set) var useWatchCellularConnection: Bool
    @Published private(set) var policy: RouteNetworkPolicyV1
    @Published private(set) var policyGeneration: UInt64

    private static let policyKey =
        "watchNavigation.useWatchCellularConnection.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Missing includes every upgrade from a build predating this setting.
        // The migration is deliberately offline and never inspects hardware.
        let enabled = defaults.object(forKey: Self.policyKey) as? Bool ?? false
        useWatchCellularConnection = enabled
        policy = enabled ? .onlineAllowed : .offlineOnly
        policyGeneration = 1
    }

    func setUseWatchCellularConnection(_ enabled: Bool) {
        guard enabled != useWatchCellularConnection else { return }
        useWatchCellularConnection = enabled
        policy = enabled ? .onlineAllowed : .offlineOnly
        policyGeneration &+= 1
        if policyGeneration == 0 { policyGeneration = 1 }
        defaults.set(enabled, forKey: Self.policyKey)
    }
}
