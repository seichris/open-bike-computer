import SwiftUI
import UniformTypeIdentifiers

/// Approved-source alternative to MapKit's policy-gated Save Offline button.
/// Import/select, confirm, persist and start are deliberately separate actions.
struct OfflineRoutesView: View {
    @ObservedObject var library: PhoneRouteLibrary
    let onShow: (PlannedRouteSummaryV1) throws -> Void
    let onStart: (PlannedRouteSummaryV1) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var interaction = OfflineRouteSaveInteraction()
    @State private var isImporting = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Apple Maps routes cannot be saved offline. Import a user-owned GPX, or select an existing saved GPX or Strava route.")
                    Button {
                        actionError = nil
                        isImporting = true
                    } label: {
                        Label("Import GPX", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("offlineRouteImportGPX")
                } footer: {
                    Text("This saves route guidance, not offline map tiles. Strava routes keep their original expiry; reload them from Settings when needed.")
                }

                if let draft = interaction.draft {
                    Section("Selected route") {
                        TextField("Route name", text: $interaction.proposedName)
                            .disabled(draft.requiresExistingArchive || interaction.result != nil)
                            .accessibilityIdentifier("offlineRouteName")
                        Text(draft.archive.route.provider.attribution)
                        if let deadline = draft.archive.deleteAfter {
                            Text("Expires \(deadline.formatted(date: .abbreviated, time: .shortened))")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Button {
                                interaction.save(now: Date()) { draft, name in
                                    try library.saveOffline(draft, name: name)
                                }
                            } label: {
                                Label("Save Offline", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!interaction.canSave(now: context.date))
                            .accessibilityIdentifier("saveApprovedRouteOffline")
                        }
                        if let result = interaction.result {
                            Label(result.message, systemImage: "checkmark.circle")
                                .accessibilityIdentifier("offlineRouteSaveSuccess")
                            Button("Show on Map") { perform { try onShow(result.summary) } }
                            Button("Start Offline Navigation") { perform { try onStart(result.summary) } }
                                .accessibilityIdentifier("startSavedRouteOffline")
                        }
                        if let error = interaction.errorMessage {
                            Text(error).foregroundStyle(.red)
                                .accessibilityIdentifier("offlineRouteSaveFailure")
                        }
                        Button("Cancel selection", role: .cancel) { interaction.cancel() }
                    }
                }

                Section("Saved on this iPhone") {
                    if library.routes.isEmpty { Text("No saved routes") }
                    ForEach(library.routes) { summary in
                        Button {
                            do {
                                interaction.select(try library.offlineDraft(for: summary),
                                    displayName: library.displayName(for: summary))
                                actionError = nil
                            } catch { actionError = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(library.displayName(for: summary))
                                Text(summary.providerID == RouteProviderPolicyV1.strava.providerID
                                     ? "Strava · time-limited offline copy" : "User-provided GPX")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Offline Routes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { interaction.cancel(); dismiss() }
                }
            }
            .onAppear { library.reload() }
            .onDisappear { interaction.cancel() }
            .alert("Offline Route", isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: { Text(actionError ?? "") }
            .fileImporter(isPresented: $isImporting,
                allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: false, onCompletion: importGPX)
        }
    }

    private func importGPX(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= GPXRouteImporterV1.maximumInputBytes else {
                throw GPXRouteImporterError.fileTooLarge
            }
            // Only the parser reads source bytes. No imported file or draft is
            // copied to permanent storage until the user explicitly saves.
            let draft = try OfflineRouteSaveDraft.gpx(
                data: Data(contentsOf: url, options: .mappedIfSafe),
                fileName: url.lastPathComponent, now: Date())
            interaction.select(draft)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return }
            actionError = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch { actionError = error.localizedDescription }
    }
}
