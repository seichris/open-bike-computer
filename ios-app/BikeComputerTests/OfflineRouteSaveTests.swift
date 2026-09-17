import Combine
import Foundation
import CoreLocation
import MapKit

@MainActor
final class PhoneWatchConnectivityCoordinator: ObservableObject {
    struct State {
        var isActivated = false
        var isPaired = false
        var isWatchAppInstalled = false
        var isReachable = false
    }
    @Published var state = State()
    var onRouteAcknowledgement: ((WatchRouteSyncMessageV1) -> Void)?
    var acceptsDeletion = true
    var cancelledTransferCount = 1
    private(set) var sideEffects = 0
    private(set) var transferredRouteIDs: [UUID] = []
    private(set) var immediateRouteIDs: [UUID] = []
    private(set) var cancelledRouteIdentities: [WatchRouteIdentityV1] = []
    func transferRoute(_ record: InstalledNavigationRouteV1) -> UUID? {
        sideEffects += 1
        transferredRouteIDs.append(record.archive.routeID)
        return UUID()
    }
    func sendRouteImmediately(_ record: InstalledNavigationRouteV1) {
        sideEffects += 1
        immediateRouteIDs.append(record.archive.routeID)
    }
    func cancelRouteTransfers(_ identity: WatchRouteIdentityV1) -> Int {
        sideEffects += 1
        cancelledRouteIdentities.append(identity)
        return cancelledTransferCount
    }
    func requestRouteDeletion(_ identity: WatchRouteIdentityV1) -> UUID? {
        sideEffects += 1
        return acceptsDeletion ? UUID() : nil
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

private final class DeletionFailingFileManager: FileManager, @unchecked Sendable {
    var failsRouteDeletion = false
    override func removeItem(at url: URL) throws {
        if failsRouteDeletion && url.pathExtension == "routev1" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

@MainActor
private final class Fixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-save-\(UUID())")
    let suite = "offline-save.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let fileManager = DeletionFailingFileManager()
    lazy var store = NavigationRouteFileStoreV1(rootDirectory: root, fileManager: fileManager)
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
        try boundedArchiveReads()
        try automaticWatchTransfer()
        try watchTransferExpiryRecovery()
        try pendingDeletionAdmission()
        try independentDeletionRetries()
        try offlineNavigationAndLateDirections()
        try mapKitPlanningRegression()
        try selectedMapKitSaving()
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
        check(coordinator.selectedRouteCanSaveOffline, "The selected MapKit route can now be saved on iPhone")
        coordinator.startSelectedRoute()
        check(coordinator.isNavigating && coordinator.currentRoute === fast, "Existing selected-route start is unchanged")
        coordinator.stopNavigation()
        coordinator.planNavigation(from: .mapItem(start), to: .mapItem(finish), transportType: RouteTransportTypes.cycling, isTestMode: true)
        factory.tasks[1].succeed(with: [fast])
        check(!coordinator.isNavigating && coordinator.routeAlternatives.count == 1 &&
            coordinator.selectedRouteAlternativeID == nil,
            "Exactly one online result still waits for route confirmation")
    }

    static func selectedMapKitSaving() throws {
        let f = Fixture(); defer { f.cleanup() }
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: factory.makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        let points = [CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
                      CLLocationCoordinate2D(latitude: 51.502, longitude: -0.098),
                      CLLocationCoordinate2D(latitude: 51.504, longitude: -0.1)]
        let start = MKMapItem(placemark: MKPlacemark(coordinate: points[0]))
        let finish = MKMapItem(placemark: MKPlacemark(coordinate: points[2]))
        start.name = "Canal gate"; finish.name = "Station"
        let fast = TestRoute(instructions: "Continue along Main Street",
            coordinates: [points[0], points[2]], expectedTravelTime: 120)
        let detour = TestRoute(steps: [
            TestRouteStep(instructions: "Turn right onto Towpath", coordinates: [points[0], points[1]]),
            TestRouteStep(instructions: "Turn left toward Station", coordinates: [points[1], points[2]])
        ], coordinates: points, expectedTravelTime: 300)
        failure { _ = try coordinator.selectedRouteOfflineDraft() }
        coordinator.planNavigation(from: .mapItem(start), to: .mapItem(finish),
            transportType: RouteTransportTypes.cycling, isTestMode: true)
        check(!coordinator.selectedRouteCanSaveOffline, "Save is disabled while calculating")
        factory.tasks[0].succeed(with: [detour, fast])
        check(coordinator.selectedRouteAlternativeID == nil, "Multiple routes still require an explicit selection")
        failure { _ = try coordinator.selectedRouteOfflineDraft() }
        let selected = coordinator.routeAlternatives[1]
        coordinator.selectRouteAlternative(selected.id)
        let draft = try coordinator.selectedRouteOfflineDraft()
        check(draft.id == selected.id && draft.archive.route.revision == 1, "Save uses selected alternative UUID, not the fastest route")
        check(draft.archive.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone,
            "Selected MapKit preserves Apple attribution with explicit phone-only storage")
        check(draft.archive.route.source == selected.canonicalRoute.source &&
            draft.archive.route.destination == selected.canonicalRoute.destination,
            "Named source and destination survive from the plan")
        check(draft.archive.route.points == selected.canonicalRoute.points &&
            draft.archive.route.steps == selected.canonicalRoute.steps,
            "Exact ordered geometry and both turn instructions survive without a second extraction")
        check(draft.archive.route.distanceMeters == detour.distance &&
            draft.archive.route.expectedTravelTimeSeconds == 300,
            "Selected distance and ETA, not fastest alternative metadata, are saved")
        check(!(draft.archive.route.name ?? "").isEmpty, "A meaningful name is derived before confirmation")
        var interaction = OfflineRouteSaveInteraction()
        interaction.select(draft); interaction.cancel()
        check(f.library.routes.isEmpty && interaction.draft == nil, "Cancelling a MapKit save writes nothing")
        coordinator.selectRouteAlternative(coordinator.routeAlternatives[0].id)
        check(draft.archive.route.points == selected.canonicalRoute.points,
            "A captured save cannot silently switch when another alternative is selected")
        interaction.select(draft)
        interaction.proposedName = "Towpath commute"
        let blockedStore = NavigationRouteFileStoreV1(rootDirectory: f.root.appendingPathComponent("blocked"),
            limits: .init(maximumArchiveCount: 0, maximumTotalEncodedBytes: 0))
        let blockedLibrary = PhoneRouteLibrary(store: blockedStore, connectivity: PhoneWatchConnectivityCoordinator(),
            defaults: f.defaults, now: { f.now })
        interaction.save(now: f.now) { try blockedLibrary.saveOffline($0, name: $1) }
        check(interaction.result == nil && interaction.errorMessage != nil && interaction.draft == draft,
            "A failed MapKit save keeps the immutable selection and name for retry")
        interaction.save(now: f.now) { try f.library.saveOffline($0, name: $1) }
        let saved = interaction.result!
        check(!saved.alreadySaved && saved.summary.name == "Towpath commute", "Save confirmation reports a real installed MapKit route")
        let archive = try f.library.offlineArchive(for: saved.summary)
        check(archive.route.points == selected.canonicalRoute.points && archive.route.steps == selected.canonicalRoute.steps,
            "Installed geometry and instructions match the chosen route exactly")
        let record = try f.store.record(matching: WatchRouteIdentityV1(archive: archive), now: f.now)
        let bytes = try Data(contentsOf: record.fileURL)
        check(try NavigationRouteArchiveV1.decode(bytes, purpose: .offlineNavigation, now: f.now) == archive,
            "Phone-only archive validates schema and content hash on disk")
        f.now.addTimeInterval(30)
        let repeated = try f.library.saveOffline(draft, name: "A different proposed name")
        check(repeated.alreadySaved && repeated.summary == saved.summary,
            "Repeated save does not mutate the first committed name or full identity")
        check(try Data(contentsOf: record.fileURL) == bytes, "Repeated MapKit save does not rewrite bytes or reset its timestamp")
        let newRoute = try MapKitRouteAdapter.route(from: detour,
            sourceLabel: "Canal gate", destinationLabel: "Station")
        let newDraft = try OfflineRouteSaveDraft.plannedMapKit(newRoute, createdAt: f.now)
        let duplicate = try f.library.saveOffline(newDraft, name: "Repeated calculation")
        check(duplicate.alreadySaved && duplicate.summary == saved.summary, "Equivalent recalculation deduplicates without crossing providers")
        check(!f.library.canSendToWatch(saved.summary), "Phone-only MapKit route does not expose Watch transfer")
        let watchEffects = f.watch.sideEffects
        failure { try f.library.sendToWatch(saved.summary) }
        check(f.watch.sideEffects == watchEffects, "Rejected Watch transfer has no side effects")
        failure { _ = try archive.encoded(purpose: .watchTransfer, now: f.now) }
        let watchStore = NavigationRouteFileStoreV1(rootDirectory: f.root.appendingPathComponent("watch"),
            limits: .watch, destination: .watch)
        failure { _ = try watchStore.install(bytes, now: f.now) }
        check(watchStore.records(now: f.now).isEmpty, "Watch store cannot admit phone-only geometry")
        let restarted = f.makeLibrary()
        check(restarted.routes == [saved.summary], "Saved MapKit route survives an app/library restart")
        let preview = try restarted.mapSelection(for: saved.summary)
        check(preview.identity == WatchRouteIdentityV1(archive: archive) &&
            preview.route.provider.attribution == "Apple Maps", "Existing preview reads saved MapKit attribution and exact identity")
        coordinator.cancelRoutePlan()
        check(!coordinator.selectedRouteCanSaveOffline, "Cancelling a plan clears Save selection")
        failure { _ = try coordinator.selectedRouteOfflineDraft() }
        try coordinator.startOfflineNavigation(restarted.offlineArchive(for: saved.summary))
        check(coordinator.isNavigating && coordinator.currentRoute == nil &&
            coordinator.offlineRouteSummary == saved.summary && factory.tasks.count == 1,
            "Saved MapKit navigation starts after restart without directions or raw MKRoute reconstruction")
        coordinator.stopNavigation()
        try restarted.delete(saved.summary)
        check(f.makeLibrary().routes.isEmpty, "Deleting a phone-only route is durable and needs no Watch")
        failure { _ = try restarted.offlineArchive(for: saved.summary) }
        let resaved = try restarted.saveOffline(draft, name: "Corruption test")
        let resavedRecord = try f.store.record(matching: WatchRouteIdentityV1(
            routeID: resaved.summary.id, revision: resaved.summary.revision, contentHash: resaved.summary.contentHash), now: f.now)
        try Data("damaged".utf8).write(to: resavedRecord.fileURL)
        check(f.makeLibrary().routes.isEmpty, "Corrupt saved MapKit archive is not restored or substituted")
        failure { _ = try OfflineRouteSaveDraft.plannedMapKit(changedProvider(newRoute, RouteProviderPolicyV1.importedGPX), createdAt: f.now) }
        let unknown = RouteProviderMetadataV1(providerID: "unknown", attribution: "Unknown", storageScope: .phoneOnly)
        check(!RouteProviderPolicyV1.allowsDurableStorage(unknown), "Phone-only scope does not whitelist unknown providers")

        let chinaPoints = [CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
                           CLLocationCoordinate2D(latitude: 31.231, longitude: 121.471)]
        let china = try MapKitRouteAdapter.route(from: TestRoute(instructions: "Continue", coordinates: chinaPoints))
        let chinaDraft = try OfflineRouteSaveDraft.plannedMapKit(china, createdAt: f.now)
        check(chinaDraft.archive.route.points == china.points && chinaDraft.archive.route.normalizationVersion == china.normalizationVersion,
            "China coordinates are not normalized a second time when saved")
    }

    static func boundedArchiveReads() throws {
        let f = Fixture(); defer { f.cleanup() }
        let summary = try f.library.importGPX(gpx(), fileName: "Canonical.gpx")
        let archive = try f.library.offlineArchive(for: summary)
        let record = try f.store.record(matching: WatchRouteIdentityV1(archive: archive), now: f.now)
        let bytes = try Data(contentsOf: record.fileURL)
        let renamed = f.root.appendingPathComponent("wrong-identity.routev1")
        try FileManager.default.moveItem(at: record.fileURL, to: renamed)
        check(f.store.records(now: f.now).isEmpty, "A valid archive under the wrong filename is rejected")
        f.library.reload()
        check(!FileManager.default.fileExists(atPath: renamed.path), "Wrong filenames are quarantined")

        let outside = f.root.appendingPathComponent("outside.bin")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: record.fileURL, withDestinationURL: outside)
        check(f.store.records(now: f.now).isEmpty, "A symlink to valid archive bytes is not admitted")
        f.library.reload()
        check(try Data(contentsOf: outside) == bytes, "Quarantining a link never mutates its target")

        // Sparse oversized file: reject before allocating its content.
        FileManager.default.createFile(atPath: record.fileURL.path, contents: Data([1]))
        let handle = try FileHandle(forWritingTo: record.fileURL)
        try handle.truncate(atOffset: UInt64(NavigationRouteLimitsV1.production.maximumEncodedBytes + 1))
        try handle.close()
        check(f.store.records(now: f.now).isEmpty, "Oversized archives cannot enter the library")
        f.library.reload()
        check(f.makeLibrary().offlineNavigationRoutes.isEmpty, "Rejected archive shapes stay unavailable after restart")
    }

    static func automaticWatchTransfer() throws {
        let f = Fixture(); defer { f.cleanup() }
        f.watch.state = .init(
            isActivated: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false
        )

        let first = try f.library.saveOffline(
            draft(f),
            name: "Automatic transfer"
        ).summary
        let firstIdentity = WatchRouteIdentityV1(
            archive: try f.library.offlineArchive(for: first)
        )
        check(
            f.watch.transferredRouteIDs == [first.id] &&
                f.watch.immediateRouteIDs == [first.id] &&
                f.library.watchSyncState[firstIdentity] == .transferring,
            "A Watch-supported offline route is queued automatically"
        )
        f.library.reload()
        check(
            f.watch.transferredRouteIDs == [first.id],
            "Reload does not duplicate a pending automatic Watch transfer"
        )
        f.watch.state = .init(
            isActivated: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: true
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(
            f.watch.immediateRouteIDs == [first.id, first.id],
            "Becoming reachable retries a transfer queued while unreachable"
        )
        f.watch.state = .init(
            isActivated: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: true
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(
            f.watch.immediateRouteIDs == [first.id, first.id],
            "Repeated reachable-state refreshes do not duplicate live sends"
        )
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge,
            identity: firstIdentity,
            status: .ready,
            errorCode: nil
        ))
        f.library.reload()
        check(
            f.watch.transferredRouteIDs == [first.id] &&
                f.library.watchSyncState[firstIdentity] == .ready,
            "A ready Watch receipt prevents automatic retransmission"
        )

        let second = try f.library.saveOffline(
            draft(f, offset: 0.02),
            name: "Rejected transfer"
        ).summary
        let secondIdentity = WatchRouteIdentityV1(
            archive: try f.library.offlineArchive(for: second)
        )
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge,
            identity: secondIdentity,
            status: .rejected,
            errorCode: "watch_storage_full"
        ))
        f.library.reload()
        check(
            f.watch.transferredRouteIDs == [first.id, second.id] &&
                f.library.watchSyncState[secondIdentity] ==
                    .rejected("watch_storage_full"),
            "A rejected automatic transfer stays failed until explicit retry"
        )
        let restarted = f.makeLibrary()
        check(
            f.watch.transferredRouteIDs == [first.id, second.id] &&
                restarted.watchSyncState[secondIdentity] ==
                    .rejected("watch_storage_full"),
            "A failed automatic transfer remains retryable after restart"
        )
        try restarted.sendToWatch(second)
        check(
            f.watch.transferredRouteIDs == [first.id, second.id, second.id] &&
                restarted.watchSyncState[secondIdentity] == .transferring,
            "The failed-transfer action retries the exact route"
        )
        f.defaults.removeObject(forKey: "watchRouteAttemptedInstalls.v1")
        let migrated = f.makeLibrary()
        check(
            f.watch.transferredRouteIDs == [first.id, second.id, second.id] &&
                migrated.watchSyncState[secondIdentity] == .transferring,
            "A legacy pending transfer is adopted without duplicate queuing"
        )
        f.defaults.set([], forKey: "watchRoutePendingInstalls.v1")
        let expired = f.makeLibrary()
        check(
            f.watch.transferredRouteIDs == [first.id, second.id, second.id] &&
                expired.watchSyncState[secondIdentity] ==
                    .rejected("transfer_expired"),
            "An expired pending attempt becomes failed instead of auto-queuing forever"
        )
    }

    static func pendingDeletionAdmission() throws {
        let f = Fixture(); defer { f.cleanup() }
        let saved = try f.library.saveOffline(draft(f), name: "Pending deletion")
        let archive = try f.library.offlineArchive(for: saved.summary)
        let identity = WatchRouteIdentityV1(archive: archive)
        let selected = try f.library.offlineDraft(for: saved.summary)
        try f.library.sendToWatch(saved.summary)
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .ready, errorCode: nil))
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: factory.makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        try coordinator.startOfflineNavigation(archive)
        try f.library.delete(saved.summary)
        check(f.library.routes == [saved.summary] && f.library.watchSyncState[identity] == .deleting,
            "Watch deletion keeps a visible status row")
        check(!f.library.isAvailableOffline(saved.summary) && f.library.offlineNavigationRoutes.isEmpty,
            "Pending deletion immediately revokes offline admission")
        coordinator.reconcileOfflineNavigation(with: f.library.offlineNavigationRoutes)
        check(!coordinator.isNavigating && factory.tasks.isEmpty, "Pending deletion stops navigation without an online fallback")
        failure { _ = try f.library.offlineArchive(for: saved.summary) }
        failure { _ = try f.library.mapSelection(for: saved.summary) }
        failure { _ = try f.library.saveOffline(selected, name: "Do not resurrect") }
        failure { try f.library.sendToWatch(saved.summary) }
        let restarted = f.makeLibrary()
        check(!restarted.isAvailableOffline(saved.summary), "Pending deletion survives restart")
        failure { _ = try restarted.offlineArchive(for: saved.summary) }
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .rejected, errorCode: "in_use"))
        check(restarted.isAvailableOffline(saved.summary), "An explicitly rejected Watch deletion keeps the original route")
        try restarted.delete(saved.summary)
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .deleted, errorCode: nil))
        check(restarted.routes.isEmpty && f.makeLibrary().routes.isEmpty, "Acknowledged deletion is durable")
    }

    static func watchTransferExpiryRecovery() throws {
        let f = Fixture(); defer { f.cleanup() }
        let summary = try f.library.importGPX(
            gpx(),
            fileName: "Watch route.gpx"
        )
        let identity = WatchRouteIdentityV1(
            archive: try f.library.offlineArchive(for: summary)
        )
        try f.library.sendToWatch(summary)
        check(
            f.library.watchSyncState[identity] == .transferring,
            "A new Watch route attempt is queued"
        )

        f.now.addTimeInterval((7 * 24 * 60 * 60) - 1)
        let beforeDeadline = f.makeLibrary()
        check(
            beforeDeadline.watchSyncState[identity] == .transferring,
            "A pending Watch route remains queued until its full lifetime"
        )

        f.now.addTimeInterval(2)
        beforeDeadline.reload()
        check(
            beforeDeadline.watchSyncState[identity] ==
                .rejected("transfer_expired") &&
                f.watch.cancelledRouteIdentities.last == identity,
            "A week-old Watch route attempt is cancelled and exposes retry"
        )

        try beforeDeadline.sendToWatch(summary)
        f.watch.cancelledTransferCount = 0
        check(
            beforeDeadline.cancelSendToWatch(summary) &&
                beforeDeadline.watchSyncState[identity] ==
                    .rejected("transfer_cancelled"),
            "Cancel clears an orphaned attempt and exposes retry"
        )

        try beforeDeadline.sendToWatch(summary)
        f.defaults.removeObject(
            forKey: "watchRoutePendingInstallStartedAt.v1"
        )
        let migrated = f.makeLibrary()
        check(
            migrated.watchSyncState[identity] ==
                .rejected("transfer_expired"),
            "A legacy untimestamped queue is cleared into retry on upgrade"
        )
    }

    static func independentDeletionRetries() throws {
        for status in [WatchRouteSyncStatusV1.deleted, .evicted] {
            for provider in [RouteProviderPolicyV1.importedGPX, RouteProviderPolicyV1.strava] {
                let f = Fixture(); defer { f.cleanup() }
                let route = changedProvider(try draft(f).archive.route, provider)
                let archive = try NavigationRouteArchiveV1.create(route: route, createdAt: f.now,
                    deleteAfter: provider == RouteProviderPolicyV1.strava ? f.now.addingTimeInterval(600) : nil,
                    purpose: .offlineNavigation)
                let summary = try f.library.importArchive(archive.encoded(purpose: .offlineNavigation, now: f.now))
                let identity = WatchRouteIdentityV1(archive: archive)
                try f.library.sendToWatch(summary)
                f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
                    operation: .acknowledge, identity: identity, status: .ready, errorCode: nil))
                f.fileManager.failsRouteDeletion = true
                if provider == RouteProviderPolicyV1.strava {
                    failure { try f.library.delete(summary) }
                    check(f.library.routes.isEmpty, "Failed provider removal stays hidden, not available again")
                } else {
                    try f.library.delete(summary)
                }
                f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
                    operation: .acknowledge, identity: identity, status: status, errorCode: nil))
                check(!f.store.records(now: f.now).isEmpty, "Injected local unlink failure really leaves archive bytes")
                check(f.library.offlineNavigationRoutes.isEmpty, "Watch acknowledgement cannot clear failed local cleanup")
                failure { _ = try f.library.offlineArchive(for: summary) }
                let restarted = f.makeLibrary()
                check(restarted.routes.isEmpty, "Local tombstone survives restart after Watch acknowledgement")
                failure { _ = try restarted.mapSelection(for: summary) }
                failure { _ = try restarted.importArchive(archive.encoded(purpose: .offlineNavigation, now: f.now)) }
                f.fileManager.failsRouteDeletion = false
                restarted.reload()
                check(f.store.records(now: f.now).isEmpty, "Recovered storage retries the exact failed deletion")
                check(f.makeLibrary().routes.isEmpty, "Cleanup remains complete on the next restart")
            }
        }
        let f = Fixture(); defer { f.cleanup() }
        let summary = try f.library.importGPX(gpx(), fileName: "Keep.gpx")
        let identity = WatchRouteIdentityV1(archive: try f.library.offlineArchive(for: summary))
        for status in [WatchRouteSyncStatusV1.evicted, .deleted] {
            f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
                operation: .acknowledge, identity: identity, status: status, errorCode: nil))
            check(f.library.isAvailableOffline(summary), "Unrequested Watch removal does not delete the iPhone copy")
        }
    }

    static func uiWiring() throws {
        let content = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/ContentView.swift", encoding: .utf8)
        let panel = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/SavedRoutesLibraryView.swift", encoding: .utf8)
        let section = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift", encoding: .utf8)
        let settings = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift", encoding: .utf8)
        check(content.contains(".disabled(!coordinator.selectedRouteCanSaveOffline)"), "Chooser enables Save only for a selected savable route")
        check(content.contains("Button(action: saveSelectedRouteOffline)") &&
            content.contains("coordinator.selectedRouteOfflineDraft()") &&
            content.contains("case .savePlannedRoute(let draft):") &&
            content.contains("RouteSaveSheet(library: routeLibrary, draft: draft)"),
            "Save Offline presents the selected immutable draft through the shared commit sheet")
        check(content.components(separatedBy: "savePlannedRouteButton").count >= 4 &&
            !content.contains("Button { } label:") && !content.contains("Saving this Apple Maps route is not available"),
            "Both route-choice layouts expose the functional Save button, not an import redirect")
        check(content.contains("plannedRouteSaveSuccess"), "Route chooser receives visible success feedback")
        check(content.contains("startPreviewedOfflineRoute(preview)"), "Preview still has an explicit navigation action")
        check(content.contains("routeLibrary.offlineArchive(for: summary)"), "UI re-reads exact archive before navigation")
        check(panel.contains(".disabled(!interaction.canSave(now: Date()))"), "Import confirmation uses tested save state")
        check(section.contains("offlineRouteSaveSuccess") && panel.contains("offlineRouteSaveFailure"), "UI exposes success and failure feedback")
        check(panel.contains("SavedRoutesSettingsSection(") && settings.contains("SavedRoutesSettingsSection("),
            "Planner shortcut and Settings share the same library/import UI")
        check(!panel.contains("ForEach(library.routes)") && !panel.contains(".fileImporter"), "Shortcut does not duplicate library or importer")
        check(section.contains("onConfirmGPX(try OfflineRouteSaveDraft.gpx(") &&
            !section.contains("try routeLibrary.importGPX("),
            "Import GPX requests confirmation before the durable commit")
        check(!section.contains(".sheet(") &&
            settings.contains("presentedSheet = .gpxRouteImport(draft)") &&
            settings.contains("RouteSaveSheet(library: routeLibrary, draft: draft)") &&
            panel.contains(".sheet(item: $presentedImport)") &&
            panel.contains("RouteSaveSheet(library: library, draft: draft)"),
            "GPX confirmation is item-driven by stable parent presenters, never a transient Section")
        check(section.contains("favoriteButton(for: route") &&
            section.contains("Label(\"Save an Online Route\"") &&
            !section.contains("Navigate on iPhone") &&
            !section.contains("Available offline") &&
            !section.contains("Apple Maps · Saved on this iPhone"),
            "Saved routes merge favorite stars and online saving without obsolete row copy")
        check(section.contains("Watch-supported routes are queued automatically") &&
            section.contains("retrySendButton(route") &&
            !section.contains("arrow.up.circle") &&
            !section.contains("cancelSendButton("),
            "Watch-supported routes auto-queue with only failed-transfer retry UI")
        check(content.contains("if routePlanningPurpose == .navigate") &&
            content.contains("if routePlanningPurpose == .saveOffline") &&
            !content.contains("Save this route to follow it later") &&
            !content.contains("chooseApprovedOfflineRoute"),
            "Route choice keeps navigation and save-only actions in separate modes")
        check(content.contains("routeLibrary.$offlineNavigationRoutes"), "Active navigation and preview observe deletion admission, not just files")
    }
}
