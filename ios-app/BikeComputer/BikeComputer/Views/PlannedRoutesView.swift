import SwiftUI
import UniformTypeIdentifiers

struct PlannedRoutesView: View {
    @ObservedObject var routeLibrary: PhoneRouteLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isImportingGPX = false

    var body: some View {
        NavigationStack {
            List {
                if routeLibrary.routes.isEmpty {
                    emptyState
                } else {
                    ForEach(routeLibrary.routes) { route in
                        routeRow(route)
                    }
                }
            }
            .navigationTitle("Offline Routes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImportingGPX = true
                    } label: {
                        Label("Import GPX", systemImage: "square.and.arrow.down")
                    }
                }
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
    }

    @ViewBuilder
    private var emptyState: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(
                "No Saved Routes",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text(
                    "Import a GPX route to prepare offline Watch navigation."
                )
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName:
                    "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No Saved Routes")
                    .font(.headline)
                Text("Import a GPX route to prepare offline Watch navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
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
        return VStack(alignment: .leading, spacing: 8) {
            Text(route.name)
                .font(.headline)
            Text("\(route.source.label) → \(route.destination.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Label(syncLabel(status), systemImage: syncIcon(status))
                    .font(.caption)
                    .foregroundStyle(syncColor(status))
                Spacer()
                if canSend(status) {
                    Button("Send to Watch") {
                        do {
                            try routeLibrary.sendToWatch(route)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    do {
                        try routeLibrary.delete(route)
                    } catch {
                        errorMessage =
                            "The route was kept because deletion could not be completed safely."
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(status == .transferring || status == .deleting)
                .accessibilityLabel("Delete \(route.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private func canSend(_ status: PhoneRouteWatchSyncStateV1) -> Bool {
        switch status {
        case .localOnly, .rejected:
            true
        case .transferring, .ready, .deleting:
            false
        }
    }

    private func syncLabel(_ status: PhoneRouteWatchSyncStateV1) -> String {
        switch status {
        case .localOnly: "On iPhone"
        case .transferring: "Queued"
        case .ready: "Ready on Watch"
        case .deleting: "Deleting"
        case .rejected: "Sync failed"
        }
    }

    private func syncIcon(_ status: PhoneRouteWatchSyncStateV1) -> String {
        switch status {
        case .localOnly: "iphone"
        case .transferring, .deleting: "clock"
        case .ready: "checkmark.circle.fill"
        case .rejected: "exclamationmark.triangle.fill"
        }
    }

    private func syncColor(_ status: PhoneRouteWatchSyncStateV1) -> Color {
        switch status {
        case .ready: .green
        case .rejected: .red
        default: .secondary
        }
    }
}
