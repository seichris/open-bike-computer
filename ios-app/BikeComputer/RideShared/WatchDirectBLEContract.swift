import CryptoKit
import Foundation

enum WatchDirectBLEProtocolV1 {
    static let serviceUUID = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800"
    static let navigationUUID = "2A6E"
    static let routeUUID = "2A6F"
    static let gpsUUID = "2A72"
    static let authUUID = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002"
    static let workoutUUID = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003"
    static let capabilityClientVersion: UInt8 = 10
    static let scopedControllerFeature: UInt32 = 1 << 13
    static let workoutTelemetryFeature: UInt32 = 1 << 7
    static let protectedFrameOverhead = 22
}

enum WatchAuthenticatedBLEChannelV1: UInt8, Sendable {
    case auth = 1
    case navigation = 2
    case route = 3
    case gps = 4
    case workout = 6
}

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

enum WatchBLEOutboundTargetV1: Equatable, Sendable {
    case navigation
    case route
    case gps
    case workout

    var channel: WatchAuthenticatedBLEChannelV1 {
        switch self {
        case .navigation: .navigation
        case .route: .route
        case .gps: .gps
        case .workout: .workout
        }
    }
}

struct WatchBLEOutboundWriteV1: Equatable, Sendable {
    let target: WatchBLEOutboundTargetV1
    let payload: Data
    let priority: UInt8
    let coalescingKey: String?
    fileprivate let sequence: UInt64

    init(
        target: WatchBLEOutboundTargetV1,
        payload: Data,
        priority: UInt8,
        coalescingKey: String? = nil,
        sequence: UInt64 = 0
    ) {
        self.target = target
        self.payload = payload
        self.priority = priority
        self.coalescingKey = coalescingKey
        self.sequence = sequence
    }
}

struct WatchBLEOutboundQueueV1: Equatable {
    let capacity: Int
    private(set) var writes: [WatchBLEOutboundWriteV1] = []
    private var nextSequence: UInt64 = 0

    var isEmpty: Bool { writes.isEmpty }

    init(capacity: Int = 32) {
        self.capacity = max(capacity, 1)
    }

    @discardableResult
    mutating func enqueue(_ write: WatchBLEOutboundWriteV1) -> Bool {
        nextSequence &+= 1
        let sequenced = WatchBLEOutboundWriteV1(
            target: write.target,
            payload: write.payload,
            priority: write.priority,
            coalescingKey: write.coalescingKey,
            sequence: nextSequence
        )
        if let key = sequenced.coalescingKey,
           let index = writes.firstIndex(where: {
               $0.coalescingKey == key
           }) {
            writes[index] = sequenced
            return true
        }
        if writes.count >= capacity,
           let replaceable = writes.indices
               .filter({ writes[$0].coalescingKey != nil })
               .min(by: { writes[$0].sequence < writes[$1].sequence }) {
            writes.remove(at: replaceable)
        }
        guard writes.count < capacity else { return false }
        writes.append(sequenced)
        return true
    }

    mutating func dequeue() -> WatchBLEOutboundWriteV1? {
        guard let index = writes.indices.min(by: { left, right in
            let lhs = writes[left]
            let rhs = writes[right]
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.sequence < rhs.sequence
        }) else { return nil }
        return writes.remove(at: index)
    }

    mutating func removeAll() {
        writes.removeAll(keepingCapacity: true)
    }

    mutating func removeAll(target: WatchBLEOutboundTargetV1) {
        writes.removeAll { $0.target == target }
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
        elapsedSeconds: TimeInterval? = nil
    ) -> Data {
        var result = Data()
        result.appendInt32LE(Int32(sample.coordinate.latitude * 1_000_000))
        result.appendInt32LE(Int32(sample.coordinate.longitude * 1_000_000))
        let heading = sample.courseDegrees >= 0
            ? UInt16(min(sample.courseDegrees, 359))
            : 0
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
        return result
    }

    private static func nonnegativeUInt32(_ value: Double?) -> UInt32 {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return UInt32(min(value.rounded(), Double(UInt32.max - 1)))
    }
}

private extension Data {
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
