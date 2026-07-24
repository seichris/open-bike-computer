import SwiftUI

struct CyclingSensorsSettingsSections: View {
    @ObservedObject var sensorStore: CyclingSensorStore
    @ObservedObject var detectionCoordinator:
        CyclingSensorDetectionCoordinator
    @State private var selectedCandidate: CyclingSensorCandidate?

    var body: some View {
        Group {
            Section {
                if sensorStore.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No Sensors", systemImage: "gauge")
                        Text(
                            "Add a sensor after BikeComputer receives cadence or power data from your Apple Watch."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sensorStore.profiles) { profile in
                        NavigationLink {
                            CyclingSensorDetailView(
                                profileID: profile.id,
                                sensorStore: sensorStore,
                                detectionCoordinator:
                                    detectionCoordinator
                            )
                        } label: {
                            CyclingSensorProfileRow(
                                profile: profile,
                                detectionCoordinator:
                                    detectionCoordinator
                            )
                        }
                    }
                }
            } header: {
                Text("My Sensors")
            }

            if detectionCoordinator.isLooking {
                Section {
                    if detectionCoordinator.candidates.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking nearby…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(detectionCoordinator.candidates) {
                            candidate in
                            Button {
                                selectedCandidate = candidate
                            } label: {
                                CyclingSensorCandidateRow(
                                    candidate: candidate
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Stop Looking", role: .cancel) {
                        detectionCoordinator.stopLooking()
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text(discoveryFooter)
                }
            } else {
                Section {
                    Button {
                        detectionCoordinator.beginLooking()
                    } label: {
                        Label(
                            "Connect a new Sensor",
                            systemImage: "plus.circle"
                        )
                    }
                } footer: {
                    Text(
                        "Apple Watch manages the Bluetooth connection. BikeComputer adds a sensor after it receives workout data."
                    )
                }
            }
        }
        .sheet(item: $selectedCandidate) { candidate in
            CyclingSensorEnrollmentSheet(
                candidate: candidate,
                sensorStore: sensorStore,
                detectionCoordinator: detectionCoordinator
            )
        }
    }

    private var discoveryFooter: String {
        if detectionCoordinator.hasActiveWorkout {
            return "Keep pedaling so Apple Watch continues receiving cadence or power data."
        }
        return "On Apple Watch, pair the sensor in Settings > Bluetooth > Health Devices. Wake the sensor, then start a BikeComputer cycling workout."
    }
}

private struct CyclingSensorProfileRow: View {
    let profile: CyclingSensorProfile
    @ObservedObject var detectionCoordinator:
        CyclingSensorDetectionCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge")
                .font(.title3)
                .foregroundStyle(profile.isEnabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                Text(profile.capabilities.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !profile.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: Date(), by: 2)) { context in
                    Text(
                        detectionCoordinator.isReporting(
                            capabilities: profile.capabilities,
                            at: context.date
                        )
                            ? "Reporting"
                            : "Not reporting"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        detectionCoordinator.isReporting(
                            capabilities: profile.capabilities,
                            at: context.date
                        )
                            ? Color.green
                            : .secondary
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CyclingSensorCandidateRow: View {
    let candidate: CyclingSensorCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.suggestedName)
                Text("\(candidate.capabilities.displayName) data received")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private enum CyclingSensorCapabilityChoice: String, CaseIterable, Identifiable {
    case cadence
    case power
    case combined

    var id: String { rawValue }

    var capabilities: CyclingSensorCapabilities {
        switch self {
        case .cadence:
            return .cadence
        case .power:
            return .power
        case .combined:
            return [.cadence, .power]
        }
    }

    var title: String {
        capabilities.displayName
    }

    init(capabilities: CyclingSensorCapabilities) {
        if capabilities.contains(.cadence)
            && capabilities.contains(.power) {
            self = .combined
        } else if capabilities.contains(.power) {
            self = .power
        } else {
            self = .cadence
        }
    }
}

private struct CyclingSensorEnrollmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidate: CyclingSensorCandidate
    @ObservedObject var sensorStore: CyclingSensorStore
    @ObservedObject var detectionCoordinator:
        CyclingSensorDetectionCoordinator
    @State private var sensorName: String
    @State private var capabilityChoice: CyclingSensorCapabilityChoice

    init(
        candidate: CyclingSensorCandidate,
        sensorStore: CyclingSensorStore,
        detectionCoordinator: CyclingSensorDetectionCoordinator
    ) {
        self.candidate = candidate
        self.sensorStore = sensorStore
        self.detectionCoordinator = detectionCoordinator
        _sensorName = State(initialValue: candidate.suggestedName)
        _capabilityChoice = State(
            initialValue: CyclingSensorCapabilityChoice(
                capabilities: candidate.capabilities
            )
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Sensor") {
                    TextField("Name", text: $sensorName)
                    Picker("Measures", selection: $capabilityChoice) {
                        ForEach(CyclingSensorCapabilityChoice.allCases) {
                            choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }

                Section {
                    Button("Connect Sensor") {
                        guard sensorStore.enroll(
                            name: sensorName,
                            capabilities: capabilityChoice.capabilities
                        ) != nil else {
                            return
                        }
                        detectionCoordinator.didEnroll(
                            capabilities: capabilityChoice.capabilities
                        )
                        dismiss()
                    }
                } footer: {
                    Text(
                        "Apple Watch keeps managing the Bluetooth connection. This choice controls which BikeComputer workout stats are shown."
                    )
                }

                Section {
                    Label(
                        "BikeComputer detected \(candidate.capabilities.displayName.lowercased()) data during the current workout.",
                        systemImage: "applewatch.radiowaves.left.and.right"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onChange(of: capabilityChoice) { newChoice in
                if sensorName == candidate.suggestedName {
                    sensorName =
                        newChoice.capabilities.suggestedSensorName
                }
            }
        }
    }
}

private struct CyclingSensorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    @ObservedObject var sensorStore: CyclingSensorStore
    @ObservedObject var detectionCoordinator:
        CyclingSensorDetectionCoordinator
    @State private var editedName = ""
    @State private var showingForgetConfirmation = false

    private var profile: CyclingSensorProfile? {
        sensorStore.profile(id: profileID)
    }

    var body: some View {
        Form {
            if let profile {
                Section("Sensor") {
                    TextField("Name", text: $editedName)
                    CyclingSensorValueRow(
                        title: "Measures",
                        value: profile.capabilities.displayName
                    )
                    TimelineView(.periodic(from: Date(), by: 2)) {
                        context in
                        CyclingSensorValueRow(
                            title: "Status",
                            value: statusText(
                                profile: profile,
                                at: context.date
                            )
                        )
                    }
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { profile.isEnabled },
                            set: {
                                sensorStore.setEnabled(
                                    $0,
                                    profileID: profile.id
                                )
                            }
                        )
                    )
                }

                Section {
                    Button("Save Name") {
                        sensorStore.rename(
                            profileID: profile.id,
                            to: editedName
                        )
                    }
                    .disabled(
                        normalizedEditedName.isEmpty
                            || normalizedEditedName == profile.name
                    )
                }

                Section {
                    Button("Forget Sensor", role: .destructive) {
                        showingForgetConfirmation = true
                    }
                } footer: {
                    Text(
                        "Forgetting removes this BikeComputer profile. It does not unpair the sensor from Apple Watch."
                    )
                }
                .confirmationDialog(
                    "Forget \(profile.name)?",
                    isPresented: $showingForgetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Forget", role: .destructive) {
                        detectionCoordinator.didForget(
                            capabilities: profile.capabilities
                        )
                        sensorStore.forget(profileID: profile.id)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(
                        "Cadence and power tiles supplied only by this profile will be hidden."
                    )
                }

                Section {
                    Text(
                        "Pair or remove the physical accessory in Apple Watch Settings > Bluetooth > Health Devices."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(profile?.name ?? "Sensor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedName = profile?.name ?? ""
        }
        .onChange(of: profile?.name) { newName in
            if let newName {
                editedName = newName
            }
        }
        .onChange(of: profile) { newProfile in
            if newProfile == nil {
                dismiss()
            }
        }
    }

    private var normalizedEditedName: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func statusText(
        profile: CyclingSensorProfile,
        at date: Date
    ) -> String {
        if detectionCoordinator.isReporting(
            capabilities: profile.capabilities,
            at: date
        ) {
            return "Data received now"
        }
        guard let lastObservedAt =
            detectionCoordinator.lastObservedAt(
                for: profile.capabilities
            ) ?? profile.lastObservedAt else {
            return "Not currently reporting"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last seen \(formatter.localizedString(for: lastObservedAt, relativeTo: date))"
    }
}

private struct CyclingSensorValueRow: View {
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
