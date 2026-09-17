import Combine

extension WorkoutMirrorManager: WorkoutWatchRecording {}

extension WorkoutWatchAvailabilityMonitor: WorkoutRecordingWatchAvailability {
    var recordingAvailabilityPublisher: AnyPublisher<WorkoutWatchAvailabilityV1, Never> {
        $availability.eraseToAnyPublisher()
    }
}
