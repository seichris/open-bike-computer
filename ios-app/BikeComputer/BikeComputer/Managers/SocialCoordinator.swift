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
    let savedRouteSharing: SocialSavedRouteSharing
    @Published private(set) var profile: SocialProfile?
    @Published private(set) var capabilities = SocialCapabilities()
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
    /// Informational outcome, such as an earlier deletion confirmed after relaunch.
    @Published var notice: String?
    @Published var pendingLink: URL?
    /// Alert registration is reported separately: it never makes a refresh or a
    /// successful friend, route or ride action look failed.
    @Published private(set) var notificationStatus: SocialNotificationBinding.Status = .inactive
    let notifications: SocialNotificationBinding
    let deletion: SocialAccountDeletion
    private let profileEdits = SocialProfileMutationQueue()
    @Published private(set) var alertsAuthorized = false
    @Published private(set) var alertsDenied = false
    private var pushToken: String?
    @discardableResult
    func enableNotifications() async throws -> Bool {
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refreshNotificationAuthorization()
        if allowed {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return allowed
    }
    func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        alertsAuthorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        alertsDenied = settings.authorizationStatus == .denied
    }
    func didRegisterNotifications(_ data: Data) {
        pushToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await bindNotifications() }
    }
    private func bindNotifications() async {
        guard session.state == .signedIn, let pushToken else { return }
        await notifications.bind(token: pushToken)
    }
    /// Re-register on sign-in and launch so a migrated or rotated installation
    /// binding is restored without the rider re-enabling alerts.
    private func registerForAlertsIfAuthorized() async {
        await refreshNotificationAuthorization()
        guard session.state == .signedIn, alertsAuthorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
    private var relay: SocialBLERelay?
    func bindBLE(_ ble: BLEManager) { relay = SocialBLERelay(ble: ble, social: self) }
    private var observers = Set<AnyCancellable>()

    init() {
        let session = BicinoUserSession()
        self.session = session
        let client = BicinoSocialClient(session: session, baseURL: URL(string: OfflineMapServiceConfig.defaultServerURLString)?.appendingPathComponent("v1/social"))
        self.client = client
        live = LiveRideService(client: client)
        savedRouteSharing = SocialSavedRouteSharing(client: client, currentGeneration: { session.generation })
        // The existing explicit app-private group; no shared group is introduced.
        let store: any SocialSecureStore = session.keychainGroup.map { SocialKeychainStore(accessGroup: $0) } ?? SocialMemoryStore()
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        notifications = SocialNotificationBinding(store: store, client: client, anonymous: client, environment: environment)
        deletion = SocialAccountDeletion(store: store, client: client, anonymous: client)
        notifications.onStatusChange = { [weak self] in self?.notificationStatus = $0 }
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        session.$generation.dropFirst().sink { [weak self] _ in self?.clear() }.store(in: &observers)
        let invitationStore = SocialRideInvitationStore(store: store)
        live.loadInvitation = { [weak self] ride in
            guard let owner = self?.profile?.id else { return nil }
            return invitationStore.read(owner: owner, ride: ride)
        }
        live.saveInvitation = { [weak self] ride, value in
            guard let owner = self?.profile?.id else { return }
            invitationStore.write(value, owner: owner, ride: ride)
        }
        live.onRidersChanged = { [weak self] riders in
            Task { @MainActor [weak self] in await self?.loadPhotos((self?.live.ride?.members ?? []) + riders.map(\.profile)) }
        }
        live.onCapabilitiesChanged = { [weak self] capabilities in
            self?.capabilities = capabilities
            if !capabilities.media { self?.photos = [:] }
        }
        session.$state.removeDuplicates().dropFirst().sink { [weak self] state in
            Task { @MainActor [weak self] in await self?.sessionChanged(state) }
        }.store(in: &observers)
        Task { [weak self] in
            // Finish work left by an offline sign-out or an interrupted deletion.
            await self?.notifications.releaseIfPending()
            await self?.recoverDeletion()
        }
    }

    private func sessionChanged(_ state: BicinoUserSession.State) async {
        switch state {
        case .signedOut:
            // Explicit, forced (revoked, disabled, deleted) and switching sign-outs
            // all end the bound account on this installation.
            await notifications.accountEnded()
            await recoverDeletion()
        case .signedIn:
            await registerForAlertsIfAuthorized()
        default:
            break
        }
    }

    func clear() {
        capabilities = SocialCapabilities()
        profile = nil; friends = []; requests = []; invitations = []; sentInvitations = []
        routes = []; activities = []; photos = [:]; rides = []; blocked = []
        live.reset()
    }

    func refresh() async throws {
        let expected = session.generation
        let capabilities = try JSONDecoder().decode(SocialCapabilities.self, from: await client.request("capabilities"))
        guard expected == session.generation else { return }
        self.capabilities = capabilities
        if !capabilities.groups { await live.stopSharing(); live.reset() }
        if !capabilities.media { photos = [:] }
        let me = try JSONDecoder().decode(SocialProfile.self, from: await client.request("me"))
        let friends: [SocialProfile] = try await pages("friends")
        let requests: [SocialFriendRequest] = try await pages("friend-requests")
        let invites: [SocialInvite] = capabilities.groups ? try await pages("ride-invites") : []
        let sent: [SocialInvite] = capabilities.groups ? try await pages("ride-invites", query: [URLQueryItem(name: "sent", value: "true")]) : []
        let rooms: [SocialGroupRide] = capabilities.groups ? try await pages("group-rides") : []
        let blocked = try JSONDecoder().decode(SocialPage<SocialProfile>.self, from: await client.request("blocks")).items
        let routes = try await content(kind: "routes")
        let activities = try await content(kind: "activities")
        guard expected == session.generation else { return }
        // A background refresh must not replace a newer autosave response.
        if profile?.id != me.id || (profile?.version ?? 0) <= (me.version ?? 0) { profile = me }
        self.friends = friends; self.requests = requests
        invitations = invites; sentInvitations = sent; rides = rooms; self.blocked = blocked; self.routes = routes; self.activities = activities
        await loadPhotos(friends + [me])
        await bindNotifications()
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
        guard kind == "routes" ? capabilities.routes : capabilities.activities else { return [] }
        let query = owner.map { [URLQueryItem(name: "owner", value: $0)] } ?? []
        return try await pages(kind, query: query)
    }

    func loadPhotos(_ profiles: [SocialProfile]) async {
        guard capabilities.media else { return }
        let expected = session.generation
        if photos.count > 128 { photos = [:] }
        for profile in profiles {
            guard let asset = profile.avatarID, photos[asset] == nil else { continue }
            if let data = try? await client.request("media/\(asset)/marker"),
               data.count <= 512000, let image = UIImage(data: data), expected == session.generation, capabilities.media {
                photos[asset] = image
            }
        }
    }

    func saveProfile(username: String, name: String, privacy: SocialPrivacy) async throws {
        try await editProfile { draft, settings in
            draft.username = username
            draft.name = name
            settings = privacy
        }
    }

    func saveProfileName(_ name: String) async throws {
        try await editProfile { draft, _ in draft.name = name }
    }

    func saveProfileUsername(_ username: String) async throws {
        try await editProfile { draft, _ in draft.username = SocialUsername.normalized(username) }
    }

    func savePrivacy(_ flag: SocialPrivacyFlag, value: Bool) async throws {
        try await editProfile { _, settings in settings[keyPath: flag.keyPath] = value }
    }

    func savePrivateAreas(_ zones: [SocialZone]) async throws {
        try await editProfile { _, settings in settings.zones = zones }
    }

    private func editProfile(
        _ change: @escaping @MainActor @Sendable (inout SocialProfileDraft, inout SocialPrivacy) -> Void
    ) async throws {
        let expected = session.generation
        try await profileEdits.perform(generation: expected, currentGeneration: { self.session.generation }) {
            guard let profile = self.profile else { throw SocialFailure.signedOut }
            var draft = SocialProfileDraft(profile: profile)
            var privacy = profile.privacy ?? SocialPrivacy()
            change(&draft, &privacy)
            guard draft.isValid else { throw SocialFailure.server("enter_a_valid_name_and_username") }
            let privacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(privacy))
            let data = try await self.client.request("me", method: "PATCH", body: JSONSerialization.data(withJSONObject: [
                "version": profile.version ?? 1, "username": draft.normalizedUsername,
                "displayName": draft.normalizedName, "privacy": privacyJSON
            ]))
            _ = try self.acceptProfileResponse(data, generation: expected)
        }
    }

    func setPhoto(_ data: Data) async throws {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
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
        let expected = session.generation
        try await profileEdits.perform(generation: expected, currentGeneration: { self.session.generation }) {
            guard let profile = self.profile else { throw SocialFailure.signedOut }
            let data = try await self.client.request("me/avatar", method: "PUT", body: png, contentType: "image/png",
                query: [URLQueryItem(name: "version", value: String(profile.version ?? 1))])
            let updated = try self.acceptProfileResponse(data, generation: expected)
            self.photos = [:]
            await self.loadPhotos([updated])
        }
    }

    func removePhoto() async throws {
        let expected = session.generation
        try await profileEdits.perform(generation: expected, currentGeneration: { self.session.generation }) {
            let data = try await self.client.request("me/avatar", method: "DELETE")
            let updated = try self.acceptProfileResponse(data, generation: expected)
            self.photos = [:]
            await self.loadPhotos([updated])
        }
    }

    private func acceptProfileResponse(_ data: Data, generation: UUID) throws -> SocialProfile {
        guard generation == session.generation else { throw SocialFailure.accountChanged }
        let profile = try JSONDecoder().decode(SocialProfile.self, from: data)
        guard self.profile?.id == profile.id else { throw SocialFailure.accountChanged }
        self.profile = profile
        return profile
    }

    func lookup(_ username: String) async throws -> SocialProfile {
        let username = SocialUsername.normalized(username)
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

    /// Publishing is limited to routes this rider owns. A sharing-rights confirmation
    /// cannot override another rider's ownership; the server enforces the same rule.
    func publication(for summary: PlannedRouteSummaryV1, in library: PhoneRouteLibrary) -> SocialRoutePublication {
        library.socialPublication(for: summary, currentProfileID: profile?.id)
    }

    func sharingUnavailableReason(for summary: PlannedRouteSummaryV1, in library: PhoneRouteLibrary) -> String? {
        guard session.state == .signedIn else { return "Sign in from your profile to start a group ride or share this route." }
        guard capabilities.routes, capabilities.groups else { return "Group rides and route sharing are unavailable right now." }
        guard summary.providerID == RouteProviderPolicyV1.importedGPX.providerID else {
            return "This provider’s routes can be navigated privately. Group rides and sharing are available for your own GPX routes."
        }
        guard publication(for: summary, in: library).mayPublish else { return "Only this route’s owner can share it or start a group ride with it." }
        return nil
    }

    func shareSavedRoute(_ summary: PlannedRouteSummaryV1, from library: PhoneRouteLibrary,
                        visibility: String) async throws -> SocialContent {
        if let reason = sharingUnavailableReason(for: summary, in: library) { throw SocialFailure.server(reason) }
        guard let owner = profile?.id else { throw SocialFailure.signedOut }
        let archive = try library.offlineArchive(for: summary)
        guard archive.route.provider == RouteProviderPolicyV1.importedGPX else {
            throw SocialFailure.server("this_route_provider_does_not_allow_social_sharing")
        }
        let encoded = try archive.encoded(purpose: .offlineNavigation)
        return try await savedRouteSharing.save(owner: owner, hash: archive.contentHash,
            archive: String(decoding: encoded, as: UTF8.self),
            hashPayload: String(decoding: try archive.socialHashPayload(), as: UTF8.self),
            title: library.displayName(for: summary), visibility: visibility, generation: session.generation)
    }

    func save(_ item: SocialContent, to library: PhoneRouteLibrary, duplicate: Bool = false) throws {
        _ = try library.importSocialArchive(verified(item.body), source: SocialRouteSource(
            kind: .content, socialID: item.id, owner: item.owner, revision: item.revision), duplicate: duplicate)
    }

    /// Saves (or opens) a Group Ride's route snapshot as the organizer's route.
    @discardableResult
    func saveRideRoute(_ ride: SocialGroupRide, to library: PhoneRouteLibrary) throws -> PlannedRouteSummaryV1 {
        try library.importSocialArchive(verified(ride.route), source: SocialRouteSource(
            kind: .ride, socialID: ride.id, owner: ride.owner, revision: nil), duplicate: false)
    }

    private func verified(_ body: SocialContentBody) throws -> Data {
        guard let raw = body.archive, let expected = body.sha256 else { throw SocialFailure.invalidResponse }
        let data = Data(raw.utf8)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw SocialFailure.invalidResponse
        }
        return data
    }

    func createRide(route: SocialContent, title: String, startsAt: Date? = nil) async throws {
        let generation = session.generation
        var body: [String: Any] = ["routeID": route.id, "title": title]
        if let startsAt { body["startsAt"] = startsAt.timeIntervalSince1970 }
        let value = try await client.json("group-rides", method: "POST", body: body)
        guard session.generation == generation else { throw SocialFailure.accountChanged }
        let ride = try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value))
        try await live.select(ride, shareOnJoin: true)
        await prepareInvitePreview(for: ride)
    }

    /// Older backends keep the original fragment link. A preview failure never
    /// turns an already-created group ride into a failed creation.
    private func prepareInvitePreview(for ride: SocialGroupRide) async {
        guard capabilities.invitePreviews else { return }
        let generation = session.generation
        do {
            let data = try await SocialInvitePreview.render(ride: ride)
            guard generation == session.generation, live.ride?.id == ride.id else { return }
            let response = try await client.request("group-rides/\(ride.id)/invite-preview", method: "PUT", body: data, contentType: "image/png")
            guard generation == session.generation, live.ride?.id == ride.id else { return }
            let value = try JSONSerialization.jsonObject(with: response) as? [String: String]
            guard let id = value?["previewID"] else { throw SocialFailure.invalidResponse }
            live.setPreview(id, for: ride.id)
        } catch {
            guard generation == session.generation, live.ride?.id == ride.id else { return }
            notice = "Your group ride is ready. The invite uses a standard link because the route preview could not be created."
        }
    }

    func acceptInvite(_ id: String) async throws {
        let value = try await client.json("ride-invites/\(id)/accept", method: "POST")
        try await live.select(try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value)), shareOnJoin: true)
        try await refresh()
    }

    func join(_ code: String) async throws {
        let value = try await client.json("group-rides/join", method: "POST", body: ["code": code])
        try await live.select(try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: value)), shareOnJoin: true)
    }

    func signOut() async throws {
        await live.stopSharing()
        live.reset()
        UIApplication.shared.unregisterForRemoteNotifications()
        pushToken = nil
        // Proof-based release needs no account token, so it completes later if offline.
        await notifications.accountEnded()
        try session.signOut()
        clear()
    }

    func deleteAccount() async throws {
        guard let profile else { throw SocialFailure.signedOut }
        let session = session, live = live
        let completed = try await deletion.delete(profileID: profile.id, accountUID: session.currentUID,
            reauthenticate: {
                if session.usesApple { return try await session.signInWithApple(reauthenticate: true) }
                try await session.signInWithGoogle(reauthenticate: true)
                return nil
            },
            beforeSending: { await live.stopSharing() })
        await finishDeletion(completed)
    }

    /// Confirms an earlier accepted deletion after relaunch or automatic sign-out,
    /// using only its receipt. Never signs in to do so.
    private func recoverDeletion() async {
        guard let completed = await deletion.recoverPending() else { return }
        await finishDeletion(completed)
        notice = "Your Bicino account deletion was completed."
    }

    private func finishDeletion(_ completed: SocialPendingDeletion) async {
        // The server removed the deleted account's push bindings when deletion began.
        await notifications.forget(owner: completed.profileID)
        // Never sign out an account the rider switched to after the deletion.
        guard SocialAccountDeletion.shouldSignOut(completed, currentUID: session.currentUID) else { return }
        live.reset()
        UIApplication.shared.unregisterForRemoteNotifications()
        pushToken = nil
        try? session.signOut()
        clear()
    }

    func handleLink(_ url: URL) -> Bool {
        guard let target = SocialLinkTarget(url: url) else { return false }
        pendingLink = target.canonicalURL
        return true
    }
}
