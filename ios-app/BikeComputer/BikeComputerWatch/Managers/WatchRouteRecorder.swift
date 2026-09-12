import Combine
import CoreLocation
import Foundation
import HealthKit

@MainActor
protocol WatchWorkoutRouteBuilding: AnyObject {
    func insertRouteData(_ locations: [CLLocation]) async throws
    func discard()
}

extension HKWorkoutRouteBuilder: WatchWorkoutRouteBuilding {}

@MainActor
final class WatchRouteRecorder: NSObject, ObservableObject {
    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    @Published private(set) var authorizationState: AuthorizationState
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var routeDistanceMeters: Double?
    @Published private(set) var routeDistanceCapturedAt: Date?
    @Published private(set) var routeSavingFailed = false
    private(set) var motionSampleEpoch: UInt16?
    private(set) var motionSampleSequence: UInt32 = 0

    private let locationService: WatchLocationService
    private var cancellables = Set<AnyCancellable>()
    private var routeBuilder: (any WatchWorkoutRouteBuilding)?
    private var workoutStart: Date?
    private var isWorkoutActive = false
    private var mayContainExistingRouteData = false
    private var timestampGate: WorkoutRouteTimestampGate?
    private var captureLifecycle: WorkoutRouteCaptureLifecycle?
    private var lastObservationAt: Date?
    private var distanceAccumulator: WorkoutRouteDistanceAccumulator?
    private var lastDistanceLocation: CLLocation?
    private var routeQueue = WorkoutRouteBatchQueue<CLLocation>()
    private var flushTask: Task<Void, Never>?
    private var onLocationUpdate: (() -> Void)?
    private var routeGeneration = WorkoutRouteGenerationGate()

    override convenience init() {
        self.init(locationService: WatchLocationService())
    }

    init(locationService: WatchLocationService) {
        self.locationService = locationService
        self.authorizationState = locationService.authorizationState
        super.init()
        locationService.$authorizationState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.authorizationState = state
            }
            .store(in: &cancellables)
    }

    func requestAuthorizationIfNeeded() {
        locationService.requestAuthorizationIfNeeded()
    }

    func begin(
        routeBuilder: (any WatchWorkoutRouteBuilding)?,
        startDate: Date,
        motionSampleEpoch: UInt16? = nil,
        mayContainExistingRouteData: Bool = false,
        onLocationUpdate: @escaping () -> Void
    ) {
        stopLocationUpdates()
        invalidateRouteBuilder(discard: true)
        self.routeBuilder = routeBuilder
        self.workoutStart = startDate
        self.onLocationUpdate = onLocationUpdate
        isWorkoutActive = true
        self.mayContainExistingRouteData = mayContainExistingRouteData
        distanceAccumulator = WorkoutRouteDistanceAccumulator(
            mayContainExistingRouteData: mayContainExistingRouteData
        )
        timestampGate = WorkoutRouteTimestampGate(workoutStart: startDate)
        captureLifecycle = WorkoutRouteCaptureLifecycle(startedAt: startDate)
        lastObservationAt = nil
        routeDistanceMeters = nil
        routeDistanceCapturedAt = nil
        routeQueue.reset()
        latestLocation = nil
        lastDistanceLocation = nil
        routeSavingFailed = false
        self.motionSampleEpoch = motionSampleEpoch.flatMap { $0 > 0 ? $0 : nil }
        motionSampleSequence = 0

        requestAuthorizationIfNeeded()
        startLocationUpdatesWhenAuthorized()
    }

    func setPaused(_ paused: Bool, at date: Date) {
        captureLifecycle?.record(paused: paused, at: date)
    }

    func stopLocationUpdates() {
        isWorkoutActive = false
        locationService.setConsumer(.workout, active: false)
        lastDistanceLocation = nil
        distanceAccumulator?.breakSegment()
    }

    func discardRoute() {
        stopLocationUpdates()
        invalidateRouteBuilder(discard: true)
        clearAfterFinalization()
    }

    /// Releases local route state after HealthKit reconciliation confirms that
    /// the associated workout was already saved. The finished route builder
    /// must not be discarded or finalized a second time.
    func completeAfterWorkoutAlreadySaved() {
        stopLocationUpdates()
        invalidateRouteBuilder(discard: false)
        clearAfterFinalization()
    }

    /// Flushes the associated route before its workout is finished. An
    /// associated `HKWorkoutRouteBuilder` must not call `finishRoute`; HealthKit
    /// finalizes it automatically when the workout builder is finished.
    func prepareForWorkoutFinalization() async -> WorkoutPreparedRoute {
        stopLocationUpdates()
        await flushPendingRouteLocations()

        let hasRouteBuilder = routeBuilder != nil
        let decision = WorkoutAssociatedRoutePolicy.decision(
            insertedPointCount: routeQueue.insertedPointCount,
            routeSavingFailed: routeSavingFailed,
            mayContainExistingRouteData: mayContainExistingRouteData
        )
        let distanceMeters = routeDistanceMeters
        if !decision.keepBuilderForWorkout {
            routeBuilder?.discard()
        }
        invalidateRouteBuilder(discard: false)
        clearAfterFinalization()
        return WorkoutPreparedRoute(
            routeStatus: hasRouteBuilder ? decision.routeStatus : .unavailable,
            distanceMeters: distanceMeters
        )
    }

    private func startLocationUpdatesWhenAuthorized() {
        guard isWorkoutActive else {
            locationService.setConsumer(.workout, active: false)
            return
        }
        locationService.setConsumer(
            .workout,
            active: true,
            handler: { [weak self] locations in
                self?.receiveServiceLocations(locations)
            }
        )
    }

    private func receiveServiceLocations(_ locations: [CLLocation]) {
        guard !locations.isEmpty else {
            lastDistanceLocation = nil
            latestLocation = nil
            onLocationUpdate?()
            return
        }
        receive(locations)
    }

    private func receive(_ locations: [CLLocation]) {
        guard isWorkoutActive, let workoutStart else { return }
        let now = Date()
        let accepted = locations.filter { [timestampGate] location in
            guard timestampGate?.accepts(location.timestamp) == true else {
                return false
            }
            return WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    capturedAt: location.timestamp,
                    horizontalAccuracy: location.horizontalAccuracy,
                    verticalAccuracy: location.verticalAccuracy
                ),
                workoutStart: workoutStart,
                now: now
            )
        }
        guard !accepted.isEmpty else { return }

        var routeAccepted: [CLLocation] = []
        for location in accepted.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard lastObservationAt.map({ location.timestamp > $0 }) ?? true,
                  let wasPaused = captureLifecycle?.paused(at: location.timestamp),
                  now.timeIntervalSince(location.timestamp) <= WorkoutRouteCaptureLifecycle.maximumLateness else {
                continue
            }
            lastObservationAt = location.timestamp
            // Motion qualification may use the previous observation even if
            // stationary drift broke the distance segment. It must not depend
            // on already having accepted a moving route point.
            let priorObservation = latestLocation
            let motionInterval = priorObservation.map {
                location.timestamp.timeIntervalSince($0.timestamp)
            }
            let motionDistance = priorObservation.map { location.distance(from: $0) }
            let hasBoundedMotionSegment = motionInterval.map { interval in
                interval <= WorkoutRouteCaptureLifecycle.maximumSegmentGap
                    && motionDistance.map {
                        WorkoutRouteSegmentFilter.accepts(distanceMeters: $0, interval: interval)
                    } == true
            } == true
            latestLocation = location
            if motionSampleEpoch != nil {
                if motionSampleSequence == UInt32.max {
                    // Never reuse a producer identity after sequence exhaustion.
                    motionSampleEpoch = nil
                } else {
                    motionSampleSequence += 1
                }
            }
            if let previous = lastDistanceLocation,
               location.timestamp.timeIntervalSince(previous.timestamp) > WorkoutRouteCaptureLifecycle.maximumSegmentGap {
                lastDistanceLocation = nil
                distanceAccumulator?.breakSegment()
            }
            var segmentDistanceFromPrevious: Double?
            if let previous = lastDistanceLocation {
                let segmentDistance = location.distance(from: previous)
                let interval = location.timestamp.timeIntervalSince(previous.timestamp)
                guard WorkoutRouteSegmentFilter.accepts(
                    distanceMeters: segmentDistance,
                    interval: interval
                ) else {
                    continue
                }
                segmentDistanceFromPrevious = segmentDistance
            }
            if wasPaused,
               !WorkoutPausedRoutePointFilter.accepts(
                 reportedSpeedMetersPerSecond: location.speed,
                 horizontalAccuracyMeters: location.horizontalAccuracy,
                 previousHorizontalAccuracyMeters:
                    hasBoundedMotionSegment ? priorObservation?.horizontalAccuracy : nil,
                 segmentDistanceMeters: hasBoundedMotionSegment ? motionDistance : nil,
                 interval: hasBoundedMotionSegment ? motionInterval : nil
               ) {
                lastDistanceLocation = nil
                distanceAccumulator?.breakSegment()
                continue
            }
            lastDistanceLocation = location
            distanceAccumulator?.appendPoint(
                segmentDistanceFromPrevious: segmentDistanceFromPrevious
            )
            routeDistanceMeters = distanceAccumulator?.totalMeters
            routeAccepted.append(location)
        }
        guard !routeAccepted.isEmpty else {
            onLocationUpdate?()
            return
        }
        routeDistanceCapturedAt = routeDistanceMeters == nil
            ? nil
            : routeAccepted.last?.timestamp
        onLocationUpdate?()

        enqueueRouteLocations(routeAccepted)
    }

#if WORKOUT_CONTRACT_XCTEST
    func receiveLocationsForTesting(_ locations: [CLLocation]) {
        receive(locations)
    }
#endif

    /// The production queue/insert boundary is internal so the Watch test
    /// target can inject a route-builder failure without Core Location or
    /// HealthKit test doubles. Filtering and distance accounting remain in
    /// `receive(_:)`; this method owns the exact builder-retention decision.
    func enqueueRouteLocations(_ locations: [CLLocation]) {
        guard routeBuilder != nil, !routeSavingFailed else { return }
        guard routeQueue.append(contentsOf: locations) else {
            failRouteSaving()
            return
        }
        scheduleRouteFlush()
    }

    private func scheduleRouteFlush() {
        guard flushTask == nil else { return }
        let generation = routeGeneration.current
        flushTask = Task { [weak self] in
            guard let self else { return }
            await self.drainRouteQueue(generation: generation)
        }
    }

    private func drainRouteQueue(generation: UInt64) async {
        defer {
            if routeGeneration.accepts(generation) {
                flushTask = nil
            }
        }
        while !Task.isCancelled,
              routeGeneration.accepts(generation),
              !routeQueue.isEmpty,
              let routeBuilder,
              !routeSavingFailed {
            let batch = routeQueue.takeNextBatch()
            guard !batch.isEmpty else { return }
            do {
                try await routeBuilder.insertRouteData(batch)
                guard routeGeneration.accepts(generation),
                      self.routeBuilder === routeBuilder else {
                    return
                }
                routeQueue.markInserted(count: batch.count)
                if routeQueue.hasFailed {
                    failRouteSaving()
                    return
                }
            } catch {
                guard routeGeneration.accepts(generation) else { return }
                failRouteSaving()
                return
            }
        }
    }

    private func flushPendingRouteLocations() async {
        if let flushTask {
            await flushTask.value
        }
        guard !routeQueue.isEmpty, routeBuilder != nil, !routeSavingFailed else {
            return
        }
        await drainRouteQueue(generation: routeGeneration.current)
    }

    private func clearAfterFinalization() {
        onLocationUpdate = nil
        workoutStart = nil
        timestampGate = nil
        captureLifecycle = nil
        lastObservationAt = nil
        distanceAccumulator = nil
        isWorkoutActive = false
        mayContainExistingRouteData = false
        routeQueue.reset()
        latestLocation = nil
        motionSampleEpoch = nil
        motionSampleSequence = 0
        lastDistanceLocation = nil
        routeDistanceMeters = nil
        routeDistanceCapturedAt = nil
    }

    private func failRouteSaving() {
        routeSavingFailed = true
        routeQueue.markFailed()
        if mayContainExistingRouteData {
            // Stop this process from making further inserts, while retaining
            // the associated builder so HealthKit can preserve route samples
            // that may have been written before recovery.
            routeGeneration.advance()
            flushTask?.cancel()
            flushTask = nil
        } else {
            invalidateRouteBuilder(discard: true)
        }
    }

    private func invalidateRouteBuilder(discard: Bool) {
        routeGeneration.advance()
        flushTask?.cancel()
        flushTask = nil
        routeQueue.reset()
        if discard {
            routeBuilder?.discard()
        }
        routeBuilder = nil
    }

    static func mapAuthorization(
        _ status: CLAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            .authorized
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}
