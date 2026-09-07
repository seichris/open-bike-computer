import Foundation
import CoreLocation
import MapKit

private final class OfflineChoiceTestRoute: MKRoute {
    let underlying: TestRoute
    let duration: TimeInterval
    init(duration: TimeInterval, coordinates: [CLLocationCoordinate2D]) {
        self.duration = duration
        underlying = TestRoute(instructions: "Continue", coordinates: coordinates)
        super.init()
    }
    override var steps: [MKRoute.Step] { underlying.steps }
    override var polyline: MKPolyline { underlying.polyline }
    override var distance: CLLocationDistance { underlying.distance }
    override var expectedTravelTime: TimeInterval { duration }
}

@MainActor
extension NavigationProtocolTests {
    /// Runs against the actual coordinator and NavigationEngine. Only directions
    /// and external location samples are controlled; offline requests are counted.
    static func testOfflineSavedNavigation() {
        let suite = "OfflineNavigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock()
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask, startServices: false, now: clock.now
        )
        defer { coordinator.stopNavigation() }
        func rejects(_ block: () throws -> Void, _ message: String) {
            do { try block(); assert(false, message) } catch { }
        }
        do {
            // Canonical WGS-84 in China deliberately exercises the boundary that
            // must NOT run a MapKit-to-WGS conversion for an imported archive.
            let points = (0...10).map { index in
                RouteCoordinateV1(latitude: 31 + Double(index) * 0.001, longitude: 121)
            }
            func makeRoute(provider: RouteProviderMetadataV1) -> NavigationRouteV1 {
                NavigationRouteV1(id: UUID(), revision: 3, provider: provider,
                    sourceReference: provider == RouteProviderPolicyV1.strava ?
                        RouteSourceReferenceV1(providerID: provider.providerID, externalRouteID: "1234",
                            canonicalURL: "https://www.strava.com/routes/1234") : nil,
                    localeIdentifier: "en_US", transportType: .cycling,
                    source: RouteEndpointV1(coordinate: points[0], label: "Start"),
                    destination: RouteEndpointV1(coordinate: points.last!, label: "Finish"),
                    bounds: RouteBoundsV1.enclosing(points)!,
                    distanceMeters: NavigationGeometryV1.cumulativeDistances(for: points).last!,
                    expectedTravelTimeSeconds: nil, name: "Offline China ride", points: points,
                    steps: [NavigationRouteStepV1(id: 1, geometryStartIndex: 0, geometryEndIndex: points.count - 1,
                        instruction: "Follow saved route", maneuver: .straight, distanceMeters: 1112)],
                    normalizationVersion: 1)
            }
            let archive = try NavigationRouteArchiveV1.create(route: makeRoute(provider: RouteProviderPolicyV1.importedGPX),
                createdAt: clock.now(), purpose: .offlineNavigation)
            let restored = try NavigationRouteArchiveV1.decode(
                archive.encoded(purpose: .offlineNavigation, now: clock.now()),
                purpose: .offlineNavigation, now: clock.now())
            let firstLocation = freshNavigationFix(testLocation(latitude: 31, longitude: 121), at: clock.now())
            coordinator.currentLocation = firstLocation
            try coordinator.startOfflineNavigation(with: restored)
            assert(coordinator.isNavigating && coordinator.currentRoute == nil, "offline start needs no MKRoute")
            assertEqual(coordinator.offlineNavigationIdentity, WatchRouteIdentityV1(archive: restored), "offline start uses restored UUID/revision/hash")
            assertEqual(factory.tasks.count, 0, "offline start never requests MapKit directions")
            for _ in 0..<6 {
                clock.advance(by: 20)
                coordinator.processNavigationLocationForTesting(freshNavigationFix(testLocation(latitude: 31.1, longitude: 121.1), at: clock.now()))
            }
            assertEqual(factory.tasks.count, 0, "off-route saved navigation never silently starts an online reroute")
            coordinator.reconcileOfflineNavigation(with: [PlannedRouteSummaryV1(archive: restored)])
            assert(coordinator.isNavigating, "exact installed identity preserves offline navigation")
            coordinator.reconcileOfflineNavigation(with: [])
            assert(!coordinator.isNavigating && coordinator.offlineNavigationIdentity == nil, "deletion/pruning stops navigation and clears identity")
            let mapKit = try NavigationRouteArchiveV1.create(route: makeRoute(provider: RouteProviderPolicyV1.mapKit),
                createdAt: clock.now(), purpose: .activeUse)
            rejects({ try coordinator.startOfflineNavigation(with: mapKit) }, "MapKit persistence gate is enforced at navigation entry")
            assert(!coordinator.isNavigating && factory.tasks.isEmpty, "rejected archive has no navigation/network effects")

            let engine = NavigationEngine(now: clock.now)
            defer { engine.stopNavigation() }
            try engine.startOfflineNavigation(with: restored, initialLocation: firstLocation)
            assert(engine.offlineSnapshotForTesting?.mode == .offline, "shared engine uses offline runtime mode")
            assertEqual(engine.offlineSnapshotForTesting?.contentHash, restored.contentHash, "shared runtime preserves archive hash")
            assertEqual(engine.offlineRouteForTesting?.points, points, "canonical imported geometry is not converted from MapKit coordinates")
            engine.stopNavigation()
            let expiring = try NavigationRouteArchiveV1.create(route: makeRoute(provider: RouteProviderPolicyV1.strava),
                createdAt: clock.now(), deleteAfter: clock.now().addingTimeInterval(30), purpose: .offlineNavigation)
            // A no-fix start still expires on the heartbeat, not only on GPS.
            try engine.startOfflineNavigation(with: expiring)
            clock.advance(by: 30)
            engine.refreshRideTelemetryForTesting()
            assert(!engine.isNavigating && engine.offlineRouteForTesting == nil, "expiry clears active geometry even before a first fix")
            rejects({ try engine.startOfflineNavigation(with: expiring) }, "expired archive cannot restart")

            // One usable returned route starts immediately. Multiple choices are
            // fastest-first, stable on ties, and still require explicit selection.
            let start = CLLocationCoordinate2D(latitude: 37, longitude: -122)
            let finish = CLLocationCoordinate2D(latitude: 37.004, longitude: -122)
            let source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            let destination = MKMapItem(placemark: MKPlacemark(coordinate: finish))
            source.name = "Start"; destination.name = "Finish"
            let slow = OfflineChoiceTestRoute(duration: 400, coordinates: [start, finish])
            let fast = OfflineChoiceTestRoute(duration: 100, coordinates: [start, finish])
            let tied = OfflineChoiceTestRoute(duration: 100, coordinates: [start, finish])
            coordinator.planNavigation(from: .mapItem(source), to: .mapItem(destination),
                transportType: RouteTransportTypes.cycling, isTestMode: true)
            factory.tasks.last!.succeed(with: [slow])
            assert(coordinator.isNavigating && coordinator.routeAlternatives.isEmpty && coordinator.currentRoute === slow,
                "single-route planning starts immediately without a picker")
            coordinator.stopNavigation()
            coordinator.planNavigation(from: .mapItem(source), to: .mapItem(destination),
                transportType: RouteTransportTypes.cycling, isTestMode: true)
            factory.tasks.last!.succeed(with: [slow, fast, tied])
            assert(!coordinator.isNavigating && coordinator.routeAlternatives.count == 3, "multiple routes remain selectable")
            assert(coordinator.routeAlternatives[0].route === fast && coordinator.routeAlternatives[1].route === tied &&
                coordinator.routeAlternatives[2].route === slow, "alternatives are fastest-first with stable tie order")
            assert(!coordinator.selectedRouteCanSaveOffline, "Save Offline is disabled with no selection")
            let selected = coordinator.routeAlternatives[1].id
            coordinator.selectRouteAlternative(selected)
            assert(!coordinator.selectedRouteCanSaveOffline, "Save Offline remains disabled for a selected MapKit source")
            let requestCount = factory.tasks.count
            rejects({ try coordinator.startOfflineNavigation(with: restored) }, "saved-route callback cannot replace a pending plan")
            assert(coordinator.selectedRouteAlternativeID == selected && coordinator.routeAlternatives.count == 3 && factory.tasks.count == requestCount,
                "failed offline start preserves the existing selection and requests")
            coordinator.startSelectedRoute()
            assert(coordinator.currentRoute === tied && coordinator.isNavigating, "selected fastest-first alternative still starts normally")
            coordinator.stopNavigation()
        } catch {
            assert(false, "offline navigation regression failed: \(error)")
        }
    }
}
