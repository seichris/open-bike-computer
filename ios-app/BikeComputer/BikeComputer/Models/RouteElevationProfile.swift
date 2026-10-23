import Foundation

/// The versioned route elevation contract shared with the map backend and the
/// Bicino device. See docs/route-elevation-profile.md. One profile drives both
/// the iPhone chart and the device screen; the device never recomputes it.
nonisolated enum RouteElevationContractV1 {
    static let profileSchema = "bicino-route-elevation-profile-v1"
    static let processingVersion = "bicino-route-elevation-v1"
    static let requestSchema = "bicino-route-elevation-request-v1"
    static let responseSchema = "bicino-route-elevation-response-v1"

    static let earthRadiusMeters = 6_371_008.8
    static let nominalSpacingMeters = 50.0
    static let spacingStepMeters = 10.0
    static let maximumSamples = 4001
    static let maximumRoutePoints = 20_000
    static let minimumRouteLengthMeters = 1.0
    static let maximumRouteLengthMeters = 1_000_000.0
    static let maximumSegmentLengthMeters = 100_000.0
    static let minimumValidElevationMeters = -500.0
    static let maximumValidElevationMeters = 9_000.0
    static let maximumInterpolatedGapMeters = 200.0
    static let smoothingMaximumSpacingMeters = 75.0
    static let ascentHysteresisMeters = 5.0
    static let gradeHalfWindowMeters = 100.0
    static let unavailableCoverage = 0.1
    static let structureAnchorClearanceMeters = 30.0
    static let structureAnchorSearchMeters = 150.0
    static let maximumStructureGrade = 0.15
    static let maximumStructureLengthMeters = 15_000.0
    static let distanceEpsilon = 1e-6

    static let flagRawMissing = 1 << 0
    static let flagInterpolatedGap = 1 << 1
    static let flagStructureEstimated = 1 << 2
    static let flagStructureUnresolved = 1 << 3
    static let flagStructureAmbiguous = 1 << 4
    static let flagBridge = 1 << 5
    static let flagTunnel = 1 << 6
    static let flagGradeEstimated = 1 << 7
    static let flagEstimated = flagInterpolatedGap | flagStructureEstimated
    static let knownFlags = 0xFF

    static let qualityComplete = "complete"
    static let qualityPartial = "partial"
    static let qualityUnavailable = "unavailable"
    static let structureEstimated = "estimated"
    static let structureUnresolved = "unresolved"
    static let structureAmbiguous = "ambiguous"

    /// Matches Swift's `.toNearestOrAwayFromZero`; the backend uses the same rule.
    static func roundHalfAway(_ value: Double, digits: Int = 1) -> Double {
        let scale = pow(10.0, Double(digits))
        let rounded = (abs(value) * scale + 0.5).rounded(.down) / scale
        return rounded == 0 ? 0 : (value < 0 ? -rounded : rounded)
    }

    static func roundOptional(_ value: Double?, digits: Int = 1) -> Double? {
        value.map { roundHalfAway($0, digits: digits) }
    }
}

nonisolated enum RouteElevationProfileError: Error, Equatable {
    case unsupportedSchema
    case geometryMismatch
    case malformedSamples
    case invalidStatistics
}

nonisolated struct RouteElevationProfileV1: Codable, Equatable, Sendable {
    nonisolated struct Geometry: Codable, Equatable, Sendable {
        let digest: String
        let pointCount: Int
        let lengthM: Double
        let crs: String
        let precision: String
    }

    nonisolated struct Sampling: Codable, Equatable, Sendable {
        let method: String
        let spacingM: Double
        let sampleCount: Int
        let smoothingHalfSamples: Int
        let ascentHysteresisM: Double
        let gradeHalfWindowM: Double
        let maximumInterpolatedGapM: Double
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        let kind: String
        let id: String
        let version: String?
        let verticalDatum: String?
        let nativeResolutionM: Double?
        let surfaceModel: String?
        let interpolation: String?
        let attribution: [String]
        let retrievedAt: String?
        let qualification: String
    }

    nonisolated struct Samples: Codable, Equatable, Sendable {
        let distanceM: [Double]
        let elevationM: [Double?]
        let rawElevationM: [Double?]
        let gradePercent: [Double?]
        let cumulativeAscentM: [Double?]
        let flags: [Int]
    }

    nonisolated struct Structure: Codable, Equatable, Sendable {
        let kind: String
        let startM: Double
        let endM: Double
        let resolution: String
        let osmWayIds: [Int64]
        let reason: String?
        let anchorStartM: Double?
        let anchorEndM: Double?
    }

    nonisolated struct StructureCorrection: Codable, Equatable, Sendable {
        let status: String
        let source: String?
        let sourceVersion: String?
        let attribution: [String]
        let reason: String?
    }

    nonisolated struct Statistics: Codable, Equatable, Sendable {
        let totalAscentM: Double?
        let totalDescentM: Double?
        let minimumElevationM: Double?
        let maximumElevationM: Double?
        let complete: Bool
        let includesEstimated: Bool
    }

    nonisolated struct Quality: Codable, Equatable, Sendable {
        let status: String
        let coverage: Double
        let validDistanceM: Double
        let estimatedDistanceM: Double
        let unknownDistanceM: Double
        let longestGapM: Double
        let reasons: [String]
    }

    let schema: String
    let processingVersion: String
    let geometry: Geometry
    let sampling: Sampling
    let source: Source
    let samples: Samples
    let structures: [Structure]
    let structureCorrection: StructureCorrection
    let statistics: Statistics
    let quality: Quality

    var isAvailable: Bool { quality.status != RouteElevationContractV1.qualityUnavailable }
    var hasAmbiguousStructures: Bool {
        structures.contains { $0.resolution == RouteElevationContractV1.structureAmbiguous }
    }

    /// Bounds every array a remote or cached profile may carry before use.
    func validate(expectedDigest: String, expectedPointCount: Int) throws {
        typealias Contract = RouteElevationContractV1
        guard schema == Contract.profileSchema,
              processingVersion == Contract.processingVersion,
              geometry.crs == "EPSG:4326" else {
            throw RouteElevationProfileError.unsupportedSchema
        }
        guard geometry.digest == expectedDigest, geometry.pointCount == expectedPointCount else {
            throw RouteElevationProfileError.geometryMismatch
        }
        let count = samples.distanceM.count
        guard count >= 2, count <= Contract.maximumSamples, count == sampling.sampleCount,
              samples.elevationM.count == count, samples.rawElevationM.count == count,
              samples.gradePercent.count == count, samples.cumulativeAscentM.count == count,
              samples.flags.count == count, structures.count <= 512 else {
            throw RouteElevationProfileError.malformedSamples
        }
        guard geometry.lengthM.isFinite, geometry.lengthM >= Contract.minimumRouteLengthMeters,
              samples.distanceM.first == 0,
              abs((samples.distanceM.last ?? -1) - geometry.lengthM) <= 0.11 else {
            throw RouteElevationProfileError.malformedSamples
        }
        var previous = -Double.infinity
        for index in 0..<count {
            let distance = samples.distanceM[index]
            guard distance.isFinite, distance >= previous,
                  samples.flags[index] >= 0, samples.flags[index] & ~Contract.knownFlags == 0 else {
                throw RouteElevationProfileError.malformedSamples
            }
            previous = distance
            for value in [samples.elevationM[index], samples.rawElevationM[index]] {
                if let value, !(value.isFinite && value >= Contract.minimumValidElevationMeters &&
                                value <= Contract.maximumValidElevationMeters) {
                    throw RouteElevationProfileError.malformedSamples
                }
            }
            if let grade = samples.gradePercent[index], !(grade.isFinite && abs(grade) <= 100) {
                throw RouteElevationProfileError.malformedSamples
            }
            if let climbed = samples.cumulativeAscentM[index], !(climbed.isFinite && climbed >= 0) {
                throw RouteElevationProfileError.malformedSamples
            }
        }
        if let ascent = statistics.totalAscentM, !(ascent.isFinite && ascent >= 0) {
            throw RouteElevationProfileError.invalidStatistics
        }
        if let descent = statistics.totalDescentM, !(descent.isFinite && descent >= 0) {
            throw RouteElevationProfileError.invalidStatistics
        }
        guard quality.coverage.isFinite, (0...1).contains(quality.coverage),
              [Contract.qualityComplete, Contract.qualityPartial, Contract.qualityUnavailable]
                .contains(quality.status) else {
            throw RouteElevationProfileError.invalidStatistics
        }
    }

    /// Values at an along-route distance, derived only from this profile.
    func position(atDistance requested: Double) -> RouteElevationPositionV1 {
        typealias Contract = RouteElevationContractV1
        let distances = samples.distanceM
        let distance = min(max(requested.isFinite ? requested : 0, 0), geometry.lengthM)
        var low = 0
        var high = distances.count - 1
        while low < high - 1 {
            let middle = (low + high) / 2
            if distances[middle] <= distance { low = middle } else { high = middle }
        }
        let following = min(low + 1, distances.count - 1)
        let span = distances[following] - distances[low]
        let fraction = span <= 0 ? 0 : (distance - distances[low]) / span
        var elevation: Double?
        if let start = samples.elevationM[low], let end = samples.elevationM[following] {
            elevation = start + fraction * (end - start)
        }
        let elevationEstimated = (samples.flags[low] | samples.flags[following]) & Contract.flagEstimated != 0
        let nearest = (distance - distances[low]) > (distances[following] - distance) ? following : low
        var climbed: Double?
        if let start = samples.cumulativeAscentM[low], let end = samples.cumulativeAscentM[following] {
            climbed = start + fraction * (end - start)
        } else {
            for index in stride(from: low, through: 0, by: -1) {
                if let value = samples.cumulativeAscentM[index] {
                    climbed = value
                    break
                }
            }
        }
        let remaining = statistics.totalAscentM.map { max(0, $0 - (climbed ?? 0)) }
        return RouteElevationPositionV1(
            distanceMeters: distance,
            elevationMeters: Contract.roundOptional(elevation),
            elevationEstimated: elevationEstimated,
            gradePercent: samples.gradePercent[nearest],
            gradeEstimated: samples.flags[nearest] & Contract.flagGradeEstimated != 0,
            ascentRemainingMeters: Contract.roundOptional(remaining),
            ascentRemainingIsLowerBound: !statistics.complete
        )
    }
}

nonisolated struct RouteElevationPositionV1: Equatable, Sendable {
    let distanceMeters: Double
    let elevationMeters: Double?
    let elevationEstimated: Bool
    let gradePercent: Double?
    let gradeEstimated: Bool
    let ascentRemainingMeters: Double?
    let ascentRemainingIsLowerBound: Bool
}

/// Wire shapes for the managed route elevation service.
nonisolated struct RouteElevationServiceRequestV1: Encodable, Equatable {
    nonisolated struct Geometry: Encodable, Equatable {
        let crs: String
        /// `[lonE6, latE6]` pairs (GeoJSON axis order).
        let coordinatesE6: [[Int32]]
        let digest: String
    }

    let schema: String
    let requestId: String
    let geometry: Geometry
    let travelMode: String
    let routeSource: String
}

nonisolated struct RouteElevationServiceResponseV1: Decodable, Equatable {
    nonisolated struct Attempt: Decodable, Equatable {
        let provider: String?
        let status: String
        let reason: String?
        /// Present only when the provider answered and the profile was processed.
        let coverage: Double?
    }

    let schema: String
    let status: String
    let profile: RouteElevationProfileV1?
    let attempts: [Attempt]
    let retryAfterSeconds: Int?
}
