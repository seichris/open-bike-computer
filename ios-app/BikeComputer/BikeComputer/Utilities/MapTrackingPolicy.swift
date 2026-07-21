import Foundation

enum MapTrackingBehavior: Equatable {
    case none
    case follow
    case followWithHeading
}

enum MapTrackingPolicy {
    static func desiredMode(
        isNavigating: Bool,
        isOfflineMapSelectionActive: Bool,
        isDestinationSelectionActive: Bool
    ) -> MapTrackingBehavior {
        guard !isOfflineMapSelectionActive,
              !isDestinationSelectionActive else { return .none }
        return isNavigating ? .followWithHeading : .follow
    }
}
