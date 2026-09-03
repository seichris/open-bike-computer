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

    static func shouldApplyDesiredMode(
        currentMode: MapTrackingBehavior,
        desiredMode: MapTrackingBehavior,
        preservesStoppedTracking: Bool
    ) -> Bool {
        guard currentMode != desiredMode else { return false }

        if preservesStoppedTracking,
           currentMode == .none,
           desiredMode != .none {
            return false
        }

        return true
    }
}

enum RideSheetLayoutPolicy {
    static let standardBottomPadding: CGFloat = 12
    static let standardCompactHeight: CGFloat = 280
    static let accessibilityCompactHeight: CGFloat = 360
    static let maximumCompactHeightFraction: CGFloat = 0.72

    static func compactHeight(
        isAccessibilitySize: Bool,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let preferredHeight = isAccessibilitySize
            ? accessibilityCompactHeight
            : standardCompactHeight
        return min(
            preferredHeight,
            max(maximumHeight, 0) * maximumCompactHeightFraction
        )
    }

    static func mapControlsBottomPadding(
        isRideSheetPresented: Bool,
        isCompactDetent: Bool,
        isAccessibilitySize: Bool,
        maximumHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> CGFloat {
        guard isRideSheetPresented, isCompactDetent else {
            return standardBottomPadding
        }

        return compactHeight(
            isAccessibilitySize: isAccessibilitySize,
            maximumHeight: maximumHeight
        ) + max(safeAreaBottom, 0) + standardBottomPadding
    }
}
