import CryptoKit
import Foundation

/// Canonical WGS-84 geometry in integer microdegrees (round half away from
/// zero), the exact representation hashed by both the app and the backend.
/// Display-only GCJ-02 conversion never enters this type.
nonisolated struct RouteElevationGeometryV1: Equatable, Sendable {
    let latitudeE6: [Int32]
    let longitudeE6: [Int32]
    let cumulativeMeters: [Double]
    let digest: String

    var pointCount: Int { latitudeE6.count }
    var lengthMeters: Double { cumulativeMeters.last ?? 0 }

    func latitude(_ index: Int) -> Double { Double(latitudeE6[index]) / 1_000_000.0 }
    func longitude(_ index: Int) -> Double { Double(longitudeE6[index]) / 1_000_000.0 }
}

nonisolated enum RouteElevationGeometryError: Error, Equatable {
    case tooFewPoints
    case tooManyPoints
    case invalidCoordinate
    case implausibleSegment
    case tooShort
    case tooLong
}

nonisolated struct RouteElevationSamplingPlanV1: Equatable, Sendable {
    let spacingMeters: Double
    let distancesMeters: [Double]
}

nonisolated struct RouteElevationStructureSpanV1: Equatable, Sendable {
    let kind: String
    let startMeters: Double
    let endMeters: Double
    let resolution: String
    let wayIDs: [Int64]
    let reason: String?
}

/// Ports `map_platform.route_elevation` step for step. Shared fixtures in
/// protocol/fixtures/route-elevation-v1 keep the two implementations equal.
nonisolated enum RouteElevationProcessorV1 {
    typealias Contract = RouteElevationContractV1

    static func scaled(_ value: Double) -> Int32 {
        Int32((value * 1_000_000).rounded(.toNearestOrAwayFromZero))
    }

    static func normalizedLongitudeDelta(_ delta: Double) -> Double {
        if delta > 180 { return delta - 360 }
        if delta < -180 { return delta + 360 }
        return delta
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = phi2 - phi1
        let deltaLambda = normalizedLongitudeDelta(lon2 - lon1) * .pi / 180
        let sinPhi = sin(deltaPhi / 2)
        let sinLambda = sin(deltaLambda / 2)
        var a = sinPhi * sinPhi + cos(phi1) * cos(phi2) * sinLambda * sinLambda
        a = min(1, max(0, a))
        return Contract.earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func digest(latitudeE6: [Int32], longitudeE6: [Int32]) -> String {
        var data = Data("bicino-route-geometry-v1\n".utf8)
        var count = UInt32(latitudeE6.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for (latitude, longitude) in zip(latitudeE6, longitudeE6) {
            var lat = latitude.littleEndian
            var lon = longitude.littleEndian
            withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `maximumPoints` defaults to the service bound; on-phone GPX processing
    /// may use the larger saved-route bound because nothing is uploaded.
    static func geometry(
        points: [RouteCoordinateV1],
        maximumPoints: Int = Contract.maximumRoutePoints
    ) throws -> RouteElevationGeometryV1 {
        try geometry(latitudeE6: points.map { scaled($0.latitude) },
                     longitudeE6: points.map { scaled($0.longitude) },
                     maximumPoints: maximumPoints)
    }

    static func geometry(
        latitudeE6: [Int32],
        longitudeE6: [Int32],
        maximumPoints: Int = Contract.maximumRoutePoints
    ) throws -> RouteElevationGeometryV1 {
        guard latitudeE6.count == longitudeE6.count, latitudeE6.count >= 2 else {
            throw RouteElevationGeometryError.tooFewPoints
        }
        guard latitudeE6.count <= maximumPoints else {
            throw RouteElevationGeometryError.tooManyPoints
        }
        guard zip(latitudeE6, longitudeE6).allSatisfy({
            (-90_000_000...90_000_000).contains($0.0) && (-180_000_000...180_000_000).contains($0.1)
        }) else {
            throw RouteElevationGeometryError.invalidCoordinate
        }
        var cumulative = [0.0]
        cumulative.reserveCapacity(latitudeE6.count)
        for index in 1..<latitudeE6.count {
            let step = haversine(
                Double(latitudeE6[index - 1]) / 1_000_000.0, Double(longitudeE6[index - 1]) / 1_000_000.0,
                Double(latitudeE6[index]) / 1_000_000.0, Double(longitudeE6[index]) / 1_000_000.0
            )
            guard step <= Contract.maximumSegmentLengthMeters else {
                throw RouteElevationGeometryError.implausibleSegment
            }
            cumulative.append(cumulative[index - 1] + step)
        }
        let length = cumulative[cumulative.count - 1]
        guard length >= Contract.minimumRouteLengthMeters else { throw RouteElevationGeometryError.tooShort }
        guard length <= Contract.maximumRouteLengthMeters else { throw RouteElevationGeometryError.tooLong }
        return RouteElevationGeometryV1(
            latitudeE6: latitudeE6,
            longitudeE6: longitudeE6,
            cumulativeMeters: cumulative,
            digest: digest(latitudeE6: latitudeE6, longitudeE6: longitudeE6)
        )
    }

    static func spacing(forLength length: Double) -> Double {
        var spacing = Contract.nominalSpacingMeters
        let required = length / Double(Contract.maximumSamples - 1)
        if required > spacing {
            spacing = (required / Contract.spacingStepMeters - 1e-9).rounded(.up) * Contract.spacingStepMeters
        }
        return spacing
    }

    static func plan(length: Double) -> RouteElevationSamplingPlanV1 {
        let spacing = spacing(forLength: length)
        let intervals = max(1, Int((length / spacing - 1e-9).rounded(.up)))
        var distances = (0..<intervals).map { Double($0) * spacing }
        distances.append(length)
        return RouteElevationSamplingPlanV1(spacingMeters: spacing, distancesMeters: distances)
    }

    /// Index of the last element `<= value` (Python `bisect_right - 1`).
    static func lastIndex(atOrBelow value: Double, in values: [Double]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }

    /// Index of the first element `>= value` (Python `bisect_left`).
    static func firstIndex(atOrAbove value: Double, in values: [Double]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    static func resampleVertexElevations(
        geometry: RouteElevationGeometryV1,
        plan: RouteElevationSamplingPlanV1,
        vertexElevations: [Double?],
        maximumBridgeMeters: Double = 250
    ) -> [Double?]? {
        guard vertexElevations.count == geometry.pointCount else { return nil }
        let validIndices = vertexElevations.indices.filter {
            if let value = vertexElevations[$0] { return value.isFinite }
            return false
        }
        let validDistances = validIndices.map { geometry.cumulativeMeters[$0] }
        return plan.distancesMeters.map { distance -> Double? in
            let position = lastIndex(atOrBelow: distance + Contract.distanceEpsilon, in: validDistances)
            guard position >= 0 else { return nil }
            let previousDistance = validDistances[position]
            let previousValue = vertexElevations[validIndices[position]]!
            if abs(distance - previousDistance) <= Contract.distanceEpsilon { return previousValue }
            guard position + 1 < validIndices.count else { return nil }
            let nextDistance = validDistances[position + 1]
            let nextValue = vertexElevations[validIndices[position + 1]]!
            let span = nextDistance - previousDistance
            guard span <= maximumBridgeMeters, span > 0 else { return nil }
            let fraction = (distance - previousDistance) / span
            return previousValue + fraction * (nextValue - previousValue)
        }
    }

    private static func validElevation(_ value: Double?) -> Double? {
        guard let value, value.isFinite,
              value >= Contract.minimumValidElevationMeters,
              value <= Contract.maximumValidElevationMeters else { return nil }
        return value
    }

    private static func firstValid(atOrBefore limit: Double, floor: Double, distances: [Double],
                                   values: [Double?]) -> Int? {
        var index = lastIndex(atOrBelow: limit + Contract.distanceEpsilon, in: distances)
        while index >= 0, distances[index] >= floor - Contract.distanceEpsilon {
            if values[index] != nil { return index }
            index -= 1
        }
        return nil
    }

    private static func firstValid(atOrAfter limit: Double, ceiling: Double, distances: [Double],
                                   values: [Double?]) -> Int? {
        var index = firstIndex(atOrAbove: limit - Contract.distanceEpsilon, in: distances)
        while index < distances.count, distances[index] <= ceiling + Contract.distanceEpsilon {
            if values[index] != nil { return index }
            index += 1
        }
        return nil
    }

    static func applyStructures(
        distances: [Double],
        values: inout [Double?],
        flags: inout [Int],
        spans: [RouteElevationStructureSpanV1]
    ) -> [RouteElevationProfileV1.Structure] {
        let raw = values
        var resolved: [RouteElevationProfileV1.Structure] = []
        let ordered = spans.enumerated().sorted {
            ($0.element.startMeters, $0.element.endMeters, $0.offset) <
                ($1.element.startMeters, $1.element.endMeters, $1.offset)
        }.map(\.element)
        for span in ordered {
            let kindFlag = span.kind == "bridge" ? Contract.flagBridge : Contract.flagTunnel
            let inside = distances.indices.filter {
                span.startMeters - Contract.distanceEpsilon <= distances[$0] &&
                    distances[$0] <= span.endMeters + Contract.distanceEpsilon
            }
            if span.resolution == Contract.structureAmbiguous {
                for index in inside { flags[index] |= Contract.flagStructureAmbiguous | kindFlag }
                resolved.append(structure(span, resolution: span.resolution, reason: span.reason))
                continue
            }
            var reason: String?
            let anchorStart = firstValid(
                atOrBefore: span.startMeters - Contract.structureAnchorClearanceMeters,
                floor: span.startMeters - Contract.structureAnchorSearchMeters,
                distances: distances, values: raw)
            let anchorEnd = firstValid(
                atOrAfter: span.endMeters + Contract.structureAnchorClearanceMeters,
                ceiling: span.endMeters + Contract.structureAnchorSearchMeters,
                distances: distances, values: raw)
            if span.endMeters - span.startMeters > Contract.maximumStructureLengthMeters {
                reason = "structure-too-long"
            } else if anchorStart == nil || anchorEnd == nil {
                reason = "missing-anchor"
            } else if let anchorStart, let anchorEnd {
                let run = distances[anchorEnd] - distances[anchorStart]
                let rise = raw[anchorEnd]! - raw[anchorStart]!
                if run <= 0 || abs(rise) / run > Contract.maximumStructureGrade {
                    reason = "implausible-anchor-grade"
                }
            }
            if span.resolution == Contract.structureUnresolved, reason == nil {
                reason = span.reason ?? "unresolved-association"
            }
            if let reason {
                for index in inside {
                    values[index] = nil
                    flags[index] |= Contract.flagStructureUnresolved | kindFlag
                }
                resolved.append(structure(span, resolution: Contract.structureUnresolved, reason: reason))
                continue
            }
            guard let anchorStart, let anchorEnd else { continue }
            let startDistance = distances[anchorStart]
            let endDistance = distances[anchorEnd]
            let startValue = raw[anchorStart]!
            let endValue = raw[anchorEnd]!
            if anchorEnd > anchorStart + 1 {
                for index in (anchorStart + 1)..<anchorEnd {
                    let fraction = (distances[index] - startDistance) / (endDistance - startDistance)
                    values[index] = startValue + fraction * (endValue - startValue)
                    flags[index] |= Contract.flagStructureEstimated | kindFlag
                    flags[index] &= ~Contract.flagStructureUnresolved
                }
            }
            resolved.append(structure(span, resolution: Contract.structureEstimated, reason: nil,
                                      anchorStart: startDistance, anchorEnd: endDistance))
        }
        return resolved
    }

    private static func structure(
        _ span: RouteElevationStructureSpanV1,
        resolution: String,
        reason: String?,
        anchorStart: Double? = nil,
        anchorEnd: Double? = nil
    ) -> RouteElevationProfileV1.Structure {
        RouteElevationProfileV1.Structure(
            kind: span.kind,
            startM: Contract.roundHalfAway(span.startMeters),
            endM: Contract.roundHalfAway(span.endMeters),
            resolution: resolution,
            osmWayIds: span.wayIDs,
            reason: reason,
            anchorStartM: Contract.roundOptional(anchorStart),
            anchorEndM: Contract.roundOptional(anchorEnd)
        )
    }

    static func fillShortGaps(distances: [Double], values: inout [Double?], flags: inout [Int]) {
        let count = values.count
        var index = 0
        while index < count {
            if values[index] != nil {
                index += 1
                continue
            }
            let start = index
            while index < count, values[index] == nil { index += 1 }
            let end = index
            if start == 0 || end >= count { continue }
            if (start..<end).contains(where: { flags[$0] & Contract.flagStructureUnresolved != 0 }) { continue }
            let before = start - 1
            let span = distances[end] - distances[before]
            if span > Contract.maximumInterpolatedGapMeters + Contract.distanceEpsilon { continue }
            let startValue = values[before]!
            let endValue = values[end]!
            for position in start..<end {
                let fraction = (distances[position] - distances[before]) / span
                values[position] = startValue + fraction * (endValue - startValue)
                flags[position] |= Contract.flagInterpolatedGap
            }
        }
    }

    static func smoothingHalfSamples(spacing: Double) -> Int {
        spacing <= Contract.smoothingMaximumSpacingMeters ? 1 : 0
    }

    static func gradeHalfWindow(spacing: Double) -> Double {
        max(Contract.gradeHalfWindowMeters, spacing)
    }

    static func smooth(_ values: [Double?], spacing: Double) -> [Double?] {
        guard smoothingHalfSamples(spacing: spacing) == 1 else { return values }
        return values.indices.map { index in
            guard let value = values[index] else { return nil }
            var total = value
            var count = 1.0
            for neighbor in [index - 1, index + 1] where values.indices.contains(neighbor) {
                if let neighborValue = values[neighbor] {
                    total += neighborValue
                    count += 1
                }
            }
            return total / count
        }
    }

    nonisolated struct HysteresisResult: Equatable {
        let ascent: Double
        let descent: Double
        let cumulativeAscent: [Double?]
    }

    static func hysteresisTotals(_ values: [Double?], threshold: Double = Contract.ascentHysteresisMeters)
        -> HysteresisResult {
        let count = values.count
        var descent = 0.0
        var climbs: [(Int, Int)] = []
        var index = 0
        while index < count {
            if values[index] == nil {
                index += 1
                continue
            }
            let runStart = index
            while index < count, values[index] != nil { index += 1 }
            let run = (runStart..<index).map { values[$0]! }
            let (runClimbs, runDescent) = hysteresisRun(run, threshold: threshold)
            descent += runDescent
            climbs.append(contentsOf: runClimbs.map { (runStart + $0.0, runStart + $0.1) })
        }
        var cumulative: [Double?] = []
        cumulative.reserveCapacity(count)
        var climbPosition = 0
        var completed = 0.0
        var runningMax: Double?
        for position in 0..<count {
            while climbPosition < climbs.count, position > climbs[climbPosition].1 {
                let (start, peak) = climbs[climbPosition]
                completed += values[peak]! - values[start]!
                climbPosition += 1
                runningMax = nil
            }
            guard let value = values[position] else {
                cumulative.append(nil)
                continue
            }
            var partial = 0.0
            if climbPosition < climbs.count {
                let (start, peak) = climbs[climbPosition]
                if start <= position, position <= peak {
                    let base = values[start]!
                    runningMax = runningMax.map { max($0, value) } ?? value
                    let gain = values[peak]! - base
                    partial = min(max(runningMax! - base, 0), gain)
                }
            }
            cumulative.append(completed + partial)
        }
        var ascent = 0.0
        for (start, peak) in climbs { ascent += values[peak]! - values[start]! }
        return HysteresisResult(ascent: ascent, descent: descent, cumulativeAscent: cumulative)
    }

    private static func hysteresisRun(_ run: [Double], threshold: Double) -> ([(Int, Int)], Double) {
        var climbs: [(Int, Int)] = []
        var descent = 0.0
        guard let first = run.first else { return (climbs, descent) }
        var direction = 0
        var low = first, high = first
        var lowIndex = 0, highIndex = 0
        var anchor = first
        var anchorIndex = 0
        var extreme = first
        var extremeIndex = 0
        for position in 1..<max(run.count, 1) where position < run.count {
            let value = run[position]
            if direction == 0 {
                if value < low { low = value; lowIndex = position }
                if value > high { high = value; highIndex = position }
                if high - low >= threshold {
                    if highIndex > lowIndex {
                        direction = 1
                        anchor = low; anchorIndex = lowIndex
                        extreme = high; extremeIndex = highIndex
                    } else {
                        direction = -1
                        anchor = high; anchorIndex = highIndex
                        extreme = low; extremeIndex = lowIndex
                    }
                }
            } else if direction == 1 {
                if value > extreme {
                    extreme = value; extremeIndex = position
                } else if extreme - value >= threshold {
                    climbs.append((anchorIndex, extremeIndex))
                    anchor = extreme; anchorIndex = extremeIndex
                    direction = -1
                    extreme = value; extremeIndex = position
                }
            } else {
                if value < extreme {
                    extreme = value; extremeIndex = position
                } else if value - extreme >= threshold {
                    descent += anchor - extreme
                    anchor = extreme; anchorIndex = extremeIndex
                    direction = 1
                    extreme = value; extremeIndex = position
                }
            }
        }
        if direction == 1 {
            climbs.append((anchorIndex, extremeIndex))
        } else if direction == -1 {
            descent += anchor - extreme
        }
        return (climbs, descent)
    }

    static func grades(distances: [Double], values: [Double?], flags: inout [Int], spacing: Double) -> [Double?] {
        let halfWindow = gradeHalfWindow(spacing: spacing)
        let count = values.count
        let ambiguous = Contract.flagStructureAmbiguous
        return (0..<count).map { index -> Double? in
            guard values[index] != nil, flags[index] & ambiguous == 0 else { return nil }
            let centre = distances[index]
            var window: [Int] = []
            var position = index
            while position >= 0, distances[position] >= centre - halfWindow - Contract.distanceEpsilon {
                guard values[position] != nil, flags[position] & ambiguous == 0 else { return nil }
                window.append(position)
                position -= 1
            }
            position = index + 1
            while position < count, distances[position] <= centre + halfWindow + Contract.distanceEpsilon {
                guard values[position] != nil, flags[position] & ambiguous == 0 else { return nil }
                window.append(position)
                position += 1
            }
            guard window.count >= 3 else { return nil }
            window.sort()
            let span = distances[window[window.count - 1]] - distances[window[0]]
            guard span >= halfWindow - Contract.distanceEpsilon else { return nil }
            var totalX = 0.0
            var totalY = 0.0
            for position in window {
                totalX += distances[position]
                totalY += values[position]!
            }
            let meanX = totalX / Double(window.count)
            let meanY = totalY / Double(window.count)
            var numerator = 0.0
            var denominator = 0.0
            for position in window {
                let dx = distances[position] - meanX
                numerator += dx * (values[position]! - meanY)
                denominator += dx * dx
            }
            guard denominator > 0 else { return nil }
            if window.contains(where: { flags[$0] & Contract.flagEstimated != 0 }) {
                flags[index] |= Contract.flagGradeEstimated
            }
            return numerator / denominator * 100
        }
    }

    static func assessQuality(
        distances: [Double],
        values: [Double?],
        flags: [Int],
        structures: [RouteElevationProfileV1.Structure]
    ) -> RouteElevationProfileV1.Quality {
        let count = distances.count
        let length = distances[count - 1] - distances[0]
        var valid = 0.0
        var estimated = 0.0
        var longestGap = 0.0
        var currentGap = 0.0
        for index in 0..<count {
            let lower = index == 0 ? distances[0] : (distances[index - 1] + distances[index]) / 2
            let upper = index == count - 1 ? distances[count - 1] : (distances[index] + distances[index + 1]) / 2
            let weight = upper - lower
            if values[index] == nil {
                currentGap += weight
                longestGap = max(longestGap, currentGap)
                continue
            }
            currentGap = 0
            valid += weight
            if flags[index] & Contract.flagEstimated != 0 { estimated += weight }
        }
        let unknown = max(0, length - valid)
        let coverage = length <= 0 ? 0 : min(1, valid / length)
        var reasons: [String] = []
        let validCount = values.filter { $0 != nil }.count
        if unknown > 0.5 { reasons.append("missing-elevation") }
        if structures.contains(where: { $0.resolution == Contract.structureUnresolved }) {
            reasons.append("unresolved-structure")
        }
        if structures.contains(where: { $0.resolution == Contract.structureAmbiguous }) {
            reasons.append("ambiguous-structure")
        }
        let status: String
        if validCount < 2 || coverage < Contract.unavailableCoverage {
            status = Contract.qualityUnavailable
        } else if !reasons.isEmpty {
            status = Contract.qualityPartial
        } else {
            status = Contract.qualityComplete
        }
        if estimated > 0 { reasons.append("estimated-elevation") }
        return RouteElevationProfileV1.Quality(
            status: status,
            coverage: Contract.roundHalfAway(coverage, digits: 4),
            validDistanceM: Contract.roundHalfAway(valid),
            estimatedDistanceM: Contract.roundHalfAway(estimated),
            unknownDistanceM: Contract.roundHalfAway(unknown),
            longestGapM: Contract.roundHalfAway(longestGap),
            reasons: reasons
        )
    }

    static func process(
        geometry: RouteElevationGeometryV1,
        plan: RouteElevationSamplingPlanV1,
        rawElevations: [Double?],
        source: RouteElevationProfileV1.Source,
        structures spans: [RouteElevationStructureSpanV1] = []
    ) -> RouteElevationProfileV1? {
        guard rawElevations.count == plan.distancesMeters.count else { return nil }
        let distances = plan.distancesMeters
        let raw = rawElevations.map(validElevation)
        var flags = raw.map { $0 == nil ? Contract.flagRawMissing : 0 }
        var working = raw
        let resolved = applyStructures(distances: distances, values: &working, flags: &flags, spans: spans)
        fillShortGaps(distances: distances, values: &working, flags: &flags)
        let processed = smooth(working, spacing: plan.spacingMeters)
        let gradeValues = grades(distances: distances, values: processed, flags: &flags,
                                 spacing: plan.spacingMeters)
        let totals = hysteresisTotals(processed)
        let quality = assessQuality(distances: distances, values: processed, flags: flags, structures: resolved)
        let known = processed.compactMap { $0 }
        let available = quality.status != Contract.qualityUnavailable
        let statistics = RouteElevationProfileV1.Statistics(
            totalAscentM: available ? Contract.roundHalfAway(totals.ascent) : nil,
            totalDescentM: available ? Contract.roundHalfAway(totals.descent) : nil,
            minimumElevationM: available ? Contract.roundOptional(known.min()) : nil,
            maximumElevationM: available ? Contract.roundOptional(known.max()) : nil,
            complete: quality.status == Contract.qualityComplete,
            includesEstimated: quality.estimatedDistanceM > 0
        )
        return RouteElevationProfileV1(
            schema: Contract.profileSchema,
            processingVersion: Contract.processingVersion,
            geometry: .init(
                digest: geometry.digest,
                pointCount: geometry.pointCount,
                lengthM: Contract.roundHalfAway(geometry.lengthMeters),
                crs: "EPSG:4326",
                precision: "microdegrees"
            ),
            sampling: .init(
                method: "uniform-distance",
                spacingM: plan.spacingMeters,
                sampleCount: distances.count,
                smoothingHalfSamples: smoothingHalfSamples(spacing: plan.spacingMeters),
                ascentHysteresisM: Contract.ascentHysteresisMeters,
                gradeHalfWindowM: gradeHalfWindow(spacing: plan.spacingMeters),
                maximumInterpolatedGapM: Contract.maximumInterpolatedGapMeters
            ),
            source: source,
            samples: .init(
                distanceM: distances.map { Contract.roundHalfAway($0) },
                elevationM: processed.map { Contract.roundOptional($0) },
                rawElevationM: raw.map { Contract.roundOptional($0) },
                gradePercent: gradeValues.map { Contract.roundOptional($0) },
                cumulativeAscentM: totals.cumulativeAscent.map { Contract.roundOptional($0) },
                flags: flags
            ),
            structures: resolved,
            structureCorrection: .init(
                status: "unavailable", source: nil, sourceVersion: nil, attribution: [],
                reason: "no-structure-source"
            ),
            statistics: statistics,
            quality: quality
        )
    }
}

/// Decides whether imported GPX `<ele>` values are trustworthy enough to be the
/// profile source. Presence of `<ele>` alone is not enough.
nonisolated enum RouteElevationGPXTrustV1 {
    nonisolated enum Decision: Equatable {
        case trusted([Double?])
        case untrusted(reason: String)
    }

    static let minimumCoverage = 0.8
    static let maximumSpikeFraction = 0.05
    static let spikeStepMeters = 25.0
    static let spikeDistanceMeters = 100.0
    static let zeroRunLength = 5
    static let zeroNeighbourMeters = 20.0

    static func evaluate(vertexElevations values: [Double?], cumulativeMeters: [Double]) -> Decision {
        typealias Contract = RouteElevationContractV1
        guard values.count == cumulativeMeters.count, values.count >= 2 else {
            return .untrusted(reason: "missing-elevation")
        }
        var cleaned = values.map { value -> Double? in
            guard let value, value.isFinite,
                  value >= Contract.minimumValidElevationMeters,
                  value <= Contract.maximumValidElevationMeters else { return nil }
            return value
        }
        let present = cleaned.compactMap { $0 }
        if present.count >= 10, present.allSatisfy({ $0 == 0 }) {
            return .untrusted(reason: "zero-filled-elevation")
        }
        // Remove zero runs that are clearly fill values between real heights.
        var index = 0
        while index < cleaned.count {
            guard cleaned[index] == 0 else {
                index += 1
                continue
            }
            let start = index
            while index < cleaned.count, cleaned[index] == 0 { index += 1 }
            guard index - start >= zeroRunLength else { continue }
            let before = start > 0 ? cleaned[start - 1] : nil
            let after = index < cleaned.count ? cleaned[index] : nil
            if [before, after].contains(where: { $0.map { abs($0) > zeroNeighbourMeters } ?? false }) {
                for position in start..<index { cleaned[position] = nil }
            }
        }
        // Isolated spikes: a sample far from both close neighbours in the same direction.
        var spikes = 0
        if cleaned.count >= 3 {
            for position in 1..<(cleaned.count - 1) {
                guard let previous = cleaned[position - 1], let value = cleaned[position],
                      let next = cleaned[position + 1] else { continue }
                let nearPrevious = cumulativeMeters[position] - cumulativeMeters[position - 1] <= spikeDistanceMeters
                let nearNext = cumulativeMeters[position + 1] - cumulativeMeters[position] <= spikeDistanceMeters
                let up = value - previous > spikeStepMeters && value - next > spikeStepMeters
                let down = previous - value > spikeStepMeters && next - value > spikeStepMeters
                if nearPrevious, nearNext, up || down {
                    cleaned[position] = nil
                    spikes += 1
                }
            }
        }
        if Double(spikes) > maximumSpikeFraction * Double(values.count) {
            return .untrusted(reason: "noisy-elevation")
        }
        let coverage = Double(cleaned.compactMap { $0 }.count) / Double(values.count)
        guard coverage >= minimumCoverage else { return .untrusted(reason: "missing-elevation") }
        return .trusted(cleaned)
    }

    static let source = RouteElevationProfileV1.Source(
        kind: "gpx",
        id: "gpx-ele",
        version: nil,
        verticalDatum: nil,
        nativeResolutionM: nil,
        surfaceModel: nil,
        interpolation: "linear-vertex",
        attribution: [],
        retrievedAt: nil,
        qualification: "user-supplied"
    )
}
