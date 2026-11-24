import Foundation

/// A Valhalla bicycle preference offered by Create a Route.
nonisolated enum BicycleRouteProfileV1: String, CaseIterable, Codable, Sendable {
    case road
    case gravel
    case everyday
    case mountain

    var title: String {
        switch self {
        case .road: "Road"
        case .gravel: "Gravel"
        case .everyday: "Everyday"
        case .mountain: "Mountain"
        }
    }
}

/// How much of a route runs on each kind of surface, from the bicycle route
/// service's `surfaces` object. Metres that the map has no surface for are
/// `unknownMeters`.
nonisolated struct RouteSurfaceBreakdownV1: Codable, Equatable, Sendable {
    var pavedMeters: Double
    var gravelMeters: Double
    var unpavedMeters: Double
    var unknownMeters: Double

    static let zero = RouteSurfaceBreakdownV1(
        pavedMeters: 0, gravelMeters: 0, unpavedMeters: 0, unknownMeters: 0
    )

    var totalMeters: Double { pavedMeters + gravelMeters + unpavedMeters + unknownMeters }

    var isValid: Bool {
        [pavedMeters, gravelMeters, unpavedMeters, unknownMeters]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        RouteSurfaceBreakdownV1(
            pavedMeters: lhs.pavedMeters + rhs.pavedMeters,
            gravelMeters: lhs.gravelMeters + rhs.gravelMeters,
            unpavedMeters: lhs.unpavedMeters + rhs.unpavedMeters,
            unknownMeters: lhs.unknownMeters + rhs.unknownMeters
        )
    }
}

nonisolated enum RouteSurfaceKind: CaseIterable, Hashable, Sendable {
    case paved
    case gravel
    case unpaved
    case unknown

    var title: String {
        switch self {
        case .paved: "paved"
        case .gravel: "gravel"
        case .unpaved: "unpaved"
        case .unknown: "unknown"
        }
    }
}

nonisolated extension RouteSurfaceBreakdownV1 {
    /// Each surface's share of the route, largest known first and unknown
    /// last, leaving out surfaces the route never uses.
    var shares: [(kind: RouteSurfaceKind, fraction: Double)] {
        let total = totalMeters
        guard isValid, total > 0 else { return [] }
        let known: [(kind: RouteSurfaceKind, fraction: Double)] = [
            (.paved, pavedMeters / total),
            (.gravel, gravelMeters / total),
            (.unpaved, unpavedMeters / total)
        ].filter { $0.fraction > 0 }.sorted { $0.fraction > $1.fraction }
        let unknown = unknownMeters / total
        return unknown > 0 ? known + [(.unknown, unknown)] : known
    }

    /// "82% paved · 12% gravel · 6% unpaved"; a share under one percent
    /// reads "<1%".
    var summary: String {
        shares.map { share in
            let percent = (share.fraction * 100).rounded()
            let value = percent < 1 ? "<1%" : "\(Int(percent))%"
            return "\(value) \(share.kind.title)"
        }.joined(separator: " · ")
    }
}

/// One route the bicycle route service offered for a leg: its first answer
/// or one of the alternatives.
nonisolated struct BicycleRouteOptionV1: Equatable {
    let route: NavigationRouteV1
    let surfaces: RouteSurfaceBreakdownV1?
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
    /// Alternatives asked for per leg, the most the service returns.
    static let maximumAlternatives = 2
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
    /// Sent only when asked for, so a plain request stays the original shape.
    let alternatives: Int?
    let surfaces: Bool?

    init(
        origin: RouteCoordinateV1,
        destination: RouteCoordinateV1,
        profile: BicycleRouteProfileV1,
        localeIdentifier: String,
        alternatives: Int = 0,
        surfaces: Bool = false,
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
        let alternatives = min(max(alternatives, 0), BicycleRouteServiceContractV1.maximumAlternatives)
        self.alternatives = alternatives > 0 ? alternatives : nil
        self.surfaces = surfaces ? true : nil
    }
}

/// Each route object has the detour route's shape plus the profile it used
/// and, when asked for, its surface breakdown.
nonisolated struct BicycleRouteServiceResponseV1: Decodable, Equatable {
    /// One route object: the shared detour route shape and its extra fields.
    nonisolated struct Route: Decodable, Equatable {
        nonisolated private struct Extras: Decodable {
            let profile: String
            let surfaces: RouteSurfaceBreakdownV1?
        }

        let route: BicycleDetourServiceResponseV1.Route
        let profile: String
        let surfaces: RouteSurfaceBreakdownV1?

        init(from decoder: Decoder) throws {
            route = try BicycleDetourServiceResponseV1.Route(from: decoder)
            let extras = try Extras(from: decoder)
            profile = extras.profile
            surfaces = extras.surfaces
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, status, route, alternatives, reason
    }

    let schema: String
    let status: String
    let route: Route?
    /// Undecodable alternatives are dropped; they never cost the main route.
    let alternatives: [Route]
    let reason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        status = try container.decode(String.self, forKey: .status)
        route = try container.decodeIfPresent(Route.self, forKey: .route)
        alternatives = (try? container.decodeIfPresent([Lenient<Route>].self, forKey: .alternatives))?
            .compactMap(\.value) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    /// Decodes one array element, or nothing when it does not decode.
    nonisolated private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
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
    /// Alternative routes to ask for, from 0 to the contract's maximum.
    var alternatives: Int = 0
    /// Whether to ask for each route's surface breakdown.
    var surfaces: Bool = false
}

/// What the bicycle route service answered for one leg.
nonisolated enum BicycleRouteServiceOutcomeV1: Equatable {
    /// The service's route first, then any usable alternatives.
    case routes([BicycleRouteOptionV1])
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
                  let first = option(from: route, query: query) else {
                return .failed
            }
            let alternatives = decoded.alternatives
                .prefix(query.alternatives)
                .compactMap { option(from: $0, query: query) }
            return .routes([first] + alternatives)
        case "unavailable" where decoded.reason == "no_bicycle_route" || decoded.reason == "request_too_long":
            return .noBicycleRoute
        case "unavailable" where decoded.reason == "service_disabled":
            return .notOffered
        default:
            return .failed
        }
    }

    /// A converted route for the asked profile; a malformed surface breakdown
    /// is dropped rather than failing the route.
    private static func option(
        from route: BicycleRouteServiceResponseV1.Route,
        query: BicycleRouteQueryV1
    ) -> BicycleRouteOptionV1? {
        guard route.profile == query.profile.rawValue,
              let converted = try? BicycleDetourServiceConversionV1.route(
                  from: route.route,
                  sourceLabel: query.originLabel,
                  destinationLabel: query.destinationLabel,
                  localeIdentifier: query.localeIdentifier
              ) else {
            return nil
        }
        let surfaces = query.surfaces ? route.surfaces.flatMap { $0.isValid ? $0 : nil } : nil
        return BicycleRouteOptionV1(route: converted, surfaces: surfaces)
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
/// the leg's two end points, the profile, the locale and the alternatives and
/// surfaces options are sent.
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
            localeIdentifier: query.localeIdentifier,
            alternatives: query.alternatives,
            surfaces: query.surfaces
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
