import SwiftUI

struct WatchWorkoutRootView: View {
    @ObservedObject var manager: WatchWorkoutManager

    var body: some View {
        Group {
            if manager.isRecovering {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Checking for an active ride…")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            } else if let summary = manager.summary,
                      manager.state == .ended {
                WorkoutSummaryView(
                    summary: summary,
                    isAwaitingSessionCleanup: manager.isAwaitingDetachedSessionCleanup,
                    onRetryCleanup: manager.retryDetachedSessionCleanup,
                    onDone: manager.dismissSummary
                )
            } else if manager.state.isActive {
                LiveWorkoutView(manager: manager)
            } else {
                NavigationStack {
                    WorkoutStartView(manager: manager)
                }
            }
        }
    }
}
