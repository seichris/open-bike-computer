import SwiftUI

struct WatchWorkoutRootView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @ObservedObject var routeLibrary: WatchRouteLibrary
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @ObservedObject var deviceLink: WatchDeviceLink
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
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
                        navigationSettings: navigationSettings,
                        favoriteStore: favoriteStore,
                        deviceLink: deviceLink
                    )
                } else if navigationManager.shouldPresentNavigation {
                    WatchNavigationOnlyView(
                        manager: manager,
                        navigationManager: navigationManager,
                        navigationSettings: navigationSettings,
                        favoriteStore: favoriteStore,
                        deviceLink: deviceLink
                    )
                } else if let summary = manager.summary,
                          manager.state == .ended {
                    WorkoutSummaryView(
                        summary: summary,
                        cleanupState: manager.terminalCleanupState,
                        onRetryCleanup: manager.retryDetachedSessionCleanup,
                        onDone: manager.dismissSummary
                    )
                } else {
                    WorkoutStartView(
                        manager: manager,
                        routeLibrary: routeLibrary,
                        navigationManager: navigationManager,
                        navigationSettings: navigationSettings,
                        favoriteStore: favoriteStore
                    )
                }
            }
        }
        .onAppear {
            manager.retryPendingTerminalCleanupIfPossible()
            manager.refreshAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            manager.retryPendingTerminalCleanupIfPossible()
            manager.refreshAuthorizationIfNeeded()
        }
    }
}
