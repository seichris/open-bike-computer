import SwiftUI

private enum WatchNavigationSelection: Hashable {
    case none
    case route(UUID)
    case favorite(UUID)
}

struct WorkoutStartView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @ObservedObject var routeLibrary: WatchRouteLibrary
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var deviceLink: WatchDeviceLink
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @State private var showingRecoveryResetConfirmation = false
    @State private var selectedNavigation: WatchNavigationSelection = .none

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "bicycle")
                    .font(.title)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text("Outdoor Cycle")
                    .font(.headline)

                navigationSelection

                setupContent

                if manager.locationAuthorizationState == .denied {
                    Label("Route, altitude, and GPS speed unavailable", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if manager.state == .failed {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Dismiss") {
                        manager.dismissSummary()
                    }
                    .buttonStyle(.borderless)
                }

                NavigationLink {
                    WatchRouteLibraryView(routeLibrary: routeLibrary)
                } label: {
                    Label("Offline Routes", systemImage: "map")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                NavigationLink {
                    WatchSettingsView(
                        navigationSettings: navigationSettings
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Settings")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
        }
        .onChange(of: routeLibrary.routes.map(\.id)) { _, routeIDs in
            if case .route(let selectedRouteID) = selectedNavigation,
               !routeIDs.contains(selectedRouteID) {
                selectedNavigation = .none
            }
        }
        .onChange(of: favoriteStore.favorites.map(\.id)) { _, favoriteIDs in
            if case .favorite(let selectedID) = selectedNavigation,
               !favoriteIDs.contains(selectedID) {
                selectedNavigation = .none
            }
        }
        .onChange(of: navigationSettings.policy) { _, policy in
            if policy == .offlineOnly,
               case .favorite = selectedNavigation {
                selectedNavigation = .none
            }
        }
        .alert(
            "Reset Workout Recovery?",
            isPresented: $showingRecoveryResetConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Recovery", role: .destructive) {
                manager.confirmResetCorruptRecovery()
            }
        } message: {
            Text(
                "This may abandon an unfinished ride. Bicino will preserve the damaged recovery file for diagnosis before resetting setup."
            )
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        switch manager.setupState {
        case .checking:
            ProgressView("Checking Health access…")
                .font(.caption)
        case .needsAuthorization:
            Text("Allow Health access to record this cycling workout and route.")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Set Up Health") {
                manager.requestAuthorization()
            }
            .tint(.blue)
        case .authorizing:
            ProgressView("Finish setup…")
                .font(.caption)
        case .ready:
            Button {
                switch selectedNavigation {
                case .none:
                    navigationManager.stopNavigation()
                case .route(let routeID):
                    navigationManager.startInstalledRoute(routeID: routeID)
                case .favorite(let favoriteID):
                    if let favorite = favoriteStore.favorites.first(where: {
                        $0.id == favoriteID
                    }) {
                        navigationManager.startOnline(destination: favorite)
                    }
                }
                manager.startOutdoorCycling()
            } label: {
                Label("Start Ride", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(manager.state == .failed)
        case .denied:
            VStack(spacing: 6) {
                Text("Bicino can’t start a workout without permission to save workouts in Health.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Text(
                    "On Apple Watch, open Settings > Health > Apps > Bicino and enable Workouts and Workout Routes, then return here."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Check Again") {
                manager.refreshAuthorizationIfNeeded()
            }
            .tint(.blue)
        case .unavailable:
            Text("Health data isn’t available on this Watch.")
                .font(.caption)
                .multilineTextAlignment(.center)
        case .failed:
            if manager.hasCorruptRecoveryState {
                Text("Bicino found damaged workout recovery data. Setup is blocked to protect a possible unfinished ride.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Recover Setup") {
                    showingRecoveryResetConfirmation = true
                }
                .tint(.orange)
            } else if manager.hasUnavailableRecoveryState {
                Text("Workout recovery data couldn’t be read. Unlock the Watch and try again.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    manager.retrySetup()
                }
            } else {
                Text("Health setup couldn’t be completed. Try again when the Watch is unlocked.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    manager.retrySetup()
                }
            }
        }
    }

    private var navigationSelection: some View {
        VStack(spacing: 5) {
            Picker("Navigation", selection: $selectedNavigation) {
                Text("None").tag(WatchNavigationSelection.none)
                ForEach(routeLibrary.routes) { route in
                    Text(route.name).tag(
                        WatchNavigationSelection.route(route.id)
                    )
                }
                if navigationSettings.policy == .onlineAllowed {
                    ForEach(favoriteStore.favorites) { favorite in
                        Text("★ \(favorite.name)").tag(
                            WatchNavigationSelection.favorite(favorite.id)
                        )
                    }
                }
            }
            .font(.caption)

            HStack {
                Label(
                    navigationSettings.policy == .onlineAllowed
                        ? "Online"
                        : "Offline",
                    systemImage: navigationSettings.policy == .onlineAllowed
                        ? "antenna.radiowaves.left.and.right"
                        : "arrow.down.circle"
                )
                Spacer()
                Text(bicinoStatus)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if routeLibrary.routes.isEmpty &&
                (navigationSettings.policy == .offlineOnly ||
                    favoriteStore.favorites.isEmpty) {
                Text(
                    navigationSettings.policy == .offlineOnly
                        ? "Transfer a planned route from iPhone for offline navigation."
                        : "Add a coordinate-backed favorite on iPhone or transfer a planned route."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var bicinoStatus: String {
        switch deviceLink.state {
        case .ready: "Bicino ready"
        case .notEnrolled: "Bicino not enrolled"
        case .busy: "Bicino busy"
        case .connecting, .discovering, .authenticating, .claimingLease,
                .scanning:
            "Connecting Bicino"
        case .bluetoothUnavailable: "Bluetooth unavailable"
        case .failed: "Bicino disconnected"
        case .idle: "Bicino on ride start"
        }
    }

    private var failureMessage: String {
        switch manager.snapshot.errorCode {
        case .authorizationDenied:
            "Health access was denied. No workout was saved."
        case .anotherWorkoutActive:
            "Another app took over the Watch workout session. Check the Watch before starting again."
        case .setupRequired:
            "Finish workout setup before starting."
        case .watchUnavailable:
            "This Watch is unavailable for workouts."
        case .finalSummaryUnavailable:
            "The final workout summary was not available. Check Health before starting again."
        case .terminalChoiceConflict:
            "The other finish choice was already committed."
        case .terminalChoiceUnconfirmed:
            "The requested finish choice could not be confirmed."
        case .segmentMarkFailed:
            "A segment could not be marked. The workout itself is unchanged."
        case .segmentMarkUnconfirmed:
            "A segment is still being confirmed. Check the live workout."
        case .segmentFinalizationPending:
            "Open the live workout to finish saving a pending segment."
        case .sessionFailed, .unknown, nil:
            "The workout couldn’t be started or recovered."
        }
    }
}
