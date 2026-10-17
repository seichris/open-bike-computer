import CoreLocation
import Foundation

struct SocialCapabilities: Codable, Equatable {
    var media = false
    var routes = false
    var activities = false
    var groups = false
    var hardware = false
}

struct SocialProfile: Codable, Identifiable, Equatable {
    let id: String
    let username: String?
    let displayName: String
    let avatarID: String?
    let version: Int?
    let privacy: SocialPrivacy?
    var initials: String { String(displayName.split(separator: " ").prefix(2).compactMap(\.first)) }
}

struct SocialPrivacy: Codable, Equatable {
    var zones: [SocialZone] = []
    var requests = true
    var invitations = true
    var notifications = true
    var friendNotifications = true
    var rideNotifications = true
}

struct SocialZone: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var radius: Double
}

struct SocialPoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct SocialPage<Item: Decodable>: Decodable {
    let items: [Item]
    let cursor: String?
}

struct SocialFriendRequest: Decodable, Identifiable {
    let id: String
    let a: String
    let b: String
    let sender: String
    let status: String
}

struct SocialContentBody: Codable {
    let archive: String?
    let sha256: String?
    let segments: [[SocialPoint]]?
    let distanceMeters: Double?
    let movingSeconds: Double?
    let elapsedSeconds: Double?
    let averageSpeed: Double?
    let needsReprocessing: Bool?
}

struct SocialContent: Codable, Identifiable {
    let id: String
    let owner: String
    let kind: String
    let title: String
    let visibility: String
    let revision: Int
    let body: SocialContentBody
}

struct SocialInvite: Decodable, Identifiable {
    let id: String
    let ride: String
    let sender: String
    let recipient: String
    let status: String
    let expires: Double
    let title: String?
    let route: SocialContentBody?
    let startsAt: Double?
}

struct SocialRider: Decodable, Identifiable {
    var id: String { profile.id }
    let profile: SocialProfile
    let latitude: Double
    let longitude: Double
    let capturedAt: Double
    let receivedAt: Double
    let horizontalAccuracy: Double
    let course: Double?
    let speed: Double?
    let distanceMeters: Double?
    let sequence: Int
    let routeProgressMeters: Double?
    let routeHash: String?
    let ageSeconds: Double
    private let observedAt = ProcessInfo.processInfo.systemUptime
    enum CodingKeys: String, CodingKey {
        case profile, latitude, longitude, capturedAt, receivedAt, horizontalAccuracy, course, speed, distanceMeters, sequence, routeProgressMeters, routeHash
        case ageSeconds = "age"
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    func age(at now: Date) -> TimeInterval { max(0, ageSeconds + ProcessInfo.processInfo.systemUptime-observedAt) }
}

struct SocialGroupRide: Decodable, Identifiable {
    let id: String
    let owner: String
    let title: String
    let status: String
    let expiresAt: Double
    let route: SocialContentBody
    let members: [SocialProfile]
    let riders: [SocialRider]
    let sharing: Bool
    let stats: Bool
    let epoch: String
    let serverTime: Double
    let joinCode: String?
}

struct SocialQuickMessage: Decodable, Identifiable {
    let id: String
    let sender: String
    let status: String
    let created: Double
}
