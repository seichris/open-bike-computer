import Foundation

/// An exact, verified archive read. This value is never written as a second
/// persistent route and its geometry remains canonical WGS-84.
struct SavedRouteMapSelection {
    let identity: WatchRouteIdentityV1
    let displayName: String
    let route: NavigationRouteV1
    let createdAt: Date
    let deleteAfter: Date?
}

nonisolated enum SavedRouteMapError: LocalizedError {
    case unavailable(String)
    case expired(String)
    case invalidGeometry(String)
    case navigationActive
    case planningActive

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            return String(format: NSLocalizedString(
                "“%@” is no longer available in this version or could not be verified. Select the current route, or import it again.",
                comment: "Saved route map preview load failure"
            ), name)
        case .expired(let name):
            return String(format: NSLocalizedString(
                "“%@” has expired. Reload it from Strava before showing it on the map.",
                comment: "Saved Strava route map preview expired"
            ), name)
        case .invalidGeometry(let name):
            return String(format: NSLocalizedString(
                "“%@” does not contain valid map geometry. Import the route again.",
                comment: "Saved route map preview invalid coordinates"
            ), name)
        case .navigationActive:
            return NSLocalizedString(
                "Stop navigation before showing a saved route on the map.",
                comment: "Saved route preview cannot replace active navigation"
            )
        case .planningActive:
            return NSLocalizedString(
                "Finish or cancel the current route or map-area selection before showing a saved route.",
                comment: "Saved route preview must not replace an existing map interaction"
            )
        }
    }
}
