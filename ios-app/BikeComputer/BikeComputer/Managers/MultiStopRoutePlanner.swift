import Combine
import CoreLocation
import Foundation
import MapKit

/// A complete multi-stop calculation. The save draft is captured once, so
/// later edits or recalculation cannot swap geometry under the save sheet.
struct MultiStopRoutePlan: Identifiable {
    var id: UUID { route.id }
    let request: MultiStopRouteRequest
    /// Canonical MapKit legs, one per consecutive pair of stops.
    let legs: [NavigationRouteV1]
    /// The stitched active-only MapKit route shown in the preview.
    let route: NavigationRouteV1
    /// The same route with the explicit phone-only saved scope.
    let draft: OfflineRouteSaveDraft
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

/// Calculates Settings > Saved Routes > Create a Route plans, one MapKit leg
/// per pair of stops. It owns its directions requests and never touches the
/// coordinator's direct-navigation plan, rerouting or active navigation.
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
    private let limits: NavigationRouteLimitsV1
    private let now: () -> Date
    private var generation: UInt = 0
    private var activeDirections: (any NavigationDirectionsTask)?
    private var cachedLegs: [LegKey: NavigationRouteV1] = [:]
    private var cachedLegOrder: [LegKey] = []

    /// Instructions are localized, so a leg is only reused in its locale.
    private struct LegKey: Hashable {
        let source: RouteCoordinateV1
        let destination: RouteCoordinateV1
        let transportType: UInt
        let localeIdentifier: String
    }

    init(
        directionsFactory: @escaping NavigationDirectionsFactory = {
            MapKitNavigationDirectionsTask(request: $0)
        },
        limits: NavigationRouteLimitsV1 = .production,
        now: @escaping () -> Date = Date.init
    ) {
        self.directionsFactory = directionsFactory
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
        let legs = places.indices.dropLast().map { index in
            cachedLegs[legKey(
                from: places[index],
                to: places[index + 1],
                request: request,
                localeIdentifier: localeIdentifier
            )]
        }
        continueCalculation(
            request: request,
            localeIdentifier: localeIdentifier,
            legs: legs,
            generation: generation
        )
    }

    private func continueCalculation(
        request: MultiStopRouteRequest,
        localeIdentifier: String,
        legs: [NavigationRouteV1?],
        generation: UInt
    ) {
        guard generation == self.generation else { return }
        guard let index = legs.firstIndex(where: { $0 == nil }) else {
            finish(request: request, legs: legs.compactMap { $0 })
            return
        }
        state = .calculating(
            completedLegs: legs.filter { $0 != nil }.count,
            totalLegs: legs.count
        )
        let source = request.places[index]
        let destination = request.places[index + 1]
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = source.mapItem
        directionsRequest.destination = destination.mapItem
        directionsRequest.transportType = request.transportType
        directionsRequest.requestsAlternateRoutes = false

        let directions = directionsFactory(directionsRequest)
        activeDirections = directions
        directions.calculate { [weak self] result in
            guard let self, self.generation == generation,
                  self.activeDirections === directions else { return }
            self.activeDirections = nil
            switch result {
            case .failure(let error):
                self.state = .failed(.leg(
                    index: index,
                    message: Self.legFailureMessage(error, from: source, to: destination)
                ))
            case .success(let routes):
                guard let leg = Self.preferredLeg(
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
                self.store(leg, for: self.legKey(
                    from: source,
                    to: destination,
                    request: request,
                    localeIdentifier: localeIdentifier
                ))
                var legs = legs
                legs[index] = leg
                self.continueCalculation(
                    request: request,
                    localeIdentifier: localeIdentifier,
                    legs: legs,
                    generation: generation
                )
            }
        }
    }

    private func finish(request: MultiStopRouteRequest, legs: [NavigationRouteV1]) {
        do {
            let route = try MultiStopRouteStitcher.stitch(
                legs: legs,
                stopLabels: request.places.map(\.label),
                limits: limits
            )
            let createdAt = now()
            let draft = try OfflineRouteSaveDraft.plannedMapKit(route, createdAt: createdAt)
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
                draft: draft
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
        localeIdentifier: String
    ) -> LegKey {
        LegKey(
            source: source.mapCoordinate,
            destination: destination.mapCoordinate,
            transportType: request.transportType.rawValue,
            localeIdentifier: localeIdentifier
        )
    }

    private func store(_ leg: NavigationRouteV1, for key: LegKey) {
        cachedLegs[key] = leg
        cachedLegOrder.removeAll { $0 == key }
        cachedLegOrder.append(key)
        while cachedLegOrder.count > Self.maximumCachedLegs {
            cachedLegs[cachedLegOrder.removeFirst()] = nil
        }
    }

    /// The same preference as direct planning: fastest, then shortest, then
    /// MapKit's order, skipping any response that cannot be normalized safely.
    private static func preferredLeg(
        from routes: [MKRoute],
        source: MultiStopRoutePlace,
        destination: MultiStopRoutePlace,
        localeIdentifier: String
    ) -> NavigationRouteV1? {
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
                return leg
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
        from source: MultiStopRoutePlace,
        to destination: MultiStopRoutePlace
    ) -> String {
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
