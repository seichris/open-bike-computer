import CoreLocation
import Foundation
import MapKit

/// Apple Maps has no cycling directions in some regions, the UAE among them.
/// There a cycling request fails with `MKError.serverFailure`, and the error's
/// `MKDirectionsErrorCode` reports the area as out of coverage (8). A route
/// that does not exist between the points reports not reachable (16) with the
/// same `MKError` code (seen with macOS 26, iOS 26.5 and watchOS 27 MapKit;
/// the key is not documented). Only the out-of-coverage failure falls back to
/// car directions. Every other failure is reported as before, and if Apple
/// drops the key the rider just sees the cycling error again.
///
/// Avoiding highways and tolls is only a preference to MapKit: it still
/// returns faster alternatives on them. Car routes without highways or tolls
/// are therefore kept whenever there is one, and every car route's notice
/// says which of the two it uses.
///
/// The iPhone's directions and the Watch's own online routing both use it.
nonisolated enum CyclingDirectionsFallback {
    static let directionsErrorCodeKey = "MKDirectionsErrorCode"
    static let outOfCoverageCode = 8
    static let notReachableCode = 16
    /// MapKit's own cycling estimates average 15–16 km/h; car times would be
    /// two to three times too short for a bike.
    static let cyclingSpeedMetersPerSecond: CLLocationSpeed = 15_000 / 3_600

    static func isOutOfCoverage(_ error: Error) -> Bool {
        directionsErrorCode(of: error) == outOfCoverageCode
    }

    static func isNotReachable(_ error: Error) -> Bool {
        directionsErrorCode(of: error) == notReachableCode
    }

    static func usesCarDirections(
        after error: Error,
        requested transportType: MKDirectionsTransportType
    ) -> Bool {
        transportType == .cycling && isOutOfCoverage(error)
    }

    /// The same endpoints as car directions. Alternatives are always asked
    /// for, so that a route without highways or tolls can be found.
    static func carRequest(for request: MKDirections.Request) -> MKDirections.Request {
        let car = MKDirections.Request()
        car.source = request.source
        car.destination = request.destination
        car.requestsAlternateRoutes = true
        car.transportType = .automobile
        avoidHighwaysAndTolls(car)
        return car
    }

    static func avoidHighwaysAndTolls(_ request: MKDirections.Request) {
        request.highwayPreference = .avoid
        request.tollPreference = .avoid
    }

    /// The car routes a rider should be offered: those without highways or
    /// tolls when there is one, otherwise all of them; shortest first. A
    /// caller that wants one route takes the first, or the first it can use.
    static func cyclingFriendlyRoutes(
        from routes: [MKRoute]
    ) -> [CyclingFallbackCarRoute] {
        let car = routes.map { CyclingFallbackCarRoute($0) }
        let clear = car.filter { !$0.hasHighways && !$0.hasTolls }
        let ordered = (clear.isEmpty ? car : clear).enumerated().sorted {
            $0.element.distance != $1.element.distance
                ? $0.element.distance < $1.element.distance
                : $0.offset < $1.offset
        }.map(\.element)
        return ordered
    }

    static func notice(hasHighways: Bool, hasTolls: Bool) -> String {
        switch (hasHighways, hasTolls) {
        case (false, false):
            "No cycling directions here: car route without highways or tolls"
        case (true, false):
            "No cycling directions here: car route uses highways; check it suits a bike"
        case (false, true):
            "No cycling directions here: car route uses toll roads; check it suits a bike"
        case (true, true):
            "No cycling directions here: car route uses highways and toll roads; check it suits a bike"
        }
    }

    /// Create a Route's summary for a plan with car legs.
    static func planNotice(
        carLegs: Int,
        totalLegs: Int,
        carLegsWithHighwaysOrTolls: Int
    ) -> String {
        let scope = carLegs == totalLegs
            ? "No cycling directions here"
            : "No cycling directions for \(carLegs) of \(totalLegs) legs"
        guard carLegsWithHighwaysOrTolls > 0 else {
            return "\(scope): car directions without highways or tolls"
        }
        let affected = carLegsWithHighwaysOrTolls == 1
            ? "1 car leg uses"
            : "\(carLegsWithHighwaysOrTolls) car legs use"
        return "\(scope): car directions; \(affected) highways or toll roads, check they suit a bike"
    }

    static func cyclingTravelTime(forDistance distance: CLLocationDistance) -> TimeInterval {
        distance.isFinite && distance > 0 ? distance / cyclingSpeedMetersPerSecond : 0
    }

    /// A car failure the rider can act on (connection, Apple Maps busy) is
    /// worth reporting instead of the cycling failure; a car request that
    /// found no route is not.
    static func isTransient(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return true }
        guard error.domain == MKErrorDomain else { return false }
        if error.code == Int(MKError.Code.loadingThrottled.rawValue) { return true }
        return error.code == Int(MKError.Code.serverFailure.rawValue) &&
            directionsErrorCode(of: error) == nil
    }

    private static func directionsErrorCode(of error: Error) -> Int? {
        let error = error as NSError
        guard error.domain == MKErrorDomain else { return nil }
        return (error.userInfo[directionsErrorCodeKey] as? NSNumber)?.intValue
    }
}

/// A car route standing in for unavailable cycling directions. It keeps
/// MapKit's geometry and instructions, gives the travel time at a cycling
/// pace, and carries its own notice in place of MapKit's car advice, so the
/// preview, the ride's remaining time and saved routes all agree.
nonisolated final class CyclingFallbackCarRoute: MKRoute {
    let base: MKRoute

    init(_ base: MKRoute) {
        self.base = base
        super.init()
    }

    override var name: String { base.name }
    override var advisoryNotices: [String] {
        [CyclingDirectionsFallback.notice(
            hasHighways: base.hasHighways,
            hasTolls: base.hasTolls
        )]
    }
    override var distance: CLLocationDistance { base.distance }
    override var expectedTravelTime: TimeInterval {
        CyclingDirectionsFallback.cyclingTravelTime(forDistance: base.distance)
    }
    override var transportType: MKDirectionsTransportType { base.transportType }
    override var polyline: MKPolyline { base.polyline }
    override var steps: [MKRoute.Step] { base.steps }
    override var hasTolls: Bool { base.hasTolls }
    override var hasHighways: Bool { base.hasHighways }
}
