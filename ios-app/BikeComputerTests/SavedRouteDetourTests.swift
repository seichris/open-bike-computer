import CoreLocation
import Foundation
import MapKit

// Host tests for saved-route bicycle detours: rejoin planning, confirmed
// rejoin, the detour engine, runtime resume, the MapKit → Valhalla provider
// chain and the service contract. Run by ios-app/scripts/run-saved-route-detour-tests.sh.

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { fatalError("FAILED SavedRouteDetourTests.swift:\(line): \(message)") }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtureDirectory = repositoryRoot.appendingPathComponent("protocol/fixtures/bicycle-detour-v1")

// MARK: - Synthetic geometry (metres east/north of a Dubai origin)

private let originLatitude = 25.20
private let originLongitude = 55.27

private func point(_ east: Double, _ north: Double) -> RouteCoordinateV1 {
    let latitude = originLatitude + north / 111_195
    let longitude = originLongitude + east / (111_195 * cos(originLatitude * .pi / 180))
    return RouteCoordinateV1(latitude: latitude, longitude: longitude)
}

/// Densifies a polyline every `spacing` metres so projections behave like a GPX track.
private func track(_ corners: [(Double, Double)], spacing: Double = 25) -> [RouteCoordinateV1] {
    var result: [RouteCoordinateV1] = []
    for (index, corner) in corners.enumerated() {
        guard index > 0 else { result.append(point(corner.0, corner.1)); continue }
        let previous = corners[index - 1]
        let length = hypot(corner.0 - previous.0, corner.1 - previous.1)
        let count = max(Int((length / spacing).rounded(.up)), 1)
        for step in 1...count {
            let t = Double(step) / Double(count)
            result.append(point(previous.0 + (corner.0 - previous.0) * t, previous.1 + (corner.1 - previous.1) * t))
        }
    }
    return result
}

/// A saved route: steps end at the given point indices (instruction, maneuver).
private func savedRoute(
    _ points: [RouteCoordinateV1],
    steps stepEnds: [(Int, String, ManeuverV1)] = [],
    provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.importedGPX
) -> NavigationRouteV1 {
    let cumulative = NavigationGeometryV1.cumulativeDistances(for: points)
    var steps: [NavigationRouteStepV1] = []
    var start = 0
    for (end, instruction, maneuver) in stepEnds + [(points.count - 1, "Arrive at Finish", .arrive)] {
        steps.append(NavigationRouteStepV1(
            id: UInt32(steps.count + 1), geometryStartIndex: start, geometryEndIndex: end,
            instruction: instruction, maneuver: maneuver,
            distanceMeters: cumulative[end] - cumulative[start]
        ))
        start = end
    }
    let route = NavigationRouteV1(
        id: UUID(), revision: 1, provider: provider, localeIdentifier: "en_AE", transportType: .cycling,
        source: RouteEndpointV1(coordinate: points[0], label: "Start"),
        destination: RouteEndpointV1(coordinate: points[points.count - 1], label: "Finish"),
        bounds: RouteBoundsV1.enclosing(points)!, distanceMeters: cumulative.last!,
        expectedTravelTimeSeconds: cumulative.last! / 4, name: "Synthetic", points: points, steps: steps,
        normalizationVersion: 1
    )
    try! route.validate()
    return route
}

private func sample(
    _ coordinate: RouteCoordinateV1,
    course: Double = 0,
    speed: Double = 5,
    accuracy: Double = 5,
    at time: Date
) -> NavigationLocationSampleV1 {
    NavigationLocationSampleV1(
        coordinate: coordinate, horizontalAccuracyMeters: accuracy, courseDegrees: course,
        speedMetersPerSecond: speed, altitudeMeters: 5, timestamp: time
    )
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Straight 3 km route north with turns at 1.5 km and 2.5 km (cue steps).
private func northRoute() -> NavigationRouteV1 {
    let points = track([(0, 0), (0, 3_000)])
    // 25 m spacing: index 60 = 1500 m, 100 = 2500 m.
    return savedRoute(points, steps: [(60, "Continue on Al Wasl Road", .straight), (100, "Turn left onto 6d Street", .left)])
}

// MARK: - Planner

private func testPlannerMissedTurnAimsAhead() {
    let geometry = SavedRouteGeometryV1(route: northRoute())
    let policy = SavedRouteDetourPolicyV1.production
    let target = SavedRouteRejoinPlannerV1.target(
        for: point(120, 1_000), attempt: 0, confirmedProgress: 900, geometry: geometry, policy: policy
    )!
    expect(target.kind == .ahead, "the first candidate aims ahead")
    expect(abs(target.distanceAlongMeters - 1_120) < 3, "nearest point plus a lookahead equal to the distance (120 m)")
    expect(target.windowLowerMeters == 900 && abs(target.windowUpperMeters - 3_000) < 1, "window from the leave point to the finish")

    let far = SavedRouteRejoinPlannerV1.target(
        for: point(900, 1_000), attempt: 0, confirmedProgress: 900, geometry: geometry, policy: policy
    )!
    expect(abs(far.distanceAlongMeters - 1_400) < 3, "lookahead is capped at 400 m")

    let order = (1...3).map {
        SavedRouteRejoinPlannerV1.target(for: point(120, 1_000), attempt: $0, confirmedProgress: 900,
                                         geometry: geometry, policy: policy)!
    }
    expect(order.map(\.kind) == [.nearest, .further, .leavePoint], "later attempts use the other candidates")
    expect(abs(order[0].distanceAlongMeters - 1_000) < 3 && abs(order[1].distanceAlongMeters - 2_000) < 3 &&
           abs(order[2].distanceAlongMeters - 900) < 0.1, "nearest, +1 km, leave point")
}

private func testPlannerLoopPrefersEarliestPass() {
    // A loop whose finish runs back beside its start.
    let route = savedRoute(track([(0, 0), (0, 1_000), (600, 1_000), (600, 0), (15, 0), (15, 40)]))
    let geometry = SavedRouteGeometryV1(route: route)
    let target = SavedRouteRejoinPlannerV1.target(
        for: point(-70, 60), attempt: 1, confirmedProgress: 30, geometry: geometry, policy: .production
    )!
    expect(target.distanceAlongMeters < 200, "the earlier pass wins over the loop's finish beside it")
}

private func testPlannerIgnoresLaterCrossingPass() {
    // Figure eight: a much later pass crosses the rider's position.
    let route = savedRoute(track([(0, 0), (0, 2_000), (3_000, 2_000), (3_000, 1_000), (-500, 1_000), (-500, 3_000)]))
    let geometry = SavedRouteGeometryV1(route: route)
    let rider = point(150, 1_000)
    let target = SavedRouteRejoinPlannerV1.target(
        for: rider, attempt: 1, confirmedProgress: 900, geometry: geometry, policy: .production
    )!
    expect(abs(target.distanceAlongMeters - 1_000) < 5, "the later crossing pass (beyond the skip limit) is never targeted")
}

private func testPlannerStopCapsWindow() {
    let points = track([(0, 0), (0, 3_000)])
    let route = savedRoute(points, steps: [(60, "Arrive at Bakery", .straight)], provider: RouteProviderPolicyV1.mapKitSavedOnPhone)
    let geometry = SavedRouteGeometryV1(route: route)
    expect(SavedRouteGeometryV1.stopInstructionPrefix == "Arrive at ", "stop marker matches MultiStopRouteStitcher")
    expect(geometry.stopDistances.count == 1 && abs(geometry.stopDistances[0] - 1_500) < 0.5, "the stop is recognised")
    expect(geometry.stopLabel(at: geometry.stopDistances[0]) == "Bakery", "stop label")
    let window = SavedRouteRejoinPlannerV1.window(confirmedProgress: 1_200, geometry: geometry, policy: .production)
    expect(window.isCappedByStop && abs(window.upper - 1_500) < 0.5, "the next unvisited stop caps the window")
    let target = SavedRouteRejoinPlannerV1.target(
        for: point(300, 1_450), attempt: 0, confirmedProgress: 1_200, geometry: geometry, policy: .production
    )!
    expect(abs(target.distanceAlongMeters - 1_500) < 0.5, "the detour never aims past the unvisited stop")
    let afterStop = SavedRouteRejoinPlannerV1.window(confirmedProgress: 1_600, geometry: geometry, policy: .production)
    expect(!afterStop.isCappedByStop && afterStop.upper == geometry.totalMeters, "a visited stop no longer caps")
}

// MARK: - Rejoin confirmation

private func runTracker(
    _ fixes: [NavigationLocationSampleV1],
    route: NavigationRouteV1 = northRoute(),
    progress: Double = 900
) -> SavedRouteRejoinV1? {
    var tracker = SavedRouteRejoinTrackerV1()
    let geometry = SavedRouteGeometryV1(route: route)
    for fix in fixes {
        if let rejoin = tracker.observe(fix, geometry: geometry, confirmedProgress: progress, policy: .production) {
            return rejoin
        }
    }
    return nil
}

private func testTrackerConfirmsHeadingAndProgress() {
    let fixes = (0..<3).map { sample(point(3, 1_200 + Double($0) * 10), course: 0, at: t0.addingTimeInterval(Double($0) * 2)) }
    let rejoin = runTracker(fixes)
    expect(rejoin != nil && abs(rejoin!.distanceAlongMeters - 1_220) < 1, "three forward fixes along the route confirm")
    expect(rejoin?.isBeyondWindow == false && rejoin?.skippedStopDistances == [], "an ordinary rejoin")
    expect(runTracker(Array(fixes.prefix(2))) == nil, "two fixes are not enough")
}

private func testTrackerRejectsSidewaysAndWrongWay() {
    let crossing = (0..<6).map { sample(point(-25 + Double($0) * 10, 1_200), course: 90, at: t0.addingTimeInterval(Double($0) * 2)) }
    expect(runTracker(crossing) == nil, "crossing the route sideways never confirms")
    let wrongWay = (0..<6).map { sample(point(2, 1_300 - Double($0) * 10), course: 180, at: t0.addingTimeInterval(Double($0) * 2)) }
    expect(runTracker(wrongWay) == nil, "riding the route the wrong way never confirms")
    let inaccurate = (0..<6).map { sample(point(2, 1_200 + Double($0) * 10), accuracy: 80, at: t0.addingTimeInterval(Double($0) * 2)) }
    expect(runTracker(inaccurate) == nil, "inaccurate fixes never confirm")
}

private func testTrackerHasNoProximityShortcutNearDestination() {
    let route = northRoute()
    let finish = (0..<2).map { sample(point(1, 2_995 + Double($0) * 2), course: 0, at: t0.addingTimeInterval(Double($0))) }
    expect(runTracker(finish, route: route, progress: 2_700) == nil, "being at the destination is not a rejoin")
    let slow = (0..<4).map { sample(point(1, 2_940 + Double($0) * 6), course: -1, speed: 0.5, at: t0.addingTimeInterval(Double($0) * 4)) }
    expect(runTracker(slow, route: route, progress: 2_700) == nil, "slow fixes need five matches")
    let slowFive = (0..<5).map { sample(point(1, 2_940 + Double($0) * 6), course: -1, speed: 0.5, at: t0.addingTimeInterval(Double($0) * 4)) }
    expect(runTracker(slowFive, route: route, progress: 2_700) != nil, "five slow forward fixes confirm")
}

private func testTrackerBeyondStopNeedsLongerMatchAndReportsSkip() {
    let route = savedRoute(track([(0, 0), (0, 3_000)]), steps: [(60, "Arrive at Bakery", .straight)])
    let short = (0..<4).map { sample(point(2, 1_800 + Double($0) * 15), course: 0, at: t0.addingTimeInterval(Double($0) * 3)) }
    expect(runTracker(short, route: route, progress: 1_200) == nil, "a rejoin past an unvisited stop needs more evidence")
    let long = (0..<8).map { sample(point(2, 1_800 + Double($0) * 15), course: 0, at: t0.addingTimeInterval(Double($0) * 3)) }
    let rejoin = runTracker(long, route: route, progress: 1_200)
    expect(rejoin?.isBeyondWindow == true, "the confirmed match is beyond the window")
    expect(rejoin.map { $0.skippedStopDistances.count == 1 && abs($0.skippedStopDistances[0] - 1_500) < 0.5 } == true,
           "the skipped stop is reported, never silent")
}

// MARK: - Engine with the real saved-route runtime

private struct Ride {
    var runtime = NavigationRuntimeV1()
    var detourRuntime = NavigationRuntimeV1()
    var engine: SavedRouteDetourEngineV1
    var effects: [SavedRouteDetourEffectV1] = []
    var lastSample: NavigationLocationSampleV1?
    let generation: UInt32

    init(route: NavigationRouteV1) {
        _ = try! runtime.start(route: route, contentHash: "hash", mode: .offline,
                               initialStepStrategy: .nearestUnambiguous, initialLocation: nil)
        generation = runtime.generation
        engine = SavedRouteDetourEngineV1(route: route)
    }

    /// Feeds one fix the way the iPhone engine and the Watch manager do.
    mutating func feed(_ fix: NavigationLocationSampleV1, now: Date? = nil) {
        lastSample = fix
        let saved = engine.isHoldingSavedRoute ? nil : try? runtime.process(fix)
        let detour = engine.phase == .following ? try? detourRuntime.process(fix) : nil
        apply(engine.observe(fix, savedRouteSnapshot: saved, detourSnapshot: detour, now: now ?? fix.timestamp))
    }

    mutating func complete(_ outcome: BicycleDetourOutcomeV1, now: Date? = nil) {
        guard case .requestDetour(let request)? = effects.last(where: {
            if case .requestDetour = $0 { return true } else { return false }
        }) else { fatalError("no request") }
        apply(engine.complete(requestID: request.id, outcome: outcome, latestSample: lastSample!,
                              now: now ?? lastSample!.timestamp))
    }

    mutating func apply(_ new: [SavedRouteDetourEffectV1]) {
        for effect in new {
            switch effect {
            case .startDetour(let route):
                _ = try! detourRuntime.start(route: route, mode: .online, initialStepStrategy: .first,
                                             initialLocation: lastSample)
            case .resumeSavedRoute(let rejoin):
                _ = try! runtime.resume(atDistanceAlongGeometry: rejoin.distanceAlongMeters, currentLocation: lastSample!)
            case .endDetour:
                detourRuntime.stop()
            default:
                break
            }
        }
        effects += new
    }

    var lastRequest: SavedRouteDetourRequestV1? {
        for effect in effects.reversed() { if case .requestDetour(let request) = effect { return request } }
        return nil
    }
}

/// A plausible detour: from the rider east of the route, north, then west onto the target.
private func syntheticDetour(from rider: RouteCoordinateV1, riderEast: Double, riderNorth: Double,
                             to targetNorth: Double, provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.valhallaDetour) -> NavigationRouteV1 {
    var points = [rider]
    points += track([(riderEast, riderNorth), (riderEast, targetNorth), (0, targetNorth)]).dropFirst()
    let cumulative = NavigationGeometryV1.cumulativeDistances(for: points)
    let turn = points.count - 1 - Int((riderEast / 25).rounded(.up))
    let steps = [
        NavigationRouteStepV1(id: 1, geometryStartIndex: 0, geometryEndIndex: turn, instruction: "Turn left onto Street 7",
                              maneuver: .left, distanceMeters: cumulative[turn]),
        NavigationRouteStepV1(id: 2, geometryStartIndex: turn, geometryEndIndex: points.count - 1,
                              instruction: "Your destination is on the right.", maneuver: .arrive,
                              distanceMeters: cumulative.last! - cumulative[turn]),
    ]
    let route = NavigationRouteV1(
        id: UUID(), revision: 1, provider: provider, localeIdentifier: "en_AE", transportType: .cycling,
        source: RouteEndpointV1(coordinate: points[0], label: "Current Location"),
        destination: RouteEndpointV1(coordinate: points.last!, label: "Saved route"),
        bounds: RouteBoundsV1.enclosing(points)!, distanceMeters: cumulative.last!, expectedTravelTimeSeconds: 120,
        name: nil, points: points, steps: steps, normalizationVersion: 1
    )
    try! route.validate()
    return route
}

/// Rides 0–900 m on the route, then drifts east to 120 m off it.
private func leaveRoute(_ ride: inout Ride) -> Date {
    var time = t0
    for north in stride(from: 0.0, through: 900, by: 10) {
        ride.feed(sample(point(0, north), course: 0, at: time))
        time.addTimeInterval(2)
    }
    expect(ride.engine.phase == .onRoute && abs(ride.engine.confirmedProgressMeters - 900) < 2, "on route until 900 m")
    for step in 1...12 {
        ride.feed(sample(point(Double(step) * 10, 900 + Double(step) * 8), course: 50, at: time))
        time.addTimeInterval(2)
    }
    return time
}

private func testEngineDetourAndConfirmedRejoinResumeOriginalGuidance() {
    var ride = Ride(route: northRoute())
    let time = leaveRoute(&ride)
    guard let request = ride.lastRequest else { fatalError("FAILED: a reliable departure asks for a detour") }
    expect(ride.engine.phase == .requesting && ride.engine.isHoldingSavedRoute, "requesting while the saved route is held")
    expect(request.target.kind == .ahead && request.target.distanceAlongMeters > 980 &&
           request.target.distanceAlongMeters < 1_200, "the target is ahead of the rider's nearest point")
    expect(request.originCourseDegrees == 50, "the rider's course travels with the request")
    expect(ride.effects.filter { if case .requestDetour = $0 { return true }; return false }.count == 1, "one request")

    // A stale answer for another request changes nothing.
    expect(ride.engine.complete(requestID: request.id &+ 7, outcome: .noBicycleRoute, latestSample: ride.lastSample!,
                                now: time).isEmpty && ride.engine.phase == .requesting, "stale answers are ignored")

    let detour = syntheticDetour(from: ride.lastSample!.coordinate, riderEast: 120, riderNorth: 996,
                                 to: request.target.distanceAlongMeters)
    ride.complete(.route(detour), now: time)
    expect(ride.engine.phase == .following, "following the detour")
    guard case .startDetour(let prepared)? = ride.effects.last else { fatalError("FAILED: detour started") }
    expect(prepared.steps.last?.instruction == "Rejoin saved route" && prepared.steps.last?.maneuver == .right,
           "westbound onto the northbound route: a right turn to rejoin, never an arrival")
    expect(ride.detourRuntime.snapshot?.instruction == "Turn left onto Street 7", "detour guidance")

    // Follow the detour north, then turn west back onto the route and continue north.
    var now = time
    for north in stride(from: 1_000.0, through: request.target.distanceAlongMeters, by: 15) {
        ride.feed(sample(point(120, north), course: 0, at: now)); now.addTimeInterval(3)
    }
    for east in stride(from: 100.0, through: 10, by: -25) {
        ride.feed(sample(point(east, request.target.distanceAlongMeters), course: 270, at: now)); now.addTimeInterval(3)
    }
    expect(ride.engine.phase != .onRoute, "arriving at the rejoin point alone does not rejoin")
    var north = request.target.distanceAlongMeters + 5
    while ride.engine.phase != .onRoute && north < 1_400 {
        ride.feed(sample(point(2, north), course: 0, at: now)); now.addTimeInterval(2); north += 10
    }
    expect(ride.engine.phase == .onRoute, "a confirmed forward match rejoins")
    expect(ride.effects.contains(.endDetour), "the detour is removed")
    guard case .resumeSavedRoute(let rejoin)? = ride.effects.last else { fatalError("FAILED: resume effect") }
    let snapshot = ride.runtime.snapshot!
    expect(snapshot.navigationGeneration == ride.generation && snapshot.contentHash == "hash",
           "the saved route keeps its generation and content hash")
    expect(abs((snapshot.distanceAlongGeometryMeters ?? 0) - rejoin.distanceAlongMeters) < 15, "progress resumes at the rejoin")
    expect(snapshot.instruction == "Continue on Al Wasl Road" && snapshot.offRouteDistanceMeters == nil,
           "original guidance resumes on the right step")
    ride.feed(sample(point(1, north + 10), course: 0, at: now))
    expect(ride.engine.phase == .onRoute, "riding on")
}

private func testEngineOfflineAndBackOnline() {
    var ride = Ride(route: northRoute())
    _ = ride.engine.networkChanged(available: false, latestSample: nil, now: t0)
    let time = leaveRoute(&ride)
    expect(ride.lastRequest == nil && ride.engine.phase == .unavailable(.offline), "offline: no request, original route kept")
    ride.apply(ride.engine.networkChanged(available: true, latestSample: ride.lastSample, now: time))
    expect(ride.lastRequest != nil && ride.engine.phase == .requesting, "back online while off route asks at once")
}

private func testEngineTriggerNeedsTimeAndDisplacement() {
    var ride = Ride(route: northRoute())
    var time = t0
    for north in stride(from: 0.0, through: 500, by: 10) { ride.feed(sample(point(0, north), at: time)); time.addTimeInterval(2) }
    // Drifting off but standing still: no request however long.
    for index in 0..<20 { ride.feed(sample(point(60, 500), speed: 0, at: time.addingTimeInterval(Double(index) * 2))) }
    expect(ride.engine.phase == .offRoute && ride.lastRequest == nil, "a stationary rider never triggers a request")
}

private func testEngineNoRouteMovesToNextCandidateAndMotionCancels() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    let first = ride.lastRequest!
    ride.complete(.noBicycleRoute, now: time)
    ride.feed(sample(point(122, 998), course: 0, at: time.addingTimeInterval(1)))
    let second = ride.lastRequest!
    expect(second.id != first.id && second.target.kind == .nearest, "no bicycle route: the next candidate is asked")
    // Moving 100+ m during the request cancels it and asks again from here.
    time = time.addingTimeInterval(20)
    ride.feed(sample(point(240, 1_000), course: 90, at: time))
    expect(ride.effects.contains(.cancelRequest(second.id)), "material motion cancels the request")
    expect(ride.lastRequest!.id != second.id, "and asks again from the new position")
    // An answer for the cancelled request is ignored.
    expect(ride.engine.complete(requestID: second.id, outcome: .route(northRoute()), latestSample: ride.lastSample!,
                                now: time).isEmpty, "a cancelled request's answer is discarded")
}

private func requestCount(_ ride: Ride) -> Int {
    ride.effects.filter { if case .requestDetour = $0 { return true }; return false }.count
}

/// Like the Buenos Aires retry, this path crosses the saved route at a
/// backward angle and finishes 50 m to the side of it.
private func wrongWayDetour(endpointEast: Double = 50) -> NavigationRouteV1 {
    savedRoute(
        track([(120, 996), (120, 1_350), (-45, 1_300), (endpointEast, 1_250)], spacing: 5),
        provider: RouteProviderPolicyV1.valhallaDetour
    )
}

private func followDetour(_ detour: NavigationRouteV1, ride: inout Ride, time: inout Date) {
    for (from, to) in zip(detour.points, detour.points.dropFirst()) {
        time.addTimeInterval(1)
        ride.feed(sample(to, course: SavedRouteGeometryV1.bearing(from: from, to: to), at: time))
    }
}

private func testEngineCompletedWrongWayDetourRetriesFromEndpoint() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    ride.complete(.noBicycleRoute, now: time)
    ride.feed(sample(point(120, 996), at: time))
    let retry = ride.lastRequest!
    expect(retry.target.kind == .nearest, "the first rejection already used the ahead candidate")

    let detour = wrongWayDetour()
    ride.complete(.route(detour), now: time)
    followDetour(detour, ride: &ride, time: &time)
    expect(ride.engine.phase == .following && requestCount(ride) == 2,
           "a wrong-way crossing and arrival at the offset endpoint do not rejoin or immediately reroute")

    let endpoint = detour.points.last!
    let fresh = time.addingTimeInterval(5)
    ride.feed(sample(endpoint, speed: 0, at: fresh), now: fresh.addingTimeInterval(11))
    expect(ride.engine.phase == .following, "a stale endpoint fix cannot end the detour")
    let accurate = fresh.addingTimeInterval(12)
    ride.feed(sample(endpoint, speed: 0, at: accurate))
    ride.feed(sample(endpoint, speed: 0, accuracy: 80, at: accurate.addingTimeInterval(5)))
    expect(ride.engine.phase == .following, "an inaccurate fix interrupts endpoint confirmation")
    ride.feed(sample(endpoint, speed: 0, at: accurate.addingTimeInterval(6)))
    expect(ride.engine.phase == .following, "the endpoint must remain confirmed through the grace period")
    ride.feed(sample(endpoint, speed: 0, at: accurate.addingTimeInterval(3)),
              now: accurate.addingTimeInterval(7))
    ride.feed(sample(endpoint, speed: 0, at: accurate.addingTimeInterval(8)))
    expect(ride.engine.phase == .following, "an out-of-order fix cannot backdate endpoint confirmation")
    ride.feed(sample(endpoint, speed: 0, at: accurate.addingTimeInterval(10)))

    guard case .requestDetour(let recovery)? = ride.effects.last else {
        fatalError("FAILED: recovery requests the next candidate")
    }
    expect(ride.effects.suffix(2).first == .endDetour && ride.detourRuntime.snapshot == nil,
           "the stale detour is cleared before retrying")
    expect(recovery.origin == endpoint && recovery.target.kind == .further && recovery.episode == retry.episode,
           "recovery uses the stopped rider's fix and the next candidate in the same episode")
    expect(recovery.originCourseDegrees == nil && requestCount(ride) == 3,
           "a stationary fix has no course and generates one request")
    expect(ride.engine.isHoldingSavedRoute && ride.runtime.generation == ride.generation &&
           ride.runtime.snapshot?.offRouteDistanceMeters != nil,
           "completing a wrong-way detour does not resume or replace saved navigation")
}

private func testEngineDetourEndNeverResetsAnExhaustedBudgetAtTheEndpoint() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    for _ in 0..<3 {
        ride.complete(.noBicycleRoute, now: time)
        time.addTimeInterval(1)
        ride.feed(sample(point(120, 996), at: time))
    }
    expect(ride.lastRequest?.target.kind == .leavePoint && requestCount(ride) == 4,
           "the last available candidate is in flight")
    let detour = wrongWayDetour()
    ride.complete(.route(detour), now: time)
    followDetour(detour, ride: &ride, time: &time)
    let endpoint = detour.points.last!
    for _ in 0..<10 {
        time.addTimeInterval(1)
        ride.feed(sample(endpoint, speed: 0, at: time))
    }
    expect(ride.engine.phase == .unavailable(.noBicycleRoute) && ride.effects.last == .endDetour,
           "an exhausted episode offers the normal off-route state")
    expect(requestCount(ride) == 4, "distance traveled on the last detour cannot reset the budget")
    time.addTimeInterval(60)
    ride.feed(sample(point(400, 1_250), course: 90, at: time))
    expect(requestCount(ride) == 5 && ride.lastRequest?.target.kind == .ahead,
           "moving sufficiently far from the exhausted endpoint can start a new set of candidates")
}

private func testEngineCompletedDetourRecoversWhenBackOnline() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    // The finished detour is outside the GPS rejoin band but closer than the
    // normal 40 m cross-track threshold for starting the first detour.
    let detour = wrongWayDetour(endpointEast: 35)
    ride.complete(.route(detour), now: time)
    ride.apply(ride.engine.networkChanged(available: false, latestSample: ride.lastSample, now: time))
    followDetour(detour, ride: &ride, time: &time)
    let endpoint = detour.points.last!
    time.addTimeInterval(5)
    ride.feed(sample(endpoint, speed: 0, at: time))
    expect(ride.engine.phase == .unavailable(.offline) && ride.effects.last == .endDetour &&
           requestCount(ride) == 1, "reaching the end offline clears the detour and waits for the network")
    ride.apply(ride.engine.networkChanged(available: true, latestSample: ride.lastSample, now: time))
    expect(requestCount(ride) == 2 && ride.lastRequest?.target.kind == .nearest &&
           ride.lastRequest?.origin == endpoint, "reconnecting retries without requiring movement away from the endpoint")
}

private func testEngineDetourEndAllowsAConfirmedForwardMerge() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    let detour = savedRoute(
        track([(120, 996), (120, 1_170), (0, 1_170), (0, 1_200)], spacing: 5),
        provider: RouteProviderPolicyV1.valhallaDetour
    )
    ride.complete(.route(detour), now: time)
    followDetour(detour, ride: &ride, time: &time)
    expect(ride.engine.phase == .onRoute && requestCount(ride) == 1 &&
           ride.runtime.snapshot?.offRouteDistanceMeters == nil,
           "rejoin on the forward approach resumes saved guidance without a retry")
}

private func testEngineDoesNotRecoverOnAnEarlierPassOfTheDetourEndpoint() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    let detour = savedRoute(
        track([(120, 996), (50, 1_100), (145, 1_200), (115, 1_285), (50, 1_100)], spacing: 5),
        provider: RouteProviderPolicyV1.valhallaDetour
    )
    ride.complete(.route(detour), now: time)
    let endpoint = detour.points.last!
    for coordinate in detour.points.dropFirst() {
        time.addTimeInterval(1)
        ride.feed(sample(coordinate, at: time))
        if coordinate == endpoint { break }
    }
    time.addTimeInterval(6)
    ride.feed(sample(endpoint, speed: 0, at: time))
    expect(ride.engine.phase == .following && requestCount(ride) == 1,
           "being at the endpoint on an earlier pass is not completing the detour")
}

private func testEngineStaleOriginAnswerAsksAgainForSameCandidate() {
    var ride = Ride(route: northRoute())
    let time = leaveRoute(&ride)
    let first = ride.lastRequest!
    // 80 m further on (under the 100 m motion cancel) when the answer, which
    // starts where the request was made, arrives: ask again, not "no route".
    let answer = syntheticDetour(from: first.origin, riderEast: 120, riderNorth: 996,
                                 to: first.target.distanceAlongMeters)
    let moved = RouteCoordinateV1(latitude: first.origin.latitude + 80 / 111_320,
                                  longitude: first.origin.longitude)
    ride.feed(sample(moved, course: 0, at: time.addingTimeInterval(12)))
    expect(ride.engine.phase == .requesting && requestCount(ride) == 1, "80 m of motion keeps the request")
    ride.complete(.route(answer), now: time.addingTimeInterval(12))
    let second = ride.lastRequest!
    expect(second.id != first.id && second.target.kind == first.target.kind,
           "a stale-origin answer asks again for the same candidate from the new position")
    expect(ride.engine.phase == .requesting && ride.engine.detour == nil, "not counted as no bicycle route")

    // A route that starts far from both the request and the rider is still
    // rejected as no route (no loop on a badly snapped answer).
    var far = Ride(route: northRoute())
    let farTime = leaveRoute(&far)
    let request = far.lastRequest!
    let snapped = syntheticDetour(from: point(320, 996), riderEast: 320, riderNorth: 996,
                                  to: request.target.distanceAlongMeters)
    far.complete(.route(snapped), now: farTime)
    expect(far.engine.phase == .unavailable(.noBicycleRoute) && requestCount(far) == 1,
           "a route starting 200 m from the request is rejected")
}

private func testEngineFailedDetourStartBacksOff() {
    var ride = Ride(route: northRoute())
    let time = leaveRoute(&ride)
    let request = ride.lastRequest!
    let detour = syntheticDetour(from: ride.lastSample!.coordinate, riderEast: 120, riderNorth: 996,
                                 to: request.target.distanceAlongMeters)
    // The host fails to start guidance on the accepted detour.
    _ = ride.engine.complete(requestID: request.id, outcome: .route(detour), latestSample: ride.lastSample!, now: time)
    expect(ride.engine.phase == .following, "accepted")
    ride.engine.detourStartFailed(now: time)
    expect(ride.engine.phase == .unavailable(.serviceError) && ride.engine.detour == nil &&
           ride.engine.isHoldingSavedRoute, "an unguidable detour is dropped; the saved route stays held")
    ride.feed(sample(point(121, 1_000), course: 0, at: time.addingTimeInterval(5)))
    expect(requestCount(ride) == 1, "backs off")
    ride.feed(sample(point(122, 1_010), course: 0, at: time.addingTimeInterval(16)))
    expect(requestCount(ride) == 2, "asks again after the back-off")
}

private func testEngineDisableRequestsStopsAndResumes() {
    var ride = Ride(route: northRoute())
    var time = leaveRoute(&ride)
    let request = ride.lastRequest!
    let cancelled = ride.engine.disableRequests()
    expect(cancelled == [.cancelRequest(request.id)] && ride.engine.phase == .unavailable(.offline),
           "turning online routing off cancels the pending request")
    ride.apply(cancelled)
    for step in 1...6 {
        time.addTimeInterval(20)
        ride.feed(sample(point(120, 996 + Double(step) * 20), course: 0, at: time))
    }
    expect(requestCount(ride) == 1, "no request while online routing is off")
    ride.apply(ride.engine.networkChanged(available: true, latestSample: ride.lastSample, now: time))
    expect(requestCount(ride) == 2 && ride.engine.phase == .requesting, "turning it back on asks again")

    // While following: the detour ends too.
    let next = ride.lastRequest!
    let detour = syntheticDetour(from: ride.lastSample!.coordinate, riderEast: 120, riderNorth: 996 + 120,
                                 to: next.target.distanceAlongMeters)
    ride.complete(.route(detour), now: time)
    expect(ride.engine.phase == .following, "following")
    let ended = ride.engine.disableRequests()
    ride.apply(ended)
    expect(ended == [.endDetour] && ride.engine.detour == nil && ride.detourRuntime.snapshot == nil &&
           ride.engine.isHoldingSavedRoute, "the detour is dropped and the saved route stays held")
}

private func testEngineRejectsImplausibleDetourAndBacksOff() {
    var ride = Ride(route: northRoute())
    let time = leaveRoute(&ride)
    // Ends 400 m east of the saved route: rejected like "no route".
    let wrong = syntheticDetour(from: ride.lastSample!.coordinate, riderEast: 120, riderNorth: 996, to: 1_100)
    let shifted = NavigationRouteV1(
        id: wrong.id, revision: 1, provider: wrong.provider, localeIdentifier: wrong.localeIdentifier,
        transportType: .cycling, source: wrong.source,
        destination: RouteEndpointV1(coordinate: point(400, 1_100), label: "Saved route"),
        bounds: RouteBoundsV1.enclosing(wrong.points.dropLast() + [point(400, 1_100)])!, distanceMeters: wrong.distanceMeters,
        expectedTravelTimeSeconds: nil, name: nil, points: wrong.points.dropLast() + [point(400, 1_100)],
        steps: wrong.steps, normalizationVersion: 1
    )
    ride.complete(.route(shifted), now: time)
    expect(ride.engine.phase == .unavailable(.noBicycleRoute) && ride.engine.detour == nil,
           "a detour that does not end on the saved route is rejected")
    ride.feed(sample(point(121, 997), course: 0, at: time.addingTimeInterval(1)))
    ride.complete(.unavailable(.serviceError, retryAfterSeconds: 45), now: time.addingTimeInterval(1))
    let count = ride.effects.filter { if case .requestDetour = $0 { return true }; return false }.count
    ride.feed(sample(point(122, 998), course: 0, at: time.addingTimeInterval(30)))
    expect(ride.effects.filter { if case .requestDetour = $0 { return true }; return false }.count == count,
           "Retry-After is honoured")
    ride.feed(sample(point(123, 999), course: 0, at: time.addingTimeInterval(47)))
    expect(ride.effects.filter { if case .requestDetour = $0 { return true }; return false }.count == count + 1,
           "asked again after the back-off")
}

private func testRuntimeResumeKeepsIdentityAndJumpsSteps() {
    let route = northRoute()
    var runtime = NavigationRuntimeV1()
    _ = try! runtime.start(route: route, contentHash: "abc", mode: .offline, initialLocation: sample(point(0, 10), at: t0))
    let generation = runtime.generation
    let snapshot = try! runtime.resume(atDistanceAlongGeometry: 2_600, currentLocation: sample(point(1, 2_600), at: t0.addingTimeInterval(60)))
    expect(snapshot.navigationGeneration == generation && snapshot.contentHash == "abc", "identity kept")
    expect(snapshot.currentStepIndex == 2 && snapshot.maneuver == .arrive, "steps skipped on the detour are not replayed")
    expect(abs((snapshot.distanceAlongGeometryMeters ?? 0) - 2_600) < 2, "progress at the rejoin")
}

// MARK: - Providers

@MainActor
private final class FakeDirections: BicycleDetourDirectionsCalculating {
    let result: Result<[MKRoute], Error>
    var gate = false
    var cancelled = false
    init(_ result: Result<[MKRoute], Error>) { self.result = result }
    func calculate() async throws -> [MKRoute] {
        while gate { await Task.yield() }
        return try result.get()
    }
    func cancel() { cancelled = true }
}

@MainActor
private final class FakeServiceTransport: BicycleDetourServiceTransporting {
    var requests: [BicycleDetourServiceRequestV1] = []
    var response: BicycleDetourHTTPResponseV1
    init(body: Data) {
        response = BicycleDetourHTTPResponseV1(statusCode: 200, cacheControl: "private, no-store",
                                               contentType: "application/json", retryAfter: nil, body: body)
    }
    func post(_ request: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        requests.append(request)
        return response
    }
}

nonisolated private final class FakeMapKitRoute: MKRoute, @unchecked Sendable {
    let line: MKPolyline
    init(_ coordinates: [CLLocationCoordinate2D]) {
        line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        super.init()
    }
    override var polyline: MKPolyline { line }
    override var steps: [MKRoute.Step] { [] }
    override var distance: CLLocationDistance { 500 }
    override var expectedTravelTime: TimeInterval { 120 }
    override var name: String { "Turn right onto Street 9" }
}

private func directionsError(_ code: Int?, mkCode: MKError.Code = .serverFailure) -> NSError {
    NSError(domain: MKErrorDomain, code: Int(mkCode.rawValue),
            userInfo: code.map { [CyclingDirectionsFallback.directionsErrorCodeKey: NSNumber(value: $0)] } ?? [:])
}

@MainActor
private func testProviderChain() async {
    let fixture = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("dubai-ready-response.json"))
    let query = BicycleDetourQueryV1(origin: RouteCoordinateV1(latitude: 25.2066, longitude: 55.2692),
                                     originCourseDegrees: 182, rejoin: RouteCoordinateV1(latitude: 25.2258, longitude: 55.2631),
                                     routeSource: "strava", localeIdentifier: "en_AE")
    func chain(_ result: Result<[MKRoute], Error>) -> (BicycleDetourProviderChainV1, FakeServiceTransport, () -> [MKDirectionsTransportType]) {
        var transportTypes: [MKDirectionsTransportType] = []
        let mapKit = MapKitCyclingDetourProvider { request in
            transportTypes.append(request.transportType)
            return FakeDirections(result)
        }
        let transport = FakeServiceTransport(body: fixture)
        return (BicycleDetourProviderChainV1(mapKit: mapKit, fallback: BicinoBicycleDetourProvider(transport: transport)),
                transport, { transportTypes })
    }

    for (code, mkCode, label) in [(Optional(8), MKError.Code.serverFailure, "out of coverage (UAE)"),
                                  (Optional(16), .serverFailure, "not reachable"),
                                  (nil, .directionsNotFound, "directions not found")] {
        let (provider, transport, types) = chain(.failure(directionsError(code, mkCode: mkCode)))
        let outcome = await provider.detour(for: query)
        guard case .route(let route) = outcome else { fatalError("FAILED: \(label) falls back to Valhalla") }
        expect(route.provider == RouteProviderPolicyV1.valhallaDetour, "\(label): Valhalla bicycle route")
        expect(provider.lastMapKitOutcome == .noBicycleRoute, "\(label): MapKit answered no cycling route")
        expect(types() == [.cycling], "\(label): only a cycling request, never driving")
        expect(transport.requests.count == 1 && transport.requests[0].routeSource == "strava", "\(label): provenance kept")
        let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(transport.requests[0])) as! [String: Any]
        expect(Set(encoded.keys) == ["schema", "requestId", "origin", "rejoin", "routeSource", "locale"],
               "\(label): only the documented fields are sent")
        expect(Set((encoded["rejoin"] as! [String: Any]).keys) == ["latitudeE6", "longitudeE6"] &&
               (encoded["origin"] as! [String: Any])["courseDegrees"] as? Double == 182 &&
               encoded["locale"] as? String == "en-AE", "\(label): exactly two coordinates")
    }

    let (transientChain, transientTransport, _) = chain(.failure(directionsError(nil)))
    let transient = await transientChain.detour(for: query)
    expect(transient == .unavailable(.serviceError, retryAfterSeconds: nil) &&
           transientTransport.requests.isEmpty, "a transient MapKit failure does not fall back")
    let (offlineChain, offlineTransport, _) = chain(.failure(URLError(.notConnectedToInternet)))
    let offline = await offlineChain.detour(for: query)
    expect(offline == .unavailable(.offline, retryAfterSeconds: nil) &&
           offlineTransport.requests.isEmpty, "offline MapKit does not fall back")

    let mapKitRoute = FakeMapKitRoute([
        CLLocationCoordinate2D(latitude: 25.2066, longitude: 55.2692),
        CLLocationCoordinate2D(latitude: 25.2100, longitude: 55.2680),
        CLLocationCoordinate2D(latitude: 25.2258, longitude: 55.2631),
    ])
    let (successChain, successTransport, successTypes) = chain(.success([mapKitRoute]))
    guard case .route(let mapKitDetour) = await successChain.detour(for: query) else {
        fatalError("FAILED: a MapKit cycling route is used")
    }
    expect(mapKitDetour.provider == RouteProviderPolicyV1.mapKit && successTransport.requests.isEmpty &&
           successTypes() == [.cycling], "MapKit success never calls Valhalla")

    // Cancelled while MapKit is still answering: no second request.
    var gated: FakeDirections?
    let cancellable = BicycleDetourProviderChainV1(
        mapKit: MapKitCyclingDetourProvider { _ in
            let directions = FakeDirections(.failure(directionsError(8)))
            directions.gate = true
            gated = directions
            return directions
        },
        fallback: BicinoBicycleDetourProvider(transport: successTransport)
    )
    let pending = Task { await cancellable.detour(for: query) }
    while gated == nil { await Task.yield() }
    cancellable.cancel()
    gated?.gate = false
    let cancelledOutcome = await pending.value
    expect(cancelledOutcome == .cancelled && successTransport.requests.isEmpty,
           "a cancelled request never goes on to Valhalla")
}

// MARK: - Contract

@MainActor
private func testServiceContract() {
    let body = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("dubai-ready-response.json"))
    let ok = BicycleDetourHTTPResponseV1(statusCode: 200, cacheControl: "private, no-store",
                                         contentType: "application/json; charset=utf-8", retryAfter: nil, body: body)
    guard case .route(let route) = BicycleDetourServiceDecoderV1.outcome(for: ok, localeIdentifier: "en_AE") else {
        fatalError("FAILED: the Dubai service answer converts")
    }
    expect(route.points.count == 137 && route.steps.count == 12, "12 steps over 137 points")
    expect(route.steps.first?.instruction == "Bear right toward Al Safa Street/شارع الصفا." &&
           route.steps.first?.maneuver == .slightRight, "step 1 announces the maneuver at its end")
    expect(route.steps.last?.maneuver == .arrive, "the raw last step is the arrival")
    let prepared = SavedRouteDetourRouteV1.prepared(route, savedRouteBearing: 300)
    expect(prepared.steps.last?.instruction == "Rejoin saved route" && prepared.steps.last?.maneuver != .arrive,
           "prepared detours never arrive")
    expect(route.provider.storageScope == .activeOnly && route.transportType == .cycling, "active-only bicycle route")

    func outcome(_ status: Int, _ body: Data = Data(), cache: String? = "private, no-store", retry: String? = nil) -> BicycleDetourOutcomeV1 {
        BicycleDetourServiceDecoderV1.outcome(for: BicycleDetourHTTPResponseV1(
            statusCode: status, cacheControl: cache, contentType: "application/json", retryAfter: retry, body: body
        ), localeIdentifier: "en")
    }
    let noRoute = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("no-bicycle-route-response.json"))
    expect(outcome(200, noRoute) == .noBicycleRoute, "no bicycle route")
    expect(outcome(429, retry: "120") == .unavailable(.serviceError, retryAfterSeconds: 120), "rate limited")
    expect(outcome(503, retry: "30") == .unavailable(.serviceError, retryAfterSeconds: 30), "busy")
    expect(outcome(200, body, cache: "max-age=60") == .unavailable(.serviceError, retryAfterSeconds: nil),
           "a cacheable answer is refused")

    var tampered = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
    var tamperedRoute = tampered["route"] as! [String: Any]
    tamperedRoute["travelMode"] = "drive"
    tampered["route"] = tamperedRoute
    expect(outcome(200, try! JSONSerialization.data(withJSONObject: tampered)) == .noBicycleRoute,
           "a non-bicycle route is never used")

    expect(BicycleDetourServiceRequestV1.languageTag("en_AE@calendar=gregorian") == "en-AE" &&
           BicycleDetourServiceRequestV1.languageTag("zh-Hans_HK") == "zh-Hans-HK" &&
           BicycleDetourServiceRequestV1.languageTag("x") == "en-US", "locale tags")
}

private func testProviderPolicy() {
    expect(RouteProviderPolicyV1.bicycleDetourRouteSource(RouteProviderPolicyV1.importedGPX) == "gpx" &&
           RouteProviderPolicyV1.bicycleDetourRouteSource(RouteProviderPolicyV1.strava) == "strava" &&
           RouteProviderPolicyV1.bicycleDetourRouteSource(RouteProviderPolicyV1.mapKitSavedOnPhone) == "mapkit",
           "GPX, Strava and saved Apple Maps routes are eligible")
    expect(RouteProviderPolicyV1.bicycleDetourRouteSource(RouteProviderPolicyV1.mapKit) == nil &&
           RouteProviderPolicyV1.bicycleDetourRouteSource(RouteProviderPolicyV1.valhallaDetour) == nil,
           "live routes and detours themselves are not")
    let valhalla = RouteProviderPolicyV1.valhallaDetour
    expect(RouteProviderPolicyV1.hasConsistentKnownPolicy(valhalla) &&
           !RouteProviderPolicyV1.hasConsistentKnownPolicy(RouteProviderMetadataV1(
            providerID: valhalla.providerID, attribution: valhalla.attribution, storageScope: .durable)),
           "the detour provider is pinned to active-only")
    expect(!RouteProviderPolicyV1.allowsDurableStorage(valhalla) && !RouteProviderPolicyV1.allowsSocialSharing(valhalla) &&
           RouteProviderPolicyV1.routeElevationServiceSource(valhalla) == nil, "detours are never stored, shared or sent for elevation")
}

// MARK: - Watch relay

@MainActor
private func testWatchRelayRoundTrip() async {
    let body = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("dubai-ready-response.json"))
    let request = BicycleDetourServiceRequestV1(
        origin: RouteCoordinateV1(latitude: 25.2066, longitude: 55.2692), courseDegrees: nil,
        rejoin: RouteCoordinateV1(latitude: 25.2258, longitude: 55.2631), routeSource: "strava", localeIdentifier: "en_AE"
    )
    let message = try! WatchBicycleDetourRelayV1.encode(request)
    expect(WatchBicycleDetourRelayV1.isRequest(message) && WatchBicycleDetourRelayV1.decodeRequest(message) == request,
           "the relayed request is exactly the two-point request")
    var tampered = try! JSONSerialization.jsonObject(with: message.dropFirst(4)) as! [String: Any]
    tampered["routeSource"] = "unknown"
    expect(WatchBicycleDetourRelayV1.decodeRequest(WatchBicycleDetourRelayV1.requestTag +
           (try! JSONSerialization.data(withJSONObject: tampered))) == nil, "the phone forwards only valid requests")
    expect(!WatchBicycleDetourRelayV1.isRequest(Data("prep".utf8)), "other message data is not a relay request")

    // The phone answers with the service's HTTP response; the Watch decodes it like the iPhone.
    var relayed: [Data] = []
    let transport = WatchBicycleDetourRelayTransport { data in
        relayed.append(data)
        return WatchBicycleDetourRelayV1.encode(WatchBicycleDetourRelayV1.response(BicycleDetourHTTPResponseV1(
            statusCode: 200, cacheControl: "private, no-store", contentType: "application/json", retryAfter: nil, body: body
        )))
    }
    let outcome = await BicinoBicycleDetourProvider(transport: transport).detour(for: BicycleDetourQueryV1(
        origin: request.origin.coordinate, originCourseDegrees: nil, rejoin: request.rejoin.coordinate,
        routeSource: "strava", localeIdentifier: "en_AE"
    ))
    guard case .route(let route) = outcome else { fatalError("FAILED: a relayed Valhalla answer becomes a detour") }
    expect(route.provider == RouteProviderPolicyV1.valhallaDetour && relayed.count == 1, "one relay round trip")

    let unreachable = WatchBicycleDetourRelayTransport { _ in throw URLError(.notConnectedToInternet) }
    let offline = await BicinoBicycleDetourProvider(transport: unreachable).detour(for: BicycleDetourQueryV1(
        origin: request.origin.coordinate, originCourseDegrees: nil, rejoin: request.rejoin.coordinate,
        routeSource: "strava", localeIdentifier: "en_AE"
    ))
    expect(offline == .unavailable(.offline, retryAfterSeconds: nil), "an unreachable iPhone means no Valhalla leg")
    let failed = WatchBicycleDetourRelayTransport { _ in
        WatchBicycleDetourRelayV1.encode(WatchBicycleDetourRelayV1.failure(offline: false))
    }
    let failure = await BicinoBicycleDetourProvider(transport: failed).detour(for: BicycleDetourQueryV1(
        origin: request.origin.coordinate, originCourseDegrees: nil, rejoin: request.rejoin.coordinate,
        routeSource: "strava", localeIdentifier: "en_AE"
    ))
    expect(failure == .unavailable(.serviceError, retryAfterSeconds: nil), "a phone-side failure is a service error")
}

private extension BicycleDetourServiceRequestV1.Origin {
    var coordinate: RouteCoordinateV1 { RouteCoordinateV1(latitude: Double(latitudeE6) / 1e6, longitude: Double(longitudeE6) / 1e6) }
}

private extension BicycleDetourServiceRequestV1.Rejoin {
    var coordinate: RouteCoordinateV1 { RouteCoordinateV1(latitude: Double(latitudeE6) / 1e6, longitude: Double(longitudeE6) / 1e6) }
}

// MARK: - Two-line Bicino One mode (RTK1)

private let referenceTrackFixtureFile = repositoryRoot
    .appendingPathComponent("protocol/fixtures/route-reference-track-v1/frames-v1.txt")

private func referenceTrackFixtures() -> (frames: [String: Data], tracks: [String: [RouteReferenceTrackV1.MicrodegreePoint]]) {
    let text = try! String(contentsOf: referenceTrackFixtureFile, encoding: .utf8)
    var frames: [String: Data] = [:]
    var tracks: [String: [RouteReferenceTrackV1.MicrodegreePoint]] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { continue }
        let name = String(fields[0])
        if name.hasSuffix("_track") {
            tracks[String(name.dropLast(6))] = fields[1].split(separator: ";").map { pair in
                let values = pair.split(separator: ",").map { Int32($0)! }
                return RouteReferenceTrackV1.MicrodegreePoint(latitude: values[0], longitude: values[1])
            }
        } else {
            var bytes = Data()
            var index = fields[1].startIndex
            while index < fields[1].endIndex {
                let next = fields[1].index(index, offsetBy: 2)
                bytes.append(UInt8(fields[1][index..<next], radix: 16)!)
                index = next
            }
            frames[name] = bytes
        }
    }
    return (frames, tracks)
}

private func decodeReferenceTrack(_ frame: Data) -> [RouteReferenceTrackV1.MicrodegreePoint] {
    let bytes = [UInt8](frame)
    func int32(_ offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }
    func int16(_ offset: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8) }
    var latitude = int32(6)
    var longitude = int32(10)
    var points = [RouteReferenceTrackV1.MicrodegreePoint(latitude: latitude, longitude: longitude)]
    var offset = 14
    while offset + 4 <= bytes.count {
        latitude += Int32(int16(offset))
        longitude += Int32(int16(offset + 2))
        points.append(.init(latitude: latitude, longitude: longitude))
        offset += 4
    }
    return points
}

private func testReferenceTrackFramesMatchFirmwareGoldens() {
    let fixtures = referenceTrackFixtures()
    expect(RouteReferenceTrackV1.setFrame(fixtures.tracks["dubai"]!) == fixtures.frames["dubai_set"],
           "the Swift encoder writes the bytes the firmware decoder is tested with")
    expect(RouteReferenceTrackV1.setFrame(fixtures.tracks["maximum"]!) == fixtures.frames["maximum_set"],
           "48 points encode to the largest frame")
    expect(fixtures.frames["maximum_set"]!.count == RouteReferenceTrackV1.maximumFrameBytes, "largest frame is 202 bytes")
    expect(RouteReferenceTrackV1.clearFrame() == fixtures.frames["clear"], "clear frame is the bare header")
    expect(RouteReferenceTrackV1.setFrame(Array(fixtures.tracks["dubai"]!.prefix(1))) == nil, "one point is not a track")
    expect(RouteReferenceTrackV1.setFrame(fixtures.tracks["maximum"]! + [fixtures.tracks["maximum"]!.last!]) == nil,
           "more than 48 points are never framed")
    let farApart = [RouteReferenceTrackV1.MicrodegreePoint(latitude: 25_000_000, longitude: 55_000_000),
                    RouteReferenceTrackV1.MicrodegreePoint(latitude: 25_040_000, longitude: 55_000_000)]
    expect(RouteReferenceTrackV1.setFrame(farApart) == nil, "a delta beyond Int16 is refused, never clamped")
    expect(RideBLEGeneratedProtocolV1.extendedRouteReferenceTrackV1Feature == 1 << 7, "two-line mode is extended bit 7")
    expect(RideBLEGeneratedProtocolV1.extendedRouteReferenceTrackV1MinimumClientVersion == 37, "and needs client 37")
}

private func testReferenceTrackSizing() {
    expect(RouteReferenceTrackV1.maximumPoints(forWriteLength: 512) == 48, "large writes are capped at 48 points")
    expect(RouteReferenceTrackV1.maximumPoints(forWriteLength: 202) == 48, "202 bytes hold 48 points")
    expect(RouteReferenceTrackV1.maximumPoints(forWriteLength: 75) == 16, "an MTU-100 session still holds 16 points")
    expect(RouteReferenceTrackV1.maximumPoints(forWriteLength: 18) == 2, "18 bytes hold the minimum track")
    expect(RouteReferenceTrackV1.maximumPoints(forWriteLength: 17) == nil, "less than the minimum track is not sent")
}

private func testReferenceTrackCoversLeavePointToPastRejoin() {
    // 3 km east, then 3 km north; leave at 1,000 m, rejoin at 1,800 m.
    let route = savedRoute(track([(0, 0), (3_000, 0), (3_000, 3_000)], spacing: 10))
    let geometry = SavedRouteGeometryV1(route: route)
    let coordinates = RouteReferenceTrackV1.coordinates(
        geometry: geometry, confirmedProgressMeters: 1_000, rejoinAlongMeters: 1_800
    )
    func along(_ coordinate: RouteCoordinateV1) -> Double {
        NavigationGeometryV1.projections(
            of: coordinate, onto: route.points, cumulativeDistances: geometry.cumulative
        ).min { $0.crossTrackDistanceMeters < $1.crossTrackDistanceMeters }!.distanceAlongRouteMeters
    }
    expect(abs(along(coordinates.first!) - 850) < 1, "starts 150 m behind the leave point")
    expect(abs(along(coordinates.last!) - 2_100) < 1, "ends 300 m past the rejoin point")

    let frame = RouteReferenceTrackV1.frame(
        geometry: geometry, confirmedProgressMeters: 1_000, rejoinAlongMeters: 1_800, maximumPoints: 48
    )!
    let decoded = decodeReferenceTrack(frame)
    expect(decoded.count == 2, "a straight stretch simplifies to its two ends")
    expect(decoded.first == RouteReferenceTrackV1.MicrodegreePoint(coordinates.first!) &&
           decoded.last == RouteReferenceTrackV1.MicrodegreePoint(coordinates.last!),
           "the ends are exact")

    // Around the corner, the corner survives simplification.
    let cornerFrame = RouteReferenceTrackV1.frame(
        geometry: geometry, confirmedProgressMeters: 2_800, rejoinAlongMeters: 3_400, maximumPoints: 48
    )!
    let corner = RouteReferenceTrackV1.MicrodegreePoint(point(3_000, 0))
    expect(decodeReferenceTrack(cornerFrame).contains { abs($0.latitude - corner.latitude) <= 30 && abs($0.longitude - corner.longitude) <= 30 },
           "the corner is kept")

    // The track never extends past the finish.
    let nearFinish = RouteReferenceTrackV1.coordinates(
        geometry: geometry, confirmedProgressMeters: 5_800, rejoinAlongMeters: 5_950
    )
    expect(nearFinish.last == route.points.last, "clamped to the finish")
}

private func testReferenceTrackFitsSmallWritesAndLongSegments() {
    // A winding 4 km route with a vertex every 5 m.
    var corners: [(Double, Double)] = []
    for index in 0...40 { corners.append((Double(index) * 100, index.isMultiple(of: 2) ? 0 : 60)) }
    let winding = savedRoute(track(corners, spacing: 5))
    let windingGeometry = SavedRouteGeometryV1(route: winding)
    // About 3.1 km east end to end: past one Int16 longitude delta, so the
    // smallest track that fits has three points.
    for limit in [48, 16, 5, 3] {
        let frame = RouteReferenceTrackV1.frame(
            geometry: windingGeometry, confirmedProgressMeters: 300, rejoinAlongMeters: 3_500, maximumPoints: limit
        )!
        let count = decodeReferenceTrack(frame).count
        expect(count >= 2 && count <= limit, "\(count) points fit a \(limit)-point write")
    }

    // A straight 9 km road simplifies to its two ends, which are too far apart
    // for one Int16 delta: intermediate points are added back.
    let straight = savedRoute(track([(0, 0), (0, 9_000)], spacing: 1_000))
    let frame = RouteReferenceTrackV1.frame(
        geometry: SavedRouteGeometryV1(route: straight), confirmedProgressMeters: 150, rejoinAlongMeters: 8_000,
        maximumPoints: 48
    )!
    let decoded = decodeReferenceTrack(frame)
    expect(decoded.count >= 3, "long segments are split, not clamped")
    for (a, b) in zip(decoded, decoded.dropFirst()) {
        expect(abs(Int(b.latitude) - Int(a.latitude)) <= 30_000, "every delta stays inside the Int16 range")
    }
    expect(RouteReferenceTrackV1.frame(
        geometry: SavedRouteGeometryV1(route: straight), confirmedProgressMeters: 150, rejoinAlongMeters: 8_000,
        maximumPoints: 2
    ) == nil, "a track that cannot fit is not sent rather than distorted")
}

@main
enum SavedRouteDetourTestRunner {
    @MainActor
    static func main() async {
        testPlannerMissedTurnAimsAhead()
        testPlannerLoopPrefersEarliestPass()
        testPlannerIgnoresLaterCrossingPass()
        testPlannerStopCapsWindow()
        testTrackerConfirmsHeadingAndProgress()
        testTrackerRejectsSidewaysAndWrongWay()
        testTrackerHasNoProximityShortcutNearDestination()
        testTrackerBeyondStopNeedsLongerMatchAndReportsSkip()
        testEngineDetourAndConfirmedRejoinResumeOriginalGuidance()
        testEngineOfflineAndBackOnline()
        testEngineTriggerNeedsTimeAndDisplacement()
        testEngineNoRouteMovesToNextCandidateAndMotionCancels()
        testEngineCompletedWrongWayDetourRetriesFromEndpoint()
        testEngineDetourEndNeverResetsAnExhaustedBudgetAtTheEndpoint()
        testEngineCompletedDetourRecoversWhenBackOnline()
        testEngineDetourEndAllowsAConfirmedForwardMerge()
        testEngineDoesNotRecoverOnAnEarlierPassOfTheDetourEndpoint()
        testEngineRejectsImplausibleDetourAndBacksOff()
        testEngineStaleOriginAnswerAsksAgainForSameCandidate()
        testEngineFailedDetourStartBacksOff()
        testEngineDisableRequestsStopsAndResumes()
        testRuntimeResumeKeepsIdentityAndJumpsSteps()
        await testProviderChain()
        testServiceContract()
        testProviderPolicy()
        await testWatchRelayRoundTrip()
        testReferenceTrackFramesMatchFirmwareGoldens()
        testReferenceTrackSizing()
        testReferenceTrackCoversLeavePointToPastRejoin()
        testReferenceTrackFitsSmallWritesAndLongSegments()
        print("Saved-route detour tests passed")
    }
}
