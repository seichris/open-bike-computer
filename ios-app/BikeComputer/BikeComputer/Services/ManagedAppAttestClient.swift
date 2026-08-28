import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif
#if os(iOS) && !HOST_TESTING
import DeviceCheck
#endif

nonisolated enum ManagedAppAttestError: LocalizedError, Equatable {
    case unsupported
    case invalidConfiguration
    case invalidChallenge
    case invalidCredential
    case keyMismatch
    case persistenceFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This device cannot prove app integrity for managed map creation."
        case .invalidConfiguration:
            return "App integrity verification is not configured for this build."
        case .invalidChallenge:
            return "The map service returned an invalid app-integrity challenge."
        case .invalidCredential:
            return "The map service returned an invalid app-integrity credential."
        case .keyMismatch:
            return "The saved map-service identity no longer matches this app installation. Try again to create a new identity."
        case .persistenceFailure(let status):
            return "Could not securely save the app-integrity key identifier (\(status))."
        }
    }
}

@MainActor
protocol OfflineMapAppAttestServicing: AnyObject {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

#if os(iOS) && !HOST_TESTING
@MainActor
final class SystemOfflineMapAppAttestService: OfflineMapAppAttestServicing {
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let keyID {
                    continuation.resume(returning: keyID)
                } else {
                    continuation.resume(throwing: ManagedAppAttestError.invalidCredential)
                }
            }
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let object {
                    continuation.resume(returning: object)
                } else {
                    continuation.resume(throwing: ManagedAppAttestError.invalidCredential)
                }
            }
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(
                keyID,
                clientDataHash: clientDataHash
            ) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let object {
                    continuation.resume(returning: object)
                } else {
                    continuation.resume(throwing: ManagedAppAttestError.invalidCredential)
                }
            }
        }
    }
}
#endif

@MainActor
final class UnsupportedOfflineMapAppAttestService: OfflineMapAppAttestServicing {
    var isSupported: Bool { false }

    func generateKey() async throws -> String {
        throw ManagedAppAttestError.unsupported
    }

    func attestKey(_: String, clientDataHash _: Data) async throws -> Data {
        throw ManagedAppAttestError.unsupported
    }

    func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data {
        throw ManagedAppAttestError.unsupported
    }
}

nonisolated struct OfflineMapAppAttestKeyStore {
    private static let service = "org.openbikecomputer.map-platform-app-attest-v1"
    private static let fallbackKeyPrefix = "offlineMap.appAttestKey."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(serverURLString: String) -> String? {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
#else
        guard let data = defaults.data(forKey: Self.fallbackKeyPrefix + account) else {
            return nil
        }
#endif
        guard let keyID = String(data: data, encoding: .utf8),
              Self.isValidKeyID(keyID) else {
            return nil
        }
        return keyID
    }

    func save(_ keyID: String, serverURLString: String) throws {
        guard Self.isValidKeyID(keyID) else {
            throw ManagedAppAttestError.invalidCredential
        }
        let account = OfflineMapServerIdentity.normalized(serverURLString)
        let data = Data(keyID.utf8)
#if os(iOS)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ManagedAppAttestError.persistenceFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ManagedAppAttestError.persistenceFailure(updateStatus)
        }
#else
        defaults.set(data, forKey: Self.fallbackKeyPrefix + account)
#endif
    }

    func delete(serverURLString: String) {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        _ = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
#else
        defaults.removeObject(forKey: Self.fallbackKeyPrefix + account)
#endif
    }

    static func isValidKeyID(_ value: String) -> Bool {
        guard value.range(
            of: "^[A-Za-z0-9+/]{43}=$",
            options: .regularExpression
        ) != nil,
        let decoded = Data(base64Encoded: value), decoded.count == 32 else {
            return false
        }
        return decoded.base64EncodedString() == value
    }
}

nonisolated struct OfflineMapAppAttestChallenge: Codable, Equatable {
    let challengeId: String
    let challenge: String
    let purpose: String
    let expiresAt: Int64
    let keyId: String?
}

private struct OfflineMapAppAttestChallengeRequest: Encodable {
    let purpose: String
    let clientInstallationId: String?
}

private struct OfflineMapAppAttestEnrollmentRequest: Encodable {
    struct Attestation: Encodable {
        let challengeId: String
        let keyId: String
        let attestationObject: String
        let appBuild: String
    }

    let appAttest: Attestation
}

nonisolated enum OfflineMapAppAttestClientData {
    static let schemaVersion = 1

    static func mapCreate(
        challenge: OfflineMapAppAttestChallenge,
        clientInstallationID: String,
        appBuild: String,
        request: URLRequest,
        jobRequest: OfflineMapJobRequest
    ) throws -> Data {
        guard challenge.purpose == "map-create",
              challenge.challengeId.range(
                of: "^[0-9a-f]{32}$",
                options: .regularExpression
              ) != nil,
              let challengeData = decodeChallenge(challenge.challenge),
              clientInstallationID.range(
                of: "^inst_v2_[0-9a-f]{32}$",
                options: .regularExpression
              ) != nil,
              appBuild.range(
                of: "^[A-Za-z0-9._-]{1,64}$",
                options: .regularExpression
              ) != nil,
              let clientRequestID = jobRequest.clientRequestId,
              clientRequestID.range(
                of: "^[A-Za-z0-9._-]{8,128}$",
                options: .regularExpression
              ) != nil,
              let requestBody = request.httpBody else {
            throw ManagedAppAttestError.invalidChallenge
        }
        let document: [String: Any] = [
            "appBuild": appBuild,
            "bodySha256": sha256Hex(requestBody),
            "challenge": base64URLEncoded(challengeData),
            "challengeId": challenge.challengeId,
            "clientInstallationId": clientInstallationID,
            "idempotencyKey": clientRequestID,
            "labelProfileVersion": jobRequest.labels?.profileVersion ?? 0,
            "method": "POST",
            "path": "/v1/map-jobs",
            "renderer": jobRequest.target?.renderer ?? "esp32-fmb",
            "rendererFormatVersion":
                jobRequest.target?.rendererFormatVersion ?? 1,
            "schemaVersion": schemaVersion,
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw ManagedAppAttestError.invalidChallenge
        }
        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func decodeChallenge(_ value: String) -> Data? {
        guard value.range(
            of: "^[A-Za-z0-9_-]{43}$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append("=")
        guard let data = Data(base64Encoded: standard), data.count == 32 else {
            return nil
        }
        return data
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class ManagedOfflineMapAppAttestClient {
    private let service: OfflineMapAppAttestServicing
    private let keyStore: OfflineMapAppAttestKeyStore
    private let session: URLSession
    private let appBuild: String

    init(
        defaults: UserDefaults,
        session: URLSession,
        service: OfflineMapAppAttestServicing? = nil,
        appBuild: String? = nil
    ) {
#if os(iOS) && !HOST_TESTING
        self.service = service ?? SystemOfflineMapAppAttestService()
#else
        self.service = service ?? UnsupportedOfflineMapAppAttestService()
#endif
        keyStore = OfflineMapAppAttestKeyStore(defaults: defaults)
        self.session = session
        self.appBuild = appBuild ?? (
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
        )
    }

    func hasKey(
        _ keyID: String?,
        serverURLString: String
    ) -> Bool {
        guard let keyID else { return false }
        return keyStore.load(serverURLString: serverURLString) == keyID
    }

    func enroll(baseURL: URL) async throws -> OfflineMapInstallationCredential {
        guard service.isSupported else {
            throw ManagedAppAttestError.unsupported
        }
        guard appBuild.range(
            of: "^[A-Za-z0-9._-]{1,64}$",
            options: .regularExpression
        ) != nil else {
            throw ManagedAppAttestError.invalidConfiguration
        }
        keyStore.delete(serverURLString: baseURL.absoluteString)
        let challenge = try await fetchChallenge(
            baseURL: baseURL,
            purpose: "attestation",
            credential: nil
        )
        guard challenge.keyId == nil,
              let challengeData = OfflineMapAppAttestClientData.decodeChallenge(
                challenge.challenge
              ) else {
            throw ManagedAppAttestError.invalidChallenge
        }
        let keyID = try await service.generateKey()
        guard OfflineMapAppAttestKeyStore.isValidKeyID(keyID) else {
            throw ManagedAppAttestError.invalidCredential
        }
        let clientDataHash = Data(SHA256.hash(data: challengeData))
        let attestation = try await service.attestKey(
            keyID,
            clientDataHash: clientDataHash
        )
        let body = OfflineMapAppAttestEnrollmentRequest(
            appAttest: .init(
                challengeId: challenge.challengeId,
                keyId: keyID,
                attestationObject: attestation.base64EncodedString(),
                appBuild: appBuild
            )
        )
        var request = URLRequest(
            url: try endpointURL(baseURL: baseURL, path: "/v1/installations")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder.offlineMap.encode(body)
        let credential: OfflineMapInstallationCredential = try await send(request)
        guard credential.appAttestKeyId == keyID else {
            throw ManagedAppAttestError.invalidCredential
        }
        try keyStore.save(keyID, serverURLString: baseURL.absoluteString)
        return credential
    }

    func authorizeMapCreate(
        request: URLRequest,
        jobRequest: OfflineMapJobRequest,
        credential: OfflineMapInstallationCredential,
        baseURL: URL
    ) async throws -> URLRequest {
        guard service.isSupported else {
            throw ManagedAppAttestError.unsupported
        }
        guard let keyID = credential.appAttestKeyId,
              hasKey(keyID, serverURLString: baseURL.absoluteString) else {
            keyStore.delete(serverURLString: baseURL.absoluteString)
            throw ManagedAppAttestError.keyMismatch
        }
        let challenge = try await fetchChallenge(
            baseURL: baseURL,
            purpose: "map-create",
            credential: credential
        )
        guard challenge.keyId == keyID else {
            keyStore.delete(serverURLString: baseURL.absoluteString)
            throw ManagedAppAttestError.keyMismatch
        }
        let clientData = try OfflineMapAppAttestClientData.mapCreate(
            challenge: challenge,
            clientInstallationID: credential.clientInstallationId,
            appBuild: appBuild,
            request: request,
            jobRequest: jobRequest
        )
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(
                keyID,
                clientDataHash: Data(SHA256.hash(data: clientData))
            )
        } catch {
            keyStore.delete(serverURLString: baseURL.absoluteString)
            throw error
        }
        var authorized = request
        authorized.setValue(
            challenge.challengeId,
            forHTTPHeaderField: "X-App-Attest-Challenge-Id"
        )
        authorized.setValue(keyID, forHTTPHeaderField: "X-App-Attest-Key-Id")
        authorized.setValue(
            assertion.base64EncodedString(),
            forHTTPHeaderField: "X-App-Attest-Assertion"
        )
        authorized.setValue(
            appBuild,
            forHTTPHeaderField: "X-App-Attest-App-Build"
        )
        return authorized
    }

    func invalidate(serverURLString: String) {
        keyStore.delete(serverURLString: serverURLString)
    }

    private func fetchChallenge(
        baseURL: URL,
        purpose: String,
        credential: OfflineMapInstallationCredential?
    ) async throws -> OfflineMapAppAttestChallenge {
        var request = URLRequest(
            url: try endpointURL(
                baseURL: baseURL,
                path: "/v1/installations/app-attest/challenges"
            )
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder.offlineMap.encode(
            OfflineMapAppAttestChallengeRequest(
                purpose: purpose,
                clientInstallationId: credential?.clientInstallationId
            )
        )
        if let credential {
            request.setValue(
                credential.clientInstallationToken,
                forHTTPHeaderField: "X-Installation-Token"
            )
        }
        let challenge: OfflineMapAppAttestChallenge = try await send(request)
        guard challenge.purpose == purpose,
              challenge.challengeId.range(
                of: "^[0-9a-f]{32}$",
                options: .regularExpression
              ) != nil,
              OfflineMapAppAttestClientData.decodeChallenge(
                challenge.challenge
              ) != nil,
              challenge.expiresAt > Int64(Date().timeIntervalSince1970) else {
            throw ManagedAppAttestError.invalidChallenge
        }
        return challenge
    }

    private func send<Response: Decodable>(
        _ request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard data.count <= 256 * 1024 else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw OfflineMapPlatformClient.platformError(
                statusCode: http.statusCode,
                data: data
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        let basePath = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let endpointPath = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        components.path = "/" + [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard let url = components.url else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return url
    }
}
