import SwiftUI
import UniformTypeIdentifiers

struct SavedRoutesSettingsSection: View {
    @ObservedObject var routeLibrary: PhoneRouteLibrary
    @FocusState private var focusedRouteID: UUID?
    @State private var renameInteraction = SavedRouteRenameInteraction()
    @State private var errorMessage: String?
    @State private var isImportingGPX = false

    var body: some View {
        Section {
            if routeLibrary.routes.isEmpty {
                Label(
                    "No Saved Routes",
                    systemImage:
                        "point.topleft.down.to.point.bottomright.curvepath"
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(routeLibrary.routes) { route in
                    routeRow(route)
                }
            }

            Button {
                finishRenaming()
                focusedRouteID = nil
                isImportingGPX = true
            } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Saved Routes")
        } footer: {
            Text(
                "Save GPX route files to your Apple watch for offline navigation"
            )
        }
        .alert(
            "Route Sync Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onAppear { routeLibrary.reload() }
        .onChange(of: focusedRouteID) { newValue in
            scheduleRenameCommitIfNeeded(focusedRouteID: newValue)
        }
        .onDisappear { finishRenaming() }
        .fileImporter(
            isPresented: $isImportingGPX,
            allowedContentTypes: [
                UTType(filenameExtension: "gpx") ?? .xml,
            ],
            allowsMultipleSelection: false
        ) { result in
            importGPX(result)
        }
    }

    private func importGPX(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let byteCount = try url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
            guard byteCount > 0,
                  byteCount <= GPXRouteImporterV1.maximumInputBytes else {
                throw GPXRouteImporterError.fileTooLarge
            }
            _ = try routeLibrary.importGPX(
                Data(contentsOf: url, options: .mappedIfSafe),
                fileName: url.lastPathComponent
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ??
                "The GPX route could not be imported."
        }
    }

    private func routeRow(_ route: PlannedRouteSummaryV1) -> some View {
        let identity = WatchRouteIdentityV1(
            routeID: route.id,
            revision: route.revision,
            contentHash: route.contentHash
        )
        let status = routeLibrary.watchSyncState[identity] ?? .localOnly
        let displayName = routeLibrary.displayName(for: route)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                routeName(route, displayName: displayName)

                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture { focusedRouteID = nil }

                watchStatusControl(
                    status,
                    route: route,
                    displayName: displayName
                )

                Button(role: .destructive) {
                    finishRenaming()
                    focusedRouteID = nil
                    do {
                        try routeLibrary.delete(route)
                    } catch {
                        errorMessage =
                            "The route was kept because deletion could not be completed safely."
                    }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(status == .transferring || status == .deleting)
                .accessibilityLabel("Delete \(displayName)")
            }

            Text("\(route.source.label) → \(route.destination.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let transientStatus = transientStatus(status) {
                Label(transientStatus.label, systemImage: transientStatus.icon)
                    .font(.caption)
                    .foregroundStyle(transientStatus.color)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func routeName(
        _ route: PlannedRouteSummaryV1,
        displayName: String
    ) -> some View {
        if renameInteraction.editingRouteID == route.id {
            TextField(
                "Route name",
                text: Binding(
                    get: { renameInteraction.draftName },
                    set: { renameInteraction.updateDraft($0) }
                )
            )
            .font(.headline)
            .focused($focusedRouteID, equals: route.id)
            .submitLabel(.done)
            .onSubmit { focusedRouteID = nil }
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async { focusedRouteID = route.id }
            })
            .accessibilityLabel("Route name")
            .layoutPriority(1)
        } else {
            Button {
                if let commit = renameInteraction.begin(
                    routeID: route.id,
                    currentName: displayName
                ) {
                    commitRename(commit)
                }
                DispatchQueue.main.async { focusedRouteID = route.id }
            } label: {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(displayName)")
            .accessibilityHint("Edits this saved route name")
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func watchStatusControl(
        _ status: PhoneRouteWatchSyncStateV1,
        route: PlannedRouteSummaryV1,
        displayName: String
    ) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .accessibilityLabel("\(displayName) is saved on Apple Watch")
        case .transferring:
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Sending \(displayName) to Apple Watch")
        case .deleting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Deleting \(displayName) from Apple Watch")
        case .localOnly:
            sendButton(
                route,
                displayName: displayName,
                systemImage: "arrow.up.circle",
                color: .primary
            )
        case .rejected:
            sendButton(
                route,
                displayName: displayName,
                systemImage: "arrow.clockwise.circle",
                color: .red
            )
        }
    }

    private func sendButton(
        _ route: PlannedRouteSummaryV1,
        displayName: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Button {
            finishRenaming()
            focusedRouteID = nil
            do {
                try routeLibrary.sendToWatch(route)
            } catch {
                errorMessage = error.localizedDescription
            }
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Send \(displayName) to Apple Watch")
    }

    private func transientStatus(
        _ status: PhoneRouteWatchSyncStateV1
    ) -> (label: String, icon: String, color: Color)? {
        switch status {
        case .transferring:
            ("Queued", "clock", .secondary)
        case .deleting:
            ("Deleting", "clock", .secondary)
        case .rejected:
            ("Sync failed", "exclamationmark.triangle.fill", .red)
        case .localOnly, .ready:
            nil
        }
    }

    private func scheduleRenameCommitIfNeeded(focusedRouteID: UUID?) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard self.focusedRouteID == focusedRouteID,
                  let commit = renameInteraction.finishIfFocusMoved(
                    to: self.focusedRouteID
                  ) else {
                return
            }
            commitRename(commit)
        }
    }

    private func finishRenaming() {
        if let commit = renameInteraction.finish() {
            commitRename(commit)
        }
    }

    private func commitRename(_ commit: SavedRouteRenameCommit) {
        guard let route = routeLibrary.routes.first(where: {
            $0.id == commit.routeID
        }) else { return }
        routeLibrary.rename(route, to: commit.proposedName)
    }
}
