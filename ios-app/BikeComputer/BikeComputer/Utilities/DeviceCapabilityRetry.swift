import Foundation

enum DeviceCapabilityRetry {
    static let maxAttempts = 5

    static func shouldRequest(isNavigationReady: Bool,
                              hasReceivedCapabilities: Bool,
                              attempt: Int) -> Bool {
        isNavigationReady && !hasReceivedCapabilities && attempt < maxAttempts
    }

    static func scheduleInitial(on queue: DispatchQueue = .main,
                                _ action: @escaping () -> Void) {
        queue.async {
            action()
        }
    }
}
