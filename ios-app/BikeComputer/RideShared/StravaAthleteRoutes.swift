import Foundation

nonisolated enum StravaAthleteRouteTypeV1: String, Codable, Equatable,
    Sendable {
    case ride
    case run

    var displayName: String {
        switch self {
        case .ride: "Ride"
        case .run: "Run"
        }
    }

    var isImportable: Bool { self == .ride }
}

nonisolated struct StravaAthleteRouteSummaryV1: Decodable, Equatable,
    Identifiable, Sendable {
    let routeID: String
    let name: String
    let distanceMeters: Double
    let elevationGainMeters: Double
    let type: StravaAthleteRouteTypeV1

    var id: String { routeID }

    var routeURL: StravaRouteURLV1? {
        try? StravaRouteURLV1(externalRouteID: routeID)
    }

    private enum CodingKeys: String, CodingKey {
        case routeID = "routeId"
        case name
        case distanceMeters
        case elevationGainMeters
        case type
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let routeID = try values.decode(String.self, forKey: .routeID)
        let name = try values.decode(String.self, forKey: .name)
        let distance = try values.decode(Double.self, forKey: .distanceMeters)
        let elevation = try values.decode(
            Double.self,
            forKey: .elevationGainMeters
        )
        let type = try values.decode(
            StravaAthleteRouteTypeV1.self,
            forKey: .type
        )
        guard RouteProviderPolicyV1.isValidStravaRouteID(routeID),
              !name.isEmpty,
              name.utf8.count <= 512,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              distance.isFinite,
              0...100_000_000 ~= distance,
              elevation.isFinite,
              0...10_000_000 ~= elevation else {
            throw StravaRouteContractError.invalidResponseContract
        }
        self.routeID = routeID
        self.name = name
        self.distanceMeters = distance
        self.elevationGainMeters = elevation
        self.type = type
    }
}

nonisolated struct StravaAthleteRoutePageV1: Decodable, Equatable, Sendable {
    static let maximumPage = 100
    static let routesPerPage = 200

    let page: Int
    let nextPage: Int?
    let routes: [StravaAthleteRouteSummaryV1]

    private enum CodingKeys: String, CodingKey {
        case page
        case nextPage
        case routes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let page = try values.decode(Int.self, forKey: .page)
        let nextPage = try values.decodeIfPresent(Int.self, forKey: .nextPage)
        let routes = try values.decode(
            [StravaAthleteRouteSummaryV1].self,
            forKey: .routes
        )
        let ids = routes.map(\.routeID)
        guard 1...Self.maximumPage ~= page,
              routes.count <= Self.routesPerPage,
              ids.count == Set(ids).count,
              nextPage == (routes.count == Self.routesPerPage ? page + 1 : nil),
              nextPage.map({ $0 <= Self.maximumPage }) ?? true else {
            throw StravaRouteContractError.invalidResponseContract
        }
        self.page = page
        self.nextPage = nextPage
        self.routes = routes
    }
}
