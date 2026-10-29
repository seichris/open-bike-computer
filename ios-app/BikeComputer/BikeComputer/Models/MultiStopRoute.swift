import CoreLocation
import Foundation
import MapKit

/// One place picked in Settings > Saved Routes > Create a Route.
///
/// `mapCoordinate` is in MapKit's routing space (GCJ-02 inside mainland China),
/// exactly as MapKit search, a saved map pin or a converted GPS fix supplies
/// it. Canonical WGS-84 geometry only exists after MapKitRouteAdapter has
/// normalized a calculated leg; this value is never written to an archive.
struct MultiStopRoutePlace: Equatable {
    enum Origin: Equatable {
        case currentLocation
        case search
        case saved(SavedDestination)
    }

    static let maximumLabelBytes = 256
    static let currentLocationLabel = "Current Location"

    let label: String
    let subtitle: String?
    let mapCoordinate: RouteCoordinateV1
    let origin: Origin

    init?(
        label: String,
        subtitle: String? = nil,
        mapCoordinate: CLLocationCoordinate2D,
        origin: Origin
    ) {
        let label = MultiStopRouteNaming.clamped(
            label.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumUTF8Bytes: Self.maximumLabelBytes
        )
        let coordinate = RouteCoordinateV1(
            latitude: mapCoordinate.latitude,
            longitude: mapCoordinate.longitude
        )
        guard !label.isEmpty, coordinate.isValid,
              CLLocationCoordinate2DIsValid(mapCoordinate) else { return nil }
        let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label
        self.subtitle = subtitle?.isEmpty == false ? subtitle : nil
        self.mapCoordinate = coordinate
        self.origin = origin
    }

    /// Snapshots a GPS fix once, converted like the existing planner's
    /// "Your Location", so later fixes cannot silently move a planned stop.
    static func currentLocation(_ location: CLLocation) -> MultiStopRoutePlace? {
        guard location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: location)
        return MultiStopRoutePlace(
            label: currentLocationLabel,
            mapCoordinate: routeLocation.coordinate,
            origin: .currentLocation
        )
    }

    /// Favorites and recents keep MapKit coordinates from the map or search.
    /// Name-only history must be resolved by search before it becomes a stop.
    static func saved(_ destination: SavedDestination) -> MultiStopRoutePlace? {
        guard let coordinate = destination.coordinate else { return nil }
        return MultiStopRoutePlace(
            label: destination.name,
            mapCoordinate: coordinate,
            origin: .saved(destination)
        )
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: mapCoordinate.latitude,
            longitude: mapCoordinate.longitude
        )
    }

    var mapItem: MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, macOS 26.0, *) {
            item = MKMapItem(
                location: CLLocation(
                    latitude: mapCoordinate.latitude,
                    longitude: mapCoordinate.longitude
                ),
                address: nil
            )
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: clCoordinate))
        }
        item.name = label
        return item
    }
}

struct MultiStopRouteStop: Identifiable, Equatable {
    let id: UUID
    var place: MultiStopRoutePlace?

    init(id: UUID = UUID(), place: MultiStopRoutePlace? = nil) {
        self.id = id
        self.place = place
    }
}

enum MultiStopRouteStopRole: Equatable {
    case start
    case stop(Int)
    case destination

    var title: String {
        switch self {
        case .start: "Start"
        case .stop(let number): "Stop \(number)"
        case .destination: "Destination"
        }
    }

    /// The role inside a sentence: "the start", "Stop 2", "the destination".
    var phrase: String {
        switch self {
        case .start: "the start"
        case .stop(let number): "Stop \(number)"
        case .destination: "the destination"
        }
    }
}

enum MultiStopRouteDraftIssue: Equatable {
    case missingPlace(index: Int)
    case repeatedPlace(index: Int)
}

struct MultiStopRouteRequest: Equatable {
    let places: [MultiStopRoutePlace]
    let transportType: MKDirectionsTransportType
}

/// Ordered stops being edited. Position defines the role: the first stop is
/// the start, the last is the destination and every other stop is visited in
/// order. Edits keep the count between `minimumStops` and `maximumStops`.
struct MultiStopRouteDraft: Equatable {
    static let minimumStops = 2
    /// Bounds directions requests per calculation and the stitched route size.
    static let maximumStops = 10
    /// Consecutive stops closer than this cannot form a meaningful leg.
    static let minimumLegSeparationMeters = 15.0

    private(set) var stops: [MultiStopRouteStop]

    init(start: MultiStopRoutePlace? = nil) {
        stops = [MultiStopRouteStop(place: start), MultiStopRouteStop()]
    }

    init(places: [MultiStopRoutePlace?]) {
        var stops = places.prefix(Self.maximumStops).map {
            MultiStopRouteStop(place: $0)
        }
        while stops.count < Self.minimumStops {
            stops.append(MultiStopRouteStop())
        }
        self.stops = stops
    }

    var canAddStop: Bool { stops.count < Self.maximumStops }
    var canRemoveStop: Bool { stops.count > Self.minimumStops }

    func role(at index: Int) -> MultiStopRouteStopRole {
        if index == 0 { return .start }
        if index == stops.count - 1 { return .destination }
        return .stop(index)
    }

    func role(of stopID: UUID) -> MultiStopRouteStopRole? {
        stops.firstIndex { $0.id == stopID }.map(role(at:))
    }

    /// Adds an empty intermediate stop just before the destination.
    @discardableResult
    mutating func addStop() -> UUID? {
        guard canAddStop else { return nil }
        let stop = MultiStopRouteStop()
        stops.insert(stop, at: stops.count - 1)
        return stop.id
    }

    mutating func removeStops(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty,
              offsets.allSatisfy(stops.indices.contains),
              stops.count - offsets.count >= Self.minimumStops else { return }
        stops = stops.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
    }

    mutating func removeStop(id: UUID) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        removeStops(atOffsets: IndexSet(integer: index))
    }

    /// List-style move: `destination` is an offset in the unmodified stops.
    mutating func moveStops(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy(stops.indices.contains),
              (0...stops.count).contains(destination) else { return }
        let moving = source.map { stops[$0] }
        var remaining = stops.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        remaining.insert(
            contentsOf: moving,
            at: destination - source.filter { $0 < destination }.count
        )
        stops = remaining
    }

    /// One position earlier (negative) or later (positive); for accessibility.
    mutating func moveStop(id: UUID, by offset: Int) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard stops.indices.contains(target), target != index else { return }
        stops.swapAt(index, target)
    }

    mutating func reverse() {
        stops.reverse()
    }

    mutating func setPlace(_ place: MultiStopRoutePlace?, forStopID id: UUID) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].place = place
    }

    /// The first problem that prevents calculation, in stop order.
    var issue: MultiStopRouteDraftIssue? {
        for (index, stop) in stops.enumerated() {
            guard let place = stop.place else { return .missingPlace(index: index) }
            if index > 0, let previous = stops[index - 1].place,
               NavigationGeometryV1.distance(
                   from: previous.mapCoordinate,
                   to: place.mapCoordinate
               ) < Self.minimumLegSeparationMeters {
                return .repeatedPlace(index: index)
            }
        }
        return nil
    }

    func message(for issue: MultiStopRouteDraftIssue) -> String {
        switch issue {
        case .missingPlace(let index):
            switch role(at: index) {
            case .start: "Choose where the route starts."
            case .destination: "Choose a destination to preview the route."
            case .stop(let number): "Choose a place for Stop \(number), or remove it."
            }
        case .repeatedPlace(let index):
            "\(role(at: index).title) is the same place as \(role(at: index - 1).phrase). Choose a different place or remove one of them."
        }
    }

    func request(transportType: MKDirectionsTransportType) -> MultiStopRouteRequest? {
        guard issue == nil else { return nil }
        return MultiStopRouteRequest(
            places: stops.compactMap(\.place),
            transportType: transportType
        )
    }
}

enum MultiStopRouteNaming {
    static let maximumNameBytes = 512
    private static let maximumLabelCharacters = 48

    /// "A → B", "A → C via B", "A → D via B, C" or "A → E via 3 stops".
    static func defaultName(stopLabels: [String]) -> String {
        let labels = stopLabels.map { shortened($0) }
        guard let first = labels.first, let last = labels.last, labels.count >= 2 else {
            return "Route"
        }
        let intermediate = labels.dropFirst().dropLast()
        var name = "\(first) → \(last)"
        switch intermediate.count {
        case 0:
            break
        case 1, 2:
            name += " via " + intermediate.joined(separator: ", ")
        default:
            name += " via \(intermediate.count) stops"
        }
        return clamped(name, maximumUTF8Bytes: maximumNameBytes)
    }

    static func clamped(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= maximumUTF8Bytes else { break }
            result.append(character)
            used += size
        }
        return result
    }

    private static func shortened(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumLabelCharacters else { return trimmed }
        return String(trimmed.prefix(maximumLabelCharacters - 1)) + "…"
    }
}

enum MultiStopRouteStitchError: LocalizedError, Equatable {
    case invalidLegs
    case disconnected(stopLabel: String)
    case tooLong

    var errorDescription: String? {
        switch self {
        case .invalidLegs:
            "The calculated legs could not be combined into one route."
        case .disconnected(let stopLabel):
            "The route could not be joined at \(stopLabel). Move that stop closer to a road or path."
        case .tooLong:
            "This route is too long to save. Remove a stop or choose closer places."
        }
    }
}

/// Joins consecutive MapKit legs into one canonical route without changing
/// provider, normalization or any leg geometry. The result is an ordinary
/// active-only MapKit route; only `OfflineRouteSaveDraft.plannedMapKit` may
/// give it the explicit phone-only saved scope.
enum MultiStopRouteStitcher {
    /// MapKit snaps the end of one leg and the start of the next to the road
    /// network independently. A wider join would invent an off-road path.
    static let maximumJunctionGapMeters = 500.0
    /// Connector vertices stay far inside the device's 16-bit delta window.
    private static let maximumConnectorStepDegrees = 0.02

    static func arrivalInstruction(stopLabel: String) -> String {
        "Arrive at \(stopLabel)"
    }

    static func stitch(
        legs: [NavigationRouteV1],
        stopLabels: [String],
        routeID: UUID = UUID(),
        limits: NavigationRouteLimitsV1 = .production
    ) throws -> NavigationRouteV1 {
        let labels = stopLabels.map {
            MultiStopRouteNaming.clamped(
                $0.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumUTF8Bytes: MultiStopRoutePlace.maximumLabelBytes
            )
        }
        guard let firstLeg = legs.first,
              labels.count == legs.count + 1,
              labels.allSatisfy({ !$0.isEmpty }) else {
            throw MultiStopRouteStitchError.invalidLegs
        }
        for leg in legs {
            guard leg.provider == RouteProviderPolicyV1.mapKit,
                  leg.sourceReference == nil,
                  leg.localeIdentifier == firstLeg.localeIdentifier,
                  leg.transportType == firstLeg.transportType,
                  leg.normalizationVersion == firstLeg.normalizationVersion,
                  (try? leg.validate()) != nil else {
                throw MultiStopRouteStitchError.invalidLegs
            }
        }

        var points: [RouteCoordinateV1] = []
        var steps: [NavigationRouteStepV1] = []
        var distance = 0.0
        var travelTime: Double? = 0
        for (legIndex, leg) in legs.enumerated() {
            let offset: Int
            if let junction = points.last {
                let legStart = leg.points[0]
                if junction != legStart {
                    let gap = NavigationGeometryV1.distance(from: junction, to: legStart)
                    guard gap <= maximumJunctionGapMeters,
                          abs(legStart.longitude - junction.longitude) <= 180,
                          let arrival = steps.popLast() else {
                        throw MultiStopRouteStitchError.disconnected(
                            stopLabel: labels[legIndex]
                        )
                    }
                    points.append(contentsOf: connector(from: junction, to: legStart))
                    // The stop's arrival step absorbs the join, so the next
                    // leg's first step still begins where this one ends.
                    steps.append(NavigationRouteStepV1(
                        id: arrival.id,
                        geometryStartIndex: arrival.geometryStartIndex,
                        geometryEndIndex: points.count - 1,
                        instruction: arrival.instruction,
                        maneuver: arrival.maneuver,
                        distanceMeters: arrival.distanceMeters + gap
                    ))
                    distance += gap
                }
                offset = points.count - 1
                points.append(contentsOf: leg.points.dropFirst())
            } else {
                offset = 0
                points = leg.points
            }

            let isFinalLeg = legIndex == legs.count - 1
            for (stepIndex, step) in leg.steps.enumerated() {
                // An intermediate stop is passed through, never a finish:
                // only the final leg may keep MapKit's arrival maneuver.
                let isStopArrival = !isFinalLeg && stepIndex == leg.steps.count - 1
                steps.append(NavigationRouteStepV1(
                    id: UInt32(steps.count + 1),
                    geometryStartIndex: step.geometryStartIndex + offset,
                    geometryEndIndex: step.geometryEndIndex + offset,
                    instruction: isStopArrival
                        ? arrivalInstruction(stopLabel: labels[legIndex + 1])
                        : step.instruction,
                    maneuver: isStopArrival ? .straight : step.maneuver,
                    distanceMeters: step.distanceMeters
                ))
            }
            distance += leg.distanceMeters
            travelTime = travelTime.flatMap { total in
                leg.expectedTravelTimeSeconds.map { total + $0 }
            }
        }

        guard let first = points.first, let last = points.last,
              let bounds = RouteBoundsV1.enclosing(points) else {
            throw MultiStopRouteStitchError.invalidLegs
        }
        let route = NavigationRouteV1(
            id: routeID,
            revision: 1,
            provider: RouteProviderPolicyV1.mapKit,
            localeIdentifier: firstLeg.localeIdentifier,
            transportType: firstLeg.transportType,
            source: RouteEndpointV1(coordinate: first, label: labels[0]),
            destination: RouteEndpointV1(coordinate: last, label: labels[labels.count - 1]),
            bounds: bounds,
            distanceMeters: distance,
            expectedTravelTimeSeconds: travelTime,
            name: MultiStopRouteNaming.defaultName(stopLabels: labels),
            points: points,
            steps: steps,
            normalizationVersion: firstLeg.normalizationVersion
        )
        do {
            try route.validate(limits: limits)
        } catch NavigationRouteValidationError.tooManyPoints,
                NavigationRouteValidationError.tooManySteps {
            throw MultiStopRouteStitchError.tooLong
        } catch {
            throw MultiStopRouteStitchError.invalidLegs
        }
        return route
    }

    /// Straight join vertices after `start`, ending exactly at `end`.
    private static func connector(
        from start: RouteCoordinateV1,
        to end: RouteCoordinateV1
    ) -> [RouteCoordinateV1] {
        let span = max(
            abs(end.latitude - start.latitude),
            abs(end.longitude - start.longitude)
        )
        let count = max(Int((span / maximumConnectorStepDegrees).rounded(.up)), 1)
        return (1...count).map { index in
            guard index < count else { return end }
            let fraction = Double(index) / Double(count)
            return RouteCoordinateV1(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                longitude: start.longitude + (end.longitude - start.longitude) * fraction
            )
        }
    }
}
