import Foundation
#if canImport(Security)
import Security
#endif

nonisolated enum OfflineMapCatalogConfig {
    static let productionHost = "maps-share.8o.vc"
    static let productionBaseURL = URL(string: "https://maps-share.8o.vc")!
    static let sharedKeychainAccessGroup =
        "4H5PK8686H.LetItRide.BikeComputer.map-library"
    static let r2DownloadHostInfoKey = "BicinoMapR2DownloadHost"

    static var r2DownloadHost: String? {
        r2DownloadHost(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func r2DownloadHost(infoDictionary: [String: Any]) -> String? {
        guard let raw = infoDictionary[r2DownloadHostInfoKey] as? String else { return nil }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.range(
            of: "^[0-9a-f]{32}\\.r2\\.cloudflarestorage\\.com$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return host
    }

    static func channel(generationServerURLString: String) -> String {
        OfflineMapServerIdentity.normalized(generationServerURLString) ==
            OfflineMapServerIdentity.normalized(
                OfflineMapServiceConfig.developmentServerURLString
            ) ? "development" : "production"
    }
}

nonisolated enum OfflineMapCatalogError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case serverStatus(Int, String)
    case missingBuildIdentity
    case missingCompatibleArtifact
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The shared map library configuration is invalid."
        case .invalidResponse:
            return "The shared map library returned an invalid response."
        case .serverStatus(let status, _):
            return "The shared map library returned HTTP \(status)."
        case .missingBuildIdentity:
            return "This app build cannot verify shared map artifacts."
        case .missingCompatibleArtifact:
            return "No compatible shared map artifact is available for this app."
        case .keychain(let status):
            return "The shared map library credential could not be saved (\(status))."
        }
    }
}

nonisolated struct OfflineMapCatalogCredential: Codable, Equatable {
    let libraryId: String
    let credential: String
}

nonisolated final class OfflineMapCatalogCredentialStore: @unchecked Sendable {
    private static let service = "vc.8o.bicino.map-library"
    private static let account = "shared-library-v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> OfflineMapCatalogCredential? {
#if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: OfflineMapCatalogConfig.sharedKeychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
#else
        guard let data = defaults.data(forKey: Self.service) else { return nil }
#endif
        return try? JSONDecoder().decode(OfflineMapCatalogCredential.self, from: data)
    }

    func save(_ credential: OfflineMapCatalogCredential) throws {
        let data = try JSONEncoder().encode(credential)
#if os(iOS)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: OfflineMapCatalogConfig.sharedKeychainAccessGroup,
        ]
        let status = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OfflineMapCatalogError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw OfflineMapCatalogError.keychain(status)
        }
#else
        defaults.set(data, forKey: Self.service)
#endif
    }
}

nonisolated struct OfflineMapCatalogArtifact: Codable, Equatable, Sendable {
    let artifactId: String
    let objectKey: String
    let format: String
    let mediaType: String
    let filename: String
    let bytes: Int64
    let sha256: String
    let manifestReceipt: String?
    let signedManifestReceipt: String?
    let signatureKeyId: String?
    let signatureKeySha256: String?
    let producerBuildSha256: String?
    let producerImageDigest: String?
    let requiredIosBuild: String?
    let requiredIosGitSha: String?
    let requiredIosBuildSha256: String?
    let requiredFirmwareVersion: String?
    let requiredFirmwareBuild: UInt32?
    let requiredFirmwareGitSha: String?
    let deliveryTier: String

    var platformArtifact: OfflineMapArtifact {
        OfflineMapArtifact(
            format: format,
            mediaType: mediaType,
            filename: filename,
            objectKey: objectKey,
            bytes: bytes,
            sha256: sha256,
            manifestReceipt: manifestReceipt,
            signedManifestReceipt: signedManifestReceipt,
            signatureKeyId: signatureKeyId,
            signatureKeySha256: signatureKeySha256,
            producerBuildSha256: producerBuildSha256,
            producerImageDigest: producerImageDigest,
            requiredIosBuild: requiredIosBuild,
            requiredIosGitSha: requiredIosGitSha,
            requiredIosBuildSha256: requiredIosBuildSha256,
            requiredFirmwareVersion: requiredFirmwareVersion,
            requiredFirmwareBuild: requiredFirmwareBuild,
            requiredFirmwareGitSha: requiredFirmwareGitSha
        )
    }
}

nonisolated struct OfflineMapCatalogMap: Codable, Equatable, Sendable, Identifiable {
    var id: String { mapEntryId }
    let mapEntryId: String
    let mapId: String
    let alias: String
    let aliasSource: String
    let aliasRevision: Int
    let canonicalName: String
    let originChannel: String
    let sourceRegionName: String?
    let bounds: [Double]?
    let renderer: String
    let rendererFormatVersion: Int
    let features: [String]
    let deliveryState: String
    let generatedAt: String?
    let addedAt: String
    let updatedAt: String
    let artifacts: [OfflineMapCatalogArtifact]
}

nonisolated struct OfflineMapSharePreview: Codable, Equatable, Sendable {
    let shareId: String
    let mapEntryId: String
    let title: String
    let bounds: [Double]?
    let renderer: String
    let rendererFormatVersion: Int
    let features: [String]
    let approximateBytes: Int64
    let deliveryState: String
    let expiresAt: String?
}

nonisolated struct OfflineMapCreatedShare: Codable, Equatable, Sendable {
    let shareId: String
    let url: URL
    let title: String
    let expiresAt: String?
}

nonisolated struct OfflineMapCatalogDownloadGrant: Codable, Equatable, Sendable {
    let downloadURL: URL
    let expiresAt: String
    let artifact: OfflineMapCatalogArtifact
}

nonisolated enum OfflineMapShareLink {
    static func token(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == OfflineMapCatalogConfig.productionHost,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        let token: Substring
        if parts.count == 2, parts[0] == "s" {
            token = parts[1]
        } else if parts.count == 3, parts[0] == "dev", parts[1] == "s" {
            token = parts[2]
        } else {
            return nil
        }
        guard token.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return String(token)
    }
}

nonisolated struct OfflineMapCatalogClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = OfflineMapCatalogConfig.productionBaseURL,
        session: URLSession = .shared
    ) throws {
        guard baseURL.scheme == "https",
              baseURL.host == OfflineMapCatalogConfig.productionHost,
              baseURL.port == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw OfflineMapCatalogError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.session = session
    }

    func bootstrap(existingCredential: String?) async throws -> OfflineMapCatalogCredential {
        var request = try request(path: "/v1/libraries/bootstrap", method: "POST")
        authorize(existingCredential, request: &request)
        let response: BootstrapResponse = try await send(request)
        if let credential = response.credential {
            return OfflineMapCatalogCredential(
                libraryId: response.libraryId,
                credential: credential
            )
        }
        guard let existingCredential else { throw OfflineMapCatalogError.invalidResponse }
        return OfflineMapCatalogCredential(
            libraryId: response.libraryId,
            credential: existingCredential
        )
    }

    func maps(credential: String) async throws -> [OfflineMapCatalogMap] {
        var result: [OfflineMapCatalogMap] = []
        var cursor: String?
        repeat {
            var path = "/v1/library/maps?limit=100"
            if let cursor {
                path += "&cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            }
            var request = try request(path: path)
            authorize(credential, request: &request)
            let page: MapsResponse = try await send(request)
            result.append(contentsOf: page.maps)
            cursor = page.nextCursor
            if result.count > 10_000 { throw OfflineMapCatalogError.invalidResponse }
        } while cursor != nil
        return result
    }

    func updateAlias(
        mapEntryId: String,
        alias: String,
        expectedRevision: Int,
        credential: String
    ) async throws -> OfflineMapCatalogMap {
        try await mutation(
            path: "/v1/library/maps/\(encodedPath(mapEntryId))",
            method: "PATCH",
            body: AliasRequest(alias: alias, expectedRevision: expectedRevision),
            credential: credential
        )
    }

    func createShare(
        mapEntryId: String,
        credential: String
    ) async throws -> OfflineMapCreatedShare {
        try await mutation(
            path: "/v1/library/maps/\(encodedPath(mapEntryId))/shares",
            method: "POST",
            body: EmptyRequest(),
            credential: credential
        )
    }

    func previewShare(token: String) async throws -> OfflineMapSharePreview {
        let request = try request(path: "/v1/shares/\(encodedPath(token))")
        return try await send(request)
    }

    func claimShare(
        token: String,
        credential: String
    ) async throws -> OfflineMapCatalogMap {
        try await mutation(
            path: "/v1/shares/\(encodedPath(token))/claim",
            method: "POST",
            body: EmptyRequest(),
            credential: credential
        )
    }

    func downloadGrant(
        mapEntryId: String,
        channel: String,
        trustStore: BikeMapStreamTrustStore,
        appIdentity: MapStreamAppBuildIdentity?,
        credential: String
    ) async throws -> OfflineMapCatalogDownloadGrant {
        guard let appIdentity, appIdentity.isReleaseGrade else {
            throw OfflineMapCatalogError.missingBuildIdentity
        }
        let acceptedSigners = (trustStore.capabilityHeaderValue ?? "")
            .split(separator: ",")
            .compactMap { value -> AcceptedSigner? in
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return AcceptedSigner(keyId: String(parts[0]), keySha256: String(parts[1]))
            }
        guard !acceptedSigners.isEmpty else {
            throw OfflineMapCatalogError.missingCompatibleArtifact
        }
        return try await mutation(
            path: "/v1/library/maps/\(encodedPath(mapEntryId))/download-grants",
            method: "POST",
            body: DownloadGrantRequest(
                channel: channel,
                acceptedSigners: acceptedSigners,
                appIdentity: AppIdentityRequest(
                    build: appIdentity.build,
                    gitSha: appIdentity.gitSha,
                    buildSha256: appIdentity.componentSha256
                )
            ),
            credential: credential
        )
    }

    private func mutation<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request,
        credential: String
    ) async throws -> Response {
        var request = try request(path: path, method: method)
        authorize(credential, request: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func request(path: String, method: String = "GET") throws -> URLRequest {
        guard path.hasPrefix("/v1/"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https",
              url.host == OfflineMapCatalogConfig.productionHost else {
            throw OfflineMapCatalogError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func authorize(_ credential: String?, request: inout URLRequest) {
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapCatalogError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(data: data.prefix(4096), encoding: .utf8) ?? ""
            throw OfflineMapCatalogError.serverStatus(http.statusCode, detail)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OfflineMapCatalogError.invalidResponse
        }
    }

    private func encodedPath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

nonisolated private struct BootstrapResponse: Decodable {
    let libraryId: String
    let credential: String?
}

nonisolated private struct MapsResponse: Decodable {
    let maps: [OfflineMapCatalogMap]
    let nextCursor: String?
}

nonisolated private struct EmptyRequest: Encodable {}
nonisolated private struct AliasRequest: Encodable {
    let alias: String
    let expectedRevision: Int
}
nonisolated private struct AcceptedSigner: Encodable {
    let keyId: String
    let keySha256: String
}
nonisolated private struct AppIdentityRequest: Encodable {
    let build: String
    let gitSha: String
    let buildSha256: String
}
nonisolated private struct DownloadGrantRequest: Encodable {
    let channel: String
    let acceptedSigners: [AcceptedSigner]
    let appIdentity: AppIdentityRequest
}
