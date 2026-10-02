import Foundation

@main
struct SavedRouteMapPolicyTests {
    struct Identity: Equatable {
        let routeID: UUID
        let revision: UInt32
        let contentHash: String
    }

    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        for mask in 0..<64 {
            let navigating = mask & 1 != 0
            let calculated = mask & 2 != 0
            let alternatives = mask & 4 != 0
            let calculating = mask & 8 != 0
            let saved = mask & 16 != 0
            let offlineSelection = mask & 32 != 0
            let actual = SavedRouteMapPolicy.content(
                isNavigating: navigating,
                hasCalculatedRoute: calculated,
                hasRouteAlternatives: alternatives,
                isCalculating: calculating,
                hasSavedRoute: saved,
                isOfflineMapSelectionActive: offlineSelection
            )
            let expected: SavedRouteMapPolicy.Content
            if navigating { expected = .navigation }
            else if calculated || alternatives || calculating {
                expected = .calculatedRoute
            } else if saved && !offlineSelection { expected = .savedRoute }
            else { expected = .none }
            check(actual == expected, "Precedence combination \(mask)")
        }

        let routeID = UUID()
        let first = Identity(routeID: routeID, revision: 1, contentHash: "a")
        let revision = Identity(routeID: routeID, revision: 2, contentHash: "a")
        let hash = Identity(routeID: routeID, revision: 1, contentHash: "b")
        let second = Identity(routeID: UUID(), revision: 1, contentHash: "a")
        var camera = SavedRouteMapCameraState<Identity>()
        check(!camera.select(nil), "Empty map must not fit")
        check(camera.select(first), "First selection must fit")
        for _ in 0..<100 {
            check(!camera.select(first), "Unrelated view/location updates must not refit")
        }
        check(camera.select(second), "A different route must fit")
        check(camera.select(revision), "A new revision must fit")
        check(camera.select(hash), "A different hash must fit")
        check(!camera.select(nil), "Clearing must not fit")
        check(camera.displayedIdentity == nil, "Clearing releases identity")
        check(camera.select(hash), "Reopening after hiding must fit")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [first], deleteAfter: nil, now: now), "GPX remains available")
        check(SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [first], deleteAfter: now.addingTimeInterval(1), now: now), "Active Strava remains available")
        check(!SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [first], deleteAfter: now, now: now), "Expiry boundary is exclusive")
        check(!SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [], deleteAfter: nil, now: now), "Deletion/pruning/corruption clears preview")
        check(!SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [revision], deleteAfter: nil, now: now), "Revision replacement clears old geometry")
        check(!SavedRouteMapPolicy.shouldRetain(first, installedIdentities: [hash], deleteAfter: nil, now: now), "Hash replacement clears old geometry")
        print("Saved route map policy: \(checks) checks passed")
    }
}
