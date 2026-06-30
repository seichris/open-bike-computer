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
    let iconID: Int
    let distance: Int
    let instruction: String

    var packet: String {
        "\(iconID)|\(distance)|\(instruction)"
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
