import Foundation
import SwiftUI

struct WatchRouteLibraryView: View {
    @ObservedObject var routeLibrary: WatchRouteLibrary

    var body: some View {
        List {
            if routeLibrary.routes.isEmpty {
                ContentUnavailableView(
                    "No Offline Routes",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text(
                        "Send an offline-capable route from Bicino on iPhone."
                    )
                )
            } else {
                ForEach(routeLibrary.routes) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(route.source.label) → \(route.destination.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(routeDistance(route.distanceMeters))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(
                            "Ready for offline ride",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let error = routeLibrary.lastSyncError {
                Text("Last sync failed: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Routes")
        .onAppear { routeLibrary.reload() }
    }

    private func routeDistance(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters.rounded())) m"
    }
}
