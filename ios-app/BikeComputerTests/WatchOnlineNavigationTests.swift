import Combine
import CoreLocation
import Foundation

@main
@MainActor
enum WatchOnlineNavigationTests {
    static func main() async throws {
        try testWatchLocalPolicyAuthority()
        try testFavoriteRevisionReconciliation()
        try await testOfflinePolicyMakesNoRequest()
        try await testAdvisoryNetworkAndPolicyGeneration()
        try await testRerouteFailurePreservesLoadedRoute()
        try await testNavigationPresentationAndIndependentRecovery()
        print("WatchOnlineNavigationTests passed")
    }

    private static func testNavigationPresentationAndIndependentRecovery()
        async throws {
        let harness = try Harness(network: .unavailable)
        defer { harness.cleanup() }
        let savedRoute = route(provider: RouteProviderPolicyV1.importedGPX)
        let archive = try NavigationRouteArchiveV1.create(
            route: savedRoute,
            purpose: .offlineNavigation
        )
        let identity = WatchRouteIdentityV1(archive: archive)
        _ = try harness.library.install(
            try archive.encoded(purpose: .offlineNavigation),
            expectedIdentity: identity
        )
        let sample = NavigationLocationSampleV1(
            coordinate: savedRoute.source.coordinate,
            horizontalAccuracyMeters: 5,
            courseDegrees: 0,
            speedMetersPerSecond: 5,
            altitudeMeters: 0,
            timestamp: Date()
        )
        try harness.journal.save(WatchNavigationJournalV1(
            identity: identity,
            mode: .offline,
            navigationGeneration: 1,
            currentStepIndex: 0,
            lastLocation: WatchNavigationJournalLocationV1(sample),
            startedAt: Date().addingTimeInterval(-30),
            updatedAt: Date()
        ))

        harness.manager.recoverIfNeeded()
        await settle()
        expect(
            harness.manager.shouldPresentNavigation &&
                harness.manager.snapshot?.routeID == savedRoute.id &&
                harness.device.demand,
            "navigation recovers and remains present without workout state"
        )
        expect(
            harness.manager.stopNavigation() &&
                !harness.manager.shouldPresentNavigation &&
                !harness.device.demand,
            "stopping navigation independently removes only navigation demand"
        )
    }

    private static func testOfflinePolicyMakesNoRequest() async throws {
        let harness = try Harness(network: .unavailable)
        defer { harness.cleanup() }
        harness.provider.outcomes = [.success(route())]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.provider.requests.isEmpty &&
                harness.manager.snapshot == nil &&
                harness.manager.onlineStatus == .offlinePolicy,
            "offline policy makes zero route-provider calls"
        )

        harness.settings.setUseWatchCellularConnection(true)
        harness.provider.outcomes = [.success(route())]
        harness.manager.startOnline(destination: favorite())
        harness.settings.setUseWatchCellularConnection(false)
        await settle()
        expect(
            harness.provider.requests.isEmpty,
            "turning policy off before task execution prevents the request"
        )

        let offlineHarness = try Harness(network: .available)
        defer { offlineHarness.cleanup() }
        let offlineRoute = route(provider: RouteProviderPolicyV1.importedGPX)
        let archive = try NavigationRouteArchiveV1.create(
            route: offlineRoute,
            purpose: .offlineNavigation
        )
        _ = try offlineHarness.library.install(
            try archive.encoded(purpose: .offlineNavigation),
            expectedIdentity: WatchRouteIdentityV1(archive: archive)
        )
        offlineHarness.manager.startOffline(routeID: offlineRoute.id)
        await settle()
        let base = Date()
        for offset in 1...3 {
            offlineHarness.location.emit(CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 0.001,
                    longitude: 0.0002
                ),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 0,
                speed: 5,
                timestamp: base.addingTimeInterval(Double(offset))
            ))
        }
        await settle()
        expect(
            offlineHarness.provider.requests.isEmpty &&
                offlineHarness.manager.snapshot?.offRouteDistanceMeters != nil,
            "offline deviation never invokes a provider"
        )
    }

    private static func testAdvisoryNetworkAndPolicyGeneration() async throws {
        let harness = try Harness(network: .unavailable)
        defer { harness.cleanup() }
        harness.settings.setUseWatchCellularConnection(true)
        harness.provider.outcomes = [.success(route())]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.provider.requests.count == 1 &&
                harness.manager.snapshot?.routeID == route().id,
            "explicit online routing may succeed despite advisory no-path state"
        )
        let loadedRouteID = harness.manager.snapshot?.routeID
        harness.network.send(.unavailable)
        expect(
            harness.manager.snapshot?.routeID == loadedRouteID &&
                harness.manager.snapshot?.mode == .onlineUsingCachedRoute,
            "network loss preserves the active route"
        )
        let callsBeforeToggle = harness.provider.requests.count
        harness.settings.setUseWatchCellularConnection(false)
        expect(
            harness.manager.snapshot?.routeID == loadedRouteID &&
                harness.manager.snapshot?.mode == .offline &&
                harness.manager.onlineStatus == .offlinePolicy,
            "turning policy off keeps the loaded route"
        )
        harness.settings.setUseWatchCellularConnection(true)
        await settle()
        expect(
            harness.provider.requests.count == callsBeforeToggle,
            "turning policy on does not immediately replace the route"
        )

        _ = harness.manager.stopNavigation()
        harness.provider.outcomes = [.pending]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.provider.pendingContinuation != nil,
            "the fake provider has an in-flight request"
        )
        harness.settings.setUseWatchCellularConnection(false)
        harness.provider.resolvePending(with: .success(route()))
        await settle()
        expect(
            harness.manager.snapshot == nil &&
                harness.manager.onlineStatus == .offlinePolicy,
            "a late result from the previous policy generation is rejected"
        )
    }

    private static func testRerouteFailurePreservesLoadedRoute() async throws {
        let harness = try Harness(network: .available)
        defer { harness.cleanup() }
        harness.settings.setUseWatchCellularConnection(true)
        harness.provider.outcomes = [
            .success(route()),
            .failure(TestProviderError.unavailable),
        ]
        harness.manager.startOnline(destination: favorite())
        await settle()
        let routeID = harness.manager.snapshot?.routeID
        let base = Date()
        for offset in 1...3 {
            harness.location.emit(CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 0.001,
                    longitude: 0.0002
                ),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 0,
                speed: 5,
                timestamp: base.addingTimeInterval(Double(offset))
            ))
        }
        await settle()
        expect(
            harness.provider.requests.count == 2 &&
                harness.manager.snapshot?.routeID == routeID &&
                harness.manager.onlineStatus == .rerouteFailed,
            "failed rerouting retains the complete prior route"
        )
    }

    private static func testWatchLocalPolicyAuthority() throws {
        let suite = "watch-online-policy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WatchNavigationSettingsStore(defaults: defaults)
        expect(
            !store.useWatchCellularConnection &&
                store.policy == .offlineOnly &&
                store.policyGeneration == 1,
            "missing preference always migrates to offline"
        )
        let generation = store.policyGeneration
        // Neither favorite sync nor a network-style callback has an API that
        // can mutate policy; receiving unrelated state leaves it unchanged.
        let favoriteStore = WatchFavoriteStore(defaults: defaults)
        favoriteStore.receiveApplicationContext(["network": "available"])
        expect(
            store.policy == .offlineOnly &&
                store.policyGeneration == generation,
            "environment callbacks cannot choose online policy"
        )
        store.setUseWatchCellularConnection(true)
        expect(
            store.policy == .onlineAllowed &&
                store.policyGeneration == generation + 1,
            "only the explicit setter changes policy and generation"
        )
        store.setUseWatchCellularConnection(true)
        expect(
            store.policyGeneration == generation + 1,
            "idempotent setting writes do not invalidate requests"
        )
        let restored = WatchNavigationSettingsStore(defaults: defaults)
        expect(
            restored.useWatchCellularConnection &&
                restored.policy == .onlineAllowed,
            "the Watch-local choice survives relaunch"
        )
    }

    private static func testFavoriteRevisionReconciliation() throws {
        let suite = "watch-online-favorites-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchFavoriteStore(defaults: defaults)
        let favorite = SyncedCoordinateFavoriteV1(
            id: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            name: "Home",
            coordinate: RouteCoordinateV1(latitude: 1, longitude: 2)
        )
        let revisionTwo = CoordinateFavoritesEnvelopeV1(
            revision: 2,
            favorites: [favorite]
        )
        store.receiveApplicationContext([
            CoordinateFavoritesEnvelopeV1.applicationContextKey:
                try revisionTwo.encoded(),
        ])
        expect(
            store.revision == 2 && store.favorites == [favorite],
            "a newer coordinate favorite context is installed"
        )
        store.receiveApplicationContext([
            CoordinateFavoritesEnvelopeV1.applicationContextKey:
                try CoordinateFavoritesEnvelopeV1(
                    revision: 1,
                    favorites: []
                ).encoded(),
        ])
        expect(
            store.revision == 2 && store.favorites == [favorite],
            "stale application context cannot erase favorites"
        )
        store.receiveApplicationContext([
            CoordinateFavoritesEnvelopeV1.applicationContextKey:
                try CoordinateFavoritesEnvelopeV1(
                    revision: 2,
                    favorites: []
                ).encoded(),
        ])
        expect(
            store.lastSyncError == "favorite_revision_conflict" &&
                store.favorites == [favorite],
            "same-revision equivocation is rejected"
        )
        let restored = WatchFavoriteStore(defaults: defaults)
        expect(
            restored.revision == 2 && restored.favorites == [favorite],
            "coordinate favorites survive Watch relaunch"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else { fatalError("FAILED: \(message)") }
    }

    private static func favorite() -> SyncedCoordinateFavoriteV1 {
        SyncedCoordinateFavoriteV1(
            id: UUID(
                uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
            )!,
            name: "Finish",
            coordinate: RouteCoordinateV1(latitude: 0, longitude: 0.001)
        )
    }

    private static func route(
        provider: RouteProviderMetadataV1? = nil
    ) -> NavigationRouteV1 {
        let provider = provider ?? RouteProviderPolicyV1.mapKit
        let points = [
            RouteCoordinateV1(latitude: 0, longitude: 0),
            RouteCoordinateV1(latitude: 0, longitude: 0.001),
        ]
        return NavigationRouteV1(
            id: UUID(
                uuidString: "cccccccc-1111-2222-3333-dddddddddddd"
            )!,
            revision: 1,
            provider: provider,
            localeIdentifier: "en_US",
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: points[0], label: "Start"),
            destination: RouteEndpointV1(
                coordinate: points[1],
                label: "Finish"
            ),
            bounds: RouteBoundsV1.enclosing(points)!,
            distanceMeters: 111,
            expectedTravelTimeSeconds: 30,
            name: "Online route",
            points: points,
            steps: [NavigationRouteStepV1(
                id: 1,
                geometryStartIndex: 0,
                geometryEndIndex: 1,
                instruction: "Arrive",
                maneuver: .arrive,
                distanceMeters: 111
            )],
            normalizationVersion: 1
        )
    }

    private static func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }
}

private enum TestProviderError: Error {
    case unavailable
}

@MainActor
private final class TestOnlineProvider: NavigationRouteProvider {
    enum Outcome {
        case success(NavigationRouteV1)
        case failure(Error)
        case pending
    }

    let metadata = RouteProviderPolicyV1.mapKit
    var outcomes: [Outcome] = []
    var requests: [NavigationRouteRequestV1] = []
    var pendingContinuation:
        CheckedContinuation<[NavigationRouteV1], Error>?
    private(set) var cancellationCount = 0

    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> [NavigationRouteV1] {
        requests.append(request)
        guard !outcomes.isEmpty else { throw TestProviderError.unavailable }
        switch outcomes.removeFirst() {
        case .success(let route):
            return [route]
        case .failure(let error):
            throw error
        case .pending:
            return try await withCheckedThrowingContinuation {
                pendingContinuation = $0
            }
        }
    }

    func cancel() {
        cancellationCount += 1
    }

    func resolvePending(
        with result: Result<NavigationRouteV1, Error>
    ) {
        let continuation = pendingContinuation
        pendingContinuation = nil
        switch result {
        case .success(let route): continuation?.resume(returning: [route])
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

@MainActor
private final class TestNavigationLocation:
    WatchNavigationLocationProviding {
    var latestLocation: CLLocation?
    private var handler: (@MainActor ([CLLocation]) -> Void)?

    init() {
        latestLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 5,
            timestamp: Date()
        )
    }

    func requestAuthorizationIfNeeded() {}

    func setNavigationConsumer(
        active: Bool,
        handler: (@MainActor ([CLLocation]) -> Void)?
    ) {
        self.handler = active ? handler : nil
    }

    func emit(_ location: CLLocation) {
        latestLocation = location
        handler?([location])
    }
}

@MainActor
private final class TestNavigationDeviceLink: WatchNavigationDeviceLinking {
    private(set) var demand = false
    private(set) var updates: [NavigationSnapshotV1] = []

    func setNavigationDemand(_ active: Bool) { demand = active }
    func updateNavigation(
        location: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1
    ) {
        updates.append(snapshot)
    }
    func endNavigationDemandAfterClearing() { demand = false }
}

@MainActor
private final class TestNetworkMonitor: WatchNetworkAvailabilityProviding {
    private let subject: CurrentValueSubject<WatchNetworkAvailabilityV1, Never>
    var availability: WatchNetworkAvailabilityV1 { subject.value }
    var availabilityPublisher:
        AnyPublisher<WatchNetworkAvailabilityV1, Never> {
        subject.eraseToAnyPublisher()
    }

    init(_ availability: WatchNetworkAvailabilityV1) {
        subject = CurrentValueSubject(availability)
    }

    func start() {}
    func send(_ availability: WatchNetworkAvailabilityV1) {
        subject.send(availability)
    }
}

@MainActor
private final class Harness {
    let root: URL
    let defaults: UserDefaults
    let settings: WatchNavigationSettingsStore
    let provider = TestOnlineProvider()
    let location = TestNavigationLocation()
    let device = TestNavigationDeviceLink()
    let network: TestNetworkMonitor
    let library: WatchRouteLibrary
    let journal: WatchNavigationJournalStore
    let manager: WatchNavigationManager
    private let suite: String

    init(network availability: WatchNetworkAvailabilityV1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch-online-manager-\(UUID().uuidString)",
            isDirectory: true
        )
        suite = "watch-online-manager-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = WatchNavigationSettingsStore(defaults: defaults)
        network = TestNetworkMonitor(availability)
        library = WatchRouteLibrary(
            store: NavigationRouteFileStoreV1(
                rootDirectory: root.appendingPathComponent("routes"),
                limits: .watch
            ),
            defaults: defaults
        )
        journal = WatchNavigationJournalStore(
            fileURL: root.appendingPathComponent("journal.plist")
        )
        manager = WatchNavigationManager(
            routeLibrary: library,
            locationService: location,
            deviceLink: device,
            journalStore: journal,
            settingsStore: settings,
            onlineProvider: provider,
            networkMonitor: network
        )
    }

    func cleanup() {
        _ = manager.stopNavigation()
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
