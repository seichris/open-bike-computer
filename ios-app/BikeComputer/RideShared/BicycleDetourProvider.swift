import CoreLocation
import Foundation
import MapKit

nonisolated enum BicycleDetourUnavailableReasonV1: Equatable, Sendable {
    case offline
    case serviceError
}

/// What a detour provider answered.
nonisolated enum BicycleDetourOutcomeV1: Equatable {
    case route(NavigationRouteV1)
    /// This provider has no bicycle route for the request (for MapKit: out of
    /// cycling coverage, not reachable, or no directions found).
    case noBicycleRoute
    case unavailable(BicycleDetourUnavailableReasonV1, retryAfterSeconds: Int?)
    case cancelled
}

/// One detour question: the rider and a single rejoin point. Nothing else of
/// the saved route leaves the device.
nonisolated struct BicycleDetourQueryV1: Equatable, Sendable {
    let origin: RouteCoordinateV1
    let originCourseDegrees: Double?
    let rejoin: RouteCoordinateV1
    /// Provenance of the saved route: "gpx", "strava" or "mapkit".
    let routeSource: String
    let localeIdentifier: String

    init(
        request: SavedRouteDetourRequestV1,
        routeSource: String,
        localeIdentifier: String
    ) {
        origin = request.origin
        originCourseDegrees = request.originCourseDegrees
        rejoin = request.target.coordinate
        self.routeSource = routeSource
        self.localeIdentifier = localeIdentifier
    }

    init(
        origin: RouteCoordinateV1,
        originCourseDegrees: Double?,
        rejoin: RouteCoordinateV1,
        routeSource: String,
        localeIdentifier: String
    ) {
        self.origin = origin
        self.originCourseDegrees = originCourseDegrees
        self.rejoin = rejoin
        self.routeSource = routeSource
        self.localeIdentifier = localeIdentifier
    }
}

@MainActor
protocol BicycleDetourProviding: AnyObject {
    func detour(for query: BicycleDetourQueryV1) async -> BicycleDetourOutcomeV1
    func cancel()
}

/// One MapKit directions calculation. Tests replace it.
@MainActor
protocol BicycleDetourDirectionsCalculating: AnyObject {
    func calculate() async throws -> [MKRoute]
    func cancel()
}

typealias BicycleDetourDirectionsFactory =
    @MainActor (MKDirections.Request) -> any BicycleDetourDirectionsCalculating

@MainActor
final class MapKitBicycleDetourDirections: BicycleDetourDirectionsCalculating {
    private let directions: MKDirections

    init(request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    func calculate() async throws -> [MKRoute] {
        try await directions.calculate().routes
    }

    func cancel() {
        directions.cancel()
    }
}

/// Apple MapKit cycling directions only. It never asks for car directions:
/// a saved-route detour is for a bicycle, and a missing cycling route is
/// reported as `noBicycleRoute` so the chain can ask the bicycle service.
@MainActor
final class MapKitCyclingDetourProvider: BicycleDetourProviding {
    private let directionsFactory: BicycleDetourDirectionsFactory
    private var activeDirections: (any BicycleDetourDirectionsCalculating)?
    /// A cancelled MapKit request can still finish with the out-of-coverage
    /// error; it must not then lead to a second request.
    private var cancellationGeneration: UInt64 = 0

    init(directionsFactory: @escaping BicycleDetourDirectionsFactory = {
        MapKitBicycleDetourDirections(request: $0)
    }) {
        self.directionsFactory = directionsFactory
    }

    func detour(for query: BicycleDetourQueryV1) async -> BicycleDetourOutcomeV1 {
        cancel()
        let generation = cancellationGeneration
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: query.origin, name: "Current Location")
        request.destination = Self.mapItem(for: query.rejoin, name: SavedRouteDetourRouteV1.destinationLabel)
        request.transportType = .cycling
        request.requestsAlternateRoutes = false
        let directions = directionsFactory(request)
        activeDirections = directions
        defer {
            if activeDirections === directions { activeDirections = nil }
        }
        do {
            let routes = try await directions.calculate()
            guard generation == cancellationGeneration, !Task.isCancelled else { return .cancelled }
            guard let first = routes.first,
                  let route = try? MapKitNavigationRouteAdapterV1.route(
                    from: first,
                    source: query.origin,
                    sourceLabel: "Current Location",
                    destinationLabel: SavedRouteDetourRouteV1.destinationLabel,
                    localeIdentifier: query.localeIdentifier
                  ) else {
                return .noBicycleRoute
            }
            return .route(route)
        } catch {
#if DEBUG
            let debugError = error as NSError
            print("DETOUR_EVIDENCE mapkit cycling error domain=\(debugError.domain) code=\(debugError.code) MKDirectionsErrorCode=\((debugError.userInfo[CyclingDirectionsFallback.directionsErrorCodeKey] as? NSNumber)?.intValue ?? -1)")
#endif
            guard generation == cancellationGeneration, !Task.isCancelled else { return .cancelled }
            if Self.meansNoCyclingRoute(error) { return .noBicycleRoute }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return .unavailable(.offline, retryAfterSeconds: nil) }
            return .unavailable(.serviceError, retryAfterSeconds: nil)
        }
    }

    func cancel() {
        cancellationGeneration &+= 1
        activeDirections?.cancel()
        activeDirections = nil
    }

    /// The actual MapKit result decides the fallback; there is no country list.
    nonisolated static func meansNoCyclingRoute(_ error: Error) -> Bool {
        if CyclingDirectionsFallback.isOutOfCoverage(error) || CyclingDirectionsFallback.isNotReachable(error) {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == MKErrorDomain &&
            nsError.code == Int(MKError.Code.directionsNotFound.rawValue)
    }

    private static func mapItem(for coordinate: RouteCoordinateV1, name: String) -> MKMapItem {
        let mapCoordinate = RouteCoordinateNormalizationV1.wgs84ToMapKit(coordinate)
        let location = CLLocation(latitude: mapCoordinate.latitude, longitude: mapCoordinate.longitude)
        let item: MKMapItem
        if #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
            item = MKMapItem(location: location, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        }
        item.name = name
        return item
    }
}

/// Sends one detour request body to the Bicino service and returns the HTTP
/// answer: the iPhone's authenticated service session, the Watch's relay
/// through its iPhone, or a test double.
@MainActor
protocol BicycleDetourServiceTransporting: AnyObject {
    func post(_ request: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1
}

/// The Bicino Valhalla bicycle service, asked only after MapKit had no
/// cycling route. It receives the rider position and one rejoin point.
@MainActor
final class BicinoBicycleDetourProvider: BicycleDetourProviding {
    private let transport: BicycleDetourServiceTransporting
    private var generation: UInt64 = 0
    private(set) var lastRequest: BicycleDetourServiceRequestV1?

    init(transport: BicycleDetourServiceTransporting) {
        self.transport = transport
    }

    func detour(for query: BicycleDetourQueryV1) async -> BicycleDetourOutcomeV1 {
        generation &+= 1
        let current = generation
        let request = BicycleDetourServiceRequestV1(
            origin: query.origin,
            courseDegrees: query.originCourseDegrees,
            rejoin: query.rejoin,
            routeSource: query.routeSource,
            localeIdentifier: query.localeIdentifier
        )
        lastRequest = request
        do {
            let response = try await transport.post(request)
            guard current == generation, !Task.isCancelled else { return .cancelled }
            return BicycleDetourServiceDecoderV1.outcome(for: response, localeIdentifier: query.localeIdentifier)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError {
            guard current == generation else { return .cancelled }
            switch error.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return .unavailable(.offline, retryAfterSeconds: nil)
            default:
                return .unavailable(.serviceError, retryAfterSeconds: nil)
            }
        } catch {
            guard current == generation else { return .cancelled }
            return .unavailable(.serviceError, retryAfterSeconds: nil)
        }
    }

    func cancel() {
        generation &+= 1
    }
}

/// MapKit cycling first; the bicycle service only when MapKit answered that
/// it has no cycling route for this request. Transient MapKit failures do not
/// fall through, and nothing here ever asks for driving directions.
@MainActor
final class BicycleDetourProviderChainV1: BicycleDetourProviding {
    private let mapKit: BicycleDetourProviding
    private let fallback: BicycleDetourProviding?
    private var generation: UInt64 = 0
    private(set) var lastMapKitOutcome: BicycleDetourOutcomeV1?

    init(mapKit: BicycleDetourProviding, fallback: BicycleDetourProviding?) {
        self.mapKit = mapKit
        self.fallback = fallback
    }

    func detour(for query: BicycleDetourQueryV1) async -> BicycleDetourOutcomeV1 {
        generation &+= 1
        let current = generation
        let first = await mapKit.detour(for: query)
        lastMapKitOutcome = first
        guard current == generation, !Task.isCancelled else { return .cancelled }
        guard case .noBicycleRoute = first, let fallback else { return first }
        let second = await fallback.detour(for: query)
        guard current == generation, !Task.isCancelled else { return .cancelled }
        return second
    }

    func cancel() {
        generation &+= 1
        mapKit.cancel()
        fallback?.cancel()
    }
}
