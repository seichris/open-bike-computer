import SwiftUI

struct WatchNavigationOnlyView: View {
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var deviceLink: WatchDeviceLink
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    let hasPendingWorkoutSummary: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label("Navigation", systemImage: "location.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                if hasPendingWorkoutSummary {
                    Text("Workout ended. Navigation is still running.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                WatchNavigationStatusView(
                    navigationManager: navigationManager,
                    deviceLink: deviceLink,
                    farStartCancelTitle: "Cancel Navigation"
                )

                Toggle(
                    "Watch cellular",
                    isOn: Binding(
                        get: {
                            navigationSettings.useWatchCellularConnection
                        },
                        set: {
                            navigationSettings
                                .setUseWatchCellularConnection($0)
                        }
                    )
                )
                .font(.caption2)

                if hasPendingWorkoutSummary {
                    Text("Stop navigation to view the workout summary.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}
