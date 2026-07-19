import SwiftUI

struct BikeComputersSettingsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @State private var selectedCandidate: DiscoveredBikeComputerDevice?

    var body: some View {
        Form {
            Section("My Bike Computers") {
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
            }

            if bleManager.isScanning || !bleManager.discoveredDevices.isEmpty {
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
                                selectedCandidate = device
                            } label: {
                                DiscoveredBikeComputerRow(device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Choose the device whose short code matches the one shown on your Bike Computer.")
                }
            }

            Section {
                if bleManager.isScanning {
                    Button("Stop Looking", role: .cancel) {
                        bleManager.cancelDeviceDiscovery()
                    }
                } else {
                    Button {
                        bleManager.startDeviceDiscovery()
                    } label: {
                        Label("Add Bike Computer", systemImage: "plus.circle")
                    }
                }
            }

            if let error = bleManager.pairingError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else if let status = bleManager.pairingStatusMessage {
                Section {
                    HStack(spacing: 12) {
                        if !status.contains("deregistered") {
                            ProgressView()
                        }
                        Text(status)
                    }
                }
            }

            Section {
                Text("A registered Bike Computer only accepts this iPhone. To recover after losing the phone, hold the device’s BOOT button for 8 seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Bike Computers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate) { candidate in
            PairBikeComputerSheet(candidate: candidate)
                .environmentObject(bleManager)
        }
        .onDisappear {
            if bleManager.isScanning {
                bleManager.cancelDeviceDiscovery()
            }
        }
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
                        Text("If this exact code is also displayed on your Bike Computer, press its BOOT button to confirm physical access.")
                    }

                    if bleManager.isPairingConfirmedOnDevice {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Registering this iPhone…")
                            }
                        }
                    }
                } else if didStart {
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

                Section {
                    if bleManager.isConnected(to: device) {
                        Button("Save Name") {
                            bleManager.rename(device: device, to: editedName)
                        }
                        .disabled(
                            device.isLegacy ||
                            DeviceOwnershipProtocol.normalizedName(editedName) == device.name
                        )
                    } else {
                        Button("Set as Current and Connect") {
                            bleManager.connect(to: device)
                        }
                    }
                }

                Section {
                    Button("Deregister from This iPhone", role: .destructive) {
                        showingDeregisterConfirmation = true
                    }
                    .disabled(!bleManager.isConnected(to: device) || device.isLegacy)
                } footer: {
                    if device.isLegacy {
                        Text("Install ownership-capable firmware, then add this device again to enable secure registration.")
                    } else if !bleManager.isConnected(to: device) {
                        Text("Connect to this device before deregistering so ownership is removed from both the iPhone and Bike Computer.")
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
