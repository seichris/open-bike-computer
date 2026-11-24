import Combine
import CoreLocation
import Foundation
import MapKit

/// A complete multi-stop calculation. The save draft is captured once, so
/// later edits or recalculation cannot swap geometry under the save sheet.
struct MultiStopRoutePlan: Identifiable {
    var id: UUID { route.id }
    let request: MultiStopRouteRequest
    /// Canonical legs, one per consecutive pair of stops: all from Bicino's
    /// bicycle route service or all from Apple Maps.
    let legs: [NavigationRouteV1]
    /// The stitched active-only route shown in the preview.
    let route: NavigationRouteV1
    /// The same route with the explicit phone-only saved scope.
    let draft: OfflineRouteSaveDraft
    /// Legs that are car directions because Apple Maps has no cycling
    /// directions there (`CyclingDirectionsFallback`).
    let carDirectionLegs: [Int]
    /// The car legs among them that use highways or toll roads.
    let carDirectionLegsWithHighwaysOrTolls: [Int]
    /// Set when a Road, Gravel or Everyday request was answered by Apple
    /// Maps cycling directions instead of Bicino's bicycle route service.
    let bicycleProfileNotice: String?

    var usesBicycleRouteService: Bool {
        route.provider == RouteProviderPolicyV1.valhallaDetour
    }

    var usesCarDirections: Bool { !carDirectionLegs.isEmpty }

    var carDirectionsNotice: String? {
        guard usesCarDirections else { return nil }
        return CyclingDirectionsFallback.planNotice(
            carLegs: carDirectionLegs.count,
            totalLegs: legs.count,
            carLegsWithHighwaysOrTolls: carDirectionLegsWithHighwaysOrTolls.count
        )
    }
}

enum MultiStopRoutePlanFailure: Equatable {
    case leg(index: Int, message: String)
    case route(message: String)

    var message: String {
        switch self {
        case .leg(_, let message), .route(let message): message
        }
    }

    var legIndex: Int? {
        if case .leg(let index, _) = self { return index }
        return nil
    }
}

/// Calculates Create a Route plans, one leg per pair of stops. Road, Gravel
/// and Everyday ask Bicino's bicycle route service for every leg; where it
/// has no route, or is not offered, the whole plan uses Apple Maps cycling
/// directions instead, so a plan never mixes providers. Drive and Walk use
/// Apple Maps. It owns its requests and never touches the coordinator's
/// direct-navigation plan, rerouting or active navigation.
@MainActor
final class MultiStopRoutePlanner: ObservableObject {
    enum State {
        case idle
        case calculating(completedLegs: Int, totalLegs: Int)
        case ready(MultiStopRoutePlan)
        case failed(MultiStopRoutePlanFailure)
    }

    static let maximumCachedLegs = 32

    @Published private(set) var state: State = .idle
    private(set) var request: MultiStopRouteRequest?

    private let directionsFactory: NavigationDirectionsFactory
    private let bicycleRoutes: BicycleRouteServicing?
    private let limits: NavigationRouteLimitsV1
    private let now: () -> Date
    private var generation: UInt = 0
    private var activeDirections: (any NavigationDirectionsTask)?
    private var activeServiceTask: Task<Void, Never>?
    private var cachedLegs: [LegKey: PlannedLeg] = [:]
    private var cachedLegOrder: [LegKey] = []
    /// A bicycle-profile request that Apple Maps answers instead, and why.
    private var appleFallback: (request: MultiStopRouteRequest, reason: AppleFallbackReason)?

    private enum AppleFallbackReason {
        case noBicycleRoute
        case notOffered
        case legTooLong

        /// Asking again could answer differently, so a new plan asks again.
        var isTransient: Bool { self == .notOffered }
    }

    /// Where a plan's legs come from.
    private enum LegSource: Equatable {
        case bicycleService(BicycleRouteProfileV1)
        case mapKit

        var profile: String? {
            if case .bicycleService(let profile) = self { return profile.rawValue }
            return nil
        }
    }

    /// A calculated leg and whether it is car directions standing in for
    /// unavailable cycling directions, and if so whether that car route uses
    /// highways or toll roads.
    private struct PlannedLeg {
        let route: NavigationRouteV1
        let usesCarDirections: Bool
        let usesHighwaysOrTolls: Bool
    }

    /// Instructions are localized, so a leg is only reused in its locale, and
    /// a bicycle service leg only for its profile.
    private struct LegKey: Hashable {
        let source: RouteCoordinateV1
        let destination: RouteCoordinateV1
        let transportType: UInt
        let profile: String?
        let localeIdentifier: String
    }

    init(
        directionsFactory: @escaping NavigationDirectionsFactory = {
            MapKitNavigationDirectionsTask(request: $0)
        },
        bicycleRoutes: BicycleRouteServicing? = nil,
        limits: NavigationRouteLimitsV1 = .production,
        now: @escaping () -> Date = Date.init
    ) {
        self.directionsFactory = directionsFactory
        self.bicycleRoutes = bicycleRoutes
        self.limits = limits
        self.now = now
    }

    var readyPlan: MultiStopRoutePlan? {
        if case .ready(let plan) = state { return plan }
        return nil
    }

    var failure: MultiStopRoutePlanFailure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }

    /// Starts calculating `request`, replacing any other calculation. The same
    /// request is left alone while it runs, after it succeeds and after it
    /// fails; a failed request is only repeated by `retry()`. `nil` cancels.
    func plan(_ request: MultiStopRouteRequest?) {
        guard let request else {
            cancel()
            return
        }
        if request == self.request, !isIdle { return }
        // Only this plan's own recalculation keeps a transient fallback.
        if appleFallback?.reason.isTransient == true { appleFallback = nil }
        start(request)
    }

    /// Recalculates the current request. Legs that already succeeded are
    /// reused, so only the failed leg and those after it are requested again.
    func retry() {
        guard let request else { return }
        start(request)
    }

    func cancel() {
        invalidate()
        request = nil
        appleFallback = nil
        state = .idle
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private func invalidate() {
        generation &+= 1
        activeDirections?.cancel()
        activeDirections = nil
        if let activeServiceTask {
            activeServiceTask.cancel()
            bicycleRoutes?.cancel()
        }
        activeServiceTask = nil
    }

    private func start(_ request: MultiStopRouteRequest) {
        invalidate()
        self.request = request
        let places = request.places
        guard (MultiStopRouteDraft.minimumStops...MultiStopRouteDraft.maximumStops)
            .contains(places.count) else {
            state = .failed(.route(
                message: "Choose between \(MultiStopRouteDraft.minimumStops) and \(MultiStopRouteDraft.maximumStops) stops."
            ))
            return
        }
        let localeIdentifier = Locale.current.identifier
        let source = legSource(for: request)
        let legs = places.indices.dropLast().map { index in
            cachedLegs[legKey(
                from: places[index],
                to: places[index + 1],
                request: request,
                source: source,
                localeIdentifier: localeIdentifier
            )]
        }
        continueCalculation(
            request: request,
            source: source,
            localeIdentifier: localeIdentifier,
            legs: legs,
            generation: generation
        )
    }

    /// The bicycle service for a profile request it can answer; Apple Maps
    /// otherwise. A leg the service would refuse as too long sends the whole
    /// plan to Apple Maps before any request.
    private func legSource(for request: MultiStopRouteRequest) -> LegSource {
        guard let profile = request.bicycleProfile, bicycleRoutes != nil else { return .mapKit }
        if appleFallback?.request == request { return .mapKit }
        let places = request.places
        let tooLong = places.indices.dropLast().contains { index in
            NavigationGeometryV1.distance(
                from: places[index].wgs84Coordinate,
                to: places[index + 1].wgs84Coordinate
            ) > BicycleRouteServiceContractV1.maximumSeparationMeters
        }
        if tooLong {
            appleFallback = (request, .legTooLong)
            return .mapKit
        }
        return .bicycleService(profile)
    }

    private func continueCalculation(
        request: MultiStopRouteRequest,
        source legSource: LegSource,
        localeIdentifier: String,
        legs: [PlannedLeg?],
        generation: UInt
    ) {
        guard generation == self.generation else { return }
        guard let index = legs.firstIndex(where: { $0 == nil }) else {
            finish(request: request, source: legSource, legs: legs.compactMap { $0 })
            return
        }
        state = .calculating(
            completedLegs: legs.filter { $0 != nil }.count,
            totalLegs: legs.count
        )
        if case .bicycleService(let profile) = legSource {
            requestServiceLeg(
                index: index,
                profile: profile,
                request: request,
                localeIdentifier: localeIdentifier,
                legs: legs,
                generation: generation
            )
            return
        }
        let source = request.places[index]
        let destination = request.places[index + 1]
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = source.mapItem
        directionsRequest.destination = destination.mapItem
        directionsRequest.transportType = request.transportType
        directionsRequest.requestsAlternateRoutes = false

        let directions = CyclingFallbackDirectionsTask(
            request: directionsRequest,
            factory: directionsFactory
        )
        activeDirections = directions
        directions.calculate { [weak self] result in
            guard let self, self.generation == generation,
                  self.activeDirections === directions else { return }
            self.activeDirections = nil
            switch result {
            case .failure(let error):
                self.state = .failed(.leg(
                    index: index,
                    message: Self.legFailureMessage(
                        error,
                        transportType: request.transportType,
                        from: source,
                        to: destination
                    )
                ))
            case .success(let routes):
                guard let (leg, mapKitRoute) = Self.preferredLeg(
                    from: routes,
                    source: source,
                    destination: destination,
                    localeIdentifier: localeIdentifier
                ) else {
                    self.state = .failed(.leg(
                        index: index,
                        message: Self.noRouteMessage(from: source, to: destination)
                    ))
                    return
                }
                let usesCarDirections = mapKitRoute is CyclingFallbackCarRoute
                let planned = PlannedLeg(
                    route: leg,
                    usesCarDirections: usesCarDirections,
                    usesHighwaysOrTolls: usesCarDirections &&
                        (mapKitRoute.hasHighways || mapKitRoute.hasTolls)
                )
                self.store(planned, for: self.legKey(
                    from: source,
                    to: destination,
                    request: request,
                    source: .mapKit,
                    localeIdentifier: localeIdentifier
                ))
                var legs = legs
                legs[index] = planned
                self.continueCalculation(
                    request: request,
                    source: .mapKit,
                    localeIdentifier: localeIdentifier,
                    legs: legs,
                    generation: generation
                )
            }
        }
    }

    /// One leg from Bicino's bicycle route service. No route, a service that
    /// is not offered or an unusable answer recalculates the whole plan with
    /// Apple Maps, so bike routes never depend on the service working;
    /// offline and busy stop with a retryable leg failure.
    private func requestServiceLeg(
        index: Int,
        profile: BicycleRouteProfileV1,
        request: MultiStopRouteRequest,
        localeIdentifier: String,
        legs: [PlannedLeg?],
        generation: UInt
    ) {
        guard let bicycleRoutes else { return }
        let source = request.places[index]
        let destination = request.places[index + 1]
        let query = BicycleRouteQueryV1(
            origin: source.wgs84Coordinate,
            destination: destination.wgs84Coordinate,
            originLabel: source.label,
            destinationLabel: destination.label,
            profile: profile,
            localeIdentifier: localeIdentifier
        )
        activeServiceTask = Task { [weak self] in
            let outcome = await bicycleRoutes.route(for: query)
            guard let self, self.generation == generation else { return }
            self.activeServiceTask = nil
            switch outcome {
            case .route(let leg):
                guard leg.provider == RouteProviderPolicyV1.valhallaDetour,
                      leg.transportType == .cycling else {
                    self.appleFallback = (request, .notOffered)
                    self.start(request)
                    return
                }
                let planned = PlannedLeg(route: leg, usesCarDirections: false, usesHighwaysOrTolls: false)
                self.store(planned, for: self.legKey(
                    from: source,
                    to: destination,
                    request: request,
                    source: .bicycleService(profile),
                    localeIdentifier: localeIdentifier
                ))
                var legs = legs
                legs[index] = planned
                self.continueCalculation(
                    request: request,
                    source: .bicycleService(profile),
                    localeIdentifier: localeIdentifier,
                    legs: legs,
                    generation: generation
                )
            case .noBicycleRoute:
                self.appleFallback = (request, .noBicycleRoute)
                self.start(request)
            case .notOffered, .failed, .cancelled:
                // A cancellation this planner did not ask for (it would have
                // changed the generation), such as a rejected trust check.
                self.appleFallback = (request, .notOffered)
                self.start(request)
            case .offline:
                self.state = .failed(.leg(
                    index: index,
                    message: "Bicino's route service could not be reached. Check your connection, then try again."
                ))
            case .busy:
                self.state = .failed(.leg(
                    index: index,
                    message: "Bicino's route service is busy. Wait a moment, then try again."
                ))
            }
        }
    }

    private func bicycleProfileNotice(
        for request: MultiStopRouteRequest,
        source: LegSource
    ) -> String? {
        guard let profile = request.bicycleProfile, source == .mapKit else { return nil }
        let reason = appleFallback?.request == request ? appleFallback?.reason : .notOffered
        switch reason ?? .notOffered {
        case .noBicycleRoute:
            return "\(profile.title) routing isn't available here, so this route uses Apple Maps cycling directions."
        case .notOffered:
            return "\(profile.title) routing isn't available right now, so this route uses Apple Maps cycling directions."
        case .legTooLong:
            return "A leg is longer than 150 km, so this route uses Apple Maps cycling directions."
        }
    }

    private func finish(
        request: MultiStopRouteRequest,
        source: LegSource,
        legs plannedLegs: [PlannedLeg]
    ) {
        let legs = plannedLegs.map(\.route)
        do {
            let route = try MultiStopRouteStitcher.stitch(
                legs: legs,
                stopLabels: request.places.map(\.label),
                limits: limits
            )
            let createdAt = now()
            let draft = try OfflineRouteSaveDraft.plannedRoute(route, createdAt: createdAt)
            // Reject a plan the library could not store before offering Save.
            _ = try draft.archive.encoded(
                purpose: .offlineNavigation,
                now: createdAt,
                limits: limits
            )
            state = .ready(MultiStopRoutePlan(
                request: request,
                legs: legs,
                route: route,
                draft: draft,
                carDirectionLegs: plannedLegs.indices.filter {
                    plannedLegs[$0].usesCarDirections
                },
                carDirectionLegsWithHighwaysOrTolls: plannedLegs.indices.filter {
                    plannedLegs[$0].usesHighwaysOrTolls
                },
                bicycleProfileNotice: bicycleProfileNotice(for: request, source: source)
            ))
        } catch let error as MultiStopRouteStitchError {
            state = .failed(.route(message: error.localizedDescription))
        } catch NavigationRouteArchiveError.encodedSizeExceeded {
            state = .failed(.route(
                message: MultiStopRouteStitchError.tooLong.localizedDescription
            ))
        } catch {
            state = .failed(.route(
                message: MultiStopRouteStitchError.invalidLegs.localizedDescription
            ))
        }
    }

    private func legKey(
        from source: MultiStopRoutePlace,
        to destination: MultiStopRoutePlace,
        request: MultiStopRouteRequest,
        source legSource: LegSource,
        localeIdentifier: String
    ) -> LegKey {
        LegKey(
            source: source.mapCoordinate,
            destination: destination.mapCoordinate,
            transportType: request.transportType.rawValue,
            profile: legSource.profile,
            localeIdentifier: localeIdentifier
        )
    }

    private func store(_ leg: PlannedLeg, for key: LegKey) {
        cachedLegs[key] = leg
        cachedLegOrder.removeAll { $0 == key }
        cachedLegOrder.append(key)
        while cachedLegOrder.count > Self.maximumCachedLegs {
            cachedLegs[cachedLegOrder.removeFirst()] = nil
        }
    }

    /// The same preference as direct planning: fastest, then shortest, then
    /// MapKit's order, skipping any response that cannot be normalized safely.
    /// Returns the canonical leg and the MapKit route it came from.
    private static func preferredLeg(
        from routes: [MKRoute],
        source: MultiStopRoutePlace,
        destination: MultiStopRoutePlace,
        localeIdentifier: String
    ) -> (NavigationRouteV1, MKRoute)? {
        let ordered = routes.enumerated().sorted { lhs, rhs in
            if lhs.element.expectedTravelTime != rhs.element.expectedTravelTime {
                return lhs.element.expectedTravelTime < rhs.element.expectedTravelTime
            }
            if lhs.element.distance != rhs.element.distance {
                return lhs.element.distance < rhs.element.distance
            }
            return lhs.offset < rhs.offset
        }
        for candidate in ordered {
            if let leg = try? MapKitRouteAdapter.route(
                from: candidate.element,
                fallbackSource: source.wgs84Coordinate,
                sourceLabel: source.label,
                destinationLabel: destination.label,
                localeIdentifier: localeIdentifier
            ) {
                return (leg, candidate.element)
            }
        }
        return nil
    }

    private static func noRouteMessage(
        from source: MultiStopRoutePlace,
        to destination: MultiStopRoutePlace
    ) -> String {
        "No route was found from \(source.label) to \(destination.label)."
    }

    private static func legFailureMessage(
        _ error: Error,
        transportType: MKDirectionsTransportType,
        from source: MultiStopRoutePlace,
        to destination: MultiStopRoutePlace
    ) -> String {
        // Apple Maps reports these directions failures with the server-failure
        // code, so they are told apart before it (CyclingDirectionsFallback).
        if CyclingDirectionsFallback.isOutOfCoverage(error) {
            return transportType == RouteTransportTypes.cycling
                ? "Apple Maps has no cycling directions here and found no car route from \(source.label) to \(destination.label)."
                : "Apple Maps has no directions for this travel mode from \(source.label) to \(destination.label)."
        }
        if CyclingDirectionsFallback.isNotReachable(error) {
            return noRouteMessage(from: source, to: destination)
        }
        if let mapError = error as? MKError {
            switch mapError.code {
            case .loadingThrottled:
                return "Apple Maps is busy. Wait a moment, then try again."
            case .serverFailure:
                return "Apple Maps could not be reached. Check your connection, then try again."
            default:
                break
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Apple Maps could not be reached. Check your connection, then try again."
        }
        return noRouteMessage(from: source, to: destination)
    }
}

/// Resolves a picked search completion, or name-only history, to a MapKit
/// coordinate before it becomes a stop. Only the newest pick can complete; an
/// older response is discarded and its MapKit search is cancelled.
@MainActor
final class RouteStopPlaceResolver: ObservableObject {
    typealias Execute = @MainActor (MKLocalSearch) async throws -> [MKMapItem]

    @Published private(set) var pendingID: String?
    @Published private(set) var errorMessage: String?

    private let execute: Execute
    private var activeSearch: MKLocalSearch?
    private var task: Task<Void, Never>?
    private var generation: UInt = 0

    init(execute: @escaping Execute = { try await $0.start().mapItems }) {
        self.execute = execute
    }

    func resolve(
        _ request: MKLocalSearch.Request,
        id: String,
        label: String,
        subtitle: String? = nil,
        origin: MultiStopRoutePlace.Origin,
        onResolved: @escaping (MultiStopRoutePlace) -> Void
    ) {
        cancel()
        let generation = generation
        let search = MKLocalSearch(request: request)
        activeSearch = search
        pendingID = id
        errorMessage = nil
        task = Task { [weak self, execute] in
            let items = try? await execute(search)
            guard let self, self.generation == generation else { return }
            self.activeSearch = nil
            self.task = nil
            self.pendingID = nil
            guard let item = items?.first,
                  let place = MultiStopRoutePlace(
                      label: label,
                      subtitle: subtitle,
                      mapCoordinate: Self.coordinate(of: item),
                      origin: origin
                  ) else {
                self.errorMessage = "That place could not be found. Try a different search."
                return
            }
            onResolved(place)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        activeSearch?.cancel()
        activeSearch = nil
        pendingID = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, macOS 26.0, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }
}
