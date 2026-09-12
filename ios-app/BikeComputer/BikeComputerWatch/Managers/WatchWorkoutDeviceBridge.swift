import Combine
import Foundation

@MainActor
final class WatchWorkoutDeviceBridge {
    private let manager: WatchWorkoutManager
    private let deviceLink: WatchDeviceLink
    private var cancellables = Set<AnyCancellable>()
    private var forwardingState = WorkoutDeviceForwardingStateV1()

    init(manager: WatchWorkoutManager, deviceLink: WatchDeviceLink) {
        self.manager = manager
        self.deviceLink = deviceLink
        manager.$latestEnvelope
            .sink { [weak self] envelope in
                self?.receive(envelope)
            }
            .store(in: &cancellables)
    }

    private func receive(_ envelope: WorkoutEnvelopeV1?) {
        switch forwardingState.receive(envelope) {
        case let .forward(snapshot, sessionID, sessionToken):
            guard let sample =
                    WorkoutDeviceTelemetrySampleMapperV1.directWatchSample(
                        snapshot: snapshot,
                        sessionToken: sessionToken,
                        sessionID: sessionID
                    ) else { return }
            guard let frames = WorkoutDeviceFrameBuilder.frames(
                for: sample
            ) else { return }
            deviceLink.setWorkoutDemand(true)
            deviceLink.updateWorkout(
                frames,
                gps: WorkoutDeviceFrameBuilder.gpsUpdate(for: snapshot),
                motion: WorkoutDeviceFrameBuilder.watchMotionUpdate(
                    for: snapshot,
                    sessionToken: sessionToken
                )
            )
        case .clear:
            guard let idle = WorkoutDeviceFrameBuilder.frames(
                for: WorkoutDeviceTelemetrySampleMapperV1.emptySample(
                    state: .idle,
                    sessionToken: 0,
                    isCurrentSnapshot: true
                )
            ) else { return }
            deviceLink.endWorkoutDemandAfterClearing(idle)
        case .ignore:
            break
        }
    }

}
