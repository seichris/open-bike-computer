import SwiftUI

struct WatchNavigationOnlyView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @ObservedObject var deviceLink: WatchDeviceLink

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if manager.summary != nil {
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

                if manager.summary != nil {
                    Text("Stop navigation to view the workout summary.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        manager.startOutdoorCycling()
                    } label: {
                        Label("Start Workout", systemImage: "bicycle")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                    .disabled(
                        manager.setupState != .ready ||
                            manager.state == .failed
                    )
                }

                Button {
                    navigationManager.stopNavigation()
                } label: {
                    Label("End Navigation", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)

                NavigationLink {
                    WatchSettingsView(
                        manager: manager,
                        navigationSettings: navigationSettings,
                        favoriteStore: favoriteStore,
                        navigationManager: navigationManager
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Navigation Settings")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
        }
    }
}
