import Combine
import Foundation
import AudioToolbox
import UIKit

@MainActor
final class RideAutomationCoordinator: ObservableObject {
    struct StartPrompt: Identifiable, Equatable {
        let identity: RideAutomationDecisionIdentity
        let frame: RideAutomationFrame

        var id: RideAutomationDecisionIdentity { identity }
    }

    @Published private(set) var startPrompt: StartPrompt?
    @Published private(set) var lastError: RideAutomationResult?
    @Published private(set) var promptSecondsRemaining = 0
    @Published private(set) var confirmedDeviceSettings:
        RideDetectionSettings?

    private let bleManager: BLEManager
    private let workoutManager: WorkoutMirrorManager
    private let settingsStore: RideDetectionSettingsStore
    private let watchAvailability: WorkoutWatchAvailabilityMonitor?
    private var cancellables: Set<AnyCancellable> = []
    private var highestSequenceByGeneration: [String: UInt32] = [:]
    private var acknowledgementByDecision:
        [RideAutomationDecisionIdentity: RideAutomationResult] = [:]
    private var pendingDecision: RideAutomationPendingDecision?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var promptCountdownTask: Task<Void, Never>?
    private var resynchronizationTask: Task<Void, Never>?
    private var lastRideGenerationByDevice: [String: UInt32] = [:]
    private var latestDeviceMonotonicByDevice: [String: UInt32] = [:]
    private var confirmedConfigurationGenerationByDevice:
        [String: UInt32] = [:]
    private var configurationRetryCountByDevice: [String: Int] = [:]
    private var startAnnotationRequestedFor:
        RideAutomationDecisionIdentity?

    init(
        bleManager: BLEManager,
        workoutManager: WorkoutMirrorManager,
        settingsStore: RideDetectionSettingsStore,
        watchAvailability: WorkoutWatchAvailabilityMonitor? = nil
    ) {
        self.bleManager = bleManager
        self.workoutManager = workoutManager
        self.settingsStore = settingsStore
        self.watchAvailability = watchAvailability
        highestSequenceByGeneration = settingsStore.loadDecisionWatermarks()
        pendingDecision = settingsStore.loadPendingDecision()

        bleManager.onRideAutomationFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handle(frame)
            }
        }
        bleManager.$supportsRideAutomation
            .combineLatest(bleManager.$connectedDeviceID)
            .sink { [weak self] supported, deviceID in
                guard supported, let deviceID else {
                    self?.resynchronizationTask?.cancel()
                    self?.resynchronizationTask = nil
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    if let pending = self?.pendingDecision,
                       pending.identity.deviceID != deviceID {
                        // The prior firmware has its own bounded 30-second
                        // logical timeout. Retire the local outbox rather than
                        // sending it to, or indefinitely blocking, a new bike.
                        self?.clearPendingDecision()
                    }
                    // Recovery controls remain inert until an authenticated
                    // device decision retry or resynchronization proves that
                    // this exact boot generation and sequence is outstanding.
                    self?.sendConfigurationAndResynchronize()
                    self?.startPeriodicResynchronization()
                }
            }
            .store(in: &cancellables)
        settingsStore.$generation
            .dropFirst()
            .sink { [weak self] _ in
                // @Published emits from willSet. Defer one main turn so the
                // frame reads the committed settings and generation together.
                DispatchQueue.main.async { [weak self] in
                    self?.confirmedDeviceSettings = nil
                    if let deviceID = self?.bleManager.connectedDeviceID {
                        self?.configurationRetryCountByDevice[deviceID] = 0
                    }
                    self?.watchAvailability?
                        .setConfirmedRideDetectionSettings(
                            nil,
                            generation: nil
                        )
                    self?.sendConfigurationAndResynchronize()
                }
            }
            .store(in: &cancellables)
        workoutManager.store.$presentation
            .sink { [weak self] presentation in
                self?.confirmIfAuthoritative(presentation)
            }
            .store(in: &cancellables)
    }

    func acceptStartPrompt() {
        guard let prompt = startPrompt else { return }
        guard bleManager.connectedDeviceID == prompt.identity.deviceID else {
            return
        }
        guard sendPromptResponse(
            to: prompt.frame,
            result: .accepted
        ) else {
            lastError = .watchUnavailable
            return
        }
        startPrompt = nil
        cancelPromptCountdown()
        beginPendingDecision(
            identity: prompt.identity,
            frame: prompt.frame,
            expectedState: .running
        )
    }

    func dismissStartPrompt() {
        guard let prompt = startPrompt else { return }
        guard bleManager.connectedDeviceID == prompt.identity.deviceID else {
            return
        }
        sendPromptResponse(to: prompt.frame, result: .rejected)
        startPrompt = nil
        cancelPromptCountdown()
        resolvePendingDecision(result: .rejected)
    }

    func dismissError() {
        lastError = nil
    }

    private func handle(_ frame: RideAutomationFrame) {
        guard let deviceID = bleManager.connectedDeviceID else { return }
        if frame.kind == .decision,
           let pending = pendingDecision,
           pending.identity.deviceID != deviceID {
            sendUnboundResponse(
                to: frame,
                kind: .acknowledgement,
                result: .stale
            )
            return
        }
        switch frame.kind {
        case .configurationAcknowledgement:
            handleConfigurationAcknowledgement(frame, deviceID: deviceID)
            return
        case .acknowledgement:
            handleAcknowledgement(frame, deviceID: deviceID)
            return
        case .confirmation:
            return
        case .cancellation:
            handleCancellation(frame, deviceID: deviceID)
            return
        case .promptResponse:
            handlePromptResponse(frame, deviceID: deviceID)
            return
        case .resynchronize:
            handleResynchronization(frame, deviceID: deviceID)
            return
        case .configuration:
            sendResponse(
                to: frame,
                kind: .configurationAcknowledgement,
                result: .accepted
            )
            return
        case .decision:
            break
        }

        let generationKey = "\(deviceID):\(frame.rideGeneration)"
        let identity = RideAutomationDecisionIdentity(
            deviceID: deviceID,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence
        )
        let highest = highestSequenceByGeneration[generationKey] ?? 0
        lastRideGenerationByDevice[deviceID] = frame.rideGeneration
        guard decisionConfigurationMatches(frame, deviceID: deviceID),
              !isExpiredDecision(frame, deviceID: deviceID) else {
            lastError = .stale
            sendResponse(to: frame, kind: .acknowledgement, result: .stale)
            sendConfigurationAndResynchronize()
            return
        }
        noteDeviceMonotonic(frame.monotonicSeconds, deviceID: deviceID)
        let presentation = workoutManager.store.presentation
        let admission = RideAutomationAdmissionPolicy.resolve(
            frame: frame,
            settings: settingsStore.settings,
            workoutState: presentation.sessionState,
            pauseOrigin: presentation.snapshot.pauseOrigin,
            expectedSessionIdentityHash:
                RideAutomationAdmissionPolicy.sessionIdentityHash(
                    presentation.sessionID
                ),
            highestDecisionSequence: highest
        )
        if admission != .duplicate {
            highestSequenceByGeneration[generationKey] =
                frame.decisionSequence
            trimWatermarks(keeping: generationKey)
            settingsStore.saveDecisionWatermarks(
                highestSequenceByGeneration
            )
        }

        switch admission {
        case .duplicate:
            if pendingDecision?.identity == identity {
                restorePendingDecision(
                    for: deviceID,
                    provenIdentity: identity
                )
                return
            }
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: acknowledgementByDecision[identity] ?? .stale
            )
        case .reject(let result):
            if result == .sessionMismatch || result == .watchUnavailable {
                lastError = result
            }
            acknowledgementByDecision[identity] = result
            sendResponse(to: frame, kind: .acknowledgement, result: result)
        case .prompt:
            supersedePendingDecision(ifDifferentFrom: identity)
            presentStartPrompt(identity: identity, frame: frame)
            acknowledgementByDecision[identity] = .accepted
            beginPendingDecision(
                identity: identity,
                frame: frame,
                expectedState: nil
            )
            sendResponse(to: frame, kind: .acknowledgement, result: .accepted)
        case .start:
            guard presentation.canStartNewWorkout else {
                sendResponse(to: frame, kind: .acknowledgement, result: .stale)
                return
            }
            acknowledgementByDecision[identity] = .accepted
            sendResponse(to: frame, kind: .acknowledgement, result: .accepted)
            supersedePendingDecision(ifDifferentFrom: identity)
            beginPendingDecision(
                identity: identity,
                frame: frame,
                expectedState: .running
            )
            launchPendingAutomaticStart()
        case .pause, .resume:
            let context = automaticControlContext(for: frame)
            guard workoutManager.requestAutomaticTransition(
                frame.transition,
                context: context
            ) else {
                sendResponse(to: frame, kind: .acknowledgement, result: .rejected)
                return
            }
            acknowledgementByDecision[identity] = .accepted
            sendResponse(to: frame, kind: .acknowledgement, result: .accepted)
            supersedePendingDecision(ifDifferentFrom: identity)
            beginPendingDecision(
                identity: identity,
                frame: frame,
                expectedState: admission == .pause ? .paused : .running
            )
        }
    }

    private func handlePromptResponse(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) {
        let identity = RideAutomationDecisionIdentity(
            deviceID: deviceID,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence
        )
        guard frame.transition == .start,
              frame.origin == .automatic,
              frame.startMode == .ask,
              let pending = pendingDecision,
              pending.identity == identity,
              pending.frame.transition == .start else {
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .stale
            )
            return
        }
        switch frame.result {
        case .accepted:
            guard sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .accepted
            ) else {
                return
            }
            startPrompt = nil
            cancelPromptCountdown()
            if pending.expectedState != .running {
                beginPendingDecision(
                    identity: pending.identity,
                    frame: pending.frame,
                    expectedState: .running
                )
            }
            launchPendingAutomaticStart()
        case .rejected:
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .accepted
            )
            // Not Now is authoritative even if the other surface accepted a
            // moment earlier. Do not attach this detector identity to a later
            // Watch transition.
            resolvePendingDecision(result: .rejected)
        case .none, .watchUnavailable, .stale, .sessionMismatch:
            sendResponse(
                to: frame,
                kind: .acknowledgement,
                result: .rejected
            )
        }
    }

    private func handleAcknowledgement(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) {
        guard frame.acknowledgedKind == .promptResponse else { return }
        let identity = RideAutomationDecisionIdentity(
            deviceID: deviceID,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence
        )
        guard let pending = pendingDecision,
              pending.resolvedResult == nil,
              pending.identity == identity,
              pending.frame.transition == .start,
              pending.frame.startMode == .ask,
              pending.expectedState == .running else {
            return
        }
        if frame.result == .accepted {
            launchPendingAutomaticStart()
        } else {
            resolvePendingDecision(
                result: frame.result == .rejected ? .rejected : frame.result
            )
        }
    }

    private func launchPendingAutomaticStart() {
        guard let pending = pendingDecision,
              pending.resolvedResult == nil,
              pending.frame.transition == .start,
              pending.expectedState == .running else {
            return
        }
        let presentation = workoutManager.store.presentation
        guard presentation.canStartNewWorkout else {
            confirmIfAuthoritative(presentation)
            return
        }
        let context = automaticControlContext(for: pending.frame)
        guard watchAvailability?.setPendingAutomaticStartContext(context)
                == true,
              workoutManager.startOutdoorCyclingOnWatch() else {
            resolvePendingDecision(result: .watchUnavailable)
            return
        }
    }

    private func confirmIfAuthoritative(
        _ presentation: WorkoutMirrorPresentationV1
    ) {
        guard let pending = pendingDecision else { return }
        if pending.resolvedResult != nil { return }
        if presentation.connectionState == .failed
            || presentation.connectionState == .unsupported {
            resolvePendingDecision(result: .watchUnavailable)
            return
        }
        guard let expectedState = pending.expectedState else {
            if [.starting, .running, .paused, .ending]
                .contains(presentation.sessionState) {
                // A manual start won while an Ask prompt was still pending.
                // Retire the detector identity instead of attaching it to the
                // already-active workout.
                resolvePendingDecision(result: .stale)
            }
            return
        }
        if [.ending, .ended, .failed].contains(
            presentation.sessionState
        ) {
            resolvePendingDecision(result: .stale)
            return
        }
        guard
              presentation.connectionState == .connected,
              presentation.sessionState == expectedState else {
            return
        }
        if pending.frame.transition == .start,
           presentation.snapshot.lastTransitionOrigin == .manual {
            resolvePendingDecision(result: .stale)
            return
        }
        if pending.frame.transition == .start {
            let context = automaticControlContext(for: pending.frame)
            if startAnnotationRequestedFor != pending.identity {
                // The full ride generation/decision sequence lives in the
                // Watch marker, while the mirrored snapshot intentionally
                // exposes only origin/profile. Require an exact, idempotent
                // annotation ACK before confirming this RAUT identity.
                startAnnotationRequestedFor = pending.identity
                guard workoutManager.requestAutomaticStartAnnotation(
                    context: context
                ) else {
                    startAnnotationRequestedFor = nil
                    return
                }
                return
            }
            if presentation.pendingControl == .requestCurrentSnapshot {
                return
            }
            guard presentation.errorCode == nil,
                  presentation.snapshot.lastTransitionOrigin == .automatic,
                  presentation.snapshot.detectorProfileVersion ==
                    pending.frame.profileVersion else {
                resolvePendingDecision(result: .watchUnavailable)
                return
            }
        }
        if pending.frame.transition == .pause
            || pending.frame.transition == .resume {
            let expectedControl: WorkoutControlV1 =
                pending.frame.transition == .pause ? .pause : .resume
            if presentation.pendingControl == expectedControl {
                return
            }
            guard presentation.pendingControl == nil else { return }
            guard presentation.errorCode == nil else {
                resolvePendingDecision(result: .watchUnavailable)
                return
            }
            if presentation.snapshot.lastTransitionOrigin == .manual {
                // A rider control reached HealthKit first. Manual state is
                // authoritative and the old automatic request must not linger
                // until it can cross that boundary.
                resolvePendingDecision(result: .stale)
                return
            }
            guard presentation.snapshot.lastTransitionOrigin == .automatic
            else {
                // HealthKit may already expose the native state while Watch
                // is still durably writing the matching provenance marker.
                return
            }
            guard presentation.snapshot.detectorProfileVersion ==
                    pending.frame.profileVersion else {
                return
            }
        }
        if expectedState == .paused,
           presentation.snapshot.pauseOrigin == .manual {
            resolvePendingDecision(result: .stale)
            return
        }
        if expectedState == .paused,
           presentation.snapshot.pauseOrigin != .automatic {
            return
        }
        guard let sessionIdentityHash =
                RideAutomationAdmissionPolicy.sessionIdentityHash(
                    presentation.sessionID
                ) else {
            resolvePendingDecision(result: .watchUnavailable)
            return
        }
        resolvePendingDecision(
            result: .accepted,
            sessionIdentityHash: sessionIdentityHash
        )
    }

    private func sendConfigurationAndResynchronize() {
        guard bleManager.supportsRideAutomation else { return }
        guard let deviceID = bleManager.connectedDeviceID else { return }
        let baseGeneration = pendingDecision.flatMap {
            $0.identity.deviceID == deviceID
                ? $0.identity.rideGeneration
                : nil
        } ?? lastRideGenerationByDevice[deviceID]
            ?? max(1, settingsStore.generation)
        let decisionWatermark = highestSequenceByGeneration[
            generationKey(deviceID: deviceID, generation: baseGeneration)
        ] ?? 0
        if lastRideGenerationByDevice[deviceID] != nil {
            sendConfiguration(
                rideGeneration: baseGeneration
            )
        }
        let settings = settingsStore.settings
        let presentation = workoutManager.store.presentation
        _ = bleManager.sendRideAutomationFrame(
            RideAutomationFrame(
                kind: .resynchronize,
                rideGeneration: baseGeneration,
                profileVersion: 1,
                sessionIdentityHash:
                    RideAutomationAdmissionPolicy.sessionIdentityHash(
                        presentation.sessionID
                    ) ?? 0,
                watermarkOrConfigGeneration: decisionWatermark,
                startMode: settings.startMode,
                autoPauseEnabled: settings.autoPauseEnabled,
                alertMode: settings.alertMode
            )
        )
    }

    @discardableResult
    private func sendResponse(
        to request: RideAutomationFrame,
        kind: RideAutomationKind,
        result: RideAutomationResult,
        sessionIdentityHash: UInt32? = nil
    ) -> Bool {
        guard let deviceID = bleManager.connectedDeviceID,
              pendingDecision?.identity.deviceID == deviceID
                || pendingDecision == nil else {
            return false
        }
        return sendUnboundResponse(
            to: request,
            kind: kind,
            result: result,
            sessionIdentityHash: sessionIdentityHash
        )
    }

    @discardableResult
    private func sendUnboundResponse(
        to request: RideAutomationFrame,
        kind: RideAutomationKind,
        result: RideAutomationResult,
        sessionIdentityHash: UInt32? = nil
    ) -> Bool {
        bleManager.sendRideAutomationFrame(
            RideAutomationFrame(
                kind: kind,
                transition: request.transition,
                origin: request.origin,
                result: result,
                rideGeneration: request.rideGeneration,
                decisionSequence: request.decisionSequence,
                evidenceMask: request.evidenceMask,
                profileVersion: request.profileVersion,
                sessionIdentityHash:
                    sessionIdentityHash ?? request.sessionIdentityHash,
                watermarkOrConfigGeneration:
                    settingsStore.generation,
                startMode: settingsStore.settings.startMode,
                autoPauseEnabled:
                    settingsStore.settings.autoPauseEnabled,
                alertMode: settingsStore.settings.alertMode,
                candidateBeganSeconds: request.candidateBeganSeconds,
                monotonicSeconds: request.monotonicSeconds,
                sourceHealthMask: request.sourceHealthMask,
                acknowledgedKind: kind == .acknowledgement
                    ? request.kind
                    : nil
            )
        )
    }

    private func trimWatermarks(keeping currentGenerationKey: String) {
        while highestSequenceByGeneration.count > 16 {
            guard let key = highestSequenceByGeneration.keys.first(where: {
                $0 != currentGenerationKey
            }) else { break }
            highestSequenceByGeneration[key] = nil
        }
        if acknowledgementByDecision.count > 32 {
            acknowledgementByDecision.remove(
                at: acknowledgementByDecision.startIndex
            )
        }
    }

    private func generationKey(
        deviceID: String,
        generation: UInt32
    ) -> String {
        "\(deviceID):\(generation)"
    }

    private func beginPendingDecision(
        identity: RideAutomationDecisionIdentity,
        frame: RideAutomationFrame,
        expectedState: WorkoutSessionStateV1?
    ) {
        if pendingDecision?.identity != identity {
            startAnnotationRequestedFor = nil
        }
        let pending = RideAutomationPendingDecision(
            identity: identity,
            frame: frame,
            expectedState: expectedState
        )
        pendingDecision = pending
        settingsStore.savePendingDecision(pending)
        schedulePendingTimeout(for: pending)
    }

    private func restorePendingDecision(
        for deviceID: String,
        provenIdentity: RideAutomationDecisionIdentity
    ) {
        guard let pending = pendingDecision,
              pending.isProvenOutstanding(
                by: provenIdentity,
                on: deviceID
              ) else {
            return
        }
        if let result = pending.resolvedResult {
            sendResolvedConfirmation(pending, result: result)
            sendConfigurationAndResynchronize()
            schedulePendingTimeout(for: pending)
            return
        }
        if pending.frame.transition == .pause
            || pending.frame.transition == .resume {
            let presentation = workoutManager.store.presentation
            guard presentation.connectionState == .connected else {
                resolvePendingDecision(result: .watchUnavailable)
                return
            }
            guard let currentSessionHash =
                    RideAutomationAdmissionPolicy.sessionIdentityHash(
                        presentation.sessionID
                    ),
                  currentSessionHash == pending.frame.sessionIdentityHash else {
                resolvePendingDecision(result: .sessionMismatch)
                return
            }
            guard RideAutomationRecoveryControlPolicy.mayReplay(
                pending.frame.transition,
                sessionState: presentation.sessionState,
                pauseOrigin: presentation.snapshot.pauseOrigin,
                lastTransitionOrigin:
                    presentation.snapshot.lastTransitionOrigin
            ) else {
                resolvePendingDecision(result: .stale)
                return
            }
        }
        acknowledgementByDecision[pending.identity] = .accepted
        if pending.expectedState == nil {
            presentStartPrompt(
                identity: pending.identity,
                frame: pending.frame
            )
        } else if pending.frame.transition == .start {
            if pending.frame.startMode == .ask {
                _ = sendPromptResponse(
                    to: pending.frame,
                    result: .accepted
                )
            } else {
                launchPendingAutomaticStart()
            }
        } else if pending.frame.transition == .pause
                    || pending.frame.transition == .resume {
            guard workoutManager.requestAutomaticTransitionConfirmation(
                pending.frame.transition,
                context: automaticControlContext(for: pending.frame)
            ) else {
                resolvePendingDecision(result: .watchUnavailable)
                return
            }
        }
        sendResponse(
            to: pending.frame,
            kind: .acknowledgement,
            result: .accepted
        )
        schedulePendingTimeout(for: pending)
        confirmIfAuthoritative(workoutManager.store.presentation)
    }

    private func supersedePendingDecision(
        ifDifferentFrom identity: RideAutomationDecisionIdentity
    ) {
        guard let pending = pendingDecision,
              pending.identity != identity else { return }
        guard pending.identity.deviceID == identity.deviceID else {
            return
        }
        resolvePendingDecision(result: .stale)
    }

    private func resolvePendingDecision(
        result: RideAutomationResult,
        sessionIdentityHash: UInt32? = nil
    ) {
        guard let pending = pendingDecision,
              pending.resolvedResult == nil else { return }
        if result == .sessionMismatch || result == .watchUnavailable {
            lastError = result
        }
        let resolved = RideAutomationPendingDecision(
            identity: pending.identity,
            frame: pending.frame,
            expectedState: pending.expectedState,
            resolvedResult: result,
            resolvedSessionIdentityHash: sessionIdentityHash
        )
        pendingDecision = resolved
        settingsStore.savePendingDecision(resolved)
        if resolved.frame.transition == .start {
            _ = watchAvailability?.setPendingAutomaticStartContext(nil)
        }
        startPrompt = nil
        startAnnotationRequestedFor = nil
        cancelPromptCountdown()
        sendResolvedConfirmation(resolved, result: result)
        sendConfigurationAndResynchronize()
        schedulePendingTimeout(for: resolved)
    }

    private func clearPendingDecision() {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        if pendingDecision?.frame.transition == .start {
            _ = watchAvailability?.setPendingAutomaticStartContext(nil)
        }
        pendingDecision = nil
        startPrompt = nil
        startAnnotationRequestedFor = nil
        cancelPromptCountdown()
        settingsStore.savePendingDecision(nil)
    }

    private func automaticControlContext(
        for frame: RideAutomationFrame
    ) -> WorkoutControlContextV1 {
        WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: frame.rideGeneration,
            decisionSequence: frame.decisionSequence,
            detectorProfileVersion: frame.profileVersion
        )
    }

    private func schedulePendingTimeout(
        for pending: RideAutomationPendingDecision
    ) {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.pendingDecision?.identity == pending.identity else {
                return
            }
            if let result = self.pendingDecision?.resolvedResult,
               let current = self.pendingDecision {
                self.sendResolvedConfirmation(current, result: result)
                self.sendConfigurationAndResynchronize()
                self.schedulePendingTimeout(for: current)
                return
            }
            self.resolvePendingDecision(
                result: pending.expectedState == nil
                    ? .rejected
                    : .watchUnavailable
            )
        }
    }

    private func handleResynchronization(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) {
        lastRideGenerationByDevice[deviceID] = frame.rideGeneration
        noteDeviceMonotonic(frame.monotonicSeconds, deviceID: deviceID)
        if let pending = pendingDecision,
           pending.identity.deviceID == deviceID,
           pending.identity.rideGeneration != frame.rideGeneration {
            clearPendingDecision()
        }
        if confirmedConfigurationGenerationByDevice[deviceID]
            != settingsStore.generation {
            sendConfiguration(rideGeneration: frame.rideGeneration)
        }
        if let pending = pendingDecision,
           pending.identity.deviceID == deviceID,
           pending.identity.rideGeneration == frame.rideGeneration,
           pending.resolvedResult != nil,
           frame.watermarkOrConfigGeneration == 0 {
            clearPendingDecision()
            return
        }
        guard frame.watermarkOrConfigGeneration != 0,
              let pending = pendingDecision,
              pending.identity.deviceID == deviceID,
              pending.identity.rideGeneration == frame.rideGeneration,
              pending.identity.decisionSequence ==
                frame.watermarkOrConfigGeneration else {
            return
        }
        restorePendingDecision(
            for: deviceID,
            provenIdentity: pending.identity
        )
    }

    private func sendConfiguration(rideGeneration: UInt32) {
        let settings = settingsStore.settings
        _ = bleManager.sendRideAutomationFrame(
            RideAutomationFrame(
                kind: .configuration,
                rideGeneration: rideGeneration,
                profileVersion: 1,
                watermarkOrConfigGeneration: settingsStore.generation,
                startMode: settings.startMode,
                autoPauseEnabled: settings.autoPauseEnabled,
                alertMode: settings.alertMode
            )
        )
    }

    @discardableResult
    private func sendPromptResponse(
        to request: RideAutomationFrame,
        result: RideAutomationResult
    ) -> Bool {
        sendResponse(
            to: request,
            kind: .promptResponse,
            result: result
        )
    }

    private func sendResolvedConfirmation(
        _ pending: RideAutomationPendingDecision,
        result: RideAutomationResult
    ) {
        guard bleManager.connectedDeviceID == pending.identity.deviceID else {
            return
        }
        sendResponse(
            to: pending.frame,
            kind: .confirmation,
            result: result,
            sessionIdentityHash: pending.resolvedSessionIdentityHash
        )
    }

    private func presentStartPrompt(
        identity: RideAutomationDecisionIdentity,
        frame: RideAutomationFrame
    ) {
        let shouldAlert = startPrompt?.identity != identity
        startPrompt = StartPrompt(identity: identity, frame: frame)
        promptSecondsRemaining = 30
        promptCountdownTask?.cancel()
        promptCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 29, through: 0, by: -1) {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self,
                      self.startPrompt?.identity == identity else { return }
                self.promptSecondsRemaining = remaining
            }
        }
        if shouldAlert, settingsStore.settings.alertMode != 2 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            if settingsStore.settings.alertMode == 0 {
                AudioServicesPlaySystemSound(1007)
            }
        }
    }

    private func cancelPromptCountdown() {
        promptCountdownTask?.cancel()
        promptCountdownTask = nil
        promptSecondsRemaining = 0
    }

    private func noteDeviceMonotonic(
        _ seconds: UInt32,
        deviceID: String
    ) {
        guard let previous = latestDeviceMonotonicByDevice[deviceID] else {
            latestDeviceMonotonicByDevice[deviceID] = seconds
            return
        }
        let forward = seconds &- previous
        if forward < 0x8000_0000 {
            latestDeviceMonotonicByDevice[deviceID] = seconds
        }
    }

    private func isExpiredDecision(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) -> Bool {
        guard let current = latestDeviceMonotonicByDevice[deviceID] else {
            return false
        }
        return RideAutomationMonotonicClock.isExpired(
            sampleSeconds: frame.monotonicSeconds,
            latestSeconds: current,
            maximumAgeSeconds: 10
        )
    }

    private func startPeriodicResynchronization() {
        guard resynchronizationTask == nil else { return }
        resynchronizationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard let self, bleManager.supportsRideAutomation else {
                    return
                }
                sendConfigurationAndResynchronize()
            }
        }
    }

    private func decisionConfigurationMatches(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) -> Bool {
        let settings = settingsStore.settings
        return confirmedConfigurationGenerationByDevice[deviceID]
                == settingsStore.generation
            && frame.watermarkOrConfigGeneration == settingsStore.generation
            && frame.startMode == settings.startMode
            && frame.autoPauseEnabled == settings.autoPauseEnabled
            && frame.alertMode == settings.alertMode
    }

    private func handleConfigurationAcknowledgement(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) {
        lastRideGenerationByDevice[deviceID] = frame.rideGeneration
        noteDeviceMonotonic(frame.monotonicSeconds, deviceID: deviceID)
        let deviceSettings = RideDetectionSettings(
            startMode: frame.startMode,
            autoPauseEnabled: frame.autoPauseEnabled,
            alertMode: frame.alertMode
        )
        let matches = frame.result == .accepted
            && frame.watermarkOrConfigGeneration == settingsStore.generation
            && deviceSettings == settingsStore.settings
        if matches {
            confirmedConfigurationGenerationByDevice[deviceID] =
                frame.watermarkOrConfigGeneration
            confirmedDeviceSettings = deviceSettings
            watchAvailability?.setConfirmedRideDetectionSettings(
                deviceSettings,
                generation: frame.watermarkOrConfigGeneration
            )
            configurationRetryCountByDevice[deviceID] = 0
            return
        }
        confirmedConfigurationGenerationByDevice[deviceID] = nil
        confirmedDeviceSettings = nil
        watchAvailability?.setConfirmedRideDetectionSettings(
            nil,
            generation: nil
        )
        if RideAutomationSerialNumber.isNewer(
                frame.watermarkOrConfigGeneration,
                than: settingsStore.generation
            ) {
            settingsStore.adoptDeviceSettings(
                deviceSettings,
                generation: frame.watermarkOrConfigGeneration
            )
            configurationRetryCountByDevice[deviceID] = 0
            return
        }
        if frame.watermarkOrConfigGeneration == settingsStore.generation {
            settingsStore.advanceGeneration(
                past: frame.watermarkOrConfigGeneration
            )
            return
        }
        let retryCount = configurationRetryCountByDevice[deviceID] ?? 0
        guard retryCount < 3 else {
            lastError = frame.result == .rejected ? .rejected : .stale
            return
        }
        configurationRetryCountByDevice[deviceID] = retryCount + 1
        sendConfigurationAndResynchronize()
    }

    private func handleCancellation(
        _ frame: RideAutomationFrame,
        deviceID: String
    ) {
        let key = generationKey(
            deviceID: deviceID,
            generation: frame.rideGeneration
        )
        let highest = highestSequenceByGeneration[key] ?? 0
        if highest == 0 || RideAutomationSerialNumber.isNewer(
            frame.decisionSequence,
            than: highest
        ) {
            highestSequenceByGeneration[key] = frame.decisionSequence
        }
        trimWatermarks(keeping: key)
        settingsStore.saveDecisionWatermarks(highestSequenceByGeneration)
        guard let pending = pendingDecision,
              pending.identity.deviceID == deviceID,
              pending.identity.rideGeneration == frame.rideGeneration,
              pending.identity.decisionSequence == frame.decisionSequence else {
            return
        }
        clearPendingDecision()
    }
}
