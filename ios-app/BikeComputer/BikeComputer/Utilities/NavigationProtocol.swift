//
//  NavigationProtocol.swift
//  BikeComputer
//
//  Testable navigation helpers shared by route UI and BLE packet generation.
//

import CoreLocation
import MapKit

enum NavigationInstructionMapper {
    static func iconID(for instruction: String) -> Int {
        let lower = instruction.lowercased()

        if lower.contains("u-turn") || lower.contains("uturn") {
            return NavigationIconID.uTurn
        } else if lower.contains("left") {
            return NavigationIconID.left
        } else if lower.contains("right") {
            return NavigationIconID.right
        } else {
            return NavigationIconID.straight
        }
    }
}

enum RoutePolylineEndpoint {
    static func location(for polyline: MKPolyline) -> CLLocation? {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return nil }

        var coordinate = CLLocationCoordinate2D()
        polyline.getCoordinates(&coordinate, range: NSRange(location: pointCount - 1, length: 1))
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

enum RouteProgress {
    private struct ProjectionCandidate {
        let crossTrackDistance: CLLocationDistance
        let distanceAlongPolyline: CLLocationDistance
    }

    private static let minimumAmbiguityTolerance: CLLocationDistance = 10

    static func remainingDistance(from location: CLLocation, in route: MKRoute) -> CLLocationDistance? {
        remainingDistance(
            from: location,
            along: route.polyline,
            referenceDistance: route.distance,
            preferredRemainingDistance: nil,
            ambiguityTolerance: minimumAmbiguityTolerance
        )
    }

    static func remainingDistance(
        from location: CLLocation,
        in step: MKRoute.Step,
        preferredRemainingDistance: CLLocationDistance? = nil,
        ambiguityTolerance: CLLocationDistance = minimumAmbiguityTolerance
    ) -> CLLocationDistance? {
        remainingDistance(
            from: location,
            along: step.polyline,
            referenceDistance: step.distance,
            preferredRemainingDistance: preferredRemainingDistance,
            ambiguityTolerance: ambiguityTolerance
        )
    }

    private static func remainingDistance(
        from location: CLLocation,
        along polyline: MKPolyline,
        referenceDistance: CLLocationDistance,
        preferredRemainingDistance: CLLocationDistance?,
        ambiguityTolerance requestedAmbiguityTolerance: CLLocationDistance
    ) -> CLLocationDistance? {
        let pointCount = polyline.pointCount
        guard pointCount > 1 else { return nil }

        let polylinePoints = polyline.points()
        let target = MKMapPoint(location.coordinate)
        var totalDistance: CLLocationDistance = 0
        var candidates: [ProjectionCandidate] = []

        for index in 0..<(pointCount - 1) {
            let start = polylinePoints[index]
            let end = polylinePoints[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLengthSquared = dx * dx + dy * dy
            let segmentLength = start.distance(to: end)

            if segmentLengthSquared > 0 {
                let rawProjection = ((target.x - start.x) * dx + (target.y - start.y) * dy) / segmentLengthSquared
                let projection = min(max(rawProjection, 0), 1)
                let projected = MKMapPoint(x: start.x + projection * dx, y: start.y + projection * dy)
                let distanceToSegment = target.distance(to: projected)
                candidates.append(ProjectionCandidate(
                    crossTrackDistance: distanceToSegment,
                    distanceAlongPolyline: totalDistance + start.distance(to: projected)
                ))
            }

            totalDistance += segmentLength
        }

        guard totalDistance > 0, !candidates.isEmpty else { return nil }

        let measuredDistance = referenceDistance.isFinite && referenceDistance > 0
            ? referenceDistance
            : totalDistance

        func remainingDistance(for candidate: ProjectionCandidate) -> CLLocationDistance {
            let scaledDistanceAlongPolyline =
                (candidate.distanceAlongPolyline / totalDistance) * measuredDistance
            return max(measuredDistance - scaledDistanceAlongPolyline, 0)
        }

        let closestCrossTrackDistance = candidates
            .map(\.crossTrackDistance)
            .min() ?? Double.greatestFiniteMagnitude
        let reportedAccuracy = location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
            ? location.horizontalAccuracy
            : 0
        let sanitizedAmbiguityTolerance = requestedAmbiguityTolerance.isFinite
            && requestedAmbiguityTolerance >= 0
            ? requestedAmbiguityTolerance
            : 0
        let ambiguityTolerance = max(
            max(reportedAccuracy, sanitizedAmbiguityTolerance),
            minimumAmbiguityTolerance
        )
        let plausibleCandidates = candidates.filter {
            $0.crossTrackDistance <= closestCrossTrackDistance + ambiguityTolerance
        }

        let selectedCandidate: ProjectionCandidate?
        if let preferredRemainingDistance,
           preferredRemainingDistance.isFinite,
           preferredRemainingDistance >= 0 {
            selectedCandidate = plausibleCandidates.min { lhs, rhs in
                let lhsProgressDelta = abs(remainingDistance(for: lhs) - preferredRemainingDistance)
                let rhsProgressDelta = abs(remainingDistance(for: rhs) - preferredRemainingDistance)
                if lhsProgressDelta == rhsProgressDelta {
                    return lhs.crossTrackDistance < rhs.crossTrackDistance
                }
                return lhsProgressDelta < rhsProgressDelta
            }
        } else {
            selectedCandidate = candidates.min {
                $0.crossTrackDistance < $1.crossTrackDistance
            }
        }

        guard let selectedCandidate else { return nil }
        return remainingDistance(for: selectedCandidate)
    }
}

enum RouteEndpointSelection {
    static func sourceEndpoint(hasSelectedSource: Bool, sourceAddress: String) -> RouteEndpoint {
        hasSelectedSource ? .query(sourceAddress) : .currentLocation
    }
}

enum RouteInitialLocation {
    static func location(for coordinate: CLLocationCoordinate2D) -> CLLocation {
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

enum RouteTransportTypes {
    static let cycling = MKDirectionsTransportType(rawValue: 1 << 3)
}

enum DeviceGPSPacketBuilder {
    static let invalidSpeedCmps = UInt16.max
    static let invalidRouteRemainingMeters = UInt32.max

    static func data(
        lat: Double,
        lon: Double,
        heading: Double = 0,
        unixTime: UInt32 = UInt32(Date().timeIntervalSince1970),
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        routeRemainingMeters: Double? = nil
    ) -> Data {
        var data = Data()
        let latInt = Int32(lat * 1_000_000)
        let lonInt = Int32(lon * 1_000_000)
        let headingDeg: UInt16 = heading >= 0 ? UInt16(min(heading, 359)) : 0
        let speedCmps: UInt16 = {
            guard let speedMetersPerSecond, speedMetersPerSecond >= 0 else {
                return invalidSpeedCmps
            }
            return UInt16(min((speedMetersPerSecond * 100).rounded(), Double(UInt16.max - 1)))
        }()
        let altitudeInt = Int16(max(min((altitudeMeters ?? 0).rounded(), Double(Int16.max)), Double(Int16.min)))
        let distanceInt = UInt32(max(min((distanceTraveledMeters ?? 0).rounded(), Double(UInt32.max)), 0))
        let elapsedInt = UInt32(max(min((elapsedSeconds ?? 0).rounded(), Double(UInt32.max)), 0))
        let routeRemainingInt: UInt32 = {
            guard let routeRemainingMeters, routeRemainingMeters >= 0 else {
                return invalidRouteRemainingMeters
            }
            return UInt32(max(min(routeRemainingMeters.rounded(), Double(UInt32.max - 1)), 0))
        }()

        withUnsafeBytes(of: latInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: lonInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: headingDeg.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: unixTime.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: speedCmps.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: altitudeInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: distanceInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: elapsedInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: routeRemainingInt.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

enum NavigationPacketBuilder {
    static let protocolMaxBytes = 96
    static let instructionMaxBytes = 63

    static func data(from packet: String, maxLength: Int) -> Data? {
        guard maxLength > 0 else { return nil }

        let parts = packet.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let prefix = "\(parts[0])|\(parts[1])|"
        guard let prefixData = prefix.data(using: .utf8), prefixData.count < maxLength else {
            return nil
        }

        let maxInstructionBytes = min(instructionMaxBytes, maxLength - prefixData.count)
        guard maxInstructionBytes > 0 else { return nil }

        var instruction = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction.isEmpty {
            instruction = "Continue"
        }
        while let instructionData = instruction.data(using: .utf8), instructionData.count > maxInstructionBytes {
            guard !instruction.isEmpty else { return nil }
            instruction.removeLast()
        }
        if instruction.isEmpty {
            instruction = "Continue"
        }

        return "\(prefix)\(instruction)".data(using: .utf8)
    }
}

struct NavigationManeuverSnapshot: Equatable {
    static let maximumTransportDistance = Int(UInt16.max)

    let iconID: Int
    let distance: Int
    let instruction: String

    var packet: String {
        let transportDistance = min(max(distance, 0), Self.maximumTransportDistance)
        return "\(iconID)|\(transportDistance)|\(instruction)"
    }
}

struct NavigationSendTracker {
    let distanceThreshold: Int
    private var lastSentSnapshot: NavigationManeuverSnapshot?

    init(distanceThreshold: Int) {
        self.distanceThreshold = distanceThreshold
    }

    mutating func reset() {
        lastSentSnapshot = nil
    }

    mutating func resetForReadinessRetry() {
        lastSentSnapshot = nil
    }

    mutating func markSent(_ snapshot: NavigationManeuverSnapshot) {
        lastSentSnapshot = snapshot
    }

    func shouldSend(_ snapshot: NavigationManeuverSnapshot) -> Bool {
        guard let lastSentSnapshot else {
            return true
        }

        if snapshot.instruction != lastSentSnapshot.instruction {
            return true
        }

        if snapshot.iconID != lastSentSnapshot.iconID {
            return true
        }

        return abs(snapshot.distance - lastSentSnapshot.distance) >= distanceThreshold
    }
}
