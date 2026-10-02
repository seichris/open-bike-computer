import Combine
import CryptoKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class SocialCoordinator: ObservableObject {
    let session: BicinoUserSession
    let client: BicinoSocialClient
    let live: LiveRideService
    @Published private(set) var profile: SocialProfile?
    @Published private(set) var friends: [SocialProfile] = []
    @Published private(set) var requests: [SocialFriendRequest] = []
    @Published private(set) var blocked: [SocialProfile] = []
    @Published private(set) var rides: [SocialGroupRide] = []
    @Published private(set) var invitations: [SocialInvite] = []
    @Published private(set) var sentInvitations: [SocialInvite] = []
    @Published private(set) var routes: [SocialContent] = []
    @Published private(set) var activities: [SocialContent] = []
    @Published private(set) var photos: [String: UIImage] = [:]
    @Published var error: String?
    @Published var pendingLink: URL?
    private var pushToken: String?
    private let pushBinding = UUID().uuidString
    func enableNotifications() async throws {
        if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    func didRegisterNotifications(_ data: Data) {
        pushToken = data.map { String(format: "%02x", $0) }.joined()
        Task { try? await bindNotifications() }
    }
    private func bindNotifications() async throws {
        guard session.state == .signedIn, let pushToken else { return }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        _ = try await client.json("notification-devices/\(pushBinding)", method: "PUT", body: ["token": pushToken, "environment": environment])
    }
    private var relay: SocialBLERelay?
    func bindBLE(_ ble: BLEManager) { relay = SocialBLERelay(ble: ble, social: self) }
    private var observers = Set<AnyCancellable>()

    init() {
        let session = BicinoUserSession()
        self.session = session
        let client = BicinoSocialClient(session: session)
        self.client = client
        live = LiveRideService(client: client)
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        session.$generation.dropFirst().sink { [weak self] _ in self?.clear() }.store(in: &observers)
        live.onRidersChanged = { [weak self] riders in
            Task { @MainActor [weak self] in await self?.loadPhotos(riders.map(\.profile)) }
        }
    }

    func clear() {
        profile = nil; friends = []; requests = []; invitations = []; sentInvitations = []
        routes = []; activities = []; photos = [:]; rides = []; blocked = []
        live.reset()
    }

    func refresh() async throws {
        let expected = session.generation
        let me = try JSONDecoder().decode(SocialProfile.self, from: await client.request("me"))
        let friends: [SocialProfile] = try await pages("friends")
        let requests: [SocialFriendRequest] = try await pages("friend-requests")
        let invites = try JSONDecoder().decode(SocialPage<SocialInvite>.self, from: await client.request("ride-invites")).items
        let sent = try JSONDecoder().decode(SocialPage<SocialInvite>.self,
            from: await client.request("ride-invites", query: [URLQueryItem(name: "sent", value: "true")])).items
        let rooms = try JSONDecoder().decode(SocialPage<SocialGroupRide>.self, from: await client.request("group-rides")).items
        let blocked = try JSONDecoder().decode(SocialPage<SocialProfile>.self, from: await client.request("blocks")).items
        let routes = try await content(kind: "routes")
        let activities = try await content(kind: "activities")
        guard expected == session.generation else { return }
        self.profile = me; self.friends = friends; self.requests = requests
        invitations = invites; sentInvitations = sent; rides = rooms; self.blocked = blocked; self.routes = routes; self.activities = activities
        await loadPhotos(friends + [me])
        try await bindNotifications()
    }

    private func pages<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var output: [T] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            var next = query
            if let cursor { next.append(URLQueryItem(name: "after", value: cursor)) }
            let page = try JSONDecoder().decode(SocialPage<T>.self, from: await client.request(path, query: next))
            output += page.items; cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted { throw SocialFailure.invalidResponse }
            guard output.count <= 5000 else { throw SocialFailure.invalidResponse }
        } while cursor != nil
        return output
    }

    func content(kind: String, owner: String? = nil) async throws -> [SocialContent] {
        let query = owner.map { [URLQueryItem(name: "owner", value: $0)] } ?? []
        return try await pages(kind, query: query)
    }

    func loadPhotos(_ profiles: [SocialProfile]) async {
        let expected = session.generation
        if photos.count > 128 { photos = [:] }
        for profile in profiles {
            guard let asset = profile.avatarID, photos[asset] == nil else { continue }
            if let data = try? await client.request("media/\(asset)/marker"),
               data.count <= 512000, let image = UIImage(data: data), expected == session.generation {
                photos[asset] = image
            }
        }
    }

    func saveProfile(username: String, name: String, privacy: SocialPrivacy) async throws {
        guard let profile else { return }
        let privacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(privacy))
        _ = try await client.json("me", method: "PATCH", body: ["version": profile.version ?? 1,
            "username": username.lowercased(), "displayName": name, "privacy": privacyJSON])
        try await refresh()
    }

    func setPhoto(_ data: Data) async throws {
        guard let profile, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw SocialFailure.invalidResponse
        }
        // Server repeats crop/validation and removes all metadata.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let thumbnail = renderer.image { _ in
            let scale = max(256 / image.size.width, 256 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (256-size.width)/2, y: (256-size.height)/2, width: size.width, height: size.height))
        }
        guard let png = thumbnail.pngData() else { throw SocialFailure.invalidResponse }
        _ = try await client.request("me/avatar", method: "PUT", body: png, contentType: "image/png",
            query: [URLQueryItem(name: "version", value: String(profile.version ?? 1))])
        photos = [:]
        try await refresh()
    }

    func removePhoto() async throws {
        _ = try await client.json("me/avatar", method: "DELETE")
        photos = [:]
        try await refresh()
    }

    func lookup(_ username: String) async throws -> SocialProfile {
        guard username.range(of: "^[a-z][a-z0-9_]{2,29}$", options: .regularExpression) != nil else {
            throw SocialFailure.server("enter_an_exact_username")
        }
        return try JSONDecoder().decode(SocialProfile.self, from: await client.request("profiles/by-username/\(username)"))
    }

    func mutate(_ path: String, method: String = "POST", body: [String: Any]? = nil) async throws {
        _ = try await client.json(path, method: method, body: body)
        try await refresh()
    }

    func removeFriend(_ id: String, block: Bool) async throws {
        _ = try await client.json("\(block ? "blocks" : "friends")/\(id)", method: block ? "PUT" : "DELETE")
        photos = [:]
        if block { await live.stopSharing(); live.reset() }
        try await refresh()
    }

    func publish(_ archive: NavigationRouteArchiveV1, title: String, visibility: String) async throws {
        guard archive.route.provider == RouteProviderPolicyV1.importedGPX else {
            throw SocialFailure.server("this_route_provider_does_not_allow_social_sharing")
        }
        let data = try archive.encoded(purpose: .offlineNavigation)
        guard let encoded = String(data: data, encoding: .utf8) else { throw SocialFailure.invalidResponse }
        let payload = String(decoding: try archive.socialHashPayload(), as: UTF8.self)
        _ = try await client.json("routes", method: "POST", body: ["archive": encoded, "hashPayload": payload, "title": title,
            "visibility": visibility, "sharingRightsConfirmed": true])
        try await refresh()
    }

    func save(_ item: SocialContent, to library: PhoneRouteLibrary, duplicate: Bool = false) throws {
        guard let raw = item.body.archive, let expected = item.body.sha256 else { throw SocialFailure.invalidResponse }
        let data = Data(raw.utf8)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw SocialFailure.invalidResponse
        }
        _ = try library.importSocialArchive(data, socialID: item.id, owner: item.owner,
            revision: item.revision, duplicate: duplicate)
    }

    func createRide(route: SocialContent, title: String, startsAt: Date? = nil) async throws {
        var body: [String: Any] = ["routeID": route.id, "title": title]
        if let startsAt { body["startsAt"] = startsAt.timeIntervalSince1970 }
        let value = try await client.json("group-rides", method: "POST", body: body)
        let ride = try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value))
        try await live.select(ride)
    }

    func acceptInvite(_ id: String) async throws {
        let value = try await client.json("ride-invites/\(id)/accept", method: "POST")
        try await live.select(try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value)))
        try await refresh()
    }

    func join(_ code: String) async throws {
        let value = try await client.json("group-rides/join", method: "POST", body: ["code": code])
        try await live.select(try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value)))
    }

    func signOut() async throws {
        _ = try? await client.json("notification-devices/\(pushBinding)", method: "DELETE")
        UIApplication.shared.unregisterForRemoteNotifications()
        pushToken = nil
        await live.stopSharing()
        live.reset()
        try session.signOut()
        clear()
    }

    func deleteAccount() async throws {
        guard let profile else { throw SocialFailure.signedOut }
        var body: [String: Any] = ["expectedProfileID": profile.id]
        if session.usesApple {
            body["appleAuthorizationCode"] = try await session.signInWithApple(reauthenticate: true)
        } else {
            try await session.signInWithGoogle(reauthenticate: true)
        }
        await live.stopSharing()
        _ = try await client.json("me/deletion", method: "POST", body: body)
        try await signOut()
    }

    func handleLink(_ url: URL) -> Bool {
        let canonical: URL
        if url.scheme == "https", url.host == "bicino.com" { canonical = url }
        else if ["bikecomputer", "bikecomputer-dev"].contains(url.scheme ?? ""), url.host == "social",
                let value = URL(string: "https://bicino.com/social" + url.path) { canonical = value }
        else { return false }
        guard canonical.path.hasPrefix("/social/") else { return false }
        pendingLink = canonical
        return true
    }
}
