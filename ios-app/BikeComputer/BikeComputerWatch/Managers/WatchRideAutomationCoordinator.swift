import Combine
import Foundation

/// Consumes detector decisions only while Apple Watch owns the scoped Bicino
/// lease. Phone-owned rides continue to use RideAutomationCoordinator; both
/// paths share the same wire frame, admission policy, full HealthKit session
/// UUID, and durable Watch transition markers.
@MainActor
final class WatchRideAutomationCoordinator {
    private struct PendingDecision {
        let deviceID: String
        let frame: RideAutomationFrame
        let expectedState: WorkoutSessionStateV1
    }

    private let manager: WatchWorkoutManager
    private let deviceLink: WatchDeviceLink
    private var cancellables = Set<AnyCancellable>()
    private var activeDeviceID: String?
    private var lastRideGeneration: UInt32?
    private var highestSequenceByGeneration: [UInt32: UInt32] = [:]
    private var latestDeviceMonotonicSeconds: UInt32?
    private var pendingDecision: PendingDecision?

    init(manager: WatchWorkoutManager, deviceLink: WatchDeviceLink) {
        self.manager = manager
        self.deviceLink = deviceLink
        deviceLink.onRideAutomationFrame = { [weak self] frame in
            self?.receive(frame)
        }
        deviceLink.$state
            .sink { [weak self] state in
                self?.receiveLinkState(state)
            }
            .store(in: &cancellables)
        manager.$snapshot
            .sink { [weak self] _ in
                self?.confirmPendingDecisionIfAuthoritative()
            }
            .store(in: &cancellables)
        Publishers.CombineLatest3(
            manager.$rideDetectionSettings,
            manager.$rideDetectionSettingsGeneration,
            manager.$rideDetectionSettingsConfirmed
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            self?.sendConfigurationAndResynchronize()
        }
        .store(in: &cancellables)
    }

    private func receiveLinkState(_ state: WatchDeviceLinkState) {
        guard case .ready(let deviceID) = state else {
            activeDeviceID = nil
            return
        }
        if activeDeviceID != deviceID {
            if pendingDecision?.deviceID != deviceID {
                pendingDecision = nil
            }
            activeDeviceID = deviceID
            lastRideGeneration = nil
            highestSequenceByGeneration.removeAll()
            latestDeviceMonotonicSeconds = nil
        }
        sendConfigurationAndResynchronize()
    }

    private func receive(_ frame: RideAutomationFrame) {
        guard activeDeviceID != nil else { return }
        lastRideGeneration = frame.rideGeneration
        noteDeviceMonotonic(frame.monotonicSeconds)
        switch frame.kind {
        case .decision:
            handleDecision(frame)
        case .configurationAcknowledgement:
            if frame.result != .accepted
                || frame.watermarkOrConfigGeneration
                    != manager.rideDetectionSettingsGeneration {
                sendConfiguration()
            }
        case .resynchronize:
            if pendingDecision != nil,
               frame.watermarkOrConfigGeneration == 0 {
                self.pendingDecision = nil
            } else if let pendingDecision,
                      frame.watermarkOrConfigGeneration
                        == pendingDecision.frame.decisionSequence {
                confirmPendingDecisionIfAuthoritative()
            }
            if !frameConfigurationMatches(frame) {
                sendConfiguration()
            }
        case .cancellation:
            if pendingDecision?.frame.rideGeneration
                    == frame.rideGeneration,
               pendingDecision?.frame.decisionSequence
                    == frame.decisionSequence {
                pendingDecision = nil
            }
        case .acknowledgement, .confirmation, .configuration,
             .promptResponse:
            break
        }
    }

    private func handleDecision(_ frame: RideAutomationFrame) {
        guard let deviceID = activeDeviceID,
              frameConfigurationMatches(frame),
              !isExpired(frame) else {
            sendResponse(to: frame, kind: .acknowledgement, result: .stale)
            sendConfigurationAndResynchronize()
            return
        }
        let memoryWatermark = highestSequenceByGeneration[
            frame.rideGeneration
        ] ?? 0
        let durableWatermark = manager.directRideAutomationDecisionWatermark(
            deviceID: deviceID,
            rideGeneration: frame.rideGeneration
        )
        let highest = newestWatermark(memoryWatermark, durableWatermark)
        let admission = RideAutomationAdmissionPolicy.resolve(
            frame: frame,
            settings: manager.rideDetectionSettings,
            workoutState: manager.snapshot.state,
            pauseOrigin: manager.snapshot.pauseOrigin,
            expectedSessionID: manager.activeSessionID,
            highestDecisionSequence: highest
        )
        switch admission {
        case .pause, .resume:
            var result = manager.requestDirectRideAutomationTransition(
                frame,
                deviceID: deviceID
            )
            if result != .accepted,
               !recordDecision(frame, deviceID: deviceID) {
                result = .rejected
            }
            guard result == .accepted else {
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: result
                )
                return
            }
            noteDecision(frame)
            pendingDecision = PendingDecision(
                deviceID: deviceID,
                frame: frame,
                expectedState: admission == .pause ? .paused : .running
            )
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .accepted
            )
            confirmPendingDecisionIfAuthoritative()
        case .duplicate:
            if pendingDecision?.frame.rideGeneration
                    == frame.rideGeneration,
               pendingDecision?.frame.decisionSequence
                    == frame.decisionSequence {
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: .accepted
                )
                confirmPendingDecisionIfAuthoritative()
            } else if transitionIsAlreadyAuthoritative(frame) {
                sendResponse(
                    to: frame,
                    kind: .confirmation,
                    result: .accepted,
                    sessionID: manager.activeSessionID
                )
            } else if let result = manager
                .retryPendingDirectRideAutomationTransition(
                    frame,
                    deviceID: deviceID
                ) {
                guard result == .accepted else {
                    sendResponse(
                        to: frame,
                        kind: .acknowledgement,
                        result: result
                    )
                    return
                }
                noteDecision(frame)
                pendingDecision = PendingDecision(
                    deviceID: deviceID,
                    frame: frame,
                    expectedState: frame.transition == .pause
                        ? .paused
                        : .running
                )
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: .accepted
                )
                confirmPendingDecisionIfAuthoritative()
            } else {
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: .stale
                )
            }
        case .prompt, .start:
            // A direct link normally exists because a workout is already
            // active. Pre-workout start prompting remains iPhone-owned.
            guard recordDecision(frame, deviceID: deviceID) else {
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: .rejected
                )
                return
            }
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .watchUnavailable
            )
        case .reject(let result):
            guard recordDecision(frame, deviceID: deviceID) else {
                sendResponse(
                    to: frame,
                    kind: .acknowledgement,
                    result: .rejected
                )
                return
            }
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: result
            )
        }
    }

    private func confirmPendingDecisionIfAuthoritative() {
        guard let pendingDecision,
              activeDeviceID == pendingDecision.deviceID,
              transitionIsAlreadyAuthoritative(pendingDecision.frame),
              manager.snapshot.state == pendingDecision.expectedState else {
            return
        }
        sendResponse(
            to: pendingDecision.frame,
            kind: .confirmation,
            result: .accepted,
            sessionID: manager.activeSessionID
        )
        self.pendingDecision = nil
    }

    private func transitionIsAlreadyAuthoritative(
        _ frame: RideAutomationFrame
    ) -> Bool {
        guard frame.sessionID == manager.activeSessionID,
              manager.snapshot.detectorProfileVersion
                == frame.profileVersion,
              manager.snapshot.lastTransitionOrigin == .automatic else {
            return false
        }
        switch frame.transition {
        case .pause:
            return manager.snapshot.state == .paused
                && manager.snapshot.pauseOrigin == .automatic
        case .resume:
            return manager.snapshot.state == .running
        case .none, .start:
            return false
        }
    }

    private func frameConfigurationMatches(
        _ frame: RideAutomationFrame
    ) -> Bool {
        let settings = manager.rideDetectionSettings
        return manager.rideDetectionSettingsConfirmed
            && manager.rideDetectionSettingsGeneration != 0
            && frame.watermarkOrConfigGeneration
                == manager.rideDetectionSettingsGeneration
            && frame.startMode == settings.startMode
            && frame.autoPauseEnabled == settings.autoPauseEnabled
            && frame.alertMode == settings.alertMode
    }

    private func sendConfigurationAndResynchronize() {
        guard let activeDeviceID else { return }
        sendConfiguration()
        sendResynchronize(deviceID: activeDeviceID)
    }

    private func sendConfiguration() {
        guard activeDeviceID != nil else { return }
        let generation = lastRideGeneration
            ?? max(1, manager.rideDetectionSettingsGeneration)
        let settings = manager.rideDetectionSettings
        if manager.rideDetectionSettingsConfirmed,
           manager.rideDetectionSettingsGeneration != 0 {
            _ = deviceLink.sendRideAutomationFrame(RideAutomationFrame(
                kind: .configuration,
                rideGeneration: generation,
                profileVersion: 1,
                watermarkOrConfigGeneration:
                    manager.rideDetectionSettingsGeneration,
                startMode: settings.startMode,
                autoPauseEnabled: settings.autoPauseEnabled,
                alertMode: settings.alertMode
            ))
        }
    }

    private func sendResynchronize(deviceID: String) {
        let generation = lastRideGeneration
            ?? max(1, manager.rideDetectionSettingsGeneration)
        let settings = manager.rideDetectionSettings
        let memoryWatermark = highestSequenceByGeneration[generation] ?? 0
        let durableWatermark = manager.directRideAutomationDecisionWatermark(
            deviceID: deviceID,
            rideGeneration: generation
        )
        _ = deviceLink.sendRideAutomationFrame(RideAutomationFrame(
            kind: .resynchronize,
            rideGeneration: generation,
            profileVersion: 1,
            sessionID: manager.activeSessionID,
            watermarkOrConfigGeneration:
                newestWatermark(memoryWatermark, durableWatermark),
            startMode: settings.startMode,
            autoPauseEnabled: settings.autoPauseEnabled,
            alertMode: settings.alertMode
        ))
    }

    @discardableResult
    private func sendResponse(
        to request: RideAutomationFrame,
        kind: RideAutomationKind,
        result: RideAutomationResult,
        sessionID: UUID? = nil
    ) -> Bool {
        deviceLink.sendRideAutomationFrame(RideAutomationFrame(
            kind: kind,
            transition: request.transition,
            origin: request.origin,
            result: result,
            rideGeneration: request.rideGeneration,
            decisionSequence: request.decisionSequence,
            evidenceMask: request.evidenceMask,
            profileVersion: request.profileVersion,
            sessionID: sessionID ?? request.sessionID,
            watermarkOrConfigGeneration:
                manager.rideDetectionSettingsGeneration,
            startMode: manager.rideDetectionSettings.startMode,
            autoPauseEnabled:
                manager.rideDetectionSettings.autoPauseEnabled,
            alertMode: manager.rideDetectionSettings.alertMode,
            candidateBeganSeconds: request.candidateBeganSeconds,
            monotonicSeconds: request.monotonicSeconds,
            sourceHealthMask: request.sourceHealthMask,
            acknowledgedKind: kind == .acknowledgement
                ? request.kind
                : nil
        ))
    }

    private func noteDeviceMonotonic(_ value: UInt32) {
        guard let current = latestDeviceMonotonicSeconds else {
            latestDeviceMonotonicSeconds = value
            return
        }
        if value &- current < 0x8000_0000 {
            latestDeviceMonotonicSeconds = value
        }
    }

    private func isExpired(_ frame: RideAutomationFrame) -> Bool {
        guard let latestDeviceMonotonicSeconds else { return false }
        return RideAutomationMonotonicClock.isExpired(
            sampleSeconds: frame.monotonicSeconds,
            latestSeconds: latestDeviceMonotonicSeconds,
            maximumAgeSeconds: 10
        )
    }

    private func trimWatermarks() {
        while highestSequenceByGeneration.count > 16 {
            guard let generation = highestSequenceByGeneration.keys.first(
                where: { $0 != lastRideGeneration }
            ) else { break }
            highestSequenceByGeneration[generation] = nil
        }
    }

    private func recordDecision(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) -> Bool {
        guard manager.recordDirectRideAutomationDecision(
            deviceID: deviceID,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence
        ) else { return false }
        noteDecision(frame)
        return true
    }

    private func noteDecision(_ frame: RideAutomationFrame) {
        highestSequenceByGeneration[frame.rideGeneration] =
            frame.decisionSequence
        trimWatermarks()
    }

    private func newestWatermark(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
        if lhs == 0 { return rhs }
        if rhs == 0 { return lhs }
        return RideAutomationSerialNumber.isNewer(rhs, than: lhs) ? rhs : lhs
    }
}
