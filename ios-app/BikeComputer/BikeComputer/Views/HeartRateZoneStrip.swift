import SwiftUI

struct HeartRateZoneStrip: View {
    let currentZone: UInt8?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let zoneCount = 5
    private let spacing: CGFloat = 6

    @ViewBuilder
    var body: some View {
        if let normalizedCurrentZone {
            GeometryReader { proxy in
                let availableWidth = max(
                    proxy.size.width - spacing * CGFloat(zoneCount - 1),
                    0
                )
                let inactiveWidth = availableWidth * 0.125
                let activeWidth = availableWidth - inactiveWidth * 4

                HStack(spacing: spacing) {
                    ForEach(1...zoneCount, id: \.self) { zone in
                        let isCurrent = zone == normalizedCurrentZone

                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(
                                    HeartRateZonePalette.color(for: zone)
                                        .opacity(isCurrent ? 1 : 0.62)
                                )

                            if isCurrent {
                                HStack(spacing: 7) {
                                    Image(systemName: "heart.fill")
                                        .accessibilityHidden(true)
                                    Text("ZONE \(zone)")
                                        .lineLimit(1)
                                }
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(
                                    HeartRateZonePalette.foregroundColor(for: zone)
                                )
                                .minimumScaleFactor(0.72)
                                .padding(.horizontal, 10)
                                .transition(.opacity)
                            }
                        }
                        .frame(width: isCurrent ? activeWidth : inactiveWidth)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: normalizedCurrentZone)
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 58 : 48)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate zone")
            .accessibilityValue("Zone \(normalizedCurrentZone) of \(zoneCount)")
        }
    }

    private var normalizedCurrentZone: Int? {
        guard let currentZone,
              (1...zoneCount).contains(Int(currentZone)) else {
            return nil
        }
        return Int(currentZone)
    }

}

enum HeartRateZonePalette {
    static func color(for zone: Int) -> Color {
        switch zone {
        case 1:
            return Color(red: 0.08, green: 0.36, blue: 0.60)
        case 2:
            return Color(red: 0.05, green: 0.48, blue: 0.44)
        case 3:
            return Color(red: 0.68, green: 0.95, blue: 0.03)
        case 4:
            return Color(red: 0.88, green: 0.45, blue: 0.06)
        default:
            return Color(red: 0.72, green: 0.03, blue: 0.32)
        }
    }

    static func foregroundColor(for zone: Int) -> Color {
        switch zone {
        case 3, 4:
            return .black
        default:
            return .white
        }
    }
}

struct HeartRateZoneBreakdown: View {
    let durations: WorkoutZoneDurationsV1?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Heart Rate Zones", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(.red)

            if let presentation {
                VStack(spacing: 13) {
                    ForEach(presentation.rows, id: \.zone) { row in
                        zoneRow(row)
                    }
                }

                if let maximumHeartRateBPM =
                    presentation.maximumHeartRateBPM {
                    Text(
                        "Based on the maximum heart rate used for this workout: \(maximumHeartRateBPM) BPM."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Heart-rate ranges are unavailable because this workout did not record its maximum-heart-rate profile."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Heart rate zone data was not available for this workout.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func zoneRow(
        _ row: WorkoutHeartRateZoneBreakdownRowV1
    ) -> some View {
        let color = HeartRateZonePalette.color(for: row.zone)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Zone \(row.zone)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(row.durationLabel)
                    .font(.subheadline.monospacedDigit())

                Spacer(minLength: 8)

                Text(row.bpmRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.16))
                    Capsule()
                        .fill(color)
                        .frame(
                            width: proxy.size.width
                                * row.fractionOfLongestDuration
                        )
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var presentation:
        WorkoutHeartRateZoneBreakdownPresentationV1? {
        WorkoutHeartRateZoneBreakdownPresentationV1.make(durations: durations)
    }
}

struct HeartRateZoneStrip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            HeartRateZoneStrip(currentZone: 1)
            HeartRateZoneStrip(currentZone: 3)
            HeartRateZoneStrip(currentZone: 5)
            HeartRateZoneStrip(currentZone: nil)
            HeartRateZoneBreakdown(
                durations: WorkoutZoneDurationsV1(
                    capturedAt: Date(),
                    secondsByZone: [109, 42, 55, 149, 704],
                    maximumHeartRateBPM: 190
                )
            )
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
