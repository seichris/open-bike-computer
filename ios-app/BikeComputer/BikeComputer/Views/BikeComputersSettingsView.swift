import SwiftUI

struct BikeComputersSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject private var sensorStore: CyclingSensorStore
    @ObservedObject private var sensorDetectionCoordinator:
        CyclingSensorDetectionCoordinator
    @State private var selectedCandidate: DiscoveredBikeComputerDevice?
    @State private var presentedPairingCompletionGeneration: UInt64?
    @State private var ownsDiscoveryLifecycle = false
    @State private var showingDisconnectForDiscoveryConfirmation = false
    private let focusSensorsOnAppear: Bool
    private let startsBikeComputerDiscoveryOnAppear: Bool

    init(
        sensorStore: CyclingSensorStore,
        sensorDetectionCoordinator: CyclingSensorDetectionCoordinator,
        focusSensorsOnAppear: Bool = false,
        startsBikeComputerDiscoveryOnAppear: Bool = false
    ) {
        _sensorStore = ObservedObject(wrappedValue: sensorStore)
        _sensorDetectionCoordinator = ObservedObject(
            wrappedValue: sensorDetectionCoordinator
        )
        self.focusSensorsOnAppear = focusSensorsOnAppear
        self.startsBikeComputerDiscoveryOnAppear =
            startsBikeComputerDiscoveryOnAppear
    }

    private var menuTitle: String {
        BikeComputerSettingsPresentationPolicy.title(
            knownDeviceCount: bleManager.knownDevices.count,
            isExplicitBikeComputerSetup:
                startsBikeComputerDiscoveryOnAppear
        )
    }

    var body: some View {
        Form {
            bikeComputerSection
            if let message = bleManager.rideRecoveryMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if shouldShowSensorManagement {
                sensorProfilesSection
            }

            if shouldShowExplicitDiscoveryState {
                Section {
                    if bleManager.discoveredDevices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking nearby…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(bleManager.discoveredDevices) { device in
                            Button {
                                presentedPairingCompletionGeneration =
                                    bleManager.completedPairingGeneration
                                bleManager.selectDiscoveredDeviceForPairing(
                                    device
                                )
                                selectedCandidate = device
                            } label: {
                                DiscoveredBikeComputerRow(device: device)
                            }
                            .buttonStyle(.plain)
                            .disabled(bleManager.deviceOperationDeviceID != nil)
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Choose the device whose short code matches the one shown on your Bike Computer.")
                }
            }

            if shouldShowConnectBikeComputerAction {
                Section {
                    Button {
                        handleConnectNewBikeComputer()
                    } label: {
                        Label(
                            bleManager.isConnecting
                                ? "Add a new Bicino"
                                : bleManager.knownDevices.isEmpty
                                ? "Find your Bicino"
                                : "Connect a new Bike Computer",
                            systemImage: "plus.circle"
                        )
                    }
                    .disabled(
                        bleManager.deviceOperationDeviceID != nil
                    )
                }
            }

            if shouldShowSensorManagement {
                sensorConnectionSection
            }

            if let error = bleManager.pairingError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else if let status = bleManager.pairingStatusMessage,
                      !bleManager.isDiscoveringDevices {
                Section {
                    HStack(spacing: 12) {
                        if !status.contains("deregistered") {
                            ProgressView()
                        }
                        Text(status)
                    }
                }
            }

            if shouldShowHardwareSettings {
                BicinoHardwareSettingsSections()
            }
        }
        .navigationTitle(menuTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate, onDismiss: {
            resumeOwnedDiscoveryIfNeeded()
        }) { candidate in
            BikeComputerPairingFlow(candidate: candidate)
                .environmentObject(bleManager)
        }
        .confirmationDialog(
            "Disconnect the current Bike Computer?",
            isPresented: $showingDisconnectForDiscoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect and Search") {
                ownsDiscoveryLifecycle = true
                bleManager.disconnectCurrentDeviceAndStartDiscovery()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Bicino can connect to one Bike Computer at a time. The current device must disconnect before searching for another.")
        }
        .onAppear {
            bleManager.setUnknownDeviceDiscoverySuspended(
                sensorDetectionCoordinator.isLooking
            )
            if shouldStartBikeComputerDiscovery {
                beginDiscovery()
            }
        }
        .onChange(of: bleManager.centralStateDescription) { state in
            if state == "powered on", ownsDiscoveryLifecycle,
               selectedCandidate == nil,
               !sensorDetectionCoordinator.isLooking {
                bleManager.startDeviceDiscovery()
            }
        }
        .onChange(of: bleManager.isApplicationActive) { isActive in
            guard BikeComputersMenuPolicy
                    .shouldRestartOwnedDiscoveryOnForeground(
                        isApplicationActive: isActive,
                        ownsDiscoveryLifecycle: ownsDiscoveryLifecycle,
                        hasPresentedCandidate: selectedCandidate != nil,
                        isSensorEnrollmentActive:
                            sensorDetectionCoordinator.isLooking
                    ) else { return }
            bleManager.startDeviceDiscovery()
        }
        .onChange(of: bleManager.knownDevices.count) { count in
            if shouldStartBikeComputerDiscovery {
                if !ownsDiscoveryLifecycle {
                    beginDiscovery()
                }
            } else if ownsDiscoveryLifecycle {
                ownsDiscoveryLifecycle = false
                bleManager.cancelDeviceDiscovery(resumeAutoReconnect: true)
            }
        }
        .onChange(of: sensorDetectionCoordinator.isLooking) {
            isLooking in
            applyDiscoveryTransition(
                BikeComputerSettingsDiscoveryLifecyclePolicy
                    .sensorEnrollmentChanged(
                        isLooking: isLooking,
                        shouldStartDiscovery:
                            shouldStartBikeComputerDiscovery,
                        ownsDiscoveryLifecycle: ownsDiscoveryLifecycle
                    )
            )
        }
        .onDisappear {
            sensorDetectionCoordinator.stopLooking()
            applyDiscoveryTransition(
                BikeComputerSettingsDiscoveryLifecyclePolicy
                    .screenDisappeared(
                        ownsDiscoveryLifecycle: ownsDiscoveryLifecycle
                    )
            )
        }
    }

    @ViewBuilder
    private var bikeComputerSection: some View {
        if !bleManager.knownDevices.isEmpty {
            Section {
                ForEach(bleManager.knownDevices) { device in
                    NavigationLink {
                        BikeComputerDetailView(deviceID: device.deviceID)
                    } label: {
                        KnownBikeComputerRow(device: device)
                    }
                }
            } header: {
                Text("Bicino")
            }
        }
    }

    private var sensorProfilesSection: some View {
        CyclingSensorProfilesSection(
            sensorStore: sensorStore,
            detectionCoordinator: sensorDetectionCoordinator,
            focusOnAppear: focusSensorsOnAppear
        )
    }

    private var sensorConnectionSection: some View {
        CyclingSensorConnectionSection(
            sensorStore: sensorStore,
            detectionCoordinator: sensorDetectionCoordinator,
            focusOnAppear: focusSensorsOnAppear
        )
    }

    private var shouldShowConnectBikeComputerAction: Bool {
        BikeComputerSettingsPresentationPolicy.shouldShowConnectAction(
            baseEligibility:
                BikeComputerSettingsPresentationPolicy.shouldShowConnectAction(
                    knownDeviceCount: bleManager.knownDevices.count,
                    isExplicitBikeComputerSetup:
                        startsBikeComputerDiscoveryOnAppear
                ),
            scanPurpose: bleManager.currentScanPurpose,
            isExplicitDiscoveryPending:
                bleManager.isExplicitDiscoveryPending
        )
    }

    private var shouldShowSensorManagement: Bool {
        BikeComputerSettingsPresentationPolicy.shouldShowSensorManagement(
            hasEverConnectedBikeComputer:
                bleManager.hasEverConnectedBikeComputer,
            sensorProfileCount: sensorStore.profiles.count,
            isExplicitSensorSetup: focusSensorsOnAppear
        )
    }

    private var shouldShowHardwareSettings: Bool {
        BikeComputerSettingsPresentationPolicy.shouldShowHardwareSettings(
            knownDeviceCount: bleManager.knownDevices.count
        )
    }

    private var shouldShowExplicitDiscoveryState: Bool {
        BikeComputerSettingsPresentationPolicy
            .shouldShowExplicitDiscoveryState(
                scanPurpose: bleManager.currentScanPurpose
            )
    }

    private var shouldStartBikeComputerDiscovery: Bool {
        BikeComputerSettingsPresentationPolicy.shouldStartDiscovery(
            knownDeviceCount: bleManager.knownDevices.count,
            isExplicitBikeComputerSetup:
                startsBikeComputerDiscoveryOnAppear,
            isSensorLooking: sensorDetectionCoordinator.isLooking,
            hasSensorCandidates:
                !sensorDetectionCoordinator.candidates.isEmpty
        )
    }

    private func beginDiscovery() {
        ownsDiscoveryLifecycle = true
        bleManager.startDeviceDiscovery()
    }

    private func applyDiscoveryTransition(
        _ transition: BikeComputerSettingsDiscoveryTransition
    ) {
        ownsDiscoveryLifecycle = transition.ownsDiscoveryLifecycle
        for command in transition.commands {
            switch command {
            case .suspendUnknownDiscovery:
                bleManager.setUnknownDeviceDiscoverySuspended(true)
            case .resumeUnknownDiscovery:
                bleManager.setUnknownDeviceDiscoverySuspended(false)
            case .beginExplicitDiscovery:
                bleManager.startDeviceDiscovery()
            case .cancelOwnedDiscovery:
                bleManager.cancelDeviceDiscovery(resumeAutoReconnect: true)
            }
        }
    }

    private func handleConnectNewBikeComputer() {
        switch BLEExplicitDiscoveryStartPolicy.action(
            hasActiveBLESession: bleManager.hasActiveTransportSession,
            isConnecting: bleManager.isConnecting
        ) {
        case .start:
            beginDiscovery()
        case .confirmDisconnect:
            showingDisconnectForDiscoveryConfirmation = true
        case .cancelConnection:
            bleManager.cancelConnectionAttemptForDiscovery()
        }
    }

    private func resumeOwnedDiscoveryIfNeeded() {
        let pairingCompletedDuringPresentation =
            presentedPairingCompletionGeneration.map {
                bleManager.completedPairingGeneration != $0
            } ?? false
        presentedPairingCompletionGeneration = nil
        guard BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: ownsDiscoveryLifecycle,
            isBluetoothPoweredOn:
                bleManager.centralStateDescription == "powered on",
            isExplicitDiscoveryActive:
                bleManager.currentScanPurpose == .explicitDiscovery,
            pairingCompletedDuringPresentation:
                pairingCompletedDuringPresentation
        ) else {
            if pairingCompletedDuringPresentation {
                ownsDiscoveryLifecycle = false
            }
            return
        }
        bleManager.startDeviceDiscovery()
    }
}

private struct KnownBikeComputerRow: View {
    @EnvironmentObject private var bleManager: BLEManager
    let device: KnownBikeComputerDevice

    var body: some View {
        let isConnected = bleManager.isConnected(to: device)

        HStack(spacing: 10) {
            Image(
                systemName: isConnected
                    ? "antenna.radiowaves.left.and.right"
                    : "antenna.radiowaves.left.and.right.slash"
            )
            .frame(width: 24)
            .foregroundStyle(isConnected ? Color.primary : Color.secondary)
            .accessibilityHidden(true)

            Text(device.name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(device.name), \(isConnected ? "Connected" : "Not connected")"
        )
    }
}

private struct DiscoveredBikeComputerRow: View {
    let device: DiscoveredBikeComputerDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bicycle")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.advertisedName)
                Text("Device \(device.shortIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.isClaimed == true {
                Text("Registered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: signalImage)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Signal \(BLEDiscoverySignalPolicy.description(for: device.rssi))"
                )
        }
        .contentShape(Rectangle())
    }

    private var signalImage: String {
        let rank = BLEDiscoverySignalPolicy.rank(for: device.rssi)
        if rank >= -60 { return "wifi" }
        if rank >= -75 { return "wifi.exclamationmark" }
        return "antenna.radiowaves.left.and.right.slash"
    }
}

struct BikeComputerPairingFlow: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    let candidate: DiscoveredBikeComputerDevice

    @State private var deviceName = DeviceOwnershipProtocol.defaultDeviceName
    @State private var didStart = false
    @FocusState private var isDeviceNameFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                if let prompt = matchingPrompt {
                    if bleManager.isPairingConfirmationSubmitting {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Registering this iPhone…")
                            }
                        }
                    } else {
                        Section {
                            VStack(spacing: 16) {
                                Text(prompt.formattedCode)
                                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .accessibilityLabel("Pairing code \(prompt.formattedCode)")

                                BikeComputerPairingConfirmationIllustration(
                                    code: prompt.formattedCode
                                )
                            }
                            .frame(maxWidth: .infinity)
                        } header: {
                            Text("Confirm the Code on your Bicino")
                        } footer: {
                            if prompt.isReplacingExistingRegistration {
                                Text("This Bike Computer was reset. Match this code, then press either button on the device to replace its old registration on this iPhone.")
                            }
                        }
                    }
                } else if didStart, bleManager.pairingError == nil {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(bleManager.pairingStatusMessage ?? "Preparing secure pairing…")
                        }
                    }
                } else {
                    Section {
                        TextField("Bike name", text: $deviceName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.continue)
                            .focused($isDeviceNameFocused)
                            .onSubmit(startPairing)
                    } header: {
                        Text("Name Your Bike")
                    }

                    Section {
                        Button("Continue") { startPairing() }
                            .frame(maxWidth: .infinity)
                    }
                }

                if let error = bleManager.pairingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        switch pairingErrorAction {
                        case .retry:
                            Button("Try Again") {
                                bleManager.cancelPairing()
                                didStart = false
                            }
                        case .close:
                            Button("Close") {
                                bleManager.cancelPairing()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Bike Computer")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.async {
                    isDeviceNameFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        bleManager.cancelPairing()
                        dismiss()
                    }
                }
            }
            .onChange(of: bleManager.isConnected) { isConnected in
                guard isConnected,
                      bleManager.knownDevices.contains(where: {
                          $0.peripheralIdentifier == candidate.peripheralIdentifier
                      }) else { return }
                dismiss()
            }
            .onDisappear {
                bleManager.cancelPairing()
            }
        }
    }

    private var matchingPrompt: BikeComputerPairingPrompt? {
        guard bleManager.pairingPrompt?.peripheralIdentifier == candidate.peripheralIdentifier else {
            return nil
        }
        return bleManager.pairingPrompt
    }

    private var pairingErrorAction: BikeComputerPairingErrorAction {
        BikeComputerPairingErrorActionPolicy.action(
            hasRetainedNearbyCandidate:
                bleManager.nearbyCandidate(
                    peripheralIdentifier: candidate.peripheralIdentifier
                ) != nil
        )
    }

    private func startPairing() {
        isDeviceNameFocused = false
        didStart = true
        bleManager.pair(with: candidate, name: deviceName)
    }
}

private struct BikeComputerPairingConfirmationIllustration: View {
    let code: String

    var body: some View {
        Image("PairingConfirmationBicino")
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    Text(code)
                        .font(
                            .system(
                                size: geometry.size.width * 0.10,
                                weight: .black,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .foregroundStyle(
                            Color(red: 1.0, green: 0.72, blue: 0.04)
                        )
                        .position(
                            x: geometry.size.width * 0.5,
                            y: geometry.size.height * 0.64
                        )
                }
            }
            .frame(maxWidth: 360)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "On your Bicino, confirm code \(code) by pressing either button"
            )
    }
}

private struct BikeComputerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    let deviceID: String
    @State private var editedName = ""
    @State private var showingDeregisterConfirmation = false
    @State private var showingForgetConfirmation = false

    private var device: KnownBikeComputerDevice? {
        bleManager.knownDevices.first { $0.deviceID == deviceID }
    }

    var body: some View {
        Form {
            if let device {
                Section("My Bicino") {
                    HStack(spacing: 12) {
                        TextField("Name", text: $editedName)
                            .disabled(
                                !bleManager.isConnected(to: device) ||
                                device.isLegacy
                            )

                        if bleManager.isConnected(to: device) && !device.isLegacy {
                            Button("Save Name") {
                                bleManager.rename(device: device, to: editedName)
                            }
                            .disabled(
                                bleManager.deviceOperationDeviceID != nil ||
                                DeviceOwnershipProtocol.normalizedName(editedName) == device.name
                            )
                        }
                    }
                    DeviceValueRow(title: "Device ID", value: device.shortIdentifier)
                    DeviceValueRow(
                        title: "Status",
                        value: bleManager.isConnected(to: device) ? "Connected" : "Disconnected"
                    )
                }

                if !device.isLegacy {
                    watchControllerSection(device: device)
                }

                if bleManager.deviceFeedbackDeviceID == device.deviceID,
                   let error = bleManager.pairingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } else if bleManager.deviceFeedbackDeviceID == device.deviceID,
                          let status = bleManager.pairingStatusMessage {
                    Section {
                        HStack(spacing: 12) {
                            if !status.contains("deregistered") { ProgressView() }
                            Text(status)
                        }
                    }
                }

                Section {
                    if !bleManager.isConnected(to: device) {
                        Button("Set as current device and connect") {
                            bleManager.connect(to: device)
                        }
                    }

                    if BikeComputerRemovalPolicy.action(
                        isConnected: bleManager.isConnected(to: device),
                        isLegacy: device.isLegacy
                    ) == .deregister {
                        Button("Deregister from This iPhone", role: .destructive) {
                            showingDeregisterConfirmation = true
                        }
                        .disabled(
                            device.isLegacy ||
                            bleManager.deviceOperationDeviceID != nil
                        )
                    } else {
                        Button("Forget device on this iPhone", role: .destructive) {
                            showingForgetConfirmation = true
                        }
                        .disabled(bleManager.deviceOperationDeviceID != nil)
                    }
                } footer: {
                    if device.isLegacy {
                        Text("You can forget this legacy entry here, or install ownership-capable firmware and add it again.")
                    } else if !bleManager.isConnected(to: device) {
                        Text("Forgetting removes this iPhone’s local credential only. Use this if the Bike Computer was reset, transferred, or is no longer available.")
                    } else {
                        Text("The Bike Computer will restart and become available for another iPhone.")
                    }
                }
                .confirmationDialog(
                    "Deregister \(device.name)?",
                    isPresented: $showingDeregisterConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Deregister", role: .destructive) {
                        bleManager.deregister(device: device)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This removes the secure owner credential from both devices.")
                }
                .confirmationDialog(
                    "Forget \(device.name) on this iPhone?",
                    isPresented: $showingForgetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Forget", role: .destructive) {
                        bleManager.forgetLocally(device: device)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This removes the saved credential from this iPhone. It does not change the Bike Computer.")
                }
            }
        }
        .navigationTitle(device?.name ?? "Bike Computer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { editedName = device?.name ?? "" }
        .onChange(of: device?.name) { newName in
            if let newName { editedName = newName }
        }
        .onChange(of: device) { newDevice in
            if newDevice == nil { dismiss() }
        }
    }

    private func watchDisplayName() -> String {
        let state = bleManager.watchConnectivityState
        if let name = state.watchMetadata?.name {
            return name
        }
        if !state.isSupported {
            return "Unavailable"
        }
        if !state.isPaired {
            return "Not paired"
        }
        if !state.isWatchAppInstalled {
            return "Bicino not installed"
        }
        return "Apple Watch"
    }

    private func directRideStatus(
        for device: KnownBikeComputerDevice
    ) -> String {
        let isCurrentDevice = bleManager.connectedDeviceID == device.deviceID
        if isCurrentDevice,
           bleManager.watchControllerOperationStatus != nil {
            return "Setting up…"
        }
        if isCurrentDevice,
           bleManager.watchControllerOperationError != nil {
            return "Needs attention"
        }
        if bleManager.isWatchControllerConfigured(for: device) {
            return "Ready"
        }
        guard bleManager.isConnected(to: device) else {
            return "Connect Bicino to set up"
        }
        guard bleManager.supportsScopedWatchController else {
            return "Update firmware"
        }
        let state = bleManager.watchConnectivityState
        if !state.isPaired {
            return "Pair an Apple Watch"
        }
        if !state.isWatchAppInstalled {
            return "Install Bicino on Watch"
        }
        if !state.isReachable {
            return "Open Watch app"
        }
        return "Setting up…"
    }

    @ViewBuilder
    private func watchControllerSection(
        device: KnownBikeComputerDevice
    ) -> some View {
        Section {
            DeviceValueRow(
                title: "Watch",
                value: watchDisplayName()
            )
            DeviceValueRow(
                title: "Direct rides",
                value: directRideStatus(for: device)
            )
            if bleManager.watchConnectivityState.pendingControllerCleanupDeviceIDs.contains(device.deviceID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watch key cleanup awaiting confirmation")
                    Text("Cleanup retries automatically when the Watch is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if bleManager.connectedDeviceID == device.deviceID,
               let status = bleManager.watchControllerOperationStatus {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(verbatim: status)
                }
            }
            if bleManager.connectedDeviceID == device.deviceID,
               let error = bleManager.watchControllerOperationError {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text(watchControllerFooter(for: device))
        }
    }

    private func watchControllerFooter(
        for device: KnownBikeComputerDevice
    ) -> String {
        let isCurrentDevice = bleManager.connectedDeviceID == device.deviceID
        if bleManager.isWatchControllerConfigured(for: device),
           (!isCurrentDevice || bleManager.watchControllerOperationError == nil) {
            return "Direct workout data and navigation switch to Apple Watch automatically when the iPhone is unavailable."
        }
        if !bleManager.isConnected(to: device) {
            return "Connect this Bicino to set up direct rides automatically."
        }
        if !bleManager.supportsScopedWatchController {
            return "Install firmware with scoped Apple Watch controller support."
        }
        if !bleManager.watchConnectivityState.isReachable {
            return "Unlock Apple Watch and open its Bicino app to finish automatic setup."
        }
        return "The Watch receives ride-only access automatically. It cannot rename, reconfigure, transfer maps to, or deregister this Bike Computer."
    }
}

private struct DeviceValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Hardware settings for the connected Bicino, at the bottom of Bicino & Bike Sensors.
private struct BicinoHardwareSettingsSections: View {
    @EnvironmentObject private var bleManager: BLEManager

    private var displayInactivityFooter: String {
        guard bleManager.supportsDisplayInactivityTimeouts else {
            return "When enabled, the display dims after 15 seconds and turns off after 45 seconds unless navigation, workout, transfer, or attention activity is active."
        }
        return "When enabled, the display dims after \(bleManager.displayDimTimeout.title) and turns off after \(bleManager.displayOffTimeout.title) unless navigation, workout, transfer, or attention activity is active."
    }

    var body: some View {
        if bleManager.supportsDisplayBrightness {
            Section(
                header: Text("Device Brightness"),
                footer: Text(displayInactivityFooter)
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
                if bleManager.supportsDisplayInactivityTimeouts {
                    Picker("Dim After", selection: $bleManager.displayDimTimeout) {
                        ForEach(DisplayDimTimeout.allCases.filter {
                            $0.rawValue < bleManager.displayOffTimeout.rawValue
                        }) { timeout in
                            Text(timeout.title).tag(timeout)
                        }
                    }
                    .onChange(of: bleManager.displayDimTimeout) { _ in
                        bleManager.sendDisplayInactivityTimeouts()
                    }
                    .disabled(!bleManager.automaticDisplayOffEnabled)

                    Picker("Turn Off After", selection: $bleManager.displayOffTimeout) {
                        ForEach(DisplayOffTimeout.allCases.filter {
                            $0.rawValue > bleManager.displayDimTimeout.rawValue
                        }) { timeout in
                            Text(timeout.title).tag(timeout)
                        }
                    }
                    .onChange(of: bleManager.displayOffTimeout) { _ in
                        bleManager.sendDisplayInactivityTimeouts()
                    }
                    .disabled(!bleManager.automaticDisplayOffEnabled)
                }
            }
            .disabled(!bleManager.supportsDeviceSettings)

        }
        if bleManager.supportsDisconnectedSleep {
            Section(
                header: Text("Power"),
                footer: Text("This puts the entire device into deep sleep after its phone connection is lost. It is separate from the connected display timeout above.")
            ) {
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
        if bleManager.supportsTapToCycle {
            Section(header: Text("Screen Navigation")) {
                Toggle("Tap to Switch Screens", isOn: $bleManager.tapToSwitchScreens)
                    .onChange(of: bleManager.tapToSwitchScreens) { newValue in
                        bleManager.sendSetting(id: 11, value: newValue ? 1 : 0)
                    }
            }
            .disabled(!bleManager.supportsDeviceSettings)

        }
        if bleManager.isEPaperDevice {
            Section("E-paper controls") {
                Text("Up and down change screens. Press the center key for actions; hold it to return from screen controls.")
                Text("The display keeps its image without power. Check the connection and GPS status before relying on displayed guidance.")
            }
        }
        DeviceSoundsSettingsSection()
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
        Section(
            header: Text("Device Sounds"),
            footer: Text("Enable this when a speaker is connected to show the sound controls and honk button.")
        ) {
            Toggle("Enable Device Sounds", isOn: $bleManager.deviceSoundsEnabled)
                .onChange(of: bleManager.deviceSoundsEnabled) { _ in
                    bleManager.saveSettings()
                }

            if bleManager.deviceSoundsEnabled {
                Group {
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
                .disabled(!bleManager.supportsDeviceSounds)
            }
        }
    }
}
