import SwiftUI

struct RideStatsLayoutEditorView: View {
    @Binding var layout: RideStatsLayout
    let capabilities: DeviceScreenConfigurationCapabilities
    let firmwareTarget: String
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Section("Ride Stats Layout") {
            devicePreview

            ForEach(layout.slots.indices, id: \.self) { index in
                HStack {
                    Picker(slotName(index), selection: slotBinding(index)) {
                        ForEach(supportedWidgets) { widget in
                            Text(widget.title).tag(widget)
                        }
                    }
                    Button {
                        moveSlot(at: index, by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(slotName(index)) up")
                    Button {
                        moveSlot(at: index, by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(index == layout.slots.count - 1)
                    .accessibilityLabel("Move \(slotName(index)) down")
                }
                .accessibilityIdentifier("ride-stats-widget-picker-\(index)")
                .accessibilityAction(named: Text("Move up")) {
                    moveSlot(at: index, by: -1)
                }
                .accessibilityAction(named: Text("Move down")) {
                    moveSlot(at: index, by: 1)
                }
            }
            .onMove(perform: moveSlots)

            Button {
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                }
            } label: {
                Label(
                    editMode == .active ? "Done Reordering" : "Reorder Positions",
                    systemImage: "arrow.up.arrow.down"
                )
            }

            Button("Restore Default Layout") {
                restoreDefaultLayout()
            }
        }
        .environment(\.editMode, $editMode)
    }

    private var devicePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            RideStatsDevicePreview(layout: layout, firmwareTarget: firmwareTarget)
            Text("Example values. Smart fields adapt to available sensors during a ride.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var supportedWidgets: [RideStatsWidget] {
        RideStatsWidget.allCases.filter(capabilities.supports)
    }

    private func slotBinding(_ index: Int) -> Binding<RideStatsWidget> {
        Binding(
            get: { layout.slots[index] },
            set: { layout.slots[index] = $0 }
        )
    }

    private func slotName(_ index: Int) -> String {
        switch index {
        case 0: return "Hero"
        case 1: return "Top Left"
        case 2: return "Top Right"
        case 3: return "Middle Left"
        case 4: return "Middle Right"
        case 5: return "Bottom Left"
        default: return "Bottom Right"
        }
    }

    private func moveSlots(from offsets: IndexSet, to destination: Int) {
        var slots = layout.slots
        slots.move(fromOffsets: offsets, toOffset: destination)
        layout.slots = slots
    }

    private func moveSlot(at index: Int, by offset: Int) {
        let destination = index + offset
        guard layout.slots.indices.contains(index),
              layout.slots.indices.contains(destination) else { return }
        layout.slots.swapAt(index, destination)
    }

    private func restoreDefaultLayout() {
        let supported = supportedWidgets
        guard let visibleFallback = supported.first(where: { $0 != .empty })
                ?? supported.first else { return }
        let unsupportedFallback: RideStatsWidget = capabilities.supports(.empty)
            ? .empty : visibleFallback
        var slots = RideStatsLayout.defaultSlots.map {
            capabilities.supports($0) ? $0 : unsupportedFallback
        }
        if !slots.contains(where: { $0 != .empty }) {
            slots[0] = visibleFallback
        }
        layout.slots = slots
    }
}
