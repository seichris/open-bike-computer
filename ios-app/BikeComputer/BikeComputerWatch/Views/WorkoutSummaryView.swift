import SwiftUI

struct WorkoutSummaryView: View {
    let summary: WatchWorkoutSummary
    let isAwaitingSessionCleanup: Bool
    let onRetryCleanup: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: summary.outcome == .saved ? "checkmark.circle.fill" : "trash.circle.fill")
                    .font(.title)
                    .foregroundStyle(summary.outcome == .saved ? .green : .orange)

                Text(summary.outcome == .saved ? "Ride Saved" : "Ride Discarded")
                    .font(.headline)

                if summary.terminalErrorCode == .anotherWorkoutActive {
                    Label(
                        WorkoutCrossAppTakeoverCopyV1.summary(
                            disposition: summary.outcome == .saved ? .save : .discard
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }

                if summary.outcome == .saved {
                    summaryRow("Time", WorkoutValueFormatter.duration(summary.duration))
                    summaryRow(
                        "Distance",
                        "\(WorkoutValueFormatter.distance(summary.distanceMeters)) \(WorkoutValueFormatter.distanceUnit(summary.distanceMeters))"
                    )
                    summaryRow("Energy", "\(WorkoutValueFormatter.energy(summary.activeEnergyKilocalories)) KCAL")
                    summaryRow("Avg Heart", "\(WorkoutValueFormatter.heartRate(summary.averageHeartRate)) BPM")
                    summaryRow("Route", routeStatusLabel)
                } else {
                    Text("No workout or route was saved to Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if isAwaitingSessionCleanup {
                    Text("Finishing workout recovery before another ride can start.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry Recovery", action: onRetryCleanup)
                        .tint(.orange)
                } else {
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
