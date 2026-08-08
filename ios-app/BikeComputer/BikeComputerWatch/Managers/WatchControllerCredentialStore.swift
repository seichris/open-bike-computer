import Foundation
import Security

enum WatchControllerCredentialStoreError: Error {
    case keychain(OSStatus)
    case missingPendingCredential
    case identityMismatch
    case invalidCredential
}

/// Stores scoped Bike Computer keys only in this Apple Watch's data-protection
/// Keychain. Credentials are explicitly non-synchronizing and device-only.
final class WatchControllerCredentialStore {
    private enum Slot: String {
        case active
        case pending
    }

    private let service =
        "com.openbikecomputer.watch.scoped-controller.v1"

    func activeCredential(
        deviceID: String
    ) throws -> WatchControllerCredentialV1? {
        try credential(deviceID: deviceID, slot: .active)
    }

    func pendingCredential(
        deviceID: String
    ) throws -> WatchControllerCredentialV1? {
        try credential(deviceID: deviceID, slot: .pending)
    }

    func allActiveCredentials() throws -> [WatchControllerCredentialV1] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let records = item as? [[String: Any]] else {
            throw WatchControllerCredentialStoreError.keychain(status)
        }
        return try records.compactMap { record in
            guard let account = record[kSecAttrAccount as String] as? String,
                  account.hasPrefix("\(Slot.active.rawValue):") else {
                return nil
            }
            guard let data = record[kSecValueData as String] as? Data else {
                throw WatchControllerCredentialStoreError.invalidCredential
            }
            do {
                return try PropertyListDecoder()
                    .decode(WatchControllerCredentialV1.self, from: data)
                    .validated()
            } catch {
                throw WatchControllerCredentialStoreError.invalidCredential
            }
        }.sorted { $0.deviceID < $1.deviceID }
    }

    func stage(_ credential: WatchControllerCredentialV1) throws {
        try store(credential.validated(), slot: .pending)
    }

    func promote(deviceID: String, controllerID: Data) throws {
        guard let pending = try pendingCredential(deviceID: deviceID) else {
            if try activeCredential(deviceID: deviceID)?.controllerID ==
                controllerID {
                return
            }
            throw WatchControllerCredentialStoreError.missingPendingCredential
        }
        guard pending.controllerID == controllerID else {
            throw WatchControllerCredentialStoreError.identityMismatch
        }
        try store(pending, slot: .active)
        try delete(deviceID: deviceID, slot: .pending)
    }

    func revoke(deviceID: String, controllerID: Data) throws {
        for slot in [Slot.active, .pending] {
            guard let credential = try credential(
                deviceID: deviceID,
                slot: slot
            ), credential.controllerID == controllerID else {
                continue
            }
            try delete(deviceID: deviceID, slot: slot)
        }
    }

    private func account(deviceID: String, slot: Slot) -> String {
        "\(slot.rawValue):\(deviceID.lowercased())"
    }

    private func baseQuery(
        deviceID: String,
        slot: Slot
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(
                deviceID: deviceID,
                slot: slot
            ),
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func credential(
        deviceID: String,
        slot: Slot
    ) throws -> WatchControllerCredentialV1? {
        var query = baseQuery(deviceID: deviceID, slot: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw WatchControllerCredentialStoreError.keychain(status)
        }
        do {
            return try PropertyListDecoder()
                .decode(WatchControllerCredentialV1.self, from: data)
                .validated()
        } catch {
            throw WatchControllerCredentialStoreError.invalidCredential
        }
    }

    private func store(
        _ credential: WatchControllerCredentialV1,
        slot: Slot
    ) throws {
        let data = try PropertyListEncoder().encode(credential.validated())
        let query = baseQuery(deviceID: credential.deviceID, slot: slot)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WatchControllerCredentialStoreError.keychain(updateStatus)
        }
        var insert = query
        for (key, value) in attributes {
            insert[key] = value
        }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WatchControllerCredentialStoreError.keychain(addStatus)
        }
    }

    private func delete(deviceID: String, slot: Slot) throws {
        let status = SecItemDelete(
            baseQuery(deviceID: deviceID, slot: slot) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WatchControllerCredentialStoreError.keychain(status)
        }
    }
}
