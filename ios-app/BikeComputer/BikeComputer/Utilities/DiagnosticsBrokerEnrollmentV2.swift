import Foundation

/// Credentials never enter the event vocabulary, support archive or clipboard.
nonisolated struct DiagnosticsBrokerEnrollmentV2: Codable, Equatable, Sendable {
    let schema: Int
    let brokerID: String
    let baseURL: URL
    let certificateSHA256: String
    let appFamily: String
    let expiresAtEpoch: Int
    let token: String
    var permissions: [String]

    func valid(for family: String, now: Date = Date()) -> Bool {
        guard schema == 2, UUID(uuidString: brokerID) != nil,
              appFamily == family, ["LetItRide.BikeComputer", "LetItRide.BikeComputer.dev"].contains(family),
              baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, ["", "/"].contains(baseURL.path),
              let host = baseURL.host, Self.localHost(host),
              (1...65535).contains(baseURL.port ?? 443),
              Self.hex64(certificateSHA256), Self.hex64(token),
              TimeInterval(expiresAtEpoch) > now.timeIntervalSince1970,
              TimeInterval(expiresAtEpoch) <= now.timeIntervalSince1970 + 31 * 86400,
              permissions.contains("read"), Set(permissions).count == permissions.count,
              Set(permissions).isSubset(of: ["read", "capture", "collect"]) else { return false }
        return true
    }
    static func hex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func localHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        // IPv6 unique-local/link-local addresses. URL parsing has already
        // rejected invalid host syntax; leaf pinning authenticates the peer.
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), let d = Int(parts[3]),
              [a, b, c, d].allSatisfy({ (0...255).contains($0) }) else { return false }
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
    }
}
