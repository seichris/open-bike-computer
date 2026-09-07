import Foundation

nonisolated enum RideAutomationKind: UInt8, Codable, Sendable {
    case decision = 1
    case acknowledgement
    case confirmation
    case configuration
    case configurationAcknowledgement
    case resynchronize
    case promptResponse
    case cancellation
}

nonisolated enum RideAutomationTransition: UInt8, Codable, Sendable {
    case none = 0
    case start
    case pause
    case resume
}

nonisolated enum RideAutomationOrigin: UInt8, Codable, Sendable {
    case unknown = 0
    case manual
    case automatic
}

nonisolated enum RideAutomationResult: UInt8, Codable, Sendable {
    case none = 0
    case accepted
    case rejected
    case watchUnavailable
    case stale
    case sessionMismatch
}

nonisolated enum RideStartMode: UInt8, Codable, Sendable, Hashable {
    case off = 0
    case ask
    case automatic
}

nonisolated enum RideAutomationSerialNumber {
    /// RFC 1982-style comparison for persisted UInt32 generations. Exactly
    /// half the serial space is intentionally unordered.
    static func isNewer(_ candidate: UInt32, than current: UInt32) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000_0000
    }
}

nonisolated struct RideAutomationFrame: Codable, Equatable, Sendable {
    static let version: UInt8 = 2
    static let byteCount = 52
    // Evidence bits are intentionally forward compatible across detector
    // profiles. Consumers interpret known bits and preserve the full field.
    static let validEvidenceMask: UInt16 = .max
static let validSourceHealthMask: UInt16 = 0x001F

    var kind: RideAutomationKind
    var transition: RideAutomationTransition = .none
    var origin: RideAutomationOrigin = .unknown
    var result: RideAutomationResult = .none
    var rideGeneration: UInt32
    var decisionSequence: UInt32 = 0
    var evidenceMask: UInt16 = 0
    var profileVersion: UInt16 = 1
    var sessionID: UUID?
    var watermarkOrConfigGeneration: UInt32 = 0
    var startMode: RideStartMode = .off
    var autoPauseEnabled = false
    var alertMode: UInt8 = 0
    var candidateBeganSeconds: UInt32 = 0
    var monotonicSeconds: UInt32 = 0
    var sourceHealthMask: UInt16 = 0
    var acknowledgedKind: RideAutomationKind?

    init(
        kind: RideAutomationKind,
        transition: RideAutomationTransition = .none,
        origin: RideAutomationOrigin = .unknown,
        result: RideAutomationResult = .none,
        rideGeneration: UInt32,
        decisionSequence: UInt32 = 0,
        evidenceMask: UInt16 = 0,
        profileVersion: UInt16 = 1,
        sessionID: UUID? = nil,
        watermarkOrConfigGeneration: UInt32 = 0,
        startMode: RideStartMode = .off,
        autoPauseEnabled: Bool = false,
        alertMode: UInt8 = 0,
        candidateBeganSeconds: UInt32 = 0,
        monotonicSeconds: UInt32 = 0,
        sourceHealthMask: UInt16 = 0,
        acknowledgedKind: RideAutomationKind? = nil
    ) {
        self.kind = kind
        self.transition = transition
        self.origin = origin
        self.result = result
        self.rideGeneration = rideGeneration
        self.decisionSequence = decisionSequence
        self.evidenceMask = evidenceMask
        self.profileVersion = profileVersion
        self.sessionID = sessionID
        self.watermarkOrConfigGeneration = watermarkOrConfigGeneration
        self.startMode = startMode
        self.autoPauseEnabled = autoPauseEnabled
        self.alertMode = alertMode
        self.candidateBeganSeconds = candidateBeganSeconds
        self.monotonicSeconds = monotonicSeconds
        self.sourceHealthMask = sourceHealthMask
        self.acknowledgedKind = acknowledgedKind
    }

    func encoded() -> Data? {
        guard rideGeneration != 0, profileVersion != 0, alertMode <= 2,
              evidenceMask & ~Self.validEvidenceMask == 0,
              sourceHealthMask & ~Self.validSourceHealthMask == 0,
              isSemanticallyValid else {
            return nil
        }
        if [.decision, .acknowledgement, .confirmation, .promptResponse,
            .cancellation]
            .contains(kind),
           decisionSequence == 0 {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        bytes[0] = Self.version
        bytes[1] = kind.rawValue
        bytes[2] = transition.rawValue
        bytes[3] = origin.rawValue
        bytes[4] = result.rawValue
        bytes[5] = startMode.rawValue
        bytes[6] = autoPauseEnabled ? 1 : 0
        bytes[7] = alertMode
        bytes.writeLE(rideGeneration, at: 8)
        bytes.writeLE(decisionSequence, at: 12)
        bytes.writeLE(evidenceMask, at: 16)
        bytes.writeLE(profileVersion, at: 18)
        bytes.writeUUID(sessionID, at: 20)
        bytes.writeLE(watermarkOrConfigGeneration, at: 36)
        bytes.writeLE(candidateBeganSeconds, at: 40)
        bytes.writeLE(monotonicSeconds, at: 44)
        bytes.writeLE(sourceHealthMask, at: 48)
        bytes[50] = acknowledgedKind?.rawValue ?? 0
        return Data(bytes)
    }

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == Self.version,
              let kind = RideAutomationKind(rawValue: bytes[1]),
              let transition = RideAutomationTransition(rawValue: bytes[2]),
              let origin = RideAutomationOrigin(rawValue: bytes[3]),
              let result = RideAutomationResult(rawValue: bytes[4]),
              let startMode = RideStartMode(rawValue: bytes[5]),
              bytes[6] <= 1,
              bytes[7] <= 2,
              bytes[51] == 0 else { return nil }
        let rideGeneration: UInt32 = bytes.readLE(at: 8)
        let sequence: UInt32 = bytes.readLE(at: 12)
        let profile: UInt16 = bytes.readLE(at: 18)
        guard rideGeneration != 0, profile != 0 else { return nil }
        if [.decision, .acknowledgement, .confirmation, .promptResponse,
            .cancellation]
            .contains(kind),
           sequence == 0 { return nil }
        self.kind = kind
        self.transition = transition
        self.origin = origin
        self.result = result
        self.rideGeneration = rideGeneration
        decisionSequence = sequence
        evidenceMask = bytes.readLE(at: 16)
        profileVersion = profile
        sessionID = bytes.readUUID(at: 20)
        watermarkOrConfigGeneration = bytes.readLE(at: 36)
        self.startMode = startMode
        autoPauseEnabled = bytes[6] == 1
        alertMode = bytes[7]
        candidateBeganSeconds = bytes.readLE(at: 40)
        monotonicSeconds = bytes.readLE(at: 44)
        sourceHealthMask = bytes.readLE(at: 48)
        if bytes[50] == 0 {
            acknowledgedKind = nil
        } else {
            guard let value = RideAutomationKind(rawValue: bytes[50]) else {
                return nil
            }
            acknowledgedKind = value
        }
        guard evidenceMask & ~Self.validEvidenceMask == 0,
              sourceHealthMask & ~Self.validSourceHealthMask == 0 else {
            return nil
        }
        guard isSemanticallyValid else { return nil }
    }

    private var isSemanticallyValid: Bool {
        switch kind {
        case .decision:
            return transition != .none && origin == .automatic
                && result == .none && acknowledgedKind == nil
        case .acknowledgement:
            return transition != .none && origin == .automatic
                && result != .none
                && (acknowledgedKind == .decision
                    || (acknowledgedKind == .promptResponse
                        && transition == .start))
        case .confirmation:
            return transition != .none && origin == .automatic
                && result != .none && acknowledgedKind == nil
        case .configuration:
            return transition == .none && origin == .unknown
                && result == .none && decisionSequence == 0
                && watermarkOrConfigGeneration != 0
                && acknowledgedKind == nil
        case .configurationAcknowledgement:
            return transition == .none && origin == .unknown
                && (result == .accepted || result == .rejected)
                && decisionSequence == 0
                && acknowledgedKind == nil
        case .resynchronize:
            return transition == .none && origin == .unknown
                && result == .none && decisionSequence == 0
                && acknowledgedKind == nil
        case .promptResponse:
            return transition == .start && origin == .automatic
                && (result == .accepted || result == .rejected)
                && acknowledgedKind == nil
        case .cancellation:
            return transition != .none && origin == .automatic
                && result == .stale
                && acknowledgedKind == nil
        }
    }
}

private extension Array where Element == UInt8 {
    nonisolated mutating func writeUUID(_ value: UUID?, at offset: Int) {
        guard var uuid = value?.uuid else { return }
        Swift.withUnsafeBytes(of: &uuid) { rawBuffer in
            for index in 0..<16 {
                self[offset + index] = rawBuffer[index]
            }
        }
    }

    nonisolated func readUUID(at offset: Int) -> UUID? {
        let values = Array(self[offset..<(offset + 16)])
        guard values.contains(where: { $0 != 0 }) else { return nil }
        return UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }

    nonisolated mutating func writeLE<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int
    ) {
        for index in 0..<MemoryLayout<T>.size {
            self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    nonisolated func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (index * 8)
        }
        return value
    }
}

nonisolated struct RideDetectionSettings: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var startMode: RideStartMode = .ask
    var autoPauseEnabled = true
    var alertMode: UInt8 = 0

    mutating func normalize() {
        schemaVersion = 1
        alertMode = min(alertMode, 2)
    }
}

nonisolated enum RideDetectionSyncContext {
    static let schemaVersionKey =
        "BikeComputer.rideDetection.schemaVersion.v1"
    static let generationKey =
        "BikeComputer.rideDetection.generation.v1"
    static let startModeKey =
        "BikeComputer.rideDetection.startMode.v1"
    static let autoPauseEnabledKey =
        "BikeComputer.rideDetection.autoPauseEnabled.v1"
    static let alertModeKey =
        "BikeComputer.rideDetection.alertMode.v1"
    static let automaticStartRideGenerationKey =
        "BikeComputer.rideDetection.automaticStart.rideGeneration.v1"
    static let automaticStartDecisionSequenceKey =
        "BikeComputer.rideDetection.automaticStart.decisionSequence.v1"
    static let automaticStartProfileVersionKey =
        "BikeComputer.rideDetection.automaticStart.profileVersion.v1"
    static let automaticStartEvidenceMaskKey =
        "BikeComputer.rideDetection.automaticStart.evidenceMask.v1"
    static let automaticStartSourceHealthMaskKey =
        "BikeComputer.rideDetection.automaticStart.sourceHealthMask.v1"
    static let automaticStartCandidateBeganKey =
        "BikeComputer.rideDetection.automaticStart.candidateBegan.v1"
    static let automaticStartDecidedAtKey =
        "BikeComputer.rideDetection.automaticStart.decidedAt.v1"

    static func adding(
        settings: RideDetectionSettings,
        generation: UInt32,
        to context: [String: Any] = [:]
    ) -> [String: Any] {
        var normalized = settings
        normalized.normalize()
        var result = context
        result[schemaVersionKey] = normalized.schemaVersion
        result[generationKey] = Int(generation)
        result[startModeKey] = Int(normalized.startMode.rawValue)
        result[autoPauseEnabledKey] = normalized.autoPauseEnabled
        result[alertModeKey] = Int(normalized.alertMode)
        return result
    }

    static func settings(
        from context: [String: Any]
    ) -> (settings: RideDetectionSettings, generation: UInt32)? {
        guard let schemaVersion = context[schemaVersionKey] as? Int,
              schemaVersion == 1,
              let generationNumber = context[generationKey] as? NSNumber,
              let generation = exactUInt32(generationNumber),
              let startModeNumber = context[startModeKey] as? NSNumber,
              let startModeRawValue = exactUInt8(startModeNumber),
              let startMode = RideStartMode(
                rawValue: startModeRawValue
              ),
              let autoPauseEnabled =
                context[autoPauseEnabledKey] as? Bool,
              let alertModeNumber = context[alertModeKey] as? NSNumber,
              let alertMode = exactUInt8(alertModeNumber),
              alertMode <= 2 else {
            return nil
        }
        var settings = RideDetectionSettings(
            startMode: startMode,
            autoPauseEnabled: autoPauseEnabled,
            alertMode: alertMode
        )
        settings.normalize()
        return (settings, generation)
    }

    static func addingPendingAutomaticStart(
        _ context: WorkoutControlContextV1?,
        to applicationContext: [String: Any]
    ) -> [String: Any] {
        var result = applicationContext
        result.removeValue(forKey: automaticStartRideGenerationKey)
        result.removeValue(forKey: automaticStartDecisionSequenceKey)
        result.removeValue(forKey: automaticStartProfileVersionKey)
        result.removeValue(forKey: automaticStartEvidenceMaskKey)
        result.removeValue(forKey: automaticStartSourceHealthMaskKey)
        result.removeValue(forKey: automaticStartCandidateBeganKey)
        result.removeValue(forKey: automaticStartDecidedAtKey)
        guard context?.origin == .automatic,
              context?.automaticReason == .rideDetection,
              let rideGeneration = context?.rideGeneration,
              let decisionSequence = context?.decisionSequence,
              let profileVersion = context?.detectorProfileVersion,
              rideGeneration > 0, decisionSequence > 0,
              profileVersion > 0 else {
            return result
        }
        result[automaticStartRideGenerationKey] =
            NSNumber(value: rideGeneration)
        result[automaticStartDecisionSequenceKey] =
            NSNumber(value: decisionSequence)
        result[automaticStartProfileVersionKey] =
            NSNumber(value: profileVersion)
        if let evidenceMask = context?.evidenceMask,
           let sourceHealthMask = context?.sourceHealthMask,
           let candidateBeganSeconds = context?.candidateBeganSeconds,
           let decidedAtSeconds = context?.decidedAtSeconds {
            result[automaticStartEvidenceMaskKey] =
                NSNumber(value: evidenceMask)
            result[automaticStartSourceHealthMaskKey] =
                NSNumber(value: sourceHealthMask)
            result[automaticStartCandidateBeganKey] =
                NSNumber(value: candidateBeganSeconds)
            result[automaticStartDecidedAtKey] =
                NSNumber(value: decidedAtSeconds)
        }
        return result
    }

    static func pendingAutomaticStart(
        from applicationContext: [String: Any]
    ) -> WorkoutControlContextV1? {
        guard let rideGenerationNumber =
                applicationContext[automaticStartRideGenerationKey]
                    as? NSNumber,
              let rideGeneration = exactUInt32(rideGenerationNumber),
              let decisionSequenceNumber =
                applicationContext[automaticStartDecisionSequenceKey]
                    as? NSNumber,
              let decisionSequence = exactUInt32(decisionSequenceNumber),
              let profileVersionNumber =
                applicationContext[automaticStartProfileVersionKey]
                    as? NSNumber,
              let profileVersion = exactUInt16(profileVersionNumber),
              rideGeneration > 0, decisionSequence > 0,
              profileVersion > 0 else {
            return nil
        }
        let evidenceNumber = applicationContext[
            automaticStartEvidenceMaskKey
        ] as? NSNumber
        let sourceHealthNumber = applicationContext[
            automaticStartSourceHealthMaskKey
        ] as? NSNumber
        let candidateNumber = applicationContext[
            automaticStartCandidateBeganKey
        ] as? NSNumber
        let decidedNumber = applicationContext[
            automaticStartDecidedAtKey
        ] as? NSNumber
        let hasDiagnostics = evidenceNumber != nil
            || sourceHealthNumber != nil
            || candidateNumber != nil
            || decidedNumber != nil
        let diagnostics: (UInt16, UInt16, UInt32, UInt32)?
        if hasDiagnostics {
            guard let evidenceNumber,
                  let sourceHealthNumber,
                  let candidateNumber,
                  let decidedNumber,
                  let evidenceMask = exactUInt16(evidenceNumber),
                  let sourceHealthMask = exactUInt16(sourceHealthNumber),
                  let candidateBeganSeconds = exactUInt32(candidateNumber),
                  let decidedAtSeconds = exactUInt32(decidedNumber),
                  evidenceMask & ~RideAutomationFrame.validEvidenceMask == 0,
                  sourceHealthMask
                    & ~RideAutomationFrame.validSourceHealthMask == 0 else {
                return nil
            }
            diagnostics = (
                evidenceMask,
                sourceHealthMask,
                candidateBeganSeconds,
                decidedAtSeconds
            )
        } else {
            diagnostics = nil
        }
        return WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: rideGeneration,
            decisionSequence: decisionSequence,
            detectorProfileVersion: profileVersion,
            evidenceMask: diagnostics?.0,
            sourceHealthMask: diagnostics?.1,
            candidateBeganSeconds: diagnostics?.2,
            decidedAtSeconds: diagnostics?.3
        )
    }

    private static func exactUInt8(_ number: NSNumber) -> UInt8? {
        exactUnsigned(number, as: UInt8.self)
    }

    private static func exactUInt16(_ number: NSNumber) -> UInt16? {
        exactUnsigned(number, as: UInt16.self)
    }

    private static func exactUInt32(_ number: NSNumber) -> UInt32? {
        exactUnsigned(number, as: UInt32.self)
    }

    private static func exactUnsigned<T: FixedWidthInteger & UnsignedInteger>(
        _ number: NSNumber,
        as type: T.Type
    ) -> T? {
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        return T(exactly: value)
    }
}
