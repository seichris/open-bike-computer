import CryptoKit
import Foundation

/// Where a social route copy came from: a published route or a Group Ride snapshot.
nonisolated struct SocialRouteSource: Equatable, Sendable {
    let kind: SocialRouteProvenance.Kind
    let socialID: String
    let owner: String
    let revision: Int?
}

/// Phone-side record kept beside a saved navigation archive. Route hashes keep
/// their navigation meaning; this sidecar carries ownership for publishing rules.
nonisolated struct SocialRouteProvenance: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case content, ride }

    var schema = 2
    let kind: Kind
    let socialID: String
    let owner: String
    let socialRevision: Int?
    let sourceRouteID: String
    let sourceRevision: Int
    let sourceHash: String
    let geometry: String

    private enum CodingKeys: String, CodingKey {
        case schema, kind, socialID, owner, socialRevision, sourceRouteID, sourceRevision, sourceHash, geometry
    }

    init(source: SocialRouteSource, sourceRouteID: String, sourceRevision: Int, sourceHash: String, geometry: String) {
        kind = source.kind; socialID = source.socialID; owner = source.owner; socialRevision = source.revision
        self.sourceRouteID = sourceRouteID; self.sourceRevision = sourceRevision
        self.sourceHash = sourceHash; self.geometry = geometry
    }

    /// Schema 1 sidecars (written before restrictions existed) had no kind or
    /// geometry. They still name the owner, which is what publishing depends on.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .content
        socialID = try values.decode(String.self, forKey: .socialID)
        owner = try values.decode(String.self, forKey: .owner)
        socialRevision = try values.decodeIfPresent(Int.self, forKey: .socialRevision)
        sourceRouteID = try values.decode(String.self, forKey: .sourceRouteID)
        sourceRevision = try values.decode(Int.self, forKey: .sourceRevision)
        sourceHash = try values.decode(String.self, forKey: .sourceHash)
        geometry = try values.decodeIfPresent(String.self, forKey: .geometry) ?? ""
    }
}

/// Whether a saved route may be published by the signed-in rider.
nonisolated enum SocialRoutePublication: Equatable, Sendable {
    /// No social source is known: the rider's own imported GPX.
    case independent
    /// A copy of the rider's own published route or Group Ride snapshot.
    case ownCopy
    /// A copy of another rider's route. Only its owner can share it.
    case restricted(owner: String)

    var mayPublish: Bool {
        if case .restricted = self { return false }
        return true
    }
}

/// Route geometry identity shared with the backend's `route_fingerprint`.
nonisolated enum SocialRouteGeometry {
    private static let domain = Data("bicino-route-geometry-v1".utf8)

    /// Direction-insensitive SHA-256 of E6-rounded coordinates. Uses the same
    /// floating-point operations as archive validation so values match exactly.
    static func fingerprint(_ points: [(latitude: Double, longitude: Double)]) -> String {
        let scaled = points.map { (scaledE6($0.latitude), scaledE6($0.longitude)) }
        return min(digest(scaled), digest(Array(scaled.reversed())))
    }

    private static func scaledE6(_ value: Double) -> Int32 {
        let scaled = value * 1_000_000
        return Int32(scaled >= 0 ? (scaled + 0.5).rounded(.down) : (scaled - 0.5).rounded(.up))
    }

    private static func digest(_ sequence: [(Int32, Int32)]) -> String {
        var hash = SHA256()
        hash.update(data: domain)
        for (latitude, longitude) in sequence {
            withUnsafeBytes(of: latitude.littleEndian) { hash.update(bufferPointer: $0) }
            withUnsafeBytes(of: longitude.littleEndian) { hash.update(bufferPointer: $0) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
