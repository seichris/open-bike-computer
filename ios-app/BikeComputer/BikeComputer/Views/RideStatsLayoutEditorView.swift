import SwiftUI

struct RideStatsLayoutEditorView: View {
    @Binding var layout: RideStatsLayout
    let capabilities: DeviceScreenConfigurationCapabilities
    @State private var editMode: EditMode = .inactive

    private let compactColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

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
            VStack(spacing: 10) {
                previewCell(index: 0, hero: true)
                LazyVGrid(columns: compactColumns, spacing: 8) {
                    ForEach(1..<RideStatsLayout.slotCount, id: \.self) { index in
                        previewCell(index: index, hero: false)
                    }
                }
            }
            .padding(14)
            .foregroundStyle(.white)
            .background(.black, in: RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 2)
            }
            .aspectRatio(410.0 / 502.0, contentMode: .fit)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bike Computer Ride Stats preview")
        }
        .padding(.vertical, 4)
    }

    private func previewCell(index: Int, hero: Bool) -> some View {
        let widget = layout.slots[index]
        return VStack(spacing: 1) {
            Text(sampleValue(for: widget))
                .font(hero ? .system(size: 36, weight: .semibold, design: .rounded) :
                        .system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(widget.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: hero ? 68 : 42)
        .background(Color.white.opacity(hero ? 0.12 : 0.07),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("ride-stats-preview-slot-\(index)")
        .accessibilityLabel("\(slotName(index)), \(widget.title), sample \(sampleValue(for: widget))")
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

    private func sampleValue(for widget: RideStatsWidget) -> String {
        switch widget {
        case .empty: return "—"
        case .speed, .averageSpeed, .maximumSpeed: return "32.1"
        case .heartRate, .averageHeartRate: return "151"
        case .heartRateZone: return "ZONE 4"
        case .distance, .routeRemaining: return "12.3"
        case .movingTime, .elapsedTime: return "1:02:03"
        case .altitude: return "88"
        case .power: return "245"
        case .cadence: return "88"
        case .calories: return "412"
        case .smartMetric1: return "24.5"
        case .smartMetric2: return "142"
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
