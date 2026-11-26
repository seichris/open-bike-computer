import Foundation

/// The saved-route library as the account route sync sees it: imported GPX and
/// Strava routes and saved Bicino plans. It excludes Apple Maps routes.
extension PhoneRouteLibrary: AccountRouteLibraryStoreV1 {
    private func latestSummary(routeID: String) -> PlannedRouteSummaryV1? {
        routes.filter { $0.id.uuidString.uppercased() == routeID.uppercased() }
            .max { $0.revision < $1.revision }
    }

    func accountSyncRoutes() -> [AccountLocalRouteV1] {
        var result: [AccountLocalRouteV1] = []
        var seen = Set<String>()
        for summary in routes.sorted(by: { $0.revision > $1.revision })
        where AccountRouteSyncPlannerV1.syncedProviderIDs.contains(summary.providerID) {
            let routeID = summary.id.uuidString.uppercased()
            guard seen.insert(routeID).inserted else { continue }
            result.append(AccountLocalRouteV1(
                routeID: routeID,
                title: AccountRouteSyncPlannerV1.accountTitle(displayName(for: summary)),
                contentHash: summary.contentHash,
                revision: Int(summary.revision),
                providerID: summary.providerID
            ))
        }
        // A Strava route whose seven-day lease ended stays in the library as a
        // reload bookmark. It is still the rider's route, not a deletion.
        for bookmark in stravaReloadBookmarks {
            let routeID = bookmark.routeID.uuidString.uppercased()
            guard seen.insert(routeID).inserted else { continue }
            result.append(AccountLocalRouteV1(
                routeID: routeID,
                title: (storedDisplayName(routeID: bookmark.routeID) ?? bookmark.localAlias)
                    .map(AccountRouteSyncPlannerV1.accountTitle),
                contentHash: nil,
                revision: Int(bookmark.lastRevision),
                providerID: RouteProviderPolicyV1.strava.providerID
            ))
        }
        return result
    }

    func accountSyncUpload(routeID: String) throws -> AccountRouteUploadV1 {
        guard let summary = latestSummary(routeID: routeID) else {
            throw NavigationRouteFileStoreError.ioFailure
        }
        let archive = try offlineArchive(for: summary)
        let encoded = try archive.encoded(purpose: .offlineNavigation)
        return AccountRouteUploadV1(
            archive: String(decoding: encoded, as: UTF8.self),
            hashPayload: String(decoding: try archive.socialHashPayload(), as: UTF8.self),
            title: AccountRouteSyncPlannerV1.accountTitle(displayName(for: summary)),
            contentHash: archive.contentHash,
            pointCount: archive.storedRoute.points.count,
            elevationGainMeters: knownAscent(for: archive)
        )
    }

    /// Ascent the phone already has: a cached service profile, else the file's
    /// trusted GPX heights. Never a network request.
    private func knownAscent(for archive: NavigationRouteArchiveV1) -> Double? {
        guard let sidecar = elevationSidecar(for: Self.elevationBinding(for: archive)) else { return nil }
        if let ascent = sidecar.serviceProfile?.statistics.totalAscentM { return ascent }
        guard let heights = sidecar.gpxVertexElevations else { return nil }
        return RouteElevationPreparationV1.prepare(
            points: archive.route.points,
            maximumPoints: NavigationRouteLimitsV1.production.maximumPoints,
            gpxVertexElevations: heights
        )?.localProfile?.statistics.totalAscentM
    }

    func accountSyncImport(_ archive: Data, title: String) throws {
        let summary = try importArchive(archive)
        if displayName(for: summary) != title {
            rename(summary, to: title)
        }
    }

    func accountSyncRename(routeID: String, title: String) {
        if let summary = latestSummary(routeID: routeID) {
            rename(summary, to: title)
        } else if let id = UUID(uuidString: routeID) {
            renameStravaBookmark(routeID: id, to: title)
        }
    }

    func accountSyncDelete(routeID: String) throws {
        if let summary = latestSummary(routeID: routeID) {
            try delete(summary)
        } else if let bookmark = stravaReloadBookmarks.first(where: {
            $0.routeID.uuidString.uppercased() == routeID.uppercased()
        }) {
            try deleteExpiredStravaBookmark(bookmark)
        }
    }
}
