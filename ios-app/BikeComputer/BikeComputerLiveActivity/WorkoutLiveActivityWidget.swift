import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(
            for: WorkoutLiveActivityAttributes.self
        ) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutLiveActivityStatusView(
                        state: context.state,
                        compact: true
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutLiveActivityElapsedView(
                        state: context.state,
                        font: .title3.monospacedDigit()
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    WorkoutLiveActivityMetricStrip(
                        state: context.state,
                        compact: true
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutLiveActivityControls(
                        sessionID: context.attributes.sessionID,
                        state: context.state
                    )
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "figure.outdoor.cycle")
                    Circle()
                        .fill(context.state.statusColor)
                        .frame(width: 6, height: 6)
                }
                .accessibilityLabel(context.state.statusTitle)
            } compactTrailing: {
                WorkoutLiveActivityElapsedView(
                    state: context.state,
                    font: .caption.monospacedDigit()
                )
            } minimal: {
                Image(systemName: context.state.minimalSymbolName)
                    .foregroundStyle(context.state.statusColor)
                    .accessibilityLabel(context.state.statusTitle)
            }
            .keylineTint(.green)
        }
    }
}
