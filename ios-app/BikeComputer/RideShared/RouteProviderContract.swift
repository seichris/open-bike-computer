import Foundation

struct NavigationRouteRequestV1: Equatable {
    let source: RouteEndpointV1
    let destination: RouteEndpointV1
    let localeIdentifier: String
    let transportType: RouteTransportTypeV1
    let requestAlternatives: Bool
}

@MainActor
protocol NavigationRouteProvider: AnyObject {
    var metadata: RouteProviderMetadataV1 { get }
    func routes(for request: NavigationRouteRequestV1) async throws -> [NavigationRouteV1]
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

    /// Explicit saved-route sharing policy requested by the maintainer, 2026-10-22.
    /// Preserve Apple attribution and phoneOnly scope; active MapKit responses and
    /// Strava archives remain ineligible. This is not an Apple license attestation.
    static func allowsSocialSharing(_ metadata: RouteProviderMetadataV1) -> Bool {
        metadata == importedGPX || metadata == mapKitSavedOnPhone
    }

    /// Whether this route's geometry may be sent to the Bicino route elevation
    /// service, which forwards sample points to its hosted terrain provider.
    /// Apple Maps geometry stays off this path: the privacy checklist forbids a
    /// MapKit export path without explicit approval under the current Apple
    /// terms (docs/reviews/mapkit-route-storage-2026-09-15.md). Strava API
    /// routes stay on the phone and use their own GPX elevations. Changing
    /// this is a product-policy decision, not an implementation detail.
    static func allowsRouteElevationService(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        metadata == importedGPX
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
