import Combine
import CoreLocation
import Foundation
import HealthKit

/// The primary iPhone recorder. It never launches, controls, or writes a Watch
/// workout. Available only on iOS 26; older OSes keep the existing mirror path.
@available(iOS 26.0, *)
@MainActor
final class PhoneWorkoutRecorder: NSObject, PhoneWorkoutRecording {
    enum RecorderError: Error {
        case unavailable, identityMismatch, ambiguousFinish, emptySaveResult
    }
    nonisolated static let ownerMetadataKey = "org.bicino.recordingOwner.v1"
    nonisolated static let segmentMetadataKey = "org.bicino.phoneSegment.v1"

    let store = WorkoutMetricsStore()
    private(set) var record: WorkoutRecordingRecord?
    private(set) var message: String?
    private let healthStore: HKHealthStore
    private let persistence: any WorkoutRecordingPersisting
    private let onRecoveredMirror: (HKWorkoutSession) -> Void
    private let canStartAfterAuthorization: () -> Bool
    private let requestLocationAuthorization: () -> Void
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var locationSubscription: AnyCancellable?
    private var timer: Task<Void, Never>?
    private var controlTimeout: Task<Void, Never>?
    private var finalization: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var state: WorkoutSessionStateV1 = .idle
    private var sequence: UInt64 = 0
    private var token: UInt16 = 1
    private var generation = UUID()
    private var collectionStarted = false
    private var collectionEnded = false
    private var finishAttempted = false
    private var routeWriteFailed = false
    private var distanceWriteFailed = false
    private var recoveredRoute = false
    private var insertedRoutePoints = 0
    private var startDate: Date?
    private var endDate: Date?
    private var lastLocation: CLLocation?
    private var latestLocation: CLLocation?
    private var timestampGate: WorkoutRouteTimestampGate?
    private var locationQueue = WorkoutRouteBatchQueue<LocationWrite>()
    private var segments = WorkoutSegmentAccumulator()
    private var pendingTransitionOrigin: WorkoutTransitionOrigin?
    private var pauseOrigin: WorkoutTransitionOrigin?
    private var lastTransitionOrigin: WorkoutTransitionOrigin?
    private var lastTransitionAt: Date?
    private var savedWorkout: HKWorkout?

    private struct LocationWrite {
        let location: CLLocation
        let distance: HKQuantitySample?
    }
    private struct SegmentBoundary: Codable {
        let completed: WorkoutCompletedSegmentV1
        let elapsed: TimeInterval
        let distance: Double?
    }

    init(
        persistence: any WorkoutRecordingPersisting,
        locations: AnyPublisher<CLLocation?, Never>,
        healthStore: HKHealthStore = HKHealthStore(),
        onRecoveredMirror: @escaping (HKWorkoutSession) -> Void = { _ in },
        canStartAfterAuthorization: @escaping () -> Bool = { true },
        requestLocationAuthorization: @escaping () -> Void = {}
    ) {
        self.persistence = persistence
        self.healthStore = healthStore
        self.onRecoveredMirror = onRecoveredMirror
        self.canStartAfterAuthorization = canStartAfterAuthorization
        self.requestLocationAuthorization = requestLocationAuthorization
        super.init()
        store.recordingOwner = .iphone
        locationSubscription = locations.sink { [weak self] location in
            guard let location else { return }
            self?.receive(location)
        }
    }

    deinit {
        timer?.cancel()
        controlTimeout?.cancel()
        finalization?.cancel()
        flushTask?.cancel()
    }

    func start(_ requested: WorkoutRecordingRecord) async {
        guard session == nil, record == nil, requested.owner == .iphone,
              requested.phase == .starting else { return }
        resetFinished()
        record = requested
        message = nil
        store.beginLocalWorkout()
        state = .starting
        publish()
        do {
            guard HKHealthStore.isHealthDataAvailable() else { throw RecorderError.unavailable }
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), Self.distanceType],
                read: [HKObjectType.workoutType(), Self.distanceType, Self.heartRateType, Self.energyType]
            )
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                throw HKError(.errorAuthorizationDenied)
            }
            guard canStartAfterAuthorization() else { throw RecorderError.identityMismatch }
            requestLocationAuthorization()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .cycling
            configuration.locationType = .outdoor
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            self.session = session
            self.builder = builder
            session.delegate = self
            builder.delegate = self
            configureDataSource(builder, configuration: configuration)
            // The same identity is used on recovery and for save reconciliation.
            // Never construct a replacement builder for an interrupted ride.
            try await builder.addMetadata([
                HKMetadataKeyExternalUUID: requested.sessionID.uuidString,
                Self.ownerMetadataKey: WorkoutRecordingOwner.iphone.rawValue
            ])
            let date = Date()
            var next = requested
            next.startedAt = date
            try persist(next)
            startDate = date
            timestampGate = WorkoutRouteTimestampGate(workoutStart: date)
            segments.reset(workoutStart: date)
            attachRouteBuilder(builder)
            session.prepare()
            session.startActivity(with: date)
            try await builder.beginCollection(at: date)
            guard self.session === session else { return }
            collectionStarted = true
            startTimer()
            publish()
        } catch {
            // A failed setup never masquerades as a recorded/saved workout.
            // Only this local, not-yet-established primary session is cleaned up.
            builder?.discardWorkout()
            routeBuilder?.discard()
            session?.end()
            session?.delegate = nil
            session = nil
            builder = nil
            routeBuilder = nil
            if let id = record?.sessionID {
                do { try persistence.clear(sessionID: id); record = nil }
                catch { message = "Workout setup failed and its recovery record could not be cleared. Reopen Bicino before starting again." }
            }
            message = message ?? "iPhone workout could not start. Allow Workouts in Settings › Health › Apps › Bicino, then try again."
            state = .failed
            store.failSession(error: Self.safeError(error))
            store.recordingMessage = message
        }
    }

    /// Called before ANY new start, including on an ordinary cold launch.
    /// A missing/corrupt record is not proof that HealthKit has no primary session.
    func recover(expected: WorkoutRecordingRecord?) async throws {
        guard session == nil else { return }
        let recovered: HKWorkoutSession? = try await withCheckedThrowingContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: session) }
            }
        }
        if let recovered, recovered.type == .mirrored {
            onRecoveredMirror(recovered)
            if expected?.owner == .iphone { throw RecorderError.identityMismatch }
            return
        }
        guard let recovered else {
            guard let expected, expected.owner == .iphone else { return }
            record = expected
            store.beginLocalWorkout()
            startDate = expected.startedAt
            if expected.phase == .finished {
                state = .ended
                publish()
                return
            }
            if expected.finishChoice == .discard {
                try complete(.discard)
                return
            }
            // Finishing may have committed to HealthKit immediately before a
            // crash. Query the original identity; never re-record the workout.
            if let workout = try await findSavedWorkout(id: expected.sessionID) {
                savedWorkout = workout
                startDate = workout.startDate
                endDate = workout.endDate
                var next = expected
                next.finishChoice = .save
                try persist(next)
                try complete(.save)
                return
            }
            if expected.startedAt == nil && expected.finishChoice == nil {
                // No session was started and HealthKit confirms none is active.
                try persistence.clear(sessionID: expected.sessionID)
                record = nil
                return
            }
            state = .ending
            message = "The iPhone recording could not be recovered. Its save status is unknown; check Apple Health. Bicino will not create a duplicate recording."
            var unresolved = expected
            unresolved.phase = .unresolved
            try persist(unresolved)
            publish(error: .finalSummaryUnavailable)
            throw RecorderError.ambiguousFinish
        }
        guard recovered.type == .primary else { throw RecorderError.identityMismatch }
        let builder = recovered.associatedWorkoutBuilder()
        guard builder.metadata[Self.ownerMetadataKey] as? String == WorkoutRecordingOwner.iphone.rawValue,
              let identifier = builder.metadata[HKMetadataKeyExternalUUID] as? String,
              let id = UUID(uuidString: identifier),
              expected == nil || (expected?.owner == .iphone && expected?.sessionID == id),
              recovered.workoutConfiguration.activityType == .cycling else {
            throw RecorderError.identityMismatch
        }
        var next = expected ?? WorkoutRecordingRecord(
            owner: .iphone, sessionID: id, requestedAt: recovered.startDate ?? Date()
        )
        next.startedAt = recovered.startDate ?? next.startedAt
        guard let date = next.startedAt else { throw RecorderError.identityMismatch }
        try persist(next)
        self.session = recovered
        self.builder = builder
        startDate = date
        collectionStarted = builder.startDate != nil
        collectionEnded = builder.endDate != nil
        finishAttempted = next.saveAttempted
        recovered.delegate = self
        builder.delegate = self
        configureDataSource(builder, configuration: recovered.workoutConfiguration)
        store.beginLocalWorkout()
        generation = UUID()
        sequence = 0
        token = UInt16.random(in: 1...UInt16.max)
        recoveredRoute = true
        attachRouteBuilder(builder)
        // Do not bridge a crash/location gap or admit delayed pre-recovery GPS.
        timestampGate = WorkoutRouteTimestampGate(workoutStart: Date())
        restoreSegments(builder)
        if next.phase == .finished {
            // A terminal tombstone must never re-enter finishWorkout.
            if next.finishedChoice == .discard { builder.discardWorkout(); routeBuilder?.discard() }
            recovered.end()
            state = .ended
            publish()
            return
        }
        switch recovered.state {
        case .running: state = .running
        case .paused: state = .paused; pauseOrigin = .unknown
        case .stopped, .ended:
            state = .ending
            endDate = recovered.endDate ?? Date()
        case .notStarted, .prepared:
            state = .starting
        @unknown default: throw RecorderError.identityMismatch
        }
        publish()
        startTimer()
        if let choice = next.finishChoice {
            finish(choice)
        } else if state == .ending || state == .starting {
            message = "An interrupted iPhone workout needs attention. Choose End and Save or Discard; Bicino will not start a second session."
            store.recordingMessage = message
        }
    }

    func pause() { requestTransition(.pause) }
    func resume() { requestTransition(.resume) }

    private func requestTransition(_ control: WorkoutControlV1) {
        guard let session, record?.finishChoice == nil,
              (control == .pause && state == .running) || (control == .resume && state == .paused),
              store.markPendingControl(control) else { return }
        pendingTransitionOrigin = .manual
        if control == .pause { session.pause() } else { session.resume() }
        let id = record?.sessionID
        controlTimeout?.cancel()
        controlTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, record?.sessionID == id,
                  store.presentation.pendingControl == control else { return }
            pendingTransitionOrigin = nil
            store.failPendingControl(control, error: .sessionFailed)
            message = "iPhone did not confirm the workout control. Check the current state before trying again."
            store.recordingMessage = message
        }
    }

    func markSegment() {
        guard let builder, state == .running, record?.finishChoice == nil,
              let candidate = segments.candidate(
                endedAt: Date(), cumulativeElapsedTime: builder.elapsedTime,
                cumulativeDistanceMeters: distanceMeters,
                cumulativeDistanceSource: .iPhoneLocation
              ), store.markPendingControl(.markSegment, sequence: sequence) else { return }
        let id = record?.sessionID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(SegmentBoundary(
                    completed: candidate.completedSegment,
                    elapsed: candidate.cumulativeElapsedTime,
                    distance: candidate.cumulativeDistanceMeters
                ))
                let event = HKWorkoutEvent(
                    type: .segment,
                    dateInterval: DateInterval(start: candidate.completedSegment.startedAt, end: candidate.completedSegment.endedAt),
                    metadata: [Self.segmentMetadataKey: data]
                )
                try await builder.addWorkoutEvents([event])
                guard self.builder === builder, record?.sessionID == id else { return }
                _ = segments.commit(candidate)
                // A local successful HealthKit write is the acknowledgement.
                acknowledgeSegment()
                publish()
            } catch {
                guard record?.sessionID == id else { return }
                store.failPendingControl(.markSegment, error: .segmentMarkFailed)
            }
        }
    }

    func finish(_ choice: WorkoutRecordingDisposition) {
        guard let record, let session, let next = record.finishing(choice),
              finalization == nil, store.presentation.pendingControl != .markSegment else { return }
        if choice == .save, !collectionStarted {
            message = "This recording has not started collecting. Wait for startup, or explicitly discard the interrupted setup."
            store.recordingMessage = message
            return
        }
        do { try persist(next) }
        catch {
            message = "The finish choice could not be stored safely. The workout has not been stopped. Try again after unlocking iPhone."
            store.recordingMessage = message
            return
        }
        controlTimeout?.cancel()
        endDate = session.endDate ?? endDate ?? Date()
        lastLocation = nil
        state = .ending
        _ = store.markPendingControl(choice == .save ? .endAndSave : .discard)
        publish()
        switch session.state {
        case .stopped, .ended: beginFinalization()
        case .notStarted, .prepared:
            // No collected workout exists to save. A discard remains explicit.
            if choice == .discard { beginFinalization() }
            else {
                message = "The recovered workout never started collecting. Discard it after checking Health."
                store.recordingMessage = message
            }
        case .running, .paused: session.stopActivity(with: endDate)
        @unknown default: break
        }
    }

    private func beginFinalization() {
        guard finalization == nil, let builder, let session,
              let record, let choice = record.finishChoice else { return }
        let id = record.sessionID
        finalization = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finalization = nil }
            do {
                if let flushTask { await flushTask.value }
                guard self.record?.sessionID == id, self.builder === builder else { return }
                if choice == .discard {
                    // Never call finishWorkout on any discard path or retry.
                    routeBuilder?.discard()
                    builder.discardWorkout()
                } else {
                    if !collectionEnded {
                        guard collectionStarted else { throw RecorderError.ambiguousFinish }
                        try await builder.endCollection(at: endDate ?? Date())
                        collectionEnded = true
                    }
                    if routeWriteFailed && !recoveredRoute && insertedRoutePoints == 0 { routeBuilder?.discard() }
                    if savedWorkout != nil {
                        // HealthKit already confirmed success; only the local
                        // tombstone write failed. Do not require read permission
                        // or call finishWorkout again to retry that disk write.
                    } else if finishAttempted {
                        guard let existing = try await findSavedWorkout(id: id) else {
                            throw RecorderError.ambiguousFinish
                        }
                        savedWorkout = existing
                    } else {
                        // Set before calling out: a failed/ambiguous completion
                        // is reconciled, not blindly retried or rebuilt.
                        var attempted = self.record ?? record
                        attempted.saveAttempted = true
                        try persist(attempted)
                        finishAttempted = true
                        savedWorkout = try await finishWorkout(builder)
                    }
                }
                try complete(choice)
                session.end()
                session.delegate = nil
                self.session = nil
                self.builder = nil
                routeBuilder = nil
                timer?.cancel()
                timer = nil
                publish()
            } catch {
                guard self.record?.sessionID == id else { return }
                message = "iPhone could not confirm the finish. Unlock it and retry the same finish choice. Check Apple Health before recording again."
                store.recordingMessage = message
                // Keep the original session/builder and immutable disposition.
                // A failed save never enables a new recording or a discard.
                store.failPendingControl(choice == .save ? .endAndSave : .discard, error: .terminalChoiceUnconfirmed)
                publish(error: .terminalChoiceUnconfirmed)
            }
        }
    }

    private func complete(_ choice: WorkoutRecordingDisposition) throws {
        guard let record, let next = record.finished(choice) else { throw RecorderError.identityMismatch }
        try persist(next)
        state = .ended
        message = choice == .save && (routeWriteFailed || distanceWriteFailed)
            ? "Workout saved, but some GPS data could not be written. Review the route and distance in Apple Health."
            : nil
        publish()
    }

    func resetFinished() {
        guard record == nil || record?.phase == .finished else { return }
        timer?.cancel(); timer = nil
        controlTimeout?.cancel(); controlTimeout = nil
        session = nil; builder = nil; routeBuilder = nil
        record = nil; state = .idle; message = nil
        sequence = 0; generation = UUID(); token = UInt16.random(in: 1...UInt16.max)
        collectionStarted = false; collectionEnded = false; finishAttempted = false
        routeWriteFailed = false; distanceWriteFailed = false; recoveredRoute = false
        insertedRoutePoints = 0; savedWorkout = nil
        startDate = nil; endDate = nil; latestLocation = nil; lastLocation = nil
        locationQueue.reset(); segments = WorkoutSegmentAccumulator()
        timestampGate = nil; pauseOrigin = nil; lastTransitionOrigin = nil; lastTransitionAt = nil
        _ = store.resetTerminalPresentation()
        store.recordingMessage = nil
    }

    private func persist(_ next: WorkoutRecordingRecord) throws {
        try persistence.save(next)
        record = next
    }

    private func configureDataSource(_ builder: HKLiveWorkoutBuilder, configuration: HKWorkoutConfiguration) {
        let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        // GPS distance is written exactly once by the pipeline below. Do not
        // simultaneously collect system-generated cycling distance samples.
        source.disableCollection(for: Self.distanceType)
        builder.dataSource = source
    }

    private func attachRouteBuilder(_ builder: HKLiveWorkoutBuilder) {
        guard healthStore.authorizationStatus(for: HKSeriesType.workoutRoute()) == .sharingAuthorized else { return }
        routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
    }

    private func receive(_ location: CLLocation) {
        guard state == .running, record?.finishChoice == nil, collectionStarted,
              let startDate, timestampGate?.accepts(location.timestamp) == true,
              Date().timeIntervalSince(location.timestamp) <= WorkoutRouteCaptureLifecycle.maximumLateness,
              WorkoutRoutePointFilter.accepts(WorkoutRoutePointCandidate(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                capturedAt: location.timestamp, horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy
              ), workoutStart: startDate, now: Date()),
              latestLocation.map({ location.timestamp > $0.timestamp }) ?? true else { return }
        var sample: HKQuantitySample?
        if let previous = lastLocation {
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            let distance = location.distance(from: previous)
            if interval <= WorkoutRouteCaptureLifecycle.maximumSegmentGap,
               WorkoutRouteSegmentFilter.accepts(distanceMeters: distance, interval: interval),
               // Avoid summing stationary GPS drift into a cycling workout.
               location.speed > 0.5 || distance > max(previous.horizontalAccuracy, location.horizontalAccuracy),
               healthStore.authorizationStatus(for: Self.distanceType) == .sharingAuthorized {
                sample = HKQuantitySample(
                    type: Self.distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                    start: previous.timestamp, end: location.timestamp
                )
            }
        }
        latestLocation = location
        lastLocation = location
        guard locationQueue.append(contentsOf: [LocationWrite(location: location, distance: sample)]) else {
            routeWriteFailed = true
            distanceWriteFailed = true
            message = "GPS writing fell behind. The workout continues, but its route or distance may be incomplete."
            store.recordingMessage = message
            return
        }
        guard flushTask == nil else { return }
        let expectedGeneration = generation
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == expectedGeneration { flushTask = nil } }
            while generation == expectedGeneration, !Task.isCancelled, !locationQueue.isEmpty, let builder {
                let batch = locationQueue.takeNextBatch()
                if let routeBuilder, !routeWriteFailed {
                    do {
                        try await routeBuilder.insertRouteData(batch.map(\.location))
                        guard generation == expectedGeneration else { return }
                        insertedRoutePoints += batch.count
                    } catch { routeWriteFailed = true }
                }
                let samples = batch.compactMap(\.distance)
                if !samples.isEmpty, !distanceWriteFailed {
                    do { try await builder.addSamples(samples) }
                    catch { distanceWriteFailed = true }
                }
                guard generation == expectedGeneration else { return }
                locationQueue.markInserted(count: batch.count)
                if routeWriteFailed || distanceWriteFailed {
                    message = "Some GPS samples could not be written. The workout continues, but its route or distance may be incomplete."
                }
                publish()
            }
        }
    }

    private var distanceMeters: Double? {
        let quantity = savedWorkout?.statistics(for: Self.distanceType)?.sumQuantity()
            ?? builder?.statistics(for: Self.distanceType)?.sumQuantity()
        return quantity.map { $0.doubleValue(for: .meter()) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private func publish(error: WorkoutSafeErrorCodeV1? = nil) {
        guard let record else { return }
        let now = Date()
        let captured = endDate ?? now
        func metric(_ value: Double?, _ unit: WorkoutMetricUnitV1, at date: Date? = nil,
                    source: WorkoutMetricSourceV1 = .healthKit) -> WorkoutMetricV1? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return WorkoutMetricV1(value: value, unit: unit, capturedAt: date ?? captured, source: source)
        }
        let hrStats = builder?.statistics(for: Self.heartRateType)
        let hrDate = hrStats?.mostRecentQuantityDateInterval()?.end
        let currentHR = hrDate.flatMap { now.timeIntervalSince($0) <= 15 ? hrStats?.mostRecentQuantity() : nil }
        let energy = savedWorkout?.statistics(for: Self.energyType)?.sumQuantity()
            ?? builder?.statistics(for: Self.energyType)?.sumQuantity()
        let averageHR = savedWorkout?.statistics(for: Self.heartRateType)?.averageQuantity() ?? hrStats?.averageQuantity()
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let location = latestLocation.flatMap { raw -> WorkoutLocationV1? in
            guard now.timeIntervalSince(raw.timestamp) <= 10 else { return nil }
            return WorkoutLocationV1(
                latitude: raw.coordinate.latitude, longitude: raw.coordinate.longitude,
                capturedAt: raw.timestamp, horizontalAccuracy: raw.horizontalAccuracy,
                altitude: raw.verticalAccuracy >= 0 && raw.altitude.isFinite ? raw.altitude : nil,
                verticalAccuracy: raw.verticalAccuracy >= 0 ? raw.verticalAccuracy : nil,
                course: raw.course >= 0 ? raw.course : nil,
                speed: raw.speed >= 0 ? raw.speed : nil
            )
        }
        let elapsed = metric(savedWorkout?.duration ?? builder?.elapsedTime, .seconds)
        let hr = metric(currentHR?.doubleValue(for: heartUnit), .beatsPerMinute, at: hrDate)
        let avgHR = metric(averageHR?.doubleValue(for: heartUnit), .beatsPerMinute)
        let kcal = metric(energy?.doubleValue(for: .kilocalorie()), .kilocalories)
        let distance = metric(distanceMeters, .meters, source: .iPhoneLocation)
        let speed = metric(location?.speed, .metersPerSecond, at: location?.capturedAt, source: .iPhoneLocation)
        var availability: WorkoutAvailabilityMaskV1 = []
        if elapsed != nil { availability.insert(.elapsedTime) }
        if hr != nil { availability.insert(.currentHeartRate) }
        if avgHR != nil { availability.insert(.averageHeartRate) }
        if kcal != nil { availability.insert(.activeEnergy) }
        if distance != nil { availability.insert(.cyclingDistance) }
        if speed != nil { availability.insert(.currentSpeed) }
        if location != nil { availability.insert(.location) }
        if location?.altitude != nil { availability.insert(.altitude) }
        let snapshot = WorkoutSnapshotV1(
            state: state, startDate: startDate, elapsedTime: elapsed,
            currentHeartRate: hr, averageHeartRate: avgHR, activeEnergy: kcal,
            cyclingDistance: distance, currentSpeed: speed, location: location,
            lastCompletedSegment: segments.lastCompletedSegment,
            availability: availability, errorCode: error,
            terminalOutcome: record.finishedChoice.map { $0 == .save ? .saved : .discarded },
            pauseOrigin: state == .paused ? pauseOrigin : nil,
            lastTransitionOrigin: lastTransitionOrigin, lastTransitionAt: lastTransitionAt,
            wallElapsedTime: startDate.flatMap { metric(max(0, captured.timeIntervalSince($0)), .seconds) }
        )
        guard sequence < UInt64.max else { return }
        sequence += 1
        _ = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: record.sessionID, sessionToken: token,
            transportGenerationID: generation, sequence: sequence, capturedAt: now, snapshot: snapshot
        )], receivedAt: now)
        store.recordingMessage = message
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, state.isActive else { return }
                publish()
            }
        }
    }

    private func restoreSegments(_ builder: HKLiveWorkoutBuilder) {
        guard let startDate else { return }
        segments.reset(workoutStart: startDate)
        let boundaries = builder.workoutEvents.compactMap { event -> SegmentBoundary? in
            guard let data = event.metadata?[Self.segmentMetadataKey] as? Data else { return nil }
            return try? JSONDecoder().decode(SegmentBoundary.self, from: data)
        }
        if let last = boundaries.max(by: { $0.completed.index < $1.completed.index }) {
            segments.restore(workoutStart: startDate, lastCompletedSegment: last.completed,
                cumulativeElapsedTime: last.elapsed, cumulativeDistanceMeters: last.distance,
                cumulativeDistanceSource: .iPhoneLocation)
        }
    }

    private func acknowledgeSegment() {
        guard let record, let acknowledged = store.currentPendingControlSequence,
              sequence < UInt64.max else { return }
        sequence += 1
        _ = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .acknowledgement, sessionID: record.sessionID,
            sessionToken: token, transportGenerationID: generation,
            sequence: sequence, capturedAt: Date(),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment, resultingState: state,
                acknowledgedSequence: acknowledged
            )
        )], receivedAt: Date())
    }

    private func findSavedWorkout(id: UUID) async throws -> HKWorkout? {
        let identity = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id.uuidString])
        let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [identity, ownSource]),
                limit: 2, sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else if let samples, samples.count > 1 { continuation.resume(throwing: RecorderError.identityMismatch) }
                else { continuation.resume(returning: samples?.first as? HKWorkout) }
            }
            healthStore.execute(query)
        }
    }

    private func finishWorkout(_ builder: HKLiveWorkoutBuilder) async throws -> HKWorkout {
        try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                if let error { continuation.resume(throwing: error) }
                else if let workout { continuation.resume(returning: workout) }
                else { continuation.resume(throwing: RecorderError.emptySaveResult) }
            }
        }
    }

    private static var distanceType: HKQuantityType { HKQuantityType(.distanceCycling) }
    private static var heartRateType: HKQuantityType { HKQuantityType(.heartRate) }
    private static var energyType: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private static func safeError(_ error: Error) -> WorkoutSafeErrorCodeV1 {
        guard let error = error as? HKError else { return .sessionFailed }
        switch error.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied: return .authorizationDenied
        case .errorAnotherWorkoutSessionStarted: return .anotherWorkoutActive
        default: return .sessionFailed
        }
    }
}

@available(iOS 26.0, *)
extension PhoneWorkoutRecorder: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                   from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor [weak self] in
            guard let self, session === workoutSession else { return }
            switch toState {
            case .running, .paused:
                guard record?.finishChoice == nil else { workoutSession.stopActivity(with: endDate ?? date); return }
                state = toState == .running ? .running : .paused
                lastLocation = nil
                timestampGate?.resume(at: date)
                lastTransitionOrigin = pendingTransitionOrigin ?? (fromState == .prepared ? .manual : .unknown)
                lastTransitionAt = date
                pauseOrigin = state == .paused ? lastTransitionOrigin : nil
                pendingTransitionOrigin = nil
                controlTimeout?.cancel()
                if var next = record {
                    next.phase = state == .running ? .running : .paused
                    do { try persist(next) }
                    catch { message = "Workout continues, but recovery bookkeeping could not be updated. Keep Bicino running." }
                }
                store.confirmSessionState(state, at: date)
                publish()
            case .stopped:
                endDate = workoutSession.endDate ?? date
                state = .ending
                lastLocation = nil
                publish()
                if record?.finishChoice != nil { beginFinalization() }
                else {
                    message = "The iPhone session stopped. Choose End and Save or Discard to finish it."
                    store.recordingMessage = message
                }
            case .ended:
                if record?.phase != .finished, finalization == nil {
                    state = .ending
                    message = "iPhone ended the session without a confirmed saved result. Check Health before recording again."
                    publish(error: .finalSummaryUnavailable)
                }
            case .notStarted, .prepared: break
            @unknown default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, session === workoutSession, record?.phase != .finished else { return }
            state = .ending
            message = "The iPhone workout was interrupted. Review this recording before starting another; Bicino has not saved or discarded it automatically."
            publish(error: Self.safeError(error))
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor [weak self] in
            guard let self, builder === workoutBuilder else { return }
            publish()
        }
    }
}
