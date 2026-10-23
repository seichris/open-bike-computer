import CryptoKit
import Foundation
import Security

/// App-private social installation proofs and consent metadata: push secrets,
/// deletion receipts, invitations and remembered friend-sharing leases. Unlike the
/// app container, these items can survive deleting and reinstalling the app.
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

/// Names one app installation. Keychain items can outlive deleting the app but its
/// container cannot, so consent bound to this marker never resumes after a reinstall.
/// Rotating it disowns every record written under the previous value.
@MainActor
protocol SocialInstallationMarker: AnyObject {
    func current() throws -> String
    func rotate() throws -> String
}

/// A missing or damaged file starts a new installation; a protected or unreadable
/// file is an error, so it is never silently replaced.
@MainActor
final class SocialInstallationFile: SocialInstallationMarker {
    let url: URL
    private var value: String?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Social/installation-v1")
    }

    func current() throws -> String {
        if let value { return value }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return try rotate()
        }
        let stored = String(decoding: data, as: UTF8.self)
        guard stored.count == 43 else { return try rotate() }
        value = stored
        return stored
    }

    func rotate() throws -> String {
        let next = SocialSecret.make()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A restored backup must not revive an earlier installation's identity.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
#if os(iOS)
        try Data(next.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try Data(next.utf8).write(to: url, options: .atomic)
#endif
        value = next
        return next
    }
}

/// Process-only marker for builds without social riding and for tests.
@MainActor
final class SocialMemoryInstallation: SocialInstallationMarker {
    private var value = SocialSecret.make()
    func current() throws -> String { value }
    func rotate() throws -> String { value = SocialSecret.make(); return value }
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
