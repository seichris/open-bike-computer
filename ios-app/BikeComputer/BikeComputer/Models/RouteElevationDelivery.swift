import Foundation

/// Phone-side delivery of the active route's elevation over one authenticated
/// BLE session. Pure: the caller supplies time, the token source and the
/// transport, so ordering, retries and pacing are testable without a device.
///
/// Every content change takes a new nonzero revision. A profile travels as one
/// atomic BEGIN/CHUNK/COMMIT batch and counts as delivered only after the
/// device's COMMIT acknowledgement; progress follows only for that revision.
nonisolated struct RouteElevationDeliveryPlannerV1 {
    typealias DeviceProtocol = RouteElevationDeviceProtocolV1

    nonisolated struct RouteKey: Equatable, Sendable {
        let navigationGeneration: UInt32
        let routeID: UUID
        let revision: UInt32
    }

    nonisolated enum Content: Equatable {
        case loading
        case unavailable(DeviceProtocol.Reason)
        case profile(RouteElevationProfileV1)

        init(_ state: RouteElevationStateV1) {
            switch state {
            case .loading: self = .loading
            case .ready(let profile): self = .profile(profile)
            case .unavailable(let reason): self = .unavailable(reason.deviceReason)
            }
        }
    }

    nonisolated enum Status: Equatable, Sendable {
        case idle
        case sending
        case delivered
        case showingState
        case failed
    }

    nonisolated struct Progress: Equatable {
        let meters: Double
        let position: RouteElevationPositionV1?
        let onRoute: Bool
    }

    static let acknowledgementTimeout: TimeInterval = 6
    static let maximumAttempts = 3
    static let progressInterval: TimeInterval = 1
    static let progressRefreshInterval: TimeInterval = 15

    private struct Transfer {
        let revision: UInt16
        let body: Data
        var transferID: UInt16
        var attempts: Int
        var deadline: TimeInterval
        var retryNow = false
    }

    private(set) var status: Status = .idle
    private(set) var routeToken: UInt32 = 0
    private(set) var revision: UInt16 = 0
    private(set) var deliveredRevision: UInt16?
    private var maximumWriteLength: Int?
    private var route: RouteKey?
    private var content: Content?
    private var pendingState: (state: DeviceProtocol.State, reason: DeviceProtocol.Reason)?
    private var pendingProfile: RouteElevationProfileV1?
    private var needsClear = false
    private var deviceHoldsRoute = false
    private var transfer: Transfer?
    private var lastTransferID: UInt16 = 0
    private var progress: Progress?
    private var progressSequence: UInt16 = 0
    private var lastProgressSignature: Data?
    private var lastProgressAt: TimeInterval = -.infinity
    private let makeToken: () -> UInt32

    init(makeToken: @escaping () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }) {
        self.makeToken = makeToken
    }

    var isConnected: Bool { maximumWriteLength != nil }
    var hasRoute: Bool { route != nil }
    var hasWork: Bool { needsClear || pendingState != nil || pendingProfile != nil || transfer != nil }

    /// A new session starts empty on the device, so everything is resent with
    /// a fresh token.
    mutating func connect(maximumWriteLength: Int) {
        self.maximumWriteLength = maximumWriteLength
        resetLink()
        if route != nil {
            routeToken = makeToken()
            revision = 0
            schedule(content)
        }
    }

    mutating func disconnect() {
        maximumWriteLength = nil
        resetLink()
    }

    mutating func update(route newRoute: RouteKey?, content newContent: Content?) {
        guard let newRoute, let newContent else {
            if route != nil, deviceHoldsRoute { needsClear = true }
            route = nil
            content = nil
            pendingState = nil
            pendingProfile = nil
            transfer = nil
            deliveredRevision = nil
            progress = nil
            status = .idle
            return
        }
        if newRoute != route {
            route = newRoute
            routeToken = makeToken()
            revision = 0
            transfer = nil
            deliveredRevision = nil
            progress = nil
            progressSequence = 0
            lastProgressSignature = nil
            // The new route's first frame replaces the device binding.
            needsClear = false
            content = newContent
            schedule(newContent)
        } else if newContent != content {
            content = newContent
            transfer = nil
            deliveredRevision = nil
            schedule(newContent)
        }
    }

    mutating func update(progress newProgress: Progress?) {
        progress = newProgress
    }

    mutating func receive(_ acknowledgement: DeviceProtocol.Acknowledgement) {
        if acknowledgement.op == DeviceProtocol.Op.state.rawValue, acknowledgement.result == .unsupported {
            // The device speaks another frame version; stop instead of retrying.
            failPermanently()
            return
        }
        guard acknowledgement.op == DeviceProtocol.Op.commit.rawValue, var pending = transfer,
              acknowledgement.transferID == pending.transferID else { return }
        switch acknowledgement.result {
        case .applied where acknowledgement.routeToken == routeToken && acknowledgement.revision == pending.revision:
            transfer = nil
            deliveredRevision = pending.revision
            status = .delivered
            lastProgressSignature = nil
            lastProgressAt = -.infinity
        case .unsupported:
            failPermanently()
        default:
            pending.retryNow = true
            transfer = pending
        }
    }

    /// Performs at most one logical send. `send` enqueues an atomic batch, or
    /// one coalescible progress frame, and returns false if it was not queued.
    mutating func tick(now: TimeInterval, send: (_ frames: [Data], _ coalescible: Bool) -> Bool) {
        guard let maximumWriteLength else { return }
        if needsClear {
            let frame = DeviceProtocol.stateFrame(routeToken: 0, revision: 0, state: .cleared, reason: .unspecified)
            guard send([frame], false) else { return }
            needsClear = false
            deviceHoldsRoute = false
        }
        guard route != nil else { return }
        if let pending = pendingState {
            let next = Self.revision(after: revision)
            let frame = DeviceProtocol.stateFrame(
                routeToken: routeToken, revision: next, state: pending.state, reason: pending.reason
            )
            guard send([frame], false) else { return }
            revision = next
            pendingState = nil
            deviceHoldsRoute = true
            status = pending.state == .failed ? .failed : .showingState
            return
        }
        if let profile = pendingProfile {
            let next = Self.revision(after: revision)
            let transferID = Self.transferID(after: lastTransferID)
            guard let body = DeviceProtocol.encodeBody(
                profile, routeToken: routeToken, revision: next, points: DeviceProtocol.displayPoints(profile)
            ), let frames = DeviceProtocol.transferFrames(
                body: body, routeToken: routeToken, revision: next, transferID: transferID,
                maximumWriteLength: maximumWriteLength
            ) else {
                pendingProfile = nil
                pendingState = (.failed, .transferFailed)
                return
            }
            guard send(frames, false) else { return }
            lastTransferID = transferID
            revision = next
            pendingProfile = nil
            deviceHoldsRoute = true
            transfer = Transfer(
                revision: next, body: body, transferID: transferID, attempts: 1,
                deadline: now + Self.acknowledgementTimeout
            )
            status = .sending
            return
        }
        if var pending = transfer {
            guard pending.retryNow || now >= pending.deadline else { return }
            guard pending.attempts < Self.maximumAttempts else {
                transfer = nil
                pendingState = (.failed, .transferFailed)
                return
            }
            let transferID = Self.transferID(after: lastTransferID)
            guard let frames = DeviceProtocol.transferFrames(
                body: pending.body, routeToken: routeToken, revision: pending.revision,
                transferID: transferID, maximumWriteLength: maximumWriteLength
            ), send(frames, false) else { return }
            lastTransferID = transferID
            pending.transferID = transferID
            pending.attempts += 1
            pending.deadline = now + Self.acknowledgementTimeout
            pending.retryNow = false
            transfer = pending
            return
        }
        guard status == .delivered, let deliveredRevision, let progress else { return }
        let meters = progress.meters.isFinite
            ? UInt32(clamping: DeviceProtocol.whole(max(0, progress.meters)))
            : DeviceProtocol.unknownProgress
        let signature = DeviceProtocol.progressFrame(
            routeToken: routeToken, revision: deliveredRevision, sequence: 0,
            progressMeters: meters, position: progress.position, onRoute: progress.onRoute
        )
        let elapsed = now - lastProgressAt
        let due = signature != lastProgressSignature
            ? elapsed >= Self.progressInterval
            : elapsed >= Self.progressRefreshInterval
        guard due else { return }
        let sequence = progressSequence &+ 1
        let frame = DeviceProtocol.progressFrame(
            routeToken: routeToken, revision: deliveredRevision, sequence: sequence,
            progressMeters: meters, position: progress.position, onRoute: progress.onRoute
        )
        guard send([frame], true) else { return }
        progressSequence = sequence
        lastProgressSignature = signature
        lastProgressAt = now
    }

    private mutating func schedule(_ content: Content?) {
        pendingState = nil
        pendingProfile = nil
        switch content {
        case .loading?: pendingState = (.loading, .unspecified)
        case .unavailable(let reason)?: pendingState = (.unavailable, reason)
        case .profile(let profile)?: pendingProfile = profile
        case nil: break
        }
    }

    private mutating func resetLink() {
        transfer = nil
        deliveredRevision = nil
        needsClear = false
        deviceHoldsRoute = false
        pendingState = nil
        pendingProfile = nil
        lastProgressSignature = nil
        lastProgressAt = -.infinity
        status = .idle
    }

    private mutating func failPermanently() {
        transfer = nil
        pendingState = nil
        pendingProfile = nil
        status = .failed
    }

    static func transferID(after value: UInt16) -> UInt16 {
        value == UInt16.max ? 1 : value + 1
    }

    static func revision(after value: UInt16) -> UInt16 {
        value == UInt16.max ? 1 : value + 1
    }
}

/// What the phone can honestly say about the device's copy of the profile.
/// `delivered` means the device validated and applied it, not that the
/// Elevation screen is currently visible.
nonisolated enum RouteElevationDeviceStatusV1: Equatable, Sendable {
    case notConnected
    case connecting
    case unsupportedFirmware
    case sending
    case delivered
    case showingState
    case failed
}

nonisolated struct RouteElevationNavigationPresentationV1: Equatable {
    let state: RouteElevationStateV1
    let progressMeters: Double?
    let position: RouteElevationPositionV1?
    let onRoute: Bool
    let device: RouteElevationDeviceStatusV1
}
