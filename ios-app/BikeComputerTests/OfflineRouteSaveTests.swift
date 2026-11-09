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
        var routeSyncSchemaVersion = 2
    }
    @Published var state = State()
    var onRouteAcknowledgement: ((WatchRouteSyncMessageV1) -> Void)?
    var operations: [WatchRouteIdentityV1: WatchRouteOperationV2] = [:]
    var acceptsDeletion = true
    var cancelledTransferCount = 1
    private(set) var sideEffects = 0
    private(set) var transferredRouteIDs: [UUID] = []
    private(set) var immediateRouteIDs: [UUID] = []
    private(set) var cancelledRouteIdentities: [WatchRouteIdentityV1] = []
    func acknowledgeCurrent(_ message: WatchRouteSyncMessageV1) {
        onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: message.operation, identity: message.identity, status: message.status,
            errorCode: message.errorCode, deliveryOperation: operations[message.identity]))
    }
    func transferRoute(_ record: InstalledNavigationRouteV1, deliveryOperation: WatchRouteOperationV2? = nil) -> UUID? {
        operations[WatchRouteIdentityV1(archive: record.archive)] = deliveryOperation
        sideEffects += 1
        transferredRouteIDs.append(record.archive.routeID)
        return UUID()
    }
    func sendRouteImmediately(_ record: InstalledNavigationRouteV1, deliveryOperation: WatchRouteOperationV2? = nil) {
        sideEffects += 1
        immediateRouteIDs.append(record.archive.routeID)
    }
    func cancelRouteTransfers(_ identity: WatchRouteIdentityV1) -> Int {
        sideEffects += 1
        cancelledRouteIdentities.append(identity)
        return cancelledTransferCount
    }
    func requestRouteDeletion(_ identity: WatchRouteIdentityV1, deliveryOperation: WatchRouteOperationV2? = nil) -> UUID? {
        operations[identity] = deliveryOperation
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
        try operationReceiptAndCrashRecovery()
        try unavailableWatchDeletionAndFenceRenewal()
        try sourceAndValidation()
        try socialCopyKeepsProviderAndProvenance()
        try socialMapKitCopyKeepsExactRoute()
        try saveIdentityRestartAndDuplicates()
        try interactionCancellationAndStorageFailure()
        try corruptionDeletionAndReplacement()
        try stravaRetention()
        try boundedArchiveReads()
        try savedRouteFavoriteCoordinates()
        try automaticWatchTransfer()
        try watchTransferExpiryRecovery()
        try pendingDeletionAdmission()
        try independentDeletionRetries()
        try offlineNavigationAndLateDirections()
        try mapKitPlanningRegression()
        try selectedMapKitSaving()
        try legacyMapKitArchives()
        try multiStopRouteTests()
        try uiWiring()
        print("Offline route save/navigation: \(checks) checks passed")
    }

    static func socialCopyKeepsProviderAndProvenance() throws {
        let f = Fixture(); defer { f.cleanup() }
        let before = checks
        let original = try draft(f).archive
        let data = try original.encoded(purpose: .offlineNavigation, now: f.now)
        let friendRoute = SocialRouteSource(kind: .content, socialID: "social-route", owner: "rider", revision: 3)
        let saved = try f.library.importSocialArchive(data, source: friendRoute, duplicate: false)
        let copy = try f.library.importSocialArchive(data, source: friendRoute, duplicate: true)
        check(saved.id == original.routeID && copy.id != original.routeID, "Only Duplicate creates a new local identity")
        let restored = try f.library.offlineArchive(for: copy)
        check(restored.route.provider == original.route.provider && restored.createdAt == original.createdAt && restored.deleteAfter == original.deleteAfter,
              "Copy preserves provider and retention")
        let provenance = f.root.appendingPathComponent("social-provenance")
        let sidecar = provenance.appendingPathComponent(copy.id.uuidString + ".json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
        check(metadata["sourceHash"] as? String == original.contentHash, "Copy retains original hash provenance outside navigation archive")
        check(metadata["socialRevision"] as? Int == 3, "Social revision is retained")
        check(metadata["owner"] as? String == "rider" && metadata["kind"] as? String == "content", "Copy records its owner and source kind")
        check(metadata["geometry"] as? String == PhoneRouteLibrary.socialGeometry(original), "Copy records its route geometry")

        // A friend's route, including an ID-changed duplicate, stays the owner's to share.
        for summary in [saved, copy] {
            check(f.library.socialPublication(for: summary, currentProfileID: "me") == .restricted(owner: "rider"),
                  "A saved or duplicated friend route cannot be published as the saver's own")
            check(f.library.socialPublication(for: summary, currentProfileID: nil) == .restricted(owner: "rider"),
                  "An unknown signed-in rider fails closed")
            check(f.library.socialPublication(for: summary, currentProfileID: "rider") == .ownCopy,
                  "The owner may republish their own saved route")
        }
        // Restrictions are read back after a relaunch over the same storage.
        let relaunched = f.makeLibrary()
        check(relaunched.socialPublication(for: copy, currentProfileID: "me") == .restricted(owner: "rider"),
              "Provenance survives reload")
        // Group Ride snapshots saved or opened on the map belong to the organizer.
        let snapshot = try draft(f, offset: 0.01).archive
        let ride = try relaunched.importSocialArchive(snapshot.encoded(purpose: .offlineNavigation, now: f.now),
            source: SocialRouteSource(kind: .ride, socialID: "ride-1", owner: "organizer", revision: nil), duplicate: false)
        check(relaunched.socialPublication(for: ride, currentProfileID: "me") == .restricted(owner: "organizer"),
              "Members cannot republish a Group Ride snapshot")
        check(relaunched.socialPublication(for: ride, currentProfileID: "organizer") == .ownCopy,
              "The organizer can still publish their own route")
        // An exported copy re-imported without its sidecar, even reversed, is matched by geometry.
        let reimported = try relaunched.importGPX(gpx(reversed: true), fileName: "Exported.gpx")
        check(reimported.id != saved.id && reimported.id != copy.id, "Re-import creates a new local identity")
        check(relaunched.socialPublication(for: reimported, currentProfileID: "me") == .restricted(owner: "rider"),
              "Re-imported copies are recognized by route geometry")
        // The rider's own unrelated GPX import remains publishable.
        let own = try relaunched.importGPX(gpx(offset: 0.05), fileName: "Mine.gpx")
        check(relaunched.socialPublication(for: own, currentProfileID: "me") == .independent, "Own GPX imports stay publishable")
        // Unreadable provenance never grants publication.
        try Data("{".utf8).write(to: sidecar)
        check(relaunched.socialPublication(for: copy, currentProfileID: "rider") == .restricted(owner: ""),
              "A corrupt sidecar fails closed")
        // Schema-1 sidecars written before restrictions existed still restrict by owner.
        let legacy = try JSONSerialization.data(withJSONObject: ["schema": 1, "socialID": "old", "owner": "rider",
            "socialRevision": 1, "sourceRouteID": saved.id.uuidString, "sourceRevision": 1, "sourceHash": original.contentHash])
        try legacy.write(to: provenance.appendingPathComponent(saved.id.uuidString + ".json"))
        check(relaunched.socialPublication(for: saved, currentProfileID: "me") == .restricted(owner: "rider"),
              "Legacy sidecars restrict by owner")
        // Native fingerprints match the backend reference vectors byte for byte.
        check(SocialRouteGeometry.fingerprint([(51.5, -0.1), (51.502, -0.1), (51.504, -0.1000004)])
              == "57424a01bcdb7b9435cd88b98d443c20878d901434ddfdc93085886de4794bb7", "Fingerprint parity, forward")
        check(SocialRouteGeometry.fingerprint([(51.504, -0.1000004), (51.502, -0.1), (51.5, -0.1)])
              == "57424a01bcdb7b9435cd88b98d443c20878d901434ddfdc93085886de4794bb7", "Fingerprint parity, reversed")
        check(SocialRouteGeometry.fingerprint([(-33.8688, 151.2093), (-33.86885, 151.20935)])
              == "643bc165b37ae90cd785b174bcb26db6016f7c90cca19c8a5b41516bfc7ff8bf", "Fingerprint parity, southern/eastern")
        let strava = try NavigationRouteArchiveV1.create(route: changedProvider(original.route, RouteProviderPolicyV1.strava), createdAt: f.now,
            deleteAfter: f.now.addingTimeInterval(60), purpose: .offlineNavigation)
        failure { _ = try f.library.importSocialArchive(strava.encoded(purpose: .offlineNavigation, now: f.now),
            source: SocialRouteSource(kind: .content, socialID: "restricted", owner: "rider", revision: 1), duplicate: true) }
        print("Social route provenance and publishing restrictions: \(checks - before) checks passed")
    }

    static func socialMapKitCopyKeepsExactRoute() throws {
        let f = Fixture(); defer { f.cleanup() }
        let planned = changedProvider(try draft(f).archive.route, RouteProviderPolicyV1.mapKit)
        let saved = try f.library.saveOffline(.plannedMapKit(planned, createdAt: f.now), name: "Selected Apple Maps route")
        let original = try f.library.offlineArchive(for: saved.summary)
        check(RouteProviderPolicyV1.allowsSocialSharing(original.route.provider), "Explicitly saved Apple Maps routes support social sharing")
        check(!RouteProviderPolicyV1.allowsSocialSharing(RouteProviderPolicyV1.mapKit), "Active MapKit responses remain private")
        check(!RouteProviderPolicyV1.allowsSocialSharing(RouteProviderPolicyV1.strava), "Strava sharing stays disabled")
        let data = try original.encoded(purpose: .offlineNavigation, now: f.now)
        let recipient = Fixture(); defer { recipient.cleanup() }
        let source = SocialRouteSource(kind: .ride, socialID: "apple-maps-group", owner: "organizer", revision: nil)
        let received = try recipient.library.importSocialArchive(data, source: source, duplicate: false)
        let restored = try recipient.library.offlineArchive(for: received)
        check(restored == original, "Joining and saving preserves the exact archive, provider, geometry, steps and content hash")
        check(restored.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone, "Received Apple Maps routes retain attribution and phone-only scope")
        check(recipient.library.socialPublication(for: received, currentProfileID: "member") == .restricted(owner: "organizer"),
              "Received Apple Maps routes remain the organizer's to share")
        let duplicate = try recipient.library.importSocialArchive(data, source: source, duplicate: true)
        let copied = try recipient.library.offlineArchive(for: duplicate)
        check(copied.route.points == original.route.points && copied.route.steps == original.route.steps && copied.route.provider == original.route.provider,
              "An explicit duplicate preserves Apple Maps geometry, instructions and attribution")
        check(recipient.library.socialPublication(for: duplicate, currentProfileID: "member") == .restricted(owner: "organizer"),
              "Duplicating an Apple Maps route does not grant publishing rights")
        check(recipient.watch.transferredRouteIDs.isEmpty, "Saving a received Apple Maps route does not transfer it to Watch")
        failure { _ = try restored.encoded(purpose: .watchTransfer, now: f.now) }
        let relaunched = recipient.makeLibrary()
        check(try relaunched.offlineArchive(for: received) == original, "Exact group route survives recipient app relaunch")
    }

    static func operationReceiptAndCrashRecovery() throws {
        let f = Fixture(); defer { f.cleanup() }
        let summary = try f.library.importGPX(gpx(), fileName: "Crash.gpx")
        let archive = try f.library.offlineArchive(for: summary)
        let identity = WatchRouteIdentityV1(archive: archive)
        let bytes = try archive.encoded(purpose: .offlineNavigation, now: f.now)
        try f.library.sendToWatch(summary)
        let oldInstall = f.watch.operations[identity]!
        let journal = WatchRouteOperationJournalV2(rootDirectory: f.root)
        let deletion = try journal.issue(.delete, identity: identity)
        let restarted = f.makeLibrary()
        check(restarted.offlineNavigationRoutes.isEmpty, "journaled delete excludes navigation after crash")
        check(f.watch.operations[identity] == deletion, "restart queues the exact persisted deletion")
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(operation: .acknowledge,
            identity: identity, status: .ready, deliveryOperation: oldInstall))
        check(restarted.offlineNavigationRoutes.isEmpty, "old install receipt cannot overwrite deletion intent")
        try journal.complete(.delete, identity: identity, token: deletion)
        let afterReceiptCrash = f.makeLibrary()
        check(afterReceiptCrash.routes.isEmpty && f.store.records(now: f.now).isEmpty,
              "crash after receipt but before unlink completes local deletion on restart")
        let imported = try afterReceiptCrash.importArchive(bytes)
        try afterReceiptCrash.sendToWatch(imported)
        let newer = f.watch.operations[identity]!
        check(newer.generation > deletion.generation, "explicit reimport can reinstall identical bytes")
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(operation: .acknowledge,
            identity: identity, status: .deleted, deliveryOperation: deletion))
        check(afterReceiptCrash.routes.count == 1, "old deletion receipt cannot delete explicit reinstall")
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(operation: .acknowledge,
            identity: identity, status: .ready))
        check(afterReceiptCrash.watchSyncState[identity] == .ready, "only exact successor receipt marks ready")
        f.watch.state.routeSyncSchemaVersion = 1
        try afterReceiptCrash.sendToWatch(imported)
        check(afterReceiptCrash.watchSyncState[identity] == .rejected("watch_update_required"),
              "older Watch requires update instead of an unacknowledgeable transfer")
    }

    static func unavailableWatchDeletionAndFenceRenewal() throws {
        let f = Fixture(); defer { f.cleanup() }
        let summary = try f.library.importGPX(gpx(), fileName: "Away.gpx")
        let identity = WatchRouteIdentityV1(archive: try f.library.offlineArchive(for: summary))
        try f.library.sendToWatch(summary)
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .ready))
        f.watch.acceptsDeletion = false
        try f.library.delete(summary)
        check(f.library.routes.isEmpty && f.store.records(now: f.now).isEmpty,
              "An unavailable Watch does not keep a deleted route on iPhone")
        let journal = WatchRouteOperationJournalV2(rootDirectory: f.root)
        let fence = try journal.entry(identity)
        check(fence?.operation == .delete && fence?.applied == false,
              "The journaled deletion waits for the Watch")
        f.watch.acceptsDeletion = true
        f.watch.operations[identity] = nil
        f.watch.state = .init(isActivated: true, isPaired: true, isWatchAppInstalled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(fence?.token != nil && f.watch.operations[identity] == fence?.token,
              "A returning Watch receives the exact persisted deletion without reachability")
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .rejected,
            errorCode: "stale_operation"))
        let renewed = try journal.entry(identity)
        check(renewed?.operation == .delete && renewed?.applied == false &&
              (renewed?.token?.generation ?? 0) > (fence?.token?.generation ?? 0),
              "A superseded fence advances its generation instead of resending forever")
        f.watch.onRouteAcknowledgement?(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .deleted,
            deliveryOperation: renewed?.token))
        let settled = try journal.entry(identity)
        check(settled?.applied == true && settled?.token == renewed?.token,
              "Only the renewed operation's receipt settles the deletion")
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
        let hongKongPoints = [CLLocationCoordinate2D(latitude: 22.2810, longitude: 114.1600),
                              CLLocationCoordinate2D(latitude: 22.2820, longitude: 114.1610)]
        let hongKong = try MapKitRouteAdapter.route(from: TestRoute(instructions: "Continue", coordinates: hongKongPoints))
        // MKPolyline stores map points, so coordinates come back within millimetres.
        func shift(_ route: NavigationRouteV1, _ input: CLLocationCoordinate2D) -> Double {
            NavigationGeometryV1.distance(from: route.points[0],
                to: RouteCoordinateV1(latitude: input.latitude, longitude: input.longitude))
        }
        check(hongKong.points.count == 2 && shift(hongKong, hongKongPoints[0]) < 0.01 && shift(china, chinaPoints[0]) > 100 &&
            hongKong.normalizationVersion == 2 && china.normalizationVersion == 2,
            "Apple Maps routes are WGS-84 in Hong Kong and stay unshifted; only mainland China is normalized, as version 2")
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
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
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
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
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
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
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
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
            operation: .acknowledge, identity: identity, status: .rejected, errorCode: "in_use"))
        check(!restarted.isAvailableOffline(saved.summary), "A rejected receipt keeps the durable deletion intent for retry")
        try restarted.delete(saved.summary)
        f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
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
                f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
                    operation: .acknowledge, identity: identity, status: .ready, errorCode: nil))
                f.fileManager.failsRouteDeletion = true
                if provider == RouteProviderPolicyV1.strava {
                    failure { try f.library.delete(summary) }
                    check(f.library.routes.isEmpty, "Failed provider removal stays hidden, not available again")
                } else {
                    try f.library.delete(summary)
                }
                f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
                    operation: .acknowledge, identity: identity, status: status, errorCode: nil))
                let deletion = try WatchRouteOperationJournalV2(rootDirectory: f.root).entry(identity)
                check(deletion?.operation == .delete && deletion?.applied == true,
                      "Exact deleted or evicted receipt settles the durable deletion before unlink")
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
            f.watch.acknowledgeCurrent(WatchRouteSyncMessageV1(
                operation: .acknowledge, identity: identity, status: status, errorCode: nil))
            check(f.library.isAvailableOffline(summary), "Unrequested Watch removal does not delete the iPhone copy")
        }
    }

    /// Version 1's normalization exactly as the app ran it before version 2.
    private static func version1(_ coordinate: RouteCoordinateV1) -> RouteCoordinateV1 {
        func inRectangle(_ latitude: Double, _ longitude: Double) -> Bool {
            latitude >= 0.8293 && latitude <= 55.8271 && longitude >= 72.004 && longitude <= 135.5
        }
        guard inRectangle(coordinate.latitude, coordinate.longitude) else { return coordinate }
        var latitude = coordinate.latitude
        var longitude = coordinate.longitude
        for _ in 0..<3 {
            let projected = inRectangle(latitude, longitude)
                ? GCJ02.fromWGS84(latitude: latitude, longitude: longitude)
                : (latitude: latitude, longitude: longitude)
            latitude += coordinate.latitude - projected.latitude
            longitude += coordinate.longitude - projected.longitude
        }
        return RouteCoordinateV1(latitude: latitude, longitude: longitude)
    }

    /// A Hong Kong route saved by version 1 lies about 600 m off the road. Every
    /// saved-route path reads it on the road, while the saved revision keeps its
    /// bytes, hash and identity.
    static func legacyMapKitArchives() throws {
        let f = Fixture(); defer { f.cleanup() }
        let before = checks
        let road = (0..<20).map {
            RouteCoordinateV1(latitude: 22.2810 + Double($0) * 0.0005, longitude: 114.1600 + Double($0) * 0.0003)
        }
        let stored = road.map(version1)
        func near(_ point: RouteCoordinateV1, _ target: RouteCoordinateV1, _ meters: Double = 0.01) -> Bool {
            NavigationGeometryV1.distance(from: point, to: target) < meters
        }
        func onRoad(_ points: [RouteCoordinateV1], _ meters: Double = 0.01) -> Bool {
            points.count == road.count && zip(points, road).allSatisfy { near($0, $1, meters) }
        }
        check(zip(stored, road).allSatisfy { !near($0, $1, 500) }, "Version 1 saved this Hong Kong route off the road")
        let saved = try NavigationRouteArchiveV1.create(route: NavigationRouteV1(
            id: UUID(), revision: 1, provider: RouteProviderPolicyV1.mapKitSavedOnPhone,
            localeIdentifier: "en_HK", transportType: .cycling,
            source: RouteEndpointV1(coordinate: stored[0], label: "Central"),
            destination: RouteEndpointV1(coordinate: stored[19], label: "Causeway Bay"),
            bounds: RouteBoundsV1.enclosing(stored)!, distanceMeters: 1_300, expectedTravelTimeSeconds: 360,
            name: "Harbour ride", points: stored,
            steps: [NavigationRouteStepV1(id: 1, geometryStartIndex: 0, geometryEndIndex: 19,
                instruction: "Ride to Causeway Bay", maneuver: .straight, distanceMeters: 1_300)],
            normalizationVersion: 1), createdAt: f.now, purpose: .offlineNavigation)
        let data = try saved.encoded(purpose: .offlineNavigation, now: f.now)
        let summary = try f.library.importArchive(data)
        let file = f.root.appendingPathComponent(
            "\(saved.routeID.uuidString.lowercased())-r1-\(saved.contentHash).routev1")

        // The library row keeps its identity and shows where the route goes.
        check(summary.id == saved.routeID && summary.revision == 1 && summary.contentHash == saved.contentHash,
              "Loading a version-1 route keeps its library identity")
        check(near(summary.source.coordinate, road[0]) && near(summary.destination.coordinate, road[19]),
              "The library row shows the route's start and destination on the road")
        let relaunched = f.makeLibrary()
        let loaded = try relaunched.offlineArchive(for: summary)
        let reencoded = try loaded.encoded(purpose: .offlineNavigation, now: f.now)
        let onDisk = try Data(contentsOf: file)
        check(loaded.storedRoute == saved.storedRoute && loaded.contentHash == saved.contentHash &&
              reencoded == data && onDisk == data && onRoad(loaded.route.points),
              "After a relaunch the saved bytes and hash are unchanged and the route is read on the road")

        // The saved-route map and offline navigation draw and follow the road.
        let selection = try relaunched.mapSelection(for: summary)
        check(selection.identity == WatchRouteIdentityV1(archive: saved) && onRoad(selection.route.points),
              "The saved-route map draws the route on the road")
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: TestNavigationDirectionsFactory().makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        try coordinator.startOfflineNavigation(loaded)
        let polyline = coordinator.offlineRoutePolyline
        var drawn = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline?.pointCount ?? 0)
        polyline?.getCoordinates(&drawn, range: NSRange(location: 0, length: drawn.count))
        check(coordinator.offlineRouteSummary == summary &&
              onRoad(drawn.map { RouteCoordinateV1(latitude: $0.latitude, longitude: $0.longitude) }),
              "Offline navigation draws the route on the road in Apple Maps")
        coordinator.stopNavigation()
        let engine = NavigationEngine(now: { f.now })
        try engine.startOfflineNavigation(archive: loaded,
            initialLocation: fix(f, latitude: road[0].latitude, longitude: road[0].longitude))
        defer { engine.stopNavigation() }
        let snapshot = engine.offlineSnapshotForTesting
        var window: [RouteCoordinateV1] = []
        if let bytes = snapshot.map({ [UInt8]($0.routeWindow) }), bytes.count >= 8 {
            func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
                (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(truncatingIfNeeded: bytes[offset + $1]) << ($1 * 8) }
            }
            var latitude = Int64(integer(0, Int32.self))
            var longitude = Int64(integer(4, Int32.self))
            window.append(RouteCoordinateV1(latitude: Double(latitude) / 1e6, longitude: Double(longitude) / 1e6))
            for offset in stride(from: 8, to: bytes.count, by: 4) {
                latitude += Int64(integer(offset, Int16.self))
                longitude += Int64(integer(offset + 2, Int16.self))
                window.append(RouteCoordinateV1(latitude: Double(latitude) / 1e6, longitude: Double(longitude) / 1e6))
            }
        }
        check(snapshot?.contentHash == saved.contentHash && snapshot?.offRouteDistanceMeters == nil &&
              onRoad(window, 0.2),
              "A rider on the road is on the route, and the Bicino receives the road under the original hash")

        // Its elevation profile is measured along the road and kept offline.
        let binding = PhoneRouteLibrary.elevationBinding(for: loaded)
        check(binding == RouteElevationArchiveBindingV1(routeID: saved.routeID, revision: 1, contentHash: saved.contentHash) &&
              relaunched.elevationSubject(for: binding).map { onRoad($0.route.points) } == true,
              "The elevation profile keeps the route's binding and follows the road")
        func profile(_ points: [RouteCoordinateV1]) throws -> RouteElevationProfileV1 {
            let geometry = try RouteElevationProcessorV1.geometry(points: points)
            let plan = RouteElevationProcessorV1.plan(length: geometry.lengthMeters)
            return RouteElevationProcessorV1.process(geometry: geometry, plan: plan,
                rawElevations: plan.distancesMeters.map { Optional(20 + $0 * 0.01) },
                source: RouteElevationProfileV1.Source(kind: "internal-dem", id: "fixture-terrain", version: nil,
                    verticalDatum: nil, nativeResolutionM: nil, surfaceModel: nil, interpolation: "fixture",
                    attribution: [], retrievedAt: nil, qualification: "fixture"))!
        }
        let offRoad = try profile(stored)
        relaunched.storeElevationProfile(offRoad, for: binding)
        check(relaunched.elevationSidecar(for: binding)?.geometryDigest == offRoad.geometry.digest,
              "A profile cached before the update describes the stored line")
        let alongRoad = try profile(loaded.route.points)
        relaunched.storeElevationProfile(alongRoad, for: binding)
        check(relaunched.elevationSidecar(for: binding)?.geometryDigest == alongRoad.geometry.digest &&
              relaunched.elevationSidecar(for: binding)?.serviceProfile == alongRoad,
              "The profile measured along the road replaces it under the same binding")

        // Starring the route favorites its real destination.
        let favorite = SavedRouteFavoritePolicy.favorite(for: summary)
        check(favorite.coordinate.map { near(RouteCoordinateV1(latitude: $0.latitude, longitude: $0.longitude), road[19]) } == true,
              "A favorite starred from the route is its destination on the road")

        // Sharing uploads the stored bytes; copies keep the stored route and
        // its geometry fingerprint, so the owner's rights hold.
        let sharedPayload = try loaded.socialHashPayload()
        let savedPayload = try saved.socialHashPayload()
        check(PhoneRouteLibrary.socialGeometry(loaded) ==
              SocialRouteGeometry.fingerprint(stored.map { (latitude: $0.latitude, longitude: $0.longitude) }) &&
              reencoded == data && sharedPayload == savedPayload,
              "Sharing sends the stored route, which the backend fingerprints")
        let recipient = Fixture(); defer { recipient.cleanup() }
        let source = SocialRouteSource(kind: .content, socialID: "harbour", owner: "organizer", revision: 1)
        let received = try recipient.library.importSocialArchive(data, source: source, duplicate: false)
        let duplicate = try recipient.library.importSocialArchive(data, source: source, duplicate: true)
        let copy = try recipient.library.offlineArchive(for: duplicate)
        let receivedBytes = try recipient.library.offlineArchive(for: received)
            .encoded(purpose: .offlineNavigation, now: f.now)
        check(received.contentHash == saved.contentHash && receivedBytes == data,
              "A received copy keeps the original bytes and hash")
        check(copy.storedRoute.points == stored && copy.storedRoute.normalizationVersion == 1 && onRoad(copy.route.points),
              "A duplicate keeps the stored route and is read on the road like the original")
        try FileManager.default.removeItem(at: recipient.root
            .appendingPathComponent("social-provenance").appendingPathComponent(duplicate.id.uuidString + ".json"))
        check(recipient.library.socialPublication(for: duplicate, currentProfileID: "member") == .restricted(owner: "organizer"),
              "A duplicate that lost its sidecar is still matched to its owner by stored geometry")
        print("Version-1 Apple Maps archives: \(checks - before) checks passed")
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
            section.contains("Label(\"Create a Route\"") &&
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
