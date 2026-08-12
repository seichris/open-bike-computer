import Combine
import Foundation

nonisolated enum RideAutomationRollout {
#if RIDE_AUTOMATION_AUTOMATIC_START
    static let allowsAutomaticStart = true
#else
    static let allowsAutomaticStart = false
#endif
}

nonisolated struct RideAutomationPendingDecision: Codable, Equatable, Sendable {
    let identity: RideAutomationDecisionIdentity
    let frame: RideAutomationFrame
    let expectedState: WorkoutSessionStateV1?
    let resolvedResult: RideAutomationResult?
    let resolvedSessionID: UUID?

    init(
        identity: RideAutomationDecisionIdentity,
        frame: RideAutomationFrame,
        expectedState: WorkoutSessionStateV1?,
        resolvedResult: RideAutomationResult? = nil,
        resolvedSessionID: UUID? = nil
    ) {
        self.identity = identity
        self.frame = frame
        self.expectedState = expectedState
        self.resolvedResult = resolvedResult
        self.resolvedSessionID = resolvedSessionID
    }

    /// UserDefaults is only a recovery cache, not an authority boundary. A
    /// partially written, corrupted, or older payload must never be able to
    /// synthesize a Watch lifecycle control after relaunch.
    var isValidForPersistence: Bool {
        guard !identity.deviceID.isEmpty,
              identity.rideGeneration == frame.rideGeneration,
              identity.decisionSequence == frame.decisionSequence,
              frame.kind == .decision,
              frame.origin == .automatic,
              frame.result == .none,
              frame.encoded() != nil else {
            return false
        }

        switch frame.transition {
        case .start:
            guard expectedState == nil || expectedState == .running else {
                return false
            }
            if expectedState == nil, frame.startMode != .ask {
                return false
            }
        case .pause:
            guard expectedState == .paused,
                  frame.sessionID != nil else {
                return false
            }
        case .resume:
            guard expectedState == .running,
                  frame.sessionID != nil else {
                return false
            }
        case .none:
            return false
        }

        guard let resolvedResult else {
            return resolvedSessionID == nil
        }
        guard resolvedResult != .none else { return false }
        if resolvedResult == .accepted {
            return resolvedSessionID != nil
        }
        return resolvedSessionID == nil
    }

    func isProvenOutstanding(
        by proof: RideAutomationDecisionIdentity,
        on deviceID: String
    ) -> Bool {
        isValidForPersistence
            && identity.deviceID == deviceID
            && identity == proof
    }
}

@MainActor
final class RideDetectionSettingsStore: ObservableObject {
    private enum Key {
        static let payload = "rideDetection.settings.v1"
        static let generation = "rideDetection.settingsGeneration.v1"
        static let watermarks = "rideDetection.decisionWatermarks.v1"
        static let pendingDecision = "rideDetection.pendingDecision.v1"
        static let locationUseAcknowledged =
            "rideDetection.locationUseAcknowledged.v1"
    }

    @Published private(set) var settings: RideDetectionSettings
    @Published private(set) var generation: UInt32
    @Published private(set) var hasAcknowledgedLocationUse: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAcknowledgedLocationUse = defaults.bool(
            forKey: Key.locationUseAcknowledged
        )
        if let data = defaults.data(forKey: Key.payload),
           var decoded = try? PropertyListDecoder().decode(
             RideDetectionSettings.self,
             from: data
           ) {
            decoded.normalize()
            if !RideAutomationRollout.allowsAutomaticStart,
               decoded.startMode == .automatic {
                decoded.startMode = .ask
            }
            settings = decoded
        } else {
            settings = RideDetectionSettings()
        }
        let storedGeneration = (
            defaults.object(forKey: Key.generation) as? NSNumber
        ).flatMap(Self.exactUInt32)
        generation = max(1, storedGeneration ?? 1)
        persist()
    }

    func setStartMode(_ value: RideStartMode) {
        guard value != .automatic
                || RideAutomationRollout.allowsAutomaticStart else {
            return
        }
        update { $0.startMode = value }
    }

    func setAutoPauseEnabled(_ value: Bool) {
        update { $0.autoPauseEnabled = value }
    }

    func setAlertMode(_ value: UInt8) {
        update { $0.alertMode = value }
    }

    func acknowledgeLocationUse() {
        guard !hasAcknowledgedLocationUse else { return }
        hasAcknowledgedLocationUse = true
        defaults.set(true, forKey: Key.locationUseAcknowledged)
    }

    /// An authenticated device-side edit wins when its serial generation is
    /// newer. Automatic start is still normalized back to Ask unless the
    /// compile-time rollout gate explicitly allows it.
    func adoptDeviceSettings(
        _ value: RideDetectionSettings,
        generation remoteGeneration: UInt32
    ) {
        guard RideAutomationSerialNumber.isNewer(
            remoteGeneration,
            than: generation
        ) else { return }
        var next = value
        next.normalize()
        let mustOverrideAutomatic =
            !RideAutomationRollout.allowsAutomaticStart
                && next.startMode == .automatic
        if mustOverrideAutomatic {
            next.startMode = .ask
        }
        let nextGeneration: UInt32
        if mustOverrideAutomatic {
            nextGeneration = remoteGeneration == UInt32.max
                ? 1
                : remoteGeneration + 1
        } else {
            nextGeneration = remoteGeneration
        }
        guard next != settings || nextGeneration != generation else { return }
        settings = next
        generation = nextGeneration
        persist()
    }

    func advanceGeneration(past remoteGeneration: UInt32) {
        guard remoteGeneration == generation
                || RideAutomationSerialNumber.isNewer(
                    remoteGeneration,
                    than: generation
                ) else { return }
        generation = remoteGeneration == UInt32.max
            ? 1
            : remoteGeneration + 1
        persist()
    }

    func loadDecisionWatermarks() -> [String: UInt32] {
        guard let values = defaults.dictionary(forKey: Key.watermarks) else {
            return [:]
        }
        var result: [String: UInt32] = [:]
        for (key, value) in values {
            guard !key.isEmpty,
                  let number = value as? NSNumber,
                  let watermark = Self.exactUInt32(number) else { continue }
            result[key] = watermark
        }
        return result
    }

    func saveDecisionWatermarks(_ values: [String: UInt32]) {
        let bounded = Dictionary(
            uniqueKeysWithValues: values.sorted { lhs, rhs in
                lhs.key < rhs.key
            }.suffix(16)
        )
        defaults.set(
            bounded.mapValues { NSNumber(value: $0) },
            forKey: Key.watermarks
        )
    }

    func loadPendingDecision() -> RideAutomationPendingDecision? {
        guard let data = defaults.data(forKey: Key.pendingDecision) else {
            return nil
        }
        guard let value = try? PropertyListDecoder().decode(
            RideAutomationPendingDecision.self,
            from: data
        ), value.isValidForPersistence else {
            defaults.removeObject(forKey: Key.pendingDecision)
            return nil
        }
        return value
    }

    func savePendingDecision(_ value: RideAutomationPendingDecision?) {
        guard let value else {
            defaults.removeObject(forKey: Key.pendingDecision)
            return
        }
        guard value.isValidForPersistence else {
            defaults.removeObject(forKey: Key.pendingDecision)
            return
        }
        guard let data = try? PropertyListEncoder().encode(value) else {
            return
        }
        defaults.set(data, forKey: Key.pendingDecision)
    }

    private func update(
        _ mutation: (inout RideDetectionSettings) -> Void
    ) {
        var next = settings
        mutation(&next)
        next.normalize()
        guard next != settings else { return }
        settings = next
        generation = generation == UInt32.max ? 1 : generation + 1
        persist()
    }

    private func persist() {
        if let data = try? PropertyListEncoder().encode(settings) {
            defaults.set(data, forKey: Key.payload)
        }
        defaults.set(Int(generation), forKey: Key.generation)
    }

    private static func exactUInt32(_ number: NSNumber) -> UInt32? {
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        return UInt32(exactly: value)
    }
}
