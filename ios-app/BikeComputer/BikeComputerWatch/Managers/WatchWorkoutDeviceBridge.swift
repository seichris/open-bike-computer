import Combine
import Foundation

@MainActor
final class WatchWorkoutDeviceBridge {
    private let manager: WatchWorkoutManager
    private let deviceLink: WatchDeviceLink
    private var cancellables = Set<AnyCancellable>()
    private var releaseTask: Task<Void, Never>?

    init(manager: WatchWorkoutManager, deviceLink: WatchDeviceLink) {
        self.manager = manager
        self.deviceLink = deviceLink
        manager.$snapshot
            .sink { [weak self] snapshot in
                self?.receive(snapshot)
            }
            .store(in: &cancellables)
    }

    deinit {
        releaseTask?.cancel()
    }

    private func receive(_ snapshot: WorkoutSnapshotV1) {
        releaseTask?.cancel()
        releaseTask = nil
        if snapshot.state.isActive,
           let token = manager.activeSessionToken,
           let frames = WorkoutDeviceFrameBuilder.frames(
               for: Self.sample(snapshot: snapshot, token: token)
           ) {
            deviceLink.setWorkoutDemand(true)
            deviceLink.updateWorkoutPair(
                core: frames.core,
                extended: frames.extended
            )
            return
        }

        guard let idle = WorkoutDeviceFrameBuilder.frames(
            for: Self.idleSample
        ) else { return }
        deviceLink.clearWorkout(core: idle.core, extended: idle.extended)
        // Give a workout-only link one bounded interval to deliver its clear
        // pair. Navigation demand, when present, independently retains BLE.
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.deviceLink.setWorkoutDemand(false)
        }
    }

    private static func sample(
        snapshot: WorkoutSnapshotV1,
        token: UInt16
    ) -> WorkoutDeviceTelemetrySample {
        var flags: WorkoutDeviceSourceFlags = [.currentSnapshot]
        switch snapshot.currentSpeed?.source {
        case .pairedCyclingSensor:
            flags.insert(.pairedSpeedSensor)
        case .watchLocation:
            flags.insert(.watchSpeed)
        default:
            break
        }
        if snapshot.cyclingDistance?.source == .healthKit {
            flags.insert(.healthKitDistance)
        }
        if snapshot.location?.altitude != nil {
            flags.insert(.watchAltitude)
        }
        if snapshot.currentHeartRateZone != nil {
            flags.insert(.liveHeartRateZone)
        }
        return WorkoutDeviceTelemetrySample(
            state: WorkoutDeviceSessionState(snapshot.state),
            sessionToken: token,
            hasLiveNumerics: true,
            isCurrentSnapshot: true,
            elapsedSeconds: snapshot.elapsedTime?.value,
            distanceMeters: snapshot.cyclingDistance?.value,
            speedMetersPerSecond: snapshot.currentSpeed?.value,
            currentHeartRateBPM: snapshot.currentHeartRate?.value,
            averageHeartRateBPM: snapshot.averageHeartRate?.value,
            activeEnergyKilocalories: snapshot.activeEnergy?.value,
            cyclingPowerWatts: snapshot.cyclingPower?.value,
            cyclingCadenceRPM: snapshot.cyclingCadence?.value,
            currentHeartRateZone: snapshot.currentHeartRateZone,
            altitudeMeters: snapshot.location?.altitude,
            heartRateZoneCount: snapshot.heartRateZoneCount,
            sourceFlags: flags
        )
    }

    private static let idleSample = WorkoutDeviceTelemetrySample(
        state: .idle,
        sessionToken: 0,
        hasLiveNumerics: false,
        isCurrentSnapshot: true,
        elapsedSeconds: nil,
        distanceMeters: nil,
        speedMetersPerSecond: nil,
        currentHeartRateBPM: nil,
        averageHeartRateBPM: nil,
        activeEnergyKilocalories: nil,
        cyclingPowerWatts: nil,
        cyclingCadenceRPM: nil,
        currentHeartRateZone: nil,
        altitudeMeters: nil,
        heartRateZoneCount: nil,
        sourceFlags: []
    )
}
