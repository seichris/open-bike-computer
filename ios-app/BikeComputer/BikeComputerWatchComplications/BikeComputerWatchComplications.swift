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
                    Image(systemName: "figure.outdoor.cycle")
                        .font(.title2)
                        .widgetAccentable()
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "figure.outdoor.cycle")
                        .font(.title2)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bicino")
                            .font(.headline)
                        Text("Start Ride")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .accessoryInline:
                Label("Start Ride", systemImage: "figure.outdoor.cycle")
            case .accessoryCorner:
                Image(systemName: "figure.outdoor.cycle")
                    .widgetAccentable()
                    .widgetLabel {
                        Text("Start Ride")
                    }
            default:
                Image(systemName: "figure.outdoor.cycle")
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
        .widgetURL(WatchWorkoutLaunchRequest.startOutdoorCyclingURL)
        .accessibilityLabel("Start a Bicino ride")
    }
}

private struct StartRideComplication: Widget {
    let kind = "StartRideComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StartRideProvider()) { _ in
            StartRideComplicationView()
        }
        .configurationDisplayName("Start Ride")
        .description("Start an outdoor cycling workout in Bicino.")
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
