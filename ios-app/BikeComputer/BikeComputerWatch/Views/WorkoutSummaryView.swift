import SwiftUI

struct WorkoutSummaryView: View {
    let summary: WatchWorkoutSummary
    let cleanupState: WatchWorkoutCleanupState
    let onRetryCleanup: () -> Void
    let onDone: () -> Void

    var body: some View {
        if summary.outcome == .discarded {
            ProgressView("Discarding…")
                .font(.caption)
                .accessibilityIdentifier("workout-discard-progress")
        } else {
            savedSummary
        }
    }

    private var savedSummary: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)

                Text("Ride Saved")
                    .font(.headline)

                if summary.terminalErrorCode == .anotherWorkoutActive {
                    Label(
                        WorkoutCrossAppTakeoverCopyV1.summary(
                            disposition: .save
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }

                summaryRow("Time", WorkoutValueFormatter.duration(summary.duration))
                summaryRow(
                    "Distance",
                    "\(WorkoutValueFormatter.distance(summary.distanceMeters)) \(WorkoutValueFormatter.distanceUnit(summary.distanceMeters))"
                )
                summaryRow("Energy", "\(WorkoutValueFormatter.energy(summary.activeEnergyKilocalories)) KCAL")
                summaryRow("Avg Heart", "\(WorkoutValueFormatter.heartRate(summary.averageHeartRate)) BPM")
                summaryRow(
                    "Avg Speed",
                    "\(WorkoutValueFormatter.averageSpeed(distanceMeters: summary.distanceMeters, elapsedSeconds: summary.duration)) KM/H"
                )
                summaryRow("Route", routeStatusLabel)

                if let native = summary.nativeZones?.heartRate {
                    WorkoutNativeZoneCard(group: native, showCurrent: false)
                }
                if let native = summary.nativeZones?.cyclingPower {
                    WorkoutNativeZoneCard(group: native, showCurrent: false)
                }

                switch cleanupState {
                case .delivering:
                    ProgressView()
                    Text("Finishing workout cleanup before another ride can start.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .retrying:
                    ProgressView()
                    Text("Retrying workout recovery before another ride can start.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .retryRequired:
                    Text("Finishing workout recovery before another ride can start.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry Recovery", action: onRetryCleanup)
                        .tint(.orange)
                case .none:
                    Button("Done", action: onDone)
                        .tint(.blue)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var routeStatusLabel: String {
        switch summary.routeStatus {
        case .present: "Saved"
        case .unavailable: "Unavailable"
        case .unknown: "Not Verified"
        }
    }
}
