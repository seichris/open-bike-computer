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
            let state = context.state.displayState(
                isSystemStale: context.isStale
            )
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutLiveActivityStatusView(
                        state: state,
                        compact: true
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutLiveActivityElapsedView(
                        state: state,
                        font: .title3.monospacedDigit()
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    WorkoutLiveActivityMetricStrip(
                        state: state,
                        compact: true
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutLiveActivityControls(
                        sessionID: context.attributes.sessionID,
                        state: state
                    )
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "figure.outdoor.cycle")
                    Circle()
                        .fill(state.statusColor)
                        .frame(width: 6, height: 6)
                }
                .accessibilityLabel(state.statusTitle)
            } compactTrailing: {
                WorkoutLiveActivityElapsedView(
                    state: state,
                    font: .caption.monospacedDigit()
                )
            } minimal: {
                Image(systemName: state.minimalSymbolName)
                    .foregroundStyle(state.statusColor)
                    .accessibilityLabel(state.statusTitle)
            }
            .keylineTint(.green)
        }
    }
}
