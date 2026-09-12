import Foundation

/// Presentation precedence only. A saved-route preview never owns navigation.
nonisolated enum SavedRouteMapPolicy {
    enum Content: Equatable {
        case navigation
        case calculatedRoute
        case savedRoute
        case none
    }

    static func content(
        isNavigating: Bool,
        hasCalculatedRoute: Bool,
        hasRouteAlternatives: Bool,
        isCalculating: Bool,
        hasSavedRoute: Bool,
        isOfflineMapSelectionActive: Bool
    ) -> Content {
        if isNavigating { return .navigation }
        if isCalculating || hasCalculatedRoute || hasRouteAlternatives {
            return .calculatedRoute
        }
        if hasSavedRoute && !isOfflineMapSelectionActive { return .savedRoute }
        return .none
    }

    /// Compare the entire immutable identity, never just its route UUID.
    static func shouldRetain<Identity: Equatable>(
        _ identity: Identity,
        installedIdentities: [Identity],
        deleteAfter: Date?,
        now: Date
    ) -> Bool {
        (deleteAfter.map { now < $0 } ?? true) &&
            installedIdentities.contains(identity)
    }
}

/// A camera fit belongs to one presentation, not to an ordinary view update.
/// Clearing the presentation allows the same route to be fitted on reopening.
nonisolated struct SavedRouteMapCameraState<Identity: Equatable> {
    private(set) var displayedIdentity: Identity?

    @discardableResult
    mutating func select(_ identity: Identity?) -> Bool {
        guard displayedIdentity != identity else { return false }
        displayedIdentity = identity
        return identity != nil
    }
}
