import CryptoKit
import Foundation

enum WatchDirectBLEProtocolV1 {
    static let serviceUUID = RideBLEGeneratedProtocolV1.serviceUUID
    static let navigationUUID = RideBLEGeneratedProtocolV1.navigationUUID
    static let routeUUID = RideBLEGeneratedProtocolV1.routeUUID
    static let gpsUUID = RideBLEGeneratedProtocolV1.gpsUUID
    static let authUUID = RideBLEGeneratedProtocolV1.authUUID
    static let workoutUUID = RideBLEGeneratedProtocolV1.workoutUUID
    static let rideAutomationUUID = RideBLEGeneratedProtocolV1
        .rideAutomationUUID
    static let capabilityClientVersion = RideBLEGeneratedProtocolV1
        .currentClientVersion
    static let scopedControllerFeature = RideBLEGeneratedProtocolV1
        .scopedWatchControllerFeature
    static let workoutTelemetryFeature = RideBLEGeneratedProtocolV1
        .workoutTelemetryFeature
    static let rideAutomationFeature = RideBLEGeneratedProtocolV1
        .rideAutomationV2Feature
    static let gpsPositionQualityV1Feature = RideBLEGeneratedProtocolV1
        .gpsPositionQualityV1Feature
    static let rideDeliveryAcknowledgementFeature =
        RideBLEGeneratedProtocolV1.rideDeliveryAckFeature
    static let watchGPSMotionEvidenceV1Feature =
        RideBLEGeneratedProtocolV1.watchGpsMotionEvidenceV1Feature
    static let protectedFrameOverhead = RideBLEGeneratedProtocolV1
        .protectedFrameOverhead
}

typealias WatchAuthenticatedBLEChannelV1 =
    RideBLEGeneratedProtectedChannelV1

enum WatchScopedAuthenticationErrorV1: Error, Equatable {
    case invalidNonce
    case invalidResponse
    case identityMismatch
    case invalidServerProof
    case invalidConfirmation
    case sequenceExhausted
    case encryptionFailed
}

struct WatchScopedAuthenticationV1 {
    let credential: WatchControllerCredentialV1
    let clientNonceHex: String

    init(
        credential: WatchControllerCredentialV1,
        clientNonce: Data
    ) throws {
        self.credential = try credential.validated()
        guard clientNonce.count == 16 else {
            throw WatchScopedAuthenticationErrorV1.invalidNonce
        }
        clientNonceHex = clientNonce.watchControllerHex
    }

    var hello: String {
        "WATCH|\(credential.controllerIDHex)|\(clientNonceHex)"
    }

    func acceptServer(
        _ response: String
    ) throws -> WatchScopedAuthenticationChallengeV1 {
        let parts = response.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 5,
              parts[0] == "WS2",
              parts[1] == credential.controllerIDHex,
              parts[2] == clientNonceHex,
              Self.isHex(parts[3], byteCount: 16),
              Self.isHex(parts[4], byteCount: 32) else {
            throw WatchScopedAuthenticationErrorV1.invalidResponse
        }
        let serverMessage =
            "watch-server1|\(credential.deviceID)|" +
            "\(credential.controllerIDHex)|\(clientNonceHex)|\(parts[3])"
        let expectedServerProof = Self.hmacHex(
            key: credential.key,
            message: serverMessage
        )
        guard Self.constantTimeEqual(parts[4], expectedServerProof) else {
            throw WatchScopedAuthenticationErrorV1.invalidServerProof
        }
        let clientMessage =
            "watch-client1|\(credential.deviceID)|" +
            "\(credential.controllerIDHex)|\(clientNonceHex)|\(parts[3])"
        let proof = Self.hmacHex(
            key: credential.key,
            message: clientMessage
        )
        return WatchScopedAuthenticationChallengeV1(
            clientNonceHex: clientNonceHex,
            serverNonceHex: parts[3],
            proofCommand:
                "WATCH_PROOF|\(credential.controllerIDHex)|" +
                "\(clientNonceHex)|\(parts[3])|\(proof)"
        )
    }

    func finish(
        _ response: String,
        challenge: WatchScopedAuthenticationChallengeV1
    ) throws -> WatchAuthenticatedBLESessionV1 {
        guard challenge.clientNonceHex == clientNonceHex else {
            throw WatchScopedAuthenticationErrorV1.identityMismatch
        }
        let parts = response.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 3,
              parts[0] == "WOK2",
              parts[1] == clientNonceHex,
              parts[2] == challenge.serverNonceHex else {
            throw WatchScopedAuthenticationErrorV1.invalidConfirmation
        }
        return WatchAuthenticatedBLESessionV1(
            controllerKey: credential.key,
            deviceID: credential.deviceID,
            controllerIDHex: credential.controllerIDHex,
            clientNonceHex: clientNonceHex,
            serverNonceHex: challenge.serverNonceHex
        )
    }

    private static func hmacHex(key: Data, message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )).watchControllerHex
    }

    private static func isHex(_ value: String, byteCount: Int) -> Bool {
        value.count == byteCount * 2 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func constantTimeEqual(
        _ left: String,
        _ right: String
    ) -> Bool {
        let left = Array(left.utf8)
        let right = Array(right.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

struct WatchScopedAuthenticationChallengeV1: Equatable {
    let clientNonceHex: String
    let serverNonceHex: String
    let proofCommand: String
}

final class WatchAuthenticatedBLESessionV1 {
    private let writeKey: SymmetricKey
    private let notifyKey: SymmetricKey
    private var nextWriteSequence:
        [WatchAuthenticatedBLEChannelV1: UInt32] = [:]
    private var lastNotificationSequence:
        [WatchAuthenticatedBLEChannelV1: UInt32] = [:]

    init(
        controllerKey: Data,
        deviceID: String,
        controllerIDHex: String,
        clientNonceHex: String,
        serverNonceHex: String
    ) {
        let context =
            "\(deviceID)|\(controllerIDHex)|" +
            "\(clientNonceHex)|\(serverNonceHex)"
        writeKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(
            for: Data("watch-session-write|\(context)".utf8),
            using: SymmetricKey(data: controllerKey)
        ))
        notifyKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(
            for: Data("watch-session-notify|\(context)".utf8),
            using: SymmetricKey(data: controllerKey)
        ))
    }

    func frame(
        payload: Data,
        channel: WatchAuthenticatedBLEChannelV1
    ) throws -> Data {
        let (sequence, overflow) = (nextWriteSequence[channel] ?? 0)
            .addingReportingOverflow(1)
        guard !overflow else {
            throw WatchScopedAuthenticationErrorV1.sequenceExhausted
        }
        let sequenceBytes = Self.sequenceBytes(sequence)
        let nonce = try AES.GCM.Nonce(data: Self.nonce(
            channel: channel,
            sequenceBytes: sequenceBytes
        ))
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                payload,
                using: writeKey,
                nonce: nonce,
                authenticating: Self.authenticatedData(
                    prefix: "write2|",
                    channel: channel,
                    sequenceBytes: sequenceBytes
                )
            )
        } catch {
            throw WatchScopedAuthenticationErrorV1.encryptionFailed
        }
        nextWriteSequence[channel] = sequence
        var result = Data([0x53, 0x32])
        result.append(contentsOf: sequenceBytes)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    func notificationPayload(
        from frame: Data,
        channel: WatchAuthenticatedBLEChannelV1
    ) -> Data? {
        guard frame.count >= WatchDirectBLEProtocolV1.protectedFrameOverhead,
              frame[0] == 0x52,
              frame[1] == 0x32 else { return nil }
        let sequenceBytes = Array(frame[2..<6])
        let sequence = sequenceBytes.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard sequence > (lastNotificationSequence[channel] ?? 0),
              let nonce = try? AES.GCM.Nonce(data: Self.nonce(
                channel: channel,
                sequenceBytes: sequenceBytes
              )) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: frame.subdata(in: 6..<(frame.count - 16)),
                tag: frame.suffix(16)
            )
            let plaintext = try AES.GCM.open(
                box,
                using: notifyKey,
                authenticating: Self.authenticatedData(
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

    private static func sequenceBytes(_ sequence: UInt32) -> [UInt8] {
        [
            UInt8((sequence >> 24) & 0xFF),
            UInt8((sequence >> 16) & 0xFF),
            UInt8((sequence >> 8) & 0xFF),
            UInt8(sequence & 0xFF),
        ]
    }

    private static func nonce(
        channel: WatchAuthenticatedBLEChannelV1,
        sequenceBytes: [UInt8]
    ) -> Data {
        Data([channel.rawValue, 0, 0, 0, 0, 0, 0, 0] + sequenceBytes)
    }

    private static func authenticatedData(
        prefix: String,
        channel: WatchAuthenticatedBLEChannelV1,
        sequenceBytes: [UInt8]
    ) -> Data {
        var result = Data(prefix.utf8)
        result.append(channel.rawValue)
        result.append(contentsOf: sequenceBytes)
        return result
    }
}

struct WatchDeviceCapabilitiesV1: Equatable {
    let featureFlags: UInt32

    var supportsScopedController: Bool {
        featureFlags & WatchDirectBLEProtocolV1.scopedControllerFeature != 0
    }

    var supportsWorkoutTelemetry: Bool {
        featureFlags & WatchDirectBLEProtocolV1.workoutTelemetryFeature != 0
    }

    var supportsRideAutomation: Bool {
        featureFlags & WatchDirectBLEProtocolV1.rideAutomationFeature != 0
    }

    var supportsGPSPositionQualityV1: Bool {
        featureFlags & WatchDirectBLEProtocolV1.gpsPositionQualityV1Feature != 0
    }

    var supportsRideDeliveryAcknowledgement: Bool {
        featureFlags &
            WatchDirectBLEProtocolV1.rideDeliveryAcknowledgementFeature != 0
    }

    var supportsWatchGPSMotionEvidenceV1: Bool {
        featureFlags &
            WatchDirectBLEProtocolV1.watchGPSMotionEvidenceV1Feature != 0
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count >= 9,
              data.prefix(4) == Data("CAP2".utf8),
              data[4] == 1 else { return nil }
        let flags = UInt32(data[5]) |
            (UInt32(data[6]) << 8) |
            (UInt32(data[7]) << 16) |
            (UInt32(data[8]) << 24)
        var offset = 9
        var seen = Set<UInt8>()
        while offset < data.count {
            guard offset + 2 <= data.count else { return nil }
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard seen.insert(type).inserted,
                  offset + length <= data.count else { return nil }
            if type == 1, length != 3 { return nil }
            offset += length
        }
        return Self(featureFlags: flags)
    }
}

struct RideBLEApplicationCommandEnvelopeV1: Equatable, Sendable {
    static let prefix = Data(
        RideBLEGeneratedProtocolV1.applicationCommandMagic.utf8
    )
    static let version = RideBLEGeneratedProtocolV1
        .applicationDeliveryVersion
    static let headerLength = RideBLEGeneratedProtocolV1
        .applicationCommandHeaderBytes

    let commandType: RideBLEApplicationCommandTypeV1
    let memberIndex: UInt8
    let memberCount: UInt8
    let commandID: UUID
    let stateGeneration: UInt32
    let payload: Data

    func encoded() -> Data? {
        guard memberCount > 0,
              memberCount <= UInt8(
                RideBLEGeneratedProtocolV1.maximumApplicationGroupMembers
              ),
              memberIndex < memberCount,
              Self.isNonzero(commandID),
              stateGeneration != 0 else { return nil }
        var result = Self.prefix
        result.append(Self.version)
        result.append(commandType.rawValue)
        result.append(memberIndex)
        result.append(memberCount)
        result.append(contentsOf: Self.uuidBytes(commandID))
        result.appendUInt32LE(stateGeneration)
        result.append(payload)
        return result
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count >= headerLength,
              data.prefix(4) == prefix,
              data[4] == version,
              let commandType = RideBLEApplicationCommandTypeV1(
                rawValue: data[5]
              ), data[7] > 0,
              data[7] <= UInt8(
                RideBLEGeneratedProtocolV1.maximumApplicationGroupMembers
              ),
              data[6] < data[7],
              let commandID = uuid(from: data[8..<24]),
              isNonzero(commandID),
              data.uint32LE(at: 24) != 0 else { return nil }
        return Self(
            commandType: commandType,
            memberIndex: data[6],
            memberCount: data[7],
            commandID: commandID,
            stateGeneration: data.uint32LE(at: 24),
            payload: Data(data.dropFirst(headerLength))
        )
    }

    fileprivate static func uuidBytes(_ value: UUID) -> [UInt8] {
        withUnsafeBytes(of: value.uuid) { Array($0) }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    fileprivate static func isNonzero(_ value: UUID) -> Bool {
        value != zeroUUID
    }

    fileprivate static func uuid(from data: Data.SubSequence) -> UUID? {
        let bytes = Array(data)
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct RideBLEApplicationAcknowledgementV1: Equatable, Sendable {
    static let prefix = Data(
        RideBLEGeneratedProtocolV1.applicationAcknowledgementMagic.utf8
    )
    static let version = RideBLEGeneratedProtocolV1
        .applicationDeliveryVersion
    static let encodedLength = RideBLEGeneratedProtocolV1
        .applicationAcknowledgementBytes

    let commandType: RideBLEApplicationCommandTypeV1
    let result: RideBLEApplicationResultV1
    let commandID: UUID
    let stateGeneration: UInt32
    let leaseGeneration: UInt32

    func encoded() -> Data {
        var data = Self.prefix
        data.append(Self.version)
        data.append(commandType.rawValue)
        data.append(result.rawValue)
        data.append(0)
        data.append(contentsOf:
            RideBLEApplicationCommandEnvelopeV1.uuidBytes(commandID))
        data.appendUInt32LE(stateGeneration)
        data.appendUInt32LE(leaseGeneration)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count == encodedLength,
              data.prefix(4) == prefix,
              data[4] == version,
              data[7] == 0,
              let commandType = RideBLEApplicationCommandTypeV1(
                rawValue: data[5]
              ), let result = RideBLEApplicationResultV1(rawValue: data[6]),
              let commandID = RideBLEApplicationCommandEnvelopeV1.uuid(
                from: data[8..<24]
              ), RideBLEApplicationCommandEnvelopeV1.isNonzero(commandID),
              data.uint32LE(at: 24) != 0 else { return nil }
        return Self(
            commandType: commandType,
            result: result,
            commandID: commandID,
            stateGeneration: data.uint32LE(at: 24),
            leaseGeneration: data.uint32LE(at: 28)
        )
    }
}

struct RideBLEApplicationPendingIdentityV1: Equatable, Sendable {
    let commandType: RideBLEApplicationCommandTypeV1
    let commandID: UUID
    let stateGeneration: UInt32
}

enum RideBLEApplicationAcknowledgementDispositionV1: Equatable, Sendable {
    case ignored
    case completed(result: RideBLEApplicationResultV1)
    case rejected(result: RideBLEApplicationResultV1)
    case invalidLeaseGeneration
}

enum RideBLEApplicationAcknowledgementPolicyV1 {
    static func disposition(
        pending: RideBLEApplicationPendingIdentityV1,
        acknowledgement: RideBLEApplicationAcknowledgementV1
    ) -> RideBLEApplicationAcknowledgementDispositionV1 {
        guard pending.commandID == acknowledgement.commandID,
              pending.commandType == acknowledgement.commandType,
              pending.stateGeneration == acknowledgement.stateGeneration else {
            return .ignored
        }
        guard acknowledgement.leaseGeneration != 0 else {
            return .invalidLeaseGeneration
        }
        switch acknowledgement.result {
        case .success, .stale:
            return .completed(result: acknowledgement.result)
        case .busy, .unauthorized, .malformed, .resourceRejected:
            return .rejected(result: acknowledgement.result)
        }
    }
}

enum RideBLEApplicationTimeoutActionV1: Equatable, Sendable {
    case retry
    case recoverTransport
}

enum RideBLEApplicationRetryPolicyV1 {
    static let maximumRetries = 1

    static func timeoutAction(
        completedRetries: Int
    ) -> RideBLEApplicationTimeoutActionV1 {
        completedRetries < maximumRetries ? .retry : .recoverTransport
    }
}

enum WatchNavigationNotificationV1: Equatable {
    case capabilities(WatchDeviceCapabilitiesV1)
    case ignoredDeviceRequest
    case invalidCapabilities

    static func decode(_ data: Data) -> Self {
        if data.prefix(4) == Data("CAP2".utf8) {
            guard let capabilities = WatchDeviceCapabilitiesV1.decode(data) else {
                return .invalidCapabilities
            }
            return .capabilities(capabilities)
        }
        // Destination-picker, workout-launch, and future owner-only requests
        // share 2A6E. A scoped Watch must ignore their exact canonical shapes
        // without accepting malformed variants or tearing down its ride link.
        if (data.count == 10 && data.prefix(4) == Data("DREQ".utf8)) ||
            data == Data("WREQ".utf8) {
            return .ignoredDeviceRequest
        }
        return .invalidCapabilities
    }
}

enum WatchBLEOutboundTargetV1: Equatable, Sendable {
    case auth
    case navigation
    case route
    case gps
    case workout
    case rideAutomation

    var channel: WatchAuthenticatedBLEChannelV1 {
        switch self {
        case .auth: .auth
        case .navigation: .navigation
        case .route: .route
        case .gps: .gps
        case .workout: .workout
        case .rideAutomation: .rideAutomation
        }
    }
}

enum WatchBLEOutboundProtectionV1: Equatable, Sendable {
    case raw
    case protected
}

struct WatchRideAutomationTransportPayloadV1: Equatable, Sendable {
    let target: WatchBLEOutboundTargetV1
    let payload: Data
}

/// Selects the dedicated RAUT characteristic when it is visible and preserves
/// an exact-size navigation fallback for peers whose GATT table is cached.
enum WatchRideAutomationTransportV1 {
    static let frameSize = 52
    static let fallbackPrefix = Data("RAUT".utf8)

    static func outbound(
        frame: Data,
        nativeCharacteristicAvailable: Bool
    ) -> WatchRideAutomationTransportPayloadV1? {
        guard frame.count == frameSize else { return nil }
        if nativeCharacteristicAvailable {
            return .init(target: .rideAutomation, payload: frame)
        }
        var payload = fallbackPrefix
        payload.append(frame)
        return .init(target: .navigation, payload: payload)
    }

    static func decodeNavigationFallback(_ payload: Data) -> Data? {
        guard payload.count == fallbackPrefix.count + frameSize,
              payload.starts(with: fallbackPrefix) else { return nil }
        return Data(payload.dropFirst(fallbackPrefix.count))
    }
}

/// Separates active ride demand from the final clear that must survive a
/// temporary disconnect. A pending release continues to require a BLE
/// connection until its clear frames have drained.
struct WatchRideDemandStateV1: Equatable, Sendable {
    private(set) var navigationActive = false
    private(set) var workoutActive = false
    private(set) var navigationReleasePending = false
    private(set) var workoutReleasePending = false

    var requiresConnection: Bool {
        navigationActive || workoutActive ||
            navigationReleasePending || workoutReleasePending
    }

    var requiresWorkoutChannel: Bool {
        workoutActive || workoutReleasePending
    }

    var hasPendingRelease: Bool {
        navigationReleasePending || workoutReleasePending
    }

    mutating func setNavigationActive(_ active: Bool) {
        navigationActive = active
        if active { navigationReleasePending = false }
    }

    mutating func setWorkoutActive(_ active: Bool) {
        workoutActive = active
        if active { workoutReleasePending = false }
    }

    mutating func beginNavigationRelease() {
        navigationActive = false
        navigationReleasePending = true
    }

    mutating func beginWorkoutRelease() {
        workoutActive = false
        workoutReleasePending = true
    }

    mutating func completePendingReleases() {
        navigationReleasePending = false
        workoutReleasePending = false
    }

    mutating func reset() {
        self = Self()
    }
}

struct WatchBLEOutboundWriteV1: Equatable, Sendable {
    let target: WatchBLEOutboundTargetV1
    let payload: Data
    let gpsSampleTimestamp: Date?
    let workoutMotionCapturedAt: Date?
    let protection: WatchBLEOutboundProtectionV1

    init(
        target: WatchBLEOutboundTargetV1,
        payload: Data,
        gpsSampleTimestamp: Date? = nil,
        workoutMotionCapturedAt: Date? = nil,
        protection: WatchBLEOutboundProtectionV1 = .protected
    ) {
        self.target = target
        self.payload = payload
        self.gpsSampleTimestamp = gpsSampleTimestamp
        self.workoutMotionCapturedAt = workoutMotionCapturedAt
        self.protection = protection
    }
}

enum RideBLECommandPriorityV1: UInt8, Comparable, Sendable {
    case control = 0
    case terminalWorkout = 1
    case navigationBoundary = 2
    case liveWorkout = 3
    case livePosition = 4
    case diagnostics = 5

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RideBLECommandDispositionV1: Equatable, Sendable {
    case critical
    case replaceable
}

enum WatchBLETransportDiagnosticKindV1: String, Codable, Sendable {
    case transportTransition
    case queueAdmission
    case attCompleted
    case attTimeout
    case applicationAcknowledged
    case applicationTimeout
    case recovery
}

/// Privacy-bounded Watch evidence forwarded through queued WatchConnectivity.
/// It deliberately contains no device identifier, BLE payload, GPS, workout
/// value, owner/controller key material, nonce, or route instruction.
struct WatchBLETransportDiagnosticEventV1: Codable, Equatable, Sendable {
    static let schema = 1

    let attemptID: UUID
    let sequence: UInt32
    let kind: WatchBLETransportDiagnosticKindV1
    let phase: String
    let reason: String?
    let connectionGeneration: UInt64
    let queueDepth: Int
    let queueHighWater: Int
    let queueBytes: Int?
    let queueHighWaterBytes: Int?
    let replacedGroups: Int
    let rejectedGroups: Int
    let uptimeMs: Int
    let latencyMs: Int?
}

struct WatchBLETransportDiagnosticBatchV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let userInfoPayloadKey = "watchBLETransportDiagnosticsV1"
    static let maximumEvents = 64

    let schema: Int
    let events: [WatchBLETransportDiagnosticEventV1]

    init(events: [WatchBLETransportDiagnosticEventV1]) {
        schema = Self.schemaVersion
        self.events = Array(events.suffix(Self.maximumEvents))
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 64 * 1024,
              let batch = try? JSONDecoder().decode(Self.self, from: data),
              batch.schema == Self.schemaVersion,
              !batch.events.isEmpty,
              batch.events.count <= maximumEvents,
              batch.events.allSatisfy({ event in
                  event.sequence != 0 &&
                      event.connectionGeneration != 0 &&
                      event.queueDepth >= 0 && event.queueDepth <= 64 &&
                      event.queueHighWater >= 0 &&
                        event.queueHighWater <= 64 &&
                      (event.queueBytes.map {
                          $0 >= 0 && $0 <= 64 *
                            WatchBLEOutboundQueueV1.maximumFrameBytes
                      } ?? true) &&
                      (event.queueHighWaterBytes.map {
                          $0 >= 0 && $0 <= 64 *
                            WatchBLEOutboundQueueV1.maximumFrameBytes
                      } ?? true) &&
                      event.replacedGroups >= 0 &&
                      event.rejectedGroups >= 0 &&
                      event.uptimeMs >= 0 &&
                      (event.latencyMs.map { $0 >= 0 } ?? true) &&
                      event.phase.utf8.count <= 24 &&
                      (event.reason?.utf8.count ?? 0) <= 48
              }) else { return nil }
        return batch
    }
}

struct WatchBLEOutboundGroupV1: Equatable, Sendable {
    let commandID: UUID
    let connectionGeneration: UInt64
    let stateGeneration: UInt32
    let priority: RideBLECommandPriorityV1
    let disposition: RideBLECommandDispositionV1
    let applicationCommandType: RideBLEApplicationCommandTypeV1?
    let coalescingKey: String?
    let writes: [WatchBLEOutboundWriteV1]

    init(
        commandID: UUID = UUID(),
        connectionGeneration: UInt64,
        stateGeneration: UInt32,
        priority: RideBLECommandPriorityV1,
        disposition: RideBLECommandDispositionV1,
        applicationCommandType: RideBLEApplicationCommandTypeV1? = nil,
        coalescingKey: String? = nil,
        writes: [WatchBLEOutboundWriteV1]
    ) {
        self.commandID = commandID
        self.connectionGeneration = connectionGeneration
        self.stateGeneration = stateGeneration
        self.priority = priority
        self.disposition = disposition
        self.applicationCommandType = applicationCommandType
        self.coalescingKey = coalescingKey
        self.writes = writes
    }
}

enum WatchBLEGroupAdmissionV1: Equatable, Sendable {
    case admitted
    case replaced(replacedGroups: Int, evictedGroups: Int)
    case rejectedReplaceable
    case criticalWaiting

    var admitted: Bool {
        switch self {
        case .admitted, .replaced: true
        case .rejectedReplaceable, .criticalWaiting: false
        }
    }
}

struct WatchBLEOutboundQueueMetricsV1: Equatable, Sendable {
    var highWaterFrames = 0
    var highWaterBytes = 0
    var replacedGroups = 0
    var evictedGroups = 0
    var rejectedGroups = 0
    var criticalWaits = 0
}

struct WatchBLEOutboundQueueV1: Equatable {
    static let maximumFrameBytes = 576

    private struct Entry: Equatable {
        let group: WatchBLEOutboundGroupV1
        let sequence: UInt64
    }

    let capacity: Int
    let reservedCriticalFrames: Int
    let byteCapacity: Int
    let reservedCriticalBytes: Int
    private var entries: [Entry] = []
    private var nextSequence: UInt64 = 0
    private(set) var metrics = WatchBLEOutboundQueueMetricsV1()

    var isEmpty: Bool { entries.isEmpty }
    var pendingFrameCount: Int {
        entries.reduce(0) { $0 + $1.group.writes.count }
    }
    var pendingByteCount: Int {
        entries.reduce(0) { total, entry in
            total + entry.group.writes.reduce(0) {
                $0 + $1.payload.count
            }
        }
    }

    init(
        capacity: Int = 32,
        reservedCriticalFrames: Int = 3,
        byteCapacity: Int? = nil,
        reservedCriticalBytes: Int? = nil
    ) {
        let normalizedCapacity = max(capacity, 1)
        let normalizedReservedFrames = min(
            max(reservedCriticalFrames, 1),
            normalizedCapacity
        )
        let normalizedByteCapacity = max(
            byteCapacity ?? normalizedCapacity * Self.maximumFrameBytes,
            1
        )
        self.capacity = normalizedCapacity
        self.reservedCriticalFrames = min(
            normalizedReservedFrames,
            normalizedCapacity
        )
        self.byteCapacity = normalizedByteCapacity
        self.reservedCriticalBytes = min(
            max(
                reservedCriticalBytes ??
                    normalizedReservedFrames * Self.maximumFrameBytes,
                1
            ),
            normalizedByteCapacity
        )
    }

    @discardableResult
    mutating func enqueue(
        _ group: WatchBLEOutboundGroupV1
    ) -> WatchBLEGroupAdmissionV1 {
        let groupByteCount = group.writes.reduce(0) {
            $0 + $1.payload.count
        }
        guard !group.writes.isEmpty,
              group.writes.count <= capacity,
              group.writes.allSatisfy({
                  $0.payload.count <= Self.maximumFrameBytes
              }),
              groupByteCount <= byteCapacity else {
            return reject(group)
        }

        var candidate = entries
        var replaced = 0
        var evicted = 0
        if let key = group.coalescingKey, !key.isEmpty {
            if group.disposition == .replaceable,
               candidate.contains(where: {
                   $0.group.coalescingKey == key &&
                       $0.group.disposition == .critical
               }) {
                // A replaceable snapshot must never supersede a retained
                // terminal/control boundary that happens to share a key.
                return reject(group)
            }
            let oldCount = candidate.count
            candidate.removeAll {
                $0.group.coalescingKey == key &&
                    (group.disposition == .critical ||
                     $0.group.disposition == .replaceable)
            }
            replaced = oldCount - candidate.count
        }

        func frameCount(_ values: [Entry]) -> Int {
            values.reduce(0) { $0 + $1.group.writes.count }
        }
        func criticalFrameCount(_ values: [Entry]) -> Int {
            values.reduce(0) { result, entry in
                result + (entry.group.disposition == .critical
                    ? entry.group.writes.count : 0)
            }
        }
        func byteCount(_ values: [Entry]) -> Int {
            values.reduce(0) { total, entry in
                total + entry.group.writes.reduce(0) {
                    $0 + $1.payload.count
                }
            }
        }
        func criticalByteCount(_ values: [Entry]) -> Int {
            values.reduce(0) { total, entry in
                guard entry.group.disposition == .critical else {
                    return total
                }
                return total + entry.group.writes.reduce(0) {
                    $0 + $1.payload.count
                }
            }
        }

        while true {
            let used = frameCount(candidate)
            let usedBytes = byteCount(candidate)
            let maximumFramesAfterAdmission: Int
            let maximumBytesAfterAdmission: Int
            if group.disposition == .critical {
                maximumFramesAfterAdmission = capacity
                maximumBytesAfterAdmission = byteCapacity
            } else {
                let remainingFrameReserve = max(
                    reservedCriticalFrames - criticalFrameCount(candidate),
                    0
                )
                let remainingByteReserve = max(
                    reservedCriticalBytes - criticalByteCount(candidate),
                    0
                )
                maximumFramesAfterAdmission =
                    capacity - remainingFrameReserve
                maximumBytesAfterAdmission =
                    byteCapacity - remainingByteReserve
            }
            if used + group.writes.count <= maximumFramesAfterAdmission,
               usedBytes + groupByteCount <= maximumBytesAfterAdmission {
                break
            }

            let evictable = candidate.indices.filter { index in
                let existing = candidate[index].group
                guard existing.disposition == .replaceable else {
                    return false
                }
                return group.disposition == .critical ||
                    existing.priority >= group.priority
            }
            guard let index = evictable.max(by: { left, right in
                let lhs = candidate[left]
                let rhs = candidate[right]
                if lhs.group.priority != rhs.group.priority {
                    return lhs.group.priority < rhs.group.priority
                }
                return lhs.sequence > rhs.sequence
            }) else {
                return reject(group)
            }
            candidate.remove(at: index)
            evicted += 1
        }

        nextSequence &+= 1
        candidate.append(Entry(group: group, sequence: nextSequence))
        entries = candidate
        metrics.replacedGroups += replaced
        metrics.evictedGroups += evicted
        metrics.highWaterFrames = max(
            metrics.highWaterFrames,
            pendingFrameCount
        )
        metrics.highWaterBytes = max(metrics.highWaterBytes, pendingByteCount)
        return replaced == 0 && evicted == 0
            ? .admitted
            : .replaced(replacedGroups: replaced, evictedGroups: evicted)
    }

    mutating func dequeueGroup() -> WatchBLEOutboundGroupV1? {
        guard let index = entries.indices.min(by: { left, right in
            let lhs = entries[left]
            let rhs = entries[right]
            if lhs.group.priority != rhs.group.priority {
                return lhs.group.priority < rhs.group.priority
            }
            return lhs.sequence < rhs.sequence
        }) else { return nil }
        return entries.remove(at: index).group
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func reject(
        _ group: WatchBLEOutboundGroupV1
    ) -> WatchBLEGroupAdmissionV1 {
        metrics.rejectedGroups += 1
        if group.disposition == .critical {
            metrics.criticalWaits += 1
            return .criticalWaiting
        }
        return .rejectedReplaceable
    }
}

enum WatchRidePacketEncoderV1 {
    static func maneuver(_ snapshot: NavigationSnapshotV1?) -> Data {
        guard let snapshot else {
            return Data("1|0|Navigation idle".utf8)
        }
        let distance = min(
            max(Int(snapshot.distanceToManeuverMeters.rounded()), 0),
            Int(UInt16.max)
        )
        var instruction = snapshot.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction.isEmpty { instruction = "Continue" }
        while instruction.utf8.count > 63 {
            instruction.removeLast()
        }
        return Data(
            "\(snapshot.maneuver.deviceIconID)|\(distance)|\(instruction)".utf8
        )
    }

    static func gps(
        _ sample: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1?,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        includeRideDetectionQuality: Bool = false,
        now: Date = Date()
    ) -> Data {
        var result = Data()
        result.appendInt32LE(Int32(sample.coordinate.latitude * 1_000_000))
        result.appendInt32LE(Int32(sample.coordinate.longitude * 1_000_000))
        let heading: UInt16 = if sample.courseDegrees.isFinite,
            (0..<360).contains(sample.courseDegrees) {
            UInt16(sample.courseDegrees.rounded()) % 360
        } else {
            .max
        }
        result.appendUInt16LE(heading)
        let seconds = sample.timestamp.timeIntervalSince1970
        result.appendUInt32LE(UInt32(max(min(seconds, Double(UInt32.max)), 0)))
        let speed: UInt16 = sample.speedMetersPerSecond >= 0
            ? UInt16(min(
                (sample.speedMetersPerSecond * 100).rounded(),
                Double(UInt16.max - 1)
            ))
            : UInt16.max
        result.appendUInt16LE(speed)
        result.appendInt16LE(Int16(max(
            min(sample.altitudeMeters.rounded(), Double(Int16.max)),
            Double(Int16.min)
        )))
        result.appendUInt32LE(Self.nonnegativeUInt32(distanceTraveledMeters))
        result.appendUInt32LE(Self.nonnegativeUInt32(elapsedSeconds))
        result.appendUInt32LE(snapshot.map {
            Self.nonnegativeUInt32($0.routeRemainingDistanceMeters)
        } ?? UInt32.max)
        if includeRideDetectionQuality {
            let validCoordinate =
                sample.coordinate.latitude.isFinite &&
                sample.coordinate.longitude.isFinite &&
                (-90...90).contains(sample.coordinate.latitude) &&
                (-180...180).contains(sample.coordinate.longitude)
            let accuracyAvailable = sample.horizontalAccuracyMeters.isFinite &&
                sample.horizontalAccuracyMeters >= 0
            let ageSeconds = now.timeIntervalSince(sample.timestamp)
            let timestampAvailable = ageSeconds.isFinite && ageSeconds >= -1
            let speedAvailable = sample.speedMetersPerSecond.isFinite &&
                sample.speedMetersPerSecond >= 0
            var flags: UInt8 = 0
            if validCoordinate && accuracyAvailable && timestampAvailable &&
                speedAvailable {
                flags |= 1 << 0
            }
            if accuracyAvailable { flags |= 1 << 1 }
            result.append(1)
            result.append(flags)
            result.appendUInt16LE(accuracyAvailable ? UInt16(min(
                (sample.horizontalAccuracyMeters * 10).rounded(),
                Double(UInt16.max - 1)
            )) : UInt16.max)
            result.appendUInt16LE(timestampAvailable ? UInt16(min(
                max((ageSeconds * 1_000).rounded(), 0),
                Double(UInt16.max - 1)
            )) : UInt16.max)
        }
        return result
    }

    static func refreshingQualityAge(
        in packet: Data,
        sampleTimestamp: Date,
        now: Date = Date()
    ) -> Data {
        guard packet.count >= 36, packet[30] == 1 else { return packet }
        var result = packet
        let ageSeconds = now.timeIntervalSince(sampleTimestamp)
        guard ageSeconds.isFinite, ageSeconds >= -1 else {
            result[31] &= ~(1 << 0)
            result[34] = 0xFF
            result[35] = 0xFF
            return result
        }
        let ageMs = UInt16(min(
            max((ageSeconds * 1_000).rounded(), 0),
            Double(UInt16.max - 1)
        ))
        result[34] = UInt8(ageMs & 0xFF)
        result[35] = UInt8((ageMs >> 8) & 0xFF)
        return result
    }

    private static func nonnegativeUInt32(_ value: Double?) -> UInt32 {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return UInt32(min(value.rounded(), Double(UInt32.max - 1)))
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendInt16LE(_ value: Int16) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendInt32LE(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }
}
