//
//  RideDiagnosticsSettingsView.swift
//  BikeComputer
//

import SwiftUI

struct RideDiagnosticsSettingsView: View {
    @ObservedObject var recorder: RideDiagnosticsRecorder
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIssue: RideIssueCode = .other
    @State private var exportURL: URL?
    @State private var statusMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var isDownloading = false

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
                if let error = recorder.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Recording health")
            } footer: {
                Text("Logs stay on this iPhone until you explicitly export or delete them.")
            }

            Section {
                Picker("Issue type", selection: $selectedIssue) {
                    ForEach(RideIssueCode.allCases) { issue in
                        Text(issue.title).tag(issue)
                    }
                }
                Button {
                    recorder.markIssue(selectedIssue)
                    let deviceMarked = bleManager.sendDiagnosticsIssueMarker(selectedIssue)
                    statusMessage = deviceMarked
                        ? "Issue marker saved on the iPhone and queued for Bicino."
                        : "Issue marker saved on this iPhone; Bicino was not ready."
                } label: {
                    Label("Mark Issue Now", systemImage: "flag.fill")
                }
            } header: {
                Text("Issue marker")
            } footer: {
                Text("Choose a predefined category so the marker cannot capture private free-form notes.")
            }

            Section {
                Toggle("Detailed Ride Trace", isOn: detailedTraceBinding)
                if recorder.detailedTraceEnabled,
                   let expiry = recorder.detailedTraceExpiresAt {
                    Text("Automatically stops \(expiry.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Optional detailed capture")
            } footer: {
                Text("Adds normalized ride-automation decisions for one ride, for up to four hours. It never records coordinates, route text, health values, or raw sensors.")
            }

            Section {
                Button {
                    guard !isDownloading else { return }
                    isDownloading = true
                    statusMessage = "Preparing the authenticated device transfer…"
                    Task { @MainActor in
                        defer { isDownloading = false }
                        do {
                            let imported = try await DeviceDiagnosticsTransferManager()
                                .downloadDeviceLogs(
                                    bleManager: bleManager,
                                    recorder: recorder,
                                    status: { statusMessage = $0 }
                                )
                            statusMessage = imported == 0
                                ? "Device logs were already imported."
                                : "Imported \(imported) verified device chunk\(imported == 1 ? "" : "s")."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Download Device Logs", systemImage: "arrow.down.doc")
                }
                .disabled(isDownloading)
                Button {
                    exportSupportBundle()
                } label: {
                    Label("Export Support Bundle", systemImage: "square.and.arrow.up")
                }
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
                Button("Delete iPhone Logs", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            } footer: {
                Text("Already-exported files are unaffected. Device-side chunks age out under their own retention policy.")
            }
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
    }

    private var detailedTraceBinding: Binding<Bool> {
        Binding(
            get: { recorder.detailedTraceEnabled },
            set: { enabled in
                if enabled {
                    recorder.beginDetailedTrace()
                } else {
                    recorder.endDetailedTrace()
                }
            }
        )
    }

    private func exportSupportBundle() {
        do {
            exportURL = try recorder.exportBundle()
            statusMessage = "Support bundle ready to share."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        RideDiagnosticsSettingsView(recorder: RideDiagnosticsRecorder())
    }
    .environmentObject(BLEManager())
}
