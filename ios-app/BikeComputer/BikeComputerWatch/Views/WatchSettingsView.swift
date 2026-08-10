import SwiftUI

struct WatchSettingsView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @ObservedObject var navigationManager: WatchNavigationManager

    var body: some View {
        Form {
            Section("Ride Detection") {
                if manager.rideDetectionSettingsConfirmed {
                    LabeledContent(
                        "Start",
                        value: startModeLabel
                    )
                    LabeledContent(
                        "Auto-Pause",
                        value: manager.rideDetectionSettings.autoPauseEnabled
                            ? "On"
                            : "Off"
                    )
                    LabeledContent(
                        "Start Alerts",
                        value: alertModeLabel
                    )
                } else {
                    Text("Connect to the bike computer to sync this policy.")
                        .foregroundStyle(.secondary)
                }
                Text("Change ride detection on iPhone or the bike computer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Use Watch cellular connection",
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

                if navigationSettings.useWatchCellularConnection {
                    NavigationLink {
                        WatchOnlineDestinationListView(
                            favoriteStore: favoriteStore,
                            navigationManager: navigationManager
                        )
                    } label: {
                        Label("Online Navigation", systemImage: "network")
                    }

                    if navigationManager.canRecalculateOnline {
                        Button("Recalculate Route") {
                            navigationManager.recalculateOnlineRoute()
                        }
                    }
                }
            } header: {
                Text("Navigation")
            } footer: {
                Text(
                    "Allows online route calculation and rerouting from this Watch. watchOS may use cellular or Wi-Fi when available."
                )
            }

            Section("About") {
                LabeledContent("Version", value: versionDescription)
            }

            Link(destination: AppPrivacyPolicy.url) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Settings")
    }

    private var startModeLabel: String {
        switch manager.rideDetectionSettings.startMode {
        case .off: "Off"
        case .ask: "Ask"
        case .automatic: "Automatic"
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        return switch (version, build) {
        case let (.some(version), .some(build)):
            "\(version) (\(build))"
        case let (.some(version), .none):
            version
        case let (.none, .some(build)):
            build
        case (.none, .none):
            "Unknown"
        }
    }

    private var alertModeLabel: String {
        switch manager.rideDetectionSettings.alertMode {
        case 0: "Sound + Haptic"
        case 1: "Haptic Only"
        default: "Visual Only"
        }
    }
}

private struct WatchOnlineDestinationListView: View {
    @ObservedObject var favoriteStore: WatchFavoriteStore
    @ObservedObject var navigationManager: WatchNavigationManager
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDestination: SyncedCoordinateFavoriteV1?

    var body: some View {
        List {
            if favoriteStore.favorites.isEmpty {
                ContentUnavailableView(
                    "No Destinations",
                    systemImage: "mappin.slash",
                    description: Text(
                        "Add a coordinate favorite in Bicino on iPhone."
                    )
                )
            } else {
                ForEach(favoriteStore.favorites) { destination in
                    Button(destination.name) {
                        pendingDestination = destination
                    }
                }
            }

            if let error = favoriteStore.lastSyncError {
                Text("Last sync failed: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Online Navigation")
        .confirmationDialog(
            "Start Online Navigation?",
            isPresented: pendingDestinationPresented,
            titleVisibility: .visible,
            presenting: pendingDestination
        ) { destination in
            Button("Start Navigation") {
                pendingDestination = nil
                navigationManager.startOnline(destination: destination)
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                pendingDestination = nil
            }
        } message: { destination in
            Text("Navigate to \(destination.name) using this Watch?")
        }
    }

    private var pendingDestinationPresented: Binding<Bool> {
        Binding(
            get: { pendingDestination != nil },
            set: { isPresented in
                if !isPresented { pendingDestination = nil }
            }
        )
    }
}
