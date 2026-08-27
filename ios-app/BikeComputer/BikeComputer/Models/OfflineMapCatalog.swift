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

nonisolated enum OfflineMapCatalogAvailability: Equatable, Sendable {
    case available
    case awaitingProductionPromotion
    case incompatible
    case unavailable

    var canDownload: Bool { self == .available }

    var statusText: String? {
        switch self {
        case .available:
            return nil
        case .awaitingProductionPromotion:
            return "Awaiting production promotion"
        case .incompatible:
            return "Not compatible with this app build"
        case .unavailable:
            return "Map is unavailable"
        }
    }

    var claimActionTitle: String {
        canDownload ? "Add and Download" : "Add to Library"
    }

    var postClaimStatusMessage: String {
        switch self {
        case .available:
            return "shared map added"
        case .awaitingProductionPromotion:
            return "shared map added; awaiting production promotion"
        case .incompatible:
            return "shared map added; no compatible download is available"
        case .unavailable:
            return "shared map added; map is unavailable"
        }
    }
}

nonisolated enum OfflineMapCatalogAvailabilityPolicy {
    static func availability(
        for map: OfflineMapCatalogMap,
        channel: String,
        trustStore: BikeMapStreamTrustStore,
        readerCapabilities: OfflineMapReaderCapabilities = .current
    ) -> OfflineMapCatalogAvailability {
        let deliveryState = map.deliveryState.lowercased()
        if deliveryState == "blocked" || deliveryState == "tombstoned" {
            return .unavailable
        }

        if !preferredCompatibleArtifacts(
            for: map,
            channel: channel,
            trustStore: trustStore,
            readerCapabilities: readerCapabilities
        ).isEmpty {
            return .available
        }

        if channel == "production" {
            let hasProductionStream = map.artifacts.contains {
                $0.platformArtifact.isBikeMapStream &&
                    $0.deliveryTier.lowercased() == "production"
            }
            if !hasProductionStream ||
                deliveryState == "development" ||
                deliveryState == "promotion_pending" {
                return .awaitingProductionPromotion
            }
        }
        return .incompatible
    }

    static func localArtifactNeedsRefresh(
        localArtifactSHA256s: Set<String>,
        map: OfflineMapCatalogMap,
        channel: String,
        trustStore: BikeMapStreamTrustStore,
        readerCapabilities: OfflineMapReaderCapabilities = .current
    ) -> Bool {
        let deliveryState = map.deliveryState.lowercased()
        guard deliveryState != "blocked", deliveryState != "tombstoned" else {
            return false
        }
        let preferredArtifacts = preferredCompatibleArtifacts(
            for: map,
            channel: channel,
            trustStore: trustStore,
            readerCapabilities: readerCapabilities
        )
        guard !preferredArtifacts.isEmpty else { return false }
        let localSHA256s = Set(localArtifactSHA256s.map { $0.lowercased() })
        return preferredArtifacts.allSatisfy {
            !localSHA256s.contains($0.sha256.lowercased())
        }
    }

    static func availability(
        for preview: OfflineMapSharePreview,
        channel: String
    ) -> OfflineMapCatalogAvailability {
        switch preview.deliveryState.lowercased() {
        case "blocked", "tombstoned":
            return .unavailable
        case "development", "promotion_pending":
            return channel == "production" ? .awaitingProductionPromotion : .available
        case "production":
            return .available
        default:
            return .incompatible
        }
    }

    private static func preferredCompatibleArtifacts(
        for map: OfflineMapCatalogMap,
        channel: String,
        trustStore: BikeMapStreamTrustStore,
        readerCapabilities: OfflineMapReaderCapabilities
    ) -> [OfflineMapCatalogArtifact] {
        let normalizedChannel = channel.lowercased()
        let compatibleArtifacts = map.artifacts.filter {
            isCompatible(
                $0,
                map: map,
                channel: normalizedChannel,
                trustStore: trustStore,
                readerCapabilities: readerCapabilities
            )
        }
        if normalizedChannel == "development" {
            let developmentArtifacts = compatibleArtifacts.filter {
                $0.deliveryTier.lowercased() == "development"
            }
            if !developmentArtifacts.isEmpty {
                return developmentArtifacts
            }
        }
        return compatibleArtifacts.filter {
            $0.deliveryTier.lowercased() == "production"
        }
    }

    private static func isCompatible(
        _ artifact: OfflineMapCatalogArtifact,
        map: OfflineMapCatalogMap,
        channel: String,
        trustStore: BikeMapStreamTrustStore,
        readerCapabilities: OfflineMapReaderCapabilities
    ) -> Bool {
        guard artifact.platformArtifact.isBikeMapStream else { return false }
        let tier = artifact.deliveryTier.lowercased()
        guard tier == "production" || (channel == "development" && tier == "development"),
              let keyID = artifact.signatureKeyId,
              let keySHA256 = artifact.signatureKeySha256,
              trustStore.capability(for: keyID) == "\(keyID)=\(keySHA256)",
              OfflineMapReaderCompatibilityPolicy.isCompatible(
                artifact: artifact,
                map: map,
                capabilities: readerCapabilities
              ) else {
            return false
        }
        return true
    }
}

nonisolated enum OfflineMapCatalogLocalArtifactPolicy {
    static func filename(mapEntryID: String, fileExtension: String) -> String? {
        guard mapEntryID.range(
            of: "^map_v1_[A-Za-z0-9_-]{43}$",
            options: .regularExpression
        ) != nil,
        fileExtension.range(
            of: "^[a-z0-9]{1,8}$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return "catalog-\(mapEntryID).\(fileExtension)"
    }
}

@MainActor
enum OfflineMapCatalogInventorySyncPolicy {
    static func bestEffortCredential(
        _ load: () async throws -> OfflineMapCatalogCredential?
    ) async -> OfflineMapCatalogCredential? {
        do {
            return try await load()
        } catch {
            return nil
        }
    }
}

nonisolated struct OfflineMapReaderCapabilities: Codable, Equatable, Sendable {
    struct StreamFormat: Codable, Equatable, Sendable {
        let format: String
        let manifestSchemaVersions: [Int]
    }

    struct Renderer: Codable, Equatable, Sendable {
        let renderer: String
        let formatVersions: [Int]
        let features: [String]
    }

    let schemaVersion: Int
    let streamFormats: [StreamFormat]
    let renderers: [Renderer]

    static let current = Self(
        schemaVersion: 1,
        streamFormats: [
            StreamFormat(
                format: OfflineMapArtifact.bikeMapStreamFormat,
                manifestSchemaVersions: [1]
            ),
        ],
        renderers: [
            Renderer(
                renderer: "esp32-fmb",
                formatVersions: [1, 2, 3],
                features: ["3d-buildings", "street-labels"]
            ),
        ]
    )
}

nonisolated struct OfflineMapReaderRequirements: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let streamFormat: String
    let manifestSchemaVersion: Int
    let renderer: String
    let rendererFormatVersion: Int
    let requiredFeatures: [String]
}

nonisolated enum OfflineMapReaderCompatibilityPolicy {
    static func isCompatible(
        artifact: OfflineMapCatalogArtifact,
        map: OfflineMapCatalogMap,
        capabilities: OfflineMapReaderCapabilities = .current
    ) -> Bool {
        guard let requirements = artifact.readerRequirements,
              requirements.streamFormat == artifact.format,
              requirements.renderer == map.renderer,
              requirements.rendererFormatVersion == map.rendererFormatVersion,
              Set(requirements.requiredFeatures) == Set(map.features) else {
            return false
        }
        return supports(requirements, capabilities: capabilities)
    }

    static func supports(
        _ requirements: OfflineMapReaderRequirements,
        capabilities: OfflineMapReaderCapabilities = .current
    ) -> Bool {
        guard capabilities.schemaVersion == 1,
              requirements.schemaVersion == 1,
              requirements.manifestSchemaVersion > 0,
              requirements.rendererFormatVersion > 0,
              isUniqueBounded(requirements.requiredFeatures, allowsEmpty: true) else {
            return false
        }
        let supportsStream = capabilities.streamFormats.contains { stream in
            stream.format == requirements.streamFormat &&
                isUniqueBounded(stream.manifestSchemaVersions) &&
                stream.manifestSchemaVersions.contains(requirements.manifestSchemaVersion)
        }
        guard supportsStream else { return false }
        return capabilities.renderers.contains { renderer in
            renderer.renderer == requirements.renderer &&
                isUniqueBounded(renderer.formatVersions) &&
                renderer.formatVersions.contains(requirements.rendererFormatVersion) &&
                isUniqueBounded(renderer.features) &&
                Set(requirements.requiredFeatures).isSubset(of: Set(renderer.features))
        }
    }

    private static func isUniqueBounded<T: Hashable>(
        _ values: [T],
        allowsEmpty: Bool = false
    ) -> Bool {
        (allowsEmpty || !values.isEmpty) &&
            values.count <= 32 &&
            Set(values).count == values.count
    }
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

    func saveAnonymousBootstrapIfAbsent(
        _ credential: OfflineMapCatalogCredential
    ) throws -> OfflineMapCatalogCredential {
        let data = try JSONEncoder().encode(credential)
#if os(iOS)
        let sharedStatus = addToKeychain(
            data,
            accessGroup: OfflineMapCatalogConfig.sharedKeychainAccessGroup
        )
        switch sharedStatus {
        case errSecSuccess:
            return credential
        case errSecDuplicateItem:
            guard let winner = loadFromKeychain(
                accessGroup: OfflineMapCatalogConfig.sharedKeychainAccessGroup
            ).credential else {
                throw OfflineMapCatalogError.invalidResponse
            }
            return winner
        case Self.missingEntitlementStatus:
            let localStatus = addToKeychain(data, accessGroup: nil)
            switch localStatus {
            case errSecSuccess:
                return credential
            case errSecDuplicateItem:
                guard let winner = loadFromKeychain(accessGroup: nil).credential else {
                    throw OfflineMapCatalogError.invalidResponse
                }
                return winner
            default:
                throw OfflineMapCatalogError.keychain(localStatus)
            }
        default:
            throw OfflineMapCatalogError.keychain(sharedStatus)
        }
#else
        if let winner = load() {
            return winner
        }
        defaults.set(data, forKey: fallbackDefaultsKey)
        return load() ?? credential
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

    private func addToKeychain(
        _ data: Data,
        accessGroup: String?
    ) -> OSStatus {
        var item = keychainIdentity(accessGroup: accessGroup)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
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
    var readerRequirements: OfflineMapReaderRequirements? = nil

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
    var alias: String
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
    static func normalizedAlias(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) else {
            return nil
        }
        // Match ECMAScript String.prototype.trim exactly after rejecting Cc.
        // Foundation's whitespace set also contains U+200B, which JavaScript
        // deliberately preserves, so using it would split the client/server
        // alias contract for invisible format scalars.
        let catalogTrimCharacters = CharacterSet(
            charactersIn:
                "\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}" +
                "\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
                "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        )
        let alias = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: catalogTrimCharacters)
        guard !alias.isEmpty,
              alias.unicodeScalars.count <= 80,
              alias.utf8.count <= 240 else {
            return nil
        }
        return alias
    }

    static func aliasToApplyAfterAttachment(
        localDisplayName: String?,
        userDefinedDisplayName: Bool?,
        attachedAlias: String
    ) -> String? {
        guard userDefinedDisplayName == true,
              let localDisplayName,
              let alias = normalizedAlias(localDisplayName),
              alias != attachedAlias else {
            return nil
        }
        return alias
    }
}

nonisolated enum OfflineMapCatalogPendingAliasState: String, Codable, Equatable, Sendable {
    case pending
    case conflict
}

nonisolated struct OfflineMapCatalogPendingAlias: Codable, Equatable, Sendable {
    let mapEntryID: String
    let alias: String
    let expectedRevision: Int
    var state: OfflineMapCatalogPendingAliasState
}

nonisolated enum OfflineMapCatalogPendingAliasPolicy {
    enum Resolution: Equatable {
        case retry
        case fulfilled
        case conflict
    }

    static func resolution(
        pending: OfflineMapCatalogPendingAlias,
        remoteAlias: String,
        remoteRevision: Int
    ) -> Resolution {
        if remoteAlias == pending.alias {
            return .fulfilled
        }
        guard pending.state == .pending,
              remoteRevision == pending.expectedRevision else {
            return .conflict
        }
        return .retry
    }

    static func belongsToRequestSnapshot(
        currentToken: UUID?,
        requestStartToken: UUID?
    ) -> Bool {
        guard let requestStartToken else { return false }
        return currentToken == requestStartToken
    }
}

nonisolated final class OfflineMapCatalogPendingAliasStore: @unchecked Sendable {
    private static let keyPrefix = "vc.8o.bicino.map-library.pending-aliases-v1"
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        catalogHost: String? = OfflineMapCatalogConfig.catalogHost
    ) {
        self.defaults = defaults
        let namespace = catalogHost?.lowercased() == OfflineMapCatalogConfig.developmentHost
            ? OfflineMapCatalogConfig.developmentHost
            : OfflineMapCatalogConfig.productionHost
        self.key = "\(Self.keyPrefix).\(namespace)"
    }

    func load() -> [String: OfflineMapCatalogPendingAlias] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                [String: OfflineMapCatalogPendingAlias].self,
                from: data
              ) else {
            return [:]
        }
        return decoded.filter { mapEntryID, pending in
            mapEntryID == pending.mapEntryID &&
                OfflineMapCatalogLocalArtifactPolicy.filename(
                    mapEntryID: mapEntryID,
                    fileExtension: "bmap"
                ) != nil &&
                OfflineMapCatalogAliasPolicy.normalizedAlias(pending.alias) == pending.alias &&
                pending.expectedRevision >= 0
        }
    }

    func save(_ pendingAliases: [String: OfflineMapCatalogPendingAlias]) {
        guard !pendingAliases.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(pendingAliases) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class OfflineMapCatalogCredentialCoordinator {
    private var inFlight: (
        id: UUID,
        task: Task<OfflineMapCatalogCredential, Error>
    )?

    func credential(
        loadExisting: @escaping @MainActor () -> OfflineMapCatalogCredential?,
        bootstrap: @escaping @MainActor (String?) async throws -> OfflineMapCatalogCredential,
        persistAnonymousBootstrap: @escaping @MainActor (
            OfflineMapCatalogCredential
        ) throws -> OfflineMapCatalogCredential
    ) async throws -> OfflineMapCatalogCredential {
        if let inFlight {
            return try await inFlight.task.value
        }

        let id = UUID()
        let task = Task { @MainActor in
            let existing = loadExisting()
            let credential = try await bootstrap(existing?.credential)
            return try persistAnonymousBootstrap(credential)
        }
        inFlight = (id, task)
        do {
            let credential = try await task.value
            if inFlight?.id == id {
                inFlight = nil
            }
            return credential
        } catch {
            if inFlight?.id == id {
                inFlight = nil
            }
            throw error
        }
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
                readerCapabilities: .current,
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
    let readerCapabilities: OfflineMapReaderCapabilities
    let appIdentity: AppIdentityRequest
}
