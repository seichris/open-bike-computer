import Combine
import Foundation
import CoreLocation
import MapKit

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

@MainActor
final class TestNavigationDirectionsTask: NavigationDirectionsTask {
    let request: MKDirections.Request
    private(set) var isCancelled = false
    private var completion: (@MainActor (Result<[MKRoute], Error>) -> Void)?

    init(request: MKDirections.Request) {
        self.request = request
    }

    func calculate(
        completion: @escaping @MainActor (Result<[MKRoute], Error>) -> Void
    ) {
        self.completion = completion
    }

    func cancel() {
        isCancelled = true
    }

    func succeed(with routes: [MKRoute]) {
        completion?(.success(routes))
    }

    func fail(with error: Error) {
        completion?(.failure(error))
    }
}

@MainActor
final class TestNavigationDirectionsFactory {
    private(set) var tasks: [TestNavigationDirectionsTask] = []

    func makeTask(request: MKDirections.Request) -> any NavigationDirectionsTask {
        let task = TestNavigationDirectionsTask(request: request)
        tasks.append(task)
        return task
    }
}

final class TestRouteStep: MKRoute.Step {
    private let storedInstructions: String
    private let storedPolyline: MKPolyline
    private let storedDistance: CLLocationDistance

    init(instructions: String, coordinates: [CLLocationCoordinate2D]) {
        self.storedInstructions = instructions
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        super.init()
    }

    override var instructions: String {
        storedInstructions
    }

    override var polyline: MKPolyline {
        storedPolyline
    }

    override var distance: CLLocationDistance {
        storedDistance
    }
}

final class TestRoute: MKRoute {
    private let storedSteps: [MKRoute.Step]
    private let storedPolyline: MKPolyline
    private let storedDistance: CLLocationDistance
    private let storedExpectedTravelTime: TimeInterval

    init(
        instructions: String,
        coordinates: [CLLocationCoordinate2D],
        expectedTravelTime: TimeInterval = 0
    ) {
        self.storedSteps = [TestRouteStep(instructions: instructions, coordinates: coordinates)]
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        self.storedExpectedTravelTime = expectedTravelTime
        super.init()
    }

    init(
        steps: [TestRouteStep],
        coordinates: [CLLocationCoordinate2D],
        expectedTravelTime: TimeInterval = 0
    ) {
        self.storedSteps = steps
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = steps.reduce(0) { $0 + $1.distance }
        self.storedExpectedTravelTime = expectedTravelTime
        super.init()
    }

    override var steps: [MKRoute.Step] {
        storedSteps
    }

    override var polyline: MKPolyline {
        storedPolyline
    }

    override var distance: CLLocationDistance {
        storedDistance
    }

    override var expectedTravelTime: TimeInterval {
        storedExpectedTravelTime
    }
}

@MainActor
private final class Fixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-save-\(UUID())")
    let suite = "offline-save.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var store = NavigationRouteFileStoreV1(rootDirectory: root)
    let watch = PhoneWatchConnectivityCoordinator()
    lazy var library = makeLibrary()

    func makeLibrary() -> PhoneRouteLibrary {
        PhoneRouteLibrary(store: store, connectivity: watch, defaults: defaults, now: { [unowned self] in self.now })
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
@MainActor
struct OfflineRouteSaveTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    static func failure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") }
        catch { checks += 1 }
    }
    static func gpx(reversed: Bool = false, offset: Double = 0) -> Data {
        var points = [(51.5 + offset, -0.1), (51.502 + offset, -0.1), (51.504 + offset, -0.1)]
        if reversed { points.reverse() }
        let xml = points.map { "<trkpt lat=\"\($0.0)\" lon=\"\($0.1)\"/>" }.joined()
        return Data("<gpx version=\"1.1\"><trk><name>Canal ride</name><trkseg>\(xml)</trkseg></trk></gpx>".utf8)
    }
    private static func draft(_ f: Fixture, reversed: Bool = false, offset: Double = 0) throws -> OfflineRouteSaveDraft {
        try .gpx(data: gpx(reversed: reversed, offset: offset), fileName: "Canal.gpx", now: f.now)
    }
    static func changedProvider(_ route: NavigationRouteV1, _ provider: RouteProviderMetadataV1) -> NavigationRouteV1 {
        NavigationRouteV1(id: route.id, revision: route.revision, provider: provider,
            sourceReference: provider == RouteProviderPolicyV1.strava ? RouteSourceReferenceV1(
                providerID: provider.providerID, externalRouteID: "123456",
                canonicalURL: "https://www.strava.com/routes/123456") : nil,
            localeIdentifier: route.localeIdentifier, transportType: route.transportType,
            source: route.source, destination: route.destination, bounds: route.bounds,
            distanceMeters: route.distanceMeters, expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
            name: route.name, points: route.points, steps: route.steps, normalizationVersion: route.normalizationVersion)
    }
    private static func fix(_ f: Fixture, latitude: Double = 51.5, longitude: Double = -0.1) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 4, timestamp: f.now)
    }

    static func main() throws {
        try sourceAndValidation()
        try saveIdentityRestartAndDuplicates()
        try interactionCancellationAndStorageFailure()
        try corruptionDeletionAndReplacement()
        try stravaRetention()
        try offlineNavigationAndLateDirections()
        try mapKitPlanningRegression()
        try uiWiring()
        print("Offline route save/navigation: \(checks) checks passed")
    }

    static func sourceAndValidation() throws {
        let f = Fixture(); defer { f.cleanup() }
        let d = try draft(f)
        check(d.isEligible(now: f.now), "Parsed user GPX is approved")
        check(!RouteProviderPolicyV1.allowsDurableStorage(.init(providerID: "unknown", attribution: "Unknown", storageScope: .durable)), "Self-declared durable is not approval")
        for provider in [RouteProviderPolicyV1.mapKit,
            RouteProviderMetadataV1(providerID: "apple.mapkit", attribution: "Apple Maps", storageScope: .durable),
            RouteProviderMetadataV1(providerID: "unknown", attribution: "Unknown", storageScope: .durable)] {
            failure { _ = try NavigationRouteArchiveV1.create(route: changedProvider(d.archive.route, provider), createdAt: f.now, purpose: .offlineNavigation) }
        }
        let active = try NavigationRouteArchiveV1.create(route: changedProvider(d.archive.route, RouteProviderPolicyV1.mapKit), createdAt: f.now, purpose: .activeUse)
        failure { _ = try OfflineRouteSaveDraft.installed(active, now: f.now) }
        failure { _ = try f.library.importArchive(active.encoded(purpose: .activeUse, now: f.now)) }
        for xml in ["", "<not-xml", "<gpx/>", "<gpx><trk><trkseg><trkpt lat=\"91\" lon=\"1\"/><trkpt lat=\"92\" lon=\"2\"/></trkseg></trk></gpx>",
                    "<gpx><rte><rtept lat=\"1\" lon=\"1\"/><rtept lat=\"1\" lon=\"1\"/></rte></gpx>"] {
            failure { _ = try OfflineRouteSaveDraft.gpx(data: Data(xml.utf8), fileName: "invalid.gpx", now: f.now) }
        }
        failure { _ = try d.namedArchive("  ") }
        failure { _ = try d.namedArchive(String(repeating: "é", count: 257)) }
        check(f.library.routes.isEmpty, "Rejected sources and geometry never appear in the library")
    }

    static func saveIdentityRestartAndDuplicates() throws {
        let f = Fixture(); defer { f.cleanup() }
        let d = try draft(f)
        let saved = try f.library.saveOffline(d, name: "  Morning commute  ")
        check(!saved.alreadySaved && saved.summary.name == "Morning commute", "Meaningful name normalized on first save")
        let archive = try f.library.offlineArchive(for: saved.summary)
        check(archive.routeID == d.archive.routeID && archive.revision == 1, "Save keeps the staged UUID and revision")
        check(archive.contentHash.count == 64 && archive.schemaVersion == 1 && archive.route.normalizationVersion == 1, "Hash and schema/normalization metadata are retained")
        check(archive.route.provider == RouteProviderPolicyV1.importedGPX && archive.route.points == d.archive.route.points, "Provenance and canonical geometry are preserved")
        let bytes = try archive.encoded(purpose: .offlineNavigation, now: f.now)
        let decoded = try NavigationRouteArchiveV1.decode(bytes, purpose: .offlineNavigation, now: f.now)
        check(decoded == archive, "Archive encoding round trips with identical immutable identity")
        let record = try f.store.record(matching: WatchRouteIdentityV1(archive: archive), now: f.now)
        let before = try Data(contentsOf: record.fileURL)
        let retry = try f.library.saveOffline(d, name: "Morning commute")
        check(retry.alreadySaved && retry.summary == saved.summary, "Repeated Save is idempotent")
        f.now.addTimeInterval(10)
        let restarted = f.makeLibrary()
        check(restarted.routes == [saved.summary], "A new library instance recovers the saved route after restart")
        let repeatedImport = try restarted.saveOffline(draft(f), name: "Different alias")
        check(repeatedImport.alreadySaved && repeatedImport.summary == saved.summary, "Reimport with a new UUID/time/name reuses the existing identity")
        check(try Data(contentsOf: record.fileURL) == before, "Duplicates never rewrite archive bytes or renew creation time")
        _ = try restarted.saveOffline(draft(f, reversed: true), name: "Reverse commute")
        check(restarted.routes.count == 2, "Reversed geometry is a different route")
        let preview = try restarted.mapSelection(for: saved.summary)
        check(preview.identity == WatchRouteIdentityV1(archive: archive) && preview.displayName == "Morning commute", "Saved route participates in PR429 exact-identity preview")
    }

    static func interactionCancellationAndStorageFailure() throws {
        let f = Fixture(); defer { f.cleanup() }
        var interaction = OfflineRouteSaveInteraction()
        check(!interaction.canSave(now: f.now), "Save disabled before selection")
        interaction.save(now: f.now) { _, _ in preconditionFailure("No selection must not commit") }
        check(interaction.errorMessage == OfflineRouteSaveError.noSelection.localizedDescription,
            "Missing selection explains why saving is unavailable")
        let d = try draft(f)
        interaction.select(d)
        check(interaction.canSave(now: f.now), "Save enabled for approved valid GPX")
        interaction.proposedName = " "
        check(!interaction.canSave(now: f.now), "Save disabled for an empty name")
        interaction.save(now: f.now) { _, _ in preconditionFailure("Invalid name must not commit") }
        check(interaction.errorMessage == OfflineRouteSaveError.invalidName.localizedDescription,
            "Invalid name is distinct from a blocked provider")
        interaction.cancel()
        check(!interaction.canSave(now: f.now) && f.library.routes.isEmpty, "Cancel discards the draft without writes")
        interaction.select(d)
        var commits = 0
        interaction.save(now: f.now) { _, _ in
            commits += 1
            throw NavigationRouteFileStoreError.ioFailure
        }
        check(interaction.result == nil && interaction.errorMessage != nil && interaction.draft?.archive == d.archive, "Failure keeps an unchanged draft/identity and shows no success")
        check(interaction.canSave(now: f.now), "Failed save can be retried")
        interaction.save(now: f.now) { draft, name in
            commits += 1
            return try f.library.saveOffline(draft, name: name)
        }
        check(interaction.result != nil && interaction.errorMessage == nil && commits == 2, "Success is shown only after verified storage")
        check(!interaction.canSave(now: f.now), "Repeated button presses after success are disabled")

        let blockedRoot = f.root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedRoot)
        let blocked = PhoneRouteLibrary(store: NavigationRouteFileStoreV1(rootDirectory: blockedRoot),
            connectivity: PhoneWatchConnectivityCoordinator(), defaults: f.defaults, now: { f.now })
        failure { _ = try blocked.saveOffline(d, name: "Blocked") }
        check(blocked.routes.isEmpty, "Actual filesystem failure never publishes a saved route")
        let limitedStore = NavigationRouteFileStoreV1(rootDirectory: f.root.appendingPathComponent("limited"),
            limits: NavigationRouteFileStoreLimitsV1(maximumArchiveCount: 1, maximumTotalEncodedBytes: 4 * 1_024 * 1_024))
        let limited = PhoneRouteLibrary(store: limitedStore, connectivity: PhoneWatchConnectivityCoordinator(), defaults: f.defaults, now: { f.now })
        let first = try limited.saveOffline(d, name: "First")
        failure { _ = try limited.saveOffline(draft(f, reversed: true), name: "Second") }
        check(limited.routes == [first.summary], "Capacity failure preserves existing routes instead of silently evicting")
    }

    static func corruptionDeletionAndReplacement() throws {
        let f = Fixture(); defer { f.cleanup() }
        let saved = try f.library.saveOffline(draft(f), name: "Local")
        let selected = try f.library.offlineDraft(for: saved.summary)
        let archive = try f.library.offlineArchive(for: saved.summary)
        let record = try f.store.record(matching: WatchRouteIdentityV1(archive: archive), now: f.now)
        let original = try Data(contentsOf: record.fileURL)
        var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        json["contentHash"] = String(repeating: "0", count: 64)
        failure { _ = try NavigationRouteArchiveV1.decode(JSONSerialization.data(withJSONObject: json), purpose: .offlineNavigation, now: f.now) }
        json["schemaVersion"] = 65535
        failure { _ = try NavigationRouteArchiveV1.decode(JSONSerialization.data(withJSONObject: json), purpose: .offlineNavigation, now: f.now) }
        try Data("corrupt".utf8).write(to: record.fileURL)
        failure { _ = try f.library.offlineArchive(for: saved.summary) }
        check(f.library.routes.isEmpty, "Corrupt archives are not offered for navigation")
        failure { _ = try f.library.saveOffline(selected, name: "Do not resurrect") }
        check(f.makeLibrary().routes.isEmpty, "Corruption remains excluded after restart")
        let fresh = try f.library.saveOffline(draft(f), name: "Fresh")
        let exact = try f.library.offlineDraft(for: fresh.summary)
        try f.library.delete(fresh.summary)
        check(f.makeLibrary().routes.isEmpty, "Deletion is durable across restart")
        failure { _ = try f.library.saveOffline(exact, name: "Deleted") }
        failure { _ = try f.library.mapSelection(for: fresh.summary) }
        failure { _ = try f.library.offlineArchive(for: fresh.summary) }

        let prior = try f.library.saveOffline(draft(f), name: "Revision 1")
        let a = try f.library.offlineArchive(for: prior.summary)
        let r = a.route
        let newerRoute = NavigationRouteV1(id: r.id, revision: 2, provider: r.provider,
            sourceReference: r.sourceReference, localeIdentifier: r.localeIdentifier, transportType: r.transportType,
            source: r.source, destination: r.destination, bounds: r.bounds, distanceMeters: r.distanceMeters,
            expectedTravelTimeSeconds: r.expectedTravelTimeSeconds, name: r.name, points: r.points, steps: r.steps,
            normalizationVersion: r.normalizationVersion)
        let newer = try NavigationRouteArchiveV1.create(route: newerRoute, createdAt: f.now, purpose: .offlineNavigation)
        _ = try f.library.importArchive(newer.encoded(purpose: .offlineNavigation, now: f.now))
        failure { _ = try f.library.offlineArchive(for: prior.summary) }
        check(f.library.routes.first?.revision == 2, "Stale identity never silently substitutes another revision")
        failure { _ = try f.library.importArchive(a.encoded(purpose: .offlineNavigation, now: f.now)) }
    }

    static func stravaRetention() throws {
        let f = Fixture(); defer { f.cleanup() }
        let route = changedProvider(try draft(f).archive.route, RouteProviderPolicyV1.strava)
        let deadline = f.now.addingTimeInterval(60)
        failure { _ = try NavigationRouteArchiveV1.create(route: route, createdAt: f.now, purpose: .offlineNavigation) }
        failure { _ = try NavigationRouteArchiveV1.create(route: route, createdAt: f.now,
            deleteAfter: f.now.addingTimeInterval(604_801), purpose: .offlineNavigation) }
        let archive = try NavigationRouteArchiveV1.create(route: route, createdAt: f.now, deleteAfter: deadline, purpose: .offlineNavigation)
        let summary = try f.library.importArchive(archive.encoded(purpose: .offlineNavigation, now: f.now))
        let selected = try f.library.offlineDraft(for: summary)
        f.now.addTimeInterval(10)
        let saved = try f.library.saveOffline(selected, name: "Not a new lease")
        check(saved.alreadySaved && saved.summary == summary && saved.summary.deleteAfter == deadline, "Library Strava Save never clones or extends retention")
        check(try f.library.offlineArchive(for: saved.summary) == archive, "Strava provenance/hash/expiry remain exactly unchanged")
        var interaction = OfflineRouteSaveInteraction()
        interaction.select(selected)
        check(interaction.canSave(now: f.now), "Unexpired approved Strava selection is enabled")
        f.now = deadline
        check(!interaction.canSave(now: f.now), "Save disabled at exact Strava expiry")
        failure { _ = try f.library.saveOffline(selected, name: "Expired") }
        failure { _ = try f.library.offlineArchive(for: summary) }
        check(f.makeLibrary().routes.isEmpty, "Expired route remains unavailable after restart")
    }

    static func offlineNavigationAndLateDirections() throws {
        let f = Fixture(); defer { f.cleanup() }
        let saved = try f.library.saveOffline(draft(f), name: "Offline")
        let restarted = f.makeLibrary()
        let archive = try restarted.offlineArchive(for: saved.summary)
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: factory.makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        try coordinator.startOfflineNavigation(archive)
        check(coordinator.isNavigating && coordinator.currentRoute == nil && coordinator.offlineRouteSummary == saved.summary,
            "Saved archive starts on iPhone after restart, without constructing an MKRoute")
        check(coordinator.offlineRoutePolyline?.pointCount == archive.route.points.count, "Offline navigation has its own active display geometry")
        check(factory.tasks.isEmpty, "Offline start performs zero directions requests")
        failure { try coordinator.startOfflineNavigation(archive) }
        for _ in 0..<5 {
            f.now.addTimeInterval(1)
            coordinator.processNavigationLocationForTesting(fix(f, longitude: -0.2))
        }
        check(factory.tasks.isEmpty, "Off-route offline navigation never requests online rerouting")
        coordinator.reconcileOfflineNavigation(with: [])
        check(!coordinator.isNavigating && coordinator.offlineRoutePolyline == nil, "Deleting active identity stops offline navigation and releases geometry")

        let engine = NavigationEngine(now: { f.now })
        try engine.startOfflineNavigation(archive: archive, initialLocation: fix(f))
        check(engine.offlineSnapshotForTesting?.mode == .offline && engine.offlineSnapshotForTesting?.contentHash == archive.contentHash,
            "Actual engine/runtime use offline mode and original content hash")
        let firstGeneration = engine.offlineSnapshotForTesting!.navigationGeneration
        engine.stopNavigation()
        try engine.startOfflineNavigation(archive: archive, initialLocation: fix(f))
        check(engine.offlineSnapshotForTesting!.navigationGeneration > firstGeneration,
            "Offline restarts preserve the monotonic runtime generation")
        engine.stopNavigation()
        let expiring = try NavigationRouteArchiveV1.create(route: changedProvider(archive.route, RouteProviderPolicyV1.strava),
            createdAt: f.now, deleteAfter: f.now.addingTimeInterval(1), purpose: .offlineNavigation)
        try engine.startOfflineNavigation(archive: expiring)
        f.now.addTimeInterval(1)
        engine.refreshRideTelemetryForTesting()
        check(!engine.isNavigating, "Expiry stops navigation even without a GPS fix")
        failure { try engine.startOfflineNavigation(archive: expiring) }
        let denied = try NavigationRouteArchiveV1.create(route: changedProvider(archive.route, RouteProviderPolicyV1.mapKit), createdAt: f.now, purpose: .activeUse)
        failure { try coordinator.startOfflineNavigation(denied) }
        check(!coordinator.isNavigating, "Offline coordinator revalidates source policy")

        let source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 51.504, longitude: -0.1)))
        coordinator.planNavigation(from: .mapItem(source), to: .mapItem(destination), transportType: RouteTransportTypes.cycling, isTestMode: true)
        check(factory.tasks.count == 1, "Test has an in-flight online request")
        try coordinator.startOfflineNavigation(archive)
        factory.tasks[0].succeed(with: [TestRoute(instructions: "Continue", coordinates: [source.placemark.coordinate, destination.placemark.coordinate])])
        check(factory.tasks[0].isCancelled && coordinator.offlineRouteSummary == saved.summary && coordinator.currentRoute == nil,
            "Late online completion cannot replace selected offline navigation")
    }

    static func mapKitPlanningRegression() throws {
        let f = Fixture(); defer { f.cleanup() }
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: factory.makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        let points = [CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1), CLLocationCoordinate2D(latitude: 51.504, longitude: -0.1)]
        let start = MKMapItem(placemark: MKPlacemark(coordinate: points[0]))
        let finish = MKMapItem(placemark: MKPlacemark(coordinate: points[1]))
        let fast = TestRoute(instructions: "Continue", coordinates: points, expectedTravelTime: 120)
        let slow = TestRoute(instructions: "Continue", coordinates: points, expectedTravelTime: 300)
        coordinator.planNavigation(from: .mapItem(start), to: .mapItem(finish), transportType: RouteTransportTypes.cycling, isTestMode: true)
        factory.tasks[0].succeed(with: [slow, fast])
        check(!coordinator.isNavigating && coordinator.routeAlternatives.count == 2 && coordinator.routeAlternatives[0].route === fast,
            "Multiple online alternatives remain selectable and fastest-first")
        check(!coordinator.selectedRouteCanSaveOffline, "No selection cannot enable Save")
        coordinator.selectRouteAlternative(coordinator.routeAlternatives[0].id)
        check(!coordinator.selectedRouteCanSaveOffline, "Selected MapKit route remains policy-gated")
        coordinator.startSelectedRoute()
        check(coordinator.isNavigating && coordinator.currentRoute === fast, "Existing selected-route start is unchanged")
        coordinator.stopNavigation()
        coordinator.planNavigation(from: .mapItem(start), to: .mapItem(finish), transportType: RouteTransportTypes.cycling, isTestMode: true)
        factory.tasks[1].succeed(with: [fast])
        check(coordinator.isNavigating && coordinator.currentRoute === fast && coordinator.routeAlternatives.isEmpty,
            "Exactly one online result still starts immediately")
    }

    static func uiWiring() throws {
        let content = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/ContentView.swift", encoding: .utf8)
        let panel = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/OfflineRoutesView.swift", encoding: .utf8)
        check(content.contains(".disabled(!coordinator.selectedRouteCanSaveOffline)"), "Chooser uses coordinator source eligibility")
        check(content.contains("startPreviewedOfflineRoute(preview)"), "PR429 preview has explicit offline start action")
        check(content.contains("routeLibrary.offlineArchive(for: summary)"), "UI re-reads exact archive before navigation")
        check(panel.contains(".disabled(!interaction.canSave(now: context.date))"), "Approved Save button uses tested interaction state and clock")
        check(panel.contains("offlineRouteSaveSuccess") && panel.contains("offlineRouteSaveFailure"), "UI exposes both success and failure feedback")
    }
}
