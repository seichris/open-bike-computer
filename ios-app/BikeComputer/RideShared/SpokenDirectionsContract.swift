import Foundation

/// Speech payloads are always inside the authenticated speech channel. These
/// codecs do not authorize an owner, prove asset readiness, or start playback.
struct SpokenCueV1: Equatable, Sendable {
    let token: UInt64
    let generation: UInt32
    let sequence: UInt32
    let stepID: UInt32
    let progressRevision: UInt32
    let phase: SpokenPhaseV1
    let maneuver: SpokenManeuverV1
    let distanceBucket: UInt16
    let volume: UInt8
    let startLifetimeMS: UInt16
    let assetKey: Data // 16 zero bytes means resident only

    var isValid: Bool {
        token != 0 && generation != 0 && sequence != 0 && stepID != 0 &&
        progressRevision != 0 && volume <= 100 && startLifetimeMS > 0 &&
        startLifetimeMS <= SpokenDirectionsGeneratedV1.maximumStartLifetimeMs &&
        assetKey.count == 16 && Self.validSemantic(phase, maneuver, distanceBucket) &&
        (phase == .prepare || assetKey.allSatisfy { $0 == 0 })
    }

    static func validSemantic(_ phase: SpokenPhaseV1, _ maneuver: SpokenManeuverV1, _ distance: UInt16) -> Bool {
        switch maneuver {
        case .unknown: return false
        case .arrive: return phase == .arrival && distance == 0
        case .rerouting, .continueRoute: return phase == .action && distance == 0
        default:
            return (phase == .action && distance == 0) ||
                (phase == .prepare && [50, 100, 200].contains(distance))
        }
    }

    func encoded() -> Data? {
        guard isValid else { return nil }
        var data = Data(SpokenDirectionsGeneratedV1.cueMagic.utf8)
        data.append(contentsOf: [UInt8(SpokenDirectionsGeneratedV1.version), phase.rawValue, maneuver.rawValue, volume])
        SpokenWireV1.append(token, to: &data)
        for value in [generation, sequence, stepID, progressRevision] { SpokenWireV1.append(value, to: &data) }
        SpokenWireV1.append(distanceBucket, to: &data)
        SpokenWireV1.append(startLifetimeMS, to: &data)
        data.append(contentsOf: [phase == .arrival ? 1 : 0, 0, 0, 0])
        data.append(assetKey)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count == SpokenDirectionsGeneratedV1.cueBytes else { return nil }
        let b = Array(data)
        guard Array(b[0..<4]) == Array(SpokenDirectionsGeneratedV1.cueMagic.utf8),
              b[4] == SpokenDirectionsGeneratedV1.version,
              let phase = SpokenPhaseV1(rawValue: b[5]),
              let maneuver = SpokenManeuverV1(rawValue: b[6]),
              b[36] == (phase == .arrival ? 1 : 0), b[37...39].allSatisfy({ $0 == 0 }) else { return nil }
        let value = Self(token: SpokenWireV1.u64(b, 8), generation: SpokenWireV1.u32(b, 16),
                         sequence: SpokenWireV1.u32(b, 20), stepID: SpokenWireV1.u32(b, 24),
                         progressRevision: SpokenWireV1.u32(b, 28), phase: phase, maneuver: maneuver,
                         distanceBucket: SpokenWireV1.u16(b, 32), volume: b[7],
                         startLifetimeMS: SpokenWireV1.u16(b, 34), assetKey: Data(b[40..<56]))
        return value.isValid ? value : nil
    }
}

struct SpokenRouteControlV1: Equatable, Sendable {
    let action: SpokenControlActionV1
    let token: UInt64
    let generation: UInt32
    let revision: UInt32
    let stepID: UInt32
    let progressRevision: UInt32
    let enabled: Bool
    let volume: UInt8
    let leaseMS: UInt16

    var isValid: Bool {
        token != 0 && generation != 0 && revision != 0 && stepID != 0 &&
        progressRevision != 0 && volume <= 100 && leaseMS > 0 &&
        leaseMS <= SpokenDirectionsGeneratedV1.progressLeaseMs
    }

    func encoded() -> Data? {
        guard isValid else { return nil }
        var data = Data(SpokenDirectionsGeneratedV1.controlMagic.utf8)
        data.append(contentsOf: [UInt8(SpokenDirectionsGeneratedV1.version), action.rawValue, enabled ? 1 : 0, volume])
        SpokenWireV1.append(token, to: &data)
        for value in [generation, revision, stepID, progressRevision] { SpokenWireV1.append(value, to: &data) }
        SpokenWireV1.append(leaseMS, to: &data)
        SpokenWireV1.append(UInt16(0), to: &data)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count == SpokenDirectionsGeneratedV1.controlBytes else { return nil }
        let b = Array(data)
        guard Array(b[0..<4]) == Array(SpokenDirectionsGeneratedV1.controlMagic.utf8),
              b[4] == SpokenDirectionsGeneratedV1.version,
              let action = SpokenControlActionV1(rawValue: b[5]), b[6] <= 1,
              b[34] == 0, b[35] == 0 else { return nil }
        let value = Self(action: action, token: SpokenWireV1.u64(b, 8),
                         generation: SpokenWireV1.u32(b, 16), revision: SpokenWireV1.u32(b, 20),
                         stepID: SpokenWireV1.u32(b, 24), progressRevision: SpokenWireV1.u32(b, 28),
                         enabled: b[6] == 1, volume: b[7], leaseMS: SpokenWireV1.u16(b, 32))
        return value.isValid ? value : nil
    }
}

enum SpokenWireV1 {
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(u16(b, at)) | UInt32(u16(b, at + 2)) << 16
    }
    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(b, at)) | UInt64(u32(b, at + 4)) << 32
    }
}
