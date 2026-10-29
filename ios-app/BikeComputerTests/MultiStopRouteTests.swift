import CoreLocation
import Foundation
import MapKit

/// Settings > Saved Routes > Create a Route: multi-stop planning, leg
/// stitching, save/reload, offline navigation and the direct-navigation
/// boundary. Runs inside the offline-route host test executable.
@MainActor
private final class MultiStopFixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-stop-\(UUID())")
    let suite = "multi-stop.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var store = NavigationRouteFileStoreV1(rootDirectory: root)
    let watch = PhoneWatchConnectivityCoordinator()
    lazy var library = makeLibrary()
    let factory = TestNavigationDirectionsFactory()

    func makeLibrary() -> PhoneRouteLibrary {
        PhoneRouteLibrary(store: store, connectivity: watch, defaults: defaults, now: { [unowned self] in self.now })
    }

    func makePlanner(limits: NavigationRouteLimitsV1 = .production) -> MultiStopRoutePlanner {
        MultiStopRoutePlanner(directionsFactory: factory.makeTask, limits: limits, now: { [unowned self] in self.now })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private enum Stops {
    static let homePoint = CLLocationCoordinate2D(latitude: 51.5000, longitude: -0.1000)
    static let canalPoint = CLLocationCoordinate2D(latitude: 51.5010, longitude: -0.1000)
    static let bakeryPoint = CLLocationCoordinate2D(latitude: 51.5020, longitude: -0.0980)
    static let stationPoint = CLLocationCoordinate2D(latitude: 51.5030, longitude: -0.0980)
    static let officePoint = CLLocationCoordinate2D(latitude: 51.5040, longitude: -0.1000)

    static let home = place("Home", homePoint)
    static let bakery = place("Bakery", bakeryPoint)
    static let office = place("Office", officePoint)

    static func place(
        _ label: String,
        _ coordinate: CLLocationCoordinate2D,
        origin: MultiStopRoutePlace.Origin = .search
    ) -> MultiStopRoutePlace {
        MultiStopRoutePlace(label: label, mapCoordinate: coordinate, origin: origin)!
    }

    static func request(_ places: [MultiStopRoutePlace]) -> MultiStopRouteRequest {
        MultiStopRouteRequest(places: places, transportType: RouteTransportTypes.cycling)
    }

    /// A MapKit-shaped leg: an empty first step, one turn, then arrival.
    static func leg(
        _ from: CLLocationCoordinate2D,
        via: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        turn: String,
        arrival: String = "Arrive at the destination",
        travelTime: TimeInterval
    ) -> TestRoute {
        TestRoute(steps: [
            TestRouteStep(instructions: "", coordinates: [from]),
            TestRouteStep(instructions: turn, coordinates: [from, via]),
            TestRouteStep(instructions: arrival, coordinates: [via, to])
        ], coordinates: [from, via, to], expectedTravelTime: travelTime)
    }

    static var homeToBakery: TestRoute {
        leg(homePoint, via: canalPoint, to: bakeryPoint,
            turn: "Turn right onto Canal Street", travelTime: 120)
    }

    static var bakeryToOffice: TestRoute {
        leg(bakeryPoint, via: stationPoint, to: officePoint,
            turn: "Turn left onto Station Road",
            arrival: "The destination is on your left", travelTime: 150)
    }

    static var homeToOffice: TestRoute {
        leg(homePoint, via: canalPoint, to: officePoint,
            turn: "Continue onto Canal Street", travelTime: 200)
    }

    static var officeToBakery: TestRoute {
        leg(officePoint, via: stationPoint, to: bakeryPoint,
            turn: "Turn left onto Station Road", travelTime: 100)
    }

    static func endpoints(_ task: TestNavigationDirectionsTask) -> [RouteCoordinateV1] {
        [task.request.source, task.request.destination].compactMap { item in
            guard let item else { return nil }
            let coordinate: CLLocationCoordinate2D
            if #available(iOS 26.0, macOS 26.0, *) {
                coordinate = item.location.coordinate
            } else {
                coordinate = item.placemark.coordinate
            }
            return RouteCoordinateV1(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    static func progress(_ planner: MultiStopRoutePlanner) -> [Int]? {
        if case .calculating(let completed, let total) = planner.state { return [completed, total] }
        return nil
    }

    static func isIdle(_ planner: MultiStopRoutePlanner) -> Bool {
        if case .idle = planner.state { return true }
        return false
    }

    static func fix(_ point: RouteCoordinateV1, at time: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 4,
            timestamp: time
        )
    }
}

extension OfflineRouteSaveTests {
    static func multiStopRouteTests() throws {
        try multiStopOrderingAndStitching()
        try multiStopDraftEditingAndLimits()
        try multiStopReorderingReusesLegs()
        try multiStopStaleResultsAndCancellation()
        try multiStopLegFailuresAndRetry()
        try multiStopJoinsAndRouteLimits()
        try multiStopSaveReloadAndOfflineNavigation()
        try multiStopDirectNavigationIsolation()
    }

    static func multiStopOrderingAndStitching() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let planner = f.makePlanner()
        let request = Stops.request([Stops.home, Stops.bakery, Stops.office])
        planner.plan(request)
        check(f.factory.tasks.count == 1 &&
            Stops.endpoints(f.factory.tasks[0]) == [Stops.home.mapCoordinate, Stops.bakery.mapCoordinate],
            "The first leg runs from the start to the first stop")
        check(Stops.progress(planner) == [0, 2] && planner.readyPlan == nil, "Calculation reports its legs while loading")
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        check(f.factory.tasks.count == 2 &&
            Stops.endpoints(f.factory.tasks[1]) == [Stops.bakery.mapCoordinate, Stops.office.mapCoordinate],
            "The next leg starts at the stop the previous leg reached")
        check(Stops.progress(planner) == [1, 2], "Completed legs are counted")
        f.factory.tasks[1].succeed(with: [Stops.bakeryToOffice])
        check(f.factory.tasks.allSatisfy {
            $0.request.transportType == RouteTransportTypes.cycling && !$0.request.requestsAlternateRoutes
        }, "Each leg is one MapKit request with the chosen travel mode")

        guard let plan = planner.readyPlan else { preconditionFailure("Expected a ready plan") }
        let first = try MapKitRouteAdapter.route(from: Stops.homeToBakery)
        let second = try MapKitRouteAdapter.route(from: Stops.bakeryToOffice)
        let route = plan.route
        check(plan.request == request && plan.legs.count == 2, "The plan belongs to the requested stops")
        check(route.points == first.points + second.points.dropFirst(),
            "Leg geometry is joined in stop order without duplicating the stop vertex")
        check(route.steps.map(\.instruction) == [
            "Continue", "Turn right onto Canal Street", "Arrive at Bakery",
            "Continue", "Turn left onto Station Road", "The destination is on your left"
        ], "Every leg's instructions survive, with the stop announced by name")
        check(route.steps.map(\.maneuver) == [.straight, .right, .straight, .straight, .left, .arrive],
            "Only the final destination keeps an arrival maneuver")
        check(route.steps.map(\.id) == (1...6).map(UInt32.init), "Step IDs are unique across legs")
        check(route.steps.map { [$0.geometryStartIndex, $0.geometryEndIndex] } ==
            [[0, 0], [0, 1], [1, 2], [2, 2], [2, 3], [3, 4]],
            "Step ranges stay contiguous across the stop")
        check(route.points[route.steps[2].geometryEndIndex] == first.points.last,
            "The stop's arrival step ends exactly at the stop")
        check(route.steps.map(\.distanceMeters) == plan.legs.flatMap { $0.steps.map(\.distanceMeters) } &&
            route.distanceMeters == Stops.homeToBakery.distance + Stops.bakeryToOffice.distance &&
            route.expectedTravelTimeSeconds == 270,
            "Step, total distance and travel time are preserved across legs")
        check(route.source.label == "Home" && route.destination.label == "Office" &&
            route.source.coordinate == route.points.first && route.destination.coordinate == route.points.last,
            "Route endpoints are the first and last stops")
        check(route.name == "Home → Office via Bakery", "The default name lists the stop")
        check(route.provider == RouteProviderPolicyV1.mapKit,
            "The preview is still an active-only Apple Maps route")
        check(plan.draft.archive.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone &&
            plan.draft.id == route.id && plan.draft.archive.route.points == route.points &&
            plan.draft.archive.route.steps == route.steps,
            "Only the typed save draft gets the phone-only scope, with identical content")
        try route.validate()
    }

    static func multiStopDraftEditingAndLimits() throws {
        var draft = MultiStopRouteDraft(start: Stops.home)
        check(draft.stops.count == 2 && draft.role(at: 0) == .start && draft.role(at: 1) == .destination,
            "A new route has a start and a destination")
        check(draft.issue == .missingPlace(index: 1) && draft.request(transportType: RouteTransportTypes.cycling) == nil &&
            draft.message(for: .missingPlace(index: 1)) == "Choose a destination to preview the route.",
            "Calculation waits for a destination")
        guard let stopID = draft.addStop() else { preconditionFailure("Expected an added stop") }
        draft.setPlace(Stops.office, forStopID: draft.stops[2].id)
        check(draft.stops[1].id == stopID && draft.stops[1].place == nil && draft.stops[2].place == Stops.office,
            "A new stop is inserted before the destination")
        check(draft.issue == .missingPlace(index: 1) &&
            draft.message(for: .missingPlace(index: 1)).contains("Stop 1"),
            "An empty stop must be chosen or removed")
        draft.setPlace(Stops.place("Gate", Stops.homePoint), forStopID: stopID)
        check(draft.issue == .repeatedPlace(index: 1) &&
            draft.message(for: .repeatedPlace(index: 1)) ==
                "Stop 1 is the same place as the start. Choose a different place or remove one of them.",
            "Consecutive stops at the same place are rejected before any request")
        draft.setPlace(Stops.bakery, forStopID: stopID)
        check(draft.request(transportType: RouteTransportTypes.cycling)?.places == [Stops.home, Stops.bakery, Stops.office],
            "A complete draft requests its stops in order")
        let loop = MultiStopRouteDraft(places: [Stops.home, Stops.bakery, Stops.home])
        check(loop.issue == nil, "A loop may return to its start")

        draft.moveStop(id: stopID, by: -1)
        check(draft.stops.compactMap(\.place?.label) == ["Bakery", "Home", "Office"], "Move earlier swaps with the previous stop")
        draft.moveStop(id: stopID, by: -1)
        check(draft.stops[0].id == stopID, "A stop cannot move before the start")
        draft.reverse()
        check(draft.stops.compactMap(\.place?.label) == ["Office", "Home", "Bakery"], "Reverse flips the visiting order")
        draft.moveStops(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        check(draft.stops.compactMap(\.place?.label) == ["Home", "Bakery", "Office"],
            "List moves use offsets in the unmodified order")

        while draft.addStop() != nil {}
        check(draft.stops.count == MultiStopRouteDraft.maximumStops && !draft.canAddStop && draft.addStop() == nil,
            "Stops are capped at the route limit")
        check(draft.role(at: 1) == .stop(1) && draft.role(at: 8) == .stop(8) && draft.role(at: 9) == .destination,
            "Intermediate stops are numbered by position")
        draft.removeStops(atOffsets: IndexSet(0..<9))
        check(draft.stops.count == MultiStopRouteDraft.maximumStops, "Removal can never leave fewer than two stops")
        draft.removeStops(atOffsets: IndexSet(2..<9))
        check(draft.stops.count == 3 && draft.canRemoveStop, "Empty stops can be removed together")
        draft.removeStop(id: draft.stops[1].id)
        check(draft.stops.compactMap(\.place?.label) == ["Home", "Office"] && !draft.canRemoveStop,
            "Removing the last intermediate stop keeps start and destination")
        draft.removeStop(id: draft.stops[0].id)
        check(draft.stops.count == 2, "A start or destination cannot be removed from a two-stop route")
    }

    static func multiStopReorderingReusesLegs() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let planner = f.makePlanner()
        var draft = MultiStopRouteDraft(places: [Stops.home, Stops.bakery, Stops.office])
        planner.plan(draft.request(transportType: RouteTransportTypes.cycling))
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[1].succeed(with: [Stops.bakeryToOffice])
        guard let original = planner.readyPlan else { preconditionFailure("Expected a ready plan") }

        draft.moveStops(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        planner.plan(draft.request(transportType: RouteTransportTypes.cycling))
        check(f.factory.tasks.count == 3 &&
            Stops.endpoints(f.factory.tasks[2]) == [Stops.home.mapCoordinate, Stops.office.mapCoordinate],
            "Reordering requests the changed first leg")
        f.factory.tasks[2].succeed(with: [Stops.homeToOffice])
        check(f.factory.tasks.count == 4 &&
            Stops.endpoints(f.factory.tasks[3]) == [Stops.office.mapCoordinate, Stops.bakery.mapCoordinate],
            "Reordering requests the changed second leg")
        f.factory.tasks[3].succeed(with: [Stops.officeToBakery])
        guard let reordered = planner.readyPlan else { preconditionFailure("Expected a reordered plan") }
        let reorderedEnd = try MapKitRouteAdapter.route(from: Stops.officeToBakery).points.last
        check(reordered.route.steps.map(\.instruction).contains("Arrive at Office") &&
            !reordered.route.steps.map(\.instruction).contains("Arrive at Bakery") &&
            reordered.route.destination.label == "Bakery" &&
            reordered.route.points.last == reorderedEnd,
            "The stitched route follows the new stop order")

        draft.moveStops(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        check(draft.stops.compactMap(\.place?.label) == ["Home", "Bakery", "Office"], "The original order is restored")
        planner.plan(draft.request(transportType: RouteTransportTypes.cycling))
        check(f.factory.tasks.count == 4 && planner.readyPlan?.route.points == original.route.points &&
            planner.readyPlan?.route.steps == original.route.steps,
            "Restoring the order reuses both cached legs without another request")

        planner.plan(MultiStopRouteRequest(
            places: [Stops.home, Stops.bakery, Stops.office],
            transportType: .walking
        ))
        check(f.factory.tasks.count == 5 && f.factory.tasks[4].request.transportType == .walking,
            "Cached legs are never reused for another travel mode")
    }

    static func multiStopStaleResultsAndCancellation() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let planner = f.makePlanner()
        let threeStops = Stops.request([Stops.home, Stops.bakery, Stops.office])
        planner.plan(threeStops)
        let superseded = f.factory.tasks[0]
        planner.plan(threeStops)
        check(f.factory.tasks.count == 1 && !superseded.isCancelled,
            "Repeating the current request keeps its in-flight leg")
        let twoStops = Stops.request([Stops.home, Stops.office])
        planner.plan(twoStops)
        check(superseded.isCancelled && f.factory.tasks.count == 2,
            "Editing the stops cancels the superseded leg request")
        superseded.succeed(with: [Stops.homeToBakery])
        check(f.factory.tasks.count == 2 && planner.readyPlan == nil && Stops.progress(planner) == [0, 1],
            "A late response for superseded stops is discarded")
        f.factory.tasks[1].succeed(with: [Stops.homeToOffice])
        check(planner.readyPlan?.request == twoStops && planner.readyPlan?.legs.count == 1,
            "Only the current stops produce a preview")

        planner.plan(threeStops)
        check(f.factory.tasks.count == 3 &&
            Stops.endpoints(f.factory.tasks[2]) == [Stops.home.mapCoordinate, Stops.bakery.mapCoordinate],
            "A discarded response was never cached")
        planner.cancel()
        check(f.factory.tasks[2].isCancelled && planner.request == nil && Stops.isIdle(planner),
            "Cancel stops the in-flight leg and clears the plan")
        f.factory.tasks[2].succeed(with: [Stops.homeToBakery])
        check(f.factory.tasks.count == 3 && Stops.isIdle(planner) && planner.readyPlan == nil,
            "A response after cancellation has no effect")
        planner.plan(nil)
        check(Stops.isIdle(planner) && f.factory.tasks.count == 3, "An incomplete draft requests nothing")
    }

    static func multiStopLegFailuresAndRetry() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let planner = f.makePlanner()
        let request = Stops.request([Stops.home, Stops.bakery, Stops.office])
        planner.plan(request)
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[1].fail(with: MKError(.directionsNotFound))
        check(planner.failure == .leg(index: 1, message: "No route was found from Bakery to Office.") &&
            planner.readyPlan == nil,
            "A failed leg names its stops and offers nothing to save")
        planner.plan(request)
        check(f.factory.tasks.count == 2, "A failed request is not repeated automatically")
        planner.retry()
        check(f.factory.tasks.count == 3 &&
            Stops.endpoints(f.factory.tasks[2]) == [Stops.bakery.mapCoordinate, Stops.office.mapCoordinate],
            "Retry requests only the failed leg")
        f.factory.tasks[2].fail(with: MKError(.loadingThrottled))
        check(planner.failure?.legIndex == 1 && planner.failure?.message.contains("busy") == true,
            "Throttling is reported as temporary")
        planner.retry()
        f.factory.tasks[3].fail(with: URLError(.notConnectedToInternet))
        check(planner.failure?.message.contains("connection") == true, "Offline failures ask for a connection")
        planner.retry()
        f.factory.tasks[4].succeed(with: [])
        check(planner.failure == .leg(index: 1, message: "No route was found from Bakery to Office."),
            "An empty response is a leg failure")
        planner.retry()
        // One segment beyond the device's 16-bit route-window delta range.
        f.factory.tasks[5].succeed(with: [TestRoute(instructions: "Continue", coordinates: [
            Stops.bakeryPoint, CLLocationCoordinate2D(latitude: 51.6, longitude: -0.098)
        ])])
        check(planner.failure?.legIndex == 1, "A response that cannot be normalized safely is rejected")
        planner.retry()
        f.factory.tasks[6].succeed(with: [Stops.bakeryToOffice])
        check(planner.readyPlan?.legs.count == 2 && f.factory.tasks.count == 7,
            "The route completes once the failed leg succeeds")
    }

    static func multiStopJoinsAndRouteLimits() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let request = Stops.request([Stops.home, Stops.bakery, Stops.office])

        // MapKit snaps the end of one leg and the start of the next separately.
        let snapped = CLLocationCoordinate2D(latitude: 51.5024, longitude: -0.0980)
        let joining = f.makePlanner()
        joining.plan(request)
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[1].succeed(with: [Stops.leg(snapped, via: Stops.stationPoint, to: Stops.officePoint,
            turn: "Turn left onto Station Road", travelTime: 150)])
        guard let joined = joining.readyPlan else { preconditionFailure("Expected a joined plan") }
        let firstEnd = joined.legs[0].points.last!
        let secondStart = joined.legs[1].points[0]
        let gap = NavigationGeometryV1.distance(from: firstEnd, to: secondStart)
        check(gap > 40 && gap < 50 && joined.route.points.contains(secondStart) &&
            joined.route.steps.map { [$0.geometryStartIndex, $0.geometryEndIndex] } ==
                [[0, 0], [0, 1], [1, 3], [3, 3], [3, 4], [4, 5]],
            "A short join is absorbed by the stop's arrival step")
        check(joined.route.steps[2].distanceMeters == joined.legs[0].steps[2].distanceMeters + gap &&
            abs(joined.route.distanceMeters - (joined.legs[0].distanceMeters + gap + joined.legs[1].distanceMeters)) < 1e-9,
            "The join's length is counted once in step and route distance")
        try joined.route.validate()

        let far = CLLocationCoordinate2D(latitude: 51.5080, longitude: -0.0980)
        let disconnected = f.makePlanner()
        disconnected.plan(request)
        f.factory.tasks[2].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[3].succeed(with: [Stops.leg(far, via: Stops.stationPoint, to: Stops.officePoint,
            turn: "Turn left onto Station Road", travelTime: 150)])
        check(disconnected.failure == .route(message: MultiStopRouteStitchError.disconnected(stopLabel: "Bakery")
            .localizedDescription) && disconnected.readyPlan == nil,
            "A join wider than the snapping tolerance is never bridged off-road")

        let points = f.makePlanner(limits: NavigationRouteLimitsV1(
            maximumPoints: 4, maximumSteps: 2_000, maximumEncodedBytes: 4 * 1_024 * 1_024))
        points.plan(request)
        f.factory.tasks[4].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[5].succeed(with: [Stops.bakeryToOffice])
        check(points.failure == .route(message: MultiStopRouteStitchError.tooLong.localizedDescription),
            "Combined geometry over the route limit is rejected before saving")

        let bytes = f.makePlanner(limits: NavigationRouteLimitsV1(
            maximumPoints: 50_000, maximumSteps: 2_000, maximumEncodedBytes: 512))
        bytes.plan(request)
        f.factory.tasks[6].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[7].succeed(with: [Stops.bakeryToOffice])
        check(bytes.failure == .route(message: MultiStopRouteStitchError.tooLong.localizedDescription),
            "A plan the archive store could not hold never offers Save")

        let crowded = f.makePlanner()
        crowded.plan(Stops.request((0...MultiStopRouteDraft.maximumStops).map {
            Stops.place("Stop \($0)", CLLocationCoordinate2D(latitude: 51.5 + Double($0) * 0.001, longitude: -0.1))
        }))
        check(crowded.failure != nil && f.factory.tasks.count == 8, "Too many stops request nothing")

        let leg = try MapKitRouteAdapter.route(from: Stops.homeToBakery)
        for (legs, labels) in [
            ([changedProvider(leg, RouteProviderPolicyV1.importedGPX)], ["Home", "Bakery"]),
            ([leg], ["Home"]),
            ([leg], ["Home", " "]),
            ([], ["Home"])
        ] {
            do {
                _ = try MultiStopRouteStitcher.stitch(legs: legs, stopLabels: labels)
                preconditionFailure("Expected invalid legs to be rejected")
            } catch {
                check(error as? MultiStopRouteStitchError == .invalidLegs,
                    "Only same-provider MapKit legs with one label per stop are stitched")
            }
        }
    }

    static func multiStopSaveReloadAndOfflineNavigation() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let planner = f.makePlanner()
        planner.plan(Stops.request([Stops.home, Stops.bakery, Stops.office]))
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[1].succeed(with: [Stops.bakeryToOffice])
        guard let plan = planner.readyPlan else { preconditionFailure("Expected a ready plan") }

        var interaction = OfflineRouteSaveInteraction()
        interaction.select(plan.draft)
        check(interaction.proposedName == "Home → Office via Bakery", "The save sheet proposes the stop list as a name")
        interaction.save(now: f.now) { try f.library.saveOffline($0, name: $1) }
        guard let saved = interaction.result else { preconditionFailure("Expected a saved route") }
        check(!saved.alreadySaved && saved.summary.name == "Home → Office via Bakery" &&
            saved.summary.providerID == RouteProviderPolicyV1.mapKit.providerID,
            "The multi-stop route is saved as one Apple Maps route")

        let restarted = f.makeLibrary()
        check(restarted.routes == [saved.summary], "The saved route survives a library restart")
        let archive = try restarted.offlineArchive(for: saved.summary)
        check(archive.route.points == plan.route.points && archive.route.steps == plan.route.steps,
            "Reloaded geometry and every leg's instructions match the preview")
        check(archive.route.distanceMeters == plan.route.distanceMeters &&
            archive.route.expectedTravelTimeSeconds == 270 &&
            archive.route.source.label == "Home" && archive.route.destination.label == "Office" &&
            archive.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone,
            "Reloaded distances, endpoints and phone-only provenance are preserved")
        check(!restarted.canSendToWatch(saved.summary), "Apple Maps provider policy keeps the route off Apple Watch")
        failure { _ = try archive.encoded(purpose: .watchTransfer, now: f.now) }
        let preview = try restarted.mapSelection(for: saved.summary)
        check(preview.route.points == plan.route.points, "The saved-route map preview shows the whole route")
        let repeated = try restarted.saveOffline(plan.draft, name: "Again")
        check(repeated.alreadySaved && repeated.summary == saved.summary, "Saving the same plan again keeps one route")

        let directions = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: directions.makeTask, startServices: false, now: { f.now })
        try coordinator.startOfflineNavigation(archive)
        check(coordinator.isNavigating && coordinator.offlineRouteSummary == saved.summary &&
            coordinator.offlineRoutePolyline?.pointCount == archive.route.points.count && directions.tasks.isEmpty,
            "Offline navigation shows the full stitched route without directions requests")
        coordinator.stopNavigation()

        // The iPhone engine drives both the iPhone banner and the Bicino device.
        let engine = NavigationEngine(now: { f.now })
        defer { engine.stopNavigation() }
        let points = archive.route.points
        try engine.startOfflineNavigation(archive: archive, initialLocation: Stops.fix(points[0], at: f.now))
        func ride(_ point: RouteCoordinateV1) {
            f.now.addTimeInterval(5)
            _ = engine.processExternalLocation(Stops.fix(point, at: f.now))
        }
        ride(points[0])
        ride(points[1])
        check(engine.offlineSnapshotForTesting?.instruction == "Arrive at Bakery" &&
            engine.offlineSnapshotForTesting?.maneuver == .straight &&
            engine.currentInstruction == "Arrive at Bakery",
            "Approaching a stop announces it by name")
        check(engine.offlineSnapshotForTesting?.routeWindow.isEmpty == false,
            "The device keeps receiving route geometry at the stop")
        ride(points[2])
        ride(points[2])
        ride(points[3])
        check(engine.isNavigating &&
            engine.offlineSnapshotForTesting?.instruction == "The destination is on your left",
            "Reaching a stop continues with the next leg")
        ride(points[4])
        check(!engine.isNavigating, "Only the final destination ends navigation")
    }

    static func multiStopDirectNavigationIsolation() throws {
        let f = MultiStopFixture(); defer { f.cleanup() }
        let directions = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(destinationStore: SavedDestinationStore(defaults: f.defaults),
            directionsFactory: directions.makeTask, startServices: false, now: { f.now })
        defer { coordinator.stopNavigation() }
        let planner = f.makePlanner()
        let start = MKMapItem(placemark: MKPlacemark(coordinate: Stops.homePoint))
        let finish = MKMapItem(placemark: MKPlacemark(coordinate: Stops.officePoint))
        coordinator.planNavigation(from: .mapItem(start), to: .mapItem(finish),
            transportType: RouteTransportTypes.cycling, isTestMode: true)
        planner.plan(Stops.request([Stops.home, Stops.bakery, Stops.office]))
        f.factory.tasks[0].succeed(with: [Stops.homeToBakery])
        f.factory.tasks[1].succeed(with: [Stops.bakeryToOffice])
        check(directions.tasks.count == 1 && !directions.tasks[0].isCancelled &&
            coordinator.routeCalculation.isCalculating && planner.readyPlan != nil,
            "Creating a multi-stop route never cancels or replaces direct planning")
        directions.tasks[0].succeed(with: [TestRoute(instructions: "Continue",
            coordinates: [Stops.homePoint, Stops.officePoint], expectedTravelTime: 300)])
        check(coordinator.routeAlternatives.count == 1 &&
            coordinator.routeAlternatives[0].canonicalRoute.points.count == 2 &&
            directions.tasks[0].request.requestsAlternateRoutes,
            "Direct planning stays one request to one destination with alternatives")
        planner.cancel()
        check(coordinator.routeAlternatives.count == 1, "Closing the creator leaves direct planning alone")
        coordinator.selectRouteAlternative(coordinator.routeAlternatives[0].id)
        coordinator.startSelectedRoute()
        check(coordinator.isNavigating && coordinator.currentRoute != nil && f.factory.tasks.count == 2,
            "Direct navigation starts without the route creator")

        let content = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/ContentView.swift", encoding: .utf8)
        let search = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/RouteInputView.swift", encoding: .utf8)
        let section = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift", encoding: .utf8)
        let settings = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift", encoding: .utf8)
        let panel = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/SavedRoutesLibraryView.swift", encoding: .utf8)
        let creator = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/RouteCreatorView.swift", encoding: .utf8)
        check(!search.contains("MultiStop") && !search.contains("RouteCreator") &&
            !content.contains("MultiStop") && !content.contains("RouteCreatorView"),
            "Direct navigation search and the main map have no waypoint UI")
        check(section.contains("onCreateRoute()") && !section.contains("onSaveOnlineRoute(nil)") &&
            section.contains("onSaveOnlineRoute(favorite)"),
            "Only Create a Route opens the creator; a favorite keeps single-destination planning")
        check(content.contains("onSaveOnlineRoute: openOfflineRouteSearch") &&
            content.contains("beginOfflineRouteSearch(destination: destination)"),
            "Favorite route planning keeps its main-map flow")
        check(settings.contains("presentedSheet = .routeCreator") && settings.contains("RouteCreatorView(") &&
            panel.contains("presentedImport = .routeCreator") && panel.contains("RouteCreatorView("),
            "Settings and the Saved Routes shortcut both open the creator from Create a Route")
        check(creator.contains("RouteSaveSheet(library: library, draft: plan.draft)") &&
            creator.contains(".onDisappear { planner.cancel() }") &&
            creator.contains("guard let plan = planner.readyPlan, plan.request == request"),
            "The creator saves only the current plan through the shared sheet and cancels when closed")
    }
}
