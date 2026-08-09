import Combine
import CoreLocation
import Foundation

enum WatchNavigationState: Equatable {
    case idle
    case waitingForLocation(routeID: UUID)
    case waitingForOnlineLocation(destinationID: UUID)
    case awaitingStartConfirmation(routeID: UUID, distanceMeters: Double)
    case requestingOnline(destinationID: UUID)
    case navigating(routeID: UUID)
    case offRoute(routeID: UUID, distanceMeters: Double)
    case unavailable(String)
    case stopping

    var isActive: Bool {
        switch self {
        case .waitingForLocation, .waitingForOnlineLocation,
                .awaitingStartConfirmation, .requestingOnline,
                .navigating, .offRoute:
            true
        case .idle, .unavailable, .stopping:
            false
        }
    }
}

enum WatchOnlineRoutingStatusV1: Equatable {
    case idle
    case offlinePolicy
    case waitingForLocation
    case calculating
    case routeFailed
    case online
    case noConnection
    case continuingCachedRoute
    case rerouting
    case rerouteFailed

    var userDescription: String {
        switch self {
        case .idle: ""
        case .offlinePolicy: "Offline"
        case .waitingForLocation: "Waiting for GPS"
        case .calculating: "Calculating route"
        case .routeFailed: "Route calculation failed"
        case .online: "Online"
        case .noConnection: "No Watch internet connection"
        case .continuingCachedRoute: "Offline - continuing route"
        case .rerouting: "Rerouting"
        case .rerouteFailed: "Reroute failed - continuing route"
        }
    }
}

@MainActor
protocol WatchNavigationLocationProviding: AnyObject {
    var latestLocation: CLLocation? { get }
    func requestAuthorizationIfNeeded()
    func setNavigationConsumer(
        active: Bool,
        handler: (@MainActor ([CLLocation]) -> Void)?
    )
}

@MainActor
protocol WatchNavigationDeviceLinking: AnyObject {
    func setNavigationDemand(_ active: Bool)
    func updateNavigation(
        location: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1
    )
    func endNavigationDemandAfterClearing()
}

@MainActor
protocol WatchNetworkAvailabilityProviding: AnyObject {
    var availability: WatchNetworkAvailabilityV1 { get }
    var availabilityPublisher:
        AnyPublisher<WatchNetworkAvailabilityV1, Never> { get }
    func start()
}

@MainActor
final class WatchNavigationManager: ObservableObject {
    @Published private(set) var state: WatchNavigationState = .idle
    @Published private(set) var snapshot: NavigationSnapshotV1?
    @Published private(set) var lastLocation: NavigationLocationSampleV1?
    @Published private(set) var recoveryError: String?
    @Published private(set) var routeAttribution: String?
    @Published private(set) var onlineStatus: WatchOnlineRoutingStatusV1 =
        .idle

    var canRecalculateOnline: Bool {
        settingsStore.policy == .onlineAllowed &&
            runtime.route != nil && activeDestination != nil &&
            lastLocation.map(isUsableRoutingLocation) == true &&
            requestTask == nil
    }

    var canRetryOnlineInitial: Bool {
        settingsStore.policy == .onlineAllowed && pendingFavorite != nil &&
            requestTask == nil
    }

    /// Keeps navigation controls reachable when the workout lifecycle has
    /// already ended or never started. An unavailable initial online request
    /// remains present while it still has an explicit destination to retry.
    var shouldPresentNavigation: Bool {
        state.isActive || state == .stopping || runtime.route != nil ||
            pendingRecord != nil || pendingFavorite != nil || snapshot != nil
    }

    private let routeLibrary: WatchRouteLibrary
    private let locationService: WatchNavigationLocationProviding
    private let deviceLink: WatchNavigationDeviceLinking
    private let journalStore: WatchNavigationJournalStore
    private let settingsStore: WatchNavigationSettingsStore
    private let onlineProvider: NavigationRouteProvider
    private let networkMonitor: WatchNetworkAvailabilityProviding
    private let now: () -> Date

    private var runtime = NavigationRuntimeV1()
    private var pendingRecord: InstalledNavigationRouteV1?
    private var pendingMode: NavigationModeV1 = .offline
    private var pendingAcceptsFarStart = false
    private var pendingFavorite: SyncedCoordinateFavoriteV1?
    private var activeRecord: InstalledNavigationRouteV1?
    private var activeDestination: RouteEndpointV1?
    private var startedAt: Date?
    private var lastJournalWriteAt = Date.distantPast
    private var lastJournalStepIndex: Int?
    private var lifecycleGeneration: UInt64 = 1
    private var requestGeneration: UInt64 = 1
    private var requestLocationGeneration: UInt64 = 1
    private var requestOrigin: RouteCoordinateV1?
    private var requestTask: Task<Void, Never>?
    private var rerouteCooldown = WatchRerouteCooldownV1()
    private var cancellables = Set<AnyCancellable>()

    init(
        routeLibrary: WatchRouteLibrary,
        locationService: WatchNavigationLocationProviding,
        deviceLink: WatchNavigationDeviceLinking,
        journalStore: WatchNavigationJournalStore,
        settingsStore: WatchNavigationSettingsStore,
        onlineProvider: NavigationRouteProvider,
        networkMonitor: WatchNetworkAvailabilityProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.routeLibrary = routeLibrary
        self.locationService = locationService
        self.deviceLink = deviceLink
        self.journalStore = journalStore
        self.settingsStore = settingsStore
        self.onlineProvider = onlineProvider
        self.networkMonitor = networkMonitor
        self.now = now

        settingsStore.$policy
            .dropFirst()
            .sink { [weak self] policy in
                self?.policyDidChange(policy)
            }
            .store(in: &cancellables)
        networkMonitor.availabilityPublisher
            .dropFirst()
            .sink { [weak self] availability in
                self?.networkDidChange(availability)
            }
            .store(in: &cancellables)
        networkMonitor.start()
    }

    func recoverIfNeeded() {
        guard state == .idle else { return }
        var activatedIdentity: WatchRouteIdentityV1?
        do {
            guard let journal = try journalStore.load(now: now()) else {
                routeLibrary.applyPendingDeletionIfInactive()
                return
            }
            let record = try routeLibrary.activate(journal.identity)
            activatedIdentity = journal.identity
            let recoveredLocation = journal.lastLocation?.sample
            let mode: NavigationModeV1 = if settingsStore.policy == .offlineOnly {
                .offline
            } else {
                networkMonitor.availability == .unavailable
                    ? .onlineUsingCachedRoute
                    : .online
            }
            _ = try runtime.start(
                route: record.archive.route,
                contentHash: record.archive.contentHash,
                mode: mode,
                initialStepStrategy: .checkpoint(
                    stepIndex: journal.currentStepIndex
                ),
                initialLocation: recoveredLocation
            )
            activeRecord = record
            activeDestination = record.archive.route.destination
            routeAttribution = record.archive.route.provider.attribution
            startedAt = journal.startedAt
            if let recoveredLocation {
                lastLocation = recoveredLocation
                snapshot = runtime.snapshot
            }
            updateStateFromSnapshot(routeID: record.archive.routeID)
            onlineStatus = switch mode {
            case .offline: .offlinePolicy
            case .online: .online
            case .onlineUsingCachedRoute: .continuingCachedRoute
            }
            beginLocationDemand()
            deviceLink.setNavigationDemand(true)
            if let lastLocation, let snapshot {
                deviceLink.updateNavigation(
                    location: lastLocation,
                    snapshot: snapshot
                )
            }
        } catch {
            if let activatedIdentity {
                routeLibrary.deactivate(activatedIdentity)
            }
            recoveryError = "Navigation recovery could not validate its route"
            try? journalStore.clear()
            routeLibrary.applyPendingDeletionIfInactive()
            state = .unavailable("Route not installed on this Watch")
        }
    }

    func startOffline(routeID: UUID) {
        startInstalledRoute(
            routeID: routeID,
            allowsOnlineRerouting: false,
            acceptsFarStart: false
        )
    }

    /// Starts a route after the rider explicitly confirmed it in the offline
    /// route library. That confirmation also covers joining a route away from
    /// its first point, so the Watch does not immediately ask a second time.
    func startConfirmedOffline(routeID: UUID) {
        startInstalledRoute(
            routeID: routeID,
            allowsOnlineRerouting: false,
            acceptsFarStart: true
        )
    }

    func startInstalledRoute(routeID: UUID) {
        startInstalledRoute(
            routeID: routeID,
            allowsOnlineRerouting: settingsStore.policy == .onlineAllowed,
            acceptsFarStart: false
        )
    }

    func startOnline(destination: SyncedCoordinateFavoriteV1) {
        guard settingsStore.policy == .onlineAllowed else {
            state = .unavailable("Online routing is disabled")
            onlineStatus = .offlinePolicy
            return
        }
        guard let destination = try? destination.validated() else {
            if runtime.route == nil {
                state = .unavailable("Navigation unavailable")
            }
            return
        }
        guard stopNavigation() else {
            return
        }
        advanceLifecycleGeneration()
        pendingFavorite = destination
        onlineStatus = .waitingForLocation
        state = .waitingForOnlineLocation(destinationID: destination.id)
        beginLocationDemand()
        deviceLink.setNavigationDemand(true)
        if let location = locationService.latestLocation {
            receive([location])
        }
    }

    func retryOnlineRoute() {
        guard settingsStore.policy == .onlineAllowed,
              let pendingFavorite else { return }
        state = .waitingForOnlineLocation(destinationID: pendingFavorite.id)
        onlineStatus = .waitingForLocation
        beginLocationDemand()
        deviceLink.setNavigationDemand(true)
        if let location = locationService.latestLocation {
            receive([location])
        }
    }

    func recalculateOnlineRoute() {
        requestReroute(explicit: true)
    }

    func startAnyway() {
        guard case .awaitingStartConfirmation = state,
              let pendingRecord,
              let lastLocation else { return }
        activate(
            pendingRecord,
            initialLocation: lastLocation,
            acceptsFarStart: true
        )
    }

    @discardableResult
    func stopNavigation() -> Bool {
        cancelRequest()
        do {
            try journalStore.clear()
        } catch {
            recoveryError = "Navigation could not stop safely. Try again."
            state = .unavailable("Navigation could not stop safely")
            return false
        }
        let identity = activeRecord.map {
            WatchRouteIdentityV1(archive: $0.archive)
        }
        if state.isActive || activeRecord != nil || pendingRecord != nil ||
            pendingFavorite != nil || runtime.route != nil {
            state = .stopping
        }
        runtime.stop()
        snapshot = nil
        lastLocation = nil
        pendingRecord = nil
        pendingAcceptsFarStart = false
        pendingFavorite = nil
        activeRecord = nil
        activeDestination = nil
        routeAttribution = nil
        startedAt = nil
        lastJournalStepIndex = nil
        requestOrigin = nil
        rerouteCooldown.reset()
        locationService.setNavigationConsumer(active: false, handler: nil)
        deviceLink.endNavigationDemandAfterClearing()
        if let identity { routeLibrary.deactivate(identity) }
        onlineStatus = .idle
        state = .idle
        advanceLifecycleGeneration()
        return true
    }

    private func startInstalledRoute(
        routeID: UUID,
        allowsOnlineRerouting: Bool,
        acceptsFarStart: Bool
    ) {
        guard stopNavigation() else { return }
        do {
            let record = try routeLibrary.record(routeID: routeID)
            advanceLifecycleGeneration()
            pendingRecord = record
            pendingAcceptsFarStart = acceptsFarStart
            pendingMode = if allowsOnlineRerouting {
                networkMonitor.availability == .unavailable
                    ? .onlineUsingCachedRoute
                    : .online
            } else {
                .offline
            }
            activeDestination = record.archive.route.destination
            routeAttribution = record.archive.route.provider.attribution
            onlineStatus = allowsOnlineRerouting
                ? (networkMonitor.availability == .unavailable
                    ? .continuingCachedRoute
                    : .online)
                : .offlinePolicy
            state = .waitingForLocation(routeID: routeID)
            beginLocationDemand()
            deviceLink.setNavigationDemand(true)
            if let location = locationService.latestLocation {
                receive([location])
            }
        } catch {
            state = .unavailable("Route not installed on this Watch")
        }
    }

    private func beginLocationDemand() {
        locationService.requestAuthorizationIfNeeded()
        locationService.setNavigationConsumer(
            active: true,
            handler: { [weak self] locations in
                self?.receive(locations)
            }
        )
    }

    private func receive(_ locations: [CLLocation]) {
        guard let location = locations.last,
              RouteCoordinateV1(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
              ).isValid,
              location.horizontalAccuracy >= 0,
              now().timeIntervalSince(location.timestamp) >= -5,
              now().timeIntervalSince(location.timestamp) <= 60 else {
            return
        }
        let sample = NavigationLocationSampleV1(
            coordinate: RouteCoordinateV1(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            horizontalAccuracyMeters: location.horizontalAccuracy,
            courseDegrees: location.course,
            speedMetersPerSecond: location.speed,
            altitudeMeters: location.altitude,
            timestamp: location.timestamp
        )
        lastLocation = sample
        invalidateRequestAfterMaterialMotion(to: sample.coordinate)

        switch state {
        case .waitingForLocation:
            guard let pendingRecord,
                  location.horizontalAccuracy <= 100 else { return }
            prepare(pendingRecord, initialLocation: sample)
            return
        case .waitingForOnlineLocation:
            guard location.horizontalAccuracy <= 100,
                  let pendingFavorite else { return }
            requestInitialOnlineRoute(
                destination: pendingFavorite,
                source: sample
            )
            return
        default:
            break
        }
        guard runtime.route != nil else { return }
        do {
            let snapshot = try runtime.process(sample)
            publish(snapshot: snapshot, location: sample)
            if snapshot.offRouteDistanceMeters != nil {
                requestReroute(explicit: false)
            }
        } catch {
            state = .unavailable("Navigation unavailable")
        }
    }

    private func prepare(
        _ record: InstalledNavigationRouteV1,
        initialLocation: NavigationLocationSampleV1
    ) {
        do {
            var candidate = NavigationRuntimeV1()
            let assessment = try candidate.start(
                route: record.archive.route,
                contentHash: record.archive.contentHash,
                mode: pendingMode,
                initialLocation: initialLocation
            )
            if assessment.requiresConfirmation {
                runtime = candidate
            }
            if assessment.requiresConfirmation && !pendingAcceptsFarStart {
                state = .awaitingStartConfirmation(
                    routeID: record.archive.routeID,
                    distanceMeters: assessment.distanceToRouteStartMeters
                )
                return
            }
            activate(
                record,
                initialLocation: initialLocation,
                acceptsFarStart: assessment.requiresConfirmation
            )
        } catch {
            pendingAcceptsFarStart = false
            state = .unavailable("Route not installed on this Watch")
        }
    }

    private func activate(
        _ record: InstalledNavigationRouteV1,
        initialLocation: NavigationLocationSampleV1,
        acceptsFarStart: Bool
    ) {
        let identity = WatchRouteIdentityV1(archive: record.archive)
        var didActivate = false
        do {
            _ = try routeLibrary.activate(identity)
            didActivate = true
            if !acceptsFarStart {
                _ = try runtime.start(
                    route: record.archive.route,
                    contentHash: record.archive.contentHash,
                    mode: pendingMode,
                    initialLocation: initialLocation
                )
            } else {
                _ = try runtime.process(initialLocation)
            }
            activeRecord = record
            activeDestination = record.archive.route.destination
            routeAttribution = record.archive.route.provider.attribution
            pendingRecord = nil
            pendingAcceptsFarStart = false
            startedAt = now()
            guard let snapshot = runtime.snapshot else {
                throw NavigationRuntimeError.noActiveRoute
            }
            publish(
                snapshot: snapshot,
                location: initialLocation,
                forceJournal: true
            )
        } catch {
            if didActivate { routeLibrary.deactivate(identity) }
            pendingAcceptsFarStart = false
            state = .unavailable("Navigation unavailable")
        }
    }

    private func requestInitialOnlineRoute(
        destination: SyncedCoordinateFavoriteV1,
        source: NavigationLocationSampleV1
    ) {
        guard requestTask == nil,
              settingsStore.policy == .onlineAllowed else { return }
        let endpoint = RouteEndpointV1(
            coordinate: destination.coordinate,
            label: destination.name
        )
        let identity = beginRequest(origin: source.coordinate)
        onlineStatus = .calculating
        state = .requestingOnline(destinationID: destination.id)
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { finishRequest(identity) }
            guard isRequestCurrent(identity) else { return }
            do {
                let routes = try await onlineProvider.routes(for:
                    NavigationRouteRequestV1(
                        source: RouteEndpointV1(
                            coordinate: source.coordinate,
                            label: "Current Location"
                        ),
                        destination: endpoint,
                        localeIdentifier: Locale.current.identifier,
                        transportType: .cycling,
                        requestAlternatives: false
                    )
                )
                guard isRequestCurrent(identity) else { return }
                guard let route = routes.first,
                      route.provider == onlineProvider.metadata,
                      route.provider.storageScope == .activeOnly,
                      let currentLocation = lastLocation,
                      isUsableRoutingLocation(currentLocation) else {
                    state = .waitingForOnlineLocation(
                        destinationID: destination.id
                    )
                    onlineStatus = .waitingForLocation
                    return
                }
                _ = try runtime.start(
                    route: route,
                    mode: .online,
                    initialLocation: currentLocation
                )
                try? journalStore.clear()
                pendingFavorite = nil
                activeDestination = endpoint
                routeAttribution = route.provider.attribution
                startedAt = now()
                onlineStatus = .online
                guard let snapshot = runtime.snapshot else {
                    throw NavigationRuntimeError.noActiveRoute
                }
                publish(snapshot: snapshot, location: currentLocation)
            } catch is CancellationError {
                return
            } catch {
                guard isRequestCurrent(identity) else { return }
                onlineStatus = networkMonitor.availability == .unavailable
                    ? .noConnection
                    : .routeFailed
                state = .unavailable(
                    networkMonitor.availability == .unavailable
                        ? "No Watch internet connection"
                        : "Navigation unavailable"
                )
                locationService.setNavigationConsumer(
                    active: false,
                    handler: nil
                )
                deviceLink.endNavigationDemandAfterClearing()
            }
        }
    }

    private func requestReroute(explicit: Bool) {
        guard requestTask == nil,
              settingsStore.policy == .onlineAllowed,
              let activeDestination,
              let source = lastLocation,
              runtime.route != nil else { return }
        guard isUsableRoutingLocation(source) else {
            onlineStatus = .waitingForLocation
            return
        }
        guard explicit || networkMonitor.availability != .unavailable else {
            runtime.setMode(.onlineUsingCachedRoute)
            onlineStatus = .continuingCachedRoute
            publishCurrentSnapshot()
            return
        }
        if !explicit && !rerouteCooldown.canAttempt(at: now()) { return }
        if explicit { _ = rerouteCooldown.canAttempt(at: now(), interval: 0) }
        let identity = beginRequest(origin: source.coordinate)
        onlineStatus = .rerouting
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { finishRequest(identity) }
            guard isRequestCurrent(identity) else { return }
            do {
                let routes = try await onlineProvider.routes(for:
                    NavigationRouteRequestV1(
                        source: RouteEndpointV1(
                            coordinate: source.coordinate,
                            label: "Current Location"
                        ),
                        destination: activeDestination,
                        localeIdentifier: Locale.current.identifier,
                        transportType: .cycling,
                        requestAlternatives: false
                    )
                )
                guard isRequestCurrent(identity) else { return }
                guard let replacement = routes.first,
                      replacement.provider == onlineProvider.metadata,
                      replacement.provider.storageScope == .activeOnly,
                      let currentLocation = lastLocation,
                      isUsableRoutingLocation(currentLocation) else {
                    onlineStatus = .rerouteFailed
                    publishCurrentSnapshot()
                    return
                }
                var candidate = runtime
                let replacementSnapshot = try candidate.replaceRoute(
                    replacement,
                    mode: .online,
                    currentLocation: currentLocation
                )
                try journalStore.clear()
                runtime = candidate
                routeAttribution = replacement.provider.attribution
                if let activeRecord {
                    routeLibrary.deactivate(
                        WatchRouteIdentityV1(archive: activeRecord.archive)
                    )
                    self.activeRecord = nil
                }
                onlineStatus = .online
                publish(
                    snapshot: replacementSnapshot,
                    location: currentLocation
                )
            } catch is CancellationError {
                return
            } catch {
                guard isRequestCurrent(identity) else { return }
                runtime.setMode(
                    networkMonitor.availability == .unavailable
                        ? .onlineUsingCachedRoute
                        : .online
                )
                onlineStatus = networkMonitor.availability == .unavailable
                    ? .continuingCachedRoute
                    : .rerouteFailed
                publishCurrentSnapshot()
            }
        }
    }

    private func beginRequest(
        origin: RouteCoordinateV1
    ) -> WatchRouteRequestIdentityV1 {
        requestGeneration &+= 1
        if requestGeneration == 0 { requestGeneration = 1 }
        requestOrigin = origin
        return WatchRouteRequestIdentityV1(
            navigationGeneration: lifecycleGeneration,
            policyGeneration: settingsStore.policyGeneration,
            requestGeneration: requestGeneration,
            locationGeneration: requestLocationGeneration
        )
    }

    private func isRequestCurrent(
        _ identity: WatchRouteRequestIdentityV1
    ) -> Bool {
        identity.isCurrent(
            navigationGeneration: lifecycleGeneration,
            policyGeneration: settingsStore.policyGeneration,
            requestGeneration: requestGeneration,
            locationGeneration: requestLocationGeneration,
            policy: settingsStore.policy
        ) &&
            !Task.isCancelled
    }

    private func finishRequest(_ identity: WatchRouteRequestIdentityV1) {
        guard identity.requestGeneration == requestGeneration else { return }
        requestTask = nil
        requestOrigin = nil
    }

    private func invalidateRequestAfterMaterialMotion(
        to coordinate: RouteCoordinateV1
    ) {
        guard let requestOrigin,
              NavigationGeometryV1.distance(
                from: requestOrigin,
                to: coordinate
              ) > 100 else { return }
        requestLocationGeneration &+= 1
        if requestLocationGeneration == 0 { requestLocationGeneration = 1 }
        cancelRequest()
        if let pendingFavorite {
            state = .waitingForOnlineLocation(destinationID: pendingFavorite.id)
            onlineStatus = .waitingForLocation
        } else if runtime.route != nil {
            onlineStatus = networkMonitor.availability == .unavailable
                ? .continuingCachedRoute
                : .online
        }
    }

    private func cancelRequest() {
        requestGeneration &+= 1
        if requestGeneration == 0 { requestGeneration = 1 }
        onlineProvider.cancel()
        requestTask?.cancel()
        requestTask = nil
        requestOrigin = nil
    }

    private func policyDidChange(_ policy: RouteNetworkPolicyV1) {
        cancelRequest()
        guard runtime.route != nil else {
            if policy == .offlineOnly, pendingFavorite != nil {
                state = .unavailable("Online routing is disabled")
                onlineStatus = .offlinePolicy
                locationService.setNavigationConsumer(
                    active: false,
                    handler: nil
                )
                deviceLink.endNavigationDemandAfterClearing()
            } else if policy == .onlineAllowed, pendingFavorite != nil {
                state = .unavailable("Navigation unavailable")
                onlineStatus = networkMonitor.availability == .unavailable
                    ? .noConnection
                    : .routeFailed
            }
            return
        }
        if policy == .offlineOnly {
            runtime.setMode(.offline)
            onlineStatus = .offlinePolicy
        } else {
            runtime.setMode(
                networkMonitor.availability == .unavailable
                    ? .onlineUsingCachedRoute
                    : .online
            )
            onlineStatus = networkMonitor.availability == .unavailable
                ? .continuingCachedRoute
                : .online
        }
        publishCurrentSnapshot()
    }

    private func networkDidChange(_ availability: WatchNetworkAvailabilityV1) {
        guard settingsStore.policy == .onlineAllowed else { return }
        guard runtime.route != nil else {
            if pendingFavorite != nil, availability == .available {
                state = .unavailable("Navigation unavailable")
                onlineStatus = .routeFailed
            }
            return
        }
        switch availability {
        case .unavailable:
            runtime.setMode(.onlineUsingCachedRoute)
            onlineStatus = .continuingCachedRoute
            publishCurrentSnapshot()
        case .available:
            runtime.setMode(.online)
            onlineStatus = .online
            publishCurrentSnapshot()
            if snapshot?.offRouteDistanceMeters != nil {
                requestReroute(explicit: false)
            }
        case .unknown:
            break
        }
    }

    private func publish(
        snapshot: NavigationSnapshotV1,
        location: NavigationLocationSampleV1,
        forceJournal: Bool = false
    ) {
        self.snapshot = snapshot
        updateStateFromSnapshot(routeID: snapshot.routeID)
        deviceLink.updateNavigation(location: location, snapshot: snapshot)
        persistJournal(
            snapshot: snapshot,
            location: location,
            force: forceJournal
        )
    }

    private func publishCurrentSnapshot() {
        guard let snapshot = runtime.snapshot,
              let lastLocation else { return }
        publish(snapshot: snapshot, location: lastLocation)
    }

    private func updateStateFromSnapshot(routeID: UUID) {
        if let distance = runtime.snapshot?.offRouteDistanceMeters {
            state = .offRoute(routeID: routeID, distanceMeters: distance)
        } else {
            state = .navigating(routeID: routeID)
        }
    }

    private func persistJournal(
        snapshot: NavigationSnapshotV1,
        location: NavigationLocationSampleV1,
        force: Bool
    ) {
        guard let activeRecord, let startedAt else { return }
        let date = now()
        guard force ||
                snapshot.currentStepIndex != lastJournalStepIndex ||
                date.timeIntervalSince(lastJournalWriteAt) >= 15 else {
            return
        }
        let journalMode: NavigationModeV1 =
            settingsStore.policy == .offlineOnly
            ? .offline
            : .onlineUsingCachedRoute
        let journal = WatchNavigationJournalV1(
            identity: WatchRouteIdentityV1(archive: activeRecord.archive),
            mode: journalMode,
            navigationGeneration: snapshot.navigationGeneration,
            currentStepIndex: snapshot.currentStepIndex,
            lastLocation: WatchNavigationJournalLocationV1(location),
            startedAt: startedAt,
            updatedAt: date
        )
        do {
            try journalStore.save(journal)
            lastJournalWriteAt = date
            lastJournalStepIndex = snapshot.currentStepIndex
            recoveryError = nil
        } catch {
            recoveryError = "Navigation recovery state could not be saved"
        }
    }

    private func advanceLifecycleGeneration() {
        lifecycleGeneration &+= 1
        if lifecycleGeneration == 0 { lifecycleGeneration = 1 }
    }

    private func isUsableRoutingLocation(
        _ location: NavigationLocationSampleV1
    ) -> Bool {
        location.coordinate.isValid &&
            location.horizontalAccuracyMeters >= 0 &&
            location.horizontalAccuracyMeters <= 100 &&
            now().timeIntervalSince(location.timestamp) >= -5 &&
            now().timeIntervalSince(location.timestamp) <= 60
    }
}
