import Foundation
#if canImport(Security)
import Security
#endif

nonisolated enum OfflineMapCatalogConfig {
    static let productionHost = "maps-share.8o.vc"
    static let developmentHost = "maps-share-staging.8o.vc"
    static let sharedKeychainAccessGroup =
        "4H5PK8686H.LetItRide.BikeComputer.map-library"
    static let catalogHostInfoKey = "BicinoMapCatalogHost"
    static let r2DownloadHostInfoKey = "BicinoMapR2DownloadHost"
    static let developmentSigningKeyIDInfoKey =
        "BicinoMapDevelopmentSigningKeyID"
    static let developmentSigningPublicKeyInfoKey =
        "BicinoMapDevelopmentSigningPublicKeyX963Hex"

    private static let allowedCatalogHosts = [
        developmentHost,
        productionHost,
    ]

    static var catalogHost: String? {
        catalogHost(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var baseURL: URL? {
        guard let catalogHost else { return nil }
        return URL(string: "https://\(catalogHost)")
    }

    static func catalogHost(infoDictionary: [String: Any]) -> String? {
        guard let raw = infoDictionary[catalogHostInfoKey] as? String else { return nil }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isAllowedCatalogHost(host) ? host : nil
    }

    static func isAllowedCatalogHost(_ host: String) -> Bool {
        allowedCatalogHosts.contains(host.lowercased())
    }

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

    static var mapStreamTrustStore: BikeMapStreamTrustStore {
        mapStreamTrustStore(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func mapStreamTrustStore(
        infoDictionary: [String: Any]
    ) -> BikeMapStreamTrustStore {
        let production = BikeMapStreamTrustStore.production
        guard OfflineMapServiceConfig.serverURLString(
            infoDictionary: infoDictionary
        ) == OfflineMapServiceConfig.developmentServerURLString,
        let rawKeyID = infoDictionary[developmentSigningKeyIDInfoKey] as? String,
        let rawPublicKey = infoDictionary[
            developmentSigningPublicKeyInfoKey
        ] as? String else {
            return production
        }
        let keyID = rawKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKeyHex = rawPublicKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard keyID.range(
            of: "^[A-Za-z0-9._-]{1,64}$",
            options: .regularExpression
        ) != nil,
        publicKeyHex.range(
            of: "^04[0-9a-f]{128}$",
            options: .regularExpression
        ) != nil,
        let publicKey = hexadecimalData(publicKeyHex),
        let development = production.including(
            keyID: keyID,
            publicKeyX963: publicKey
        ) else {
            return production
        }
        return development
    }

    private static func hexadecimalData(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
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
    private static let productionAccount = "shared-library-v1"
#if os(iOS)
    private static let missingEntitlementStatus = OSStatus(-34_018)
#endif
    private let defaults: UserDefaults
    private let account: String
    private let fallbackDefaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        catalogHost: String? = OfflineMapCatalogConfig.catalogHost
    ) {
        self.defaults = defaults
        if catalogHost?.lowercased() == OfflineMapCatalogConfig.developmentHost {
            self.account = "\(Self.productionAccount).\(OfflineMapCatalogConfig.developmentHost)"
            self.fallbackDefaultsKey =
                "\(Self.service).\(OfflineMapCatalogConfig.developmentHost)"
        } else {
            self.account = Self.productionAccount
            self.fallbackDefaultsKey = Self.service
        }
    }

    func load() -> OfflineMapCatalogCredential? {
#if os(iOS)
        let shared = loadFromKeychain(
            accessGroup: OfflineMapCatalogConfig.sharedKeychainAccessGroup
        )
        if let credential = shared.credential {
            return credential
        }
        guard shared.status == errSecItemNotFound ||
                shared.status == Self.missingEntitlementStatus else {
            return nil
        }
        return loadFromKeychain(accessGroup: nil).credential
#else
        guard let data = defaults.data(forKey: fallbackDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(OfflineMapCatalogCredential.self, from: data)
#endif
    }

    func save(_ credential: OfflineMapCatalogCredential) throws {
        let data = try JSONEncoder().encode(credential)
#if os(iOS)
        let sharedStatus = saveToKeychain(
            data,
            accessGroup: OfflineMapCatalogConfig.sharedKeychainAccessGroup
        )
        if sharedStatus == errSecSuccess {
            return
        }
        guard sharedStatus == Self.missingEntitlementStatus else {
            throw OfflineMapCatalogError.keychain(sharedStatus)
        }
        let localStatus = saveToKeychain(data, accessGroup: nil)
        guard localStatus == errSecSuccess else {
            throw OfflineMapCatalogError.keychain(localStatus)
        }
#else
        defaults.set(data, forKey: fallbackDefaultsKey)
#endif
    }

#if os(iOS)
    private func keychainIdentity(accessGroup: String?) -> [String: Any] {
        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            identity[kSecAttrAccessGroup as String] = accessGroup
        }
        return identity
    }

    private func loadFromKeychain(
        accessGroup: String?
    ) -> (status: OSStatus, credential: OfflineMapCatalogCredential?) {
        var query = keychainIdentity(accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(
                OfflineMapCatalogCredential.self,
                from: data
              ) else {
            return (status, nil)
        }
        return (status, credential)
    }

    private func saveToKeychain(
        _ data: Data,
        accessGroup: String?
    ) -> OSStatus {
        let identity = keychainIdentity(accessGroup: accessGroup)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            update as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else {
            return updateStatus
        }
        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(
                identity as CFDictionary,
                update as CFDictionary
            )
        }
        return addStatus
    }
#endif
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

nonisolated struct OfflineMapCatalogShare: Codable, Equatable, Sendable, Identifiable {
    var id: String { shareId }
    let shareId: String
    let mapEntryId: String
    let title: String
    let createdAt: String
    let expiresAt: String?
    let revokedAt: String?
    let claimCount: Int

    var isActive: Bool {
        guard revokedAt == nil else { return false }
        guard let expiresAt else { return true }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let date = fractionalFormatter.date(from: expiresAt) ??
            ISO8601DateFormatter().date(from: expiresAt)
        return date.map { $0 > Date() } ?? false
    }
}

nonisolated struct OfflineMapLibraryLinkCode: Codable, Equatable, Sendable {
    let code: String
    let expiresAt: String
}

nonisolated struct OfflineMapCatalogDownloadGrant: Codable, Equatable, Sendable {
    let downloadURL: URL
    let expiresAt: String
    let artifact: OfflineMapCatalogArtifact
}

nonisolated enum OfflineMapCatalogAliasPolicy {
    static func aliasToApplyAfterAttachment(
        localDisplayName: String?,
        userDefinedDisplayName: Bool?,
        attachedAlias: String
    ) -> String? {
        guard userDefinedDisplayName == true,
              let alias = localDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty,
              alias != attachedAlias else {
            return nil
        }
        return alias
    }
}

nonisolated enum OfflineMapCatalogReconciliationPolicy {
    static func matchingMapIndex(
        catalogMapEntryID: String?,
        localArtifactSHA256s: Set<String>,
        catalogMaps: [OfflineMapCatalogMap]
    ) -> Int? {
        if let catalogMapEntryID {
            return catalogMaps.firstIndex { $0.mapEntryId == catalogMapEntryID }
        }
        guard !localArtifactSHA256s.isEmpty else { return nil }
        let matches = catalogMaps.indices.filter { index in
            catalogMaps[index].artifacts.contains {
                localArtifactSHA256s.contains($0.sha256)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

nonisolated enum OfflineMapShareLink {
    static func token(
        from url: URL,
        catalogHost: String? = OfflineMapCatalogConfig.catalogHost
    ) -> String? {
        guard let catalogHost else { return nil }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == catalogHost.lowercased(),
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
        baseURL: URL? = nil,
        session: URLSession = .shared
    ) throws {
        guard let baseURL = baseURL ?? OfflineMapCatalogConfig.baseURL,
              baseURL.scheme == "https",
              let host = baseURL.host?.lowercased(),
              OfflineMapCatalogConfig.isAllowedCatalogHost(host),
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

    func removeMapFromLibrary(
        mapEntryId: String,
        credential: String
    ) async throws {
        var request = try request(
            path: "/v1/library/maps/\(encodedPath(mapEntryId))",
            method: "DELETE"
        )
        authorize(credential, request: &request)
        try await sendNoContent(request, expectedStatus: 204)
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

    func shares(credential: String) async throws -> [OfflineMapCatalogShare] {
        var result: [OfflineMapCatalogShare] = []
        var cursor: String?
        repeat {
            var path = "/v1/library/shares?limit=100"
            if let cursor {
                path += "&cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            }
            var request = try request(path: path)
            authorize(credential, request: &request)
            let page: SharesResponse = try await send(request)
            result.append(contentsOf: page.shares)
            cursor = page.nextCursor
            if result.count > 10_000 { throw OfflineMapCatalogError.invalidResponse }
        } while cursor != nil
        return result
    }

    func revokeShare(
        shareId: String,
        credential: String
    ) async throws {
        var request = try request(
            path: "/v1/library/shares/\(encodedPath(shareId))",
            method: "DELETE"
        )
        authorize(credential, request: &request)
        try await sendNoContent(request, expectedStatus: 204)
    }

    func createLinkCode(
        credential: String
    ) async throws -> OfflineMapLibraryLinkCode {
        try await mutation(
            path: "/v1/libraries/link-codes",
            method: "POST",
            body: EmptyRequest(),
            credential: credential
        )
    }

    func claimLinkCode(
        _ code: String,
        credential: String
    ) async throws -> OfflineMapCatalogCredential {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.range(
            of: "^[A-Z0-9_-]{4}-[A-Z0-9_-]{4}$",
            options: .regularExpression
        ) != nil else {
            throw OfflineMapCatalogError.invalidResponse
        }
        let response: LinkClaimResponse = try await mutation(
            path: "/v1/libraries/link-codes/\(encodedPath(normalized))/claim",
            method: "POST",
            body: EmptyRequest(),
            credential: credential
        )
        return OfflineMapCatalogCredential(
            libraryId: response.libraryId,
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
              url.host?.lowercased() == baseURL.host?.lowercased() else {
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

    private func sendNoContent(
        _ request: URLRequest,
        expectedStatus: Int
    ) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapCatalogError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            let detail = String(data: data.prefix(4096), encoding: .utf8) ?? ""
            throw OfflineMapCatalogError.serverStatus(http.statusCode, detail)
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
nonisolated private struct SharesResponse: Decodable {
    let shares: [OfflineMapCatalogShare]
    let nextCursor: String?
}
nonisolated private struct LinkClaimResponse: Decodable {
    let libraryId: String
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
