import Combine
import Foundation
import MapKit
import SwiftUI
import UIKit

// Boundary doubles only: compile the production library, archive store,
// preview factory, and MapView coordinator in this executable.
@MainActor
final class PhoneWatchConnectivityCoordinator: ObservableObject {
    struct State { var isReachable = false }
    @Published var state = State()
    var onRouteAcknowledgement: ((WatchRouteSyncMessageV1) -> Void)?
    private(set) var sideEffects = 0
    func transferRoute(_ record: InstalledNavigationRouteV1) -> UUID? {
        sideEffects += 1
        return UUID()
    }
    func sendRouteImmediately(_ record: InstalledNavigationRouteV1) {
        sideEffects += 1
    }
    func cancelRouteTransfers(_ identity: WatchRouteIdentityV1) -> Int {
        sideEffects += 1
        return 1
    }
    func requestRouteDeletion(_ identity: WatchRouteIdentityV1) -> UUID? {
        sideEffects += 1
        return UUID()
    }
    func updateRouteDisplayNames(_ entries: [WatchRouteDisplayNameV1]) throws {
        sideEffects += 1
    }
}

struct OfflineMapBounds {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double
}

@MainActor
private final class PreviewClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class LibraryFixture {
    let clock = PreviewClock()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("saved-route-preview-\(UUID().uuidString)")
    let suite = "saved-route-preview.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: NavigationRouteFileStoreV1
    let connectivity = PhoneWatchConnectivityCoordinator()
    let library: PhoneRouteLibrary

    init() {
        defaults = UserDefaults(suiteName: suite)!
        store = NavigationRouteFileStoreV1(rootDirectory: root)
        let clock = self.clock
        library = PhoneRouteLibrary(
            store: store,
            connectivity: connectivity,
            defaults: defaults,
            now: { clock.now }
        )
    }

    func install(_ archive: NavigationRouteArchiveV1) throws -> PlannedRouteSummaryV1 {
        try library.importArchive(archive.encoded(purpose: .offlineNavigation, now: clock.now))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class PreviewRecordingMap: MKMapView {
    private var items: [MKOverlay] = []
    private var mode: MKUserTrackingMode = .none
    private var selection: [MKAnnotation] = []
    private var renderers: [ObjectIdentifier: MKOverlayRenderer] = [:]
    private(set) var additions = 0
    private(set) var removals = 0
    private(set) var fits: [(MKMapRect, UIEdgeInsets)] = []
    private(set) var regionUpdates = 0
    private(set) var cameraUpdates = 0
    private(set) var levels: [MKOverlayLevel] = []

    override var overlays: [MKOverlay] { items }
    override var userTrackingMode: MKUserTrackingMode {
        get { mode }
        set { mode = newValue }
    }
    override var selectedAnnotations: [MKAnnotation] {
        get { selection }
        set { selection = newValue }
    }
    override func setUserTrackingMode(_ mode: MKUserTrackingMode, animated: Bool) {
        self.mode = mode
    }
    override func addOverlay(_ overlay: MKOverlay, level: MKOverlayLevel) {
        additions += 1
        items.append(overlay)
        levels.append(level)
    }
    override func addOverlays(_ overlays: [MKOverlay], level: MKOverlayLevel) {
        for overlay in overlays { addOverlay(overlay, level: level) }
    }
    override func removeOverlay(_ overlay: MKOverlay) {
        if items.contains(where: { $0 === overlay }) { removals += 1 }
        items.removeAll { $0 === overlay }
        renderers.removeValue(forKey: ObjectIdentifier(overlay as AnyObject))
    }
    override func removeOverlays(_ overlays: [MKOverlay]) {
        for overlay in overlays { removeOverlay(overlay) }
    }
    override func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        let key = ObjectIdentifier(overlay as AnyObject)
        if let renderer = renderers[key] { return renderer }
        guard let renderer = delegate?.mapView?(self, rendererFor: overlay) else { return nil }
        renderers[key] = renderer
        return renderer
    }
    override func setVisibleMapRect(_ mapRect: MKMapRect, edgePadding insets: UIEdgeInsets, animated: Bool) {
        fits.append((mapRect, insets))
    }
    override func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        regionUpdates += 1
    }

    func resetRegionUpdates() {
        regionUpdates = 0
    }
    override func setCamera(_ camera: MKMapCamera, animated: Bool) {
        cameraUpdates += 1
    }
}

private final class PreviewRecordingRoute: MKRoute {
    private let line: MKPolyline
    init(_ line: MKPolyline) {
        self.line = line
        super.init()
    }
    override var polyline: MKPolyline { line }
}

@main
@MainActor
struct SavedRouteMapPreviewTests {
    private static var checks = 0
    private static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async throws {
        try testLibraryReadsAndWatchIndependence()
        try testMissingReplacedAndCorruptArchives()
        try testExpiryAndDeletion()
        try testFactoryAndCoordinateBoundary()
        try testOverlayOwnershipAndCamera()
        try testSettingsAction()
        print("Saved route map integration: \(checks) checks passed")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @discardableResult
    private static func failure(_ body: () throws -> Void) -> String {
        do {
            try body()
            preconditionFailure("Expected operation to fail")
        } catch {
            checks += 1
            return error.localizedDescription
        }
    }

    private static func route(
        id: UUID = UUID(), revision: UInt32 = 1,
        provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.importedGPX,
        name: String = "Canal ride", points: [RouteCoordinateV1]? = nil
    ) -> NavigationRouteV1 {
        let points = points ?? [
            RouteCoordinateV1(latitude: 51.5, longitude: -0.1),
            RouteCoordinateV1(latitude: 51.501, longitude: -0.099),
            RouteCoordinateV1(latitude: 51.502, longitude: -0.098)
        ]
        return NavigationRouteV1(
            id: id, revision: revision, provider: provider,
            sourceReference: provider == RouteProviderPolicyV1.strava ?
                RouteSourceReferenceV1(providerID: provider.providerID,
                    externalRouteID: "123456", canonicalURL: "https://www.strava.com/routes/123456") : nil,
            localeIdentifier: "en_US", transportType: .cycling,
            source: RouteEndpointV1(coordinate: points[0], label: "Start"),
            destination: RouteEndpointV1(coordinate: points[points.count - 1], label: "Finish"),
            bounds: RouteBoundsV1.enclosing(points)!, distanceMeters: 300,
            expectedTravelTimeSeconds: 90, name: name, points: points,
            steps: [NavigationRouteStepV1(id: 1, geometryStartIndex: 0,
                geometryEndIndex: points.count - 1, instruction: "Continue",
                maneuver: .straight, distanceMeters: 300)],
            normalizationVersion: 1
        )
    }

    private static func archive(_ route: NavigationRouteV1, deadline: Date? = nil) throws -> NavigationRouteArchiveV1 {
        try NavigationRouteArchiveV1.create(route: route, createdAt: timestamp,
            deleteAfter: deadline, purpose: .offlineNavigation)
    }

    private static func selection(_ archive: NavigationRouteArchiveV1, name: String = "Local alias") -> SavedRouteMapSelection {
        SavedRouteMapSelection(identity: WatchRouteIdentityV1(archive: archive),
            displayName: name, route: archive.route, createdAt: archive.createdAt,
            deleteAfter: archive.deleteAfter)
    }

    private static func testLibraryReadsAndWatchIndependence() throws {
        for provider in [RouteProviderPolicyV1.importedGPX, RouteProviderPolicyV1.strava] {
            let fixture = LibraryFixture()
            defer { fixture.cleanup() }
            let saved = try archive(route(provider: provider),
                deadline: provider == RouteProviderPolicyV1.strava ? timestamp.addingTimeInterval(600) : nil)
            let summary = try fixture.install(saved)
            _ = fixture.library.rename(summary, to: "My renamed ride")
            let record = try fixture.store.record(matching: WatchRouteIdentityV1(archive: saved), now: fixture.clock.now)
            let data = try Data(contentsOf: record.fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: record.fileURL.path)
            let beforeDefaults = fixture.defaults.dictionaryRepresentation()
            let beforeWatch = fixture.connectivity.sideEffects
            let loaded = try fixture.library.mapSelection(for: summary)
            check(loaded.displayName == "My renamed ride", "Preview uses the local alias")
            check(loaded.identity == WatchRouteIdentityV1(archive: saved), "Preview reads the exact identity")
            check(loaded.route == saved.route, "Preview keeps canonical archive geometry and metadata")
            check(loaded.createdAt == saved.createdAt && loaded.deleteAfter == saved.deleteAfter, "Preview keeps retention metadata")
            check(try Data(contentsOf: record.fileURL) == data, "Preview does not rewrite the archive")
            let afterAttributes = try FileManager.default.attributesOfItem(atPath: record.fileURL.path)
            check(attributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date, "Preview does not touch the archive")
            check(NSDictionary(dictionary: beforeDefaults).isEqual(to: fixture.defaults.dictionaryRepresentation()), "Preview does not write preferences")
            check(fixture.connectivity.sideEffects == beforeWatch, "Preview has no Watch side effects")

            let identity = loaded.identity
            fixture.connectivity.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
                operation: .acknowledge, identity: identity, status: .rejected, errorCode: "test_rejection"))
            let rejectedEffects = fixture.connectivity.sideEffects
            _ = try fixture.library.mapSelection(for: summary)
            check(fixture.connectivity.sideEffects == rejectedEffects, "Rejected Watch sync does not block local preview")
            try fixture.library.sendToWatch(summary)
            for status in [WatchRouteSyncStatusV1.ready, .rejected] {
                let effects = fixture.connectivity.sideEffects
                _ = try fixture.library.mapSelection(for: summary)
                check(fixture.connectivity.sideEffects == effects, "Transferring/ready reads have no Watch effects")
                fixture.connectivity.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
                    operation: .acknowledge, identity: identity, status: status,
                    errorCode: status == .rejected ? "test_rejection" : nil))
            }
        }
    }

    private static func testMissingReplacedAndCorruptArchives() throws {
        let fixture = LibraryFixture()
        defer { fixture.cleanup() }
        let first = try archive(route())
        let summary = try fixture.install(first)
        let missing = PlannedRouteSummaryV1(archive: try archive(route()))
        failure { _ = try fixture.library.mapSelection(for: missing) }
        let otherHash = PlannedRouteSummaryV1(archive: try archive(route(id: first.routeID, name: "Other content")))
        failure { _ = try fixture.library.mapSelection(for: otherHash) }
        let newArchive = try archive(route(id: first.routeID, revision: 2))
        let newest = try fixture.install(newArchive)
        failure { _ = try fixture.library.mapSelection(for: summary) }
        check(try fixture.library.mapSelection(for: newest).identity == WatchRouteIdentityV1(archive: newArchive), "Stale read never silently substitutes the new revision")
        let record = try fixture.store.record(matching: WatchRouteIdentityV1(archive: newArchive), now: timestamp)
        try Data("corrupt archive".utf8).write(to: record.fileURL)
        let message = failure { _ = try fixture.library.mapSelection(for: newest) }
        check(!message.isEmpty, "Corruption returns a user-visible explanation")
        check(fixture.library.routes.isEmpty, "Corrupt archive is pruned through normal library reload")
    }

    private static func testExpiryAndDeletion() throws {
        let fixture = LibraryFixture()
        defer { fixture.cleanup() }
        let deadline = timestamp.addingTimeInterval(60)
        let saved = try archive(route(provider: RouteProviderPolicyV1.strava), deadline: deadline)
        let summary = try fixture.install(saved)
        fixture.clock.now = deadline.addingTimeInterval(-0.001)
        _ = try fixture.library.mapSelection(for: summary)
        fixture.clock.now = deadline
        let message = failure { _ = try fixture.library.mapSelection(for: summary) }
        check(message == SavedRouteMapError.expired(fixture.library.displayName(for: summary)).localizedDescription, "Exact deadline returns an expiry error")
        check(fixture.library.routes.isEmpty, "Expiry publishes removal to existing previews")
        let gpx = try archive(route())
        let local = try fixture.install(gpx)
        try fixture.library.delete(local)
        failure { _ = try fixture.library.mapSelection(for: local) }
        check(fixture.library.routes.isEmpty, "Deleted routes cannot remain selected")
    }

    private static func testFactoryAndCoordinateBoundary() throws {
        for points in [
            [RouteCoordinateV1(latitude: 51.5, longitude: -0.1), RouteCoordinateV1(latitude: 51.501, longitude: -0.099)],
            [RouteCoordinateV1(latitude: 31.23, longitude: 121.47), RouteCoordinateV1(latitude: 31.231, longitude: 121.471)]
        ] {
            let saved = try archive(route(points: points))
            let preview = try SavedRouteMapPreviewFactory.make(selection(saved), now: { timestamp })
            var actual = Array(repeating: CLLocationCoordinate2D(), count: points.count)
            preview.overlay.polyline.getCoordinates(&actual, range: NSRange(location: 0, length: actual.count))
            for index in points.indices {
                let expected = SavedRouteMapPreviewFactory.displayCoordinate(CLLocationCoordinate2D(latitude: points[index].latitude, longitude: points[index].longitude))
                check(abs(actual[index].latitude - expected.latitude) < 1e-7 && abs(actual[index].longitude - expected.longitude) < 1e-7, "Ordered coordinates convert exactly once at display boundary")
            }
            check(saved.route.points == points, "Factory leaves WGS-84 archive points unchanged")
            check(preview.displayName == "Local alias" && preview.sourceLabel == "Start" && preview.attribution == saved.route.provider.attribution, "Factory preserves display metadata")
            failure {
                _ = try SavedRouteMapPreviewFactory.make(selection(saved), now: { timestamp }, convert: { _ in
                    CLLocationCoordinate2D(latitude: .nan, longitude: 0)
                })
            }
        }
        let deadline = timestamp.addingTimeInterval(10)
        let strava = try archive(route(provider: RouteProviderPolicyV1.strava), deadline: deadline)
        failure { _ = try SavedRouteMapPreviewFactory.make(selection(strava), now: { deadline }) }
        var time = timestamp
        failure {
            _ = try SavedRouteMapPreviewFactory.make(selection(strava), now: { time }, convert: { coordinate in
                time = deadline
                return coordinate
            })
        }
        let largePoints = (0..<50_000).map {
            RouteCoordinateV1(latitude: 51.5 + Double($0) * 0.0000001, longitude: -0.1)
        }
        let largeRoute = route(points: largePoints)
        let large = SavedRouteMapSelection(identity: WatchRouteIdentityV1(routeID: largeRoute.id, revision: 1, contentHash: String(repeating: "a", count: 64)), displayName: "Large GPX", route: largeRoute, createdAt: timestamp, deleteAfter: nil)
        var conversions = 0
        let preview = try SavedRouteMapPreviewFactory.make(large, now: { timestamp }, convert: {
            conversions += 1
            return $0
        })
        let map = PreviewRecordingMap(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = MapViewContainer.Coordinator()
        for _ in 0..<100 { update(coordinator, map: map, preview: preview.overlay) }
        check(conversions == 50_000, "Maximum-size GPX converts once, not on view updates")
        check(map.additions == 1 && map.fits.count == 1, "Maximum-size GPX reuses one overlay and one fit")
        let tooLargeRoute = route(points: largePoints + [largePoints.last!])
        let tooLarge = SavedRouteMapSelection(identity: WatchRouteIdentityV1(routeID: tooLargeRoute.id, revision: 1, contentHash: large.identity.contentHash), displayName: "Too large", route: tooLargeRoute, createdAt: timestamp, deleteAfter: nil)
        failure { _ = try SavedRouteMapPreviewFactory.make(tooLarge, now: { timestamp }) }
    }

    private static func update(
        _ coordinator: MapViewContainer.Coordinator, map: PreviewRecordingMap,
        preview: MapSavedRouteOverlay? = nil, route: MKRoute? = nil,
        alternatives: [MapRouteAlternative] = [], selected: UUID? = nil,
        navigating: Bool = false, calculating: Bool = false,
        authorized: Bool = true, padding: CGFloat? = 300
    ) {
        coordinator.mapView = map
        coordinator.isNavigating = navigating
        coordinator.isUserLocationAuthorized = authorized
        map.delegate = coordinator
        coordinator.updateRouteOverlays(on: map, route: route, alternatives: alternatives,
            selectedAlternativeID: selected, routePlanningBottomPadding: 300,
            location: nil, simulatedPosition: nil, isSimulationMode: false,
            isNavigating: navigating, isUserLocationAuthorized: authorized,
            isFreePanActive: coordinator.isFreePanActive(mapView: map,
                isOfflineMapSelectionActive: coordinator.offlineMapSelectionFrame != nil,
                includesSavedRoutePreview: false),
            savedRoutePreview: preview, savedRoutePreviewBottomPadding: padding,
            isRouteCalculationActive: calculating)
    }

    private static func testOverlayOwnershipAndCamera() throws {
        let saved = try archive(route())
        let preview = try SavedRouteMapPreviewFactory.make(selection(saved), now: { timestamp })
        let map = PreviewRecordingMap(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        map.resetRegionUpdates()
        let coordinator = MapViewContainer.Coordinator()
        let unrelated = MKPolyline(coordinates: [CLLocationCoordinate2D(latitude: 0, longitude: 0), CLLocationCoordinate2D(latitude: 0.1, longitude: 0.1)], count: 2)
        map.addOverlay(unrelated, level: .aboveLabels)
        update(coordinator, map: map, preview: preview.overlay, padding: nil)
        check(map.fits.isEmpty && map.userTrackingMode == .none, "Wait for measured layout without following location")
        update(coordinator, map: map, preview: preview.overlay)
        check(map.fits.count == 1 && map.fits[0].1.bottom == 300, "Fit once using actual card padding")
        let owned = coordinator.displayedSavedRouteOverlay
        let beforeAdds = map.additions
        let beforeRemoves = map.removals
        update(coordinator, map: map, preview: preview.overlay, padding: 330)
        check(map.additions == beforeAdds && map.removals == beforeRemoves && map.fits.count == 1, "Ordinary layout update does not rebuild or refit")
        check(coordinator.displayedSavedRouteOverlay === owned, "Unchanged immutable identity reuses polyline")
        coordinator.updateUserTrackingMode(mapView: map, isNavigating: false, isOfflineMapSelectionActive: false)
        coordinator.updateInitialRegionIfNeeded(mapView: map, location: CLLocation(latitude: 40, longitude: 0), simulatedPosition: nil, isSimulationMode: false,
            isFreePanActive: coordinator.isFreePanActive(mapView: map, isOfflineMapSelectionActive: false))
        check(map.userTrackingMode == .none && map.regionUpdates == 0, "Location changes cannot steal preview camera")
        let renderer = coordinator.mapView(map, rendererFor: preview.overlay.polyline) as! MKPolylineRenderer
        check(renderer.lineWidth == 4 && abs(renderer.alpha - 0.65) < 0.001 && renderer.lineCap == .round && renderer.lineJoin == .round, "Saved route has distinct rounded thinner styling")
        check(map.levels.last == .aboveRoads, "Saved route is above roads")

        let revision = MapSavedRouteOverlay(identity: WatchRouteIdentityV1(routeID: saved.routeID, revision: 2, contentHash: saved.contentHash), polyline: preview.overlay.polyline)
        update(coordinator, map: map, preview: revision)
        check(map.fits.count == 2, "Same UUID with a new revision fits anew")
        let changedHash = MapSavedRouteOverlay(identity: WatchRouteIdentityV1(routeID: saved.routeID, revision: 2, contentHash: String(repeating: "b", count: 64)), polyline: preview.overlay.polyline)
        update(coordinator, map: map, preview: changedHash)
        check(map.fits.count == 3, "Same UUID and revision with changed hash is a new preview")
        update(coordinator, map: map)
        check(map.overlays.count == 1 && map.overlays[0] === unrelated, "Hide removes only the saved overlay")
        check(map.userTrackingMode == .follow && coordinator.displayedSavedRouteIdentity == nil, "Hide releases identity and restores permitted follow")
        update(coordinator, map: map, preview: preview.overlay)
        map.selectedAnnotations = [DestinationAnnotation()]
        update(coordinator, map: map)
        check(map.userTrackingMode == .none, "Hide preserves destination free pan")
        map.selectedAnnotations = []
        update(coordinator, map: map, preview: preview.overlay)
        update(coordinator, map: map, authorized: false)
        check(map.userTrackingMode == .none, "Hide does not follow without location authorization")
        update(coordinator, map: map, preview: preview.overlay)
        coordinator.offlineMapSelectionFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        update(coordinator, map: map, preview: preview.overlay)
        check(coordinator.displayedSavedRouteOverlay == nil && map.userTrackingMode == .none, "Offline-area selection takes control without destroying unrelated overlays")
        coordinator.offlineMapSelectionFrame = nil

        let navigation = PreviewRecordingRoute(preview.overlay.polyline)
        let alternativeID = UUID()
        let alternatives = [MapRouteAlternative(id: alternativeID, route: navigation)]
        update(coordinator, map: map, preview: preview.overlay, alternatives: alternatives)
        check(coordinator.displayedSavedRouteOverlay == nil && coordinator.lastRouteAlternatives == alternatives, "Calculated alternatives outrank saved previews")
        let foreignRenderer = map.renderer(for: unrelated) as! MKPolylineRenderer
        foreignRenderer.lineWidth = 17
        coordinator.updateSelectedRouteAlternative(alternativeID, on: map)
        check(foreignRenderer.lineWidth == 17, "Alternative selection does not restyle foreign polylines")
        update(coordinator, map: map, preview: preview.overlay, route: navigation, alternatives: alternatives, navigating: true)
        check(coordinator.lastRoute === navigation && coordinator.lastRouteAlternatives.isEmpty && coordinator.displayedSavedRouteOverlay == nil, "Active navigation beats even late alternatives")
        let navigationAdds = map.additions
        let navigationRemoves = map.removals
        update(coordinator, map: map, route: navigation, navigating: true)
        check(map.additions == navigationAdds && map.removals == navigationRemoves, "Clearing a suppressed preview does not reinstall unchanged navigation")
        update(coordinator, map: map, preview: preview.overlay, calculating: true)
        check(coordinator.displayedSavedRouteOverlay == nil, "In-flight directions calculations suppress stale saved previews")
        check(map.overlays.contains(where: { $0 === unrelated }), "All transitions preserve unrelated overlays")
    }

    private static func testSettingsAction() throws {
        let fixture = LibraryFixture()
        defer { fixture.cleanup() }
        let saved = try archive(route())
        let summary = try fixture.install(saved)
        var settingsPresented = true
        var accepted: SavedRouteMapPreview?
        let action = SavedRouteMapAction(isNavigationActive: false, show: { value in
            accepted = try SavedRouteMapPreviewFactory.make(value, now: { timestamp })
            settingsPresented = false
        })
        failure { try action.perform { throw SavedRouteMapError.unavailable("Missing") } }
        check(settingsPresented && accepted == nil, "Read failure leaves Settings presented")
        let expired = try archive(route(provider: RouteProviderPolicyV1.strava), deadline: timestamp.addingTimeInterval(1))
        let expiredAction = SavedRouteMapAction(isNavigationActive: false, show: { value in
            accepted = try SavedRouteMapPreviewFactory.make(value, now: { timestamp.addingTimeInterval(1) })
            settingsPresented = false
        })
        failure { try expiredAction.perform { selection(expired) } }
        check(settingsPresented && accepted == nil, "Expiry during presentation also leaves Settings presented")
        var loadedWhileNavigating = false
        let blocked = SavedRouteMapAction(isNavigationActive: true, show: action.show)
        failure {
            try blocked.perform {
                loadedWhileNavigating = true
                return try fixture.library.mapSelection(for: summary)
            }
        }
        check(!loadedWhileNavigating && settingsPresented, "Disabled navigation action cannot even load a route")
        try action.perform { try fixture.library.mapSelection(for: summary) }
        check(!settingsPresented && accepted?.identity == WatchRouteIdentityV1(archive: saved), "Validated success accepts the exact preview before dismissing Settings")
    }
}
