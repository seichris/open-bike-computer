import CryptoKit
import Foundation
import Security

/// Small secrets that let this app installation prove earlier social actions
/// without an account token: its push installation secret and deletion receipts.
@MainActor
protocol SocialSecureStore: AnyObject {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data?, for key: String) throws
}

struct SocialSecureStoreError: Error, Equatable {
    let status: OSStatus
}

/// Keychain storage in the app's existing explicit private access group (the
/// group Firebase Auth already uses). Items are device-only and never synced,
/// so a backup or another device cannot replay this installation's proofs.
@MainActor
final class SocialKeychainStore: SocialSecureStore {
    private let service = "LetItRide.BikeComputer.social-installation"
    private let accessGroup: String

    init(accessGroup: String) { self.accessGroup = accessGroup }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SocialSecureStoreError(status: status) }
        return data
    }

    func write(_ data: Data?, for key: String) throws {
        let base = query(key)
        guard let data else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SocialSecureStoreError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SocialSecureStoreError(status: status) }
    }
}

/// Process-only fallback when social riding is not configured for this build.
@MainActor
final class SocialMemoryStore: SocialSecureStore {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws { values[key] = data }
}

nonisolated enum SocialSecret {
    /// 256 random bits, base64url without padding.
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                     "Secure random bytes are unavailable")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The server stores only this digest of a secret.
    static func digest(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Join capabilities stay in the same app-private, device-only Keychain as other
/// installation proofs. The account ID prevents cross-account restoration.
struct SocialRideInvitation: Codable, Equatable {
    let code: String
    let previewID: String?
}

@MainActor
final class SocialRideInvitationStore {
    private let store: any SocialSecureStore
    init(store: any SocialSecureStore) { self.store = store }
    private func key(_ owner: String, _ ride: String) -> String { "ride-invite.\(owner).\(ride)" }
    func read(owner: String, ride: String) -> SocialRideInvitation? {
        guard let data = try? store.read(key(owner, ride)) else { return nil }
        return try? JSONDecoder().decode(SocialRideInvitation.self, from: data)
    }
    func write(_ value: SocialRideInvitation?, owner: String, ride: String) {
        try? store.write(value.flatMap { try? JSONEncoder().encode($0) }, for: key(owner, ride))
    }
}
