import SwiftUI

struct WatchWorkoutRootView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @ObservedObject var routeLibrary: WatchRouteLibrary
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var deviceLink: WatchDeviceLink
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if manager.isRecovering {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Checking for an active ride…")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            } else if manager.state.isActive {
                LiveWorkoutView(
                    manager: manager,
                    navigationManager: navigationManager,
                    deviceLink: deviceLink,
                    navigationSettings: navigationSettings
                )
            } else if navigationManager.shouldPresentNavigation {
                WatchNavigationOnlyView(
                    navigationManager: navigationManager,
                    deviceLink: deviceLink,
                    navigationSettings: navigationSettings,
                    hasPendingWorkoutSummary: manager.summary != nil
                )
            } else if let summary = manager.summary,
                      manager.state == .ended {
                WorkoutSummaryView(
                    summary: summary,
                    isAwaitingSessionCleanup: manager.isAwaitingDetachedSessionCleanup,
                    onRetryCleanup: manager.retryDetachedSessionCleanup,
                    onDone: manager.dismissSummary
                )
            } else {
                NavigationStack {
                    WorkoutStartView(
                        manager: manager,
                        routeLibrary: routeLibrary,
                        navigationManager: navigationManager,
                        deviceLink: deviceLink,
                        navigationSettings: navigationSettings,
                        favoriteStore: favoriteStore
                    )
                }
            }
        }
        .onAppear {
            manager.refreshAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            manager.refreshAuthorizationIfNeeded()
        }
    }
}
