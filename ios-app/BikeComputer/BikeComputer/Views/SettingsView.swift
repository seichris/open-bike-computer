//
//  SettingsView.swift
//  BikeComputer
//
//  Settings view for runtime map configuration via BLE
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.openURL) private var openURL
    @ObservedObject private var offlineMapManager: OfflineMapManager
    let locationAuthorized: Bool

    init(
        locationAuthorized: Bool = true,
        offlineMapManager: OfflineMapManager
    ) {
        self.locationAuthorized = locationAuthorized
        self.offlineMapManager = offlineMapManager
    }
    
    var body: some View {
        NavigationView {
            Form {
                if !locationAuthorized {
                    Section {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Label("Enable Location Access", systemImage: "location")
                        }
                    } footer: {
                        Text("Location access is needed to download the map for your current area.")
                    }
                }

                DeviceScreensSettingsSection()
                OfflineMapSelectionSettingsSection(manager: offlineMapManager)
                DownloadedMapsSettingsSection(manager: offlineMapManager)

                Section {
                    NavigationLink {
                        UICustomizationSettingsView()
                    } label: {
                        Label("UI Customization", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        HardwareCustomizationSettingsView()
                    } label: {
                        Label("Hardware Customization", systemImage: "dial.low")
                    }

                    NavigationLink {
                        DeveloperSettingsView(offlineMapManager: offlineMapManager)
                    } label: {
                        Label("Developer Settings", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct OfflineMapSelectionSettingsSection: View {
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Section(header: Text("Map Selection")) {
            Text("Move the map to frame the area you want to download to your Bike Computer.")
                .foregroundColor(.secondary)

            Button(action: manager.beginMapAreaSelection) {
                Label("Choose Area", systemImage: "rectangle.dashed")
            }
            .disabled(manager.isBusy)

            if let bounds = manager.selectedMapBounds {
                SettingsValueRow(
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

            if !manager.statusMessage.isEmpty {
                SettingsValueRow(title: "Status", value: manager.statusMessage)
            }

            if manager.isBusy {
                ProgressView(value: manager.downloadProgress > 0 ? manager.downloadProgress : nil)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

private struct DownloadedMapsSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Section(header: Text("Downloaded Maps")) {
            if manager.cachedPackURLs.isEmpty {
                Text("No maps downloaded yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.cachedPackURLs, id: \.self) { packURL in
                    DownloadedMapRow(manager: manager, packURL: packURL)
                        .environmentObject(bleManager)
                }
            }

            if let job = manager.currentJob {
                SettingsValueRow(title: "Job", value: job.status)
                if let mapId = job.mapId {
                    SettingsValueRow(title: "Map ID", value: mapId)
                }
                if let region = job.sourceRegion {
                    SettingsValueRow(title: "Source", value: region.name)
                }
                if let area = job.geometry?.areaKm2 {
                    SettingsValueRow(title: "Area", value: "\(Int(area.rounded())) km²")
                }
            }
        }
    }
}

private struct DownloadedMapRow: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    let packURL: URL

    var body: some View {
        HStack(spacing: 12) {
            Text(manager.displayName(forCachedPack: packURL))
                .lineLimit(2)

            Spacer()

            Button {
                manager.transferCachedPack(at: packURL, bleManager: bleManager)
            } label: {
                Image(systemName: "arrow.up.circle")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(manager.isBusy || !bleManager.isNavigationReady)
            .accessibilityLabel("Transfer map to device")

            Button(role: .destructive) {
                manager.deleteCachedPack(at: packURL)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(manager.isBusy)
            .accessibilityLabel("Delete map")
        }
    }
}

private struct OfflineMapDeviceTransferSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Section(header: Text("Device Transfer")) {
            SettingsValueRow(
                title: "BLE",
                value: bleManager.isNavigationReady ? "Ready" : "Not Ready"
            )
            SettingsValueRow(
                title: "Transfer",
                value: bleManager.mapTransferStatusDescription
            )
            if let localURL = manager.downloadedPackURL {
                SettingsValueRow(title: "Selected Map", value: manager.displayName(forCachedPack: localURL))
            }

            if manager.transferProgress > 0 && manager.transferProgress < 1 {
                ProgressView(value: manager.transferProgress)
            }
        }
    }
}

private struct DeviceScreensSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Section(header: Text("Device Screens")) {
            ForEach(DeviceScreen.displayOrder) { screen in
                Toggle(screen.title, isOn: Binding(
                    get: { bleManager.isDeviceScreenEnabled(screen) },
                    set: { bleManager.setDeviceScreen(screen, enabled: $0) }
                ))
                .disabled(bleManager.isOnlyEnabledDeviceScreen(screen))
            }

            Picker("Default Screen", selection: $bleManager.defaultDeviceScreen) {
                ForEach(bleManager.enabledDeviceScreens) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .onChange(of: bleManager.defaultDeviceScreen) { _ in
                bleManager.sendDefaultDeviceScreen()
            }
        }
        .disabled(!bleManager.supportsDeviceSettings)
    }
}

private struct UICustomizationSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Form {
            Section(header: Text("Navigation Overlays"), footer: Text("Show or hide live navigation layers drawn above the map.")) {
                Toggle("Route Line", isOn: $bleManager.showRouteOverlay)
                    .onChange(of: bleManager.showRouteOverlay) { _ in bleManager.sendVisibilityMask() }
                Toggle("Current Position", isOn: $bleManager.showCurrentPosition)
                    .onChange(of: bleManager.showCurrentPosition) { _ in bleManager.sendVisibilityMask() }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Roads & Paths"), footer: Text("Control which street and trail classes appear on the device map.")) {
                Toggle("Major Roads", isOn: $bleManager.showMajorRoads)
                    .onChange(of: bleManager.showMajorRoads) { _ in bleManager.sendVisibilityMask() }
                Toggle("Local Streets", isOn: $bleManager.showLocalStreets)
                    .onChange(of: bleManager.showLocalStreets) { _ in bleManager.sendVisibilityMask() }
                Toggle("Paths & Tracks", isOn: $bleManager.showPaths)
                    .onChange(of: bleManager.showPaths) { _ in bleManager.sendVisibilityMask() }
                Toggle("Railways", isOn: $bleManager.showRailways)
                    .onChange(of: bleManager.showRailways) { _ in bleManager.sendVisibilityMask() }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Places & Terrain"), footer: Text("Control background map areas and lower-priority context.")) {
                Toggle("Buildings", isOn: $bleManager.showBuildings)
                    .onChange(of: bleManager.showBuildings) { _ in bleManager.sendVisibilityMask() }
                Toggle("Parks & Nature", isOn: $bleManager.showGreenSpace)
                    .onChange(of: bleManager.showGreenSpace) { _ in bleManager.sendVisibilityMask() }
                Toggle("Water", isOn: $bleManager.showWater)
                    .onChange(of: bleManager.showWater) { _ in bleManager.sendVisibilityMask() }
                Toggle("Other Areas", isOn: $bleManager.showOtherAreas)
                    .onChange(of: bleManager.showOtherAreas) { _ in bleManager.sendVisibilityMask() }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Map Rendering"), footer: Text("Feature toggles control map categories; polygon size filters tiny filled areas.")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Min Polygon Size")
                        Spacer()
                        Text("\(Int(bleManager.minPolygonSize)) px²")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $bleManager.minPolygonSize, in: 0...50, step: 5)
                        .onChange(of: bleManager.minPolygonSize) { newValue in
                            bleManager.sendSetting(id: 1, value: Int32(newValue))
                        }
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Detail Level"), footer: Text("Controls small-area density without overriding feature visibility.")) {
                Picker("Detail", selection: $bleManager.detailLevel) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: bleManager.detailLevel) { newValue in
                    bleManager.sendSetting(id: 2, value: Int32(newValue))
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Line Thickness")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Route Line Width")
                        Spacer()
                        Text("\(Int(bleManager.routeLineWidth)) px")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $bleManager.routeLineWidth, in: 2...48, step: 1)
                        .onChange(of: bleManager.routeLineWidth) { newValue in
                            bleManager.sendSetting(id: 3, value: Int32(newValue))
                        }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Street Width Boost")
                        Spacer()
                        Text("+\(Int(bleManager.streetLineWidthBoost)) px")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $bleManager.streetLineWidthBoost, in: 0...24, step: 1)
                        .onChange(of: bleManager.streetLineWidthBoost) { newValue in
                            bleManager.sendSetting(id: 9, value: Int32(newValue))
                        }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Position Marker Size")
                        Spacer()
                        Text("\(Int(bleManager.positionMarkerScale))x")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $bleManager.positionMarkerScale, in: 1...5, step: 1)
                        .onChange(of: bleManager.positionMarkerScale) { newValue in
                            bleManager.sendSetting(id: 10, value: Int32(newValue))
                        }
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Display Rotation"), footer: Text("Rotate display 90° CCW. Requires reboot.")) {
                Toggle("Rotate 90°", isOn: Binding(
                    get: { bleManager.displayRotation == 1 },
                    set: { newValue in
                        bleManager.displayRotation = newValue ? 1 : 0
                        bleManager.sendSetting(id: 4, value: Int32(bleManager.displayRotation))
                    }
                ))
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Map Mode")) {
                Picker("Rotation", selection: $bleManager.mapRotationMode) {
                    Text("North Up").tag(0)
                    Text("Course Up").tag(1)
                }
                .pickerStyle(.segmented)
                .onChange(of: bleManager.mapRotationMode) { newValue in
                    bleManager.sendSetting(id: 6, value: Int32(newValue))
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Zoom Level"), footer: Text("0 = Super Zoom, 5 = Farthest")) {
                Picker("Zoom", selection: $bleManager.zoomLevel) {
                    Text("0").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                    Text("5").tag(5)
                }
                .pickerStyle(.segmented)
                .onChange(of: bleManager.zoomLevel) { newValue in
                    bleManager.sendSetting(id: 7, value: Int32(newValue))
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)
        }
        .navigationTitle("UI Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HardwareCustomizationSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Form {
            Section(header: Text("Screen Navigation")) {
                Toggle("Tap to Switch Screens", isOn: $bleManager.tapToSwitchScreens)
                    .onChange(of: bleManager.tapToSwitchScreens) { newValue in
                        bleManager.sendSetting(id: 11, value: newValue ? 1 : 0)
                    }
            }
            .disabled(!bleManager.supportsDeviceSettings)

            Section(header: Text("Device Brightness")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(bleManager.deviceBrightnessPercent))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $bleManager.deviceBrightnessPercent, in: 5...100, step: 5)
                        .onChange(of: bleManager.deviceBrightnessPercent) { newValue in
                            bleManager.sendSetting(id: DeviceBLEProtocol.brightnessSettingID, value: Int32(newValue))
                        }
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)
        }
        .navigationTitle("Hardware Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeveloperSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var offlineMapManager: OfflineMapManager

    var body: some View {
        Form {
            connectionSummary
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))

            Section(header: Text("Map Server")) {
                SettingsValueRow(title: "Service", value: offlineMapManager.serverURLString)
                Button {
                    offlineMapManager.serverURLString = OfflineMapServiceConfig.productionServerURLString
                } label: {
                    Label("Use Production Server", systemImage: "checkmark.seal")
                }
            }

            OfflineMapDeviceTransferSettingsSection(manager: offlineMapManager)

            Section {
                HStack {
                    Text("Central")
                    Spacer()
                    Text(bleManager.centralStateDescription)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Navigation")
                    Spacer()
                    Text(bleManager.isNavigationReady ? "Ready" : "Not Ready")
                        .foregroundColor(bleManager.isNavigationReady ? .green : .secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trusted Device")
                    Text(bleManager.trustedPeripheralDescription)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Button(action: {
                    bleManager.reconnect()
                }) {
                    Label("Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                }

                Button(action: {
                    bleManager.sendDebugNavigationPacket()
                }) {
                    Label("Send Test Navigation", systemImage: "arrow.turn.up.left")
                }
                .disabled(!bleManager.isNavigationReady)

                Button(role: .destructive, action: {
                    bleManager.forgetTrustedPeripheral()
                }) {
                    Label("Forget Device", systemImage: "trash")
                }

                Button(action: {
                    UIPasteboard.general.string = bleManager.debugLogText
                }) {
                    Label("Copy Debug Log", systemImage: "doc.on.doc")
                }

                Button(action: {
                    bleManager.sendSetting(id: 5, value: 1)
                }) {
                    Label("Reboot Device", systemImage: "arrow.clockwise")
                }
                .disabled(!bleManager.isConnected || !bleManager.supportsDeviceSettings)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(bleManager.debugEvents.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Developer Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Bike Computer")
                .font(.body)

            Spacer()

            Text(connectionStatusText)
                .font(.subheadline)
                .foregroundColor(bleManager.isConnected ? .green : .red)
        }
    }

    private var connectionStatusText: String {
        guard bleManager.isConnected else {
            return "Disconnected"
        }

        if bleManager.signalStrength != 0 {
            return "Connected \(bleManager.signalStrength) dBm"
        }

        return "Connected"
    }
}

private struct SettingsValueRow: View {
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
    SettingsView(offlineMapManager: OfflineMapManager())
        .environmentObject(BLEManager())
}
