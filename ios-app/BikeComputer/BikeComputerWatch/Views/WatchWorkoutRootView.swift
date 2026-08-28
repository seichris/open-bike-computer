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
                if let request = manager.pendingWorkoutLaunchRequest {
                    PendingWorkoutLaunchConfirmationView(
                        request: request,
                        canStart: manager.canConfirmPendingWorkoutLaunchRequest,
                        onStart: manager.confirmPendingWorkoutLaunchRequest,
                        onCancel: manager.cancelPendingWorkoutLaunchRequest
                    )
                } else if manager.isRecovering {
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
            routeLibrary.reload()
            manager.retryPendingTerminalCleanupIfPossible()
            manager.refreshAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else {
                manager.cancelPendingWorkoutLaunchRequest()
                return
            }
            routeLibrary.reload()
            manager.retryPendingTerminalCleanupIfPossible()
            manager.refreshAuthorizationIfNeeded()
        }
    }
}

private struct PendingWorkoutLaunchConfirmationView: View {
    let request: PendingWorkoutLaunchRequest
    let canStart: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.outdoor.cycle")
                .font(.title2)
                .accessibilityHidden(true)
            Text(workoutTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(sourceDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start", action: onStart)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(.horizontal, 4)
    }

    private var sourceDescription: String {
        switch request.source {
        case .complicationURL:
            return "Requested from your complication."
        }
    }

    private var workoutTitle: String {
        switch request.workoutType {
        case .outdoorCycling:
            return "Start Outdoor Cycling?"
        }
    }
}
