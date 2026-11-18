import Combine
import CoreLocation
import Foundation
import MapKit

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
        try await testProviderFallsBackToCarWhereCyclingIsUnavailable()
        try await testProviderPrefersCarRoutesWithoutHighwaysOrTolls()
        try await testProviderReportsOtherFailuresUnchanged()
        try await testProviderStartsNoCarRequestAfterCancellation()
        try await testCarDirectionsNoticeFollowsTheActiveRoute()
        try await testCyclingRerouteCanFallBackToCar()
        print("WatchOnlineNavigationTests passed")
    }

    private static let clearCarNotice =
        "No cycling directions here: car route without highways or tolls"

    /// Where Apple Maps has no cycling coverage (the UAE, for example), a
    /// cycling request fails with the server-failure code and directions
    /// error 8. The provider then asks for car directions that avoid highways
    /// and tolls for the same endpoints, as iPhone does.
    private static func testProviderFallsBackToCarWhereCyclingIsUnavailable()
        async throws {
        let directions = TestDirectionsFactory()
        let provider = WatchOnlineRouteProvider(
            directionsFactory: { directions.make($0) }
        )
        directions.outcomes = [
            .failure(directionsError(8)),
            .routes([TestMapKitRoute(distance: 380)]),
        ]
        let options = try await provider.routes(for: providerRequest())
        let cycling = directions.requests.first
        let car = directions.requests.last
        expect(
            directions.requests.count == 2 &&
                cycling?.transportType == .cycling &&
                cycling?.highwayPreference == .any &&
                cycling?.tollPreference == .any &&
                cycling?.requestsAlternateRoutes == false,
            "the first request asks for plain cycling directions"
        )
        expect(
            car?.transportType == .automobile &&
                car?.highwayPreference == .avoid &&
                car?.tollPreference == .avoid,
            "out of cycling coverage the request is repeated as car " +
                "directions that avoid highways and tolls"
        )
        expect(
            car?.source != nil && car?.source === cycling?.source &&
                car?.destination != nil &&
                car?.destination === cycling?.destination &&
                car?.requestsAlternateRoutes == true,
            "the car request keeps the endpoints and asks for alternatives, " +
                "to find a route without highways or tolls"
        )
        let option = options.first
        expect(
            options.count == 1 &&
                option?.notice == clearCarNotice &&
                option?.route.transportType == .cycling &&
                option?.route.provider == RouteProviderPolicyV1.mapKit,
            "the car route says it has no highways or tolls; the ride stays cycling"
        )
        expect(
            option?.route.expectedTravelTimeSeconds.map {
                abs($0 - 380 / (15_000.0 / 3_600)) < 0.001
            } == true,
            "the car route is timed at a cycling pace, not a car's"
        )

        let cyclingDirections = TestDirectionsFactory()
        let cyclingProvider = WatchOnlineRouteProvider(
            directionsFactory: { cyclingDirections.make($0) }
        )
        cyclingDirections.outcomes = [.routes([TestMapKitRoute()])]
        let cyclingOptions = try await cyclingProvider.routes(
            for: providerRequest()
        )
        expect(
            cyclingDirections.requests.count == 1 &&
                cyclingOptions.count == 1 &&
                cyclingOptions.first?.notice == nil,
            "cycling directions where Apple Maps has them make one request " +
                "and carry no notice"
        )
    }

    /// Avoiding highways and tolls is only a preference to MapKit, which
    /// still offers routes on them. Routes without them come first, shortest
    /// first; with none, the shortest car route says what it uses.
    private static func testProviderPrefersCarRoutesWithoutHighwaysOrTolls()
        async throws {
        let directions = TestDirectionsFactory()
        let provider = WatchOnlineRouteProvider(
            directionsFactory: { directions.make($0) }
        )
        let mixed: () -> [MKRoute] = {
            [
                TestMapKitRoute(
                    distance: 300,
                    highways: true,
                    tolls: true,
                    name: "Sheikh Zayed Road"
                ),
                TestMapKitRoute(distance: 450, name: "Al Wasl Road"),
                TestMapKitRoute(distance: 400, name: "Jumeira Street"),
            ]
        }
        directions.outcomes = [
            .failure(directionsError(8)),
            .routes(mixed()),
            .failure(directionsError(8)),
            .routes([
                TestMapKitRoute(distance: 300, highways: true),
                TestMapKitRoute(distance: 250, tolls: true),
            ]),
            .failure(directionsError(8)),
            .routes(mixed()),
        ]
        let single = try await provider.routes(for: providerRequest())
        expect(
            single.count == 1 &&
                single.first?.route.name == "Jumeira Street" &&
                single.first?.notice == clearCarNotice,
            "one route: the shortest without highways or tolls"
        )
        let onlyBusyRoads = try await provider.routes(for: providerRequest())
        expect(
            onlyBusyRoads.count == 1 &&
                onlyBusyRoads.first?.route.distanceMeters == 250 &&
                onlyBusyRoads.first?.notice ==
                    "No cycling directions here: car route uses toll " +
                    "roads; check it suits a bike",
            "without such a route, the shortest car route says what it uses"
        )
        let alternatives = try await provider.routes(
            for: providerRequest(alternatives: true)
        )
        expect(
            alternatives.map(\.route.name) ==
                ["Jumeira Street", "Al Wasl Road"] &&
                alternatives.allSatisfy { $0.notice == clearCarNotice },
            "alternatives keep every route without highways or tolls, " +
                "shortest first"
        )
        expect(
            directions.requests.count == 6 &&
                directions.requests.enumerated().allSatisfy {
                    $0.element.transportType ==
                        ($0.offset.isMultiple(of: 2) ? .cycling : .automobile)
                },
            "every call, a reroute too, asks for cycling directions first"
        )
    }

    private static func testProviderReportsOtherFailuresUnchanged()
        async throws {
        let failures: [(String, Error)] = [
            ("not reachable (16)", directionsError(16)),
            ("a plain server failure", MKError(.serverFailure)),
            ("directions not found", MKError(.directionsNotFound)),
            ("throttling", MKError(.loadingThrottled)),
            ("no connection", URLError(.notConnectedToInternet)),
            ("code 8 from another domain", NSError(
                domain: "Other",
                code: Int(MKError.Code.serverFailure.rawValue),
                userInfo: ["MKDirectionsErrorCode": 8]
            )),
        ]
        for (name, failure) in failures {
            let directions = TestDirectionsFactory()
            let provider = WatchOnlineRouteProvider(
                directionsFactory: { directions.make($0) }
            )
            directions.outcomes = [
                .failure(failure),
                .routes([TestMapKitRoute()]),
            ]
            let error = await routeFailure(of: provider, providerRequest())
            expect(
                error.map { sameFailure($0, failure) } == true &&
                    directions.requests.count == 1,
                "\(name) is reported unchanged without a car request"
            )
        }

        let directions = TestDirectionsFactory()
        let provider = WatchOnlineRouteProvider(
            directionsFactory: { directions.make($0) }
        )
        directions.outcomes = [
            .failure(directionsError(8)),
            .failure(MKError(.directionsNotFound)),
            .failure(directionsError(8)),
            .routes([]),
            .failure(directionsError(8)),
            .failure(URLError(.timedOut)),
        ]
        let noCarRoute = await routeFailure(of: provider, providerRequest())
        expect(
            noCarRoute.map { sameFailure($0, directionsError(8)) } == true &&
                directions.requests.count == 2,
            "a car request that finds no route reports why cycling failed"
        )
        let emptyCar = await routeFailure(of: provider, providerRequest())
        expect(
            emptyCar.map { sameFailure($0, directionsError(8)) } == true &&
                directions.requests.count == 4,
            "a car fallback without routes reports why cycling failed"
        )
        let transient = await routeFailure(of: provider, providerRequest())
        expect(
            transient.map { sameFailure($0, URLError(.timedOut)) } == true &&
                directions.requests.count == 6,
            "a car request that fails for a connection reason reports that, " +
                "as iPhone does"
        )
    }

    /// MapKit can still finish a cancelled request with the out-of-coverage
    /// failure (seen on the watchOS 27 simulator), so cancellation must stop
    /// the car request from starting.
    private static func testProviderStartsNoCarRequestAfterCancellation()
        async throws {
        for cancellation in ["provider", "task", "newer request"] {
            let directions = TestDirectionsFactory()
            let provider = WatchOnlineRouteProvider(
                directionsFactory: { directions.make($0) }
            )
            directions.outcomes = [
                .pending,
                .routes([TestMapKitRoute()]),
                .routes([TestMapKitRoute()]),
            ]
            let task = Task { try await provider.routes(for: providerRequest()) }
            await settle()
            switch cancellation {
            case "provider":
                provider.cancel()
            case "task":
                task.cancel()
            default:
                let newer = try await provider.routes(for: providerRequest())
                expect(
                    newer.count == 1 && newer.first?.notice == nil,
                    "the newer request gets its own cycling route"
                )
            }
            directions.tasks.first?.resolve(.failure(directionsError(8)))
            var isCancellation = false
            if case .failure(let error) = await task.result {
                isCancellation = error is CancellationError
            }
            expect(
                isCancellation &&
                    directions.requests.allSatisfy {
                        $0.transportType == .cycling
                    } &&
                    directions.requests.count ==
                        (cancellation == "newer request" ? 2 : 1),
                "cancellation by \(cancellation) starts no car request"
            )
            // The manager cancels the provider with its task; a task
            // cancelled alone leaves the MapKit request running.
            expect(
                cancellation == "task" ||
                    directions.tasks.first?.isCancelled == true,
                "cancellation by \(cancellation) cancels the MapKit request"
            )
        }
    }

    /// The notice belongs to the active route: a car route says what it
    /// uses, its reroute brings its own notice, and stopping clears it.
    private static func testCarDirectionsNoticeFollowsTheActiveRoute()
        async throws {
        let harness = try Harness(network: .available)
        defer { harness.cleanup() }
        harness.settings.setUseWatchCellularConnection(true)
        let highwayNotice =
            "No cycling directions here: car route uses highways; " +
            "check it suits a bike"
        harness.provider.outcomes = [
            .success(route(), notice: clearCarNotice),
            .success(reroutedRoute(), notice: highwayNotice),
        ]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.manager.snapshot?.routeID == route().id &&
                harness.manager.routeDirectionsNotice == clearCarNotice,
            "a car route starts and says it has no highways or tolls"
        )
        emitOffRoute(harness)
        await settle()
        expect(
            harness.provider.requests.count == 2 &&
                harness.manager.snapshot?.routeID == reroutedRoute().id &&
                harness.manager.onlineStatus == .online &&
                harness.manager.routeDirectionsNotice == highwayNotice,
            "its reroute shows the new route's own notice"
        )
        _ = harness.manager.stopNavigation()
        expect(
            harness.manager.routeDirectionsNotice == nil,
            "stopping navigation clears the notice"
        )
        harness.provider.outcomes = [.success(route())]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.provider.requests.count == 3 &&
                harness.manager.snapshot?.routeID == route().id &&
                harness.manager.routeDirectionsNotice == nil,
            "a cycling route that follows shows no notice"
        )
    }

    /// A cycling route can lead out of Apple Maps' cycling coverage; its
    /// reroute then comes back as car directions, which the rider is told.
    /// A failed reroute keeps the car route and its notice, and a reroute
    /// that finds cycling directions again clears it.
    private static func testCyclingRerouteCanFallBackToCar() async throws {
        let harness = try Harness(network: .available)
        defer { harness.cleanup() }
        harness.settings.setUseWatchCellularConnection(true)
        let backToCycling = route(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-ffffffffffff")!,
            points: [
                RouteCoordinateV1(latitude: 0.001, longitude: 0.0002),
                RouteCoordinateV1(latitude: 0, longitude: 0.001),
            ],
            distanceMeters: 142
        )
        harness.provider.outcomes = [
            .success(route()),
            .success(reroutedRoute(), notice: clearCarNotice),
            .failure(TestProviderError.unavailable),
            .success(backToCycling),
        ]
        harness.manager.startOnline(destination: favorite())
        await settle()
        expect(
            harness.manager.snapshot?.routeID == route().id &&
                harness.manager.routeDirectionsNotice == nil,
            "a cycling route shows no car notice"
        )
        emitOffRoute(harness)
        await settle()
        expect(
            harness.provider.requests.count == 2 &&
                harness.manager.snapshot?.routeID == reroutedRoute().id &&
                harness.manager.routeDirectionsNotice == clearCarNotice,
            "a cycling reroute that fell back to car directions says so"
        )
        harness.manager.recalculateOnlineRoute()
        await settle()
        expect(
            harness.provider.requests.count == 3 &&
                harness.manager.onlineStatus == .rerouteFailed &&
                harness.manager.snapshot?.routeID == reroutedRoute().id &&
                harness.manager.routeDirectionsNotice == clearCarNotice,
            "a failed reroute keeps the car route and its notice"
        )
        harness.manager.recalculateOnlineRoute()
        await settle()
        expect(
            harness.provider.requests.count == 4 &&
                harness.manager.snapshot?.routeID == backToCycling.id &&
                harness.manager.routeDirectionsNotice == nil,
            "a reroute that finds cycling directions again clears the notice"
        )
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
        provider: RouteProviderMetadataV1? = nil,
        id: UUID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
        points: [RouteCoordinateV1] = [
            RouteCoordinateV1(latitude: 0, longitude: 0),
            RouteCoordinateV1(latitude: 0, longitude: 0.001),
        ],
        distanceMeters: Double = 111
    ) -> NavigationRouteV1 {
        let provider = provider ?? RouteProviderPolicyV1.mapKit
        return NavigationRouteV1(
            id: id,
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
            distanceMeters: distanceMeters,
            expectedTravelTimeSeconds: 30,
            name: "Online route",
            points: points,
            steps: [NavigationRouteStepV1(
                id: 1,
                geometryStartIndex: 0,
                geometryEndIndex: 1,
                instruction: "Arrive",
                maneuver: .arrive,
                distanceMeters: distanceMeters
            )],
            normalizationVersion: 1
        )
    }

    /// A replacement that starts where `emitOffRoute` leaves the rider.
    private static func reroutedRoute() -> NavigationRouteV1 {
        route(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-eeeeeeeeeeee")!,
            points: [
                RouteCoordinateV1(latitude: 0.001, longitude: 0.0002),
                RouteCoordinateV1(latitude: 0, longitude: 0.001),
            ],
            distanceMeters: 142
        )
    }

    /// About 111 m north of `route()`, enough samples to count as off route.
    private static func emitOffRoute(_ harness: Harness) {
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
    }

    /// A MapKit directions failure as watchOS reports it; the user-info key
    /// is spelled out here so a typo in the provider fails the tests.
    private static func directionsError(_ code: Int) -> NSError {
        NSError(
            domain: MKErrorDomain,
            code: Int(MKError.Code.serverFailure.rawValue),
            userInfo: ["MKDirectionsErrorCode": code]
        )
    }

    private static func sameFailure(_ lhs: Error, _ rhs: Error) -> Bool {
        let lhs = lhs as NSError
        let rhs = rhs as NSError
        return lhs.domain == rhs.domain && lhs.code == rhs.code &&
            lhs.userInfo["MKDirectionsErrorCode"] as? Int ==
                rhs.userInfo["MKDirectionsErrorCode"] as? Int
    }

    private static func routeFailure(
        of provider: WatchOnlineRouteProvider,
        _ request: NavigationRouteRequestV1
    ) async -> Error? {
        do {
            _ = try await provider.routes(for: request)
            return nil
        } catch {
            return error
        }
    }

    /// Burj Khalifa toward Dubai Marina, where Apple Maps has no cycling
    /// directions.
    private static func providerRequest(
        alternatives: Bool = false
    ) -> NavigationRouteRequestV1 {
        NavigationRouteRequestV1(
            source: RouteEndpointV1(
                coordinate: RouteCoordinateV1(
                    latitude: 25.1972,
                    longitude: 55.2744
                ),
                label: "Current Location"
            ),
            destination: RouteEndpointV1(
                coordinate: RouteCoordinateV1(
                    latitude: 25.1950,
                    longitude: 55.2715
                ),
                label: "Finish"
            ),
            localeIdentifier: "en_US",
            transportType: .cycling,
            requestAlternatives: alternatives
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
        case success(NavigationRouteV1, notice: String? = nil)
        case failure(Error)
        case pending
    }

    let metadata = RouteProviderPolicyV1.mapKit
    var outcomes: [Outcome] = []
    var requests: [NavigationRouteRequestV1] = []
    var pendingContinuation:
        CheckedContinuation<[NavigationRouteOptionV1], Error>?
    private(set) var cancellationCount = 0

    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> [NavigationRouteOptionV1] {
        requests.append(request)
        guard !outcomes.isEmpty else { throw TestProviderError.unavailable }
        switch outcomes.removeFirst() {
        case .success(let route, let notice):
            return [NavigationRouteOptionV1(route: route, notice: notice)]
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
        case .success(let route):
            continuation?.resume(returning: [
                NavigationRouteOptionV1(route: route, notice: nil),
            ])
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

/// Stands in for MapKit behind `WatchOnlineRouteProvider`.
@MainActor
private final class TestDirectionsFactory {
    enum Outcome {
        case routes([MKRoute])
        case failure(Error)
        case pending
    }

    var outcomes: [Outcome] = []
    private(set) var requests: [MKDirections.Request] = []
    private(set) var tasks: [TestDirections] = []

    func make(
        _ request: MKDirections.Request
    ) -> any WatchDirectionsCalculating {
        requests.append(request)
        let task = TestDirections(
            outcome: outcomes.isEmpty
                ? .failure(TestProviderError.unavailable)
                : outcomes.removeFirst()
        )
        tasks.append(task)
        return task
    }
}

@MainActor
private final class TestDirections: WatchDirectionsCalculating {
    private let outcome: TestDirectionsFactory.Outcome
    private var continuation: CheckedContinuation<[MKRoute], Error>?
    private(set) var isCancelled = false

    init(outcome: TestDirectionsFactory.Outcome) {
        self.outcome = outcome
    }

    func calculate() async throws -> [MKRoute] {
        switch outcome {
        case .routes(let routes):
            return routes
        case .failure(let error):
            throw error
        case .pending:
            return try await withCheckedThrowingContinuation {
                continuation = $0
            }
        }
    }

    /// Like MapKit, cancelling does not end a pending calculation.
    func cancel() {
        isCancelled = true
    }

    func resolve(_ result: Result<[MKRoute], Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

/// One step along three points near Burj Khalifa, with MapKit's car time.
private nonisolated final class TestMapKitRoute: MKRoute {
    private let storedPolyline: MKPolyline
    private let storedSteps: [MKRoute.Step]
    private let storedDistance: CLLocationDistance
    private let storedHasHighways: Bool
    private let storedHasTolls: Bool
    private let storedName: String

    init(
        distance: CLLocationDistance = 380,
        highways: Bool = false,
        tolls: Bool = false,
        name: String = "Test route"
    ) {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 25.1972, longitude: 55.2744),
            CLLocationCoordinate2D(latitude: 25.1961, longitude: 55.2730),
            CLLocationCoordinate2D(latitude: 25.1950, longitude: 55.2715),
        ]
        storedPolyline = MKPolyline(
            coordinates: coordinates,
            count: coordinates.count
        )
        storedSteps = [
            TestMapKitRouteStep(polyline: storedPolyline, distance: distance),
        ]
        storedDistance = distance
        storedHasHighways = highways
        storedHasTolls = tolls
        storedName = name
        super.init()
    }

    override var steps: [MKRoute.Step] { storedSteps }
    override var polyline: MKPolyline { storedPolyline }
    override var distance: CLLocationDistance { storedDistance }
    override var expectedTravelTime: TimeInterval { 120 }
    override var name: String { storedName }
    override var hasHighways: Bool { storedHasHighways }
    override var hasTolls: Bool { storedHasTolls }
}

private nonisolated final class TestMapKitRouteStep: MKRoute.Step {
    private let storedPolyline: MKPolyline
    private let storedDistance: CLLocationDistance

    init(polyline: MKPolyline, distance: CLLocationDistance) {
        storedPolyline = polyline
        storedDistance = distance
        super.init()
    }

    override var instructions: String { "Arrive at destination" }
    override var polyline: MKPolyline { storedPolyline }
    override var distance: CLLocationDistance { storedDistance }
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
