//
//  OfflineMapsView.swift
//  BikeComputer
//
//  Offline map platform controls.
//

import SwiftUI

struct OfflineMapsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Form {
            Section(header: Text("Map Server")) {
                OfflineMapValueRow(title: "Service", value: manager.serverURLString)
                Button {
                    manager.serverURLString = OfflineMapServiceConfig.productionServerURLString
                } label: {
                    Label("Use Production Server", systemImage: "checkmark.seal")
                }
            }

            Section(header: Text("Download Map")) {
                Text("Move the map to frame the area you want to download to your Bike Computer.")
                    .foregroundColor(.secondary)

                Button(action: manager.beginMapAreaSelection) {
                    Label("Choose Area", systemImage: "rectangle.dashed")
                }
                .disabled(manager.isBusy || manager.hasPendingMapJob)

                if let bounds = manager.selectedMapBounds {
                    OfflineMapValueRow(
                        title: "Selected Bounds",
                        value: String(
                            format: "%.4f, %.4f - %.4f, %.4f",
                            bounds.minLat,
                            bounds.minLon,
                            bounds.maxLat,
                            bounds.maxLon
                        )
                    )
                }
            }

            if !manager.statusMessage.isEmpty {
                Section(header: Text("Status")) {
                    Text(manager.statusMessage)
                        .foregroundColor(.secondary)
                }
            }

            if let job = manager.currentJob {
                Section(header: Text("Current Job")) {
                    OfflineMapValueRow(title: "Status", value: job.status)
                    OfflineMapValueRow(title: "Job ID", value: job.jobId)
                    if let mapId = job.mapId {
                        OfflineMapValueRow(title: "Map ID", value: mapId)
                    }
                    if let region = job.sourceRegion {
                        OfflineMapValueRow(title: "Source", value: region.name)
                    }
                    if let area = job.geometry?.areaKm2 {
                        OfflineMapValueRow(title: "Area", value: "\(Int(area.rounded())) km²")
                    }
                    if let error = job.error {
                        Text(error)
                            .foregroundColor(.red)
                    }

                    Button(action: manager.refreshJob) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(manager.isBusy)

                    Button(action: manager.fetchDownloadURL) {
                        Label("Get Download URL", systemImage: "arrow.down.circle")
                    }
                    .disabled(manager.isBusy || job.mapId == nil)
                }
            }

            if let downloadURL = manager.downloadURL {
                Section(header: Text("Download")) {
                    Text(downloadURL.absoluteString)
                        .font(.caption)
                        .textSelection(.enabled)

                    ProgressView(value: manager.downloadProgress)
                    OfflineMapValueRow(title: "Progress", value: "\(Int((manager.downloadProgress * 100).rounded()))%")
                    if let byteProgress = manager.downloadByteProgress {
                        OfflineMapValueRow(
                            title: "Downloaded",
                            value: "\(Self.byteText(byteProgress.completedBytes)) of \(Self.byteText(byteProgress.totalBytes))"
                        )
                    }

                    if manager.downloadedPackURL == nil && !manager.isBusy {
                        Button(action: manager.downloadPack) {
                            Label("Retry Download", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            Section(header: Text("Device Transfer")) {
                OfflineMapValueRow(
                    title: "BLE",
                    value: bleManager.isNavigationReady ? "Ready" : "Not Ready"
                )
                OfflineMapValueRow(
                    title: "Transfer",
                    value: bleManager.mapTransferStatusDescription
                )
                if let localURL = manager.downloadedPackURL {
                    OfflineMapValueRow(title: "Pack", value: localURL.lastPathComponent)
                }

                Button(action: { bleManager.requestMapTransferMode(enabled: true) }) {
                    Label("Enable Transfer Mode", systemImage: "wifi")
                }
                .disabled(!bleManager.isNavigationReady)

                Button(action: { manager.transferDownloadedPack(bleManager: bleManager) }) {
                    Label("Upload to Device", systemImage: "sdcard")
                }
                .disabled(manager.isBusy || !bleManager.isNavigationReady || manager.downloadedPackURL == nil)

                if manager.transferProgress > 0 && manager.transferProgress < 1 {
                    ProgressView(value: manager.transferProgress)
                }
            }

            if manager.isBusy {
                Section {
                    ProgressView()
                }
            }

            if let error = manager.errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Offline Maps")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct OfflineMapValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    NavigationView {
        OfflineMapsView(manager: OfflineMapManager())
            .environmentObject(BLEManager())
    }
}
