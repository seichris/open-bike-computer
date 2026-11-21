import Foundation

struct NavigationRouteRequestV1: Equatable {
    let source: RouteEndpointV1
    let destination: RouteEndpointV1
    let localeIdentifier: String
    let transportType: RouteTransportTypeV1
    let requestAlternatives: Bool
}

/// A route a provider offers and what the rider must be told with it.
struct NavigationRouteOptionV1: Equatable {
    let route: NavigationRouteV1
    /// Set when car directions stand in for unavailable cycling directions
    /// (`CyclingDirectionsFallback`). The rider still cycles, so the route
    /// keeps `RouteTransportTypeV1.cycling`; the notice says whether it uses
    /// highways or toll roads.
    let notice: String?
}

@MainActor
protocol NavigationRouteProvider: AnyObject {
    var metadata: RouteProviderMetadataV1 { get }
    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> [NavigationRouteOptionV1]
    func cancel()
}

nonisolated enum RouteProviderPolicyV1 {
    static let stravaRouteMaximumRetentionSeconds: TimeInterval = 604_800

    static let mapKit = RouteProviderMetadataV1(
        providerID: "apple.mapkit",
        attribution: "Apple Maps",
        storageScope: .activeOnly
    )

    // Explicit product-policy change requested by the maintainer, 2026-09-15.
    // Storage scope is NOT a claim of Apple licensing permission. See
    // docs/reviews/mapkit-route-storage-2026-09-15.md before distribution.
    // Ordinary MapKit responses above remain active-only; only a selected route
    // captured by the phone's typed save flow receives this local scope.
    static let mapKitSavedOnPhone = RouteProviderMetadataV1(
        providerID: "apple.mapkit",
        attribution: "Apple Maps",
        storageScope: .phoneOnly
    )

    static let importedGPX = RouteProviderMetadataV1(
        providerID: "user.imported-gpx",
        attribution: "User-provided GPX",
        storageScope: .durable
    )

    static let strava = RouteProviderMetadataV1(
        providerID: "strava.route",
        attribution: "Strava",
        storageScope: .durable
    )

    /// A temporary bicycle detour from Bicino's Valhalla service (OSM data).
    /// Active only: never stored, shared, sent for elevation or to the Watch.
    static let valhallaDetour = RouteProviderMetadataV1(
        providerID: "bicino.valhalla",
        attribution: "© OpenStreetMap contributors",
        storageScope: .activeOnly
    )

    /// Saved routes a temporary bicycle detour may serve, with the provenance
    /// tag the detour service receives. Strava API imports were approved by
    /// the maintainer on 2026-11-21 on the same terms as GPX and saved Apple
    /// Maps routes. Only the rider position and one rejoin point are sent.
    static func bicycleDetourRouteSource(
        _ metadata: RouteProviderMetadataV1
    ) -> String? {
        if metadata == importedGPX { return "gpx" }
        if metadata == strava { return "strava" }
        if metadata == mapKitSavedOnPhone { return "mapkit" }
        return nil
    }

    /// Explicit saved-route sharing policy requested by the maintainer, 2026-10-22.
    /// Preserve Apple attribution and phoneOnly scope; active MapKit responses and
    /// Strava archives remain ineligible. This is not an Apple license attestation.
    static func allowsSocialSharing(_ metadata: RouteProviderMetadataV1) -> Bool {
        metadata == importedGPX || metadata == mapKitSavedOnPhone
    }

    /// Whether this route's geometry may be sent to the Bicino route elevation
    /// service, which forwards sample points to its hosted terrain provider.
    /// The maintainer enabled active and saved Apple Maps routes on 2026-10-23,
    /// and direct Strava API imports on 2026-11-21 (approved and confirmed as
    /// permitted under his Strava terms). Preserve the route's provenance in
    /// the request. A Strava route's own trusted GPX heights are still used on
    /// the phone first; only a route without them asks the service.
    static func allowsRouteElevationService(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        routeElevationServiceSource(metadata) != nil
    }

    static func routeElevationServiceSource(
        _ metadata: RouteProviderMetadataV1
    ) -> String? {
        if metadata == importedGPX { return "gpx" }
        if metadata == mapKit || metadata == mapKitSavedOnPhone { return "mapkit" }
        if metadata == strava { return "strava" }
        return nil
    }

    static func hasConsistentKnownPolicy(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        switch metadata.providerID {
        case mapKit.providerID:
            metadata == mapKit || metadata == mapKitSavedOnPhone
        case importedGPX.providerID:
            metadata == importedGPX
        case strava.providerID:
            metadata == strava
        case valhallaDetour.providerID:
            metadata == valhallaDetour
        default:
            true
        }
    }

    static func allowsDurableStorage(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        // Implementation admission, not a license grant. A self-declared
        // durable scope is insufficient, and normal MapKit responses still fail.
        metadata == importedGPX || metadata == strava || metadata == mapKitSavedOnPhone
    }

    static func requiresExpiry(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        metadata == strava
    }

    static func maximumRetentionSeconds(
        for metadata: RouteProviderMetadataV1
    ) -> TimeInterval? {
        metadata == strava ? stravaRouteMaximumRetentionSeconds : nil
    }

    static func hasConsistentSourceReference(
        _ reference: RouteSourceReferenceV1?,
        for metadata: RouteProviderMetadataV1
    ) -> Bool {
        guard metadata == strava else { return reference == nil }
        guard let reference,
              reference.providerID == strava.providerID,
              isValidStravaRouteID(reference.externalRouteID) else {
            return false
        }
        return reference.canonicalURL ==
            "https://www.strava.com/routes/\(reference.externalRouteID)"
    }

    static func isValidStravaRouteID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 19,
              value.first != "0",
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = UInt64(value),
              parsed <= UInt64(Int64.max) else {
            return false
        }
        return String(parsed) == value
    }
}
