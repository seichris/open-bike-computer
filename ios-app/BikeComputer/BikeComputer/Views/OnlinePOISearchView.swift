import MapKit
import SwiftUI

struct OnlinePOICategoryRow: View {
    @ObservedObject var session: OnlinePOISearchSession
    let onToggle: (OnlinePOICategory) -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize = 48.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(OnlinePOICategory.allCases) { category in
                    let selected = session.categories.contains(category)
                    Button { onToggle(category) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: category.symbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(selected ? .white : .blue)
                                .frame(width: iconSize, height: iconSize)
                                .background(selected ? Color.blue : Color.blue.opacity(0.12), in: Circle())
                                .overlay(alignment: .topTrailing) {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .blue)
                                            .background(.blue, in: Circle())
                                    }
                                }
                            Text(category.title)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: max(78, iconSize + 16))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.title)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint("Double tap to toggle this nearby category")
                    .accessibilityIdentifier("online-poi-category-\(category.rawValue)")
                }
            }
            .padding(.vertical, 3)
        }
    }
}

struct OnlinePOIResultsView: View {
    @ObservedObject var session: OnlinePOISearchSession
    let onSearchArea: () -> Void
    @State private var mapsLaunchFailed = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Search this area", action: onSearchArea)
                            .accessibilityIdentifier("online-poi-search-area")
                        Spacer()
                        Button("Clear", action: session.clear)
                            .accessibilityLabel("Clear nearby categories")
                            .accessibilityIdentifier("online-poi-clear")
                    }
                    .font(.subheadline)

                    Text("Within \(Int(session.radius)) m · distances from search center")
                        .font(.caption).foregroundStyle(.secondary)

                    if session.categories.contains(.bicycles) {
                        Text("Bicycle matches use text search. Repair services may be missing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if session.usedCategoryTextFallback {
                        Text("Approximate category matches in this area.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    switch session.state {
                    case .idle:
                        EmptyView()
                    case .loading:
                        ProgressView("Searching nearby…")
                            .frame(maxWidth: .infinity).padding(.vertical)
                    case .failed(let message):
                        Label(message, systemImage: "wifi.exclamationmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    case .loaded:
                        if session.items.isEmpty {
                            Text("No matches returned here. Try another category or search area.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            if let item = session.selectedItem {
                                detailCard(item).id("selected-online-place")
                            }
                            ForEach(session.items, id: \.self) { item in
                                Button { session.select(item) } label: {
                                    resultRow(item)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(session.selectedItem === item ? .isSelected : [])
                                Divider()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
            .accessibilityIdentifier("online-poi-results")
            .onChange(of: session.selectedItem) { item in
                mapsLaunchFailed = false
                if item != nil {
                    withAnimation { proxy.scrollTo("selected-online-place", anchor: .top) }
                }
            }
        }
    }

    private func resultRow(_ item: MKMapItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.selectedItem === item ? "mappin.circle.fill" : "mappin.circle")
                .foregroundStyle(.blue).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name ?? "Place").font(.body).foregroundStyle(.primary)
                if let address = item.placemark.title {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let distance = session.distance(to: item) {
                Text(Measurement(value: distance, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityHint("Show this place on the map")
    }

    private func detailCard(_ item: MKMapItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name ?? "Place").font(.headline)
            if let address = item.placemark.title {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                mapsLaunchFailed = !item.openInMaps()
            } label: {
                Label("Open in Apple Maps", systemImage: "map")
            }
            .accessibilityIdentifier("online-poi-open-maps")
            if mapsLaunchFailed {
                Text("Unable to open Apple Maps. Try again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
