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

private final class OfflineDeleteFailureFileManager: FileManager, @unchecked Sendable {
    var deniedURL: URL?
    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL == deniedURL?.standardizedFileURL {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.removeItem(at: url)
    }
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
        try testOfflineArchiveCorruptionAndCapacity()
        try testOfflineDeletionFailureRecovery()
        try testOfflineSaveLifecycle()
        try testOfflineSaveFailuresAndAdmission()
        try testOfflineNavigationActionAndOverlay()
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

    private static let offlineGPX = Data("""
        <gpx version="1.1"><trk><name>River path</name><trkseg>
        <trkpt lat="51.5" lon="-0.1"/><trkpt lat="51.501" lon="-0.099"/>
        <trkpt lat="51.502" lon="-0.098"/></trkseg></trk></gpx>
        """.utf8)

    private static func testOfflineArchiveCorruptionAndCapacity() throws {
        let f = LibraryFixture()
        defer { f.cleanup() }
        let source = try archive(route())
        let bytes = try source.encoded(purpose: .durableStorage, now: f.clock.now)
        check(try NavigationRouteArchiveV1.decode(bytes, purpose: .offlineNavigation, now: f.clock.now) == source,
            "archive creation/loading round-trips schema and identity")
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        json["contentHash"] = String(repeating: "0", count: 64)
        do {
            _ = try NavigationRouteArchiveV1.decode(JSONSerialization.data(withJSONObject: json), purpose: .offlineNavigation, now: f.clock.now)
            preconditionFailure("altered hash must fail")
        } catch NavigationRouteArchiveError.hashMismatch {
            check(true, "hash mismatch rejected")
        }
        json["schemaVersion"] = 99
        do {
            _ = try NavigationRouteArchiveV1.decode(JSONSerialization.data(withJSONObject: json), purpose: .offlineNavigation, now: f.clock.now)
            preconditionFailure("unknown schema must fail")
        } catch NavigationRouteArchiveError.invalidSchemaVersion(99) {
            check(true, "unknown archive schema rejected")
        }
        let limited = PhoneRouteLibrary(store: NavigationRouteFileStoreV1(rootDirectory: f.root,
            limits: NavigationRouteFileStoreLimitsV1(maximumArchiveCount: 0, maximumTotalEncodedBytes: 1)),
            connectivity: PhoneWatchConnectivityCoordinator(), defaults: f.defaults, now: { f.clock.now })
        let draft = try limited.prepareGPX(offlineGPX, fileName: "full.gpx")
        check(draft.save(to: limited) == nil && limited.routes.isEmpty, "capacity failure does not evict or claim a save")
        let record = try f.store.install(bytes, now: f.clock.now)
        let wrongPath = f.root.appendingPathComponent("wrong-identity.routev1")
        try bytes.write(to: wrongPath)
        check(f.store.records(now: f.clock.now).count == 1, "a valid archive under a mismatched filename is not another installed identity")
        _ = f.store.pruneInvalidAndExpired(now: f.clock.now)
        check(!FileManager.default.fileExists(atPath: wrongPath.path), "mismatched archive filename is removed from active store")
        try Data(repeating: 32, count: NavigationRouteLimitsV1.production.maximumEncodedBytes + 1).write(to: record.fileURL)
        check(f.store.records(now: f.clock.now).isEmpty, "oversized corruption is rejected before decoding")
        _ = f.store.pruneInvalidAndExpired(now: f.clock.now)
        check(!FileManager.default.fileExists(atPath: record.fileURL.path), "oversized archive cannot survive as an active route")
        let outside = f.root.appendingPathComponent("outside.json")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: record.fileURL, withDestinationURL: outside)
        check(f.store.records(now: f.clock.now).isEmpty, "archive reads do not follow symlinks")
        _ = f.store.pruneInvalidAndExpired(now: f.clock.now)
        check(try Data(contentsOf: outside) == bytes, "symlink cleanup does not remove or modify its target")
    }

    private static func testOfflineDeletionFailureRecovery() throws {
        let f = LibraryFixture()
        defer { f.cleanup() }
        let manager = OfflineDeleteFailureFileManager()
        let store = NavigationRouteFileStoreV1(rootDirectory: f.root, fileManager: manager)
        let library = PhoneRouteLibrary(store: store, connectivity: PhoneWatchConnectivityCoordinator(),
            defaults: f.defaults, now: { f.clock.now })
        let source = try archive(route(provider: RouteProviderPolicyV1.strava), deadline: timestamp.addingTimeInterval(600))
        let summary = try library.importArchive(source.encoded(purpose: .offlineNavigation, now: f.clock.now))
        let record = try store.record(matching: WatchRouteIdentityV1(archive: source), now: f.clock.now)
        manager.deniedURL = record.fileURL
        failure { try library.delete(summary) }
        check(FileManager.default.fileExists(atPath: record.fileURL.path), "injected local deletion failure is real")
        check(library.routes.isEmpty, "pending provider deletion stays unavailable even when disk removal fails")
        failure { _ = try library.offlineNavigationArchive(for: summary) }
        failure { _ = try library.mapSelection(for: summary) }
        manager.deniedURL = nil
        let restarted = PhoneRouteLibrary(store: store, connectivity: PhoneWatchConnectivityCoordinator(),
            defaults: f.defaults, now: { f.clock.now })
        check(restarted.routes.isEmpty && !FileManager.default.fileExists(atPath: record.fileURL.path),
            "persisted deletion tombstone retries local removal after restart")
    }

    private static func testOfflineSaveLifecycle() throws {
        let f = LibraryFixture()
        defer { f.cleanup() }
        let cancelled = try f.library.prepareGPX(offlineGPX, fileName: "ride.gpx")
        check(cancelled.name == "River path" && cancelled.canSave, "GPX derives a useful name and enables Save")
        check(f.library.routes.isEmpty && !FileManager.default.fileExists(atPath: f.root.path), "draft performs no disk write")
        cancelled.cancel()
        check(cancelled.state == .cancelled && cancelled.save(to: f.library) == nil, "cancelled draft cannot later commit")

        let draft = try f.library.prepareGPX(offlineGPX, fileName: "ride.gpx")
        draft.name = "  "
        check(!draft.canSave, "blank name disables Save")
        draft.name = String(repeating: "x", count: 121)
        check(!draft.canSave, "unbounded name disables Save")
        draft.name = "  Sunday river ride  "
        let result = draft.save(to: f.library)!
        check(!result.alreadySaved && result.summary.name == "Sunday river ride", "successful Save trims and persists chosen name")
        check(draft.state == .saved(result) && !draft.canSave, "success disables repeat submission")
        draft.cancel()
        check(draft.state == .saved(result), "sheet dismissal does not undo a committed save")
        let loaded = try f.library.offlineNavigationArchive(for: result.summary)
        check(loaded.routeID == draft.id && loaded.revision == 1 && loaded.contentHash.count == 64, "saved route has stable UUID revision and SHA-256 identity")
        check(loaded.schemaVersion == 1 && loaded.route.normalizationVersion == 1, "archive and normalization versions survive saving")
        check(loaded.route.provider == RouteProviderPolicyV1.importedGPX && loaded.deleteAfter == nil, "GPX attribution and permitted retention survive saving")
        let record = try f.store.record(matching: WatchRouteIdentityV1(archive: loaded), now: f.clock.now)
        let bytes = try Data(contentsOf: record.fileURL)
        let modification = try FileManager.default.attributesOfItem(atPath: record.fileURL.path)[.modificationDate] as? Date
        f.clock.now.addTimeInterval(10)
        let duplicate = try f.library.prepareGPX(offlineGPX, fileName: "renamed-file.gpx")
        duplicate.name = "Different alias"
        let duplicateResult = duplicate.save(to: f.library)!
        check(duplicateResult.alreadySaved && duplicateResult.summary == result.summary, "duplicate GPX preserves the original identity and name")
        check(f.library.routes.count == 1, "duplicate creates no second row")
        check(try Data(contentsOf: record.fileURL) == bytes, "duplicate does not rewrite archive bytes")
        let afterModification = try FileManager.default.attributesOfItem(atPath: record.fileURL.path)[.modificationDate] as? Date
        check(modification == afterModification, "duplicate does not touch archive mtime")
        check(try f.library.saveOffline(loaded, name: "Another name").alreadySaved, "library-backed Save is idempotent")

        let restarted = PhoneRouteLibrary(store: NavigationRouteFileStoreV1(rootDirectory: f.root),
            connectivity: PhoneWatchConnectivityCoordinator(), defaults: f.defaults, now: { f.clock.now })
        check(restarted.routes == [result.summary], "fresh library instance restores only committed route")
        let afterRestart = try restarted.offlineNavigationArchive(for: result.summary)
        check(afterRestart == loaded, "restart preserves full immutable archive identity and canonical geometry")
        var runtime = NavigationRuntimeV1()
        _ = try runtime.start(route: afterRestart.route, contentHash: afterRestart.contentHash, mode: .offline)
        check(runtime.route == afterRestart.route, "offline runtime starts directly with restored canonical route")
        let first = afterRestart.route.points[0]
        let snapshot = try runtime.process(NavigationLocationSampleV1(coordinate: first,
            horizontalAccuracyMeters: 5, courseDegrees: -1, speedMetersPerSecond: 4,
            altitudeMeters: 0, timestamp: f.clock.now))
        check(snapshot.mode == .offline && snapshot.contentHash == loaded.contentHash, "offline runtime retains the saved identity without directions")
        _ = try restarted.mapSelection(for: result.summary)
        try restarted.delete(result.summary)
        check(restarted.routes.isEmpty && !FileManager.default.fileExists(atPath: record.fileURL.path), "local deletion removes row and durable archive")
        failure { _ = try restarted.offlineNavigationArchive(for: result.summary) }
        f.library.reload()
        check(f.library.routes.isEmpty, "deleted route stays absent across reload/restart")

        let repaired = try f.library.importGPX(offlineGPX, fileName: "again.gpx")
        let repairedRecord = try f.store.record(matching: WatchRouteIdentityV1(routeID: repaired.id,
            revision: repaired.revision, contentHash: repaired.contentHash), now: f.clock.now)
        try Data("corrupt archive".utf8).write(to: repairedRecord.fileURL)
        failure { _ = try f.library.offlineNavigationArchive(for: repaired) }
        check(f.library.routes.isEmpty, "corruption is pruned, never substituted by a cached preview")
        restarted.reload()
        check(restarted.routes.isEmpty, "corrupt archive remains unavailable after restart")
    }

    private static func testOfflineSaveFailuresAndAdmission() throws {
        let f = LibraryFixture()
        defer { f.cleanup() }
        let mapKit = try NavigationRouteArchiveV1.create(route: route(provider: RouteProviderPolicyV1.mapKit),
            createdAt: timestamp, purpose: .activeUse)
        let denied = PhoneOfflineRouteSaveSession(archive: mapKit, now: { timestamp })
        check(!denied.canSave && denied.save(to: f.library) == nil, "MapKit active route cannot enable Save")
        failure { _ = try f.library.saveOffline(mapKit, name: "Forbidden export") }
        failure { _ = try f.library.prepareGPX(Data("<gpx><trkpt lat='NaN' lon='0'/></gpx>".utf8), fileName: "bad.gpx") }
        failure { _ = try archive(route(points: [RouteCoordinateV1(latitude: 1, longitude: 1), RouteCoordinateV1(latitude: 1, longitude: 1)])) }
        check(f.library.routes.isEmpty, "invalid source and invalid geometry write no archive")

        let draft = try f.library.prepareGPX(offlineGPX, fileName: "retry.gpx")
        try Data("not a directory".utf8).write(to: f.root)
        check(draft.save(to: f.library) == nil && draft.canSave, "storage failure permits retry but never success")
        if case .failed(let message) = draft.state {
            check(!message.isEmpty, "failure provides UI feedback")
        } else { preconditionFailure("storage failure must be visible") }
        check(f.library.routes.isEmpty, "failed save publishes no row")
        try FileManager.default.removeItem(at: f.root)
        let saved = draft.save(to: f.library)!
        check(saved.summary.id == draft.id, "retry retains the draft identity")
        let installed = try f.library.offlineNavigationArchive(for: saved.summary)
        let conflict = try NavigationRouteArchiveV1.create(route: installed.route.namedForOfflineStorage("conflict"),
            createdAt: installed.createdAt, purpose: .durableStorage)
        failure { _ = try f.library.saveOffline(conflict, name: "conflict") }
        check(try f.library.offlineNavigationArchive(for: saved.summary) == installed, "revision conflict preserves installed archive")
        let stale = try NavigationRouteArchiveV1.create(route: route(id: installed.routeID, revision: 2),
            createdAt: timestamp, purpose: .offlineNavigation)
        _ = try f.library.importArchive(stale.encoded(purpose: .offlineNavigation, now: f.clock.now))
        failure { _ = try f.library.offlineNavigationArchive(for: saved.summary) }
        failure { _ = try f.library.saveOffline(installed, name: "stale") }

        let strava = try archive(route(provider: RouteProviderPolicyV1.strava), deadline: timestamp.addingTimeInterval(60))
        failure { _ = try f.library.saveOffline(strava, name: "No receipt") }
        let stravaSummary = try f.install(strava)
        let same = try f.library.saveOffline(strava, name: "No retention extension")
        check(same.alreadySaved && same.summary.deleteAfter == strava.deleteAfter && same.summary.contentHash == strava.contentHash,
            "library-backed Strava save cannot renew expiry or rewrite identity")
        f.clock.now = strava.deleteAfter!
        failure { _ = try f.library.offlineNavigationArchive(for: stravaSummary) }
        check(!f.library.routes.contains(where: { $0.id == stravaSummary.id }), "Strava deadline is exclusive and prunes offline availability")
    }

    private static func testOfflineNavigationActionAndOverlay() throws {
        let f = LibraryFixture()
        defer { f.cleanup() }
        let summary = try f.library.importGPX(offlineGPX, fileName: "ride.gpx")
        var loadCount = 0
        var startCount = 0
        let disabled = SavedRouteNavigationAction(isEnabled: false, start: { _, _ in startCount += 1 })
        failure {
            try disabled.perform(name: "ride") {
                loadCount += 1
                return try f.library.offlineNavigationArchive(for: summary)
            }
        }
        check(loadCount == 0 && startCount == 0, "disabled navigation action has no read/start effects")
        let enabled = SavedRouteNavigationAction(isEnabled: true, start: { archive, name in
            check(archive.routeID == summary.id && name == summary.name, "enabled action passes exact archive and displayed name")
            startCount += 1
        })
        try enabled.perform(name: summary.name) { try f.library.offlineNavigationArchive(for: summary) }
        check(startCount == 1, "enabled library action starts once")
        let display = try SavedRouteMapPreviewFactory.make(f.library.mapSelection(for: summary), now: { f.clock.now })
        let map = PreviewRecordingMap(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = MapViewContainer.Coordinator()
        let foreign = MKPolyline(coordinates: [CLLocationCoordinate2D(latitude: 1, longitude: 1), CLLocationCoordinate2D(latitude: 1.01, longitude: 1.01)], count: 2)
        map.addOverlay(foreign, level: .aboveLabels)
        coordinator.updateRouteOverlays(on: map, route: nil, alternatives: [], selectedAlternativeID: nil,
            routePlanningBottomPadding: 220, location: nil, simulatedPosition: nil, isSimulationMode: false,
            isNavigating: true, isUserLocationAuthorized: true, isFreePanActive: false,
            savedRoutePreview: display.overlay, offlineNavigationRoute: display.overlay)
        check(coordinator.displayedSavedRouteOverlay == nil && map.overlays.contains(where: { $0 === display.overlay.polyline }), "offline navigation owns a normal route overlay, not a saved preview")
        check(map.userTrackingMode == .followWithHeading, "offline navigation follows the user like online navigation")
        let renderer = coordinator.mapView(map, rendererFor: display.overlay.polyline) as! MKPolylineRenderer
        check(renderer.alpha == 1 && renderer.lineWidth > 4, "offline navigation has active-route styling")
        update(coordinator, map: map)
        check(!map.overlays.contains(where: { $0 === display.overlay.polyline }) && map.overlays.contains(where: { $0 === foreign }), "stopping clears only the owned offline overlay")
        try f.library.delete(summary)
        failure { try enabled.perform(name: summary.name) { try f.library.offlineNavigationArchive(for: summary) } }
        check(startCount == 1, "failed reload never invokes navigation callback")
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
        // MKMapView may call overridden camera APIs during initialization on
        // newer SDKs. Assert this location update causes no additional movement,
        // rather than assuming UIKit made zero calls before this operation.
        let beforeLocationRegionUpdates = map.regionUpdates
        let beforeLocationCameraUpdates = map.cameraUpdates
        print("Preview camera baseline: regions=\(beforeLocationRegionUpdates), cameras=\(beforeLocationCameraUpdates)")
        coordinator.updateUserTrackingMode(mapView: map, isNavigating: false, isOfflineMapSelectionActive: false)
        coordinator.updateInitialRegionIfNeeded(mapView: map, location: CLLocation(latitude: 40, longitude: 0), simulatedPosition: nil, isSimulationMode: false,
            isFreePanActive: coordinator.isFreePanActive(mapView: map, isOfflineMapSelectionActive: false))
        check(map.userTrackingMode == .none && map.regionUpdates == beforeLocationRegionUpdates &&
            map.cameraUpdates == beforeLocationCameraUpdates,
            "Location changes cannot steal preview camera: regions \(beforeLocationRegionUpdates) → \(map.regionUpdates), cameras \(beforeLocationCameraUpdates) → \(map.cameraUpdates), tracking \(map.userTrackingMode.rawValue)")
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
