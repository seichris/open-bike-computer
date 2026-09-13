import SwiftUI

struct ConfigurableDeviceScreensSettingsSection: View {
    @ObservedObject var controller: DeviceScreenConfigurationController
    let onAddScreen: () -> Void

    var body: some View {
        Section {
            statusContent

            if let document = controller.draft {
                ForEach(document.instances) { instance in
                    HStack {
                        NavigationLink {
                            DeviceScreenInstanceEditorView(
                                controller: controller,
                                instance: instance
                            )
                        } label: {
                            HStack {
                                Image(systemName: icon(for: instance.type))
                                    .foregroundStyle(instance.enabled ? .primary : .secondary)
                                VStack(alignment: .leading) {
                                    Text(instance.name)
                                    Text(instance.type.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if document.defaultInstanceID == instance.id {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .accessibilityLabel("Default screen")
                                }
                            }
                        }
                        Toggle(
                            "Show \(instance.name)",
                            isOn: enabledBinding(for: instance)
                        )
                        .labelsHidden()
                        .disabled(instance.enabled && enabledInstanceCount == 1)
                    }
                    .accessibilityIdentifier("device-screen-row-\(instance.id)")
                    .contextMenu {
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            try? controller.duplicate(instanceID: instance.id)
                        }
                        .disabled(!canAdd(to: document))
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            controller.remove(instanceID: instance.id)
                        }
                        .disabled(
                            document.instances.count <= 1 ||
                                (instance.enabled && enabledInstanceCount == 1)
                        )
                    }
                }
                .onMove(perform: controller.move)

                Button {
                    onAddScreen()
                } label: {
                    Label("Add Screen", systemImage: "plus")
                }
                .disabled(!canAdd(to: document))
                .accessibilityIdentifier("device-screen-add")

                if controller.canSave {
                    Button("Save to Bicino") {
                        controller.save()
                    }
                    .accessibilityIdentifier("device-screen-save")
                }

                if controller.canDiscardChanges {
                    Button("Cancel Changes", role: .destructive) {
                        controller.reloadDeviceSettings()
                    }
                }
            }
        } header: {
            Text("Device Screens")
        } footer: {
            Text("Drag screens to reorder, add new screens or hide screens")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch controller.state {
        case .loading:
            HStack {
                ProgressView()
                Text("Loading screen settings…")
            }
        case .saving:
            HStack {
                ProgressView()
                Text("Saving all screen settings…")
            }
        case .conflict:
            VStack(alignment: .leading, spacing: 8) {
                Label("The configuration changed on the Bike Computer.", systemImage: "arrow.triangle.2.circlepath")
                HStack {
                    Button("Use Device Version") {
                        controller.reloadDeviceSettings()
                    }
                    Button("Keep My Changes") {
                        controller.keepDraftAfterConflict()
                    }
                }
                .disabled(!controller.canResolveConflict)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") { controller.retry() }
            }
        case .ready:
            EmptyView()
        case .legacyUnsupported:
            Text("This firmware uses the original fixed screen settings.")
                .foregroundStyle(.secondary)
        }
    }

    private func canAdd(to document: DeviceScreenConfigurationDocument) -> Bool {
        guard let capabilities = controller.capabilities else { return false }
        return document.instances.count < Int(capabilities.maximumInstances)
    }

    private var enabledInstanceCount: Int {
        controller.draft?.instances.filter(\.enabled).count ?? 0
    }

    private func enabledBinding(for instance: DeviceScreenInstance) -> Binding<Bool> {
        Binding(
            get: {
                controller.draft?.instances.first(where: { $0.id == instance.id })?.enabled
                    ?? instance.enabled
            },
            set: { controller.setEnabled($0, instanceID: instance.id) }
        )
    }

    private func icon(for type: ConfiguredDeviceScreenType) -> String {
        switch type {
        case .map: return "map"
        case .navigation: return "arrow.triangle.turn.up.right.diamond"
        case .rideStats: return "figure.outdoor.cycle"
        case .mapPlusNavigation: return "location.north.line"
        case .batteryStatus: return "battery.100percent"
        }
    }
}

// The stable Settings root owns presentation; the sheet dismisses only itself.
struct AddDeviceScreenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: DeviceScreenConfigurationController
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(supportedScreenTypes) { type in
                    Button(type.title) {
                        do {
                            try controller.add(
                                type: type,
                                after: controller.draft?.instances.last?.id
                            )
                            dismiss()
                        } catch {
                            errorMessage = String(describing: error)
                        }
                    }
                    .disabled(controller.draft == nil)
                    .accessibilityIdentifier("device-screen-add-type-\(type.rawValue)")
                }
            }
            .navigationTitle("Add Screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var supportedScreenTypes: [ConfiguredDeviceScreenType] {
        guard let capabilities = controller.capabilities else { return [] }
        return ConfiguredDeviceScreenType.allCases.filter(capabilities.supports)
    }
}

private struct DeviceScreenInstanceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bleManager: BLEManager
    @ObservedObject var controller: DeviceScreenConfigurationController
    private let initialInstance: DeviceScreenInstance

    init(
        controller: DeviceScreenConfigurationController,
        instance: DeviceScreenInstance
    ) {
        self.controller = controller
        initialInstance = instance
    }

    private var instance: DeviceScreenInstance {
        controller.draft?.instances.first(where: { $0.id == initialInstance.id })
            ?? initialInstance
    }

    private var instanceBinding: Binding<DeviceScreenInstance> {
        Binding(get: { instance }, set: { controller.update(instance: $0) })
    }

    var body: some View {
        Form {
            Section("Screen") {
                TextField("Name", text: instanceBinding.name)
                Text("\(instance.name.utf8.count) of \(maximumNameBytes) bytes")
                    .font(.caption)
                    .foregroundStyle(
                        instance.name.utf8.count > maximumNameBytes
                            ? .red : .secondary
                    )
                Toggle("Show while cycling", isOn: instanceBinding.enabled)
                    .disabled(isOnlyEnabledScreen)
                Button("Make Default") {
                    controller.setDefault(instanceID: instance.id)
                }
                .disabled(!instance.enabled || isDefault)
            }

            if instance.type == .map || instance.type == .mapPlusNavigation,
               instance.mapProfile != nil {
                DeviceScreenMapProfileEditor(
                    profile: mapProfileBinding,
                    type: instance.type,
                    supportsNavigationOrientation: bleManager.supportsMapNavigationOrientation
                )
            }

            if instance.type == .rideStats,
               instance.rideStatsLayout != nil,
               let capabilities = controller.capabilities {
                RideStatsLayoutEditorView(
                    layout: rideStatsLayoutBinding,
                    capabilities: capabilities
                )
            }

            Section {
                Button("Duplicate Screen") {
                    try? controller.duplicate(instanceID: instance.id)
                }
                .disabled(!canDuplicate)
                Button("Delete Screen", role: .destructive) {
                    controller.remove(instanceID: instance.id)
                    dismiss()
                }
                .disabled(!canDelete)
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isDefault: Bool {
        controller.draft?.defaultInstanceID == instance.id
    }

    private var isOnlyEnabledScreen: Bool {
        instance.enabled &&
            controller.draft?.instances.filter(\.enabled).count == 1
    }

    private var canDuplicate: Bool {
        guard let capabilities = controller.capabilities else { return false }
        return (controller.draft?.instances.count ?? 0) <
            Int(capabilities.maximumInstances)
    }

    private var canDelete: Bool {
        guard let draft = controller.draft,
              draft.instances.count > 1 else { return false }
        return !instance.enabled || draft.instances.filter(\.enabled).count > 1
    }

    private var maximumNameBytes: Int {
        Int(controller.capabilities?.maximumNameBytes ?? UInt8(
            RideBLEGeneratedProtocolV1.maximumScreenConfigurationNameBytes
        ))
    }

    private var mapProfileBinding: Binding<DeviceScreenMapProfile> {
        Binding(
            get: { instance.mapProfile ?? .mapDefault },
            set: { profile in
                var updated = instance
                updated.mapProfile = profile
                controller.update(instance: updated)
            }
        )
    }

    private var rideStatsLayoutBinding: Binding<RideStatsLayout> {
        Binding(
            get: { instance.rideStatsLayout ?? RideStatsLayout() },
            set: { layout in
                var updated = instance
                updated.rideStatsLayout = layout
                controller.update(instance: updated)
            }
        )
    }
}

private struct DeviceScreenMapProfileEditor: View {
    @Binding var profile: DeviceScreenMapProfile
    let type: ConfiguredDeviceScreenType
    let supportsNavigationOrientation: Bool

    private let visibilityOptions: [(String, UInt32)] = [
        ("Buildings", 1 << 0), ("Green Space", 1 << 1),
        ("Paths", 1 << 2), ("Major Roads", 1 << 3),
        ("Local Streets", 1 << 4), ("Water", 1 << 5),
        ("Railways", 1 << 6), ("Other Areas", 1 << 7),
        ("Route Line", 1 << 8), ("Current Position", 1 << 9),
        ("Service Roads", 1 << 10), ("Tracks", 1 << 11),
    ]

    var body: some View {
        Section("Map Detail") {
            Stepper("Detail Level: \(profile.detailLevel)", value: $profile.detailLevel, in: 0...2)
            Stepper("Minimum Polygon: \(profile.minimumPolygonSize)", value: $profile.minimumPolygonSize, in: 0...50)
            Stepper("Route Width: \(profile.routeLineWidth)", value: $profile.routeLineWidth, in: 2...48)
            Stepper("Street Width: \(profile.streetLineWidth)", value: $profile.streetLineWidth, in: 1...24)
            Stepper("Position Scale: \(profile.positionMarkerScale)", value: $profile.positionMarkerScale, in: 1...5)
            Stepper("Zoom: \(profile.zoomLevel)", value: $profile.zoomLevel, in: 0...5)
        }

        Section("Map Content") {
            ForEach(visibilityOptions, id: \.1) { option in
                Toggle(option.0, isOn: visibilityBinding(option.1))
            }
        }

        Section("Labels") {
            Toggle("Show Labels", isOn: labelsVisibleBinding)
            Picker("Density", selection: $profile.labelDensity) {
                Text("Low").tag(UInt8(1))
                Text("Medium").tag(UInt8(2))
                Text("High").tag(UInt8(3))
            }
            .disabled(profile.labelDensity == 0)
            Picker("Language", selection: $profile.labelLanguageMode) {
                Text("Local").tag(UInt8(0))
                Text("Preferred").tag(UInt8(1))
                Text("Local + Preferred").tag(UInt8(2))
            }
            Picker("Text Size", selection: $profile.labelTextSize) {
                Text("Small").tag(UInt8(0))
                Text("Medium").tag(UInt8(1))
                Text("Large").tag(UInt8(2))
            }
            Picker("Orientation", selection: $profile.labelOrientation) {
                Text("Follow Roads").tag(UInt8(0))
                Text("Keep Upright").tag(UInt8(1))
            }
        }

        if type == .map || supportsNavigationOrientation {
            Section("Orientation") {
                Picker("Rotation", selection: $profile.rotationMode) {
                    Text("North Up").tag(UInt8(0))
                    Text("Course Up").tag(UInt8(1))
                }
            }
        }
        if type == .mapPlusNavigation {
            Section("Navigation View") {
                Toggle("Bird’s-Eye View", isOn: $profile.birdsEyeEnabled)
                Picker("Perspective", selection: $profile.birdsEyePerspective) {
                    ForEach(UInt8(0)..<UInt8(5), id: \.self) { value in
                        Text("Level \(Int(value) + 1)").tag(value)
                    }
                }
                Toggle("3D Buildings", isOn: $profile.buildings3DEnabled)
            }
        }
    }

    private func visibilityBinding(_ mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { profile.visibilityMask & mask != 0 },
            set: { enabled in
                if enabled {
                    profile.visibilityMask |= mask
                } else {
                    profile.visibilityMask &= ~mask
                }
            }
        )
    }

    private var labelsVisibleBinding: Binding<Bool> {
        Binding(
            get: { profile.labelDensity > 0 },
            set: { profile.labelDensity = $0 ? max(profile.labelDensity, 2) : 0 }
        )
    }
}
