import CoreLocation
import CoreGraphics
import Foundation

struct SocialCapabilities: Codable, Equatable {
    var media = false
    var routes = false
    var activities = false
    var groups = false
    var hardware = false
    var invitePreviews = false
    var savedMapKitRoutes = false
    var friendSharing = false
    enum CodingKeys: String, CodingKey { case media, routes, activities, groups, hardware, invitePreviews, savedMapKitRoutes, friendSharing }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? false
        routes = try c.decodeIfPresent(Bool.self, forKey: .routes) ?? false
        activities = try c.decodeIfPresent(Bool.self, forKey: .activities) ?? false
        groups = try c.decodeIfPresent(Bool.self, forKey: .groups) ?? false
        hardware = try c.decodeIfPresent(Bool.self, forKey: .hardware) ?? false
        invitePreviews = try c.decodeIfPresent(Bool.self, forKey: .invitePreviews) ?? false
        friendSharing = try c.decodeIfPresent(Bool.self, forKey: .friendSharing) ?? false
        savedMapKitRoutes = try c.decodeIfPresent(Bool.self, forKey: .savedMapKitRoutes) ?? false
    }
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
    let movingSeconds: Double?
    let elapsedSeconds: Double?
    let sequence: Int
    let routeProgressMeters: Double?
    let routeHash: String?
    let ageSeconds: Double
    private let observedAt = ProcessInfo.processInfo.systemUptime
    enum CodingKeys: String, CodingKey {
        case profile, latitude, longitude, capturedAt, receivedAt, horizontalAccuracy, course, speed, distanceMeters, movingSeconds, elapsedSeconds, sequence, routeProgressMeters, routeHash
        case ageSeconds = "age"
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    func age(at now: Date) -> TimeInterval { max(0, ageSeconds + ProcessInfo.processInfo.systemUptime-observedAt) }

    /// Age advances locally; an unchanged publication needs no new map render.
    func displaysSameState(as other: SocialRider) -> Bool {
        profile == other.profile && latitude == other.latitude && longitude == other.longitude &&
        capturedAt == other.capturedAt && receivedAt == other.receivedAt &&
        horizontalAccuracy == other.horizontalAccuracy && course == other.course && speed == other.speed &&
        distanceMeters == other.distanceMeters && movingSeconds == other.movingSeconds &&
        elapsedSeconds == other.elapsedSeconds && sequence == other.sequence &&
        routeProgressMeters == other.routeProgressMeters && routeHash == other.routeHash
    }
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
    let sharingExpiresAt: Double?
    let invitationCodeNeedsRotation: Bool?
}

struct SocialQuickMessage: Decodable, Identifiable {
    let id: String
    let sender: String
    let status: String
    let created: Double
}

/// Capability secrets stay in URL fragments, which are never sent to the website.
struct SocialLinkTarget {
    let kind: String
    let id: String
    let canonicalURL: URL
    init?(url: URL) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if ["bikecomputer", "bikecomputer-dev"].contains(url.scheme ?? ""), url.host == "social" {
            components?.scheme = "https"; components?.host = "bicino.com"
            components?.path = "/social" + url.path
        }
        guard let parts = components, parts.scheme == "https", parts.host == "bicino.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              let canonical = parts.url else { return nil }
        let path = canonical.pathComponents
        guard path.count >= 3, path[1] == "social" else { return nil }
        kind = path[2]
        if kind == "profile", path.count == 4, parts.fragment == nil { id = path[3] }
        else if ["ride", "shared"].contains(kind), (path.count == 3 || (kind == "ride" && path.count == 4 && UUID(uuidString: path[3]) != nil)), let secret = parts.fragment { id = secret }
        else { return nil }
        guard id.range(of: "^[A-Za-z0-9_-]{20,100}$", options: .regularExpression) != nil else { return nil }
        canonicalURL = canonical
    }
}

/// Portrait, initials, distance and grouped count all follow one friend-marker size.
struct SocialMapMarkerStyle: Equatable {
    var scale: FriendMarkerScale = .normal
    private var factor: CGFloat { CGFloat(scale.factor) }
    var pictureDiameter: CGFloat { 40 * factor }
    var numberHeight: CGFloat { 20 * factor }
    /// Distance labels keep their normal width and grow more slowly than the
    /// portrait, so 3× edge badges still fit a small phone.
    var distanceWidth: CGFloat { max(96, 72 * factor) }
    var clusterWidth: CGFloat { 27 * factor }
    var initialsFontSize: CGFloat { 15 * factor }
    var numberFontSize: CGFloat { 12 * factor }
    /// Edge badges carry the distance label and grouped count around the portrait.
    var badgeSize: CGSize {
        CGSize(width: max(distanceWidth, pictureDiameter + clusterWidth / 2 + 8),
               height: pictureDiameter + numberHeight + 2)
    }
    /// On-map markers show only the portrait, so their tappable area is the portrait.
    var annotationSize: CGSize { CGSize(width: pictureDiameter + 4, height: pictureDiameter + 4) }
    /// The rider's coordinate stays at the portrait's bottom centre at every size.
    var annotationCenterOffset: CGPoint {
        CGPoint(x: 0, y: annotationSize.height / 2 - (pictureDiameter + 2))
    }

    /// A rider stays on the map while its whole portrait is visible; only clipped
    /// or off-screen riders become edge badges.
    func showsOnMap(_ point: CGPoint, in bounds: CGRect) -> Bool {
        let radius = pictureDiameter / 2
        return point.x - radius >= bounds.minX + 11 && point.x + radius <= bounds.maxX - 11
            && point.y - pictureDiameter >= bounds.minY + 15 && point.y <= bounds.maxY - 15
    }
}

/// Projected coordinates already include camera rotation, panning and perspective.
enum SocialMapGeometry {
    static func edgeCenter(projected: CGPoint, bounds: CGRect,
                           badgeSize: CGSize = CGSize(width: 48, height: 60)) -> CGPoint? {
        let safe = bounds.insetBy(dx: badgeSize.width / 2 + 18, dy: badgeSize.height / 2 + 40)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = projected.x-center.x, dy = projected.y-center.y
        guard dx.isFinite, dy.isFinite, safe.width > 0, safe.height > 0,
              abs(dx)+abs(dy) > 0.0001 else { return nil }
        let tx = abs(dx) > 0.0001 ? safe.width/2/abs(dx) : CGFloat.greatestFiniteMagnitude
        let ty = abs(dy) > 0.0001 ? safe.height/2/abs(dy) : CGFloat.greatestFiniteMagnitude
        let scale = min(tx, ty)
        return CGPoint(x: center.x+scale*dx, y: center.y+scale*dy)
    }
}

struct SocialFriendConsent: Decodable {
    let profileID: String
    let epoch: String
    let sharing: Bool
    let sharingExpiresAt: Double?
    let serverTime: Double
}

struct SocialFriendSnapshot: Decodable {
    let outgoing: [SocialFriendConsent]
    let riders: [SocialRider]
    let serverTime: Double
}
