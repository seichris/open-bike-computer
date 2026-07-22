import SwiftUI
import WidgetKit

private struct StartRideEntry: TimelineEntry {
    let date: Date
}

private struct StartRideProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartRideEntry {
        StartRideEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (StartRideEntry) -> Void
    ) {
        completion(StartRideEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<StartRideEntry>) -> Void
    ) {
        completion(
            Timeline(
                entries: [StartRideEntry(date: Date())],
                policy: .never
            )
        )
    }
}

private struct StartRideComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "bicycle")
                        .font(.title2)
                        .widgetAccentable()
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "bicycle")
                        .font(.title2)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BikeComputer")
                            .font(.headline)
                        Text("Start Ride")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .accessoryInline:
                Label("Start Ride", systemImage: "bicycle")
            case .accessoryCorner:
                Image(systemName: "bicycle")
                    .widgetAccentable()
                    .widgetLabel {
                        Text("Start Ride")
                    }
            default:
                Image(systemName: "bicycle")
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
        .widgetURL(WatchWorkoutLaunchRequest.startOutdoorCyclingURL)
        .accessibilityLabel("Start a BikeComputer ride")
    }
}

private struct StartRideComplication: Widget {
    let kind = "StartRideComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StartRideProvider()) { _ in
            StartRideComplicationView()
        }
        .configurationDisplayName("Start Ride")
        .description("Start an outdoor cycling workout in BikeComputer.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

@main
struct BikeComputerWatchComplications: WidgetBundle {
    var body: some Widget {
        StartRideComplication()
    }
}
