import HealthKit
import WatchKit

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workoutManager = WatchWorkoutManager()

    func handleActiveWorkoutRecovery() {
        workoutManager.handleActiveWorkoutRecovery()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workoutManager.handleWorkoutConfiguration(workoutConfiguration)
    }
}
