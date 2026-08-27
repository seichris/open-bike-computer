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
    @ObservedObject private var routeLibrary: PhoneRouteLibrary
    @ObservedObject private var stravaIntegrationCoordinator:
        StravaIntegrationCoordinator
    @ObservedObject private var watchAvailability:
        WorkoutWatchAvailabilityMonitor
    @ObservedObject private var cyclingSensorStore:
        CyclingSensorStore
    @ObservedObject private var cyclingSensorDetectionCoordinator:
        CyclingSensorDetectionCoordinator
    @ObservedObject private var rideDetectionSettingsStore:
        RideDetectionSettingsStore
    @ObservedObject private var rideDiagnosticsRecorder:
        RideDiagnosticsRecorder
    @FocusState private var focusedSavedMapFilename: String?
    let locationAuthorizationStatus: CLAuthorizationStatus
    let locationAccuracyAuthorization: CLAccuracyAuthorization
    let currentLocation: CLLocation?
    let isNavigationActive: Bool
    let onRequestLocationAuthorization: () -> Void
    let onStartTestNavigation: (String) -> Void

    init(
        locationAuthorizationStatus: CLAuthorizationStatus = .authorizedAlways,
        locationAccuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy,
        currentLocation: CLLocation?,
        isNavigationActive: Bool = false,
        offlineMapManager: OfflineMapManager,
        firmwareUpdateManager: FirmwareUpdateManager,
        routeLibrary: PhoneRouteLibrary,
        stravaIntegrationCoordinator: StravaIntegrationCoordinator? = nil,
        watchAvailability: WorkoutWatchAvailabilityMonitor,
        cyclingSensorStore: CyclingSensorStore? = nil,
        cyclingSensorDetectionCoordinator:
            CyclingSensorDetectionCoordinator? = nil,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil,
        rideDiagnosticsRecorder: RideDiagnosticsRecorder? = nil,
        onRequestLocationAuthorization: @escaping () -> Void = {},
        onStartTestNavigation: @escaping (String) -> Void
    ) {
        let cyclingSensorStore =
            cyclingSensorStore ?? CyclingSensorStore()
        self.locationAuthorizationStatus = locationAuthorizationStatus
        self.locationAccuracyAuthorization = locationAccuracyAuthorization
        self.currentLocation = currentLocation
        self.isNavigationActive = isNavigationActive
        self.onRequestLocationAuthorization = onRequestLocationAuthorization
        self.offlineMapManager = offlineMapManager
        self.firmwareUpdateManager = firmwareUpdateManager
        self.routeLibrary = routeLibrary
        self.stravaIntegrationCoordinator =
            stravaIntegrationCoordinator ?? StravaIntegrationCoordinator(
                client: StravaIntegrationClient(
                    serviceSession: BicinoServiceSession(),
                    expectedCallbackScheme: BicinoURLSchemeConfig.current
                ),
                routeLibrary: routeLibrary,
                callbackScheme: BicinoURLSchemeConfig.current
            )
        self.watchAvailability = watchAvailability
        _cyclingSensorStore = ObservedObject(
            wrappedValue: cyclingSensorStore
        )
        _cyclingSensorDetectionCoordinator = ObservedObject(
            wrappedValue: cyclingSensorDetectionCoordinator
                ?? CyclingSensorDetectionCoordinator(
                    sensorStore: cyclingSensorStore
                )
        )
        _rideDetectionSettingsStore = ObservedObject(
            wrappedValue:
                rideDetectionSettingsStore ?? RideDetectionSettingsStore()
        )
        _rideDiagnosticsRecorder = ObservedObject(
            wrappedValue: rideDiagnosticsRecorder ?? RideDiagnosticsRecorder()
        )
        self.onStartTestNavigation = onStartTestNavigation
    }

    var body: some View {
        NavigationView {
            Form {
                if shouldPromoteBikeComputerSettings {
                    Section {
                        bikeComputerSettingsLink
                    }
                }

                if !locationAuthorized {
                    Section {
                        Button(action: remediateLocationAuthorization) {
                            Label(
                                LocationAuthorizationRemediationPolicy
                                    .buttonTitle(
                                        for: locationAuthorizationStatus
                                    ) ?? "Location Access",
                                systemImage: "location"
                            )
                        }
                    } footer: {
                        Text("Location access is needed to download the map for your current area.")
                    }
                }

                MainFirmwareUpdateSection(manager: firmwareUpdateManager)
                if BikeComputerSettingsPresentationPolicy
                    .shouldShowDeviceScreens(
                        knownDeviceCount: bleManager.knownDevices.count
                    ) {
                    DeviceScreensSettingsSection(
                        offlineMapManager: offlineMapManager
                    )
                }
                SavedMapsSettingsSection(
                    manager: offlineMapManager,
                    focusedPackFilename: $focusedSavedMapFilename
                )
                if OfflineMapDownloadingSectionPresentation.isVisible(
                    isBusy: offlineMapManager.isBusy,
                    hasPendingJob: offlineMapManager.hasPendingMapJob,
                    hasPendingActivation: offlineMapManager.hasPendingDeviceActivation,
                    isServerRecoveryCheckPending: offlineMapManager.isServerRecoveryCheckPending,
                    hasCurrentJob: offlineMapManager.currentJob != nil,
                    hasDownloadedPack: offlineMapManager.downloadedPackURL != nil,
                    errorMessage: offlineMapManager.errorMessage
                ) {
                    DownloadingMapsSettingsSection(manager: offlineMapManager)
                }

                SavedRoutesSettingsSection(
                    routeLibrary: routeLibrary,
                    stravaCoordinator: stravaIntegrationCoordinator
                )

                Section {
                    if !shouldPromoteBikeComputerSettings {
                        bikeComputerSettingsLink
                    }

                    NavigationLink {
                        RideDetectionSettingsView(
                            store: rideDetectionSettingsStore,
                            authorizationStatus: locationAuthorizationStatus,
                            accuracyAuthorization:
                                locationAccuracyAuthorization,
                            currentLocation: currentLocation,
                            onRequestLocationAuthorization:
                                onRequestLocationAuthorization
                        )
                    } label: {
                        Label("Ride Detection", systemImage: "figure.outdoor.cycle")
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
                            watchAvailability: watchAvailability,
                            cyclingSensorStore: cyclingSensorStore,
                            cyclingSensorDetectionCoordinator:
                                cyclingSensorDetectionCoordinator,
                            currentLocation: currentLocation,
                            isNavigationActive: isNavigationActive,
                            onStartTestNavigation: { destination in
                                onStartTestNavigation(destination)
                                dismiss()
                            }
                        )
                    } label: {
                        Label("Developer Settings", systemImage: "wrench.and.screwdriver")
                    }

                    NavigationLink {
                        RideDiagnosticsSettingsView(
                            recorder: rideDiagnosticsRecorder
                        )
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }

                Section {
                    Link(destination: AppPrivacyPolicy.url) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if shouldPromoteBikeComputerSettings {
                    BicinoOneStoreHero()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: createdSharePresentation) { presentation in
            SavedMapShareSheet(url: presentation.url)
                .presentationDetents([.medium])
        }
    }

    private var createdSharePresentation:
        Binding<SavedMapSharePresentation?> {
        Binding(
            get: {
                offlineMapManager.createdShareURL.map {
                    SavedMapSharePresentation(url: $0)
                }
            },
            set: { presentation in
                if presentation == nil {
                    offlineMapManager.clearCreatedShareURL()
                }
            }
        )
    }

    private var shouldPromoteBikeComputerSettings: Bool {
        BikeComputerSettingsPresentationPolicy.shouldPromoteSettingsLink(
            knownDeviceCount: bleManager.knownDevices.count
        )
    }

    private var bikeComputerSettingsLink: some View {
        NavigationLink {
            BikeComputersSettingsView(
                sensorStore: cyclingSensorStore,
                sensorDetectionCoordinator:
                    cyclingSensorDetectionCoordinator
            )
        } label: {
            Label(
                BikeComputerSettingsPresentationPolicy.settingsLinkTitle(
                    knownDeviceCount: bleManager.knownDevices.count
                ),
                systemImage: "bicycle"
            )
        }
    }

    private var locationAuthorized: Bool {
        locationAuthorizationStatus == .authorizedAlways ||
            locationAuthorizationStatus == .authorizedWhenInUse
    }

    private func remediateLocationAuthorization() {
        switch LocationAuthorizationRemediationPolicy.action(
            for: locationAuthorizationStatus
        ) {
        case .requestInApp:
            onRequestLocationAuthorization()
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            openURL(url)
        case .none:
            break
        }
    }
}

private struct BicinoOneStoreHero: View {
    private static let storeURL = URL(string: "https://bicino.com")!

    var body: some View {
        Link(destination: Self.storeURL) {
            VStack(alignment: .leading, spacing: 0) {
                Image("BicinoOneSettingsPromo")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Get your Bicino One")
                        .font(.headline)

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Get your Bicino One")
        .accessibilityHint("Opens bicino.com")
    }
}

private struct RideDetectionSettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var store: RideDetectionSettingsStore
    let authorizationStatus: CLAuthorizationStatus
    let accuracyAuthorization: CLAccuracyAuthorization
    let currentLocation: CLLocation?
    let onRequestLocationAuthorization: () -> Void
    @State private var showAutomaticStartWarning = false
    @State private var showLocationUseWarning = false

    var body: some View {
        Form {
            Section {
                Picker(
                    "Detect Ride Start",
                    selection: Binding(
                        get: { store.settings.startMode },
                        set: { value in
                            if value == .automatic {
                                showAutomaticStartWarning = true
                            } else {
                                store.setStartMode(value)
                            }
                        }
                    )
                ) {
                    Text("Off").tag(RideStartMode.off)
                    Text("Ask to Start").tag(RideStartMode.ask)
                    if RideAutomationRollout.allowsAutomaticStart {
                        Text("Start Automatically")
                            .tag(RideStartMode.automatic)
                    }
                }
                .pickerStyle(.inline)
                .alert(
                    "Start Workouts Automatically?",
                    isPresented: $showAutomaticStartWarning
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable Automatic Start") {
                        store.setStartMode(.automatic)
                    }
                } message: {
                    Text(
                        "A detected ride can start an Outdoor Cycling "
                        + "workout on Apple Watch without another prompt. "
                        + "Manual controls always take precedence."
                    )
                }

                if store.settings.startMode != .off &&
                    !store.hasAcknowledgedLocationUse {
                    Button("Use iPhone GPS for Detection") {
                        showLocationUseWarning = true
                    }
                    .alert(
                        "Use iPhone GPS for Ride Detection?",
                        isPresented: $showLocationUseWarning
                    ) {
                        Button("Continue") {
                            store.acknowledgeLocationUse()
                            if authorizationStatus == .notDetermined {
                                onRequestLocationAuthorization()
                            }
                        }
                    } message: {
                        Text(
                            "When Ride Start is enabled and your bike "
                            + "computer is connected, Bicino keeps precise "
                            + "location active in the background so GPS and "
                            + "motion can detect a ride. You can turn Ride "
                            + "Start off at any time."
                        )
                    }
                }

                if store.settings.startMode != .off &&
                    rideDetectionLocationStatus == .permissionNeeded {
                    Button {
                        if authorizationStatus == .notDetermined {
                            onRequestLocationAuthorization()
                        } else {
                            openApplicationSettings()
                        }
                    } label: {
                        Label(
                            LocationAuthorizationRemediationPolicy
                                .buttonTitle(for: authorizationStatus)
                                ?? "Location Access",
                            systemImage: "location"
                        )
                    }
                }

                if store.settings.startMode != .off &&
                    rideDetectionLocationStatus == .foregroundOnly {
                    Button("Allow Background Location") {
                        openApplicationSettings()
                    }
                }

                if store.settings.startMode != .off &&
                    accuracyAuthorization == .reducedAccuracy {
                    Button("Enable Precise Location") {
                        openApplicationSettings()
                    }
                }
            } header: {
                Text("Detect Ride Start")
            } footer: {
                Text(rideDetectionFooterText)
            }

            Section("iPhone GPS") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let status = rideDetectionLocationStatus(at: context.date)
                    LabeledContent("Status", value: status.label)
                    Text(rideDetectionLocationStatusDetail(status))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(
                    "Auto-Pause",
                    isOn: Binding(
                        get: { store.settings.autoPauseEnabled },
                        set: store.setAutoPauseEnabled
                    )
                )
            } footer: {
                Text(
                    "Stops and resumes the existing Watch-owned Outdoor "
                    + "Cycling workout. A manually paused ride is never "
                    + "resumed automatically."
                )
            }

            Section("Start Alerts") {
                Picker(
                    "Start Alerts",
                    selection: Binding(
                        get: { store.settings.alertMode },
                        set: store.setAlertMode
                    )
                ) {
                    Text("Sound + Haptic").tag(UInt8(0))
                    Text("Haptic Only").tag(UInt8(1))
                    Text("Visual Only").tag(UInt8(2))
                }
            }
        }
        .navigationTitle("Ride Detection")
    }

    private var rideDetectionFooterText: String {
        if RideAutomationRollout.allowsAutomaticStart {
            return "Ride detection uses iPhone GPS in the background while "
                + "the compatible bike computer is connected. Automatic "
                + "start requires a separate opt-in and the bike "
                + "computer, iPhone, and Apple Watch to be reachable."
        }
        return "Ride detection uses iPhone GPS in the background while the "
            + "compatible bike computer is connected. Ask to Start is the "
            + "current rollout ceiling. Automatic start "
            + "remains gated until the physical false-start validation is "
            + "complete."
    }

    private var rideDetectionLocationStatus: RideDetectionLocationStatus {
        rideDetectionLocationStatus(at: Date())
    }

    private func rideDetectionLocationStatus(
        at now: Date
    ) -> RideDetectionLocationStatus {
        RideDetectionLocationStatusResolver.resolve(
            startMode: store.settings.startMode,
            locationUseAcknowledged: store.hasAcknowledgedLocationUse,
            isNavigationReady: bleManager.isNavigationReady,
            supportsRideAutomation: bleManager.supportsRideAutomation,
            supportsGPSPositionQualityV1:
                bleManager.supportsGPSPositionQualityV1,
            authorizationLevel: locationAuthorizationLevel,
            accuracyAuthorization: accuracyAuthorization,
            location: currentLocation,
            now: now
        )
    }

    private func rideDetectionLocationStatusDetail(
        _ status: RideDetectionLocationStatus
    ) -> String {
        switch status {
        case .disabled:
            "Enable Ride Start and confirm iPhone GPS use to arm detection."
        case .waitingForCompatibleDevice:
            "Connect a bike computer that supports ride detection and GPS quality."
        case .permissionNeeded:
            "Location permission is required before iPhone GPS can be used."
        case .foregroundOnly:
            "Detection works while Bicino is open. Allow Always access for reliable background detection."
        case .waitingForPreciseLocation:
            "Waiting for a fresh precise fix with measured cycling speed."
        case .sending:
            "Fresh iPhone GPS and quality are being sent to the connected bike computer."
        case .stale:
            "The last fix is too old for detection; the device will fail closed until GPS refreshes."
        }
    }

    private var locationAuthorizationLevel: LocationAuthorizationLevel {
        switch authorizationStatus {
        case .authorizedAlways:
            .always
        case .authorizedWhenInUse:
            .whenInUse
        case .notDetermined, .restricted, .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    private func openApplicationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
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
                .disabled(
                    !SavedMapDeviceTransferPolicy.canStart(
                        isDeviceTransferBusy: manager.isDeviceTransferBusy,
                        hasActiveBackgroundUpload: manager.hasActiveBackgroundUpload,
                        isPausedUpload: true,
                        isNavigationReady: bleManager.isNavigationReady
                    )
                )
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
                StatusValueRow(
                    status: manager.statusMessage,
                    isBusy: manager.isBusy && manager.downloadByteProgress == nil
                )
            } else if manager.hasPendingDeviceActivation {
                StatusValueRow(status: "Checking device activation", isBusy: false)
            }

            if let downloadProgress = manager.downloadByteProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Download Progress")
                        Spacer()
                        Text("\(downloadProgress.percentage)%")
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: downloadProgress.fraction)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Map download \(downloadProgress.percentage) percent")
            }

            if let overallGenerationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Overall Generation")
                        Spacer()
                        if let percentage = overallGenerationProgress.percentage {
                            Text("\(percentage)%")
                                .foregroundColor(.secondary)
                        }
                    }
                    if let fraction = overallGenerationProgress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(overallGenerationProgress.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let generationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Generation Progress")
                        Spacer()
                        if generationProgress.displayFraction != nil {
                            Text("\(generationProgress.percentage)%")
                                .foregroundColor(.secondary)
                        }
                    }
                    if let fraction = generationProgress.displayFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(generationProgress.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let sourceSummary {
                SettingsValueRow(title: "Source", value: sourceSummary)
            }

            if let preparationEstimatePresentation {
                SettingsValueRow(
                    title: preparationEstimatePresentation.title,
                    value: preparationEstimatePresentation.value
                )
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if manager.isMapJobProcessing, manager.hasPendingMapJob {
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

    private var preparationEstimatePresentation:
        OfflineMapPreparationEstimatePresentation? {
        guard let job = manager.currentJob else { return nil }
        return OfflineMapPreparationEstimatePresentation.presentation(for: job)
    }

    private var generationProgress: OfflineMapJobProgress? {
        guard manager.currentJob?.status == "converting_features" else { return nil }
        return manager.currentJob?.progress
    }

    private var overallGenerationProgress: OfflineMapBuildingProgress? {
        guard manager.currentJob?.status == "converting_features" else { return nil }
        return manager.currentJob?.buildingProgress
    }
}

private struct MapLibrarySettingsView: View {
    @ObservedObject var manager: OfflineMapManager
    @State private var linkCodeDraft = ""
    @State private var pendingRevocation: OfflineMapCatalogShare?

    var body: some View {
        Form {
            Section {
                if let code = manager.libraryLinkCode {
                    LabeledContent("One-time code") {
                        Text(code.code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = code.code
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                }

                Button {
                    manager.createLibraryLinkCode()
                } label: {
                    Label("Create Link Code", systemImage: "link.badge.plus")
                }
                .disabled(manager.isBusy)

                TextField("ABCD-EFGH", text: $linkCodeDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                Button {
                    manager.claimLibraryLinkCode(linkCodeDraft)
                    linkCodeDraft = ""
                } label: {
                    Label("Link This App", systemImage: "link")
                }
                .disabled(manager.isBusy || !isValidLinkCode)
            } header: {
                Text("Link Bicino Apps")
            } footer: {
                Text(
                    "Normally both apps use the same private Cloudflare map library " +
                        "credential from the shared Keychain. If they do not, create " +
                        "a code in the app whose library you want to keep, then enter " +
                        "it in the other app within 10 minutes."
                )
            }

            Section {
                if manager.catalogShares.isEmpty {
                    Text("No map links have been shared yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.catalogShares) { share in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(share.title)
                                Spacer()
                                Text(share.isActive ? "Active" : "Revoked")
                                    .font(.caption)
                                    .foregroundColor(
                                        share.isActive ? .green : .secondary
                                    )
                            }
                            Text(
                                share.claimCount == 1
                                    ? "Added by 1 library"
                                    : "Added by \(share.claimCount) libraries"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            if share.isActive {
                                Button("Revoke Link", role: .destructive) {
                                    pendingRevocation = share
                                }
                                .disabled(manager.isBusy)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Shared Links")
            } footer: {
                Text(
                    "Revoking prevents new previews and additions. Friends who " +
                        "already added the map keep their copy."
                )
            }

            if let error = manager.errorMessage, !error.isEmpty {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Map Library")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            manager.refreshCatalogShares()
        }
        .alert(item: $pendingRevocation) { share in
            Alert(
                title: Text("Revoke Map Link?"),
                message: Text(
                    "People who have not already added \(share.title) will no " +
                        "longer be able to use this link."
                ),
                primaryButton: .destructive(Text("Revoke")) {
                    manager.revokeCatalogShare(share)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var isValidLinkCode: Bool {
        linkCodeDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .range(
                of: "^[A-Z0-9_-]{4}-[A-Z0-9_-]{4}$",
                options: .regularExpression
            ) != nil
    }
}

private struct SavedMapsSettingsSection: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    @FocusState.Binding var focusedPackFilename: String?
    @State private var renameInteraction = SavedMapRenameInteraction()

    var body: some View {
        let savedMaps = manager.savedMapListItems(
            activeDeviceMap: bleManager.activeDeviceMap
        )
        Section(header: Text("Saved Maps")) {
            if savedMaps.isEmpty {
                Text("No offline maps yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedMaps) { item in
                    SavedMapRow(
                        manager: manager,
                        item: item,
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
            manager.updateActiveDeviceMap(bleManager.activeDeviceMap)
            manager.reconcileLastTransfer(bleManager: bleManager)
            if bleManager.isNavigationReady {
                bleManager.requestMapTransferStatus()
            }
        }
        .onChange(of: bleManager.isNavigationReady) { isReady in
            if isReady {
                bleManager.requestMapTransferStatus()
            }
        }
        .onChange(of: bleManager.activeDeviceMap) { descriptor in
            manager.updateActiveDeviceMap(descriptor)
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

private struct SavedMapSharePresentation: Identifiable {
    let url: URL

    var id: URL { url }
}

private struct SavedMapShareSheet: View {
    let url: URL

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.accentColor)
                Text(
                    "Your friend can open this link in Bicino, preview the map, " +
                        "and choose whether to add it."
                )
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                ShareLink(item: url) {
                    Label("Share Map Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("Share Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SavedMapRow: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var manager: OfflineMapManager
    let item: SavedMapListItem
    @FocusState.Binding var focusedPackFilename: String?
    @Binding var renameInteraction: SavedMapRenameInteraction
    let onCommitRename: (SavedMapRenameCommit) -> Void
    @State private var isShowingInstalledConfirmation = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingLibraryRemovalConfirmation = false
    @State private var presentedPreview: SavedMapPreviewPresentation?
    @State private var isShowingCatalogRename = false
    @State private var catalogRenameDraft = ""

    var body: some View {
        let displayName = item.displayName
        let packURL = item.packURL
        let isPausedUpload = packURL.map(manager.isPausedMapUpload) ?? false
        let isAwaitingActivation = packURL.map(
            manager.isAwaitingMapActivationConfirmation
        ) ?? false
        let previewImage = manager.previewImage(for: item)
        let catalogAvailability = item.catalogMap.map(manager.catalogAvailability(for:))
        let catalogArtifactNeedsRefresh = manager.catalogArtifactNeedsRefresh(for: item)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    guard let previewImage else { return }
                    finishRenaming()
                    focusedPackFilename = nil
                    presentedPreview = SavedMapPreviewPresentation(
                        displayName: displayName,
                        image: previewImage
                    )
                } label: {
                    SavedMapThumbnail(image: previewImage)
                }
                .buttonStyle(.plain)
                .disabled(previewImage == nil)
                .accessibilityLabel("Show preview for \(displayName)")
                .accessibilityHint(
                    previewImage == nil
                        ? "Preview is loading"
                        : "Opens the map preview"
                )
                .task(id: item.id) {
                    manager.loadPreviewIfNeeded(for: item)
                }

                if let packURL,
                   renameInteraction.editingFilename == packURL.lastPathComponent {
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
                } else if let packURL {
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
                } else {
                    Button {
                        catalogRenameDraft = displayName
                        isShowingCatalogRename = true
                    } label: {
                        Text(displayName)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(displayName)")
                    .layoutPriority(1)
                }

                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedPackFilename = nil
                    }

                if item.isActiveOnDevice {
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
                    .accessibilityLabel("\(displayName) is active on the Bike Computer")
                    .accessibilityHint(
                        item.isOnIPhone
                            ? "Shows the installed map status"
                            : "This map is not saved on this iPhone"
                    )
                } else if isAwaitingActivation {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel(
                            "Waiting for the Bike Computer to confirm \(displayName)"
                        )
                } else if catalogArtifactNeedsRefresh,
                          let catalogMap = item.catalogMap {
                    Button {
                        finishRenaming()
                        focusedPackFilename = nil
                        manager.downloadCatalogMap(catalogMap)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        manager.isBusy ||
                            manager.isDeviceTransferBusy ||
                            manager.hasActiveBackgroundUpload ||
                            isPausedUpload ||
                            catalogAvailability?.canDownload != true
                    )
                    .accessibilityLabel("Update \(displayName) on this iPhone")
                    .accessibilityHint("Downloads the current compatible map artifact")
                } else if let packURL {
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
                        !SavedMapDeviceTransferPolicy.canStart(
                            isDeviceTransferBusy: manager.isDeviceTransferBusy,
                            hasActiveBackgroundUpload: manager.hasActiveBackgroundUpload,
                            isPausedUpload: isPausedUpload,
                            isNavigationReady: bleManager.isNavigationReady
                        )
                    )
                    .accessibilityLabel(
                        isPausedUpload
                            ? "Resume transferring \(displayName) to device"
                            : "Transfer \(displayName) to device"
                    )
                } else if let catalogMap = item.catalogMap {
                    Button {
                        finishRenaming()
                        focusedPackFilename = nil
                        manager.downloadCatalogMap(catalogMap)
                    } label: {
                        Image(
                            systemName: catalogAvailability?.canDownload == true
                                ? "arrow.down.circle"
                                : "clock.badge.exclamationmark"
                        )
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        manager.isBusy || catalogAvailability?.canDownload != true
                    )
                    .accessibilityLabel("Download \(displayName) to this iPhone")
                    .accessibilityHint(
                        catalogAvailability?.statusText ?? "Downloads this saved map"
                    )
                }

                if item.isAvailableInLibrary {
                    Button {
                        finishRenaming()
                        focusedPackFilename = nil
                        manager.createShare(for: item)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.isBusy)
                    .accessibilityLabel("Share \(displayName)")
                }

                if packURL != nil {
                    Button(role: .destructive) {
                        finishRenaming()
                        focusedPackFilename = nil
                        isShowingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.isBusy || manager.hasActiveBackgroundUpload)
                    .accessibilityLabel("Delete \(displayName)")
                } else {
                    Color.clear
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
            }

            if let status = catalogAvailability?.statusText {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(displayName): \(status)")
            }

            if catalogArtifactNeedsRefresh {
                Label("Updated map available", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(displayName): Updated map available")
            }

            if let mapEntryID = item.catalogMap?.mapEntryId,
               let aliasStatus = manager.catalogAliasStatus(for: mapEntryID) {
                Label(aliasStatus, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(displayName): \(aliasStatus)")
            }

            if item.canRemoveFromMapLibrary {
                Button("Remove from Map Library", role: .destructive) {
                    finishRenaming()
                    focusedPackFilename = nil
                    isShowingLibraryRemovalConfirmation = true
                }
                .disabled(manager.isBusy)
                .accessibilityHint("Removes only this app library's cloud reference")
            }
        }
        .alert("Already on Device", isPresented: $isShowingInstalledConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This map is already installed on the device.")
        }
        .alert("Rename Map", isPresented: $isShowingCatalogRename) {
            TextField("Map name", text: $catalogRenameDraft)
            Button("Save") {
                if let map = item.catalogMap {
                    _ = manager.renameCatalogMap(map, to: catalogRenameDraft)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This private name is shared between Bicino and Bicino Dev.")
        }
        .confirmationDialog(
            "Delete Saved Map?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let packURL {
                    manager.deleteCachedPack(at: packURL)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                SavedMapRemovalPolicy.localDeletionMessage(
                    displayName: displayName,
                    libraryCopyRemains: item.hasKnownMapLibraryCopy
                )
            )
        }
        .confirmationDialog(
            "Remove from Map Library?",
            isPresented: $isShowingLibraryRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Map Library", role: .destructive) {
                if let map = item.catalogMap {
                    manager.removeCatalogMapFromLibrary(map)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                SavedMapRemovalPolicy.libraryRemovalMessage(
                    displayName: displayName
                )
            )
        }
        .sheet(item: $presentedPreview) { preview in
            SavedMapPreviewSheet(preview: preview)
                .presentationDetents([.large])
        }
    }

    private func finishRenaming() {
        if let commit = renameInteraction.finish() {
            onCommitRename(commit)
        }
    }
}

private struct SavedMapPreviewPresentation: Identifiable {
    let id = UUID()
    let displayName: String
    let image: UIImage
}

private struct SavedMapPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: SavedMapPreviewPresentation

    var body: some View {
        NavigationView {
            Image(uiImage: preview.image)
                .resizable()
                .scaledToFit()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle(preview.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
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
    let offlineMapManager: OfflineMapManager

    var body: some View {
        Section(
            header: Text("Device Screens"),
            footer: Text(mapStyleFooter)
        ) {
            ForEach(bleManager.availableDeviceScreens) { screen in
                HStack(spacing: 4) {
                    Text(screen.title)

                    if let styleScreen = mapStyleScreen(for: screen) {
                        NavigationLink {
                            MapStyleSettingsView(
                                screen: styleScreen,
                                offlineMapManager: offlineMapManager
                            )
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(
                                    width: 44,
                                    height: 44,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            mapStyleAccessibilityLabel(for: screen)
                        )
                    }

                    Spacer()

                    Toggle(
                        screen.title,
                        isOn: Binding(
                            get: {
                                bleManager.isDeviceScreenEnabled(screen)
                            },
                            set: {
                                bleManager.setDeviceScreen(
                                    screen,
                                    enabled: $0
                                )
                            }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("\(screen.title) screen")
                    .disabled(bleManager.isOnlyEnabledDeviceScreen(screen))
                }
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

    private var mapStyleFooter: String {
        if !bleManager.hasReceivedDeviceCapabilities {
            return "Checking whether the connected firmware supports independent map styles."
        }
        if bleManager.supportsIndependentMapProfiles {
            return "Use the gear buttons to configure Map and Map + Navigation independently."
        }
        return "This firmware uses one shared style for Map and Map + Navigation. Either gear opens the shared Map Screens settings."
    }

    private func mapStyleAccessibilityLabel(for screen: DeviceScreen) -> String {
        if !bleManager.supportsIndependentMapProfiles {
            return "Shared Map Screens UI settings, affects Map and Map + Navigation"
        }
        return "\(screen.title) UI settings"
    }

    private func mapStyleScreen(for screen: DeviceScreen) -> MapStyleScreen? {
        switch screen {
        case .map:
            return .map
        case .mapPlusNavigation:
            return bleManager.supportsIndependentMapProfiles
                ? .mapPlusNavigation
                : .map
        case .navigation, .rideStats, .batteryStatus:
            return nil
        }
    }
}

private struct NavigationOverlaysSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        Section {
            Toggle("Route Line", isOn: $bleManager.showRouteOverlay)
                .onChange(of: bleManager.showRouteOverlay) { _ in
                    bleManager.sendVisibilityMask()
                }
            Toggle("Current Position", isOn: $bleManager.showCurrentPosition)
                .onChange(of: bleManager.showCurrentPosition) { _ in
                    bleManager.sendVisibilityMask()
                }
        } header: {
            Text("Navigation Overlays")
        } footer: {
            Text(
                "Show or hide live navigation layers drawn above both map screens."
            )
        }
        .disabled(!bleManager.supportsDeviceSettings)
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
    @ObservedObject var offlineMapManager: OfflineMapManager

    private var labelsAvailable: Bool {
        (bleManager.activeMapRendererFormat ?? 0) >= 2 &&
            bleManager.activeMapLabelProfileVersion == 1 &&
            bleManager.activeMapFontAssetHealthy
    }

    private var preferredLanguageName: String {
        guard let tag = bleManager.activeMapLabelLanguages.first else {
            return "map language"
        }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    private var labelLanguagesNeedUpdate: Bool {
        labelsAvailable &&
            bleManager.activeMapLabelLanguages !=
                OfflineMapJobRequest.preferredLabelLanguages
    }

    private var streetLabelsFooter: String {
        if (bleManager.activeMapRendererFormat ?? 0) < 2 {
            return "Download this map again to add street names."
        }
        if !bleManager.activeMapFontAssetHealthy {
            return "This map's street-name font asset is unavailable. Download the map again to repair it."
        }
        if labelLanguagesNeedUpdate {
            return "Your iPhone language preferences changed after this map was built. Update the map to use the current language list."
        }
        if !labelsEnabled.wrappedValue {
            return "Street names are hidden on this screen."
        }
        return "Follow Roads and Keep Upright are rendered on the device and apply immediately. Changing the iPhone language list may require updating map languages."
    }

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

    private var streetLineWidth: Binding<Double> {
        binding(map: \.streetLineWidth, mapPlusNavigation: \.mapPlusNavigationStreetLineWidth)
    }

    private var positionMarkerScale: Binding<Double> {
        binding(map: \.positionMarkerScale, mapPlusNavigation: \.mapPlusNavigationPositionMarkerScale)
    }

    private var zoomLevel: Binding<Int> {
        binding(map: \.zoomLevel, mapPlusNavigation: \.mapPlusNavigationZoomLevel)
    }

    private var labelDensity: Binding<Int> {
        binding(map: \.mapLabelDensity,
                mapPlusNavigation: \.mapPlusNavigationLabelDensity)
    }

    private var labelsEnabled: Binding<Bool> {
        binding(map: \.mapLabelsEnabled,
                mapPlusNavigation: \.mapPlusNavigationLabelsEnabled)
    }

    private var labelLanguageMode: Binding<Int> {
        binding(map: \.mapLabelLanguageMode,
                mapPlusNavigation: \.mapPlusNavigationLabelLanguageMode)
    }

    private var labelTextSize: Binding<Int> {
        binding(map: \.mapLabelTextSize,
                mapPlusNavigation: \.mapPlusNavigationLabelTextSize)
    }

    private var labelOrientation: Binding<Int> {
        binding(map: \.mapLabelOrientation,
                mapPlusNavigation: \.mapPlusNavigationLabelOrientation)
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

    private var birdsEyeFooter: String {
        if !bleManager.hasReceivedDeviceCapabilities {
            return "Connect to the Bike Computer to check bird's-eye view support."
        }
        if !bleManager.supportsBirdsEyeMapNavigation {
            return "Update the Bike Computer firmware to enable bird's-eye view."
        }
        if !bleManager.supportsBirdsEyeMapNavigationPerspective {
            return "Tilts the Map + Navigation screen. Update the Bike Computer firmware to adjust the perspective."
        }
        if !bleManager.supportsBirdsEyeMapNavigationStrongerPerspective {
            return "Choose how strongly Map + Navigation tilts. Update the Bike Computer firmware for Very Strong and Maximum."
        }
        return "Choose how strongly Map + Navigation tilts. The ordinary Map screen stays flat."
    }

    private var birdsEyePerspectiveOptions: [MapNavigationBirdsEyePerspective] {
        bleManager.supportsBirdsEyeMapNavigationStrongerPerspective
            ? MapNavigationBirdsEyePerspective.allCases
            : MapNavigationBirdsEyePerspective.baselineCases
    }

    private var birdsEyePerspectiveSelection: Binding<MapNavigationBirdsEyePerspective> {
        Binding(
            get: {
                bleManager.mapPlusNavigationBirdsEyePerspective.supportedValue(
                    supportsStrongerPerspectives:
                        bleManager.supportsBirdsEyeMapNavigationStrongerPerspective
                )
            },
            set: { bleManager.mapPlusNavigationBirdsEyePerspective = $0 }
        )
    }

    var body: some View {
        Form {
            if screen == .map {
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
            }

            if screen == .mapPlusNavigation {
                Section(header: Text("View"), footer: Text(birdsEyeFooter)) {
                    Toggle(
                        "Bird's-Eye View",
                        isOn: $bleManager.mapPlusNavigationBirdsEyeViewEnabled
                    )
                    .onChange(
                        of: bleManager.mapPlusNavigationBirdsEyeViewEnabled
                    ) { enabled in
                        bleManager.sendSetting(
                            id: DeviceBLEProtocol.mapPlusNavigationBirdsEyeViewSettingID,
                            value: enabled ? 1 : 0
                        )
                    }
                    .disabled(
                        !bleManager.hasReceivedDeviceCapabilities ||
                            !bleManager.supportsBirdsEyeMapNavigation
                    )

                    if bleManager.supportsBirdsEyeMapNavigationPerspective {
                        Picker(
                            "Perspective",
                            selection: birdsEyePerspectiveSelection
                        ) {
                            ForEach(birdsEyePerspectiveOptions) { perspective in
                                Text(perspective.title).tag(perspective)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(
                            of: bleManager.mapPlusNavigationBirdsEyePerspective
                        ) { perspective in
                            bleManager.sendSetting(
                                id: DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID,
                                value: Int32(perspective.rawValue)
                            )
                        }
                        .disabled(!bleManager.mapPlusNavigationBirdsEyeViewEnabled)
                    }

                    if bleManager.supports3DBuildings {
                        Toggle(
                            "3D Buildings",
                            isOn: $bleManager.mapPlusNavigation3DBuildingsEnabled
                        )
                        .onChange(
                            of: bleManager.mapPlusNavigation3DBuildingsEnabled
                        ) { enabled in
                            bleManager.sendSetting(
                                id: DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID,
                                value: enabled ? 1 : 0
                            )
                        }
                        .disabled(!bleManager.mapPlusNavigationBirdsEyeViewEnabled)
                    }
                }
            }

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

            if bleManager.supportsStreetLabels {
                Section(
                    header: Text("Street Labels"),
                    footer: Text(streetLabelsFooter)
                ) {
                    Toggle("Show Street Labels", isOn: labelsEnabled)
                        .onChange(of: labelsEnabled.wrappedValue) { _ in
                            bleManager.sendStreetLabelDensity(
                                for: screen.deviceScreen
                            )
                        }
                        .disabled(!labelsAvailable)

                    Group {
                        Picker("Density", selection: labelDensity) {
                            Text("Major Roads").tag(1)
                            Text("Balanced").tag(2)
                            Text("All Roads").tag(3)
                        }
                        .onChange(of: labelDensity.wrappedValue) { _ in
                            bleManager.sendStreetLabelDensity(
                                for: screen.deviceScreen
                            )
                        }

                        Picker("Language", selection: labelLanguageMode) {
                            Text("Local").tag(0)
                            Text("Preferred — \(preferredLanguageName)").tag(1)
                            Text("Local + Preferred").tag(2)
                        }
                        .onChange(of: labelLanguageMode.wrappedValue) { newValue in
                            sendSetting(
                                mapID: DeviceBLEProtocol.mapLabelLanguageModeSettingID,
                                mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationLabelLanguageModeSettingID,
                                value: Int32(newValue)
                            )
                        }

                        Picker("Text Size", selection: labelTextSize) {
                            Text("Small").tag(0)
                            Text("Standard").tag(1)
                            Text("Large").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: labelTextSize.wrappedValue) { newValue in
                            sendSetting(
                                mapID: DeviceBLEProtocol.mapLabelTextSizeSettingID,
                                mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationLabelTextSizeSettingID,
                                value: Int32(newValue)
                            )
                        }

                        Picker("Orientation", selection: labelOrientation) {
                            Text("Follow Roads").tag(0)
                            Text("Keep Upright").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: labelOrientation.wrappedValue) { newValue in
                            sendSetting(
                                mapID: DeviceBLEProtocol.mapLabelOrientationSettingID,
                                mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID,
                                value: Int32(newValue)
                            )
                        }
                    }
                    .disabled(!labelsAvailable || !labelsEnabled.wrappedValue)
                    if !labelsAvailable || labelLanguagesNeedUpdate {
                        Button(labelLanguagesNeedUpdate
                               ? "Update Map Languages"
                               : "Download Active Map Again") {
                        offlineMapManager.regenerateActiveMap(
                            bleManager: bleManager
                        )
                        }
                        .disabled(offlineMapManager.isBusy ||
                                  bleManager.mapTransferActiveMapId.isEmpty)
                    }
                }
            }

            Section(header: Text("Line Thickness")) {
                settingSlider(title: "Route Line Width", value: routeLineWidth, range: 2...48, prefix: "", suffix: " px") { newValue in
                    sendSetting(mapID: 3, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID, value: Int32(newValue))
                }
                settingSlider(title: "Street Width", value: streetLineWidth, range: 1...24, prefix: "", suffix: " px") { newValue in
                    sendSetting(mapID: 9, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID, value: Int32(newValue))
                }
                settingSlider(title: "Position Marker Size", value: positionMarkerScale, range: 1...5, prefix: "", suffix: "x") { newValue in
                    sendSetting(mapID: 10, mapPlusNavigationID: DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID, value: Int32(newValue))
                }
            }

            Section(header: Text("Zoom Level"), footer: Text("0 = Closest, 5 = Farthest")) {
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
            Section(
                header: Text("Device Brightness"),
                footer: Text("When enabled, the display dims after 15 seconds and turns off after 45 seconds unless navigation, workout, transfer, or attention activity is active.")
            ) {
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

                Toggle("Automatic Display Off", isOn: $bleManager.automaticDisplayOffEnabled)
                    .onChange(of: bleManager.automaticDisplayOffEnabled) { newValue in
                        bleManager.sendSetting(
                            id: DeviceBLEProtocol.automaticDisplayOffSettingID,
                            value: newValue ? 1 : 0
                        )
                    }
                    .disabled(!bleManager.supportsAutomaticDisplayOff)
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

@MainActor
private struct DiagnosticsTransferNetworkSettingsSection: View {
    @State private var ssid = ""
    @State private var password = ""
    @State private var loaded = false
    @State private var statusMessage: String?
    private let credentialStore = RemoteDebugLANCredentialStore()

    var body: some View {
        Section {
            TextField("Wi-Fi name (SSID)", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Wi-Fi password", text: $password)
                .textContentType(.password)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(action: save) {
                Label("Save Trusted Wi-Fi", systemImage: "key.fill")
            }
            .disabled(credentials == nil)
            Button(role: .destructive, action: forget) {
                Label("Forget Trusted Wi-Fi", systemImage: "trash")
            }
            .disabled(ssid.isEmpty && password.isEmpty)
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics Transfer Network")
        } footer: {
            Text("Authenticated device-log transfers try this trusted 2.4 GHz Wi-Fi first. Credentials stay in this iPhone's device-only Keychain and are sent to Bicino over authenticated BLE for the current session only. A per-session WPA2 device hotspot remains the fallback.")
        }
        .onAppear(perform: loadIfNeeded)
    }

    private var credentials: RemoteDebugLANCredentials? {
        RemoteDebugLANCredentials(ssid: ssid, password: password)
    }

    private var validationMessage: String? {
        if ssid.isEmpty {
            return password.isEmpty ? nil : "Enter the Wi-Fi name."
        }
        guard credentials == nil else { return nil }
        return "SSID must be at most 32 bytes; password must be empty for an open network or 8-63 bytes."
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let saved = credentialStore.load() else { return }
        ssid = saved.ssid
        password = saved.password
    }

    private func save() {
        guard let credentials else {
            statusMessage = validationMessage ?? "Enter valid Wi-Fi credentials."
            return
        }
        statusMessage = credentialStore.save(credentials)
            ? "Trusted Wi-Fi saved."
            : "Trusted Wi-Fi could not be saved to Keychain."
    }

    private func forget() {
        guard credentialStore.remove() else {
            statusMessage = "Trusted Wi-Fi could not be removed from Keychain."
            return
        }
        ssid = ""
        password = ""
        statusMessage = "Trusted Wi-Fi forgotten."
    }
}

#if DEBUG
@MainActor
private struct RemoteDeviceDebugSettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @AppStorage("remoteDebug.preferLAN.v1") private var preferLAN = true
    @State private var isWorking = false
    @State private var statusMessage = "Idle"
    @State private var errorMessage: String?
    @State private var copiedBrowserURL: String?
    @State private var copiedHotspotPassphrase: String?
    @State private var revealsHotspotPassphrase = false
    @State private var lanSSID = ""
    @State private var lanPassword = ""
    @State private var loadedLANCredentials = false
    private let credentialStore = RemoteDebugLANCredentialStore()

    var body: some View {
        Section {
            SettingsValueRow(title: "Status", value: sessionStatus)
            SettingsValueRow(
                title: "Target",
                value: bleManager.firmwareTarget.isEmpty
                    ? (bleManager.hardwareLabel.isEmpty ? "Unknown" : bleManager.hardwareLabel)
                    : bleManager.firmwareTarget
            )
            if let session = activeSession {
                SettingsValueRow(
                    title: "Connection",
                    value: connectionLabel(for: session)
                )
                if let reason = session.hotspotFallbackReason {
                    SettingsValueRow(
                        title: "Fallback Reason",
                        value: fallbackReasonLabel(reason)
                    )
                }
                SettingsValueRow(
                    title: "SSID",
                    value: session.networkSSID ??
                        session.accessPointSSID ?? "Not provided"
                )
                if let passphrase = session.accessPointPassphrase,
                   !passphrase.isEmpty {
                    SettingsValueRow(
                        title: "Hotspot Security",
                        value: "WPA2 (per session)"
                    )
                    Button {
                        revealsHotspotPassphrase.toggle()
                    } label: {
                        Label(
                            revealsHotspotPassphrase
                                ? "Hide Hotspot Password"
                                : "Show Hotspot Password",
                            systemImage: revealsHotspotPassphrase
                                ? "eye.slash"
                                : "eye"
                        )
                    }
                    .disabled(isWorking)
                    if revealsHotspotPassphrase {
                        Text(passphrase)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Hotspot password")
                    }
                    Button(action: copyHotspotPassphrase) {
                        Label("Copy Hotspot Password", systemImage: "key")
                    }
                    .disabled(isWorking)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                    Text(session.baseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button(action: copyBrowserURL) {
                    Label("Copy Browser URL", systemImage: "safari")
                }
                .disabled(isWorking || browserURL == nil)

                Button(action: copySessionDetails) {
                    Label("Copy Session Details", systemImage: "doc.on.doc")
                }
                .disabled(isWorking)

                Button(role: .destructive, action: endSession) {
                    Label("End Debug Session", systemImage: "stop.circle")
                }
                .disabled(isWorking)
            } else if debugModeIsActive {
                Text("The device still reports an active debug session, but its browser connection details are unavailable.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Button(role: .destructive, action: endSession) {
                    Label("End Debug Session", systemImage: "stop.circle")
                }
                .disabled(isWorking)
            } else {
                Toggle("Prefer Local Wi-Fi", isOn: $preferLAN)
                if preferLAN {
                    TextField("Wi-Fi name (SSID)", text: $lanSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Wi-Fi password", text: $lanPassword)
                        .textContentType(.password)
                    if let lanValidationMessage {
                        Text(lanValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !lanSSID.isEmpty || !lanPassword.isEmpty {
                        Button(role: .destructive, action: forgetLANCredentials) {
                            Label("Forget Local Wi-Fi", systemImage: "trash")
                        }
                        .disabled(isWorking)
                    }
                }

                Button(action: startSession) {
                    if isWorking {
                        HStack {
                            ProgressView()
                            Text("Starting Remote Debugging…")
                        }
                    } else {
                        Label("Start Remote Debugging", systemImage: "rectangle.connected.to.line.below")
                    }
                }
                .disabled(!canStart || isWorking)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Remote Device Debugging")
        } footer: {
            Text(footerText)
        }
        .onAppear(perform: loadLANCredentialsIfNeeded)
        .onChange(of: bleManager.deviceTransferMode) { mode in
            if mode != DeviceTransferSession.Mode.debug.rawValue {
                clearCopiedBrowserURLIfOwned()
                clearCopiedHotspotPassphraseIfOwned()
                revealsHotspotPassphrase = false
                if !isWorking {
                    statusMessage = "Idle"
                    errorMessage = nil
                }
            }
        }
        .onChange(of: bleManager.deviceTransferSessionToken) { _ in
            if copiedBrowserURL != browserURL?.absoluteString {
                clearCopiedBrowserURLIfOwned()
            }
        }
        .task(id: bleManager.deviceTransferMode) {
            guard bleManager.deviceTransferMode ==
                    DeviceTransferSession.Mode.debug.rawValue else { return }
            while !Task.isCancelled,
                  bleManager.deviceTransferMode ==
                    DeviceTransferSession.Mode.debug.rawValue {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                _ = bleManager.requestDeviceTransferStatus()
            }
        }
    }

    private var activeSession: DeviceTransferSession? {
        guard bleManager.deviceTransferMode == DeviceTransferSession.Mode.debug.rawValue,
              let baseURL = bleManager.deviceTransferBaseURL,
              let token = bleManager.deviceTransferSessionToken,
              !token.isEmpty else { return nil }
        return DeviceTransferSession(
            mode: .debug,
            baseURL: baseURL,
            accessPointSSID: bleManager.deviceTransferAccessPointSSID,
            accessPointPassphrase: bleManager.deviceTransferAccessPointPassphrase,
            sessionToken: token,
            networkTransport: bleManager.deviceTransferNetworkTransport,
            networkSSID: bleManager.deviceTransferNetworkSSID,
            hotspotFallback: bleManager.deviceTransferUsedHotspotFallback,
            hotspotFallbackReason: bleManager.deviceTransferHotspotFallbackReason
        )
    }

    private var browserURL: URL? {
        activeSession.flatMap {
            RemoteDeviceDebugSessionPolicy.browserURL(for: $0)
        }
    }

    private var debugModeIsActive: Bool {
        bleManager.deviceTransferMode == DeviceTransferSession.Mode.debug.rawValue
    }

    private var canStart: Bool {
        bleManager.isNavigationReady &&
            bleManager.hasReceivedDeviceCapabilities &&
            bleManager.supportsRemoteDeviceDebug &&
            bleManager.deviceTransferMode.isEmpty &&
            lanInputIsValid
    }

    private var sessionStatus: String {
        if activeSession != nil { return "Ready for browser" }
        if debugModeIsActive { return "Debug connection unavailable" }
        if !bleManager.isNavigationReady { return "Device not ready" }
        if !bleManager.hasReceivedDeviceCapabilities { return "Checking firmware" }
        if !bleManager.supportsRemoteDeviceDebug { return "Unsupported firmware" }
        if !bleManager.deviceTransferMode.isEmpty {
            return "Busy: \(bleManager.deviceTransferMode)"
        }
        return statusMessage
    }

    private var footerText: String {
        if let activeSession {
            if activeSession.networkTransport == "lan" {
                return "Open the copied URL from a computer on the same local network. The URL fragment is the session secret; do not paste it into logs."
            }
            return "Reveal or copy the per-session hotspot password, join the shown device Wi-Fi on the Mac, then open the copied URL. The URL fragment and hotspot password are secrets; do not paste them into logs."
        }
        return "Local Wi-Fi is tried first with credentials stored in this iPhone's Keychain and sent over authenticated BLE for this session only. The device hotspot is used if the device cannot join; turn off Prefer Local Wi-Fi to choose it directly."
    }

    private var lanInputIsValid: Bool {
        guard preferLAN else { return true }
        if lanSSID.isEmpty { return lanPassword.isEmpty }
        return RemoteDebugLANCredentials(
            ssid: lanSSID,
            password: lanPassword
        ) != nil
    }

    private var lanValidationMessage: String? {
        guard preferLAN else { return nil }
        if lanSSID.isEmpty {
            return lanPassword.isEmpty
                ? "Enter a network to try LAN first, or start with the device hotspot."
                : "Enter the Wi-Fi name."
        }
        guard !lanInputIsValid else { return nil }
        return "SSID must be at most 32 bytes; password must be empty for an open network or 8-63 bytes."
    }

    private func startSession() {
        revealsHotspotPassphrase = false
        isWorking = true
        errorMessage = nil
        statusMessage = "Requesting session"
        Task {
            defer { isWorking = false }
            do {
                let credentials: RemoteDebugLANCredentials?
                if preferLAN, !lanSSID.isEmpty {
                    guard let validated = RemoteDebugLANCredentials(
                        ssid: lanSSID,
                        password: lanPassword
                    ) else {
                        throw RemoteDeviceDebugError.rejected(
                            code: "invalid_lan_credentials",
                            message: lanValidationMessage ?? "Invalid local Wi-Fi credentials."
                        )
                    }
                    guard credentialStore.save(validated) else {
                        throw RemoteDeviceDebugError.rejected(
                            code: "lan_credentials_not_saved",
                            message: "The local Wi-Fi credentials could not be saved to Keychain."
                        )
                    }
                    credentials = validated
                } else {
                    if preferLAN {
                        _ = credentialStore.remove()
                    }
                    credentials = nil
                }
                _ = try await DeviceTransferManager().enterRemoteDebug(
                    bleManager: bleManager,
                    lanCredentials: credentials,
                    status: { statusMessage = $0 }
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Failed"
            }
        }
    }

    private func copyBrowserURL() {
        guard let browserURL else { return }
        UIPasteboard.general.string = browserURL.absoluteString
        copiedBrowserURL = browserURL.absoluteString
        statusMessage = "Browser URL copied"
    }

    private func copyHotspotPassphrase() {
        guard let passphrase = activeSession?.accessPointPassphrase,
              !passphrase.isEmpty else { return }
        UIPasteboard.general.string = passphrase
        copiedHotspotPassphrase = passphrase
        statusMessage = "Hotspot password copied"
    }

    private func connectionLabel(for session: DeviceTransferSession) -> String {
        switch session.networkTransport {
        case "lan":
            return "Local Wi-Fi"
        case "hotspot":
            return session.hotspotFallback
                ? "Device hotspot (fallback)"
                : "Device hotspot"
        case "connecting", "starting":
            return "Connecting"
        default:
            return "Unknown"
        }
    }

    private func fallbackReasonLabel(_ reason: String) -> String {
        switch reason {
        case "ssid_unavailable": return "Wi-Fi network not found"
        case "authentication_failed": return "Wi-Fi authentication failed"
        case "association_timeout": return "Wi-Fi connection timed out"
        case "endpoint_unreachable": return "LAN debug endpoint unreachable"
        default: return reason
        }
    }

    private func loadLANCredentialsIfNeeded() {
        guard !loadedLANCredentials else { return }
        loadedLANCredentials = true
        guard let credentials = credentialStore.load() else { return }
        lanSSID = credentials.ssid
        lanPassword = credentials.password
    }

    private func forgetLANCredentials() {
        _ = credentialStore.remove()
        lanSSID = ""
        lanPassword = ""
        statusMessage = "Local Wi-Fi forgotten"
    }

    private func copySessionDetails() {
        guard let session = activeSession else { return }
        UIPasteboard.general.string = RemoteDeviceDebugSessionPolicy.sessionDetails(
            for: session,
            target: bleManager.firmwareTarget,
            deviceName: bleManager.peripheralName
        )
        statusMessage = "Secret-free details copied"
    }

    private func endSession() {
        isWorking = true
        errorMessage = nil
        statusMessage = "Ending session"
        Task {
            defer { isWorking = false }
            do {
                try await DeviceTransferManager().exitRemoteDebug(
                    bleManager: bleManager
                )
                clearCopiedBrowserURLIfOwned()
                clearCopiedHotspotPassphraseIfOwned()
                revealsHotspotPassphrase = false
                statusMessage = "Session ended"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "End failed"
            }
        }
    }

    private func clearCopiedBrowserURLIfOwned() {
        guard let copiedBrowserURL else { return }
        if UIPasteboard.general.string == copiedBrowserURL {
            UIPasteboard.general.string = ""
        }
        self.copiedBrowserURL = nil
    }

    private func clearCopiedHotspotPassphraseIfOwned() {
        guard let copiedHotspotPassphrase else { return }
        if UIPasteboard.general.string == copiedHotspotPassphrase {
            UIPasteboard.general.string = ""
        }
        self.copiedHotspotPassphrase = nil
    }
}

@MainActor
private struct RendererBenchmarkReplaySettingsSection: View {
    @EnvironmentObject private var bleManager: BLEManager
    @StateObject private var replay = RendererBenchmarkReplayCoordinator()
    let isNavigationActive: Bool

    var body: some View {
        Section {
            SettingsValueRow(
                title: "Replay",
                value: replay.progressDescription
            )
            SettingsValueRow(
                title: "Diagnostics",
                value: bleManager.rendererDiagnosticsStatus
            )
            if !replay.fixtureID.isEmpty {
                SettingsValueRow(title: "Fixture", value: replay.fixtureID)
            }

            if !bleManager.supportsRemoteDeviceDebug {
                Picker(
                    "Ordinary Profile",
                    selection: $replay.selectedOrdinaryProfile
                ) {
                    ForEach(RendererBenchmarkProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .disabled(replay.isRunning)
            }

            Button {
                if replay.isRunning {
                    replay.stop()
                } else {
                    replay.start(
                        bleManager: bleManager,
                        isNavigationActive: isNavigationActive
                    )
                }
            } label: {
                Label(
                    replay.isRunning ? "Stop Pinned Replay" :
                        "Start Pinned 1 Hz Replay",
                    systemImage: replay.isRunning ? "stop.fill" :
                        "location.fill.viewfinder"
                )
            }
            .disabled(!replay.isRunning && !canStartReplay)

            Button {
                _ = bleManager.requestRendererDiagnosticsSnapshot()
            } label: {
                Label("Request Diagnostics Snapshot", systemImage: "waveform.path.ecg")
            }
            .disabled(!canRequestSnapshot)

            if let snapshot = bleManager.rendererDiagnosticsSnapshotJSON {
                Button {
                    UIPasteboard.general.string = snapshot
                } label: {
                    Label("Copy Latest Snapshot JSON", systemImage: "doc.on.doc")
                }
            }

            if replay.ordinarySnapshotCount > 0 {
                Button {
                    if let capture = replay.ordinaryCaptureJSON() {
                        UIPasteboard.general.string = capture
                    }
                } label: {
                    Label(
                        "Copy Ordinary Capture (\(replay.ordinarySnapshotCount))",
                        systemImage: "doc.on.clipboard"
                    )
                }
            }

            if let errorMessage = replay.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Renderer Benchmark Replay")
        } footer: {
            Text(
                "Replays the checked-in Shanghai route at exactly 1 Hz, including its SHA-256 marker and GPS sample; the route window follows the app's normal two-second cadence. Snapshot requests also work with ordinary diagnostics firmware."
            )
        }
        .onChange(of: bleManager.isNavigationReady) { ready in
            if !ready { replay.stop(clearRoute: false) }
        }
        .onChange(of: bleManager.supportsRendererDiagnostics) { supported in
            if !supported { replay.stop(clearRoute: false) }
        }
        .onChange(of: isNavigationActive) { active in
            if active { replay.stop() }
        }
        .onDisappear { replay.stop() }
    }

    private var canRequestSnapshot: Bool {
        bleManager.isConnected && bleManager.isNavigationReady &&
            bleManager.supportsRendererDiagnostics
    }

    private var canStartReplay: Bool {
        canRequestSnapshot && !isNavigationActive
    }
}
#endif

private struct DeveloperSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var offlineMapManager: OfflineMapManager
    @ObservedObject var firmwareUpdateManager: FirmwareUpdateManager
    @ObservedObject var watchAvailability: WorkoutWatchAvailabilityMonitor
    @ObservedObject var cyclingSensorStore: CyclingSensorStore
    @ObservedObject var cyclingSensorDetectionCoordinator:
        CyclingSensorDetectionCoordinator
    let currentLocation: CLLocation?
    let isNavigationActive: Bool
    let onStartTestNavigation: (String) -> Void

    var body: some View {
        Form {
            connectionSummary
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))

            Section(header: Text("Map Server")) {
                SettingsValueRow(title: "Service", value: offlineMapManager.serverURLString)
                Button(action: useProductionMapServer) {
                    Label("Use Production Server", systemImage: "checkmark.seal")
                }
#if DEBUG
                Button(action: useDevelopmentMapServer) {
                    Label("Use Development Server", systemImage: "hammer")
                }
#endif
            }

            Section {
                NavigationLink {
                    MapLibrarySettingsView(manager: offlineMapManager)
                } label: {
                    Label("Map Library", systemImage: "map.circle")
                }
            } footer: {
                Text(
                    "Manage the private Cloudflare map library, shared links, " +
                        "and Bicino app linking."
                )
            }

            Section {
                Stepper(
                    value: Binding(
                        get: { watchAvailability.maximumHeartRateBPM },
                        set: watchAvailability.setMaximumHeartRateBPM
                    ),
                    in: WorkoutHeartRateZoneProfile
                        .supportedMaximumHeartRateBPM
                ) {
                    HStack {
                        Text("Maximum Heart Rate")
                        Spacer()
                        Text("\(watchAvailability.maximumHeartRateBPM) BPM")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("Maximum heart rate")
                .accessibilityValue(
                    "\(watchAvailability.maximumHeartRateBPM) beats per minute"
                )
            } header: {
                Text("Workout Heart Zones")
            } footer: {
                Text(
                    "Bicino calculates five heart zones from this value and syncs it to the paired Watch. The default is 190 BPM."
                )
            }

            OfflineMapDeviceTransferSettingsSection(manager: offlineMapManager)
            FirmwareUpdateSettingsSection(manager: firmwareUpdateManager)
            DiagnosticsTransferNetworkSettingsSection()
#if DEBUG
            RemoteDeviceDebugSettingsSection()
            RendererBenchmarkReplaySettingsSection(
                isNavigationActive: isNavigationActive
            )
#endif
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
                    BikeComputersSettingsView(
                        sensorStore: cyclingSensorStore,
                        sensorDetectionCoordinator:
                            cyclingSensorDetectionCoordinator
                    )
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

            Section(header: Text("App")) {
                SettingsValueRow(
                    title: "App Version",
                    value: appVersionText
                )
            }

            NavigationOverlaysSettingsSection()
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

    private func useProductionMapServer() {
        offlineMapManager.serverURLString =
            OfflineMapServiceConfig.productionServerURLString
    }

#if DEBUG
    private func useDevelopmentMapServer() {
        offlineMapManager.serverURLString =
            OfflineMapServiceConfig.developmentServerURLString
    }
#endif

    private var connectionStatusText: String {
        guard bleManager.isConnected else {
            return "Disconnected"
        }

        if bleManager.signalStrength != 0 {
            return "Connected \(bleManager.signalStrength) dBm"
        }

        return "Connected"
    }

    private var appVersionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        case (nil, nil):
            return "Unknown"
        }
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
        routeLibrary: PhoneRouteLibrary(
            connectivity: PhoneWatchConnectivityCoordinator(session: nil)
        ),
        watchAvailability: WorkoutWatchAvailabilityMonitor(),
        onStartTestNavigation: { _ in }
    )
        .environmentObject(BLEManager())
}
