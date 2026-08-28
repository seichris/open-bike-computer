import Foundation

nonisolated struct StravaRouteImportCapabilityV1: Equatable, Sendable {
    let enabled: Bool
    let providerID: String
    let maximumCacheSeconds: Int

    var isUsable: Bool {
        enabled &&
            providerID == RouteProviderPolicyV1.strava.providerID &&
            maximumCacheSeconds == Int(
                RouteProviderPolicyV1.stravaRouteMaximumRetentionSeconds
            )
    }
}

nonisolated struct StravaConnectionStatusV1: Equatable, Sendable {
    let enabled: Bool
    let connected: Bool
    let grantedScopes: [String]
    let canReadPrivateRoutes: Bool
    let connectedAt: Date?

    static let unavailable = StravaConnectionStatusV1(
        enabled: false,
        connected: false,
        grantedScopes: [],
        canReadPrivateRoutes: false,
        connectedAt: nil
    )
}

nonisolated struct StravaOAuthStartV1: Equatable, Sendable {
    let sessionID: String
    let appAuthorizationURL: URL
    let webAuthorizationURL: URL
    let callbackScheme: String
    let expiresAt: Date
}

nonisolated struct StravaRouteDownloadV1: Equatable, Sendable {
    let gpx: Data
    let receipt: StravaRouteImportReceiptV1
}

nonisolated struct StravaRouteValidationV1: Equatable, Sendable {
    let checkedAt: Date
}

nonisolated enum StravaIntegrationClientError: Error, Equatable,
    LocalizedError {
    case invalidResponse
    case responseTooLarge
    case unavailable
    case notConnected
    case scopeRequired
    case routeNotImportable
    case routeUnavailable
    case oauthSessionInvalid
    case rateLimited(retryAfterSeconds: Int?)
    case server(code: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Bicino received an invalid response while contacting Strava."
        case .responseTooLarge:
            "This Strava route is too large to import."
        case .unavailable:
            "Strava route import is temporarily unavailable."
        case .notConnected:
            "Connect Bicino to Strava to continue."
        case .scopeRequired:
            "Reconnect Strava and allow private-route access to import this route."
        case .routeNotImportable:
            "This route is not a cycling route available to Bicino."
        case .routeUnavailable:
            "This Strava route is unavailable."
        case .oauthSessionInvalid:
            "The Strava authorization session expired. Try again."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                "Strava is rate limiting requests. Try again in \(retryAfterSeconds) seconds."
            } else {
                "Strava is rate limiting requests. Try again later."
            }
        case .server:
            "The Strava request could not be completed."
        }
    }

    var requiresConnection: Bool {
        self == .notConnected || self == .scopeRequired
    }

    var authoritativelyRemovesRoute: Bool {
        self == .routeUnavailable || self == .routeNotImportable
    }
}

private nonisolated struct StravaCapabilitiesEnvelopeV1: Decodable {
    struct Integrations: Decodable {
        struct Capability: Decodable {
            let enabled: Bool
            let providerID: String
            let maximumCacheSeconds: Int
        }

        let stravaRouteImport: Capability
    }

    let integrations: Integrations
}

private nonisolated struct StravaConnectionEnvelopeV1: Decodable {
    let enabled: Bool
    let connected: Bool
    let grantedScopes: [String]
    let canReadPrivateRoutes: Bool
    let connectedAt: String?
}

private nonisolated struct StravaOAuthStartEnvelopeV1: Decodable {
    let sessionId: String
    let appAuthorizationUrl: String
    let webAuthorizationUrl: String
    let callbackScheme: String
    let expiresAt: String
}

private nonisolated struct StravaRouteValidationEnvelopeV1: Decodable {
    let available: Bool
    let checkedAt: String
}

private nonisolated struct StravaDisconnectEnvelopeV1: Decodable {
    let disconnected: Bool
    let revocationPending: Bool
}

private nonisolated struct StravaBackendErrorEnvelopeV1: Decodable {
    let code: String
    let message: String
}

typealias StravaHTTPRequestExecutor = @MainActor (
    URLRequest
) async throws -> (Data, URLResponse)

/// Typed, installation-authenticated client for Bicino's fixed Strava
/// mediator. It never sends a pasted URL or any Strava credential from iOS.
@MainActor
final class StravaIntegrationClient {
    static let maximumGPXBytes = GPXRouteImporterV1.maximumInputBytes
    static let maximumAthleteRoutePageBytes = 256 * 1_024

    private let serviceSession: BicinoServiceSession
    private let execute: StravaHTTPRequestExecutor
    private let expectedCallbackScheme: String
    private let now: () -> Date

    init(
        serviceSession: BicinoServiceSession,
        expectedCallbackScheme: String,
        execute: StravaHTTPRequestExecutor? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.serviceSession = serviceSession
        self.expectedCallbackScheme = expectedCallbackScheme
        self.now = now
        self.execute = execute ?? { request in
            try await serviceSession.urlSession.data(for: request)
        }
    }

    func capability() async throws -> StravaRouteImportCapabilityV1 {
        let response = try await perform(
            path: "/v1/capabilities",
            method: "GET"
        )
        let envelope: StravaCapabilitiesEnvelopeV1 = try decodeJSON(response)
        let value = envelope.integrations.stravaRouteImport
        let capability = StravaRouteImportCapabilityV1(
            enabled: value.enabled,
            providerID: value.providerID,
            maximumCacheSeconds: value.maximumCacheSeconds
        )
        guard !capability.enabled || capability.isUsable else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return capability
    }

    func connectionStatus() async throws -> StravaConnectionStatusV1 {
        let response = try await perform(
            path: "/v1/integrations/strava/connection",
            method: "GET"
        )
        let envelope: StravaConnectionEnvelopeV1 = try decodeJSON(response)
        let connectedAt = try envelope.connectedAt.map(Self.parseDate)
        let scopes = envelope.grantedScopes.sorted()
        guard scopes.count == Set(scopes).count,
              Set(scopes).isSubset(of: ["read", "read_all"]),
              (!envelope.connected || envelope.enabled),
              (!envelope.connected || scopes.contains("read")),
              envelope.canReadPrivateRoutes == scopes.contains("read_all"),
              (envelope.connectedAt == nil) == !envelope.connected,
              (connectedAt.map {
                  $0 <= now().addingTimeInterval(5 * 60)
              } ?? true) else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return StravaConnectionStatusV1(
            enabled: envelope.enabled,
            connected: envelope.connected,
            grantedScopes: scopes,
            canReadPrivateRoutes: envelope.canReadPrivateRoutes,
            connectedAt: connectedAt
        )
    }

    func startOAuth() async throws -> StravaOAuthStartV1 {
        let response = try await perform(
            path: "/v1/integrations/strava/oauth/start",
            method: "POST"
        )
        let envelope: StravaOAuthStartEnvelopeV1 = try decodeJSON(response)
        guard envelope.sessionId.range(
            of: "^oauth_[A-Za-z0-9_-]{24,128}$",
            options: .regularExpression
        ) != nil,
              envelope.callbackScheme == expectedCallbackScheme,
              let appURL = URL(string: envelope.appAuthorizationUrl),
              let webURL = URL(string: envelope.webAuthorizationUrl),
              let serviceURL = serviceSession.managedServiceURL,
              Self.isValidAuthorizationURL(
                appURL,
                native: true,
                serviceURL: serviceURL
              ),
              Self.isValidAuthorizationURL(
                webURL,
                native: false,
                serviceURL: serviceURL
              ),
              URLComponents(
                url: appURL,
                resolvingAgainstBaseURL: false
              )?.percentEncodedQuery == URLComponents(
                url: webURL,
                resolvingAgainstBaseURL: false
              )?.percentEncodedQuery else {
            throw StravaIntegrationClientError.invalidResponse
        }
        let expiresAt = try Self.parseDate(envelope.expiresAt)
        let remaining = expiresAt.timeIntervalSince(now())
        guard remaining > 0, remaining <= 10 * 60 + 30 else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return StravaOAuthStartV1(
            sessionID: envelope.sessionId,
            appAuthorizationURL: appURL,
            webAuthorizationURL: webURL,
            callbackScheme: envelope.callbackScheme,
            expiresAt: expiresAt
        )
    }

    func downloadRoute(
        _ routeURL: StravaRouteURLV1
    ) async throws -> StravaRouteDownloadV1 {
        let response = try await perform(
            path: "/v1/integrations/strava/routes/\(routeURL.externalRouteID)/gpx",
            method: "POST"
        )
        do {
            let validated = try StravaRouteImportResponseV1.validate(
                gpx: response.data,
                requestedRouteURL: routeURL,
                contentType: Self.header("Content-Type", in: response.http),
                cacheControl: Self.header("Cache-Control", in: response.http),
                providerID: Self.header(
                    "X-Bicino-Route-Provider",
                    in: response.http
                ),
                externalRouteID: Self.header(
                    "X-Bicino-External-Route-ID",
                    in: response.http
                ),
                fetchedAt: Self.header(
                    "X-Bicino-Fetched-At",
                    in: response.http
                ),
                deleteAfter: Self.header(
                    "X-Bicino-Delete-After",
                    in: response.http
                ),
                now: now()
            )
            return StravaRouteDownloadV1(
                gpx: validated.gpx,
                receipt: validated.receipt
            )
        } catch StravaRouteContractError.responseTooLarge {
            throw StravaIntegrationClientError.responseTooLarge
        } catch {
            throw StravaIntegrationClientError.invalidResponse
        }
    }

    func athleteRoutes(page: Int) async throws -> StravaAthleteRoutePageV1 {
        guard 1...StravaAthleteRoutePageV1.maximumPage ~= page else {
            throw StravaIntegrationClientError.invalidResponse
        }
        let response = try await perform(
            path: "/v1/integrations/strava/routes",
            method: "GET",
            additionalQueryItems: [
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
        let result: StravaAthleteRoutePageV1 = try decodeJSON(
            response,
            maximumBytes: Self.maximumAthleteRoutePageBytes
        )
        guard result.page == page else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return result
    }

    func validateRoute(
        _ routeURL: StravaRouteURLV1
    ) async throws -> StravaRouteValidationV1 {
        let response = try await perform(
            path: "/v1/integrations/strava/routes/\(routeURL.externalRouteID)/validate",
            method: "POST"
        )
        let envelope: StravaRouteValidationEnvelopeV1 = try decodeJSON(response)
        guard envelope.available else {
            throw StravaIntegrationClientError.invalidResponse
        }
        let checkedAt = try Self.parseDate(envelope.checkedAt)
        guard abs(checkedAt.timeIntervalSince(now())) <= 5 * 60 else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return StravaRouteValidationV1(checkedAt: checkedAt)
    }

    func disconnect() async throws {
        let response = try await perform(
            path: "/v1/integrations/strava/connection",
            method: "DELETE"
        )
        let envelope: StravaDisconnectEnvelopeV1 = try decodeJSON(response)
        guard envelope.disconnected else {
            throw StravaIntegrationClientError.invalidResponse
        }
        _ = envelope.revocationPending
    }

    private struct Response {
        let data: Data
        let http: HTTPURLResponse
    }

    private func perform(
        path: String,
        method: String,
        additionalQueryItems: [URLQueryItem] = []
    ) async throws -> Response {
        var request = try await serviceSession.authenticatedRequest(
            path: path,
            method: method,
            additionalQueryItems: additionalQueryItems
        )
        var response = try await send(request)
        if response.http.statusCode == 401,
           Self.backendCode(response.data) != "strava_not_connected" {
            request = try await serviceSession.authenticatedRequest(
                path: path,
                method: method,
                additionalQueryItems: additionalQueryItems,
                refreshCredential: true
            )
            response = try await send(request)
        }
        guard 200..<300 ~= response.http.statusCode else {
            throw Self.error(for: response)
        }
        guard Self.header("Cache-Control", in: response.http)
            .lowercased() == "private, no-store" else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return response
    }

    private func send(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await execute(request)
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url,
              let serviceURL = serviceSession.managedServiceURL,
              let responseComponents = URLComponents(
                  url: responseURL,
                  resolvingAgainstBaseURL: false
              ),
              let serviceComponents = URLComponents(
                  url: serviceURL,
                  resolvingAgainstBaseURL: false
              ),
              responseComponents.scheme == serviceComponents.scheme,
              responseComponents.host == serviceComponents.host,
              responseComponents.port == serviceComponents.port,
              responseComponents.user == nil,
              responseComponents.password == nil else {
            throw StravaIntegrationClientError.invalidResponse
        }
        return Response(data: data, http: http)
    }

    private func decodeJSON<Value: Decodable>(
        _ response: Response,
        maximumBytes: Int = 64 * 1_024
    ) throws -> Value {
        guard Self.mediaType(response.http) == "application/json",
              response.data.count <= maximumBytes else {
            throw StravaIntegrationClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Value.self, from: response.data)
        } catch {
            throw StravaIntegrationClientError.invalidResponse
        }
    }

    private nonisolated static func error(
        for response: Response
    ) -> StravaIntegrationClientError {
        let code = backendCode(response.data) ?? "unknown"
        let retry = Int(header("Retry-After", in: response.http))
        switch code {
        case "strava_not_connected": return .notConnected
        case "strava_scope_required": return .scopeRequired
        case "strava_route_not_importable": return .routeNotImportable
        case "strava_route_unavailable": return .routeUnavailable
        case "strava_oauth_session_invalid": return .oauthSessionInvalid
        case "strava_route_too_large": return .responseTooLarge
        case "strava_rate_limited": return .rateLimited(
            retryAfterSeconds: retry
        )
        case "strava_temporarily_unavailable": return .unavailable
        case "invalid_strava_route_id", "strava_invalid_response":
            return .invalidResponse
        default:
            if response.http.statusCode == 429 {
                return .rateLimited(retryAfterSeconds: retry)
            }
            if response.http.statusCode >= 500 { return .unavailable }
            return .server(code: code, status: response.http.statusCode)
        }
    }

    private nonisolated static func backendCode(_ data: Data) -> String? {
        guard data.count <= 64 * 1_024 else { return nil }
        return try? JSONDecoder().decode(
            StravaBackendErrorEnvelopeV1.self,
            from: data
        ).code
    }

    private nonisolated static func parseDate(_ value: String) throws -> Date {
        guard value.utf8.count <= 64 else {
            throw StravaIntegrationClientError.invalidResponse
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
            throw StravaIntegrationClientError.invalidResponse
        }
        return date
    }

    private nonisolated static func isValidAuthorizationURL(
        _ url: URL,
        native: Bool,
        serviceURL: URL?
    ) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.user == nil,
           components.password == nil,
           components.port == nil,
           components.fragment == nil,
           let items = components.queryItems,
           items.count == 6,
           items.count == Set(items.map(\.name)).count,
           Set(items.map(\.name)) == [
               "client_id",
               "redirect_uri",
               "response_type",
               "approval_prompt",
               "scope",
               "state",
           ],
           let serviceURL else {
            return false
        }
        let pairs = items.compactMap { item in
            item.value.map { (item.name, $0) }
        }
        guard pairs.count == items.count else { return false }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        guard
           values["client_id"]?.range(
                of: "^[1-9][0-9]{0,18}$",
                options: .regularExpression
           ) != nil,
           values["redirect_uri"] == serviceURL.absoluteString +
                "/v1/integrations/strava/oauth/callback",
           values["response_type"] == "code",
           values["approval_prompt"] == "auto",
           values["scope"] == "read,read_all",
           values["state"]?.range(
                of: "^[A-Za-z0-9_-]{32,256}$",
                options: .regularExpression
           ) != nil else {
            return false
        }
        if native {
            return components.scheme == "strava" &&
                components.host == "oauth" &&
                components.path == "/mobile/authorize"
        }
        return components.scheme == "https" &&
            components.host == "www.strava.com" &&
            components.port == nil &&
            components.path == "/oauth/mobile/authorize"
    }

    private nonisolated static func mediaType(
        _ response: HTTPURLResponse
    ) -> String {
        header("Content-Type", in: response)
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private nonisolated static func header(
        _ name: String,
        in response: HTTPURLResponse
    ) -> String {
        response.value(forHTTPHeaderField: name) ?? ""
    }
}
