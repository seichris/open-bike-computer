import Foundation

nonisolated enum StravaRouteContractError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidReceiptDate
    case invalidCacheLifetime
    case invalidBookmark
    case revisionExhausted

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Paste a Strava route URL in the form https://www.strava.com/routes/123."
        case .invalidReceiptDate:
            "The Strava route response contains an invalid timestamp."
        case .invalidCacheLifetime:
            "The Strava route response does not use Bicino's seven-day cache window."
        case .invalidBookmark:
            "The saved Strava reload reference is invalid."
        case .revisionExhausted:
            "This saved route cannot be revised again. Delete it and import it again."
        }
    }
}

nonisolated struct StravaRouteURLV1: Codable, Equatable, Hashable, Sendable {
    let externalRouteID: String
    let canonicalURL: String

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host == "www.strava.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw StravaRouteContractError.invalidURL
        }
        let prefix = "/routes/"
        guard components.percentEncodedPath.hasPrefix(prefix) else {
            throw StravaRouteContractError.invalidURL
        }
        let routeID = String(components.percentEncodedPath.dropFirst(prefix.count))
        guard RouteProviderPolicyV1.isValidStravaRouteID(routeID),
              components.percentEncodedPath == prefix + routeID else {
            throw StravaRouteContractError.invalidURL
        }
        externalRouteID = routeID
        canonicalURL = "https://www.strava.com/routes/\(routeID)"
    }

    init(reference: RouteSourceReferenceV1) throws {
        guard reference.providerID == RouteProviderPolicyV1.strava.providerID else {
            throw StravaRouteContractError.invalidURL
        }
        let parsed = try StravaRouteURLV1(reference.canonicalURL)
        guard parsed.externalRouteID == reference.externalRouteID else {
            throw StravaRouteContractError.invalidURL
        }
        self = parsed
    }

    var sourceReference: RouteSourceReferenceV1 {
        RouteSourceReferenceV1(
            providerID: RouteProviderPolicyV1.strava.providerID,
            externalRouteID: externalRouteID,
            canonicalURL: canonicalURL
        )
    }
}

nonisolated struct StravaRouteImportReceiptV1: Equatable, Sendable {
    let routeURL: StravaRouteURLV1
    let fetchedAt: Date
    let deleteAfter: Date
    let validatedAt: Date

    init(
        routeURL: StravaRouteURLV1,
        fetchedAt: Date,
        deleteAfter: Date,
        validatedAt: Date
    ) throws {
        guard fetchedAt.timeIntervalSince1970.isFinite,
              deleteAfter.timeIntervalSince1970.isFinite,
              validatedAt.timeIntervalSince1970.isFinite,
              deleteAfter > fetchedAt else {
            throw StravaRouteContractError.invalidReceiptDate
        }
        let lifetime = deleteAfter.timeIntervalSince(fetchedAt)
        guard abs(
            lifetime - RouteProviderPolicyV1.stravaRouteMaximumRetentionSeconds
        ) <= 0.001 else {
            throw StravaRouteContractError.invalidCacheLifetime
        }
        self.routeURL = routeURL
        self.fetchedAt = fetchedAt
        self.deleteAfter = deleteAfter
        self.validatedAt = validatedAt
    }
}

nonisolated struct StravaRouteReloadBookmarkV1: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let id: UUID
    let externalRouteID: String
    let canonicalURL: String
    let lastRevision: UInt32
    let localAlias: String?
    let createdAt: Date
    let lastReloadAttemptAt: Date?
    let lastReloadSucceededAt: Date?
    let lastValidationAt: Date?
    let lastErrorAt: Date?

    var routeID: UUID { id }

    init(
        routeURL: StravaRouteURLV1,
        routeID: UUID,
        lastRevision: UInt32,
        localAlias: String? = nil,
        createdAt: Date,
        lastReloadAttemptAt: Date? = nil,
        lastReloadSucceededAt: Date? = nil,
        lastValidationAt: Date? = nil,
        lastErrorAt: Date? = nil
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.id = routeID
        self.externalRouteID = routeURL.externalRouteID
        self.canonicalURL = routeURL.canonicalURL
        self.lastRevision = lastRevision
        self.localAlias = Self.normalizedAlias(localAlias)
        self.createdAt = createdAt
        self.lastReloadAttemptAt = lastReloadAttemptAt
        self.lastReloadSucceededAt = lastReloadSucceededAt
        self.lastValidationAt = lastValidationAt
        self.lastErrorAt = lastErrorAt
        try validate()
    }

    func routeURL() throws -> StravaRouteURLV1 {
        let parsed = try StravaRouteURLV1(canonicalURL)
        guard parsed.externalRouteID == externalRouteID else {
            throw StravaRouteContractError.invalidBookmark
        }
        return parsed
    }

    var sourceReference: RouteSourceReferenceV1 {
        RouteSourceReferenceV1(
            providerID: RouteProviderPolicyV1.strava.providerID,
            externalRouteID: externalRouteID,
            canonicalURL: canonicalURL
        )
    }

    var nextRevision: UInt32? {
        lastRevision == UInt32.max ? nil : lastRevision + 1
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              lastRevision > 0,
              let parsed = try? StravaRouteURLV1(canonicalURL),
              parsed.externalRouteID == externalRouteID,
              localAlias == Self.normalizedAlias(localAlias),
              Self.validDate(createdAt),
              Self.validDate(lastReloadAttemptAt),
              Self.validDate(lastReloadSucceededAt),
              Self.validDate(lastValidationAt),
              Self.validDate(lastErrorAt) else {
            throw StravaRouteContractError.invalidBookmark
        }
    }

    func updating(
        lastRevision: UInt32? = nil,
        localAlias: String?? = nil,
        lastReloadAttemptAt: Date?? = nil,
        lastReloadSucceededAt: Date?? = nil,
        lastValidationAt: Date?? = nil,
        lastErrorAt: Date?? = nil
    ) throws -> StravaRouteReloadBookmarkV1 {
        try StravaRouteReloadBookmarkV1(
            routeURL: routeURL(),
            routeID: routeID,
            lastRevision: lastRevision ?? self.lastRevision,
            localAlias: localAlias ?? self.localAlias,
            createdAt: createdAt,
            lastReloadAttemptAt: lastReloadAttemptAt ?? self.lastReloadAttemptAt,
            lastReloadSucceededAt:
                lastReloadSucceededAt ?? self.lastReloadSucceededAt,
            lastValidationAt: lastValidationAt ?? self.lastValidationAt,
            lastErrorAt: lastErrorAt ?? self.lastErrorAt
        )
    }

    private static func normalizedAlias(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }

    private static func validDate(_ value: Date?) -> Bool {
        value?.timeIntervalSince1970.isFinite ?? true
    }
}
