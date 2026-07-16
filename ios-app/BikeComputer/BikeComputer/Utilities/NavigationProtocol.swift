//
//  NavigationProtocol.swift
//  BikeComputer
//
//  Testable navigation helpers shared by route UI and BLE packet generation.
//

import Foundation
import CoreLocation
import MapKit

enum DeviceDestinationKind: String, Codable, Equatable {
    case favorite
    case recent
}

struct DeviceDestinationCatalogItem: Codable, Equatable {
    let token: UInt16
    let kind: DeviceDestinationKind
    let label: String
}

struct DeviceDestinationCatalogPayload: Codable, Equatable {
    let version: UInt8
    let generation: UInt32
    let items: [DeviceDestinationCatalogItem]
}

struct DeviceDestinationCatalogBuild {
    let payload: DeviceDestinationCatalogPayload
    let destinationsByToken: [UInt16: SavedDestination]
    let sourceFingerprint: String
}

enum DeviceDestinationCatalogGeneration {
    static func initial(
        randomValue: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) -> UInt32 {
        randomValue == 0 ? 1 : randomValue
    }

    static func next(after current: UInt32) -> UInt32 {
        current == UInt32.max ? 1 : current + 1
    }
}

enum DeviceDestinationCatalogSyncPolicy {
    static func shouldPublish(
        force: Bool,
        lastFingerprint: String?,
        nextFingerprint: String
    ) -> Bool {
        force || lastFingerprint != nextFingerprint
    }
}

enum DeviceDestinationLocationPolicy {
    static let maximumAge: TimeInterval = 5
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 100
    static let maximumFutureSkew: TimeInterval = 5

    static func isUsable(_ location: CLLocation, now: Date = Date()) -> Bool {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return false
        }
        let age = now.timeIntervalSince(location.timestamp)
        return age >= -maximumFutureSkew && age <= maximumAge
    }
}

enum DeviceDestinationRequestTiming {
    static let locationRefreshTimeout: TimeInterval = 5
    static let firmwareRequestTimeout: TimeInterval = 15
    // Leave enough time for the terminal DNST write to reach firmware before
    // its own pending-request timeout expires.
    static let appRequestDeadline: TimeInterval = 13
}

enum DeviceDestinationStatusRetryPolicy {
    static let maximumRetryCount = 2
    static let retryDelay: TimeInterval = 0.15

    static func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maximumRetryCount
    }
}

enum DeviceDestinationCatalogBuilder {
    static let version: UInt8 = 1
    static let favoriteLimit = 3
    static let labelMaxBytes = 64

    static func build(
        favorites: [SavedDestination],
        generation: UInt32
    ) -> DeviceDestinationCatalogBuild {
        var selected: [(
            kind: DeviceDestinationKind,
            destination: SavedDestination,
            label: String
        )] = []
        var seenIdentities = Set<String>()

        for destination in favorites where selected.count < favoriteLimit {
            let label = utf8Prefix(destination.name, maxBytes: labelMaxBytes)
            let identity = destinationIdentity(destination)
            guard !label.isEmpty,
                  seenIdentities.insert(identity).inserted else { continue }
            selected.append((.favorite, destination, label))
        }

        var destinationsByToken: [UInt16: SavedDestination] = [:]
        let items = selected.enumerated().map { index, entry in
            let token = UInt16(index + 1)
            destinationsByToken[token] = entry.destination
            return DeviceDestinationCatalogItem(
                token: token,
                kind: entry.kind,
                label: entry.label
            )
        }
        let fingerprintParts: [String] = selected.map { entry in
            let kind = entry.kind
            let destination = entry.destination
            let latitude = destination.latitude.map { String($0) } ?? "-"
            let longitude = destination.longitude.map { String($0) } ?? "-"
            return "\(kind.rawValue)|\(destination.id.uuidString)|\(latitude)|\(longitude)|\(destination.name)"
        }
        let fingerprint = fingerprintParts.joined(separator: "\u{1F}")

        return DeviceDestinationCatalogBuild(
            payload: DeviceDestinationCatalogPayload(
                version: version,
                generation: generation,
                items: items
            ),
            destinationsByToken: destinationsByToken,
            sourceFingerprint: fingerprint
        )
    }

    static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var sanitized = ""
        for scalar in value.unicodeScalars {
            if scalar.value == 0 {
                continue
            }
            sanitized.unicodeScalars.append(
                CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
            )
        }
        var result = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.utf8.count > maxBytes && !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func destinationIdentity(_ destination: SavedDestination) -> String {
        if let coordinate = destination.coordinate {
            return String(format: "coordinate|%.5f|%.5f", locale: Locale(identifier: "en_US_POSIX"),
                          coordinate.latitude, coordinate.longitude)
        }
        return "query|\(destination.name.lowercased())"
    }
}

enum DeviceDestinationCatalogChunker {
    static let headerSize = 7
    static let maxChunkCount = 160
    static let maxCatalogBytes = 4096

    static func frames(
        payload: DeviceDestinationCatalogPayload,
        transferID: UInt8,
        maximumWriteLength: Int
    ) -> [Data]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              data.count <= maxCatalogBytes,
              maximumWriteLength > headerSize else {
            return nil
        }

        let payloadLength = maximumWriteLength - headerSize
        let chunkCount = max(1, (data.count + payloadLength - 1) / payloadLength)
        guard chunkCount <= maxChunkCount, chunkCount <= Int(UInt8.max) else { return nil }

        return (0..<chunkCount).map { index in
            let start = index * payloadLength
            let end = min(start + payloadLength, data.count)
            var frame = Data(DeviceBLEProtocol.destinationCatalogChunkPrefix.utf8)
            frame.append(transferID)
            frame.append(UInt8(index))
            frame.append(UInt8(chunkCount))
            frame.append(data.subdata(in: start..<end))
            return frame
        }
    }
}

struct DeviceDestinationRequest: Equatable {
    let generation: UInt32
    let token: UInt16

    static func parse(_ data: Data) -> DeviceDestinationRequest? {
        guard data.count == 10,
              String(data: data.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.destinationRequestPrefix else { return nil }
        return DeviceDestinationRequest(
            generation: data.readUInt32LE(at: 4),
            token: data.readUInt16LE(at: 8)
        )
    }
}

enum DeviceDestinationStatusCode: UInt8, Equatable {
    case calculating = 1
    case started = 2
    case failed = 3
    case stale = 4
}

enum DeviceDestinationStatusPacketBuilder {
    static let messageMaxBytes = 64

    static func data(
        generation: UInt32,
        token: UInt16,
        status: DeviceDestinationStatusCode,
        message: String,
        maximumLength: Int = 11 + messageMaxBytes
    ) -> Data {
        var data = Data(DeviceBLEProtocol.destinationStatusPrefix.utf8)
        data.appendUInt32LE(generation)
        data.appendUInt16LE(token)
        data.append(status.rawValue)
        let availableMessageBytes = max(0, maximumLength - data.count)
        data.append(Data(DeviceDestinationCatalogBuilder.utf8Prefix(
            message,
            maxBytes: min(messageMaxBytes, availableMessageBytes)
        ).utf8))
        return data
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

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

enum RouteDeviation {
    static func distance(from location: CLLocation, to polyline: MKPolyline) -> CLLocationDistance? {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return nil }

        let routePoints = polyline.points()
        let target = MKMapPoint(location.coordinate)
        if pointCount == 1 {
            return target.distance(to: routePoints[0])
        }

        var closestDistance = Double.greatestFiniteMagnitude
        for index in 0..<(pointCount - 1) {
            let start = routePoints[index]
            let end = routePoints[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLengthSquared = dx * dx + dy * dy

            guard segmentLengthSquared > 0 else {
                closestDistance = min(closestDistance, target.distance(to: start))
                continue
            }

            let rawProjection = ((target.x - start.x) * dx + (target.y - start.y) * dy) / segmentLengthSquared
            let projection = min(max(rawProjection, 0), 1)
            let projected = MKMapPoint(x: start.x + projection * dx, y: start.y + projection * dy)
            closestDistance = min(closestDistance, target.distance(to: projected))
        }

        return closestDistance.isFinite ? closestDistance : nil
    }
}

struct RouteDeviationDetector {
    let distanceThreshold: CLLocationDistance
    let requiredConsecutiveSamples: Int
    let maxHorizontalAccuracy: CLLocationAccuracy
    private(set) var consecutiveOffRouteSamples = 0

    init(
        distanceThreshold: CLLocationDistance = 30,
        requiredConsecutiveSamples: Int = 3,
        maxHorizontalAccuracy: CLLocationAccuracy = 50
    ) {
        self.distanceThreshold = distanceThreshold
        self.requiredConsecutiveSamples = max(requiredConsecutiveSamples, 1)
        self.maxHorizontalAccuracy = maxHorizontalAccuracy
    }

    mutating func reset() {
        consecutiveOffRouteSamples = 0
    }

    mutating func shouldReroute(
        distanceToRoute: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy
    ) -> Bool {
        guard distanceToRoute.isFinite,
              horizontalAccuracy >= 0,
              horizontalAccuracy <= maxHorizontalAccuracy else {
            reset()
            return false
        }

        let accuracyAdjustedThreshold = max(distanceThreshold, horizontalAccuracy * 2)
        guard distanceToRoute > accuracyAdjustedThreshold else {
            reset()
            return false
        }

        consecutiveOffRouteSamples += 1
        guard consecutiveOffRouteSamples >= requiredConsecutiveSamples else { return false }

        reset()
        return true
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
