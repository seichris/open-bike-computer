import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// Display-only data. In particular, no archive or second coordinate cache is
/// retained after construction of the MapKit overlay.
struct SavedRouteMapPreview {
    let identity: WatchRouteIdentityV1
    let displayName: String
    let sourceLabel: String
    let destinationLabel: String
    let distanceMeters: CLLocationDistance
    let providerID: String
    let attribution: String
    let sourceURL: URL?
    let createdAt: Date
    let deleteAfter: Date?
    let overlay: MapSavedRouteOverlay

    var layoutIdentity: String {
        "\(identity.routeID.uuidString)|\(identity.revision)|\(identity.contentHash)"
    }
}

@MainActor
enum SavedRouteMapPreviewFactory {
    static func make(
        _ selection: SavedRouteMapSelection,
        now: () -> Date = Date.init,
        convert: @MainActor (CLLocationCoordinate2D) -> CLLocationCoordinate2D =
            displayCoordinate
    ) throws -> SavedRouteMapPreview {
        try checkExpiry(selection, now: now())
        let route = selection.route
        guard selection.identity.routeID == route.id,
              selection.identity.revision == route.revision,
              (2...NavigationRouteLimitsV1.production.maximumPoints)
                .contains(route.points.count) else {
            throw SavedRouteMapError.invalidGeometry(selection.displayName)
        }

        // Convert once, at the iPhone presentation boundary. Never mutate the
        // archive, request directions, reparse GPX, or contact the provider.
        let coordinates = try route.points.map { point in
            guard point.isValid else {
                throw SavedRouteMapError.invalidGeometry(selection.displayName)
            }
            let coordinate = convert(CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ))
            guard CLLocationCoordinate2DIsValid(coordinate),
                  coordinate.latitude.isFinite,
                  coordinate.longitude.isFinite else {
                throw SavedRouteMapError.invalidGeometry(selection.displayName)
            }
            return coordinate
        }
        guard let first = coordinates.first,
              coordinates.contains(where: {
                  $0.latitude != first.latitude || $0.longitude != first.longitude
              }) else {
            throw SavedRouteMapError.invalidGeometry(selection.displayName)
        }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let bounds = polyline.boundingMapRect
        guard !bounds.isNull,
              [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height]
                .allSatisfy(\.isFinite) else {
            throw SavedRouteMapError.invalidGeometry(selection.displayName)
        }
        try checkExpiry(selection, now: now())
        return SavedRouteMapPreview(
            identity: selection.identity,
            displayName: selection.displayName,
            sourceLabel: route.source.label,
            destinationLabel: route.destination.label,
            distanceMeters: route.distanceMeters,
            providerID: route.provider.providerID,
            attribution: route.provider.attribution,
            sourceURL: route.sourceReference.flatMap { URL(string: $0.canonicalURL) },
            createdAt: selection.createdAt,
            deleteAfter: selection.deleteAfter,
            overlay: MapSavedRouteOverlay(identity: selection.identity, polyline: polyline)
        )
    }

    static func displayCoordinate(
        _ coordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        guard CoordinateConverter.isInChina(
            lat: coordinate.latitude,
            lon: coordinate.longitude
        ) else { return coordinate }
        return CoordinateConverter.wgs84ToGCJ02(coordinate: coordinate)
    }

    private static func checkExpiry(_ selection: SavedRouteMapSelection, now: Date) throws {
        if let deadline = selection.deleteAfter, now >= deadline {
            throw SavedRouteMapError.expired(selection.displayName)
        }
    }
}

/// A scoped Settings-to-main-map callback. The default does not silently accept
/// selections. Both the exact archive read and the presentation callback must
/// succeed before ContentView dismisses Settings.
nonisolated struct SavedRouteMapAction: Sendable {
    let isNavigationActive: Bool
    let show: @MainActor @Sendable (SavedRouteMapSelection) throws -> Void

    @MainActor
    func perform(load: () throws -> SavedRouteMapSelection) throws {
        guard !isNavigationActive else { throw SavedRouteMapError.navigationActive }
        try show(try load())
    }
}

private nonisolated struct SavedRouteMapActionKey: EnvironmentKey {
    static let defaultValue: SavedRouteMapAction? = nil
}

extension EnvironmentValues {
    var savedRouteMapAction: SavedRouteMapAction? {
        get { self[SavedRouteMapActionKey.self] }
        set { self[SavedRouteMapActionKey.self] = newValue }
    }
}

/// Include identity so equally tall successive route cards still publish their
/// first layout. A delayed layout from a previous preview cannot fit a new one.
nonisolated struct SavedRoutePreviewLayout: Equatable, Sendable {
    let identity: String
    let height: CGFloat
}

nonisolated struct SavedRoutePreviewLayoutKey: PreferenceKey {
    static let defaultValue: SavedRoutePreviewLayout? = nil

    static func reduce(value: inout SavedRoutePreviewLayout?, nextValue: () -> SavedRoutePreviewLayout?) {
        value = nextValue() ?? value
    }
}

struct SavedRouteMapPreviewCard: View {
    let preview: SavedRouteMapPreview
    let maximumHeight: CGFloat
    let onHide: () -> Void
    var onStart: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .vertical) {
            contents
                .fixedSize(horizontal: false, vertical: true)
            ScrollView { contents }
                .frame(maxHeight: maximumHeight, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedRouteMapPreview")
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.displayName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide \(preview.displayName) from map")
                .accessibilityHint("Closes the preview without deleting the saved route")
                .accessibilityIdentifier("hideSavedRouteMapPreview")
            }
            Text(distance)
                .font(.subheadline)
            Text(preview.attribution)
                .font(.caption).foregroundStyle(.secondary)
            if let onStart {
                Button(action: onStart) {
                    Label("Start Offline Navigation", systemImage: "location.fill")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("startSavedRoutePreviewOffline")
                Text("Follows the saved route; no online rerouting or offline map tiles are downloaded.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if preview.providerID == RouteProviderPolicyV1.strava.providerID,
               let url = preview.sourceURL {
                Link("View on Strava", destination: url)
                    .font(.caption)
            }
            if let deadline = preview.deleteAfter {
                Text("Expires \(deadline.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var distance: String {
        let formatter = MKDistanceFormatter()
        return formatter.string(fromDistance: preview.distanceMeters)
    }
}
