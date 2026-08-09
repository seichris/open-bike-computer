import Foundation
import SwiftUI

struct WatchRouteLibraryView: View {
    @ObservedObject var routeLibrary: WatchRouteLibrary
    @ObservedObject var navigationManager: WatchNavigationManager
    @State private var pendingRoute: PlannedRouteSummaryV1?

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
                    Button {
                        pendingRoute = route
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(
                                "\(route.source.label) → \(route.destination.label)"
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(routeDistance(route.distanceMeters))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Label(
                                "Ready for offline navigation",
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption2)
                            .foregroundStyle(.green)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = routeLibrary.lastSyncError {
                Text("Last sync failed: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Offline Navigation")
        .onAppear { routeLibrary.reload() }
        .confirmationDialog(
            "Start Navigation?",
            isPresented: pendingRoutePresented,
            titleVisibility: .visible,
            presenting: pendingRoute
        ) { route in
            Button("Start Navigation") {
                pendingRoute = nil
                navigationManager.startConfirmedOffline(routeID: route.id)
            }
            Button("Cancel", role: .cancel) {
                pendingRoute = nil
            }
        } message: { route in
            Text(
                "Navigate \(route.name) using the route saved on this Watch?"
            )
        }
    }

    private var pendingRoutePresented: Binding<Bool> {
        Binding(
            get: { pendingRoute != nil },
            set: { isPresented in
                if !isPresented { pendingRoute = nil }
            }
        )
    }

    private func routeDistance(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters.rounded())) m"
    }
}
