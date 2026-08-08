import HealthKit
import WatchKit

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workoutManager: WatchWorkoutManager
    private let heartRateZoneSettingsReceiver:
        WatchHeartRateZoneSettingsReceiver

    override init() {
        let workoutManager = WatchWorkoutManager()
        self.workoutManager = workoutManager
        heartRateZoneSettingsReceiver = WatchHeartRateZoneSettingsReceiver(
            applyMaximumHeartRateBPM: { value in
                workoutManager.setMaximumHeartRateBPM(value)
            },
            applyRideDetectionSettings: { settings, generation in
                if let settings, let generation {
                    workoutManager.setRideDetectionSettings(
                        settings,
                        generation: generation
                    )
                } else {
                    workoutManager.clearRideDetectionSettings()
                }
            },
            applyPendingAutomaticStart: { context in
                workoutManager.setPendingAutomaticStartContext(context)
            }
        )
        super.init()
        heartRateZoneSettingsReceiver.activate()
    }

    func handleActiveWorkoutRecovery() {
        workoutManager.handleActiveWorkoutRecovery()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workoutManager.handleWorkoutConfiguration(workoutConfiguration)
    }
}
