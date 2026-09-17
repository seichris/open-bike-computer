import SwiftUI

private nonisolated struct WorkoutSessionCoordinatorKey: EnvironmentKey {
    static let defaultValue: WorkoutSessionCoordinator? = nil
}

extension EnvironmentValues {
    var workoutSessionCoordinator: WorkoutSessionCoordinator? {
        get { self[WorkoutSessionCoordinatorKey.self] }
        set { self[WorkoutSessionCoordinatorKey.self] = newValue }
    }
}

/// Explicit choices and recovery actions. A disconnected Watch is never treated
/// as an invitation to silently start recording on a second device.
struct WorkoutRecordingStatusView: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    @ObservedObject var store: WorkoutMetricsStore
    @State private var confirmsWatchIdle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = coordinator.record {
                Label("Recorder: \(record.owner.displayName)",
                      systemImage: record.owner == .iphone ? "iphone" : "applewatch")
                    .font(.subheadline.weight(.semibold))
                if record.phase != .finished {
                    Text("This recorder stays selected if devices disconnect or reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = coordinator.notice {
                Text(notice.message).font(.subheadline)
                if notice.kind == .chooseRecorder {
                    recorderChoices
                }
            }
            if let message = store.recordingMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if !coordinator.recoveryComplete {
                Button("Retry Recovery") { coordinator.retryRecovery() }
                    .buttonStyle(.bordered)
            } else if coordinator.record == nil, coordinator.notice?.kind != .chooseRecorder {
                Button("Choose Recorder") { coordinator.chooseRecorder() }
                    .buttonStyle(.bordered)
            }
            if let record = coordinator.record, record.owner == .watch,
               record.phase == .unresolved {
                Button("Retry on Apple Watch") { coordinator.retryWatchStart() }
                    .buttonStyle(.bordered)
                Button("I checked Watch — no workout is running") { confirmsWatchIdle = true }
                    .font(.footnote)
            }
            if let record = coordinator.record, record.owner == .iphone,
               record.phase != .finished {
                if let choice = record.finishChoice {
                    Button(choice == .save ? "Reconcile Save" : "Retry Discard") {
                        coordinator.retryFinish()
                    }
                    .buttonStyle(.bordered)
                } else if store.presentation.sessionState == .ending
                            || store.presentation.sessionState == .starting {
                    WorkoutFinishButton(store: store,
                        onEndAndSave: coordinator.endAndSave,
                        onDiscard: coordinator.discard) {
                        Label("Resolve Interrupted Workout", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog("Confirm Apple Watch is idle", isPresented: $confirmsWatchIdle) {
            Button("No Watch Workout Is Running") { coordinator.confirmNoWorkoutOnWatch() }
            Button("Keep Checking", role: .cancel) {}
        } message: {
            Text("Check Bicino on your Watch first. This clears only the iPhone's unresolved ownership record; it does not end or discard a Watch workout. A late Watch recording would remain a separate ride.")
        }
    }

    private var recorderChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coordinator.watchAvailability.availability != .unsupported {
                Button("Record with Apple Watch") { _ = coordinator.requestStart(explicitOwner: .watch) }
                    .buttonStyle(.bordered)
            }
            if coordinator.phoneSupported {
                Button("Record with iPhone") { _ = coordinator.requestStart(explicitOwner: .iphone) }
                    .buttonStyle(.borderedProminent)
                Text("iPhone GPS records route and distance. Heart rate requires a compatible external monitor; cadence and power are not collected in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("iPhone-only recording requires iOS 26 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!coordinator.recoveryComplete || coordinator.record != nil)
    }
}
