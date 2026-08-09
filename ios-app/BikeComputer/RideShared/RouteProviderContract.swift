import Foundation

struct NavigationRouteRequestV1: Equatable {
    let source: RouteEndpointV1
    let destination: RouteEndpointV1
    let localeIdentifier: String
    let transportType: RouteTransportTypeV1
    let requestAlternatives: Bool
}

protocol NavigationRouteProvider: AnyObject {
    var metadata: RouteProviderMetadataV1 { get }
    func routes(for request: NavigationRouteRequestV1) async throws -> [NavigationRouteV1]
    func cancel()
}

nonisolated enum RouteProviderPolicyV1 {
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

    static func hasConsistentKnownPolicy(
        _ metadata: RouteProviderMetadataV1
    ) -> Bool {
        switch metadata.providerID {
        case mapKit.providerID:
            metadata == mapKit
        case importedGPX.providerID:
            metadata == importedGPX
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
        metadata == importedGPX
    }
}
