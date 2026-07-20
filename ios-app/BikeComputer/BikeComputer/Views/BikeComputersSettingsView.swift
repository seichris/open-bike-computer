import SwiftUI

struct BikeComputersSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var selectedCandidate: DiscoveredBikeComputerDevice?
    @State private var presentedPairingCompletionGeneration: UInt64?
    @State private var ownsDiscoveryLifecycle = false

    private var menuTitle: String {
        BikeComputersMenuPolicy.title(
            knownDeviceCount: bleManager.knownDevices.count
        )
    }

    var body: some View {
        Form {
            Section {
                if bleManager.knownDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No Bike Computers", systemImage: "bicycle")
                        Text("Add a nearby device and choose a name for it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(bleManager.knownDevices) { device in
                        NavigationLink {
                            BikeComputerDetailView(deviceID: device.deviceID)
                        } label: {
                            KnownBikeComputerRow(device: device)
                        }
                    }
                }
            } header: {
                if !bleManager.knownDevices.isEmpty {
                    Text(menuTitle)
                }
            }

            if bleManager.isDiscoveringDevices ||
                !bleManager.discoveredDevices.isEmpty {
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

            if BikeComputersMenuPolicy.shouldShowConnectNewDeviceAction(
                knownDeviceCount: bleManager.knownDevices.count
            ), !bleManager.isDiscoveringDevices {
                Section {
                    Button {
                        beginDiscovery()
                    } label: {
                        Label(
                            "Connect a new Bike Computer",
                            systemImage: "plus.circle"
                        )
                    }
                    .disabled(bleManager.deviceOperationDeviceID != nil)
                }
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

        }
        .navigationTitle(menuTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate, onDismiss: {
            resumeOwnedDiscoveryIfNeeded()
        }) { candidate in
            PairBikeComputerSheet(candidate: candidate)
                .environmentObject(bleManager)
        }
        .onAppear {
            if BikeComputersMenuPolicy.shouldStartDiscoveryOnEntry(
                knownDeviceCount: bleManager.knownDevices.count
            ) {
                beginDiscovery()
            } else if bleManager.isDiscoveringDevices {
                bleManager.cancelDeviceDiscovery(resumeAutoReconnect: true)
            }
        }
        .onChange(of: bleManager.centralStateDescription) { state in
            if state == "powered on", ownsDiscoveryLifecycle,
               selectedCandidate == nil {
                bleManager.startDeviceDiscovery()
            }
        }
        .onChange(of: bleManager.knownDevices.count) { count in
            if BikeComputersMenuPolicy.shouldStartDiscoveryOnEntry(
                knownDeviceCount: count
            ) {
                if !ownsDiscoveryLifecycle {
                    beginDiscovery()
                }
            } else if ownsDiscoveryLifecycle {
                ownsDiscoveryLifecycle = false
                bleManager.cancelDeviceDiscovery(resumeAutoReconnect: true)
            }
        }
        .onDisappear {
            if ownsDiscoveryLifecycle || bleManager.isDiscoveringDevices {
                ownsDiscoveryLifecycle = false
                bleManager.cancelDeviceDiscovery(resumeAutoReconnect: true)
            }
        }
    }

    private func beginDiscovery() {
        ownsDiscoveryLifecycle = true
        bleManager.startDeviceDiscovery()
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
            isDiscoveringDevices: bleManager.isDiscoveringDevices,
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
        HStack(spacing: 12) {
            Image(systemName: "bicycle.circle.fill")
                .font(.title2)
                .foregroundStyle(bleManager.isConnected(to: device) ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                Text("Device \(device.shortIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if bleManager.isConnected(to: device) {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if bleManager.hasObservedIdentityMismatch(for: device) {
                Text("Needs Setup")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if bleManager.activeDeviceID == device.deviceID {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
                .accessibilityLabel("Signal \(device.rssi) dBm")
        }
        .contentShape(Rectangle())
    }

    private var signalImage: String {
        if device.rssi >= -60 { return "wifi" }
        if device.rssi >= -75 { return "wifi.exclamationmark" }
        return "antenna.radiowaves.left.and.right.slash"
    }
}

private struct PairBikeComputerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    let candidate: DiscoveredBikeComputerDevice

    @State private var deviceName = DeviceOwnershipProtocol.defaultDeviceName
    @State private var didStart = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    DeviceValueRow(title: "Device", value: candidate.shortIdentifier)
                    DeviceValueRow(title: "Signal", value: "\(candidate.rssi) dBm")
                }

                if let prompt = matchingPrompt {
                    Section {
                        Text(prompt.formattedCode)
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Pairing code \(prompt.formattedCode)")
                    } header: {
                        Text("Confirm the Code")
                    } footer: {
                        if prompt.isReplacingExistingRegistration {
                            Text("This Bike Computer was reset. Match this code, then press either button on the device to replace its old registration on this iPhone.")
                        } else {
                            Text("If this exact code is also displayed on your Bike Computer, press either button on the device to confirm physical access.")
                        }
                    }

                    if bleManager.isPairingConfirmationSubmitting {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Registering this iPhone…")
                            }
                        }
                    } else if bleManager.isPairingConfirmedOnDevice {
                        Section {
                            Button(
                                prompt.isReplacingExistingRegistration
                                    ? "Codes Match — Replace Registration"
                                    : "Codes Match — Register This iPhone",
                                role: prompt.isReplacingExistingRegistration
                                    ? .destructive
                                    : nil
                            ) {
                                bleManager.confirmPairingAfterCodeMatch()
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
                            .onSubmit(startPairing)
                    } header: {
                        Text("Name Your Bike")
                    } footer: {
                        Text("You can change this later. iOS does not expose the owner’s Apple ID name, so the app starts with “My bike.”")
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
                        Button("Try Again") {
                            bleManager.cancelPairing()
                            didStart = false
                        }
                    }
                }
            }
            .navigationTitle("Add Bike Computer")
            .navigationBarTitleDisplayMode(.inline)
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

    private func startPairing() {
        didStart = true
        bleManager.pair(with: candidate, name: deviceName)
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
                Section("Bike Computer") {
                    TextField("Name", text: $editedName)
                        .disabled(!bleManager.isConnected(to: device) || device.isLegacy)
                    DeviceValueRow(title: "Device ID", value: device.shortIdentifier)
                    DeviceValueRow(
                        title: "Status",
                        value: bleManager.isConnected(to: device) ? "Connected" : "Disconnected"
                    )
                }

                if !bleManager.isConnected(to: device) || !device.isLegacy {
                    Section {
                        if bleManager.isConnected(to: device) {
                            Button("Save Name") {
                                bleManager.rename(device: device, to: editedName)
                            }
                            .disabled(
                                bleManager.deviceOperationDeviceID != nil ||
                                DeviceOwnershipProtocol.normalizedName(editedName) == device.name
                            )
                        } else {
                            Button("Set as Current and Connect") {
                                bleManager.connect(to: device)
                            }
                        }
                    }
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
                        Button("Forget on This iPhone", role: .destructive) {
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
