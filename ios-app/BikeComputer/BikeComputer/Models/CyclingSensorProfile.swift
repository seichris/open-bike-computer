import Foundation

struct CyclingSensorCapabilities: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let cadence = Self(rawValue: 1 << 0)
    static let power = Self(rawValue: 1 << 1)
    static let supported: Self = [.cadence, .power]

    var displayName: String {
        switch intersection(.supported) {
        case [.cadence, .power]:
            return "Cadence + Power"
        case .cadence:
            return "Cadence"
        case .power:
            return "Power"
        default:
            return "Cycling"
        }
    }

    var suggestedSensorName: String {
        switch intersection(.supported) {
        case [.cadence, .power]:
            return "Cadence + Power Sensor"
        case .cadence:
            return "Cadence Sensor"
        case .power:
            return "Power Sensor"
        default:
            return "Cycling Sensor"
        }
    }
}

enum CyclingSensorIdentityKind: Codable, Equatable, Sendable {
    /// The first implementation intentionally uses a logical profile because
    /// HKLiveWorkoutBuilder statistics do not expose a trustworthy physical
    /// cycling-peripheral identity. A future physical-device implementation
    /// can add a versioned case after validation with real sensors.
    case logical
}

struct CyclingSensorProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var capabilities: CyclingSensorCapabilities
    var isEnabled: Bool
    let identityKind: CyclingSensorIdentityKind
    let createdAt: Date
    var lastObservedAt: Date?
}

struct CyclingSensorCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let capabilities: CyclingSensorCapabilities
    let firstObservedAt: Date
    var lastObservedAt: Date

    var suggestedName: String {
        capabilities.suggestedSensorName
    }
}

struct CyclingSensorPrompt: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case connect
        case enable
        case review
    }

    let capabilities: CyclingSensorCapabilities
    let action: Action

    var title: String {
        switch capabilities.intersection(.supported) {
        case .cadence:
            return "Cadence sensor detected"
        case .power:
            return "Power sensor detected"
        default:
            return "Cycling sensor detected"
        }
    }

    var actionTitle: String {
        switch action {
        case .connect:
            return "Connect sensor?"
        case .enable:
            return "Enable sensor?"
        case .review:
            return "Review sensors"
        }
    }
}

struct WorkoutMetricTilePolicy: Equatable, Sendable {
    let enabledSensorCapabilities: CyclingSensorCapabilities

    var showsCadence: Bool {
        enabledSensorCapabilities.contains(.cadence)
    }

    var showsPower: Bool {
        enabledSensorCapabilities.contains(.power)
    }
}

enum SensorSettingsRouteDecision: Equatable, Sendable {
    case presentImmediately
    case dismissAndQueue
    case unchanged
}

enum SheetDismissalDecision: Equatable, Sendable {
    case presentQueuedSheet
    case restoreRideMetrics
    case doNothing
}

struct SensorSettingsRoutingPolicy: Sendable {
    static func openDecision(
        hasPresentedSheet: Bool,
        isSensorSettingsPresented: Bool
    ) -> SensorSettingsRouteDecision {
        if isSensorSettingsPresented {
            return .unchanged
        }
        return hasPresentedSheet ? .dismissAndQueue : .presentImmediately
    }

    static func dismissalDecision(
        hasQueuedSheet: Bool,
        isWorkoutActive: Bool
    ) -> SheetDismissalDecision {
        if hasQueuedSheet {
            return .presentQueuedSheet
        }
        return isWorkoutActive ? .restoreRideMetrics : .doNothing
    }
}
