import Foundation

nonisolated enum StravaRouteContractError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidReceiptDate
    case invalidCacheLifetime
    case invalidResponseContract
    case emptyResponse
    case responseTooLarge
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
        case .invalidResponseContract:
            "Bicino received an invalid Strava route response."
        case .emptyResponse:
            "Strava returned an empty route."
        case .responseTooLarge:
            "This Strava route is too large to import."
        case .invalidBookmark:
            "The saved Strava reload reference is invalid."
        case .revisionExhausted:
            "This saved route cannot be revised again. Delete it and import it again."
        }
    }
}

nonisolated struct StravaRouteImportResponseV1: Equatable, Sendable {
    let gpx: Data
    let receipt: StravaRouteImportReceiptV1

    static func validate(
        gpx: Data,
        requestedRouteURL: StravaRouteURLV1,
        contentType: String,
        cacheControl: String,
        providerID: String,
        externalRouteID: String,
        fetchedAt: String,
        deleteAfter: String,
        now: Date
    ) throws -> StravaRouteImportResponseV1 {
        guard !gpx.isEmpty else {
            throw StravaRouteContractError.emptyResponse
        }
        guard gpx.count <= GPXRouteImporterV1.maximumInputBytes else {
            throw StravaRouteContractError.responseTooLarge
        }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/gpx+xml",
              cacheControl.lowercased() == "private, no-store",
              providerID == RouteProviderPolicyV1.strava.providerID,
              externalRouteID == requestedRouteURL.externalRouteID else {
            throw StravaRouteContractError.invalidResponseContract
        }
        let fetchedDate = try parseDate(fetchedAt)
        let deleteDate = try parseDate(deleteAfter)
        let receipt = try StravaRouteImportReceiptV1(
            routeURL: requestedRouteURL,
            fetchedAt: fetchedDate,
            deleteAfter: deleteDate,
            validatedAt: fetchedDate
        )
        guard fetchedDate <= now.addingTimeInterval(5 * 60),
              deleteDate > now else {
            throw StravaRouteContractError.invalidResponseContract
        }
        return StravaRouteImportResponseV1(gpx: gpx, receipt: receipt)
    }

    private static func parseDate(_ value: String) throws -> Date {
        guard value.utf8.count <= 64 else {
            throw StravaRouteContractError.invalidReceiptDate
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? whole.date(from: value),
              date.timeIntervalSince1970.isFinite else {
            throw StravaRouteContractError.invalidReceiptDate
        }
        return date
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
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "strava.com" || host == "www.strava.com",
              components.port == nil,
              components.user == nil,
              components.password == nil else {
            throw StravaRouteContractError.invalidURL
        }
        let prefix = "/routes/"
        var path = components.percentEncodedPath
        if path.hasSuffix("/"), path != "/" { path.removeLast() }
        guard path.hasPrefix(prefix) else {
            throw StravaRouteContractError.invalidURL
        }
        let routeID = String(path.dropFirst(prefix.count))
        guard RouteProviderPolicyV1.isValidStravaRouteID(routeID),
              path == prefix + routeID else {
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

nonisolated enum StravaOAuthCallbackResultV1: String, Equatable, Sendable {
    case connected
    case denied
    case failed
    case invalid
}

nonisolated struct StravaOAuthCallbackV1: Equatable, Sendable {
    let result: StravaOAuthCallbackResultV1
    let sessionID: String?

    static func parse(
        _ url: URL,
        expectedScheme: String,
        expectedSessionID: String
    ) -> StravaOAuthCallbackV1? {
        guard matchesReturnLocation(url, expectedScheme: expectedScheme),
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == Set(items.map(\.name)).count,
              Set(items.map(\.name)).isSubset(of: ["result", "sessionId"]),
              let resultValue = items.first(where: {
                  $0.name == "result"
              })?.value,
              let result = StravaOAuthCallbackResultV1(rawValue: resultValue)
        else {
            return nil
        }
        let sessionID = items.first(where: { $0.name == "sessionId" })?.value
        if let sessionID {
            guard sessionID == expectedSessionID,
                  sessionID.range(
                    of: "^oauth_[A-Za-z0-9_-]{24,128}$",
                    options: .regularExpression
                  ) != nil else {
                return nil
            }
        } else if result != .invalid {
            return nil
        }
        return StravaOAuthCallbackV1(
            result: result,
            sessionID: sessionID
        )
    }

    static func matchesReturnLocation(
        _ url: URL,
        expectedScheme: String
    ) -> Bool {
        guard !expectedScheme.isEmpty,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ) else {
            return false
        }
        return components.scheme == expectedScheme &&
            components.host == "strava" &&
            components.path == "/oauth-complete"
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
