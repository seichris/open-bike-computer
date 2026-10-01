//
//  RideDiagnosticsSettingsView.swift
//  BikeComputer
//

import SwiftUI
import UniformTypeIdentifiers

struct RideDiagnosticsSettingsView: View {
    @ObservedObject var recorder: RideDiagnosticsRecorder
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var broker: DiagnosticsBrokerClientV2
    @State private var importingEnrollment = false
    @State private var allowBrokerCapture = false
    @State private var allowBrokerCollection = false
    @EnvironmentObject private var collection: DiagnosticsCollectionCoordinatorV2
    @State private var selectedProfile = "ble-navigation"
    @State private var captureError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIssue: RideIssueCode = .other
    @State private var exportURL: URL?
    @State private var statusMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var isDownloading = false
    @State private var isExporting = false
    @State private var localMarkerStatus: String?
    @State private var deviceMarkerStatus: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                LabeledContent("Recording") {
                    Text(recorder.lastError == nil ? "Healthy" : "Needs attention")
                        .foregroundStyle(recorder.lastError == nil ? .green : .orange)
                }
                LabeledContent("Retained size") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(recorder.retainedBytes),
                        countStyle: .file
                    ))
                }
                LabeledContent("Dropped events") {
                    Text(String(recorder.droppedEventCount))
                }
                LabeledContent("Oldest retained") {
                    Text(recorder.oldestRetainedAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "None")
                }
                LabeledContent("Newest retained") {
                    Text(recorder.newestRetainedAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "None")
                }
                LabeledContent("Connected Bicino") {
                    Text(deviceDiagnosticsSupportLabel)
                        .foregroundStyle(
                            bleManager.supportsRideDiagnostics ? .green : .secondary
                        )
                }
                LabeledContent("Last device import") {
                    Text(recorder.lastDeviceImportAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "Never")
                }
                if let error = recorder.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Recording health")
            } footer: {
                Text("Logs are retained on this iPhone for up to 14 days, 20 captures, or 50 MB, whichever limit is reached first. Export important evidence before it ages out.")
            }

            Section {
                Picker("Issue type", selection: $selectedIssue) {
                    ForEach(RideIssueCode.allCases) { issue in
                        Text(issue.title).tag(issue)
                    }
                }
                Button {
                    _ = collection.mark(selectedIssue)
                    statusMessage = collection.incidentStatus
                } label: {
                    Label("Mark Issue Now", systemImage: "flag.fill")
                }
                if let localMarkerStatus {
                    LabeledContent("iPhone marker", value: localMarkerStatus)
                }
                if let deviceMarkerStatus {
                    LabeledContent("Bicino marker", value: deviceMarkerStatus)
                }
            } header: {
                Text("Issue marker")
            } footer: {
                Text("Choose a predefined category so the marker cannot capture private free-form notes.")
            }

            Section {
                Picker("Capture profile", selection: $selectedProfile) {
                    ForEach(DiagnosticsContractV2.profiles.keys.filter { $0 != "baseline" }.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Button("Start Bounded Capture on Both Sources") {
                    Task { @MainActor in
                        do {
                            _ = try await collection.startCapture(profile: selectedProfile,
                                durationSeconds: selectedProfile == "all" ? 900 : 7200)
                            captureError = nil
                        } catch {
                            captureError = "iPhone capture is retained; Bicino did not acknowledge this policy. Inspect capabilities before riding."
                        }
                    }
                }
                .disabled(!bleManager.isNavigationReady)
                if let captureError { Text(captureError).font(.footnote).foregroundStyle(.orange) }
                Toggle("Detailed Ride Trace", isOn: detailedTraceBinding)
                    .disabled(
                        !bleManager.supportsDetailedRideDiagnostics &&
                            !recorder.detailedTraceEnabled
                    )
                if recorder.detailedTraceEnabled,
                   let expiry = recorder.detailedTraceExpiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(
                            0,
                            Int(expiry.timeIntervalSince(context.date).rounded(.up))
                        )
                        Text("Remaining: \(formatRemaining(seconds: remaining)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Optional detailed capture")
            } footer: {
                Text(bleManager.supportsDetailedRideDiagnostics
                    ? "Adds normalized ride-automation decisions for one ride, for up to four hours. It never records coordinates, route text, health values, or raw sensors."
                    : "Detailed ride-automation capture requires development firmware. Standard privacy-safe diagnostics remain active.")
            }

            Section {
                Button {
                    collection.start()
                } label: {
                    Label("Collect iPhone + Bicino Logs", systemImage: "arrow.down.doc")
                }
                .disabled(collection.isCollecting || !bleManager.isNavigationReady || !bleManager.supportsRideDiagnostics)
                if collection.isCollecting {
                    Button("Pause Collection", role: .cancel) { collection.cancel() }
                    ProgressView()
                }
                Text(collection.status).font(.footnote).foregroundStyle(.secondary)
                if let bundle = collection.latestBundle {
                    ShareLink(item: bundle) { Label("Share Verified Handoff", systemImage: "square.and.arrow.up") }
                }
                Button {
                    exportSupportBundle()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Preparing Support Bundle…")
                        }
                    } else {
                        Label("Export Support Bundle", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share Latest Export", systemImage: "square.and.arrow.up.circle")
                    }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Mac handoff")
            } footer: {
                Text("The export is a stored ZIP with hashes and raw JSONL chunks. The repository validator can produce a correlated timeline.")
            }

            Section {
                Text(broker.status).font(.footnote)
                Toggle("Allow Mac capture controls", isOn: $allowBrokerCapture)
                Toggle("Allow Mac log collection", isOn: $allowBrokerCollection)
                Button("Import Mac Enrollment File") { importingEnrollment = true }
                if broker.paired { Button("Revoke Mac Access", role: .destructive) { broker.revoke() } }
            } header: { Text("Codex / paired Mac") } footer: {
                Text("Enrollment is explicit and app-family specific. The Mac can read sanitized logs; optional capture and collection grants are applied when importing. No flashing, reset, remote shell, coordinates or health streams are exposed. Open the app on the same network to deliver retained evidence.")
            }

            Section {
                Button("Delete iPhone Logs", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(isDownloading || isExporting)
            } footer: {
                Text("Already-exported files are unaffected. Device-side chunks age out under their own retention policy.")
            }
        }
        .fileImporter(isPresented: $importingEnrollment, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 16 * 1024 else { throw DiagnosticsBrokerClientError.invalidEnrollment }
                try broker.importEnrollment(Data(contentsOf: url), allowCapture: allowBrokerCapture, allowCollection: allowBrokerCollection)
                statusMessage = "Mac enrollment saved in this app's device-only Keychain."
            } catch { statusMessage = "Enrollment rejected. Check app family, expiry, and the original Mac-generated file." }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete all retained iPhone diagnostics?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete iPhone Logs", role: .destructive) {
                do {
                    try recorder.deleteLocalLogs()
                    statusMessage = "iPhone diagnostics deleted."
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            if let exportURL {
                try? FileManager.default.removeItem(at: exportURL)
                self.exportURL = nil
            }
        }
    }

    private var detailedTraceBinding: Binding<Bool> {
        Binding(
            get: { recorder.detailedTraceEnabled },
            set: { enabled in
                if enabled {
                    if bleManager.supportsDetailedRideDiagnostics {
                        recorder.beginDetailedTrace()
                    }
                } else {
                    recorder.endDetailedTrace()
                }
            }
        )
    }

    private var deviceDiagnosticsSupportLabel: String {
        guard bleManager.isConnected, bleManager.isNavigationReady else {
            return "Not connected"
        }
        return bleManager.supportsRideDiagnostics
            ? "Diagnostics supported"
            : "Firmware unsupported"
    }

    private func formatRemaining(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return hours > 0
            ? "\(hours)h \(minutes)m \(remainingSeconds)s"
            : "\(minutes)m \(remainingSeconds)s"
    }

    private func exportSupportBundle() {
        guard !isExporting else { return }
        isExporting = true
        statusMessage = "Preparing the support bundle…"
        exportTask = Task { @MainActor in
            defer { isExporting = false }
            do {
                let completedURL = try await recorder.exportBundleAsync()
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: completedURL)
                    return
                }
                if let exportURL {
                    try? FileManager.default.removeItem(at: exportURL)
                }
                exportURL = completedURL
                statusMessage = "Support bundle ready to share."
            } catch {
                if !Task.isCancelled {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    let recorder = RideDiagnosticsRecorder()
    let ble = BLEManager()
    let collection = DiagnosticsCollectionCoordinatorV2(recorder: recorder, bleManager: ble)
    NavigationStack { RideDiagnosticsSettingsView(recorder: recorder) }
        .environmentObject(ble)
        .environmentObject(collection)
        .environmentObject(DiagnosticsBrokerClientV2(recorder: recorder, ble: ble, collection: collection))
}
