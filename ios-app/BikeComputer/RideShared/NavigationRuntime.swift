import Foundation

struct NavigationLocationSampleV1: Equatable {
    let coordinate: RouteCoordinateV1
    let horizontalAccuracyMeters: Double
    let courseDegrees: Double
    let speedMetersPerSecond: Double
    let altitudeMeters: Double
    let timestamp: Date
}

enum NavigationModeV1: String, Codable, Equatable {
    case offline
    case online
    case onlineUsingCachedRoute
}

struct NavigationSnapshotV1: Equatable {
    let navigationGeneration: UInt32
    let routeID: UUID
    let revision: UInt32
    let contentHash: String?
    let currentStepIndex: Int
    let maneuver: ManeuverV1
    let instruction: String
    let distanceToManeuverMeters: Double
    let routeRemainingDistanceMeters: Double
    let expectedArrival: Date?
    let offRouteDistanceMeters: Double?
    let mode: NavigationModeV1
    let routeWindow: Data
}

enum NavigationRuntimeError: Error, Equatable {
    case invalidLocation
    case invalidCheckpoint
    case noActiveRoute
    case noProjectableGeometry
}

struct NavigationStartAssessmentV1: Equatable {
    static let warningDistanceMeters = 250.0

    let distanceToRouteStartMeters: Double
    let requiresConfirmation: Bool
}

enum NavigationInitialStepStrategyV1: Equatable {
    case first
    case nearestUnambiguous
    case checkpoint(stepIndex: Int)
}

struct NavigationRuntimeV1 {
    private(set) var route: NavigationRouteV1?
    private(set) var snapshot: NavigationSnapshotV1?
    private(set) var generation: UInt32 = 0

    private var contentHash: String?
    private var mode: NavigationModeV1 = .offline
    private var initialStepStrategy: NavigationInitialStepStrategyV1 = .nearestUnambiguous
    private var cumulativeDistances: [Double] = []
    private var lastDistanceAlongGeometry: Double?
    private var lastSegmentIndex: Int?
    private var currentStepIndex = 0
    private var consecutiveOffRouteSamples = 0
    private var isOffRoute = false
    private var lastProcessedSample: NavigationLocationSampleV1?

    mutating func start(
        route: NavigationRouteV1,
        contentHash: String? = nil,
        mode: NavigationModeV1,
        initialStepStrategy: NavigationInitialStepStrategyV1 = .nearestUnambiguous,
        initialLocation: NavigationLocationSampleV1? = nil
    ) throws -> NavigationStartAssessmentV1 {
        var candidate = self
        let assessment = try candidate.configureStart(
            route: route,
            contentHash: contentHash,
            mode: mode,
            initialStepStrategy: initialStepStrategy,
            initialLocation: initialLocation
        )
        self = candidate
        return assessment
    }

    private mutating func configureStart(
        route: NavigationRouteV1,
        contentHash: String?,
        mode: NavigationModeV1,
        initialStepStrategy: NavigationInitialStepStrategyV1,
        initialLocation: NavigationLocationSampleV1?
    ) throws -> NavigationStartAssessmentV1 {
        try route.validate()
        if case .checkpoint(let stepIndex) = initialStepStrategy {
            guard route.steps.indices.contains(stepIndex) else {
                throw NavigationRuntimeError.invalidCheckpoint
            }
        }
        self.route = route
        self.contentHash = contentHash
        self.mode = mode
        self.initialStepStrategy = initialStepStrategy
        cumulativeDistances = NavigationGeometryV1.cumulativeDistances(for: route.points)
        lastDistanceAlongGeometry = nil
        lastSegmentIndex = nil
        currentStepIndex = 0
        consecutiveOffRouteSamples = 0
        isOffRoute = false
        lastProcessedSample = nil
        snapshot = nil
        advanceGeneration()

        let assessment: NavigationStartAssessmentV1
        if let initialLocation {
            guard initialLocation.coordinate.isValid else {
                throw NavigationRuntimeError.invalidLocation
            }
            let distance = NavigationGeometryV1.distance(
                from: initialLocation.coordinate,
                to: route.points[0]
            )
            assessment = NavigationStartAssessmentV1(
                distanceToRouteStartMeters: distance,
                requiresConfirmation: distance > NavigationStartAssessmentV1.warningDistanceMeters
            )
            _ = try process(initialLocation)
        } else {
            assessment = NavigationStartAssessmentV1(
                distanceToRouteStartMeters: 0,
                requiresConfirmation: false
            )
        }
        return assessment
    }

    mutating func replaceRoute(
        _ route: NavigationRouteV1,
        contentHash: String? = nil,
        mode: NavigationModeV1,
        currentLocation: NavigationLocationSampleV1
    ) throws -> NavigationSnapshotV1 {
        var candidate = self
        _ = try candidate.configureStart(
            route: route,
            contentHash: contentHash,
            mode: mode,
            initialStepStrategy: .nearestUnambiguous,
            initialLocation: nil
        )
        let replacement = try candidate.process(currentLocation)
        self = candidate
        return replacement
    }

    mutating func stop() {
        route = nil
        snapshot = nil
        contentHash = nil
        cumulativeDistances = []
        lastDistanceAlongGeometry = nil
        lastSegmentIndex = nil
        currentStepIndex = 0
        consecutiveOffRouteSamples = 0
        isOffRoute = false
        lastProcessedSample = nil
        advanceGeneration()
    }

    mutating func setMode(_ mode: NavigationModeV1) {
        self.mode = mode
        if let snapshot {
            self.snapshot = NavigationSnapshotV1(
                navigationGeneration: snapshot.navigationGeneration,
                routeID: snapshot.routeID,
                revision: snapshot.revision,
                contentHash: snapshot.contentHash,
                currentStepIndex: snapshot.currentStepIndex,
                maneuver: snapshot.maneuver,
                instruction: snapshot.instruction,
                distanceToManeuverMeters: snapshot.distanceToManeuverMeters,
                routeRemainingDistanceMeters: snapshot.routeRemainingDistanceMeters,
                expectedArrival: snapshot.expectedArrival,
                offRouteDistanceMeters: snapshot.offRouteDistanceMeters,
                mode: mode,
                routeWindow: snapshot.routeWindow
            )
        }
    }

    mutating func process(
        _ sample: NavigationLocationSampleV1
    ) throws -> NavigationSnapshotV1 {
        guard sample.coordinate.isValid,
              sample.horizontalAccuracyMeters.isFinite,
              sample.courseDegrees.isFinite,
              sample.speedMetersPerSecond.isFinite,
              sample.altitudeMeters.isFinite,
              sample.timestamp.timeIntervalSince1970.isFinite else {
            throw NavigationRuntimeError.invalidLocation
        }
        guard let route else { throw NavigationRuntimeError.noActiveRoute }
        if sample == lastProcessedSample, let snapshot {
            return snapshot
        }

        let projections = candidateProjections(for: sample, route: route)
        guard let closestDistance = projections.map(\.crossTrackDistanceMeters).min(),
              !projections.isEmpty else {
            throw NavigationRuntimeError.noProjectableGeometry
        }

        let accuracy = sample.horizontalAccuracyMeters >= 0
            ? sample.horizontalAccuracyMeters
            : 0
        // Treat projections inside the same 20 m maneuver-arrival band as
        // ambiguous. Continuity then wins on loopbacks, while `.first` keeps a
        // new ride from starting near the end of its first curved maneuver.
        let ambiguityTolerance = max(accuracy, 20)
        let plausible = projections.filter {
            $0.crossTrackDistanceMeters <= closestDistance + ambiguityTolerance
        }
        let selectedProjection = selectProjection(
            candidates: plausible.isEmpty ? projections : plausible,
            initialStrategy: lastDistanceAlongGeometry == nil
                ? initialStepStrategy
                : nil,
            route: route
        )
        guard let selectedProjection else {
            throw NavigationRuntimeError.noProjectableGeometry
        }
        lastSegmentIndex = selectedProjection.segmentIndex

        let measuredTotal = cumulativeDistances.last ?? 0
        let referenceTotal = route.distanceMeters > 0 ? route.distanceMeters : measuredTotal
        let scale = measuredTotal > 0 ? referenceTotal / measuredTotal : 1
        let isInitialProjection = lastDistanceAlongGeometry == nil
        let selectedAlongGeometry = selectedProjection.distanceAlongRouteMeters
        let distanceAlongGeometry = max(
            lastDistanceAlongGeometry ?? selectedAlongGeometry,
            selectedAlongGeometry
        )
        lastDistanceAlongGeometry = distanceAlongGeometry
        let distanceAlong = distanceAlongGeometry * scale
        if isInitialProjection {
            let projectedStep = stepIndex(
                forDistanceAlong: distanceAlong,
                route: route,
                scale: scale
            )
            switch initialStepStrategy {
            case .first:
                currentStepIndex = 0
            case .nearestUnambiguous:
                currentStepIndex = projectedStep
            case .checkpoint(let stepIndex):
                currentStepIndex = max(stepIndex, projectedStep)
            }
        } else {
            advanceStepIfReached(
                sample: sample,
                distanceAlong: distanceAlong,
                route: route,
                scale: scale
            )
        }

        updateDeviation(
            crossTrackDistance: selectedProjection.crossTrackDistanceMeters,
            horizontalAccuracy: sample.horizontalAccuracyMeters
        )

        let step = route.steps[currentStepIndex]
        let remainingDistance = max(referenceTotal - distanceAlong, 0)
        let stepStartMeasured = cumulativeDistances[step.geometryStartIndex]
        let stepEndMeasured = cumulativeDistances[step.geometryEndIndex]
        let stepMeasuredLength = max(stepEndMeasured - stepStartMeasured, 0)
        let stepProgress = min(
            max(distanceAlongGeometry - stepStartMeasured, 0),
            stepMeasuredLength
        )
        let projectedManeuverDistance: Double
        if stepMeasuredLength > 0, step.distanceMeters > 0 {
            projectedManeuverDistance = max(
                step.distanceMeters * (1 - stepProgress / stepMeasuredLength),
                0
            )
        } else {
            projectedManeuverDistance = max(
                stepEndMeasured * scale - distanceAlong,
                0
            )
        }
        let stepEndpoint = route.points[step.geometryEndIndex]
        let endpointDistance = NavigationGeometryV1.distance(
            from: sample.coordinate,
            to: stepEndpoint
        )
        let maneuverDistance = projectedManeuverDistance <= 0 && endpointDistance >= 20
            ? endpointDistance
            : projectedManeuverDistance
        let expectedArrival: Date? = {
            guard let expected = route.expectedTravelTimeSeconds,
                  referenceTotal > 0 else { return nil }
            return sample.timestamp.addingTimeInterval(
                max(expected * remainingDistance / referenceTotal, 0)
            )
        }()
        let window = NavigationGeometryV1.compressedRouteWindow(
            points: route.points,
            startingAt: NavigationGeometryV1.routeWindowStartIndex(
                for: selectedProjection
            )
        ) ?? Data()

        let next = NavigationSnapshotV1(
            navigationGeneration: generation,
            routeID: route.routeID,
            revision: route.revision,
            contentHash: contentHash,
            currentStepIndex: currentStepIndex,
            maneuver: step.maneuver,
            instruction: step.instruction,
            distanceToManeuverMeters: maneuverDistance,
            routeRemainingDistanceMeters: remainingDistance,
            expectedArrival: expectedArrival,
            offRouteDistanceMeters: isOffRoute
                ? selectedProjection.crossTrackDistanceMeters
                : nil,
            mode: mode,
            routeWindow: window
        )
        snapshot = next
        lastProcessedSample = sample
        return next
    }

    private func selectProjection(
        candidates: [NavigationGeometryV1.Projection],
        initialStrategy: NavigationInitialStepStrategyV1?,
        route: NavigationRouteV1
    ) -> NavigationGeometryV1.Projection? {
        guard let lastDistanceAlongGeometry else {
            if initialStrategy == .first {
                return candidates.min {
                    $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters
                }
            }
            if case .checkpoint(let stepIndex) = initialStrategy {
                let step = route.steps[stepIndex]
                let target = (
                    cumulativeDistances[step.geometryStartIndex] +
                    cumulativeDistances[step.geometryEndIndex]
                ) / 2
                return candidates.min {
                    abs($0.distanceAlongRouteMeters - target) <
                        abs($1.distanceAlongRouteMeters - target)
                }
            }
            let closest = candidates.map(\.crossTrackDistanceMeters).min() ?? .infinity
            return candidates
                .filter { abs($0.crossTrackDistanceMeters - closest) < 0.001 }
                .min { $0.distanceAlongRouteMeters < $1.distanceAlongRouteMeters }
        }
        return candidates.min { lhs, rhs in
            let lhsDelta = abs(lhs.distanceAlongRouteMeters - lastDistanceAlongGeometry)
            let rhsDelta = abs(rhs.distanceAlongRouteMeters - lastDistanceAlongGeometry)
            if lhsDelta == rhsDelta {
                return lhs.crossTrackDistanceMeters < rhs.crossTrackDistanceMeters
            }
            return lhsDelta < rhsDelta
        }
    }

    private func candidateProjections(
        for sample: NavigationLocationSampleV1,
        route: NavigationRouteV1
    ) -> [NavigationGeometryV1.Projection] {
        guard let lastSegmentIndex else {
            return NavigationGeometryV1.projections(
                of: sample.coordinate,
                onto: route.points,
                cumulativeDistances: cumulativeDistances
            )
        }

        let segmentCount = route.points.count - 1
        let localRange = max(lastSegmentIndex - 25, 0)..<min(
            lastSegmentIndex + 251,
            segmentCount
        )
        let local = NavigationGeometryV1.projections(
            of: sample.coordinate,
            onto: route.points,
            cumulativeDistances: cumulativeDistances,
            segmentRange: localRange
        )
        let localDistance = local.map(\.crossTrackDistanceMeters).min() ?? .infinity
        let accuracy = max(sample.horizontalAccuracyMeters, 0)
        if localDistance <= max(100, accuracy * 3) {
            return local
        }

        // A large jump can be a resumed session, a stale prior cursor, or a
        // rejoin elsewhere on a loop. Fall back to the complete route only in
        // that exceptional case instead of allocating 50k projections for
        // every ordinary Watch GPS update.
        return NavigationGeometryV1.projections(
            of: sample.coordinate,
            onto: route.points,
            cumulativeDistances: cumulativeDistances
        )
    }

    private func stepIndex(
        forDistanceAlong distanceAlong: Double,
        route: NavigationRouteV1,
        scale: Double
    ) -> Int {
        let candidate = route.steps.firstIndex { step in
            cumulativeDistances[step.geometryEndIndex] * scale + 0.5 >= distanceAlong
        } ?? (route.steps.count - 1)
        return max(currentStepIndex, candidate)
    }

    private mutating func advanceStepIfReached(
        sample: NavigationLocationSampleV1,
        distanceAlong: Double,
        route: NavigationRouteV1,
        scale: Double
    ) {
        guard currentStepIndex < route.steps.count - 1 else { return }
        let step = route.steps[currentStepIndex]
        let stepEndDistance = cumulativeDistances[step.geometryEndIndex] * scale
        let endpointDistance = NavigationGeometryV1.distance(
            from: sample.coordinate,
            to: route.points[step.geometryEndIndex]
        )
        let reachedEndpoint = endpointDistance < 20 &&
            distanceAlong >= stepEndDistance - 20
        // A delayed GPS fix can land well into the next route segment without
        // ever entering the endpoint radius. Only accept that gap when the
        // observed travel chord crossed the maneuver endpoint. Progress along
        // a later route segment alone is insufficient: on a corner it can be
        // a shortcut that intentionally needs off-route/reroute handling.
        let passedEndpointOnRoute: Bool = {
            guard distanceAlong >= stepEndDistance + 20,
                  let previousSample = lastProcessedSample else {
                return false
            }
            let observedTravel = [
                previousSample.coordinate,
                sample.coordinate
            ]
            let observedDistances = NavigationGeometryV1.cumulativeDistances(
                for: observedTravel
            )
            guard observedDistances.last ?? 0 > 0 else { return false }
            let endpointProjections = NavigationGeometryV1.projections(
                of: route.points[step.geometryEndIndex],
                onto: observedTravel,
                cumulativeDistances: observedDistances
            )
            let crossingTolerance = max(
                20,
                max(
                    previousSample.horizontalAccuracyMeters,
                    sample.horizontalAccuracyMeters
                )
            )
            return endpointProjections.contains {
                $0.crossTrackDistanceMeters <= crossingTolerance
            }
        }()
        guard reachedEndpoint || passedEndpointOnRoute else { return }
        // Never consume multiple maneuvers from one GPS fix. Loopbacks and
        // short adjacent steps can put several endpoints inside the arrival
        // radius, but each instruction must still become observable.
        currentStepIndex += 1
    }

    private mutating func updateDeviation(
        crossTrackDistance: Double,
        horizontalAccuracy: Double
    ) {
        guard horizontalAccuracy >= 0, horizontalAccuracy <= 50 else { return }
        let threshold = max(30, horizontalAccuracy * 2)
        if crossTrackDistance > threshold {
            consecutiveOffRouteSamples += 1
            if consecutiveOffRouteSamples >= 3 {
                isOffRoute = true
            }
        } else {
            consecutiveOffRouteSamples = 0
            isOffRoute = false
        }
    }

    private mutating func advanceGeneration() {
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
    }
}
