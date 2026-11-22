import Foundation

/// Wire contract of `POST /v1/bicycle-detours` (see docs/saved-route-detours.md).
/// The request carries exactly two coordinates: the rider and one rejoin point.
nonisolated enum BicycleDetourServiceContractV1 {
    static let requestSchema = "bicino-bicycle-detour-request-v1"
    static let responseSchema = "bicino-bicycle-detour-response-v1"
    static let path = "/v1/bicycle-detours"
    static let maximumResponseBytes = 2 * 1_024 * 1_024
}

nonisolated struct BicycleDetourServiceRequestV1: Codable, Equatable, Sendable {
    nonisolated struct Origin: Codable, Equatable, Sendable {
        let latitudeE6: Int32
        let longitudeE6: Int32
        let courseDegrees: Double?
    }

    nonisolated struct Rejoin: Codable, Equatable, Sendable {
        let latitudeE6: Int32
        let longitudeE6: Int32
    }

    let schema: String
    let requestId: String
    let origin: Origin
    let rejoin: Rejoin
    let routeSource: String
    let locale: String

    init(
        origin: RouteCoordinateV1,
        courseDegrees: Double?,
        rejoin: RouteCoordinateV1,
        routeSource: String,
        localeIdentifier: String,
        requestID: UUID = UUID()
    ) {
        schema = BicycleDetourServiceContractV1.requestSchema
        requestId = requestID.uuidString.lowercased()
        self.origin = Origin(
            latitudeE6: Self.microdegrees(origin.latitude),
            longitudeE6: Self.microdegrees(origin.longitude),
            courseDegrees: courseDegrees.map { ($0 * 10).rounded() / 10 }
        )
        self.rejoin = Rejoin(
            latitudeE6: Self.microdegrees(rejoin.latitude),
            longitudeE6: Self.microdegrees(rejoin.longitude)
        )
        self.routeSource = routeSource
        locale = Self.languageTag(localeIdentifier)
    }

    static func microdegrees(_ value: Double) -> Int32 {
        Int32(clamping: Int64((value * 1_000_000).rounded()))
    }

    /// "en_AE@calendar=…" → "en-AE"; anything unusable → "en-US".
    static func languageTag(_ identifier: String) -> String {
        let base = identifier.split(separator: "@").first.map(String.init) ?? ""
        let tag = base.replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-")
        guard let language = parts.first, (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({ (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
              parts.count <= 4, tag.count <= 35 else { return "en-US" }
        return tag
    }
}

nonisolated struct BicycleDetourServiceResponseV1: Codable, Equatable, Sendable {
    nonisolated struct Provider: Codable, Equatable, Sendable {
        let id: String
        let attribution: String
    }

    nonisolated struct Maneuver: Codable, Equatable, Sendable {
        let type: Int
        let instruction: String
        let beginShapeIndex: Int
        let endShapeIndex: Int
        let lengthMeters: Double
        let timeSeconds: Double
        let bearingBefore: Int?
        let bearingAfter: Int?
    }

    nonisolated struct Route: Codable, Equatable, Sendable {
        let provider: Provider
        let travelMode: String
        let distanceMeters: Double
        let durationSeconds: Double
        /// `[latitudeE6, longitudeE6]` in travel order.
        let pointsE6: [[Int32]]
        let maneuvers: [Maneuver]
    }

    let schema: String
    let status: String
    let route: Route?
    let reason: String?
}

nonisolated enum BicycleDetourServiceConversionError: Error, Equatable {
    case invalidResponse
    case notBicycle
}

/// Turns the service's Valhalla bicycle route into an active-only route.
nonisolated enum BicycleDetourServiceConversionV1 {
    static func route(
        from response: BicycleDetourServiceResponseV1.Route,
        localeIdentifier: String
    ) throws -> NavigationRouteV1 {
        guard response.travelMode == "bicycle",
              response.provider == BicycleDetourServiceResponseV1.Provider(
                id: RouteProviderPolicyV1.valhallaDetour.providerID,
                attribution: RouteProviderPolicyV1.valhallaDetour.attribution
              ) else {
            throw BicycleDetourServiceConversionError.notBicycle
        }
        let points = try response.pointsE6.map { pair -> RouteCoordinateV1 in
            guard pair.count == 2 else { throw BicycleDetourServiceConversionError.invalidResponse }
            let point = RouteCoordinateV1(latitude: Double(pair[0]) / 1_000_000, longitude: Double(pair[1]) / 1_000_000)
            guard point.isValid else { throw BicycleDetourServiceConversionError.invalidResponse }
            return point
        }
        let maneuvers = response.maneuvers
        guard points.count >= 2, maneuvers.count >= 2,
              let first = points.first, let last = points.last,
              let bounds = RouteBoundsV1.enclosing(points) else {
            throw BicycleDetourServiceConversionError.invalidResponse
        }
        var previousEnd = 0
        for maneuver in maneuvers {
            guard maneuver.beginShapeIndex == previousEnd,
                  maneuver.endShapeIndex >= maneuver.beginShapeIndex,
                  maneuver.endShapeIndex < points.count else {
                throw BicycleDetourServiceConversionError.invalidResponse
            }
            previousEnd = maneuver.endShapeIndex
        }
        guard previousEnd == points.count - 1 else { throw BicycleDetourServiceConversionError.invalidResponse }
        // Valhalla states each instruction where its maneuver begins; a route
        // step ends at its maneuver. Step j covers maneuver j's geometry and
        // announces maneuver j + 1. The final (arrival) maneuver only names
        // the last step, which becomes "Rejoin saved route".
        var steps: [NavigationRouteStepV1] = []
        for index in 0..<(maneuvers.count - 1) {
            let geometry = maneuvers[index]
            let action = maneuvers[index + 1]
            let instruction = action.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(NavigationRouteStepV1(
                id: UInt32(steps.count + 1),
                geometryStartIndex: geometry.beginShapeIndex,
                geometryEndIndex: geometry.endShapeIndex,
                instruction: instruction.isEmpty ? "Continue" : String(instruction.prefix(1_000)),
                maneuver: maneuver(forValhallaType: action.type),
                distanceMeters: max(geometry.lengthMeters, 0)
            ))
        }
        let measured = NavigationGeometryV1.cumulativeDistances(for: points).last ?? 0
        let route = NavigationRouteV1(
            id: UUID(),
            revision: 1,
            provider: RouteProviderPolicyV1.valhallaDetour,
            localeIdentifier: localeIdentifier,
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: first, label: "Current Location"),
            destination: RouteEndpointV1(coordinate: last, label: SavedRouteDetourRouteV1.destinationLabel),
            bounds: bounds,
            distanceMeters: response.distanceMeters > 0 ? response.distanceMeters : max(measured, 1),
            expectedTravelTimeSeconds: response.durationSeconds > 0 ? response.durationSeconds : nil,
            name: nil,
            points: points,
            steps: steps,
            normalizationVersion: 1
        )
        try route.validate()
        return route
    }

    /// Valhalla `TripDirections.Maneuver.Type` → the shared maneuver set.
    static func maneuver(forValhallaType type: Int) -> ManeuverV1 {
        switch type {
        case 9, 18, 20, 23, 37: .slightRight
        case 10: .right
        case 11: .sharpRight
        case 12, 13: .uTurn
        case 14: .sharpLeft
        case 15: .left
        case 16, 19, 21, 24, 38: .slightLeft
        case 26: .roundabout
        case 4, 5, 6: .arrive
        default: .straight
        }
    }
}

/// One HTTP answer from the detour endpoint.
nonisolated struct BicycleDetourHTTPResponseV1: Equatable, Sendable {
    let statusCode: Int
    let cacheControl: String?
    let contentType: String?
    let retryAfter: String?
    let body: Data

    init(statusCode: Int, cacheControl: String?, contentType: String?, retryAfter: String?, body: Data) {
        self.statusCode = statusCode
        self.cacheControl = cacheControl
        self.contentType = contentType
        self.retryAfter = retryAfter
        self.body = body
    }
}

nonisolated enum BicycleDetourServiceDecoderV1 {
    /// Validates the HTTP answer and maps it to a provider outcome.
    static func outcome(
        for response: BicycleDetourHTTPResponseV1,
        localeIdentifier: String
    ) -> BicycleDetourOutcomeV1 {
        let retryAfter = response.retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { min(max($0, 1), 3_600) }
        switch response.statusCode {
        case 200:
            break
        case 429, 503:
            return .unavailable(.serviceError, retryAfterSeconds: retryAfter)
        default:
            return .unavailable(.serviceError, retryAfterSeconds: nil)
        }
        let mediaType = (response.contentType ?? "").split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard response.cacheControl?.lowercased() == "private, no-store",
              mediaType == "application/json",
              response.body.count <= BicycleDetourServiceContractV1.maximumResponseBytes,
              let decoded = try? JSONDecoder().decode(BicycleDetourServiceResponseV1.self, from: response.body),
              decoded.schema == BicycleDetourServiceContractV1.responseSchema else {
            return .unavailable(.serviceError, retryAfterSeconds: nil)
        }
        switch decoded.status {
        case "ready":
            guard let route = decoded.route,
                  let converted = try? BicycleDetourServiceConversionV1.route(
                    from: route, localeIdentifier: localeIdentifier
                  ) else {
                return .noBicycleRoute
            }
            return .route(converted)
        case "unavailable" where decoded.reason == "no_bicycle_route" || decoded.reason == "request_too_long":
            return .noBicycleRoute
        default:
            return .unavailable(.serviceError, retryAfterSeconds: nil)
        }
    }
}
