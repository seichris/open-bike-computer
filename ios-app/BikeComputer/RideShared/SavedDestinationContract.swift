import Foundation

nonisolated struct SyncedCoordinateFavoriteV1:
    Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let coordinate: RouteCoordinateV1

    func validated() throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0)),
              !trimmedName.isEmpty,
              trimmedName.utf8.count <= 256,
              coordinate.isValid else {
            throw SyncedFavoriteContractError.invalidFavorite
        }
        return SyncedCoordinateFavoriteV1(
            id: id,
            name: trimmedName,
            coordinate: coordinate
        )
    }
}

nonisolated struct CoordinateFavoritesEnvelopeV1:
    Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 1
    static let applicationContextKey =
        "rideNavigation.coordinateFavorites.v1"
    static let maximumFavorites = 50

    let schema: UInt16
    let revision: UInt64
    let favorites: [SyncedCoordinateFavoriteV1]

    init(revision: UInt64, favorites: [SyncedCoordinateFavoriteV1]) {
        schema = Self.schemaVersion
        self.revision = revision
        self.favorites = favorites
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion,
              revision > 0,
              favorites.count <= Self.maximumFavorites else {
            throw SyncedFavoriteContractError.invalidEnvelope
        }
        var ids = Set<UUID>()
        let validated = try favorites.map { favorite -> SyncedCoordinateFavoriteV1 in
            let favorite = try favorite.validated()
            guard ids.insert(favorite.id).inserted else {
                throw SyncedFavoriteContractError.duplicateFavorite
            }
            return favorite
        }
        return CoordinateFavoritesEnvelopeV1(
            revision: revision,
            favorites: validated
        )
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 else {
            throw SyncedFavoriteContractError.invalidEnvelope
        }
        return try PropertyListDecoder()
            .decode(Self.self, from: data)
            .validated()
    }
}

nonisolated enum SyncedFavoriteContractError: Error, Equatable {
    case invalidFavorite
    case invalidEnvelope
    case duplicateFavorite
}

nonisolated enum RouteNetworkPolicyV1: String, Codable, Equatable, Sendable {
    case offlineOnly
    case onlineAllowed
}

/// Immutable request identity used to reject results after any authority or
/// origin change. The location generation changes only after material motion,
/// not for ordinary GPS noise while a request is in flight.
nonisolated struct WatchRouteRequestIdentityV1: Equatable, Sendable {
    let navigationGeneration: UInt64
    let policyGeneration: UInt64
    let requestGeneration: UInt64
    let locationGeneration: UInt64

    func isCurrent(
        navigationGeneration: UInt64,
        policyGeneration: UInt64,
        requestGeneration: UInt64,
        locationGeneration: UInt64,
        policy: RouteNetworkPolicyV1
    ) -> Bool {
        self.navigationGeneration == navigationGeneration &&
            self.policyGeneration == policyGeneration &&
            self.requestGeneration == requestGeneration &&
            self.locationGeneration == locationGeneration &&
            policy == .onlineAllowed
    }
}

nonisolated struct WatchRerouteCooldownV1: Equatable, Sendable {
    static let productionInterval: TimeInterval = 15
    private(set) var lastAttempt: Date?

    mutating func canAttempt(
        at date: Date,
        interval: TimeInterval = Self.productionInterval
    ) -> Bool {
        guard interval >= 0,
              lastAttempt.map({ date.timeIntervalSince($0) >= interval }) ?? true
        else { return false }
        lastAttempt = date
        return true
    }

    mutating func reset() {
        lastAttempt = nil
    }
}
