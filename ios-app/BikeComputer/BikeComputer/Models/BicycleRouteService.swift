import Foundation

/// A Valhalla bicycle preference offered by Create a Route.
nonisolated enum BicycleRouteProfileV1: String, CaseIterable, Codable, Sendable {
    case road
    case gravel
    case everyday

    var title: String {
        switch self {
        case .road: "Road"
        case .gravel: "Gravel"
        case .everyday: "Everyday"
        }
    }
}

/// Wire contract of `POST /v1/bicycle-routes`: one leg between two points
/// with a bicycle profile (see docs/saved-route-detours.md).
nonisolated enum BicycleRouteServiceContractV1 {
    static let requestSchema = "bicino-bicycle-route-request-v1"
    static let responseSchema = "bicino-bicycle-route-response-v1"
    static let path = "/v1/bicycle-routes"
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let minimumSeparationMeters = 10.0
    /// The service rejects longer legs; the app sends them to Apple Maps.
    static let maximumSeparationMeters = 150_000.0
}

nonisolated struct BicycleRouteServiceRequestV1: Codable, Equatable, Sendable {
    nonisolated struct Point: Codable, Equatable, Sendable {
        let latitudeE6: Int32
        let longitudeE6: Int32
    }

    let schema: String
    let requestId: String
    let origin: Point
    let destination: Point
    let profile: String
    let locale: String

    init(
        origin: RouteCoordinateV1,
        destination: RouteCoordinateV1,
        profile: BicycleRouteProfileV1,
        localeIdentifier: String,
        requestID: UUID = UUID()
    ) {
        schema = BicycleRouteServiceContractV1.requestSchema
        requestId = requestID.uuidString.lowercased()
        self.origin = Point(
            latitudeE6: BicycleDetourServiceRequestV1.microdegrees(origin.latitude),
            longitudeE6: BicycleDetourServiceRequestV1.microdegrees(origin.longitude)
        )
        self.destination = Point(
            latitudeE6: BicycleDetourServiceRequestV1.microdegrees(destination.latitude),
            longitudeE6: BicycleDetourServiceRequestV1.microdegrees(destination.longitude)
        )
        self.profile = profile.rawValue
        locale = BicycleDetourServiceRequestV1.languageTag(localeIdentifier)
    }
}

/// The route object has the detour route's shape plus the profile it used.
nonisolated struct BicycleRouteServiceResponseV1: Decodable, Equatable {
    nonisolated private struct ProfileEcho: Decodable {
        let profile: String
    }

    private enum CodingKeys: String, CodingKey {
        case schema, status, route, reason
    }

    let schema: String
    let status: String
    let route: BicycleDetourServiceResponseV1.Route?
    let routeProfile: String?
    let reason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        status = try container.decode(String.self, forKey: .status)
        route = try container.decodeIfPresent(BicycleDetourServiceResponseV1.Route.self, forKey: .route)
        routeProfile = try container.decodeIfPresent(ProfileEcho.self, forKey: .route)?.profile
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// One leg question. Coordinates are WGS-84; nothing else of the route
/// leaves the phone.
nonisolated struct BicycleRouteQueryV1: Equatable, Sendable {
    let origin: RouteCoordinateV1
    let destination: RouteCoordinateV1
    let originLabel: String
    let destinationLabel: String
    let profile: BicycleRouteProfileV1
    let localeIdentifier: String
}

/// What the bicycle route service answered for one leg.
nonisolated enum BicycleRouteServiceOutcomeV1: Equatable {
    case route(NavigationRouteV1)
    /// No bicycle route between these points, which includes points outside
    /// the service's graph (where Apple Maps has cycling directions).
    case noBicycleRoute
    /// This server does not offer bicycle routes (not deployed or disabled).
    case notOffered
    case offline
    case busy(retryAfterSeconds: Int?)
    case failed
    case cancelled
}

nonisolated enum BicycleRouteServiceDecoderV1 {
    /// Validates the HTTP answer and maps it to a leg outcome.
    static func outcome(
        for response: BicycleDetourHTTPResponseV1,
        query: BicycleRouteQueryV1
    ) -> BicycleRouteServiceOutcomeV1 {
        switch response.statusCode {
        case 200:
            break
        case 404:
            return .notOffered
        case 429, 503:
            let retryAfter = response.retryAfter
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { min(max($0, 1), 3_600) }
            return .busy(retryAfterSeconds: retryAfter)
        default:
            return .failed
        }
        let mediaType = (response.contentType ?? "").split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard response.cacheControl?.lowercased() == "private, no-store",
              mediaType == "application/json",
              response.body.count <= BicycleRouteServiceContractV1.maximumResponseBytes,
              let decoded = try? JSONDecoder().decode(BicycleRouteServiceResponseV1.self, from: response.body),
              decoded.schema == BicycleRouteServiceContractV1.responseSchema else {
            return .failed
        }
        switch decoded.status {
        case "ready":
            guard let route = decoded.route,
                  decoded.routeProfile == query.profile.rawValue,
                  let converted = try? BicycleDetourServiceConversionV1.route(
                      from: route,
                      sourceLabel: query.originLabel,
                      destinationLabel: query.destinationLabel,
                      localeIdentifier: query.localeIdentifier
                  ) else {
                return .failed
            }
            return .route(converted)
        case "unavailable" where decoded.reason == "no_bicycle_route" || decoded.reason == "request_too_long":
            return .noBicycleRoute
        case "unavailable" where decoded.reason == "service_disabled":
            return .notOffered
        default:
            return .failed
        }
    }
}

/// Sends one request body to the Bicino service: the phone's authenticated
/// service session, or a test double.
@MainActor
protocol BicycleRouteServiceTransporting: AnyObject {
    func post(_ request: BicycleRouteServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1
}

@MainActor
protocol BicycleRouteServicing: AnyObject {
    func route(for query: BicycleRouteQueryV1) async -> BicycleRouteServiceOutcomeV1
    func cancel()
}

/// The Bicino Valhalla bicycle route service for Create a Route legs. Only
/// the leg's two end points, the profile and the locale are sent.
@MainActor
final class BicinoBicycleRouteService: BicycleRouteServicing {
    private let transport: BicycleRouteServiceTransporting
    private var generation: UInt64 = 0
    private(set) var lastRequest: BicycleRouteServiceRequestV1?

    init(transport: BicycleRouteServiceTransporting) {
        self.transport = transport
    }

    func route(for query: BicycleRouteQueryV1) async -> BicycleRouteServiceOutcomeV1 {
        generation &+= 1
        let current = generation
        let request = BicycleRouteServiceRequestV1(
            origin: query.origin,
            destination: query.destination,
            profile: query.profile,
            localeIdentifier: query.localeIdentifier
        )
        lastRequest = request
        do {
            let response = try await transport.post(request)
            guard current == generation, !Task.isCancelled else { return .cancelled }
            return BicycleRouteServiceDecoderV1.outcome(for: response, query: query)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError {
            guard current == generation else { return .cancelled }
            switch error.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed,
                 .cannotConnectToHost, .timedOut:
                return .offline
            default:
                return .failed
            }
        } catch {
            // The installation credential or App Attest is unavailable here.
            guard current == generation else { return .cancelled }
            return .notOffered
        }
    }

    func cancel() {
        generation &+= 1
    }
}
