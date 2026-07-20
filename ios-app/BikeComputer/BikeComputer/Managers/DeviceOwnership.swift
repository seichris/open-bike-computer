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
        return String(deviceID.suffix(4)).uppercased()
    }
}

struct DiscoveredBikeComputerDevice: Equatable, Identifiable {
    let peripheralIdentifier: UUID
    var advertisedName: String
    var shortIdentifier: String
    var identitySuffix: String?
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
        var identitySuffix: String?
        var isClaimed: Bool?
        if let data = manufacturerData,
           data.count == DeviceOwnershipProtocol.advertisementLength,
           data[0] == 0xFF,
           data[1] == 0xFF,
           data[2] == DeviceOwnershipProtocol.version {
            isClaimed = data[3] & DeviceOwnershipProtocol.claimedFlag != 0
            let parsedIdentitySuffix = data.subdata(in: 4..<8).ownershipHex.uppercased()
            identitySuffix = parsedIdentitySuffix
            shortIdentifier = String(parsedIdentitySuffix.suffix(4))
        }
        return DiscoveredBikeComputerDevice(
            peripheralIdentifier: peripheralIdentifier,
            advertisedName: localName.nilIfEmpty ?? "BikeComputer \(shortIdentifier.suffix(4))",
            shortIdentifier: shortIdentifier,
            identitySuffix: identitySuffix,
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
    let isReplacingExistingRegistration: Bool

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

    static func resolvedName(
        reportedName: String,
        existingName: String?,
        peripheralName: String?
    ) -> String {
        if !reportedName.isEmpty { return normalizedName(reportedName) }
        if let existingName, !existingName.isEmpty {
            return normalizedName(existingName)
        }
        if let peripheralName, !peripheralName.isEmpty {
            return normalizedName(peripheralName)
        }
        return defaultDeviceName
    }

    static func resolvedInfoName(
        reportedName: String,
        isClaimed: Bool,
        existingName: String?,
        peripheralName: String?
    ) -> String {
        resolvedName(
            reportedName: isClaimed && existingName != nil ? "" : reportedName,
            existingName: existingName,
            peripheralName: peripheralName
        )
    }
}

enum DeviceOwnershipFlowPolicy {
    static func allowsLegacyFallback(
        knownDevice: KnownBikeComputerDevice?,
        pairingCandidate: DiscoveredBikeComputerDevice?
    ) -> Bool {
        guard pairingCandidate?.isClaimed == nil else { return false }
        return knownDevice?.isLegacy == true
    }
}

enum BLEDiscoveryFreshnessPolicy {
    static let maximumAge: TimeInterval = 6

    static func retained(
        _ devices: [DiscoveredBikeComputerDevice],
        now: Date = Date(),
        maximumAge: TimeInterval = maximumAge
    ) -> [DiscoveredBikeComputerDevice] {
        devices.filter { now.timeIntervalSince($0.lastSeenAt) <= maximumAge }
    }
}

enum BikeComputersMenuPolicy {
    static func title(knownDeviceCount: Int) -> String {
        switch knownDeviceCount {
        case 0:
            return "Connect Bike Computer"
        case 1:
            return "My Bike Computer"
        default:
            return "My Bike Computers"
        }
    }

    static func shouldStartDiscoveryOnEntry(knownDeviceCount: Int) -> Bool {
        knownDeviceCount == 0
    }

    static func shouldShowConnectNewDeviceAction(knownDeviceCount: Int) -> Bool {
        knownDeviceCount > 0
    }

    static func shouldResumeOwnedDiscovery(
        ownsDiscoveryLifecycle: Bool,
        isBluetoothPoweredOn: Bool,
        isDiscoveringDevices: Bool,
        pairingCompletedDuringPresentation: Bool
    ) -> Bool {
        ownsDiscoveryLifecycle && isBluetoothPoweredOn &&
            !isDiscoveringDevices && !pairingCompletedDuringPresentation
    }
}

enum BLEPendingScanPolicy {
    static let timeout: TimeInterval = 8

    static func accepts(
        discoveredIdentifier: UUID,
        pendingIdentifier: UUID
    ) -> Bool {
        discoveredIdentifier == pendingIdentifier
    }
}

enum BLEPairingCancellationPolicy {
    static func shouldDisconnect(
        connectedPeripheralIdentifier: UUID?,
        pairingPeripheralIdentifier: UUID?,
        hasActivePairing: Bool
    ) -> Bool {
        hasActivePairing && connectedPeripheralIdentifier != nil &&
            connectedPeripheralIdentifier == pairingPeripheralIdentifier
    }
}

enum BLEOwnershipLifecyclePhase: Equatable {
    case idle
    case discovering
    case pairing(UUID)
    case comparisonReady(UUID)
    case submitting(UUID)
}

struct BLEOwnershipCancellation: Equatable {
    let pairingPeripheralIdentifier: UUID?
    let shouldDisconnectPairingPeripheral: Bool
}

/// Owns the user-driven registration lifecycle independently of CoreBluetooth.
/// BLEManager uses every transition below, while host tests can exercise the
/// same handoff, cancellation, and single-submit decisions deterministically.
struct BLEOwnershipLifecycle {
    private(set) var phase: BLEOwnershipLifecyclePhase = .idle

    mutating func beginDiscovery() {
        phase = .discovering
    }

    mutating func endDiscovery(resumeAutoReconnect: Bool) -> Bool {
        phase = .idle
        return resumeAutoReconnect
    }

    mutating func beginPairing(
        candidateIdentifier: UUID,
        connectedIdentifier: UUID?
    ) -> Bool {
        phase = .pairing(candidateIdentifier)
        return connectedIdentifier != nil &&
            connectedIdentifier != candidateIdentifier
    }

    mutating func markComparisonReady(for candidateIdentifier: UUID) -> Bool {
        guard phase == .pairing(candidateIdentifier) else { return false }
        phase = .comparisonReady(candidateIdentifier)
        return true
    }

    mutating func beginConfirmation(for candidateIdentifier: UUID) -> Bool {
        guard phase == .comparisonReady(candidateIdentifier) else { return false }
        phase = .submitting(candidateIdentifier)
        return true
    }

    mutating func cancel(connectedIdentifier: UUID?) -> BLEOwnershipCancellation {
        let candidateIdentifier: UUID?
        switch phase {
        case .pairing(let identifier),
             .comparisonReady(let identifier),
             .submitting(let identifier):
            candidateIdentifier = identifier
        case .idle, .discovering:
            candidateIdentifier = nil
        }
        let cancellation = BLEOwnershipCancellation(
            pairingPeripheralIdentifier: candidateIdentifier,
            shouldDisconnectPairingPeripheral:
                BLEPairingCancellationPolicy.shouldDisconnect(
                    connectedPeripheralIdentifier: connectedIdentifier,
                    pairingPeripheralIdentifier: candidateIdentifier,
                    hasActivePairing: candidateIdentifier != nil
                )
        )
        phase = .discovering
        return cancellation
    }

    mutating func interrupt() {
        phase = .idle
    }

    mutating func complete() {
        phase = .idle
    }
}

enum BLEIdentityObservationPolicy {
    static func conflictingDeviceIDs(
        knownDevices: [KnownBikeComputerDevice],
        peripheralIdentifier: UUID,
        observedDeviceID: String
    ) -> Set<String> {
        Set(knownDevices.compactMap { device in
            guard device.peripheralIdentifier == peripheralIdentifier,
                  device.deviceID != observedDeviceID else { return nil }
            return device.deviceID
        })
    }
}

enum BLEReconnectBackoff {
    static func delay(
        attempt: Int,
        base: TimeInterval = 1,
        maximum: TimeInterval = 60
    ) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 0), 30)
        return min(base * pow(2, Double(boundedAttempt)), maximum)
    }
}

enum BLEConnectionPersistence {
    // Trusted-device connects intentionally remain pending in CoreBluetooth so
    // iOS can complete them when the accessory reappears, including while the
    // app is suspended. Interactive pairing attempts remain bounded.
    static func shouldCancelTimedOutConnection(isPairing: Bool) -> Bool {
        isPairing
    }
}

enum BLEPendingHandoffPolicy {
    static func consume(_ pendingIdentifier: inout UUID?) -> UUID? {
        defer { pendingIdentifier = nil }
        return pendingIdentifier
    }
}

enum BLEDeviceOperationPolicy {
    static func canStartPairing(operationDeviceID: String?) -> Bool {
        operationDeviceID == nil
    }
}

enum BikeComputerRemovalAction: Equatable {
    case deregister
    case forget
}

enum BikeComputerRemovalPolicy {
    static func action(
        isConnected: Bool,
        isLegacy: Bool
    ) -> BikeComputerRemovalAction {
        isConnected && !isLegacy ? .deregister : .forget
    }
}

enum BLELocalForgetPolicy {
    static func acceptsCallback(
        peripheralIdentifier: UUID,
        currentIdentifier: UUID?,
        forgottenIdentifiers: Set<UUID>
    ) -> Bool {
        currentIdentifier == peripheralIdentifier &&
            !forgottenIdentifiers.contains(peripheralIdentifier)
    }

    static func shouldStopScanning(
        wasActive: Bool,
        hadPendingTransport: Bool,
        hasSuccessor: Bool
    ) -> Bool {
        (wasActive || hadPendingTransport) && !hasSuccessor
    }
}

enum BLENavigationNotificationPolicy {
    static func accepts(
        isAuthenticated: Bool,
        isLegacyDevice: Bool,
        hasProtectedSession: Bool,
        isProtectedFrame: Bool
    ) -> Bool {
        guard isAuthenticated else { return false }
        if hasProtectedSession { return isProtectedFrame }
        return isLegacyDevice && !isProtectedFrame
    }
}

enum BLERestorationPolicy {
    static func selectedIdentifier(
        from available: [UUID],
        trustedIdentifier: UUID?
    ) -> UUID? {
        guard let trustedIdentifier else { return nil }
        return available.contains(trustedIdentifier) ? trustedIdentifier : nil
    }

    static func identifiersToCancel(
        from available: [UUID],
        keeping selectedIdentifier: UUID
    ) -> [UUID] {
        available.filter { $0 != selectedIdentifier }
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

    func matches(peripheralIdentifier: UUID) -> Bool {
        self.peripheralIdentifier == peripheralIdentifier
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
        clientNonce: String,
        serverNonce: String
    ) -> String {
        "server2|\(deviceID)|\(ownerID.ownershipHex)|\(clientNonce)|\(serverNonce)"
    }

    static func clientMessage(
        deviceID: String,
        ownerID: Data,
        clientNonce: String,
        serverNonce: String
    ) -> String {
        "client2|\(deviceID)|\(ownerID.ownershipHex)|\(clientNonce)|\(serverNonce)"
    }

    static func revocationMessage(
        deviceID: String,
        ownerID: Data,
        nonce: String
    ) -> String {
        "revoked2|\(deviceID)|\(ownerID.ownershipHex)|\(nonce)"
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

    static func isValidRevocationReceipt(
        suppliedProof: String,
        key: Data,
        deviceID: String,
        ownerID: Data,
        nonce: String
    ) -> Bool {
        guard Data(ownershipHex: nonce)?.count == 16,
              Data(ownershipHex: suppliedProof)?.count == 32 else {
            return false
        }
        return isValidProof(
            suppliedProof,
            expected: proof(
                key: key,
                message: revocationMessage(
                    deviceID: deviceID,
                    ownerID: ownerID,
                    nonce: nonce
                )
            )
        )
    }
}

enum AuthenticatedBLEChannel: UInt8 {
    case auth = 1
    case navigation = 2
    case route = 3
    case gps = 4
    case settings = 5
}

final class AuthenticatedBLEWriteSession {
    static let frameOverhead = 22

    private let writeKey: SymmetricKey
    private let notifyKey: SymmetricKey
    private var nextSequence: [AuthenticatedBLEChannel: UInt32] = [:]
    private var lastNotificationSequence: [AuthenticatedBLEChannel: UInt32] = [:]

    init(
        ownerKey: Data,
        deviceID: String,
        clientNonce: String,
        serverNonce: String
    ) {
        let context = "\(deviceID)|\(clientNonce)|\(serverNonce)"
        writeKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(
            for: Data("session2-write|\(context)".utf8),
            using: SymmetricKey(data: ownerKey)
        ))
        notifyKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(
            for: Data("session2-notify|\(context)".utf8),
            using: SymmetricKey(data: ownerKey)
        ))
    }

    func frame(payload: Data, channel: AuthenticatedBLEChannel) -> Data? {
        let (sequence, overflow) = (nextSequence[channel] ?? 0)
            .addingReportingOverflow(1)
        guard !overflow else { return nil }
        nextSequence[channel] = sequence
        let sequenceBytes: [UInt8] = [
            UInt8((sequence >> 24) & 0xFF),
            UInt8((sequence >> 16) & 0xFF),
            UInt8((sequence >> 8) & 0xFF),
            UInt8(sequence & 0xFF)
        ]
        guard let nonce = try? AES.GCM.Nonce(data: nonceData(
            channel: channel,
            sequenceBytes: sequenceBytes
        )) else { return nil }
        let aad = authenticatedData(
            prefix: "write2|",
            channel: channel,
            sequenceBytes: sequenceBytes
        )
        guard let sealed = try? AES.GCM.seal(
            payload,
            using: writeKey,
            nonce: nonce,
            authenticating: aad
        ) else { return nil }
        var frame = Data([0x53, 0x32])
        frame.append(contentsOf: sequenceBytes)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        return frame
    }

    func notificationPayload(
        from frame: Data,
        channel: AuthenticatedBLEChannel
    ) -> Data? {
        guard frame.count >= Self.frameOverhead,
              frame[0] == 0x52, frame[1] == 0x32 else { return nil }
        let sequenceBytes = Array(frame[2..<6])
        let sequence = sequenceBytes.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard sequence > (lastNotificationSequence[channel] ?? 0),
              let nonce = try? AES.GCM.Nonce(data: nonceData(
                channel: channel,
                sequenceBytes: sequenceBytes
              )) else { return nil }
        let ciphertext = frame.subdata(in: 6..<(frame.count - 16))
        let tag = frame.suffix(16)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: notifyKey,
                authenticating: authenticatedData(
                    prefix: "notify2|",
                    channel: channel,
                    sequenceBytes: sequenceBytes
                )
            )
            lastNotificationSequence[channel] = sequence
            return plaintext
        } catch {
            return nil
        }
    }

    private func nonceData(
        channel: AuthenticatedBLEChannel,
        sequenceBytes: [UInt8]
    ) -> Data {
        Data([channel.rawValue, 0, 0, 0, 0, 0, 0, 0] + sequenceBytes)
    }

    private func authenticatedData(
        prefix: String,
        channel: AuthenticatedBLEChannel,
        sequenceBytes: [UInt8]
    ) -> Data {
        var data = Data(prefix.utf8)
        data.append(channel.rawValue)
        data.append(contentsOf: sequenceBytes)
        return data
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
    var shouldFailRemoval = false
    func data(account: String) -> Data? { values[account] }
    func set(_ data: Data, account: String) -> Bool {
        values[account] = data
        return true
    }
    func remove(account: String) -> Bool {
        if shouldFailRemoval { return false }
        values.removeValue(forKey: account)
        return true
    }
}
#endif

final class BikeComputerDeviceRegistry {
    private enum Keys {
        static let devices = "ble.knownDevices.v2"
        static let activeDeviceID = "ble.activeDeviceID.v2"
        static func provisionalConfirmed(deviceID: String) -> String {
            "ble.provisionalOwnerConfirmed.\(deviceID)"
        }
        static func provisionalReplacementAuthorized(deviceID: String) -> String {
            "ble.provisionalReplacementAuthorized.\(deviceID)"
        }
        static let installationOwnerID = "installation-owner-id"
        static func ownerKey(deviceID: String) -> String { "owner-key-\(deviceID)" }
        static func provisionalOwnerKey(deviceID: String) -> String {
            "provisional-owner-key-\(deviceID)"
        }
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

    func provisionalOwnerKey(deviceID: String) -> Data? {
        credentialStore.data(account: Keys.provisionalOwnerKey(deviceID: deviceID))
    }

    @discardableResult
    func saveProvisionalOwnerKey(_ key: Data, deviceID: String) -> Bool {
        guard key.count == DeviceOwnershipProtocol.ownerKeyLength else { return false }
        defaults.removeObject(forKey: Keys.provisionalConfirmed(deviceID: deviceID))
        defaults.removeObject(
            forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
        )
        return credentialStore.set(
            key,
            account: Keys.provisionalOwnerKey(deviceID: deviceID)
        )
    }

    func markProvisionalOwnerKeyConfirmed(deviceID: String) {
        defaults.set(true, forKey: Keys.provisionalConfirmed(deviceID: deviceID))
    }

    func isProvisionalOwnerKeyConfirmed(deviceID: String) -> Bool {
        defaults.bool(forKey: Keys.provisionalConfirmed(deviceID: deviceID))
    }

    func authorizeProvisionalCredentialReplacement(deviceID: String) {
        defaults.set(
            true,
            forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
        )
    }

    func isProvisionalCredentialReplacementAuthorized(
        deviceID: String
    ) -> Bool {
        defaults.bool(
            forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
        )
    }

    func hasConfirmedReplacementCredential(deviceID: String) -> Bool {
        isProvisionalOwnerKeyConfirmed(deviceID: deviceID) &&
            isProvisionalCredentialReplacementAuthorized(deviceID: deviceID) &&
            provisionalOwnerKey(deviceID: deviceID) != nil
    }

    @discardableResult
    func promoteProvisionalOwnerKey(
        deviceID: String,
        allowReplacingExisting: Bool = false
    ) -> Bool {
        guard let key = provisionalOwnerKey(deviceID: deviceID) else {
            return false
        }
        // A stable DeviceID is an identifier, not proof of continuity. Never
        // let an ordinary pairing flow replace a different credential for the
        // same ID; that requires an explicit recovery/reset flow.
        if let existing = ownerKey(deviceID: deviceID),
           existing != key,
           !allowReplacingExisting {
            return false
        }
        guard saveOwnerKey(key, deviceID: deviceID) else { return false }
        let removed = credentialStore.remove(
            account: Keys.provisionalOwnerKey(deviceID: deviceID)
        )
        if removed {
            defaults.removeObject(forKey: Keys.provisionalConfirmed(deviceID: deviceID))
            defaults.removeObject(
                forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
            )
        }
        return removed
    }

    func removeProvisionalOwnerKey(deviceID: String) {
        credentialStore.remove(
            account: Keys.provisionalOwnerKey(deviceID: deviceID)
        )
        defaults.removeObject(forKey: Keys.provisionalConfirmed(deviceID: deviceID))
        defaults.removeObject(
            forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
        )
    }

    func upsert(_ device: KnownBikeComputerDevice, makeActive: Bool = false) {
        let previous = devices
        let replacedActiveAlias = previous.contains {
            $0.peripheralIdentifier == device.peripheralIdentifier &&
                $0.deviceID == activeDeviceID
        }
        var current = previous.filter {
            $0.deviceID != device.deviceID &&
                $0.peripheralIdentifier != device.peripheralIdentifier
        }
        current.append(device)
        devices = current
        if makeActive || activeDeviceID == nil || replacedActiveAlias ||
            !current.contains(where: { $0.deviceID == activeDeviceID }) {
            activeDeviceID = device.deviceID
        }
    }

    @discardableResult
    func remove(deviceID: String) -> Bool {
        let ownerAccount = Keys.ownerKey(deviceID: deviceID)
        let provisionalAccount = Keys.provisionalOwnerKey(deviceID: deviceID)
        let ownerKey = credentialStore.data(account: ownerAccount)
        let provisionalKey = credentialStore.data(account: provisionalAccount)

        let removedOwner = credentialStore.remove(account: ownerAccount)
        let removedProvisional = credentialStore.remove(account: provisionalAccount)
        guard removedOwner && removedProvisional else {
            // Keychain has no transaction primitive. Restore whichever secrets
            // were present so a partial deletion cannot hide a device while
            // leaving the registry and credentials out of sync.
            if let ownerKey {
                _ = credentialStore.set(ownerKey, account: ownerAccount)
            }
            if let provisionalKey {
                _ = credentialStore.set(provisionalKey, account: provisionalAccount)
            }
            return false
        }

        devices = devices.filter { $0.deviceID != deviceID }
        defaults.removeObject(forKey: Keys.provisionalConfirmed(deviceID: deviceID))
        defaults.removeObject(
            forKey: Keys.provisionalReplacementAuthorized(deviceID: deviceID)
        )
        if activeDeviceID == deviceID {
            activeDeviceID = devices.first?.deviceID
        }
        return true
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
