//
//  SettingsView.swift
//  BikeComputer
//
//  Settings view for runtime map configuration via BLE
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit

struct SettingsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var offlineMapManager: OfflineMapManager
    @ObservedObject private var firmwareUpdateManager: FirmwareUpdateManager
    @FocusState private var focusedSavedMapFilename: String?
    let locationAuthorized: Bool
    let currentLocation: CLLocation?
    let onStartTestNavigation: (String) -> Void

    init(
        locationAuthorized: Bool = true,
        currentLocation: CLLocation?,
        offlineMapManager: OfflineMapManager,
        firmwareUpdateManager: FirmwareUpdateManager,
        onStartTestNavigation: @escaping (String) -> Void
    ) {
        self.locationAuthorized = locationAuthorized
        self.currentLocation = currentLocation
        self.offlineMapManager = offlineMapManager
        self.firmwareUpdateManager = firmwareUpdateManager
        self.onStartTestNavigation = onStartTestNavigation
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
                SavedMapsSettingsSection(
                    manager: offlineMapManager,
                    focusedPackFilename: $focusedSavedMapFilename
                )
                if OfflineMapDownloadingSectionPresentation.isVisible(
                    isBusy: offlineMapManager.isBusy,
                    hasPendingJob: offlineMapManager.hasPendingMapJob,
                    hasPendingActivation: offlineMapManager.hasPendingDeviceActivation,
                    errorMessage: offlineMapManager.errorMessage
                ) {
                    DownloadingMapsSettingsSection(manager: offlineMapManager)
                }

                Section {
                    NavigationLink {
                        BikeComputersSettingsView()
                    } label: {
                        Label(
                            BikeComputersMenuPolicy.title(
                                knownDeviceCount: bleManager.knownDevices.count
                            ),
                            systemImage: "bicycle"
                        )
                    }

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
                            firmwareUpdateManager: firmwareUpdateManager,
                            currentLocation: currentLocation,
                            onStartTestNavigation: { destination in
                                onStartTestNavigation(destination)
                                dismiss()
                            }
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
    @EnvironmentObject private var bleManager: BLEManager
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

            if manager.hasPausedMapUpload {
                Button {
                    manager.resumePausedMapUpload(bleManager: bleManager)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusValueRow(
                            status: "Map upload paused. Tap to resume.",
                            isBusy: false
                        )
                        if let activationProgress = manager.activationProgress {
                            ProgressView(value: activationProgress.fraction)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(manager.isBusy || !bleManager.isNavigationReady)
                .accessibilityLabel("Resume map upload")
                .accessibilityHint("Reconnects to the device Wi-Fi and resumes the saved map")
            } else if let activationProgress = manager.activationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    StatusValueRow(status: activationProgress.label, isBusy: false)
                    ProgressView(value: activationProgress.fraction)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Map activation \(activationProgress.label)")
            } else if !manager.statusMessage.isEmpty {
                StatusValueRow(status: manager.statusMessage, isBusy: manager.isBusy)
            } else if manager.hasPendingDeviceActivation {
                StatusValueRow(status: "Checking device activation", isBusy: false)
            }

            if let generationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Generation Progress")
                        Spacer()
                        Text("\(generationProgress.percentage)%")
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: generationProgress.fraction)
                    Text("\(generationProgress.completedBlocks) of \(generationProgress.totalBlocks) map blocks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let sourceSummary {
                SettingsValueRow(title: "Source", value: sourceSummary)
            }

            if let preparationTimeEstimate {
                SettingsValueRow(title: "Estimated Preparation", value: preparationTimeEstimate)
                Text("Feature density and water coverage can affect preparation time.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if manager.isBusy, manager.hasPendingMapJob {
                Button(role: .destructive) {
                    manager.pausePendingMapJob()
                } label: {
                    Label("Pause Map Preparation", systemImage: "pause.circle")
                }
            } else if manager.hasPendingMapJob {
                Button {
                    manager.resumePendingMapJobIfNeeded(bleManager: bleManager)
                } label: {
                    Label("Resume Map Preparation", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    manager.forgetPendingMapJob()
                } label: {
                    Label("Forget Pending Map", systemImage: "trash")
                }
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

    private var preparationTimeEstimate: String? {
        guard let job = manager.currentJob,
              !job.isTerminal,
              let areaKm2 = job.geometry?.areaKm2 else {
            return nil
        }
        return OfflineMapPreparationTimeEstimate.description(for: areaKm2)
    }

    private var generationProgress: OfflineMapJobProgress? {
        guard manager.currentJob?.status == "converting_features" else { return nil }
        return manager.currentJob?.progress
    }
}

private struct SavedMapsSettingsSection: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    @FocusState.Binding var focusedPackFilename: String?
    @State private var renameInteraction = SavedMapRenameInteraction()

    var body: some View {
        Section(header: Text("Saved Maps")) {
            if manager.cachedPackURLs.isEmpty {
                Text("0 maps downloaded yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.cachedPackURLs, id: \.self) { packURL in
                    DownloadedMapRow(
                        manager: manager,
                        packURL: packURL,
                        focusedPackFilename: $focusedPackFilename,
                        renameInteraction: $renameInteraction,
                        onCommitRename: commitRename
                    )
                        .environmentObject(bleManager)
                }
            }

            Button {
                if let commit = renameInteraction.finish() {
                    commitRename(commit)
                }
                focusedPackFilename = nil
                manager.beginMapAreaSelection()
                if manager.isMapAreaSelectionActive {
                    dismiss()
                }
            } label: {
                Label("Download a new Map", systemImage: "rectangle.dashed")
            }
        }
        .onChange(of: focusedPackFilename) { newValue in
            scheduleRenameCommitIfNeeded(focusedFilename: newValue)
        }
        .onDisappear {
            if let commit = renameInteraction.finish() {
                commitRename(commit)
            }
        }
        .onAppear {
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActiveMapId) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActiveSessionId) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationStatus) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationSequence) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationStep) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
        .onChange(of: bleManager.mapTransferActivationProgress) { _ in
            manager.reconcileLastTransfer(bleManager: bleManager)
        }
    }

    private func scheduleRenameCommitIfNeeded(focusedFilename: String?) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard focusedPackFilename == focusedFilename,
                  let commit = renameInteraction.finishIfFocusMoved(
                    to: focusedPackFilename
                  ) else {
                return
            }
            commitRename(commit)
        }
    }

    private func commitRename(_ commit: SavedMapRenameCommit) {
        guard let packURL = manager.cachedPackURLs.first(where: {
            $0.lastPathComponent == commit.filename
        }) else {
            return
        }
        manager.renameCachedPack(at: packURL, to: commit.proposedName)
    }
}

private struct DownloadedMapRow: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    let packURL: URL
    @FocusState.Binding var focusedPackFilename: String?
    @Binding var renameInteraction: SavedMapRenameInteraction
    let onCommitRename: (SavedMapRenameCommit) -> Void
    @State private var isShowingInstalledConfirmation = false

    var body: some View {
        let displayName = manager.displayName(forCachedPack: packURL)
        let isInstalled = manager.isCachedPackInstalled(
            packURL,
            activeMapId: bleManager.mapTransferActiveMapId,
            activeSessionId: bleManager.mapTransferActiveSessionId
        )
        let isPausedUpload = manager.isPausedMapUpload(packURL)

        HStack(spacing: 12) {
            SavedMapThumbnail(
                image: manager.previewImage(forCachedPack: packURL)
            )
            .task(id: packURL) {
                manager.loadPreviewIfNeeded(forCachedPack: packURL)
            }

            if renameInteraction.editingFilename == packURL.lastPathComponent {
                TextField(
                    "Map name",
                    text: Binding(
                        get: { renameInteraction.draftName },
                        set: { renameInteraction.updateDraft($0) }
                    )
                )
                    .focused($focusedPackFilename, equals: packURL.lastPathComponent)
                    .submitLabel(.done)
                    .onSubmit {
                        focusedPackFilename = nil
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        DispatchQueue.main.async {
                            focusedPackFilename = packURL.lastPathComponent
                        }
                    })
                    .accessibilityLabel("Map name")
                    .layoutPriority(1)
            } else {
                Button {
                    if let commit = renameInteraction.begin(
                        filename: packURL.lastPathComponent,
                        currentName: displayName
                    ) {
                        onCommitRename(commit)
                    }
                    DispatchQueue.main.async {
                        focusedPackFilename = packURL.lastPathComponent
                    }
                } label: {
                    Text(displayName)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(displayName)")
                .accessibilityHint("Edits this saved map name")
                .layoutPriority(1)
            }

            Spacer()
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedPackFilename = nil
                }

            if isInstalled {
                Button {
                    finishRenaming()
                    focusedPackFilename = nil
                    isShowingInstalledConfirmation = true
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(displayName) is installed on device")
                .accessibilityHint("Shows the installed map status")
            } else {
                Button {
                    finishRenaming()
                    focusedPackFilename = nil
                    manager.transferCachedPack(at: packURL, bleManager: bleManager)
                } label: {
                    Image(
                        systemName: isPausedUpload
                            ? "arrow.clockwise.circle"
                            : "arrow.up.circle"
                    )
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(
                    manager.isBusy ||
                        (!isPausedUpload && manager.hasActiveBackgroundUpload) ||
                        !bleManager.isNavigationReady
                )
                .accessibilityLabel(
                    isPausedUpload
                        ? "Resume transferring \(displayName) to device"
                        : "Transfer \(displayName) to device"
                )
            }

            Button(role: .destructive) {
                finishRenaming()
                focusedPackFilename = nil
                manager.deleteCachedPack(at: packURL)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(manager.isBusy || manager.hasActiveBackgroundUpload)
            .accessibilityLabel("Delete \(displayName)")
        }
        .alert("Already on Device", isPresented: $isShowingInstalledConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This map is already installed on the device.")
        }
    }

    private func finishRenaming() {
        if let commit = renameInteraction.finish() {
            onCommitRename(commit)
        }
    }
}

private struct SavedMapThumbnail: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "map")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
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
            ForEach(bleManager.availableDeviceScreens) { screen in
                Toggle(screen.title, isOn: Binding(
                    get: { bleManager.isDeviceScreenEnabled(screen) },
                    set: { bleManager.setDeviceScreen(screen, enabled: $0) }
                ))
                .disabled(bleManager.isOnlyEnabledDeviceScreen(screen))
            }

            Picker("Default Screen", selection: Binding(
                get: { bleManager.effectiveDefaultDeviceScreen },
                set: {
                    bleManager.defaultDeviceScreen = $0
                    bleManager.sendDefaultDeviceScreen()
                }
            )) {
                ForEach(bleManager.enabledDeviceScreens) { screen in
                    Text(screen.title).tag(screen)
                }
            }
        }
        .disabled(!bleManager.supportsDeviceSettings ||
                  !bleManager.hasReceivedDeviceCapabilities)
    }
}

private struct UICustomizationSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager

    private var screenStylesFooter: String {
        if !bleManager.hasReceivedDeviceCapabilities {
            return "Checking whether the connected firmware supports independent map styles."
        }
        if bleManager.supportsIndependentMapProfiles {
            return "Configure map appearance independently for each device screen."
        }
        return "This firmware uses one shared style for both map screens. Update the firmware to configure them independently."
    }

    var body: some View {
        Form {
            Section(header: Text("Screen Styles"), footer: Text(screenStylesFooter)) {
                NavigationLink {
                    MapStyleSettingsView(screen: .map)
                } label: {
                    Label(bleManager.supportsIndependentMapProfiles ? "Map" : "Map Screens",
                          systemImage: "map")
                }

                if bleManager.supportsIndependentMapProfiles {
                    NavigationLink {
                        MapStyleSettingsView(screen: .mapPlusNavigation)
                    } label: {
                        Label("Map + Navigation", systemImage: "location.north.line")
                    }
                }
            }
            .disabled(!bleManager.supportsDeviceSettings ||
                      !bleManager.hasReceivedDeviceCapabilities)

            Section(header: Text("Map Mode"), footer: Text("Applies only to the Map screen. Map + Navigation automatically uses course-up while navigating.")) {
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

            Section(header: Text("Navigation Overlays"), footer: Text("Show or hide live navigation layers drawn above both map screens.")) {
                Toggle("Route Line", isOn: $bleManager.showRouteOverlay)
                    .onChange(of: bleManager.showRouteOverlay) { _ in bleManager.sendVisibilityMask() }
                Toggle("Current Position", isOn: $bleManager.showCurrentPosition)
                    .onChange(of: bleManager.showCurrentPosition) { _ in bleManager.sendVisibilityMask() }
            }
            .disabled(!bleManager.supportsDeviceSettings)
        }
        .navigationTitle("UI Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum MapStyleScreen {
    case map
    case mapPlusNavigation

    var title: String {
        switch self {
        case .map: return "Map"
        case .mapPlusNavigation: return "Map + Navigation"
        }
    }

    var deviceScreen: DeviceScreen {
        switch self {
        case .map: return .map
        case .mapPlusNavigation: return .mapPlusNavigation
        }
    }

    func settingID(map: UInt8, mapPlusNavigation: UInt8) -> UInt8 {
        self == .map ? map : mapPlusNavigation
    }
}

private struct MapStyleSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    let screen: MapStyleScreen

    private var navigationTitle: String {
        screen == .map && !bleManager.supportsIndependentMapProfiles
            ? "Map Screens"
            : screen.title
    }

    private func binding<Value>(
        map: ReferenceWritableKeyPath<BLEManager, Value>,
        mapPlusNavigation: ReferenceWritableKeyPath<BLEManager, Value>
    ) -> Binding<Value> {
        let keyPath = screen == .map ? map : mapPlusNavigation
        return Binding(
            get: { bleManager[keyPath: keyPath] },
            set: { bleManager[keyPath: keyPath] = $0 }
        )
    }

    private var minPolygonSize: Binding<Double> {
        binding(map: \.minPolygonSize, mapPlusNavigation: \.mapPlusNavigationMinPolygonSize)
    }

    private var detailLevel: Binding<Int> {
        binding(map: \.detailLevel, mapPlusNavigation: \.mapPlusNavigationDetailLevel)
    }

    private var routeLineWidth: Binding<Double> {
        binding(map: \.routeLineWidth, mapPlusNavigation: \.mapPlusNavigationRouteLineWidth)
    }

    private var streetLineWidthBoost: Binding<Double> {
        binding(map: \.streetLineWidthBoost, mapPlusNavigation: \.mapPlusNavigationStreetLineWidthBoost)
    }

    private var positionMarkerScale: Binding<Double> {
        binding(map: \.positionMarkerScale, mapPlusNavigation: \.mapPlusNavigationPositionMarkerScale)
    }

    private var zoomLevel: Binding<Int> {
        binding(map: \.zoomLevel, mapPlusNavigation: \.mapPlusNavigationZoomLevel)
    }

    private var showMajorRoads: Binding<Bool> {
        binding(map: \.showMajorRoads, mapPlusNavigation: \.mapPlusNavigationShowMajorRoads)
    }

    private var showLocalStreets: Binding<Bool> {
        binding(map: \.showLocalStreets, mapPlusNavigation: \.mapPlusNavigationShowLocalStreets)
    }

    private var localRoadsControl: Binding<Bool> {
        guard !bleManager.supportsExtendedMapVisibility else {
            return showLocalStreets
        }
        return Binding(
            get: { showLocalStreets.wrappedValue || showServiceRoads.wrappedValue },
            set: {
                showLocalStreets.wrappedValue = $0
                showServiceRoads.wrappedValue = $0
            }
        )
    }

    private var showPaths: Binding<Bool> {
        binding(map: \.showPaths, mapPlusNavigation: \.mapPlusNavigationShowPaths)
    }

    private var pathsControl: Binding<Bool> {
        guard !bleManager.supportsExtendedMapVisibility else {
            return showPaths
        }
        return Binding(
            get: { showPaths.wrappedValue || showTracks.wrappedValue },
            set: {
                showPaths.wrappedValue = $0
                showTracks.wrappedValue = $0
            }
        )
    }

    private var showTracks: Binding<Bool> {
        binding(map: \.showTracks, mapPlusNavigation: \.mapPlusNavigationShowTracks)
    }

    private var showServiceRoads: Binding<Bool> {
        binding(map: \.showServiceRoads, mapPlusNavigation: \.mapPlusNavigationShowServiceRoads)
    }

    private var showRailways: Binding<Bool> {
        binding(map: \.showRailways, mapPlusNavigation: \.mapPlusNavigationShowRailways)
    }

    private var showBuildings: Binding<Bool> {
        binding(map: \.showBuildings, mapPlusNavigation: \.mapPlusNavigationShowBuildings)
    }

    private var showGreenSpace: Binding<Bool> {
        binding(map: \.showGreenSpace, mapPlusNavigation: \.mapPlusNavigationShowGreenSpace)
    }

    private var showWater: Binding<Bool> {
        binding(map: \.showWater, mapPlusNavigation: \.mapPlusNavigationShowWater)
    }

    private var showOtherAreas: Binding<Bool> {
        binding(map: \.showOtherAreas, mapPlusNavigation: \.mapPlusNavigationShowOtherAreas)
    }

    var body: some View {
        Form {
            Section(header: Text("Roads & Paths"), footer: Text("Service roads commonly include driveways and internal compound roads. Separate Service Roads and Tracks require current v2 map downloads; legacy maps keep each pair combined.")) {
                Toggle("Major Roads", isOn: showMajorRoads)
                    .onChange(of: showMajorRoads.wrappedValue) { _ in sendVisibilityMask() }
                Toggle(bleManager.supportsExtendedMapVisibility
                       ? "Residential & Local Roads"
                       : "Residential, Local & Service Roads",
                       isOn: localRoadsControl)
                    .onChange(of: localRoadsControl.wrappedValue) { _ in sendVisibilityMask() }
                if bleManager.supportsExtendedMapVisibility {
                    Toggle("Service Roads", isOn: showServiceRoads)
                        .onChange(of: showServiceRoads.wrappedValue) { _ in sendVisibilityMask() }
                }
                Toggle(bleManager.supportsExtendedMapVisibility
                       ? "Paths & Footways"
                       : "Paths, Footways & Tracks",
                       isOn: pathsControl)
                    .onChange(of: pathsControl.wrappedValue) { _ in sendVisibilityMask() }
                if bleManager.supportsExtendedMapVisibility {
                    Toggle("Tracks", isOn: showTracks)
                        .onChange(of: showTracks.wrappedValue) { _ in sendVisibilityMask() }
                }
                Toggle("Railways", isOn: showRailways)
                    .onChange(of: showRailways.wrappedValue) { _ in sendVisibilityMask() }
            }

            Section(header: Text("Places & Terrain"), footer: Text("Control background map areas and lower-priority context on this screen.")) {
                Toggle("Buildings", isOn: showBuildings)
                    .onChange(of: showBuildings.wrappedValue) { _ in sendVisibilityMask() }
                Toggle("Parks & Nature", isOn: showGreenSpace)
                    .onChange(of: showGreenSpace.wrappedValue) { _ in sendVisibilityMask() }
                Toggle("Water", isOn: showWater)
                    .onChange(of: showWater.wrappedValue) { _ in sendVisibilityMask() }
                Toggle("Other Areas", isOn: showOtherAreas)
                    .onChange(of: showOtherAreas.wrappedValue) { _ in sendVisibilityMask() }
            }

            Section(header: Text("Map Rendering"), footer: Text("Feature toggles control map categories; polygon size filters tiny filled areas.")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Min Polygon Size")
                        Spacer()
                        Text("\(Int(minPolygonSize.wrappedValue)) px²")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: minPolygonSize, in: 0...50, step: 5)
                        .onChange(of: minPolygonSize.wrappedValue) { newValue in
                            sendSetting(mapID: 1, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID, value: Int32(newValue))
                        }
                }
            }

            Section(header: Text("Detail Level"), footer: Text("Controls small-area density without overriding feature visibility.")) {
                Picker("Detail", selection: detailLevel) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: detailLevel.wrappedValue) { newValue in
                    sendSetting(mapID: 2, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID, value: Int32(newValue))
                }
            }

            Section(header: Text("Line Thickness")) {
                settingSlider(title: "Route Line Width", value: routeLineWidth, range: 2...48, prefix: "", suffix: " px") { newValue in
                    sendSetting(mapID: 3, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID, value: Int32(newValue))
                }
                settingSlider(title: "Street Width Boost", value: streetLineWidthBoost, range: 0...24, prefix: "+", suffix: " px") { newValue in
                    sendSetting(mapID: 9, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationStreetLineWidthBoostSettingID, value: Int32(newValue))
                }
                settingSlider(title: "Position Marker Size", value: positionMarkerScale, range: 1...5, prefix: "", suffix: "x") { newValue in
                    sendSetting(mapID: 10, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID, value: Int32(newValue))
                }
            }

            Section(header: Text("Zoom Level"), footer: Text("0 = Super Zoom, 5 = Farthest")) {
                Picker("Zoom", selection: zoomLevel) {
                    ForEach(0...5, id: \.self) { level in
                        Text("\(level)").tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: zoomLevel.wrappedValue) { newValue in
                    sendSetting(mapID: 7, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID, value: Int32(newValue))
                }
            }
        }
        .disabled(!bleManager.supportsDeviceSettings ||
                  !bleManager.hasReceivedDeviceCapabilities ||
                  (screen == .mapPlusNavigation &&
                   !bleManager.supportsIndependentMapProfiles))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendVisibilityMask() {
        bleManager.sendVisibilityMask(for: screen.deviceScreen)
    }

    private func sendSetting(mapID: UInt8, mapPlusNavigationID: UInt8, value: Int32) {
        bleManager.sendSetting(
            id: screen.settingID(map: mapID, mapPlusNavigation: mapPlusNavigationID),
            value: value
        )
    }

    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        prefix: String,
        suffix: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(prefix)\(Int(value.wrappedValue))\(suffix)")
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .onChange(of: value.wrappedValue, perform: onChange)
        }
    }
}

private struct HardwareCustomizationSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Form {
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

            Section(header: Text("Screen Navigation")) {
                Toggle("Tap to Switch Screens", isOn: $bleManager.tapToSwitchScreens)
                    .onChange(of: bleManager.tapToSwitchScreens) { newValue in
                        bleManager.sendSetting(id: 11, value: newValue ? 1 : 0)
                    }
            }
            .disabled(!bleManager.supportsDeviceSettings)
        }
        .navigationTitle("Hardware Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TestNavigationSettingsSection: View {
    let currentLocation: CLLocation?
    let onStartNavigation: (String) -> Void

    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @State private var destination = ""
    @State private var isApplyingSuggestion = false
    @FocusState private var isDestinationFocused: Bool

    var body: some View {
        Section {
            TextField("Destination", text: $destination)
                .textContentType(.fullStreetAddress)
                .submitLabel(.go)
                .focused($isDestinationFocused)
                .onChange(of: destination) { newValue in
                    if isApplyingSuggestion {
                        isApplyingSuggestion = false
                        return
                    }
                    destinationCompleter.search(query: newValue)
                }
                .onSubmit(startNavigation)

            if isDestinationFocused && !normalizedDestination.isEmpty {
                ForEach(Array(destinationCompleter.suggestions.prefix(5)), id: \.self) { suggestion in
                    Button {
                        isApplyingSuggestion = true
                        destination = formattedAddress(for: suggestion)
                        isDestinationFocused = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .foregroundColor(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: startNavigation) {
                Label("Start Test Navigation", systemImage: "testtube.2")
            }
            .disabled(!canStartNavigation)
        } header: {
            Text("Test Navigation")
        } footer: {
            Text(footerText)
        }
        .onAppear(perform: updateSearchRegion)
        .onChange(of: currentLocation) { _ in
            updateSearchRegion()
        }
    }

    private var normalizedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStartNavigation: Bool {
        currentLocation != nil && !normalizedDestination.isEmpty
    }

    private var footerText: String {
        if currentLocation == nil {
            return "Waiting for your current location. Test navigation starts from your live position."
        }
        return "Starts a simulated Bike route from your current location to this destination."
    }

    private func startNavigation() {
        guard canStartNavigation else { return }
        isDestinationFocused = false
        onStartNavigation(normalizedDestination)
    }

    private func formattedAddress(for suggestion: MKLocalSearchCompletion) -> String {
        suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
    }

    private func updateSearchRegion() {
        guard let currentLocation else { return }
        destinationCompleter.updateRegion(
            MKCoordinateRegion(
                center: currentLocation.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        )
    }
}

private struct DeveloperSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var offlineMapManager: OfflineMapManager
    @ObservedObject var firmwareUpdateManager: FirmwareUpdateManager
    let currentLocation: CLLocation?
    let onStartTestNavigation: (String) -> Void

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
            TestNavigationSettingsSection(
                currentLocation: currentLocation,
                onStartNavigation: onStartTestNavigation
            )

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

                NavigationLink {
                    BikeComputersSettingsView()
                } label: {
                    Label("Manage Bike Computers", systemImage: "bicycle")
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
        currentLocation: nil,
        offlineMapManager: OfflineMapManager(),
        firmwareUpdateManager: FirmwareUpdateManager(),
        onStartTestNavigation: { _ in }
    )
        .environmentObject(BLEManager())
}
