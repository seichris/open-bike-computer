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
                if coordinator.isRouteCatalogAuthorized {
                    routeCatalogSection
                    routeURLSection
                    privacySection

                    if let error = coordinator.errorMessage {
                        Section {
                            Label(
                                error,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        }
                    }

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
                } else {
                    connectSection
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
            coordinator.activateRouteCatalog()
        }
        .onDisappear {
            coordinator.deactivateRouteCatalog()
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

    private var connectSection: some View {
        Section {
            Button {
                coordinator.connect()
            } label: {
                HStack {
                    if coordinator.activity == .checking ||
                        coordinator.activity == .authorizing {
                        ProgressView().controlSize(.small)
                    }
                    Text("Connect with Strava")
                }
            }
            .disabled(
                !coordinator.isImportAvailable ||
                    coordinator.activity.isBusy
            )

            if coordinator.routeCatalogState == .authorizationExpired {
                Label(
                    "Your Strava authorization expired. Connect again to load routes.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private var routeCatalogSection: some View {
        Section {
            if coordinator.athleteRoutes.isEmpty {
                emptyRouteCatalogContent
            } else {
                ForEach(coordinator.athleteRoutes) { route in
                    routeRow(route)
                }
                routeCatalogFooter
            }
        } header: {
            HStack {
                Text("Your Routes")
                Spacer()
                Button {
                    coordinator.refreshRouteCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(routeCatalogIsLoading)
                .accessibilityLabel("Reload Strava routes")
            }
        }
    }

    @ViewBuilder
    private var emptyRouteCatalogContent: some View {
        switch coordinator.routeCatalogState {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Loading Strava route")
                        Text("Distance · Elevation · Type")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .redacted(reason: .placeholder)
                }
            }
        case .empty, .loaded:
            Label(
                "No routes were found in this Strava account.",
                systemImage: "map"
            )
            .foregroundStyle(.secondary)
        case .loadingMore(let loadedRouteCount):
            ProgressView("Loading more routes… \(loadedRouteCount) loaded")
        case .authorizationExpired:
            Label(
                "Your Strava authorization expired.",
                systemImage: "arrow.clockwise.circle"
            )
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button("Try Again") {
                coordinator.refreshRouteCatalog()
            }
        }
    }

    @ViewBuilder
    private var routeCatalogFooter: some View {
        switch coordinator.routeCatalogState {
        case .loadingMore(let loadedRouteCount):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading more routes… \(loadedRouteCount) loaded")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button("Try Again") {
                coordinator.refreshRouteCatalog()
            }
        default:
            EmptyView()
        }
    }

    private func routeRow(
        _ route: StravaAthleteRouteSummaryV1
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(route.name)
                    .font(.body.weight(.medium))
                Text(
                    "\(distanceText(route.distanceMeters)) · " +
                        "\(elevationText(route.elevationGainMeters)) · " +
                        route.type.displayName
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                coordinator.importRoute(route)
            } label: {
                if coordinator.isImporting(externalRouteID: route.routeID) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Import")
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                !route.type.isImportable ||
                    coordinator.activity.isBusy
            )
            .accessibilityHint(
                route.type.isImportable
                    ? "Imports this route into Bicino"
                    : "Only cycling routes can be imported"
            )
        }
    }

    private var routeURLSection: some View {
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

            Button("Import Route") {
                coordinator.importRoute(urlString: routeURLText)
            }
            .disabled(
                parsedRouteURL == nil ||
                    !coordinator.isImportAvailable ||
                    coordinator.activity.isBusy
            )
        } header: {
            Text("Import a Specific Route")
        }
    }

    private var privacySection: some View {
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
    }

    private var routeCatalogIsLoading: Bool {
        switch coordinator.routeCatalogState {
        case .loading, .loadingMore: true
        default: false
        }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(
                format: "%.1f km",
                locale: Locale.current,
                meters / 1_000
            )
        }
        return String(format: "%.0f m", locale: Locale.current, meters)
    }

    private func elevationText(_ meters: Double) -> String {
        String(format: "%.0f m elevation", locale: Locale.current, meters)
    }
}
