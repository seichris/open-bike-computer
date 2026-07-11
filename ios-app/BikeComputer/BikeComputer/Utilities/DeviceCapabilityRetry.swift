import Foundation

enum DeviceCapabilityRetry {
    static let maxAttempts = 5

    static func shouldRequest(isNavigationReady: Bool,
                              hasReceivedCapabilities: Bool,
                              attempt: Int) -> Bool {
        isNavigationReady && !hasReceivedCapabilities && attempt < maxAttempts
    }

    static func isCurrentSession(_ generation: UInt,
                                 currentGeneration: UInt) -> Bool {
        generation == currentGeneration
    }

    static func scheduleInitial(on queue: DispatchQueue = .main,
                                _ action: @escaping () -> Void) {
        queue.async {
            action()
        }
    }
}

enum PowerButtonHonkRetry {
    static let maxAttempts = 3

    static func shouldRetry(isNavigationReady: Bool, attempt: Int) -> Bool {
        isNavigationReady && attempt + 1 < maxAttempts
    }
}
