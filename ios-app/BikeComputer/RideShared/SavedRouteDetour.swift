import Foundation

// Temporary bicycle detours back to a saved route.
//
// The saved route never changes: its runtime keeps its generation, content
// hash and elevation identity, and is only held (not fed fixes) while the
// rider is off it. A detour is a separate, active-only route from the rider to
// one rejoin point ahead on the saved route. Guidance returns to the saved
// route only after a confirmed, heading- and progress-consistent rejoin.
// Everything here is pure and host-tested; the iPhone engine and the Watch
// manager drive it with fixes, runtime snapshots and provider outcomes.

/// Every threshold of the detour feature in one place.
nonisolated struct SavedRouteDetourPolicyV1: Equatable, Sendable {
    var maximumAccuracyMeters = 50.0
    var offRouteMinimumMeters = 30.0
    /// A detour is asked for only after this long off the route...
    var minimumOffRouteSeconds: TimeInterval = 8
    /// ...after moving at least this far since leaving it...
    var minimumDisplacementMeters = 25.0
    /// ...while still at least this far from the expected part of the route.
    var requestCrossTrackMinimumMeters = 40.0
    var maximumFixAgeSeconds: TimeInterval = 10
    var cooldownSeconds: TimeInterval = 15
    var backoffSeconds: [TimeInterval] = [15, 30, 60, 120]
    /// One rejoin candidate per request: ahead, nearest, further, leave point.
    var maximumRequestsPerEpisode = 4
    /// Travel that starts a fresh set of candidates after they ran out.
    var episodeResetDistanceMeters = 250.0
    var minimumLookaheadMeters = 100.0
    var maximumLookaheadMeters = 400.0
    var furtherCandidateMeters = 1_000.0
    /// Automatic rejoin never skips more than this much of the route.
    var maximumSkipMeters = 5_000.0
    var passTieToleranceMeters = 20.0
    var rejoinBehindToleranceMeters = 20.0
    var minimumRejoinSeparationMeters = 15.0
    var confirmationFixes = 3
    var slowConfirmationFixes = 5
    var confirmationProgressMeters = 15.0
    var headingToleranceDegrees = 60.0
    var headingMinimumSpeedMetersPerSecond = 2.0
    var farConfirmationFixes = 5
    var farConfirmationProgressMeters = 100.0
    var maximumContinuityJumpMeters = 150.0
    var maximumStartOffsetMeters = 75.0
    var maximumEndOffsetMeters = 60.0
    var minimumMaximumDetourMeters = 3_000.0
    var maximumDetourLengthFactor = 4.0
    var requestMotionCancelMeters = 100.0

    static let production = SavedRouteDetourPolicyV1()

    func offRouteThreshold(accuracy: Double) -> Double {
        max(offRouteMinimumMeters, max(accuracy, 0) * 2)
    }

    func backoff(afterFailures failures: Int) -> TimeInterval {
        guard !backoffSeconds.isEmpty else { return cooldownSeconds }
        return backoffSeconds[min(max(failures - 1, 0), backoffSeconds.count - 1)]
    }
}

/// The saved route as distances along its geometry, with its planned stops.
/// Distances use the same unscaled haversine axis as `NavigationRuntimeV1`.
nonisolated struct SavedRouteGeometryV1: Equatable {
    /// Create a Route marks each intermediate stop with this instruction on a
    /// straight step (`MultiStopRouteStitcher.arrivalInstruction`, pinned by
    /// a test). Named GPX points are cues ("Continue to …"), not stops.
    static let stopInstructionPrefix = "Arrive at "

    let route: NavigationRouteV1
    let cumulative: [Double]
    /// Distances of intermediate planned stops, ascending.
    let stopDistances: [Double]

    init(route: NavigationRouteV1) {
        self.route = route
        cumulative = NavigationGeometryV1.cumulativeDistances(for: route.points)
        let stops = route.steps.dropLast().filter {
            $0.maneuver == .straight && $0.instruction.hasPrefix(Self.stopInstructionPrefix)
        }
        let cumulative = self.cumulative
        stopDistances = stops.map { cumulative[$0.geometryEndIndex] }.sorted()
    }

    var totalMeters: Double { cumulative.last ?? 0 }

    /// The first stop the rider has not passed, given confirmed progress.
    func nextUnvisitedStop(after progress: Double) -> Double? {
        stopDistances.first { $0 > progress + 0.5 }
    }

    func stops(between lower: Double, and upper: Double) -> [Double] {
        stopDistances.filter { $0 > lower + 0.5 && $0 < upper - 0.5 }
    }

    func stopLabel(at distance: Double) -> String? {
        guard let step = route.steps.dropLast().first(where: {
            abs(cumulative[$0.geometryEndIndex] - distance) < 0.5 &&
                $0.instruction.hasPrefix(Self.stopInstructionPrefix)
        }) else { return nil }
        return String(step.instruction.dropFirst(Self.stopInstructionPrefix.count))
    }

    /// Index of the segment that contains `distance`.
    func segmentIndex(atDistance distance: Double) -> Int {
        guard cumulative.count > 1 else { return 0 }
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid - 1 }
        }
        return min(low, cumulative.count - 2)
    }

    func coordinate(atDistance distance: Double) -> RouteCoordinateV1 {
        let points = route.points
        guard points.count > 1 else { return points[0] }
        let clamped = min(max(distance, 0), totalMeters)
        let index = segmentIndex(atDistance: clamped)
        let length = cumulative[index + 1] - cumulative[index]
        guard length > 0 else { return points[index] }
        let fraction = (clamped - cumulative[index]) / length
        let start = points[index]
        let end = points[index + 1]
        return RouteCoordinateV1(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    /// Initial bearing of a segment in degrees clockwise from north.
    func bearing(ofSegment index: Int) -> Double? {
        let points = route.points
        guard points.indices.contains(index), points.indices.contains(index + 1),
              points[index] != points[index + 1] else { return nil }
        return Self.bearing(from: points[index], to: points[index + 1])
    }

    static func bearing(from start: RouteCoordinateV1, to end: RouteCoordinateV1) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let difference = abs((a - b).truncatingRemainder(dividingBy: 360))
        return difference > 180 ? 360 - difference : difference
    }

    /// The closest point of each pass: projections whose distance is a local
    /// minimum along the route. Neighbouring segments of one street clamp to
    /// shared vertices and must not count as separate passes.
    static func passMinima(
        _ projections: [NavigationGeometryV1.Projection]
    ) -> [NavigationGeometryV1.Projection] {
        let sorted = projections.sorted { $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters }
        return sorted.indices.filter { index in
            let distance = sorted[index].crossTrackDistanceMeters
            let previous = index > 0 ? sorted[index - 1].crossTrackDistanceMeters : .infinity
            let next = index + 1 < sorted.count ? sorted[index + 1].crossTrackDistanceMeters : .infinity
            return distance <= previous && distance <= next
        }.map { sorted[$0] }
    }

    /// Projections of `target` onto the part of the route between `lower` and
    /// `upper`, plus the two window ends, so a window edge is a candidate too.
    func projections(
        of target: RouteCoordinateV1,
        within lower: Double,
        _ upper: Double
    ) -> [NavigationGeometryV1.Projection] {
        let low = max(0, min(lower, totalMeters))
        let high = max(low, min(upper, totalMeters))
        let first = segmentIndex(atDistance: low)
        let last = segmentIndex(atDistance: high)
        var result = NavigationGeometryV1.projections(
            of: target,
            onto: route.points,
            cumulativeDistances: cumulative,
            segmentRange: first..<(last + 1)
        ).filter { $0.distanceAlongRouteMeters >= low - 0.01 && $0.distanceAlongRouteMeters <= high + 0.01 }
        for edge in [low, high] {
            let index = segmentIndex(atDistance: edge)
            let length = cumulative[min(index + 1, cumulative.count - 1)] - cumulative[index]
            result.append(NavigationGeometryV1.Projection(
                segmentIndex: index,
                fraction: length > 0 ? (edge - cumulative[index]) / length : 0,
                crossTrackDistanceMeters: NavigationGeometryV1.distance(
                    from: target, to: coordinate(atDistance: edge)
                ),
                distanceAlongRouteMeters: edge
            ))
        }
        return result
    }
}

/// One point on the saved route a detour aims for.
nonisolated struct SavedRouteRejoinTargetV1: Equatable, Sendable {
    nonisolated enum Kind: Int, Equatable, Sendable {
        case ahead = 0
        case nearest = 1
        case further = 2
        case leavePoint = 3
    }

    let kind: Kind
    let distanceAlongMeters: Double
    let coordinate: RouteCoordinateV1
    /// Confirmed progress when the rider left the route.
    let windowLowerMeters: Double
    /// The farthest automatic rejoin: next unvisited stop, skip limit or finish.
    let windowUpperMeters: Double
}

nonisolated enum SavedRouteRejoinPlannerV1 {
    struct Window: Equatable {
        let lower: Double
        let upper: Double
        let isCappedByStop: Bool
    }

    static func window(
        confirmedProgress: Double,
        geometry: SavedRouteGeometryV1,
        policy: SavedRouteDetourPolicyV1
    ) -> Window {
        let lower = min(max(confirmedProgress, 0), geometry.totalMeters)
        let skip = min(lower + policy.maximumSkipMeters, geometry.totalMeters)
        if let stop = geometry.nextUnvisitedStop(after: lower), stop <= skip {
            return Window(lower: lower, upper: stop, isCappedByStop: true)
        }
        return Window(lower: lower, upper: skip, isCappedByStop: false)
    }

    /// The window point nearest the rider; within the tie tolerance the
    /// earliest pass wins, so an out-and-back street skips nothing.
    static func nearest(
        to rider: RouteCoordinateV1,
        geometry: SavedRouteGeometryV1,
        window: Window,
        policy: SavedRouteDetourPolicyV1
    ) -> NavigationGeometryV1.Projection? {
        let candidates = SavedRouteGeometryV1.passMinima(
            geometry.projections(of: rider, within: window.lower, window.upper)
        )
        guard let best = candidates.min(by: { $0.crossTrackDistanceMeters < $1.crossTrackDistanceMeters }) else {
            return nil
        }
        let closest = best.crossTrackDistanceMeters
        // Another pass ties only when it is nearly as close and genuinely
        // elsewhere along the route, not part of the same broad stretch.
        let ties = candidates.filter {
            $0.crossTrackDistanceMeters <= closest + policy.passTieToleranceMeters &&
                abs($0.distanceAlongRouteMeters - best.distanceAlongRouteMeters) >
                max(closest, policy.passTieToleranceMeters)
        }
        return ([best] + ties).min { $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters }
    }

    /// The rejoin point for the given attempt of an episode, skipping
    /// candidates too close to the rider to route to.
    static func target(
        for rider: RouteCoordinateV1,
        attempt: Int,
        confirmedProgress: Double,
        geometry: SavedRouteGeometryV1,
        policy: SavedRouteDetourPolicyV1
    ) -> SavedRouteRejoinTargetV1? {
        let window = window(confirmedProgress: confirmedProgress, geometry: geometry, policy: policy)
        guard let nearest = nearest(to: rider, geometry: geometry, window: window, policy: policy) else {
            return nil
        }
        var kindIndex = attempt
        while let kind = SavedRouteRejoinTargetV1.Kind(rawValue: kindIndex) {
            let along: Double
            switch kind {
            case .ahead:
                let lookahead = min(
                    max(nearest.crossTrackDistanceMeters, policy.minimumLookaheadMeters),
                    policy.maximumLookaheadMeters
                )
                along = min(nearest.distanceAlongRouteMeters + lookahead, window.upper)
            case .nearest:
                along = nearest.distanceAlongRouteMeters
            case .further:
                along = min(nearest.distanceAlongRouteMeters + policy.furtherCandidateMeters, window.upper)
            case .leavePoint:
                along = window.lower
            }
            let coordinate = geometry.coordinate(atDistance: along)
            if NavigationGeometryV1.distance(from: rider, to: coordinate) >= policy.minimumRejoinSeparationMeters {
                return SavedRouteRejoinTargetV1(
                    kind: kind,
                    distanceAlongMeters: along,
                    coordinate: coordinate,
                    windowLowerMeters: window.lower,
                    windowUpperMeters: window.upper
                )
            }
            kindIndex += 1
        }
        return nil
    }
}

/// A confirmed return to the saved route.
nonisolated struct SavedRouteRejoinV1: Equatable, Sendable {
    let distanceAlongMeters: Double
    /// Rejoined beyond the automatic window (past a stop or the skip limit).
    let isBeyondWindow: Bool
    /// Planned stops between the leave point and the rejoin point.
    let skippedStopDistances: [Double]
}

/// Confirms a rejoin only from consecutive accurate fixes that lie on the
/// route, move forward along it and, when moving, head along it. There is no
/// proximity shortcut: being close to the rejoin point or the destination is
/// never enough, and crossing the route sideways or riding it the wrong way
/// never confirms.
nonisolated struct SavedRouteRejoinTrackerV1: Equatable {
    private var alongs: [Double] = []
    private var sawSlowFix = false

    mutating func reset() {
        alongs.removeAll()
        sawSlowFix = false
    }

    var matchedFixCount: Int { alongs.count }

    mutating func observe(
        _ sample: NavigationLocationSampleV1,
        geometry: SavedRouteGeometryV1,
        confirmedProgress: Double,
        policy: SavedRouteDetourPolicyV1
    ) -> SavedRouteRejoinV1? {
        let accuracy = sample.horizontalAccuracyMeters
        guard accuracy >= 0, accuracy <= policy.maximumAccuracyMeters else { return nil }
        let window = SavedRouteRejoinPlannerV1.window(
            confirmedProgress: confirmedProgress, geometry: geometry, policy: policy
        )
        let threshold = policy.offRouteThreshold(accuracy: accuracy)
        let lowest = max(confirmedProgress - policy.rejoinBehindToleranceMeters, 0)
        let onRoute = SavedRouteGeometryV1.passMinima(NavigationGeometryV1.projections(
            of: sample.coordinate,
            onto: geometry.route.points,
            cumulativeDistances: geometry.cumulative,
            segmentRange: geometry.segmentIndex(atDistance: lowest)..<max(geometry.route.points.count - 1, 1)
        )).filter {
            $0.crossTrackDistanceMeters <= threshold && $0.distanceAlongRouteMeters >= lowest
        }
        guard !onRoute.isEmpty else {
            reset()
            return nil
        }
        let chosen: NavigationGeometryV1.Projection
        if let previous = alongs.last {
            chosen = onRoute.min {
                abs($0.distanceAlongRouteMeters - previous) < abs($1.distanceAlongRouteMeters - previous)
            }!
        } else {
            chosen = onRoute.filter { $0.distanceAlongRouteMeters <= window.upper + 0.5 }
                .min { $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters }
                ?? onRoute.min { $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters }!
        }
        let along = chosen.distanceAlongRouteMeters
        let moving = sample.speedMetersPerSecond >= policy.headingMinimumSpeedMetersPerSecond
        if moving {
            guard sample.courseDegrees >= 0, sample.courseDegrees < 360,
                  let bearing = geometry.bearing(ofSegment: chosen.segmentIndex),
                  SavedRouteGeometryV1.angleDifference(sample.courseDegrees, bearing) <=
                    policy.headingToleranceDegrees else {
                reset()
                return nil
            }
        } else {
            sawSlowFix = true
        }
        if let previous = alongs.last,
           along < previous - 2 || along - previous > policy.maximumContinuityJumpMeters {
            // Backwards along the route, or a jump to another pass.
            reset()
        }
        alongs.append(along)
        let beyond = along > window.upper + 0.5
        let required = beyond
            ? policy.farConfirmationFixes
            : (sawSlowFix ? policy.slowConfirmationFixes : policy.confirmationFixes)
        let progressRequired = beyond
            ? policy.farConfirmationProgressMeters
            : policy.confirmationProgressMeters
        guard alongs.count >= required,
              let first = alongs.first,
              along - first >= progressRequired else { return nil }
        let rejoin = SavedRouteRejoinV1(
            distanceAlongMeters: along,
            isBeyondWindow: beyond,
            skippedStopDistances: geometry.stops(between: confirmedProgress, and: along)
        )
        reset()
        return rejoin
    }
}

nonisolated enum SavedRouteDetourUnavailableReasonV1: String, Equatable, Sendable {
    case offline
    case noBicycleRoute
    case serviceError
}

nonisolated enum SavedRouteDetourPhaseV1: Equatable, Sendable {
    case onRoute
    /// Off the route, waiting until a detour request is warranted.
    case offRoute
    case requesting
    case following
    case unavailable(SavedRouteDetourUnavailableReasonV1)
}

nonisolated struct SavedRouteDetourRequestV1: Equatable, Sendable {
    let id: UInt64
    let episode: UInt32
    let origin: RouteCoordinateV1
    let originCourseDegrees: Double?
    let target: SavedRouteRejoinTargetV1
    let issuedAt: Date
}

nonisolated enum SavedRouteDetourEffectV1: Equatable {
    case requestDetour(SavedRouteDetourRequestV1)
    case cancelRequest(UInt64)
    /// Guide along this route (from the rider to the rejoin point).
    case startDetour(NavigationRouteV1)
    case endDetour
    /// Continue the saved route's runtime at this confirmed point.
    case resumeSavedRoute(SavedRouteRejoinV1)
}

/// Drives the detour lifecycle for one saved-route ride.
nonisolated struct SavedRouteDetourEngineV1 {
    let policy: SavedRouteDetourPolicyV1
    let geometry: SavedRouteGeometryV1

    private(set) var phase: SavedRouteDetourPhaseV1 = .onRoute
    private(set) var request: SavedRouteDetourRequestV1?
    private(set) var detour: NavigationRouteV1?
    private(set) var detourTarget: SavedRouteRejoinTargetV1?
    /// Distance along the saved route at the last on-route fix.
    private(set) var confirmedProgressMeters: Double = 0
    private(set) var episode: UInt32 = 0
    private(set) var networkAvailable = true

    private var requestCounter: UInt64 = 0
    private var offRouteSince: Date?
    private var offRouteOrigin: RouteCoordinateV1?
    private var attempt = 0
    private var requestsThisEpisode = 0
    private var lastRequestOrigin: RouteCoordinateV1?
    private var nextAllowedAt: Date = .distantPast
    private var serviceFailures = 0
    private var pendingTarget: SavedRouteRejoinTargetV1?
    private var tracker = SavedRouteRejoinTrackerV1()

    init(route: NavigationRouteV1, policy: SavedRouteDetourPolicyV1 = .production) {
        self.policy = policy
        geometry = SavedRouteGeometryV1(route: route)
    }

    /// While true the host must not feed fixes to the saved route's runtime.
    var isHoldingSavedRoute: Bool { phase != .onRoute }

    var routeID: UUID { geometry.route.id }

    /// One location fix. `savedRouteSnapshot` is the saved runtime's answer
    /// for this fix while it is not held; `detourSnapshot` the detour
    /// runtime's answer while following a detour.
    mutating func observe(
        _ sample: NavigationLocationSampleV1,
        savedRouteSnapshot: NavigationSnapshotV1?,
        detourSnapshot: NavigationSnapshotV1?,
        now: Date
    ) -> [SavedRouteDetourEffectV1] {
        if phase == .onRoute {
            guard let snapshot = savedRouteSnapshot, snapshot.routeID == geometry.route.id else { return [] }
            if snapshot.offRouteDistanceMeters == nil {
                if let along = snapshot.distanceAlongGeometryMeters { confirmedProgressMeters = along }
                return []
            }
            enterOffRoute(at: sample, episodeStart: true)
            return []
        }

        if let rejoin = tracker.observe(
            sample, geometry: geometry, confirmedProgress: confirmedProgressMeters, policy: policy
        ) {
            var effects: [SavedRouteDetourEffectV1] = []
            if let request { effects.append(.cancelRequest(request.id)) }
            if detour != nil { effects.append(.endDetour) }
            request = nil
            detour = nil
            detourTarget = nil
            pendingTarget = nil
            phase = .onRoute
            confirmedProgressMeters = rejoin.distanceAlongMeters
            serviceFailures = 0
            effects.append(.resumeSavedRoute(rejoin))
            return effects
        }

        switch phase {
        case .following:
            if let detourSnapshot, detourSnapshot.offRouteDistanceMeters != nil {
                // The rider left the detour: plan again from here.
                detour = nil
                detourTarget = nil
                enterOffRoute(at: sample, episodeStart: false)
                return [.endDetour]
            }
            return []
        case .requesting:
            guard let request,
                  NavigationGeometryV1.distance(from: request.origin, to: sample.coordinate) >
                    policy.requestMotionCancelMeters else { return [] }
            self.request = nil
            pendingTarget = nil
            phase = .offRoute
            nextAllowedAt = now
            return [.cancelRequest(request.id)] + issueIfWarranted(sample, now: now)
        case .offRoute, .unavailable:
            return issueIfWarranted(sample, now: now)
        case .onRoute:
            return []
        }
    }

    /// The provider's answer to `requestID`. Answers for any other request
    /// (stale, cancelled, superseded) are ignored.
    mutating func complete(
        requestID: UInt64,
        outcome: BicycleDetourOutcomeV1,
        latestSample: NavigationLocationSampleV1,
        now: Date
    ) -> [SavedRouteDetourEffectV1] {
        guard let request, request.id == requestID else { return [] }
        self.request = nil
        let target = pendingTarget ?? request.target
        pendingTarget = nil
        switch outcome {
        case .route(let route):
            guard let prepared = validatedDetour(route, target: target, latestSample: latestSample) else {
                return noRoute(now: now)
            }
            serviceFailures = 0
            detour = prepared
            detourTarget = target
            phase = .following
            return [.startDetour(prepared)]
        case .noBicycleRoute:
            return noRoute(now: now)
        case .unavailable(let reason, let retryAfterSeconds):
            serviceFailures += 1
            let backoff = max(policy.backoff(afterFailures: serviceFailures),
                              TimeInterval(retryAfterSeconds ?? 0))
            nextAllowedAt = now.addingTimeInterval(backoff)
            phase = .unavailable(reason == .offline ? .offline : .serviceError)
            return []
        case .cancelled:
            phase = .offRoute
            return []
        }
    }

    /// Path changes from the network monitor. Coming back online while still
    /// off the route asks again immediately.
    mutating func networkChanged(
        available: Bool,
        latestSample: NavigationLocationSampleV1?,
        now: Date
    ) -> [SavedRouteDetourEffectV1] {
        networkAvailable = available
        guard available else {
            if phase == .offRoute { phase = .unavailable(.offline) }
            return []
        }
        guard phase == .unavailable(.offline) else { return [] }
        phase = .offRoute
        nextAllowedAt = now
        guard let latestSample else { return [] }
        return issueIfWarranted(latestSample, now: now)
    }

    // MARK: - Private

    private mutating func enterOffRoute(at sample: NavigationLocationSampleV1, episodeStart: Bool) {
        phase = networkAvailable ? .offRoute : .unavailable(.offline)
        offRouteSince = sample.timestamp
        offRouteOrigin = sample.coordinate
        attempt = 0
        requestsThisEpisode = 0
        tracker.reset()
        if episodeStart {
            episode &+= 1
            serviceFailures = 0
        }
    }

    private mutating func noRoute(now: Date) -> [SavedRouteDetourEffectV1] {
        attempt += 1
        phase = .unavailable(.noBicycleRoute)
        // The next candidate is a different point; it may be asked at once.
        nextAllowedAt = now
        return []
    }

    private mutating func issueIfWarranted(
        _ sample: NavigationLocationSampleV1,
        now: Date
    ) -> [SavedRouteDetourEffectV1] {
        guard request == nil, detour == nil else { return [] }
        let age = now.timeIntervalSince(sample.timestamp)
        guard age >= -1, age <= policy.maximumFixAgeSeconds,
              sample.horizontalAccuracyMeters >= 0,
              sample.horizontalAccuracyMeters <= policy.maximumAccuracyMeters else { return [] }
        guard networkAvailable else {
            phase = .unavailable(.offline)
            return []
        }
        guard let since = offRouteSince, let origin = offRouteOrigin,
              sample.timestamp.timeIntervalSince(since) >= policy.minimumOffRouteSeconds,
              NavigationGeometryV1.distance(from: origin, to: sample.coordinate) >=
                policy.minimumDisplacementMeters,
              now >= nextAllowedAt else { return [] }
        let window = SavedRouteRejoinPlannerV1.window(
            confirmedProgress: confirmedProgressMeters, geometry: geometry, policy: policy
        )
        guard let nearest = SavedRouteRejoinPlannerV1.nearest(
            to: sample.coordinate, geometry: geometry, window: window, policy: policy
        ), nearest.crossTrackDistanceMeters >= max(
            policy.requestCrossTrackMinimumMeters,
            sample.horizontalAccuracyMeters * 2
        ) else { return [] }
        if requestsThisEpisode >= policy.maximumRequestsPerEpisode || attempt > SavedRouteRejoinTargetV1.Kind.leavePoint.rawValue {
            guard let last = lastRequestOrigin,
                  NavigationGeometryV1.distance(from: last, to: sample.coordinate) >=
                    policy.episodeResetDistanceMeters else {
                if case .unavailable = phase {} else { phase = .unavailable(.noBicycleRoute) }
                return []
            }
            attempt = 0
            requestsThisEpisode = 0
        }
        guard let target = SavedRouteRejoinPlannerV1.target(
            for: sample.coordinate,
            attempt: attempt,
            confirmedProgress: confirmedProgressMeters,
            geometry: geometry,
            policy: policy
        ) else {
            phase = .unavailable(.noBicycleRoute)
            return []
        }
        attempt = target.kind.rawValue
        requestCounter &+= 1
        requestsThisEpisode += 1
        let course = sample.speedMetersPerSecond >= policy.headingMinimumSpeedMetersPerSecond &&
            sample.courseDegrees >= 0 && sample.courseDegrees < 360 ? sample.courseDegrees : nil
        let issued = SavedRouteDetourRequestV1(
            id: requestCounter,
            episode: episode,
            origin: sample.coordinate,
            originCourseDegrees: course,
            target: target,
            issuedAt: now
        )
        request = issued
        pendingTarget = target
        lastRequestOrigin = sample.coordinate
        nextAllowedAt = now.addingTimeInterval(policy.cooldownSeconds)
        phase = .requesting
        return [.requestDetour(issued)]
    }

    /// Accepts a provider route only when it starts at the rider, ends on the
    /// expected part of the saved route and is not absurdly long; the last
    /// step becomes "Rejoin saved route", never an arrival.
    private func validatedDetour(
        _ route: NavigationRouteV1,
        target: SavedRouteRejoinTargetV1,
        latestSample: NavigationLocationSampleV1
    ) -> NavigationRouteV1? {
        guard route.transportType == .cycling, (try? route.validate()) != nil,
              let first = route.points.first, let last = route.points.last,
              NavigationGeometryV1.distance(from: first, to: latestSample.coordinate) <=
                policy.maximumStartOffsetMeters else { return nil }
        let ends = geometry.projections(
            of: last,
            within: target.windowLowerMeters - policy.rejoinBehindToleranceMeters,
            target.windowUpperMeters
        )
        guard let end = ends.min(by: { $0.crossTrackDistanceMeters < $1.crossTrackDistanceMeters }),
              end.crossTrackDistanceMeters <= policy.maximumEndOffsetMeters else { return nil }
        let straight = NavigationGeometryV1.distance(from: latestSample.coordinate, to: target.coordinate)
        let measured = NavigationGeometryV1.cumulativeDistances(for: route.points).last ?? 0
        guard measured <= max(policy.minimumMaximumDetourMeters, straight * policy.maximumDetourLengthFactor) else {
            return nil
        }
        return SavedRouteDetourRouteV1.prepared(
            route,
            savedRouteBearing: geometry.bearing(ofSegment: end.segmentIndex)
        )
    }
}

/// Final shaping of a detour route shared by every provider.
nonisolated enum SavedRouteDetourRouteV1 {
    static let rejoinInstruction = "Rejoin saved route"
    static let destinationLabel = "Saved route"

    /// Replaces the provider's arrival with a rejoin step whose turn follows
    /// the angle between the detour's last segment and the saved route.
    static func prepared(_ route: NavigationRouteV1, savedRouteBearing: Double?) -> NavigationRouteV1 {
        guard var last = route.steps.last else { return route }
        let maneuver: ManeuverV1 = {
            let points = route.points
            guard let savedRouteBearing, points.count >= 2 else { return .straight }
            var index = points.count - 2
            while index > 0, points[index] == points[points.count - 1] { index -= 1 }
            guard points[index] != points[points.count - 1] else { return .straight }
            let incoming = SavedRouteGeometryV1.bearing(from: points[index], to: points[points.count - 1])
            var turn = (savedRouteBearing - incoming).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn -= 360 }
            if turn < -180 { turn += 360 }
            switch turn {
            case -30...30: return .straight
            case 30...150: return .right
            case -150 ... -30: return .left
            default: return .uTurn
            }
        }()
        last = NavigationRouteStepV1(
            id: last.id,
            geometryStartIndex: last.geometryStartIndex,
            geometryEndIndex: last.geometryEndIndex,
            instruction: rejoinInstruction,
            maneuver: maneuver,
            distanceMeters: last.distanceMeters
        )
        var steps = route.steps
        steps[steps.count - 1] = last
        // Never let an intermediate provider arrival end navigation either.
        steps = steps.map { step in
            guard step.maneuver == .arrive, step.id != last.id else { return step }
            return NavigationRouteStepV1(
                id: step.id, geometryStartIndex: step.geometryStartIndex, geometryEndIndex: step.geometryEndIndex,
                instruction: step.instruction, maneuver: .straight, distanceMeters: step.distanceMeters
            )
        }
        return NavigationRouteV1(
            id: route.id,
            revision: route.revision,
            provider: route.provider,
            sourceReference: route.sourceReference,
            localeIdentifier: route.localeIdentifier,
            transportType: route.transportType,
            source: route.source,
            destination: RouteEndpointV1(coordinate: route.destination.coordinate, label: destinationLabel),
            bounds: route.bounds,
            distanceMeters: route.distanceMeters,
            expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
            name: route.name,
            points: route.points,
            steps: steps,
            normalizationVersion: route.normalizationVersion
        )
    }
}
