import Foundation
import CoreBluetooth
import CryptoKit
import Security

struct KnownBikeComputerDevice: Codable, Equatable, Identifiable {
    let deviceID: String
    var peripheralIdentifier: UUID
    var name: String
    var lastConnectedAt: Date
    var isLegacy: Bool

    var id: String { deviceID }

    var shortIdentifier: String {
        guard !isLegacy, deviceID.count >= 8 else {
            return String(peripheralIdentifier.uuidString.prefix(4)).uppercased()
        }
        return String(deviceID.suffix(8)).uppercased()
    }
}

struct DiscoveredBikeComputerDevice: Equatable, Identifiable {
    let peripheralIdentifier: UUID
    var advertisedName: String
    var shortIdentifier: String
    var isClaimed: Bool?
    var rssi: Int
    var lastSeenAt: Date

    var id: UUID { peripheralIdentifier }

    static func parse(
        peripheralIdentifier: UUID,
        localName: String?,
        manufacturerData: Data?,
        rssi: Int,
        now: Date = Date()
    ) -> DiscoveredBikeComputerDevice {
        var shortIdentifier = String(peripheralIdentifier.uuidString.prefix(4)).uppercased()
        var isClaimed: Bool?
        if let data = manufacturerData,
           data.count == DeviceOwnershipProtocol.advertisementLength,
           data[0] == 0xFF,
           data[1] == 0xFF,
           data[2] == DeviceOwnershipProtocol.version {
            isClaimed = data[3] & DeviceOwnershipProtocol.claimedFlag != 0
            shortIdentifier = data.subdata(in: 4..<8).ownershipHex.uppercased()
        }
        return DiscoveredBikeComputerDevice(
            peripheralIdentifier: peripheralIdentifier,
            advertisedName: localName.nilIfEmpty ?? "BikeComputer \(shortIdentifier.suffix(4))",
            shortIdentifier: shortIdentifier,
            isClaimed: isClaimed,
            rssi: rssi,
            lastSeenAt: now
        )
    }
}

struct BikeComputerPairingPrompt: Equatable, Identifiable {
    let peripheralIdentifier: UUID
    let deviceName: String
    let shortIdentifier: String
    let comparisonCode: Int

    var id: UUID { peripheralIdentifier }
    var formattedCode: String { String(format: "%06d", comparisonCode) }
}

enum DeviceOwnershipProtocol {
    static let version: UInt8 = 2
    static let advertisementLength = 8
    static let claimedFlag: UInt8 = 1
    static let ownerIDLength = 16
    static let deviceIDLength = 16
    static let ownerKeyLength = 32
    static let publicKeyLength = 65
    static let maximumNameBytes = 24
    static let defaultDeviceName = "My bike"

    static func normalizedName(_ proposedName: String) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDeviceName }
        var result = ""
        for character in trimmed {
            let characterText = String(character)
            let bytes = characterText.utf8
            guard !bytes.contains(where: { $0 == 0 || $0 == 0x7C || $0 < 0x20 || $0 == 0x7F }) else {
                continue
            }
            let candidate = result + characterText
            guard candidate.utf8.count <= maximumNameBytes else { break }
            result = candidate
        }
        return result.isEmpty ? defaultDeviceName : result
    }
}

enum DeviceOwnershipCryptoError: Error, Equatable {
    case invalidOwnerID
    case invalidDeviceID
    case invalidPublicKey
    case invalidResponse
}

struct DevicePairingMaterial {
    let deviceID: String
    let ownerKey: Data
    let comparisonCode: Int
    let confirmationCommand: String
}

struct DevicePairingSession {
    let peripheralIdentifier: UUID
    let ownerID: Data
    let deviceName: String
    private let privateKey: P256.KeyAgreement.PrivateKey

    init(peripheralIdentifier: UUID, ownerID: Data, deviceName: String) throws {
        guard ownerID.count == DeviceOwnershipProtocol.ownerIDLength else {
            throw DeviceOwnershipCryptoError.invalidOwnerID
        }
        self.peripheralIdentifier = peripheralIdentifier
        self.ownerID = ownerID
        self.deviceName = DeviceOwnershipProtocol.normalizedName(deviceName)
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    init(
        peripheralIdentifier: UUID,
        ownerID: Data,
        deviceName: String,
        privateKeyRawRepresentation: Data
    ) throws {
        guard ownerID.count == DeviceOwnershipProtocol.ownerIDLength else {
            throw DeviceOwnershipCryptoError.invalidOwnerID
        }
        self.peripheralIdentifier = peripheralIdentifier
        self.ownerID = ownerID
        self.deviceName = DeviceOwnershipProtocol.normalizedName(deviceName)
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
    }

    var pairingCommand: String {
        "PAIR|\(ownerID.ownershipHex)|\(privateKey.publicKey.x963Representation.ownershipHex)"
    }

    func material(from response: String) throws -> DevicePairingMaterial {
        let parts = response.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "PAIRING",
              let deviceID = Data(ownershipHex: parts[1]),
              deviceID.count == DeviceOwnershipProtocol.deviceIDLength,
              let devicePublicData = Data(ownershipHex: parts[2]),
              devicePublicData.count == DeviceOwnershipProtocol.publicKeyLength else {
            throw DeviceOwnershipCryptoError.invalidResponse
        }
        let devicePublicKey: P256.KeyAgreement.PublicKey
        do {
            devicePublicKey = try P256.KeyAgreement.PublicKey(x963Representation: devicePublicData)
        } catch {
            throw DeviceOwnershipCryptoError.invalidPublicKey
        }
        let appPublicData = privateKey.publicKey.x963Representation
        let transcriptHash = Self.transcriptHash(
            deviceID: deviceID,
            ownerID: ownerID,
            appPublicKey: appPublicData,
            devicePublicKey: devicePublicData
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
        let ownerKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("BikeComputer owner key v2".utf8),
            outputByteCount: DeviceOwnershipProtocol.ownerKeyLength
        )
        let ownerKeyData = ownerKey.withUnsafeBytes { Data($0) }
        var comparisonMessage = Data("compare|".utf8)
        comparisonMessage.append(transcriptHash)
        let comparisonDigest = Self.hmac(key: ownerKeyData, message: comparisonMessage)
        let comparisonValue = comparisonDigest.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        var confirmationMessage = Data("claim|".utf8)
        confirmationMessage.append(transcriptHash)
        let proof = Self.hmac(key: ownerKeyData, message: confirmationMessage)
        return DevicePairingMaterial(
            deviceID: parts[1].lowercased(),
            ownerKey: ownerKeyData,
            comparisonCode: Int(comparisonValue % 1_000_000),
            confirmationCommand: "CONFIRM|\(ownerID.ownershipHex)|\(proof.ownershipHex)|\(Data(deviceName.utf8).ownershipHex)"
        )
    }

    private static func transcriptHash(
        deviceID: Data,
        ownerID: Data,
        appPublicKey: Data,
        devicePublicKey: Data
    ) -> Data {
        var transcript = Data("BikeComputer ownership v2".utf8)
        transcript.append(deviceID)
        transcript.append(ownerID)
        transcript.append(appPublicKey)
        transcript.append(devicePublicKey)
        return Data(SHA256.hash(data: transcript))
    }

    private static func hmac(key: Data, message: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }
}

enum DeviceOwnerAuthenticator {
    static func serverMessage(
        deviceID: String,
        ownerID: Data,
        nonce: String
    ) -> String {
        "server2|\(deviceID)|\(ownerID.ownershipHex)|\(nonce)"
    }

    static func clientMessage(
        deviceID: String,
        ownerID: Data,
        nonce: String
    ) -> String {
        "client2|\(deviceID)|\(ownerID.ownershipHex)|\(nonce)"
    }

    static func proof(key: Data, message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )).ownershipHex
    }

    static func isValidProof(_ supplied: String, expected: String) -> Bool {
        guard let suppliedData = Data(ownershipHex: supplied),
              let expectedData = Data(ownershipHex: expected),
              suppliedData.count == expectedData.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in suppliedData.indices {
            difference |= suppliedData[index] ^ expectedData[index]
        }
        return difference == 0
    }
}

protocol DeviceCredentialStoring {
    func data(account: String) -> Data?
    @discardableResult func set(_ data: Data, account: String) -> Bool
    @discardableResult func remove(account: String) -> Bool
}

final class KeychainDeviceCredentialStore: DeviceCredentialStoring {
    private let service = "LetItRide.BikeComputer.device-ownership.v2"

    func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    @discardableResult
    func set(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

#if HOST_TESTING
final class InMemoryDeviceCredentialStore: DeviceCredentialStoring {
    private var values: [String: Data] = [:]
    func data(account: String) -> Data? { values[account] }
    func set(_ data: Data, account: String) -> Bool {
        values[account] = data
        return true
    }
    func remove(account: String) -> Bool {
        values.removeValue(forKey: account)
        return true
    }
}
#endif

final class BikeComputerDeviceRegistry {
    private enum Keys {
        static let devices = "ble.knownDevices.v2"
        static let activeDeviceID = "ble.activeDeviceID.v2"
        static let installationOwnerID = "installation-owner-id"
        static func ownerKey(deviceID: String) -> String { "owner-key-\(deviceID)" }
    }

    private let defaults: UserDefaults
    private let credentialStore: DeviceCredentialStoring

    init(
        defaults: UserDefaults = .standard,
        credentialStore: DeviceCredentialStoring? = nil
    ) {
        self.defaults = defaults
#if HOST_TESTING
        self.credentialStore = credentialStore ?? InMemoryDeviceCredentialStore()
#else
        self.credentialStore = credentialStore ?? KeychainDeviceCredentialStore()
#endif
    }

    var devices: [KnownBikeComputerDevice] {
        get {
            guard let data = defaults.data(forKey: Keys.devices),
                  let devices = try? JSONDecoder().decode([KnownBikeComputerDevice].self, from: data) else {
                return []
            }
            return devices.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.devices)
        }
    }

    var activeDeviceID: String? {
        get { defaults.string(forKey: Keys.activeDeviceID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.activeDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.activeDeviceID)
            }
        }
    }

    func installationOwnerID() -> Data? {
        if let existing = credentialStore.data(account: Keys.installationOwnerID),
           existing.count == DeviceOwnershipProtocol.ownerIDLength {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: DeviceOwnershipProtocol.ownerIDLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let ownerID = Data(bytes)
        return credentialStore.set(ownerID, account: Keys.installationOwnerID) ? ownerID : nil
    }

    func ownerKey(deviceID: String) -> Data? {
        credentialStore.data(account: Keys.ownerKey(deviceID: deviceID))
    }

    @discardableResult
    func saveOwnerKey(_ key: Data, deviceID: String) -> Bool {
        guard key.count == DeviceOwnershipProtocol.ownerKeyLength else { return false }
        return credentialStore.set(key, account: Keys.ownerKey(deviceID: deviceID))
    }

    func upsert(_ device: KnownBikeComputerDevice, makeActive: Bool = false) {
        var current = devices.filter { $0.deviceID != device.deviceID }
        current.append(device)
        devices = current
        if makeActive || activeDeviceID == nil {
            activeDeviceID = device.deviceID
        }
    }

    func remove(deviceID: String) {
        devices = devices.filter { $0.deviceID != deviceID }
        credentialStore.remove(account: Keys.ownerKey(deviceID: deviceID))
        if activeDeviceID == deviceID {
            activeDeviceID = devices.first?.deviceID
        }
    }
}

extension Data {
    init?(ownershipHex: String) {
        guard ownershipHex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: ownershipHex.count / 2)
        var index = ownershipHex.startIndex
        while index < ownershipHex.endIndex {
            let next = ownershipHex.index(index, offsetBy: 2)
            guard let byte = UInt8(ownershipHex[index..<next], radix: 16) else {
                return nil
            }
            append(byte)
            index = next
        }
    }

    var ownershipHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
