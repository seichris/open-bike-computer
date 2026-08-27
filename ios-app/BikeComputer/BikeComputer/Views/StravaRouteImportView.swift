import SwiftUI

struct StravaRouteImportView: View {
    @ObservedObject var coordinator: StravaIntegrationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var routeURLText = ""
    @State private var showDisconnectConfirmation = false
    @State private var initialCompletionSequence: UInt?

    private var parsedRouteURL: StravaRouteURLV1? {
        try? StravaRouteURLV1(routeURLText)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Strava route URL", text: $routeURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .disabled(coordinator.activity.isBusy)
                        .accessibilityLabel("Strava route URL")

                    if !routeURLText.isEmpty, parsedRouteURL == nil {
                        Label(
                            "Paste a URL like https://www.strava.com/routes/123.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Route")
                }

                Section {
                    Text(
                        "Bicino reads the selected route's name and geometry, " +
                            "keeps it on this iPhone and paired Apple Watch for " +
                            "seven days for offline navigation, then deletes the " +
                            "route data. You can reload it or disconnect and " +
                            "delete it sooner."
                    )
                    Link("Bicino Privacy Policy", destination: AppPrivacyPolicy.url)
                } header: {
                    Text("How your route is used")
                }

                Section {
                    HStack {
                        Text("Connection")
                        Spacer()
                        if coordinator.activity == .checking {
                            ProgressView().controlSize(.small)
                        }
                        Text(connectionLabel)
                            .foregroundStyle(.secondary)
                    }

                    if let error = coordinator.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

                    Button(primaryActionTitle) {
                        coordinator.importRoute(urlString: routeURLText)
                    }
                    .disabled(
                        parsedRouteURL == nil ||
                            !coordinator.isImportAvailable ||
                            coordinator.activity.isBusy
                    )

                    if coordinator.activity == .authorizing ||
                        coordinator.activity == .importing {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(
                                coordinator.activity == .authorizing
                                    ? "Waiting for Strava authorization…"
                                    : "Importing route…"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if coordinator.isConnected {
                    Section {
                        Button(
                            "Disconnect Strava and Delete Data",
                            role: .destructive
                        ) {
                            showDisconnectConfirmation = true
                        }
                        .disabled(coordinator.activity.isBusy)
                    } footer: {
                        Text(
                            "This removes every Strava route and reload reference " +
                                "from Bicino on iPhone and Apple Watch."
                        )
                    }
                }

                if !coordinator.isImportAvailable,
                   coordinator.activity != .checking {
                    Section {
                        Label(
                            "Strava route import is not available from this Bicino service right now.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import from Strava")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.cancelUserOperation()
                        dismiss()
                    }
                    .disabled(coordinator.activity == .disconnecting)
                }
            }
        }
        .interactiveDismissDisabled(coordinator.activity.isBusy)
        .onAppear {
            initialCompletionSequence = coordinator.completedImportSequence
            coordinator.clearError()
            coordinator.activate()
        }
        .onChange(of: routeURLText) { _ in coordinator.clearError() }
        .onChange(of: coordinator.completedImportSequence) { sequence in
            guard let initialCompletionSequence,
                  sequence != initialCompletionSequence else { return }
            dismiss()
        }
        .alert(
            "Disconnect Strava and Delete Data?",
            isPresented: $showDisconnectConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect and Delete", role: .destructive) {
                coordinator.disconnectAndDeleteData()
            }
        } message: {
            Text(
                "Bicino will remove its Strava connection, cached routes, " +
                    "and reload references. This does not delete routes on Strava."
            )
        }
    }

    private var connectionLabel: String {
        if coordinator.isConnected { return "Connected" }
        if coordinator.isImportAvailable { return "Not connected" }
        return "Unavailable"
    }

    private var primaryActionTitle: String {
        coordinator.isConnected ? "Import Route" : "Connect with Strava"
    }
}
