import CryptoKit
import Foundation

nonisolated enum NavigationRouteArchivePurposeV1: Equatable {
    case activeUse
    case durableStorage
    case offlineNavigation
    case watchTransfer
}

nonisolated enum NavigationRouteArchiveError: Error, Equatable, CustomStringConvertible {
    case durableStorageNotAllowed(providerID: String)
    case deletionDateRequired(providerID: String)
    case invalidDeletionDate
    case retentionExceeded(providerID: String)
    case expired
    case encodedSizeExceeded
    case invalidSchemaVersion(UInt16)
    case hashMismatch
    case invalidEncoding

    var description: String {
        switch self {
        case .durableStorageNotAllowed(let providerID):
            "Provider \(providerID) does not allow durable route storage"
        case .deletionDateRequired(let providerID):
            "Provider \(providerID) requires a route deletion date"
        case .invalidDeletionDate:
            "Route deletion date must be after its creation date"
        case .retentionExceeded(let providerID):
            "Provider \(providerID) route retention exceeds its maximum"
        case .expired:
            "Route archive has expired"
        case .encodedSizeExceeded:
            "Route archive exceeds the encoded-size limit"
        case .invalidSchemaVersion(let version):
            "Unsupported route archive schema \(version)"
        case .hashMismatch:
            "Route archive integrity check failed"
        case .invalidEncoding:
            "Route archive could not be encoded or decoded"
        }
    }
}

nonisolated struct NavigationRouteArchiveV1: Codable, Equatable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    /// The route exactly as saved: what `contentHash` covers, what encoding
    /// writes and sharing uploads, and what geometry fingerprints use.
    let storedRoute: NavigationRouteV1
    /// The route to draw, navigate, profile and send to the Bicino. It is
    /// `storedRoute`, except for a version-1 Apple Maps route that version 2
    /// reads differently (`RouteCoordinateNormalizationV1.rereadVersion1`).
    let route: NavigationRouteV1
    let createdAt: Date
    let deleteAfter: Date?
    let contentHash: String

    var routeID: UUID { storedRoute.routeID }
    var revision: UInt32 { storedRoute.revision }
    var providerID: String { storedRoute.provider.providerID }

    private struct HashPayload: Codable {
        let schemaVersion: UInt16
        let route: NavigationRouteV1
        let createdAt: Date
        let deleteAfter: Date?
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, route, createdAt, deleteAfter, contentHash
    }

    init(
        schemaVersion: UInt16,
        storedRoute: NavigationRouteV1,
        createdAt: Date,
        deleteAfter: Date?,
        contentHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.storedRoute = storedRoute
        route = RouteCoordinateNormalizationV1.rereadVersion1(storedRoute)
        self.createdAt = createdAt
        self.deleteAfter = deleteAfter
        self.contentHash = contentHash
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(UInt16.self, forKey: .schemaVersion),
            storedRoute: try values.decode(NavigationRouteV1.self, forKey: .route),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            deleteAfter: try values.decodeIfPresent(Date.self, forKey: .deleteAfter),
            contentHash: try values.decode(String.self, forKey: .contentHash)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(storedRoute, forKey: .route)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(deleteAfter, forKey: .deleteAfter)
        try values.encode(contentHash, forKey: .contentHash)
    }

    static func create(
        route: NavigationRouteV1,
        createdAt: Date = Date(),
        deleteAfter: Date? = nil,
        purpose: NavigationRouteArchivePurposeV1
    ) throws -> NavigationRouteArchiveV1 {
        try route.validate()
        let normalizedCreatedAt = normalizedMilliseconds(createdAt)
        let normalizedDeleteAfter = deleteAfter.map(normalizedMilliseconds)
        try validateRetention(
            route: route,
            createdAt: normalizedCreatedAt,
            deleteAfter: normalizedDeleteAfter,
            purpose: purpose,
            now: normalizedCreatedAt
        )
        let payload = HashPayload(
            schemaVersion: schemaVersion,
            route: route,
            createdAt: normalizedCreatedAt,
            deleteAfter: normalizedDeleteAfter
        )
        let hash = try hash(payload)
        return NavigationRouteArchiveV1(
            schemaVersion: schemaVersion,
            storedRoute: route,
            createdAt: normalizedCreatedAt,
            deleteAfter: normalizedDeleteAfter,
            contentHash: hash
        )
    }

    func validate(
        purpose: NavigationRouteArchivePurposeV1,
        now: Date = Date(),
        limits: NavigationRouteLimitsV1 = .production
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw NavigationRouteArchiveError.invalidSchemaVersion(schemaVersion)
        }
        try storedRoute.validate(limits: limits)
        try Self.validateRetention(
            route: storedRoute,
            createdAt: createdAt,
            deleteAfter: deleteAfter,
            purpose: purpose,
            now: now
        )
        let payload = HashPayload(
            schemaVersion: schemaVersion,
            route: storedRoute,
            createdAt: createdAt,
            deleteAfter: deleteAfter
        )
        guard contentHash == (try Self.hash(payload)) else {
            throw NavigationRouteArchiveError.hashMismatch
        }
    }

    func encoded(
        purpose: NavigationRouteArchivePurposeV1,
        now: Date = Date(),
        limits: NavigationRouteLimitsV1 = .production
    ) throws -> Data {
        try validate(purpose: purpose, now: now, limits: limits)
        let data: Data
        do {
            data = try Self.encoder().encode(self)
        } catch {
            throw NavigationRouteArchiveError.invalidEncoding
        }
        guard data.count <= limits.maximumEncodedBytes else {
            throw NavigationRouteArchiveError.encodedSizeExceeded
        }
        return data
    }

    static func decode(
        _ data: Data,
        purpose: NavigationRouteArchivePurposeV1,
        now: Date = Date(),
        limits: NavigationRouteLimitsV1 = .production
    ) throws -> NavigationRouteArchiveV1 {
        guard data.count <= limits.maximumEncodedBytes else {
            throw NavigationRouteArchiveError.encodedSizeExceeded
        }
        let archive: NavigationRouteArchiveV1
        do {
            archive = try decoder().decode(NavigationRouteArchiveV1.self, from: data)
        } catch {
            throw NavigationRouteArchiveError.invalidEncoding
        }
        try archive.validate(purpose: purpose, now: now, limits: limits)
        return archive
    }

    /// Fully verifies an archive while allowing its retention deadline to be
    /// inspected after expiry. Callers must never use the returned geometry for
    /// navigation; this exists so stores can delete the exact expired identity.
    static func decodeForRetentionInspection(
        _ data: Data,
        purpose: NavigationRouteArchivePurposeV1,
        limits: NavigationRouteLimitsV1 = .production
    ) throws -> NavigationRouteArchiveV1 {
        guard data.count <= limits.maximumEncodedBytes else {
            throw NavigationRouteArchiveError.encodedSizeExceeded
        }
        let archive: NavigationRouteArchiveV1
        do {
            archive = try decoder().decode(NavigationRouteArchiveV1.self, from: data)
        } catch {
            throw NavigationRouteArchiveError.invalidEncoding
        }
        try archive.validate(
            purpose: purpose,
            now: archive.createdAt,
            limits: limits
        )
        return archive
    }

    private static func validateRetention(
        route: NavigationRouteV1,
        createdAt: Date,
        deleteAfter: Date?,
        purpose: NavigationRouteArchivePurposeV1,
        now: Date
    ) throws {
        guard createdAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else {
            throw NavigationRouteArchiveError.invalidDeletionDate
        }
        if let deleteAfter {
            guard deleteAfter.timeIntervalSince1970.isFinite,
                  deleteAfter > createdAt else {
                throw NavigationRouteArchiveError.invalidDeletionDate
            }
            guard now < deleteAfter else {
                throw NavigationRouteArchiveError.expired
            }
        }
        if RouteProviderPolicyV1.requiresExpiry(route.provider),
           deleteAfter == nil {
            throw NavigationRouteArchiveError.deletionDateRequired(
                providerID: route.provider.providerID
            )
        }
        if let maximumRetention = RouteProviderPolicyV1.maximumRetentionSeconds(
            for: route.provider
        ), let deleteAfter,
           deleteAfter.timeIntervalSince(createdAt) > maximumRetention {
            throw NavigationRouteArchiveError.retentionExceeded(
                providerID: route.provider.providerID
            )
        }
        if purpose == .watchTransfer, route.provider.storageScope == .phoneOnly {
            throw NavigationRouteArchiveError.durableStorageNotAllowed(
                providerID: route.provider.providerID
            )
        }
        if purpose != .activeUse,
           !RouteProviderPolicyV1.allowsDurableStorage(route.provider) {
            throw NavigationRouteArchiveError.durableStorageNotAllowed(
                providerID: route.provider.providerID
            )
        }
    }

    private static func hash(_ payload: HashPayload) throws -> String {
        let data: Data
        do {
            data = try encoder().encode(payload)
        } catch {
            throw NavigationRouteArchiveError.invalidEncoding
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Exact bytes for server-side verification without cross-language JSON
    /// floating-point re-encoding. The receiver also compares decoded content.
    func socialHashPayload() throws -> Data {
        try Self.encoder().encode(HashPayload(schemaVersion: schemaVersion, route: storedRoute,
                                              createdAt: createdAt, deleteAfter: deleteAfter))
    }

    private static func normalizedMilliseconds(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct PlannedRouteSummaryV1: Codable, Equatable, Identifiable {
    let id: UUID
    let revision: UInt32
    let contentHash: String
    let providerID: String
    let sourceReference: RouteSourceReferenceV1?
    let name: String
    let source: RouteEndpointV1
    let destination: RouteEndpointV1
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double?
    let createdAt: Date
    let deleteAfter: Date?

    init(archive: NavigationRouteArchiveV1) {
        id = archive.routeID
        revision = archive.revision
        contentHash = archive.contentHash
        providerID = archive.route.provider.providerID
        sourceReference = archive.route.sourceReference
        name = archive.route.name ?? archive.route.destination.label
        source = archive.route.source
        destination = archive.route.destination
        distanceMeters = archive.route.distanceMeters
        expectedTravelTimeSeconds = archive.route.expectedTravelTimeSeconds
        createdAt = archive.createdAt
        deleteAfter = archive.deleteAfter
    }
}
