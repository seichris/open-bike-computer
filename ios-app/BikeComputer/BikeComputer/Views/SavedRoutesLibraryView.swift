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
    @Environment(\.dismiss) private var dismiss
    @State private var presentedImport: SavedRouteImportSheet?
    @State private var importFeedback: String?

    var body: some View {
        NavigationStack {
            Form {
                SavedRoutesSettingsSection(
                    routeLibrary: library,
                    stravaCoordinator: stravaCoordinator,
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
                    GPXRouteSaveSheet(library: library, draft: draft) { result in
                        importFeedback = result.message
                        presentedImport = nil
                    }
                }
            }
        }
    }
}

/// Only new GPX imports need confirmation. The typed draft/commit interaction
/// is shared with library integration tests; cancellation never writes bytes.
struct GPXRouteSaveSheet: View {
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
                        Label("Save Route", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!interaction.canSave(now: Date()))
                    .accessibilityIdentifier("saveApprovedRouteOffline")
                    if let error = interaction.errorMessage {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("offlineRouteSaveFailure")
                    }
                } footer: {
                    Text("Saves route guidance on this iPhone, not offline map tiles. You can send the saved route to Apple Watch separately.")
                }
            }
            .navigationTitle("Import GPX")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { interaction.cancel(); dismiss() }
                }
            }
            .onDisappear { interaction.cancel() }
        }
    }
}
