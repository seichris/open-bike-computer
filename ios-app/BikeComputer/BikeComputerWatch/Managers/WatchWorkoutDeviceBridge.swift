import Combine
import Foundation

@MainActor
final class WatchWorkoutDeviceBridge {
    private let manager: WatchWorkoutManager
    private let deviceLink: WatchDeviceLink
    private var cancellables = Set<AnyCancellable>()
    private var hasForwardedActiveWorkout = false

    init(manager: WatchWorkoutManager, deviceLink: WatchDeviceLink) {
        self.manager = manager
        self.deviceLink = deviceLink
        manager.$snapshot
            .sink { [weak self] snapshot in
                self?.receive(snapshot)
            }
            .store(in: &cancellables)
    }

    private func receive(_ snapshot: WorkoutSnapshotV1) {
        if snapshot.state.isActive,
           let token = manager.activeSessionToken,
           let frames = WorkoutDeviceFrameBuilder.frames(
               for: Self.sample(
                snapshot: snapshot,
                token: token,
                sessionID: manager.activeSessionID
               )
           ) {
            hasForwardedActiveWorkout = true
            deviceLink.setWorkoutDemand(true)
            deviceLink.updateWorkout(
                frames,
                gps: WorkoutDeviceFrameBuilder.gpsUpdate(for: snapshot)
            )
            return
        }

        guard hasForwardedActiveWorkout else { return }
        hasForwardedActiveWorkout = false
        guard let idle = WorkoutDeviceFrameBuilder.frames(
            for: Self.idleSample
        ) else { return }
        deviceLink.endWorkoutDemandAfterClearing(idle)
    }

    private static func sample(
        snapshot: WorkoutSnapshotV1,
        token: UInt16,
        sessionID: UUID?
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
            sourceFlags: flags,
            pauseOrigin: snapshot.pauseOrigin,
            wallElapsedSeconds: snapshot.wallElapsedTime?.value,
            sessionID: sessionID,
            detectorProfileVersion: snapshot.detectorProfileVersion,
            lastTransitionOrigin: snapshot.lastTransitionOrigin
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
        sourceFlags: [],
        pauseOrigin: nil,
        wallElapsedSeconds: nil,
        sessionID: nil,
        detectorProfileVersion: nil,
        lastTransitionOrigin: nil
    )
}
