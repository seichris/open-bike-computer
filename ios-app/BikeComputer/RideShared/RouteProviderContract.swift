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

    static func hasConsistentKnownPolicy(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        switch metadata.providerID {
        case mapKit.providerID:
            metadata == mapKit
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
        // Durable providers are an explicit allowlist. Add an export-licensed
        // provider here only with its reviewed attribution and retention
        // metadata; a self-declared `.durable` flag is not sufficient.
        metadata == importedGPX || metadata == strava
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
