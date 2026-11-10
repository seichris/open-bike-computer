import Foundation

/// Shows a device screen now. Activation never edits the screen
/// configuration, its revision or the default screen.
nonisolated enum DeviceScreenActivationRequest: Equatable, Sendable {
    /// The first enabled screen of these types, in preference order. A visible
    /// screen of any listed type is kept.
    case show([RideBLEScreenTypeV1])
    case next
    case previous
}

nonisolated struct DeviceScreenActivationReply: Equatable, Sendable {
    var requestID: UInt32
    var result: RideBLEScreenActivationResultV1
    var activeInstanceID: UInt32
    /// The screen visible after the request; nil when none applies.
    var activeScreenType: RideBLEScreenTypeV1?
}

nonisolated enum DeviceScreenActivationOutcome: Equatable, Sendable {
    case replied(DeviceScreenActivationReply)
    case notConnected
    case unsupported
    case noResponse
}

/// What Siri says after a screen request. Spoken names avoid the "+" and
/// abbreviations of the on-screen titles.
nonisolated enum DeviceScreenActivationReplyText {
    /// `requested` names the asked-for screen; nil for Next and Previous.
    static func text(for outcome: DeviceScreenActivationOutcome, requested: String?) -> String {
        switch outcome {
        case .replied(let reply):
            let shown = reply.activeScreenType.map(spokenName) ?? requested ?? "that screen"
            switch reply.result {
            case .switched:
                return "Showing \(shown) on Bicino."
            case .alreadyActive:
                guard requested != nil else {
                    return "Bicino has only one screen turned on."
                }
                return "Bicino is already showing \(shown)."
            case .noMatchingScreen:
                return "Bicino has no \(requested ?? "other") screen turned on. " +
                    "You can add one under Bicino Screens in Settings."
            case .unavailable:
                return "Bicino can't switch screens right now. " +
                    "Leave its settings or pairing screen and try again."
            case .malformed:
                return "Bicino didn't understand the request. Update the app and the bike computer."
            case .busy:
                return "Bicino is still switching screens. Try again."
            }
        case .notConnected:
            return "Bicino isn't connected to this iPhone."
        case .unsupported:
            // Older firmware, or a production build before its board check.
            return "This Bicino's firmware can't switch screens from Siri yet."
        case .noResponse:
            return "Bicino didn't answer. Try again."
        }
    }

    static func spokenName(_ type: RideBLEScreenTypeV1) -> String {
        switch type {
        case .map: return "the Map"
        case .navigation: return "Navigation"
        case .rideStats: return "Ride Stats"
        case .mapPlusNavigation: return "Map and Navigation"
        case .batteryStatus: return "Battery Status"
        case .worldRadio: return "World Radio"
        case .elevation: return "Elevation"
        case .nearby: return "Nearby"
        }
    }
}

enum DeviceScreenActivationFrameCodec {
    static let headerBytes = 10
    static let replyBytes = 14

    static func request(
        requestID: UInt32,
        _ request: DeviceScreenActivationRequest
    ) -> Data? {
        guard requestID != 0 else { return nil }
        let action: RideBLEScreenActivationActionV1
        let types: [RideBLEScreenTypeV1]
        switch request {
        case .show(let requested):
            guard !requested.isEmpty,
                  requested.count <= RideBLEGeneratedProtocolV1.maximumScreenActivationTypes else {
                return nil
            }
            action = .showTypes
            types = requested
        case .next:
            action = .next
            types = []
        case .previous:
            action = .previous
            types = []
        }
        var frame = Data(RideBLEGeneratedProtocolV1.screenActivationMagic.utf8)
        frame.appendScreenActivationUInt32LE(requestID)
        frame.append(action.rawValue)
        frame.append(UInt8(types.count))
        frame.append(contentsOf: types.map(\.rawValue))
        return frame
    }

    static func isReply(_ payload: Data) -> Bool {
        payload.count >= 4 &&
            Data(payload.prefix(4)) == Data(RideBLEGeneratedProtocolV1.screenActivationResultMagic.utf8)
    }

    static func reply(_ payload: Data) -> DeviceScreenActivationReply? {
        // The shared readers index from zero; notification payloads may be slices.
        let frame = Data(payload)
        guard frame.count == replyBytes,
              isReply(frame),
              let result = RideBLEScreenActivationResultV1(rawValue: frame[8]) else {
            return nil
        }
        let requestID = frame.screenActivationUInt32LE(at: 4)
        guard requestID != 0 else { return nil }
        return DeviceScreenActivationReply(
            requestID: requestID,
            result: result,
            activeInstanceID: frame.screenActivationUInt32LE(at: 9),
            activeScreenType: RideBLEScreenTypeV1(rawValue: frame[13])
        )
    }
}

/// Pairs one in-flight activation with its reply. A newer request supersedes
/// an unanswered one, which then reports no response.
@MainActor
final class DeviceScreenActivationClient {
    typealias SendFrame = (_ frame: Data, _ failed: @escaping () -> Void) -> Bool

    private struct Pending {
        let requestID: UInt32
        let continuation: CheckedContinuation<DeviceScreenActivationOutcome, Never>
        let timeout: Task<Void, Never>
    }

    private var pending: Pending?
    private let requestIDGenerator = DeviceScreenInstanceIDGenerator.secure
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 4_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func activate(
        _ request: DeviceScreenActivationRequest,
        send: SendFrame
    ) async -> DeviceScreenActivationOutcome {
        if let pending {
            finish(requestID: pending.requestID, .noResponse)
        }
        guard let requestID = try? requestIDGenerator.generate(excluding: []),
              let frame = DeviceScreenActivationFrameCodec.request(
                requestID: requestID,
                request
              ) else {
            return .noResponse
        }
        return await withCheckedContinuation { continuation in
            let timeoutNanoseconds = timeoutNanoseconds
            pending = Pending(
                requestID: requestID,
                continuation: continuation,
                timeout: Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    self?.finish(requestID: requestID, .noResponse)
                }
            )
            let queued = send(frame) { [weak self] in
                Task { @MainActor in
                    self?.finish(requestID: requestID, .noResponse)
                }
            }
            if !queued {
                finish(requestID: requestID, .notConnected)
            }
        }
    }

    /// Consumes every activation reply, including stale ones, so they never
    /// reach the configuration transfer's chunk reassembly.
    func receive(_ payload: Data) -> Bool {
        guard DeviceScreenActivationFrameCodec.isReply(payload) else { return false }
        if let reply = DeviceScreenActivationFrameCodec.reply(payload) {
            finish(requestID: reply.requestID, .replied(reply))
        }
        return true
    }

    func disconnect() {
        if let pending {
            finish(requestID: pending.requestID, .notConnected)
        }
    }

    private func finish(requestID: UInt32, _ outcome: DeviceScreenActivationOutcome) {
        guard let current = pending, current.requestID == requestID else { return }
        pending = nil
        current.timeout.cancel()
        current.continuation.resume(returning: outcome)
    }
}

private extension Data {
    mutating func appendScreenActivationUInt32LE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// Callers pass zero-based frames.
    func screenActivationUInt32LE(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
}
