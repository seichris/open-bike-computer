import CryptoKit
import Foundation

enum WatchControllerContractError: Error, Equatable {
    case invalidDeviceID
    case invalidControllerID
    case invalidCredentialKey
    case invalidChallenge
    case invalidProof
    case invalidEnvelope
}

enum PhoneWatchControllerTransportError: Error, Sendable {
    case watchUnavailable
    case invalidRequest
    case invalidResponse
    case rejected(String)
    case transport(String)
}

protocol PhoneWatchControllerTransporting: AnyObject {
    func sendWatchControllerRequest(
        _ request: WatchControllerRequestV1,
        completion: @escaping @Sendable (
            Result<WatchControllerResponseV1,
                   PhoneWatchControllerTransportError>
        ) -> Void
    )

    func queueWatchControllerRevocation(
        _ request: WatchControllerRequestV1
    )
}

struct WatchControllerCredentialV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let deviceID: String
    let controllerID: Data
    let key: Data
    let createdAt: Date

    init(
        deviceID: String,
        controllerID: Data,
        key: Data,
        createdAt: Date = Date()
    ) throws {
        let normalizedDeviceID = deviceID.lowercased()
        guard Self.isHex(normalizedDeviceID, byteCount: 16) else {
            throw WatchControllerContractError.invalidDeviceID
        }
        guard controllerID.count == 16,
              controllerID.contains(where: { $0 != 0 }) else {
            throw WatchControllerContractError.invalidControllerID
        }
        guard key.count == 32, key.contains(where: { $0 != 0 }) else {
            throw WatchControllerContractError.invalidCredentialKey
        }
        schema = Self.schemaVersion
        self.deviceID = normalizedDeviceID
        self.controllerID = controllerID
        self.key = key
        self.createdAt = createdAt
    }

    var controllerIDHex: String { controllerID.watchControllerHex }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return try Self(
            deviceID: deviceID,
            controllerID: controllerID,
            key: key,
            createdAt: createdAt
        )
    }

    private static func isHex(_ value: String, byteCount: Int) -> Bool {
        value.count == byteCount * 2 &&
            value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) ||
                    ($0 >= 97 && $0 <= 102)
            }
    }
}

enum WatchControllerMessageOperationV1: String, Codable, Sendable {
    case proveEnrollment
    case promote
    case revoke
}

struct WatchControllerRequestV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let requestID: UUID
    let operation: WatchControllerMessageOperationV1
    let deviceID: String
    let controllerID: Data
    let credential: WatchControllerCredentialV1?
    let challenge: Data?

    init(
        requestID: UUID = UUID(),
        operation: WatchControllerMessageOperationV1,
        deviceID: String,
        controllerID: Data,
        credential: WatchControllerCredentialV1? = nil,
        challenge: Data? = nil
    ) {
        schema = Self.schemaVersion
        self.requestID = requestID
        self.operation = operation
        self.deviceID = deviceID.lowercased()
        self.controllerID = controllerID
        self.credential = credential
        self.challenge = challenge
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion,
              deviceID.count == 32,
              deviceID.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }),
              controllerID.count == 16,
              controllerID.contains(where: { $0 != 0 }) else {
            throw WatchControllerContractError.invalidEnvelope
        }
        switch operation {
        case .proveEnrollment:
            guard let credential = try credential?.validated(),
                  credential.deviceID == deviceID,
                  credential.controllerID == controllerID,
                  let challenge,
                  challenge.count == 16 else {
                throw WatchControllerContractError.invalidEnvelope
            }
        case .promote, .revoke:
            guard credential == nil, challenge == nil else {
                throw WatchControllerContractError.invalidEnvelope
            }
        }
        return self
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

struct WatchControllerResponseV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let requestID: UUID
    let accepted: Bool
    let proof: Data?
    let errorCode: String?

    init(
        requestID: UUID,
        accepted: Bool,
        proof: Data? = nil,
        errorCode: String? = nil
    ) {
        schema = Self.schemaVersion
        self.requestID = requestID
        self.accepted = accepted
        self.proof = proof
        self.errorCode = errorCode
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion,
              accepted ? errorCode == nil : proof == nil,
              proof == nil || proof?.count == 32 else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return self
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

enum WatchControllerCryptographyV1 {
    static func enrollmentProof(
        credential: WatchControllerCredentialV1,
        challenge: Data
    ) throws -> Data {
        let credential = try credential.validated()
        guard challenge.count == 16 else {
            throw WatchControllerContractError.invalidChallenge
        }
        let message = Data(
            "watch-enroll1|\(credential.deviceID)|\(credential.controllerIDHex)|\(challenge.watchControllerHex)".utf8
        )
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: credential.key)
        )
        return Data(authenticationCode)
    }
}

enum WatchControllerTransportV1 {
    static let userInfoPayloadKey = "watchControllerRequestV1"
}

enum WatchDirectRidePreparationOperationV1: String, Codable, Equatable,
    Sendable {
    case prepare
    case release
}

/// Synchronous admission result for a Watch-to-iPhone preparation message.
/// A caller must not treat invoking a callback as delivery: only `submitted`
/// means WatchConnectivity accepted the message or a durable local release.
enum WatchDirectRidePreparationSubmissionDispositionV1: Equatable, Sendable {
    case submitted
    case transportUnavailable
    case activationPending
    case counterpartUnreachable
    case encodingFailed
}

/// The logical handoff identity survives retries and Watch relaunches. Each
/// transport attempt gets a fresh request ID, while `preparationID` remains
/// stable so both peers can make prepare/release idempotent.
struct WatchDirectRidePreparationIntentV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let preparationID: UUID
    let operation: WatchDirectRidePreparationOperationV1
    let deviceID: String

    init(
        preparationID: UUID,
        operation: WatchDirectRidePreparationOperationV1,
        deviceID: String
    ) throws {
        let request = try WatchDirectRidePreparationRequestV1(
            preparationID: preparationID,
            operation: operation,
            deviceID: deviceID
        )
        schema = Self.schemaVersion
        self.preparationID = request.preparationID
        self.operation = request.operation
        self.deviceID = request.deviceID
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return try Self(
            preparationID: preparationID,
            operation: operation,
            deviceID: deviceID
        )
    }

    func request(requestID: UUID = UUID()) throws
        -> WatchDirectRidePreparationRequestV1 {
        let validated = try validated()
        return try WatchDirectRidePreparationRequestV1(
            requestID: requestID,
            preparationID: validated.preparationID,
            operation: validated.operation,
            deviceID: validated.deviceID
        )
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

enum WatchDirectRidePreparationRetryPolicyV1 {
    static let responseTimeoutSeconds: Double = 5

    static func delaySeconds(afterAttempt attempt: Int) -> Double {
        let normalizedAttempt = max(1, min(attempt, 6))
        return min(pow(2, Double(normalizedAttempt - 1)), 30)
    }
}

struct WatchDirectRidePreparationRequestV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let userInfoPayloadKey = "watchDirectRidePreparationRequestV1"

    let schema: Int
    let requestID: UUID
    let preparationID: UUID
    let operation: WatchDirectRidePreparationOperationV1
    let deviceID: String

    init(
        requestID: UUID = UUID(),
        preparationID: UUID,
        operation: WatchDirectRidePreparationOperationV1,
        deviceID: String
    ) throws {
        let deviceID = deviceID.lowercased()
        guard deviceID.count == 32,
              deviceID.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw WatchControllerContractError.invalidDeviceID
        }
        schema = Self.schemaVersion
        self.requestID = requestID
        self.preparationID = preparationID
        self.operation = operation
        self.deviceID = deviceID
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return try Self(
            requestID: requestID,
            preparationID: preparationID,
            operation: operation,
            deviceID: deviceID
        )
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

struct WatchDirectRidePreparationResponseV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let requestID: UUID
    let accepted: Bool
    let errorCode: String?

    init(requestID: UUID, accepted: Bool, errorCode: String? = nil) {
        schema = Self.schemaVersion
        self.requestID = requestID
        self.accepted = accepted
        self.errorCode = errorCode.map { String($0.prefix(64)) }
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion,
              accepted ? errorCode == nil : errorCode?.isEmpty == false,
              errorCode?.utf8.count ?? 0 <= 64 else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return self
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

enum WatchDirectRidePreparationPolicyV1 {
    static func rejectionCode(
        requestedDeviceID: String,
        selectedDeviceID: String?,
        phoneNavigationActive: Bool,
        transferActive: Bool,
        administrationActive: Bool
    ) -> String? {
        guard requestedDeviceID == selectedDeviceID else {
            return "different_device"
        }
        guard !phoneNavigationActive else { return "phone_navigation_active" }
        guard !transferActive else { return "device_transfer_active" }
        guard !administrationActive else { return "device_admin_active" }
        return nil
    }

    static func releaseMatches(
        preparedDeviceID: String?,
        preparedPreparationID: UUID?,
        request: WatchDirectRidePreparationRequestV1
    ) -> Bool {
        request.operation == .release &&
            preparedDeviceID == request.deviceID &&
            preparedPreparationID == request.preparationID
    }
}

enum WatchDirectRidePreparationRestorationDecisionV1: Equatable, Sendable {
    case none
    case retain
    case release
}

/// Defers resolution of a restored prepare until navigation and HealthKit
/// workout recovery have both had a chance to restore direct-ride demand.
struct WatchDirectRidePreparationRestorationGateV1: Sendable {
    private(set) var isPending: Bool

    init(restoredOperation: WatchDirectRidePreparationOperationV1?) {
        isPending = restoredOperation == .prepare
    }

    mutating func complete(
        hasRecoveredDemand: Bool
    ) -> WatchDirectRidePreparationRestorationDecisionV1 {
        guard isPending else { return .none }
        isPending = false
        return hasRecoveredDemand ? .retain : .release
    }
}

struct WatchDeviceMetadataV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let applicationContextKey = "watchDeviceMetadataV1"
    static let maximumDisplayValueBytes = 256
    static let maximumSystemValueBytes = 64

    let schema: Int
    let name: String
    let localizedModel: String
    let systemName: String
    let systemVersion: String

    init(
        name: String,
        localizedModel: String,
        systemName: String,
        systemVersion: String
    ) throws {
        schema = Self.schemaVersion
        self.name = try Self.validatedValue(
            name,
            maximumBytes: Self.maximumDisplayValueBytes
        )
        self.localizedModel = try Self.validatedValue(
            localizedModel,
            maximumBytes: Self.maximumDisplayValueBytes
        )
        self.systemName = try Self.validatedValue(
            systemName,
            maximumBytes: Self.maximumSystemValueBytes
        )
        self.systemVersion = try Self.validatedValue(
            systemVersion,
            maximumBytes: Self.maximumSystemValueBytes
        )
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return try Self(
            name: name,
            localizedModel: localizedModel,
            systemName: systemName,
            systemVersion: systemVersion
        )
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }

    private static func validatedValue(
        _ value: String,
        maximumBytes: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.lengthOfBytes(using: .utf8) <= maximumBytes else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return normalized
    }
}

/// Identifies the iPhone-selected Bike Computer that direct Watch rides must
/// target. A versioned tombstone (`deviceID == nil`) is retained so changing
/// or removing the active device cannot make the Watch fall back to an
/// arbitrary enrolled credential.
struct WatchSelectedBikeComputerV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let applicationContextKey = "watchSelectedBikeComputerV1"

    let schema: Int
    let revision: UInt64
    let deviceID: String?

    init(revision: UInt64, deviceID: String?) throws {
        guard revision > 0 else {
            throw WatchControllerContractError.invalidEnvelope
        }
        let normalizedDeviceID = deviceID?.lowercased()
        if let normalizedDeviceID {
            guard normalizedDeviceID.count == 32,
                  normalizedDeviceID.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                  }) else {
                throw WatchControllerContractError.invalidDeviceID
            }
        }
        schema = Self.schemaVersion
        self.revision = revision
        self.deviceID = normalizedDeviceID
    }

    func validated() throws -> Self {
        guard schema == Self.schemaVersion else {
            throw WatchControllerContractError.invalidEnvelope
        }
        return try Self(revision: revision, deviceID: deviceID)
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(validated())
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data).validated()
    }

    func selects(_ credential: WatchControllerCredentialV1) -> Bool {
        deviceID == credential.deviceID
    }
}

struct WatchControllerAvailabilityV1: Equatable, Sendable {
    var isSupported = false
    var isActivated = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false

    var canPerformLiveEnrollment: Bool {
        isSupported && isActivated && isPaired && isWatchAppInstalled &&
            isReachable
    }
}

struct PhoneWatchConnectivityStateV1: Equatable, Sendable {
    var isSupported = false
    var isActivated = false
    var activationFailed = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
    var watchMetadata: WatchDeviceMetadataV1?

    var controllerAvailability: WatchControllerAvailabilityV1 {
        WatchControllerAvailabilityV1(
            isSupported: isSupported,
            isActivated: isActivated,
            isPaired: isPaired,
            isWatchAppInstalled: isWatchAppInstalled,
            isReachable: isReachable
        )
    }
}

enum WatchControllerAutomaticEnrollmentPolicyV1 {
    static func shouldStart(
        firmwareSupportsScopedController: Bool,
        deviceConnectedAndAuthenticated: Bool,
        controllerStatusKnown: Bool,
        hasController: Bool,
        operationInFlight: Bool,
        availability: WatchControllerAvailabilityV1
    ) -> Bool {
        firmwareSupportsScopedController &&
            deviceConnectedAndAuthenticated &&
            controllerStatusKnown &&
            !hasController &&
            !operationInFlight &&
            availability.canPerformLiveEnrollment
    }
}

extension Data {
    var watchControllerHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
