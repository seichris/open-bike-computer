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
    @ObservedObject private var firmwareUpdateManager: FirmwareUpdateManager
    let locationAuthorized: Bool

    init(
        locationAuthorized: Bool = true,
        offlineMapManager: OfflineMapManager,
        firmwareUpdateManager: FirmwareUpdateManager
    ) {
        self.locationAuthorized = locationAuthorized
        self.offlineMapManager = offlineMapManager
        self.firmwareUpdateManager = firmwareUpdateManager
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

                MainFirmwareUpdateSection(manager: firmwareUpdateManager)
                DeviceScreensSettingsSection()
                SavedMapsSettingsSection(manager: offlineMapManager)
                if offlineMapManager.isBusy || offlineMapManager.errorMessage != nil {
                    DownloadingMapsSettingsSection(manager: offlineMapManager)
                }

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
                        DeveloperSettingsView(
                            offlineMapManager: offlineMapManager,
                            firmwareUpdateManager: firmwareUpdateManager
                        )
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

private struct DeviceSoundsSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager

    private var soundSelection: Binding<DeviceSound> {
        Binding(
            get: { bleManager.selectedDeviceSound },
            set: { sound in
                bleManager.selectedDeviceSound = sound
                bleManager.saveSettings()
                if bleManager.isPowerButtonHonkEnabled {
                    bleManager.sendPowerButtonHonkConfiguration()
                }
            }
        )
    }

    private var volumeSelection: Binding<Double> {
        Binding(
            get: { bleManager.deviceSoundVolumePercent },
            set: { volume in
                bleManager.deviceSoundVolumePercent = volume
                bleManager.saveSettings()
            }
        )
    }

    private var powerButtonHonkSelection: Binding<Bool> {
        Binding(
            get: { bleManager.isPowerButtonHonkEnabled },
            set: { enabled in
                bleManager.isPowerButtonHonkEnabled = enabled
                bleManager.saveSettings()
                bleManager.sendPowerButtonHonkConfiguration()
            }
        )
    }

    var body: some View {
        Section(header: Text("Device Sounds")) {
            Picker("Sound", selection: soundSelection) {
                ForEach(DeviceSound.allCases) { sound in
                    Label(sound.title, systemImage: sound.systemImage)
                        .tag(sound)
                }
            }
            .pickerStyle(.inline)

            VStack(alignment: .leading) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int(bleManager.deviceSoundVolumePercent))%")
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: volumeSelection,
                    in: 0...100,
                    step: 5,
                    onEditingChanged: { isEditing in
                        bleManager.deviceSoundVolumeEditingChanged(isEditing)
                    }
                )
            }

            Toggle("Use PWR Button as Honk", isOn: powerButtonHonkSelection)
                .disabled(!bleManager.supportsPowerButtonHonk)

            if let error = bleManager.powerButtonHonkConfigurationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

private struct MainFirmwareUpdateSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: FirmwareUpdateManager

    var body: some View {
        if let manifest = manager.latestManifest,
           manager.isNewerUpdateAvailable(manifest, bleManager: bleManager) {
            Section(header: Text("Firmware Update")) {
                SettingsValueRow(
                    title: "Available",
                    value: "\(manifest.version) (\(manifest.build))"
                )

                if manager.isBusy, !manager.statusMessage.isEmpty {
                    StatusValueRow(status: manager.statusMessage, isBusy: true)
                }
                if manager.downloadProgress > 0 && manager.downloadProgress < 1 {
                    ProgressView(value: manager.downloadProgress)
                }
                if manager.uploadProgress > 0 && manager.uploadProgress < 1 {
                    ProgressView(value: manager.uploadProgress)
                }
                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button {
                    manager.installLatest(bleManager: bleManager)
                } label: {
                    Label("Install Update", systemImage: "arrow.up.forward.app")
                }
                .disabled(manager.isBusy || !bleManager.isNavigationReady)
            }
        }
    }
}

private struct DownloadingMapsSettingsSection: View {
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Section(header: Text("Downloading Maps")) {
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
                StatusValueRow(status: manager.statusMessage, isBusy: manager.isBusy)
            }

            if let sourceSummary {
                SettingsValueRow(title: "Source", value: sourceSummary)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var sourceSummary: String? {
        guard let regionName = manager.currentJob?.sourceRegion?.name else { return nil }
        if let area = manager.currentJob?.geometry?.areaKm2 {
            return "\(regionName) \(Int(area.rounded())) km²"
        }
        return regionName
    }
}

private struct SavedMapsSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager

    var body: some View {
        Section(header: Text("Saved Maps")) {
            if !bleManager.mapTransferActiveMapId.isEmpty {
                SettingsValueRow(
                    title: "Installed on Device",
                    value: manager.displayName(forMapId: bleManager.mapTransferActiveMapId)
                )
            }
            if let lastTransferDescription = manager.lastTransferDescription {
                SettingsValueRow(title: "Last Transfer", value: lastTransferDescription)
            }

            if manager.cachedPackURLs.isEmpty {
                Text("0 maps downloaded yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.cachedPackURLs, id: \.self) { packURL in
                    DownloadedMapRow(manager: manager, packURL: packURL)
                        .environmentObject(bleManager)
                }
            }

            Button(action: manager.beginMapAreaSelection) {
                Label("Download a new Map", systemImage: "rectangle.dashed")
            }
            .disabled(manager.isBusy)
        }
        .onAppear {
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActiveMapId) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationStatus) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationSequence) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
    }
}

private struct DownloadedMapRow: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    let packURL: URL

    var body: some View {
        let displayName = manager.displayName(forCachedPack: packURL)

        HStack(spacing: 12) {
            Text(displayName)
                .lineLimit(2)

            if bleManager.mapTransferActiveMapId == packURL.deletingPathExtension().lastPathComponent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Installed on device")
            }

            Spacer()

            Button {
                manager.transferCachedPack(at: packURL, bleManager: bleManager)
            } label: {
                Image(systemName: "arrow.up.circle")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(manager.isBusy || !bleManager.isNavigationReady)
            .accessibilityLabel("Transfer \(displayName) to device")

            Button(role: .destructive) {
                manager.deleteCachedPack(at: packURL)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(manager.isBusy)
            .accessibilityLabel("Delete \(displayName)")
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

private struct FirmwareUpdateSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: FirmwareUpdateManager

    var body: some View {
        Section(header: Text("Firmware Update")) {
            SettingsValueRow(
                title: "Current",
                value: currentFirmwareSummary
            )
            if !bleManager.firmwareGitSha.isEmpty {
                SettingsValueRow(
                    title: "Current SHA",
                    value: String(bleManager.firmwareGitSha.prefix(12))
                )
            }
            SettingsValueRow(
                title: "Target",
                value: bleManager.firmwareTarget.isEmpty ? "unknown" : bleManager.firmwareTarget
            )
            SettingsValueRow(
                title: "Status",
                value: manager.statusMessage.isEmpty ? bleManager.firmwareUpdateStatus : manager.statusMessage
            )

            TextField("Manifest Base URL", text: $manager.manifestBaseURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Toggle("Allow Developer Downgrade", isOn: $manager.allowDeveloperDowngrade)

            if !manager.lastManifestURLString.isEmpty {
                SettingsValueRow(
                    title: "Manifest",
                    value: manager.lastManifestURLString
                )
            }

            if let manifest = manager.latestManifest {
                SettingsValueRow(
                    title: "Available",
                    value: "\(manifest.version) (\(manifest.build))"
                )
            }

            if manager.downloadProgress > 0 && manager.downloadProgress < 1 {
                ProgressView(value: manager.downloadProgress)
            }
            if manager.uploadProgress > 0 && manager.uploadProgress < 1 {
                ProgressView(value: manager.uploadProgress)
            }
            if let error = manager.errorMessage ?? bleManager.firmwareUpdateLastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button {
                manager.refreshDeviceFirmwareStatus(bleManager: bleManager)
            } label: {
                Label("Refresh Firmware Status", systemImage: "arrow.clockwise")
            }
            .disabled(!bleManager.isNavigationReady)

            Button {
                manager.checkForUpdate(bleManager: bleManager)
            } label: {
                Label("Check for Firmware Update", systemImage: "square.and.arrow.down")
            }
            .disabled(manager.isBusy || !bleManager.isNavigationReady)

            Button {
                manager.installLatest(bleManager: bleManager)
            } label: {
                Label("Install Firmware Update", systemImage: "arrow.up.forward.app")
            }
            .disabled(!canInstall)
        }
    }

    private var canInstall: Bool {
        guard !manager.isBusy,
              bleManager.isNavigationReady,
              let manifest = manager.latestManifest else {
            return false
        }
        return manager.isUpdateAllowed(manifest, bleManager: bleManager)
    }

    private var currentFirmwareSummary: String {
        if bleManager.firmwareVersion.isEmpty && bleManager.firmwareBuild == 0 {
            return "unknown"
        }
        return "\(bleManager.firmwareVersion) (\(bleManager.firmwareBuild))"
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

            DeviceSoundsSettingsSection()
                .disabled(!bleManager.supportsDeviceSounds)

            Section(header: Text("Power")) {
                Picker("Disconnected Sleep After", selection: $bleManager.disconnectedSleepTimeout) {
                    ForEach(DisconnectedSleepTimeout.allCases) { timeout in
                        Text(timeout.title).tag(timeout)
                    }
                }
                .onChange(of: bleManager.disconnectedSleepTimeout) { newValue in
                    bleManager.sendSetting(
                        id: DeviceBLEProtocol.disconnectedSleepTimeoutSettingID,
                        value: newValue.settingValue
                    )
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
    @ObservedObject var firmwareUpdateManager: FirmwareUpdateManager

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
            FirmwareUpdateSettingsSection(manager: firmwareUpdateManager)

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

private struct StatusValueRow: View {
    let status: String
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Status")
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(status)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    SettingsView(
        offlineMapManager: OfflineMapManager(),
        firmwareUpdateManager: FirmwareUpdateManager()
    )
        .environmentObject(BLEManager())
}
