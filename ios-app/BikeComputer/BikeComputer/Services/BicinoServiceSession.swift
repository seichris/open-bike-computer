import Foundation

nonisolated enum BicinoServiceSessionError: Error, Equatable {
    case invalidManagedServiceURL
    case invalidEndpoint
}

/// Owns the installation credential shared by every Bicino managed-service
/// feature. Credentials remain isolated by normalized service origin, and all
/// registration/refresh work is serialized per origin.
@MainActor
final class BicinoServiceSession {
    let urlSession: URLSession

    private let defaults: UserDefaults
    private let installationCredentialStore:
        OfflineMapInstallationCredentialStore
    private let legacyBearerTokenStore: OfflineMapLegacyBearerTokenStore
    private let legacyInstallationID: String
    private var registrationTasks: [
        String: Task<OfflineMapPlatformClient, Error>
    ] = [:]

    init(
        defaults: UserDefaults = .standard,
        urlSession: URLSession = .shared
    ) {
        self.defaults = defaults
        self.urlSession = urlSession
        installationCredentialStore =
            OfflineMapInstallationCredentialStore(defaults: defaults)
        let legacyBearerTokenStore =
            OfflineMapLegacyBearerTokenStore(defaults: defaults)
        OfflineMapSharedSecretMigration.migrateCustomServerValues(
            defaults: defaults,
            tokenStore: legacyBearerTokenStore
        )
        self.legacyBearerTokenStore = legacyBearerTokenStore
        legacyInstallationID =
            OfflineMapInstallationIdentity.resolve(defaults: defaults)
    }

    var managedServiceURL: URL? {
        Self.validatedManagedServiceURL(
            OfflineMapServiceConfig.defaultServerURLString
        )
    }

    func loadedCredential(
        serverURLString: String
    ) -> OfflineMapInstallationCredential? {
        installationCredentialStore.load(
            serverURLString: serverURLString
        )
    }

    func makeOfflineMapClient(
        serverURLString: String,
        mapStreamTrustCapabilities: String? =
            BikeMapStreamTrustStore.production.capabilityHeaderValue,
        mapStreamAppBuildIdentity: MapStreamAppBuildIdentity? = .current
    ) throws -> OfflineMapPlatformClient {
        guard let baseURL = URL(string: serverURLString),
              baseURL.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        let credential = loadedCredential(
            serverURLString: serverURLString
        )
        let legacyBearerToken = legacyBearerTokenStore.load(
            serverURLString: serverURLString
        ) ?? OfflineMapSharedSecretMigration.legacyCustomToken(
            serverURLString: serverURLString,
            defaults: defaults
        )
        return OfflineMapPlatformClient(
            baseURL: baseURL,
            legacyBearerToken: legacyBearerToken,
            clientInstallationId:
                credential?.clientInstallationId ?? legacyInstallationID,
            clientInstallationToken:
                credential?.clientInstallationToken,
            mapStreamTrustCapabilities: mapStreamTrustCapabilities,
            mapStreamAppBuildIdentity: mapStreamAppBuildIdentity,
            session: urlSession
        )
    }

    func ensureRegisteredInstallation(
        client: OfflineMapPlatformClient,
        honorRefreshBackoff: Bool = true
    ) async throws -> OfflineMapPlatformClient {
        let key = OfflineMapServerIdentity.normalized(
            client.baseURL.absoluteString
        )
        if let task = registrationTasks[key] {
            return try await task.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.registerInstallation(
                client: client,
                honorRefreshBackoff: honorRefreshBackoff
            )
        }
        registrationTasks[key] = task
        defer { registrationTasks.removeValue(forKey: key) }
        return try await task.value
    }

    /// Builds an authenticated request for the build-owned managed service.
    /// The caller may retry once with `refreshCredential` after an HTTP 401.
    func authenticatedRequest(
        path: String,
        method: String,
        additionalQueryItems: [URLQueryItem] = [],
        refreshCredential: Bool = false
    ) async throws -> URLRequest {
        guard Self.isValidEndpointPath(path),
              let baseURL = managedServiceURL else {
            throw BicinoServiceSessionError.invalidEndpoint
        }
        var client = try makeOfflineMapClient(
            serverURLString: baseURL.absoluteString,
            mapStreamTrustCapabilities: nil,
            mapStreamAppBuildIdentity: nil
        )
        if refreshCredential || client.clientInstallationToken?.isEmpty != false {
            client = try await ensureRegisteredInstallation(
                client: client,
                honorRefreshBackoff: !refreshCredential
            )
        }
        var request = try OfflineMapPlatformClient
            .makeInstallationScopedURLRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                clientInstallationId: client.clientInstallationId,
                additionalQueryItems: additionalQueryItems
            )
        guard let token = client.clientInstallationToken,
              !token.isEmpty else {
            throw OfflineMapPlatformError.invalidResponse
        }
        request.setValue(token, forHTTPHeaderField: "X-Installation-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        return request
    }

    nonisolated static func validatedManagedServiceURL(
        _ value: String
    ) -> URL? {
        guard value == OfflineMapServiceConfig.developmentServerURLString ||
                value == OfflineMapServiceConfig.productionServerURLString,
              let url = URL(string: value),
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return url
    }

    private func registerInstallation(
        client: OfflineMapPlatformClient,
        honorRefreshBackoff: Bool
    ) async throws -> OfflineMapPlatformClient {
        if honorRefreshBackoff,
           client.clientInstallationToken?.isEmpty == false,
           OfflineMapInstallationRefreshBackoff.shouldDefer(
                serverURLString: client.baseURL.absoluteString,
                defaults: defaults
           ) {
            do {
                _ = try await client.jobs()
                return client
            } catch let error as OfflineMapPlatformError {
                guard case .serverStatus(let status, _) = error,
                      status == 401 else {
                    return client
                }
                OfflineMapInstallationRefreshBackoff.clear(
                    serverURLString: client.baseURL.absoluteString,
                    defaults: defaults
                )
                return try await registerInstallation(
                    client: client,
                    honorRefreshBackoff: false
                )
            } catch {
                return client
            }
        }
        do {
            let credential = try await client.registerInstallation()
            if !client.canAdoptInstallationCredential(credential) {
                OfflineMapInstallationRefreshBackoff.deferRefresh(
                    serverURLString: client.baseURL.absoluteString,
                    defaults: defaults
                )
                return client
            }
            OfflineMapInstallationRefreshBackoff.clear(
                serverURLString: client.baseURL.absoluteString,
                defaults: defaults
            )
            return try registeredClient(
                credential,
                replacing: client
            )
        } catch let error as OfflineMapPlatformError {
            if case .serverStatus(let status, _) = error,
               status == 404 || status == 405 {
                return client
            }
            if case .serverStatus(let status, _) = error,
               status == 401,
               client.clientInstallationToken?.isEmpty == false {
                let replacement = OfflineMapPlatformClient(
                    baseURL: client.baseURL,
                    legacyBearerToken: client.legacyBearerToken,
                    clientInstallationId: legacyInstallationID,
                    mapStreamTrustCapabilities:
                        client.mapStreamTrustCapabilities,
                    mapStreamAppBuildIdentity:
                        client.mapStreamAppBuildIdentity,
                    session: urlSession
                )
                let credential = try await replacement.registerInstallation()
                return try registeredClient(
                    credential,
                    replacing: replacement
                )
            }
            throw error
        }
    }

    private func registeredClient(
        _ credential: OfflineMapInstallationCredential,
        replacing client: OfflineMapPlatformClient
    ) throws -> OfflineMapPlatformClient {
        try installationCredentialStore.save(
            credential,
            serverURLString: client.baseURL.absoluteString
        )
        return OfflineMapPlatformClient(
            baseURL: client.baseURL,
            legacyBearerToken: client.legacyBearerToken,
            clientInstallationId: credential.clientInstallationId,
            clientInstallationToken: credential.clientInstallationToken,
            mapStreamTrustCapabilities: client.mapStreamTrustCapabilities,
            mapStreamAppBuildIdentity: client.mapStreamAppBuildIdentity,
            session: urlSession
        )
    }

    private nonisolated static func isValidEndpointPath(
        _ path: String
    ) -> Bool {
        path.hasPrefix("/v1/") &&
            !path.contains("?") &&
            !path.contains("#") &&
            !path.contains("//") &&
            !path.contains("..")
    }
}
