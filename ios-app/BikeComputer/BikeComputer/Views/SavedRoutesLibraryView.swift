import SwiftUI

private enum SavedRouteImportSheet: Identifiable {
    case strava
    case gpx(OfflineRouteSaveDraft)

    var id: String {
        switch self {
        case .strava: "strava"
        case .gpx(let draft): "gpx:\(draft.id.uuidString)"
        }
    }
}

/// A shortcut to the same library used by Settings, not a second save flow.
struct SavedRoutesLibraryView: View {
    @ObservedObject var library: PhoneRouteLibrary
    @ObservedObject var stravaCoordinator: StravaIntegrationCoordinator
    @ObservedObject var destinationStore: SavedDestinationStore
    let onSaveOnlineRoute: (SavedDestination?) -> Void
    /// Create a Route happens on the main map; this closes the shortcut first.
    let onCreateRoute: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var presentedImport: SavedRouteImportSheet?
    @State private var importFeedback: String?

    var body: some View {
        NavigationStack {
            Form {
                SavedRoutesSettingsSection(
                    routeLibrary: library,
                    stravaCoordinator: stravaCoordinator,
                    destinationStore: destinationStore,
                    onSaveOnlineRoute: onSaveOnlineRoute,
                    onCreateRoute: onCreateRoute,
                    onImportFromStrava: { presentedImport = .strava },
                    onConfirmGPX: { draft in
                        importFeedback = nil
                        presentedImport = .gpx(draft)
                    },
                    importFeedback: importFeedback
                )
            }
            .navigationTitle("Saved Routes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $presentedImport) { destination in
                switch destination {
                case .strava:
                    StravaRouteImportView(coordinator: stravaCoordinator)
                case .gpx(let draft):
                    RouteSaveSheet(library: library, draft: draft) { result in
                        importFeedback = result.message
                        presentedImport = nil
                    }
                }
            }
        }
    }
}

/// One confirmation for newly imported GPX and selected MapKit routes. The
/// immutable draft is captured before presentation; changing a plan cannot swap
/// geometry under this sheet. Cancellation never writes bytes.
struct RouteSaveSheet: View {
    @ObservedObject var library: PhoneRouteLibrary
    let onSaved: (OfflineRouteSaveResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var interaction: OfflineRouteSaveInteraction

    init(library: PhoneRouteLibrary, draft: OfflineRouteSaveDraft,
         onSaved: @escaping (OfflineRouteSaveResult) -> Void) {
        self.library = library
        self.onSaved = onSaved
        var interaction = OfflineRouteSaveInteraction()
        interaction.select(draft)
        _interaction = State(initialValue: interaction)
    }

    private var isPlannedMapKitRoute: Bool {
        interaction.draft?.archive.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone
    }

    /// A Road, Gravel, Everyday or Mountain route from Bicino's bicycle route service.
    private var isPlannedBicinoRoute: Bool {
        interaction.draft?.archive.route.provider == RouteProviderPolicyV1.valhallaSavedOnPhone
    }

    private var isPlannedRoute: Bool { isPlannedMapKitRoute || isPlannedBicinoRoute }

    private var footer: String {
        if isPlannedMapKitRoute {
            return "Saves this Apple Maps route and its instructions on this iPhone. Offline map tiles and Watch transfer are not included."
        }
        if isPlannedBicinoRoute {
            return "Saves this route and its instructions on this iPhone. Eligible routes sync privately to your Bicino account when you’re signed in. Offline map tiles and Watch transfer are not included."
        }
        return "Saves route guidance on this iPhone, not offline map tiles. You can send the saved route to Apple Watch separately."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route name") {
                    TextField("Route name", text: $interaction.proposedName)
                        .accessibilityIdentifier("offlineRouteName")
                    if let draft = interaction.draft {
                        Text(draft.archive.route.provider.attribution)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        interaction.save(now: Date()) { draft, name in
                            try library.saveOffline(draft, name: name)
                        }
                        if let result = interaction.result {
                            onSaved(result)
                            dismiss()
                        }
                    } label: {
                        Label(isPlannedRoute ? "Save Offline" : "Save Route",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(!interaction.canSave(now: Date()))
                    .accessibilityIdentifier("saveApprovedRouteOffline")
                    if let error = interaction.errorMessage {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("offlineRouteSaveFailure")
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(isPlannedRoute ? "Save Offline" : "Import GPX")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { interaction.cancel(); dismiss() }
                }
            }
            .onDisappear { interaction.cancel() }
        }
    }
}

/// Why a GPX file opened from another app could not be imported. It is a sheet,
/// not an alert, so it shows even when another sheet was already up: the
/// presenter replaces that sheet the same way it does for a valid file.
struct OpenedGPXFailureSheet: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("openedGPXFailure")
                } footer: {
                    Text("Nothing was saved. Export the route as a GPX file again and open it in Bicino, or choose Import GPX in Saved Routes.")
                }
            }
            .navigationTitle("Import GPX")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}
