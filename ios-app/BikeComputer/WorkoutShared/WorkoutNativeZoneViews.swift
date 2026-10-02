#if canImport(SwiftUI)
import SwiftUI

/// Shared presentation keeps the Watch and phone on the same per-workout
/// configuration. It intentionally doesn't reuse the five-band legacy strip.
struct WorkoutNativeZoneCard: View {
    let group: WorkoutNativeZoneSnapshotV1
    var showCurrent = true

    private var currentZone: UInt8? {
        showCurrent && !group.isFinal ? group.currentZone : nil
    }

    var body: some View {
        if group.isValid {
            VStack(alignment: .leading, spacing: 8) {
                Text(group.configuration.metric.title)
                    .font(.headline)
                Text(group.configuration.source.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(group.configuration.ranges.indices, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(
                                currentZone == UInt8(index + 1)
                                    ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    currentZone.map { "Zone \($0) of \(group.configuration.ranges.count)" }
                        ?? "\(group.configuration.ranges.count) zones; current zone unavailable"
                )

                if group.isFinal {
                    ForEach(group.configuration.ranges.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Zone \(index + 1)")
                                Spacer()
                                Text(WorkoutValueFormatter.duration(group.secondsByZone[index]))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            Text("\(group.configuration.ranges[index].label) \(group.configuration.metric.unitLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ProgressView(
                                value: group.secondsByZone[index],
                                total: max(1, group.secondsByZone.max() ?? 0)
                            )
                            .accessibilityHidden(true)
                        }
                    }
                    Text("Time in zones reported by the saved HealthKit workout.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let currentZone {
                    Text("Zone \(currentZone) of \(group.configuration.ranges.count)")
                        .font(.caption)
                } else {
                    Text("Current zone unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }
}
#endif
