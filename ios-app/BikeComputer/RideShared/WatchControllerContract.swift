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

extension Data {
    var watchControllerHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
