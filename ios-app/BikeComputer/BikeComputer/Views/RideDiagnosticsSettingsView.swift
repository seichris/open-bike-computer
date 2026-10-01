//
//  RideDiagnosticsSettingsView.swift
//  BikeComputer
//

import SwiftUI
import UniformTypeIdentifiers

struct RideDiagnosticsSettingsView: View {
    @ObservedObject var recorder: RideDiagnosticsRecorder
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIssue: RideIssueCode = .other
    @State private var diagnosticDomain = "ble"
    @State private var diagnosticLevel: UInt32 = 1
    @ObservedObject private var broker = DiagnosticsBrokerClient.shared
    @State private var importingPairing = false
    @State private var exportURL: URL?
    @State private var statusMessage: String?
    @State private var showingDeleteConfirmation = false
    @ObservedObject private var collection = DiagnosticsCollectionCoordinator.shared
    @State private var isExporting = false
    @State private var localMarkerStatus: String?
    @State private var deviceMarkerStatus: String?
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
                    guard recorder.markIssue(selectedIssue) else {
                        localMarkerStatus = "Failed"
                        deviceMarkerStatus = "Not attempted"
                        statusMessage = "The issue marker could not be saved on this iPhone."
                        return
                    }
                    localMarkerStatus = "Saved"
                    let deviceMarked = bleManager.sendDiagnosticsIssueMarker(selectedIssue)
                    deviceMarkerStatus = deviceMarked
                        ? "Queued; persistence pending"
                        : "Failed — device not ready"
                    statusMessage = deviceMarked
                        ? "Issue marker saved on the iPhone and queued for Bicino."
                        : "Issue marker saved on this iPhone; Bicino was not ready."
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
                Picker("Subsystem", selection: $diagnosticDomain) {
                    ForEach(DiagnosticsSchema.domains.filter {
                        DiagnosticsSchema.mask(for: $0) & DiagnosticsSchema.instrumentedMask != 0
                    }, id: \.self) { Text($0).tag($0) }
                }
                Picker("Detail", selection: $diagnosticLevel) {
                    Text("Debug").tag(UInt32(1))
                    Text("Trace").tag(UInt32(0))
                }
                Button("Record Subsystem for One Hour") {
                    _ = recorder.beginTargetedCapture(
                        mask: DiagnosticsSchema.mask(for: diagnosticDomain),
                        minimumLevel: diagnosticLevel, seconds: 3600,
                        budgetBytes: 8 * 1024 * 1024)
                }
                if let requested = recorder.runtimeCapturePolicy {
                    Text("iPhone journal policy requested for \(requested.durationSeconds / 60) minutes; 8 MiB trace budget.")
                    Text(bleManager.diagnosticsCaptureStatus?.acknowledges(requested) == true
                        ? "Bicino acknowledged the same capture and policy."
                        : "Bicino has not acknowledged this policy. iPhone recording is independent.")
                    if bleManager.diagnosticsCaptureStatus != nil {
                        Button("Retry Policy on Bicino") {
                            _ = bleManager.sendDiagnosticsCapturePolicy(requested)
                        }
                    }
                }
            } header: {
                Text("Targeted diagnostics")
            } footer: {
                Text("Only compiled, privacy-safe events are recorded. Info and critical baseline events stay enabled. This does not enable raw sensors, credentials or route coordinates.")
            }

            Section {
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
                    Label("Download Device Logs", systemImage: "arrow.down.doc")
                }
                .disabled(
                    collection.isRunning || !bleManager.isNavigationReady ||
                        !bleManager.supportsRideDiagnostics
                )
                if collection.isRunning {
                    Button("Cancel Device Download", role: .cancel) {
                        statusMessage = "Cancelling device log download…"
                        collection.cancel()
                    }
                }
                Text(collection.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let manifest = collection.manifest {
                    LabeledContent("Verified chunks", value: "\(manifest.verified.count) / \(manifest.expected.count)")
                    LabeledContent("Delivery", value: manifest.deliveryComplete ? "Complete at saved cutoff" : "Incomplete")
                    Text("Recording coverage is evaluated separately by the host validator.")
                        .font(.footnote)
                    if !collection.isRunning && !manifest.deliveryComplete {
                        Button("Start New Collection Cutoff") { collection.start(newCutoff: true) }
                    }
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
                Button("Pair Mac from Configuration File") { importingPairing = true }
                if broker.isPaired {
                    Button("Queue Handoff to Mac") { broker.enqueueExport(acquisitionID: nil) }
                    Button("Unpair Mac", role: .destructive) {
                        do { try broker.unpair() }
                        catch { statusMessage = "Mac pairing could not be removed." }
                    }
                }
            } header: { Text("Codex handoff") }
            footer: {
                Text("Pair only with your own Mac. Until pairing expires, it may request privacy-safe captures and receive bundles on your private LAN while the app is active. No reset, flash, raw payloads or arbitrary commands are allowed. Recording works without the Mac.")
            }

            Section {
                Button("Delete iPhone Logs", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(collection.isRunning || isExporting)
            } footer: {
                Text("Already-exported files are unaffected. Device-side chunks age out under their own retention policy.")
            }
        }
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.json]) { result in
            do { try broker.pair(from: result.get()) }
            catch { statusMessage = "The pairing file is invalid, expired or unavailable. No credentials were sent." }
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
                let completedURL = try await collection.exportForCodex(recorder: recorder)
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
    NavigationStack {
        RideDiagnosticsSettingsView(recorder: RideDiagnosticsRecorder())
    }
    .environmentObject(BLEManager())
}
