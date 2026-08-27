import Foundation

nonisolated struct RouteCoordinateV1: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

nonisolated struct RouteEndpointV1: Codable, Equatable {
    let coordinate: RouteCoordinateV1
    let label: String
}

nonisolated struct RouteBoundsV1: Codable, Equatable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    static func enclosing(_ points: [RouteCoordinateV1]) -> RouteBoundsV1? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(
            RouteBoundsV1(
                south: first.latitude,
                west: first.longitude,
                north: first.latitude,
                east: first.longitude
            )
        ) { bounds, point in
            RouteBoundsV1(
                south: min(bounds.south, point.latitude),
                west: min(bounds.west, point.longitude),
                north: max(bounds.north, point.latitude),
                east: max(bounds.east, point.longitude)
            )
        }
    }

    var isValid: Bool {
        [south, west, north, east].allSatisfy(\.isFinite) &&
            (-90...90).contains(south) && (-90...90).contains(north) &&
            (-180...180).contains(west) && (-180...180).contains(east) &&
            south <= north && west <= east
    }
}

nonisolated enum RouteTransportTypeV1: String, Codable, Equatable {
    case cycling
}

nonisolated enum ManeuverV1: String, Codable, CaseIterable, Equatable {
    case straight
    case slightLeft
    case left
    case sharpLeft
    case slightRight
    case right
    case sharpRight
    case uTurn
    case roundabout
    case arrive
    case unknown

    var deviceIconID: Int {
        switch self {
        case .slightLeft, .left, .sharpLeft:
            2
        case .slightRight, .right, .sharpRight:
            3
        case .uTurn:
            4
        case .straight, .roundabout, .arrive, .unknown:
            1
        }
    }

    static func infer(from instruction: String) -> ManeuverV1 {
        let lowercased = instruction.lowercased()
        if lowercased.contains("u-turn") || lowercased.contains("uturn") {
            return .uTurn
        }
        if lowercased.contains("roundabout") {
            return .roundabout
        }
        if lowercased.contains("arrive") || lowercased.contains("destination") {
            return .arrive
        }
        if lowercased.contains("slight left") {
            return .slightLeft
        }
        if lowercased.contains("sharp left") {
            return .sharpLeft
        }
        if lowercased.contains("left") {
            return .left
        }
        if lowercased.contains("slight right") {
            return .slightRight
        }
        if lowercased.contains("sharp right") {
            return .sharpRight
        }
        if lowercased.contains("right") {
            return .right
        }
        return .straight
    }
}

nonisolated struct NavigationRouteStepV1: Codable, Equatable, Identifiable {
    let id: UInt32
    let geometryStartIndex: Int
    let geometryEndIndex: Int
    let instruction: String
    let maneuver: ManeuverV1
    let distanceMeters: Double
}

nonisolated enum RouteStorageScopeV1: String, Codable, Equatable {
    case activeOnly
    case durable
}

nonisolated struct RouteProviderMetadataV1: Codable, Equatable {
    let providerID: String
    let attribution: String
    let storageScope: RouteStorageScopeV1
}

nonisolated struct RouteSourceReferenceV1: Codable, Equatable, Sendable {
    let providerID: String
    let externalRouteID: String
    let canonicalURL: String
}

nonisolated struct NavigationRouteV1: Codable, Equatable, Identifiable {
    static let schemaVersion: UInt16 = 1

    let id: UUID
    let revision: UInt32
    let provider: RouteProviderMetadataV1
    let sourceReference: RouteSourceReferenceV1?
    let localeIdentifier: String
    let transportType: RouteTransportTypeV1
    let source: RouteEndpointV1
    let destination: RouteEndpointV1
    let bounds: RouteBoundsV1
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double?
    let name: String?
    let points: [RouteCoordinateV1]
    let steps: [NavigationRouteStepV1]
    let normalizationVersion: UInt16

    var routeID: UUID { id }

    init(
        id: UUID,
        revision: UInt32,
        provider: RouteProviderMetadataV1,
        sourceReference: RouteSourceReferenceV1? = nil,
        localeIdentifier: String,
        transportType: RouteTransportTypeV1,
        source: RouteEndpointV1,
        destination: RouteEndpointV1,
        bounds: RouteBoundsV1,
        distanceMeters: Double,
        expectedTravelTimeSeconds: Double?,
        name: String?,
        points: [RouteCoordinateV1],
        steps: [NavigationRouteStepV1],
        normalizationVersion: UInt16
    ) {
        self.id = id
        self.revision = revision
        self.provider = provider
        self.sourceReference = sourceReference
        self.localeIdentifier = localeIdentifier
        self.transportType = transportType
        self.source = source
        self.destination = destination
        self.bounds = bounds
        self.distanceMeters = distanceMeters
        self.expectedTravelTimeSeconds = expectedTravelTimeSeconds
        self.name = name
        self.points = points
        self.steps = steps
        self.normalizationVersion = normalizationVersion
    }
}

nonisolated struct NavigationRouteLimitsV1: Equatable {
    static let production = NavigationRouteLimitsV1(
        maximumPoints: 50_000,
        maximumSteps: 2_000,
        maximumEncodedBytes: 4 * 1_024 * 1_024
    )

    let maximumPoints: Int
    let maximumSteps: Int
    let maximumEncodedBytes: Int
}

nonisolated enum NavigationRouteValidationError: Error, Equatable, CustomStringConvertible {
    case invalidRouteID
    case invalidRevision
    case invalidProvider
    case invalidSourceReference
    case invalidLocale
    case invalidEndpoint
    case invalidBounds
    case invalidDistance
    case invalidTravelTime
    case invalidNormalizationVersion
    case emptyGeometry
    case insufficientGeometry
    case tooManyPoints
    case invalidCoordinate(index: Int)
    case tooManySteps
    case emptySteps
    case duplicateStepID(UInt32)
    case invalidStepRange(index: Int)
    case backwardStepRange(index: Int)
    case discontinuousStepRange(index: Int)
    case invalidStepDistance(index: Int)
    case invalidInstruction(index: Int)
    case endpointGeometryMismatch
    case unencodableGeometrySegment(index: Int)
    case boundsMismatch

    var description: String {
        switch self {
        case .invalidRouteID: "Invalid route ID"
        case .invalidRevision: "Invalid route revision"
        case .invalidProvider: "Invalid route provider metadata"
        case .invalidSourceReference: "Invalid route source reference"
        case .invalidLocale: "Invalid route locale"
        case .invalidEndpoint: "Invalid route endpoint"
        case .invalidBounds: "Invalid route bounds"
        case .invalidDistance: "Invalid route distance"
        case .invalidTravelTime: "Invalid route travel time"
        case .invalidNormalizationVersion: "Invalid coordinate normalization version"
        case .emptyGeometry: "Route geometry is empty"
        case .insufficientGeometry: "Route geometry needs at least two distinct points"
        case .tooManyPoints: "Route has too many geometry points"
        case .invalidCoordinate(let index): "Invalid route coordinate at index \(index)"
        case .tooManySteps: "Route has too many steps"
        case .emptySteps: "Route has no navigation steps"
        case .duplicateStepID(let id): "Duplicate route step ID \(id)"
        case .invalidStepRange(let index): "Invalid geometry range for step \(index)"
        case .backwardStepRange(let index): "Backward or overlapping geometry range for step \(index)"
        case .discontinuousStepRange(let index): "Discontinuous geometry range for step \(index)"
        case .invalidStepDistance(let index): "Invalid distance for step \(index)"
        case .invalidInstruction(let index): "Invalid instruction for step \(index)"
        case .endpointGeometryMismatch: "Route endpoints do not match route geometry"
        case .unencodableGeometrySegment(let index): "Route geometry segment \(index) exceeds the device delta range"
        case .boundsMismatch: "Route bounds do not enclose its geometry"
        }
    }
}

nonisolated extension NavigationRouteV1 {
    func validate(limits: NavigationRouteLimitsV1 = .production) throws {
        guard id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw NavigationRouteValidationError.invalidRouteID
        }
        guard revision > 0 else { throw NavigationRouteValidationError.invalidRevision }
        guard !provider.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.providerID.utf8.count <= 128,
              !provider.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.attribution.utf8.count <= 512,
              RouteProviderPolicyV1.hasConsistentKnownPolicy(provider) else {
            throw NavigationRouteValidationError.invalidProvider
        }
        guard RouteProviderPolicyV1.hasConsistentSourceReference(
            sourceReference,
            for: provider
        ) else {
            throw NavigationRouteValidationError.invalidSourceReference
        }
        guard !localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              localeIdentifier.utf8.count <= 128 else {
            throw NavigationRouteValidationError.invalidLocale
        }
        guard source.coordinate.isValid, destination.coordinate.isValid,
              !source.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.label.utf8.count <= 1_024,
              !destination.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              destination.label.utf8.count <= 1_024 else {
            throw NavigationRouteValidationError.invalidEndpoint
        }
        guard bounds.isValid else { throw NavigationRouteValidationError.invalidBounds }
        guard distanceMeters.isFinite, distanceMeters > 0 else {
            throw NavigationRouteValidationError.invalidDistance
        }
        if let expectedTravelTimeSeconds {
            guard expectedTravelTimeSeconds.isFinite, expectedTravelTimeSeconds > 0 else {
                throw NavigationRouteValidationError.invalidTravelTime
            }
        }
        guard normalizationVersion > 0 else {
            throw NavigationRouteValidationError.invalidNormalizationVersion
        }
        guard !points.isEmpty else { throw NavigationRouteValidationError.emptyGeometry }
        guard points.count >= 2,
              zip(points, points.dropFirst()).contains(where: { pair in
                  pair.0 != pair.1
              }) else {
            throw NavigationRouteValidationError.insufficientGeometry
        }
        guard points.count <= limits.maximumPoints else {
            throw NavigationRouteValidationError.tooManyPoints
        }
        for (index, point) in points.enumerated() where !point.isValid {
            throw NavigationRouteValidationError.invalidCoordinate(index: index)
        }
        guard source.coordinate == points.first,
              destination.coordinate == points.last else {
            throw NavigationRouteValidationError.endpointGeometryMismatch
        }
        for index in 0..<(points.count - 1) where
            !NavigationGeometryV1.isRouteWindowDeltaEncodable(
                from: points[index],
                to: points[index + 1]
            ) {
            throw NavigationRouteValidationError.unencodableGeometrySegment(index: index)
        }
        guard steps.count <= limits.maximumSteps else {
            throw NavigationRouteValidationError.tooManySteps
        }
        guard !steps.isEmpty else { throw NavigationRouteValidationError.emptySteps }

        var stepIDs = Set<UInt32>()
        var previousEndIndex: Int?
        for (index, step) in steps.enumerated() {
            guard stepIDs.insert(step.id).inserted else {
                throw NavigationRouteValidationError.duplicateStepID(step.id)
            }
            guard step.geometryStartIndex >= 0,
                  step.geometryEndIndex >= step.geometryStartIndex,
                  step.geometryEndIndex < points.count else {
                throw NavigationRouteValidationError.invalidStepRange(index: index)
            }
            if let previousEndIndex {
                if step.geometryStartIndex < previousEndIndex {
                    throw NavigationRouteValidationError.backwardStepRange(index: index)
                }
                if step.geometryStartIndex != previousEndIndex {
                    throw NavigationRouteValidationError.discontinuousStepRange(index: index)
                }
            } else if step.geometryStartIndex != 0 {
                throw NavigationRouteValidationError.discontinuousStepRange(index: index)
            }
            previousEndIndex = step.geometryEndIndex
            guard step.distanceMeters.isFinite, step.distanceMeters >= 0 else {
                throw NavigationRouteValidationError.invalidStepDistance(index: index)
            }
            guard !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  step.instruction.utf8.count <= 1_024 else {
                throw NavigationRouteValidationError.invalidInstruction(index: index)
            }
        }
        guard previousEndIndex == points.count - 1 else {
            throw NavigationRouteValidationError.discontinuousStepRange(
                index: steps.count - 1
            )
        }

        guard let measuredBounds = RouteBoundsV1.enclosing(points),
              bounds.south <= measuredBounds.south,
              bounds.west <= measuredBounds.west,
              bounds.north >= measuredBounds.north,
              bounds.east >= measuredBounds.east else {
            throw NavigationRouteValidationError.boundsMismatch
        }
    }
}
