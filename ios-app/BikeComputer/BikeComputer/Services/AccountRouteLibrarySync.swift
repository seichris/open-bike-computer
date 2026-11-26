import Combine
import CryptoKit
import Foundation

/// One row of the signed-in account's private route library (`GET /library/routes`).
/// bicino.com shows the same rows at /account/routes.
struct AccountLibraryRouteV1: Decodable, Equatable, Sendable {
    let id: String
    let routeID: String
    let title: String
    let revision: Int
    let contentHash: String?
    let routeRevision: Int?
    let providerID: String?
}

/// A saved route on this phone as the account sync sees it.
struct AccountLocalRouteV1: Equatable, Sendable {
    /// Uppercase route UUID, the sync key on both sides.
    let routeID: String
    /// The name the rider sees, or nil when the phone has no name for it (an
    /// expired Strava lease without a rename); the account's title then stands.
    let title: String?
    /// Nil while the archive is not on this phone, such as a Strava route whose
    /// seven-day lease ended and that waits for a reload from Strava.
    let contentHash: String?
    let revision: Int
    let providerID: String
}

/// What both sides last agreed on, kept per account.
struct AccountRouteSyncStateV1: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var contentHash: String?
        var title: String
    }

    /// Route ID to the content and title last seen on both sides.
    var synced: [String: Entry] = [:]
    /// Rider deletions for this round, filled from the shared deletion log.
    var pendingDeletes: Set<String> = []
    /// Route ID to the content hash the server refused permanently (for
    /// example over its point limit); retried only when the content changes.
    var refused: [String: String] = [:]
}

enum AccountRouteSyncActionV1: Equatable, Sendable {
    case upload(routeID: String)
    case renameRemote(routeID: String, title: String)
    case deleteRemote(routeID: String)
    case download(routeID: String, contentID: String, title: String)
    case renameLocal(routeID: String, title: String)
    case deleteLocal(routeID: String)
    case adopt(routeID: String, contentHash: String?, title: String)
    case forget(routeID: String)
}

/// Decides one sync round. Pure, so every rule is testable without a phone or server.
///
/// - The phone uploads its GPX and Strava routes, newer revisions (a reloaded
///   Strava route) and renames.
/// - GPX routes that exist only in the account (imported on bicino.com or on
///   another phone) are downloaded. Strava routes are never downloaded: the
///   phone gets those from Strava itself.
/// - A route deleted on one side is deleted on the other. A Strava route whose
///   phone lease expired still counts as present, so expiry never deletes it
///   from the account.
/// - A rename wins on the side that changed since the last agreement; with no
///   shared baseline the account's title wins.
enum AccountRouteSyncPlannerV1 {
    static let gpxProviderID = "user.imported-gpx"
    static let stravaProviderID = "strava.route"
    static let syncedProviderIDs: Set<String> = [gpxProviderID, stravaProviderID]
    /// The account library's limits (`LibraryRouteUpload`, `validate_archive`).
    static let maximumTitleScalars = 160
    static let maximumPoints = 20_000
    static let maximumArchiveCharacters = 1_900_000

    /// The title as the account stores it: at most 160 Unicode scalars, cut at
    /// a character boundary so both sides compare the same text.
    static func accountTitle(_ title: String) -> String {
        guard title.unicodeScalars.count > maximumTitleScalars else { return title }
        var result = ""
        for character in title {
            guard result.unicodeScalars.count + character.unicodeScalars.count <= maximumTitleScalars else { break }
            result.append(character)
        }
        return result
    }

    /// Whether the account library can hold this upload at all.
    static func fitsAccountLibrary(_ upload: AccountRouteUploadV1) -> Bool {
        upload.pointCount <= maximumPoints && upload.archive.count <= maximumArchiveCharacters &&
            upload.hashPayload.count <= maximumArchiveCharacters && !upload.title.isEmpty
    }

    static func plan(
        local: [AccountLocalRouteV1],
        remote: [AccountLibraryRouteV1],
        state: AccountRouteSyncStateV1
    ) -> [AccountRouteSyncActionV1] {
        var localByID: [String: AccountLocalRouteV1] = [:]
        for route in local where syncedProviderIDs.contains(route.providerID) {
            localByID[route.routeID.uppercased()] = localByID[route.routeID.uppercased()] ?? route
        }
        var remoteByID: [String: AccountLibraryRouteV1] = [:]
        for route in remote {
            remoteByID[route.routeID.uppercased()] = remoteByID[route.routeID.uppercased()] ?? route
        }
        var actions: [AccountRouteSyncActionV1] = []

        for routeID in state.pendingDeletes.sorted() where localByID[routeID] == nil {
            actions.append(remoteByID[routeID] == nil ? .forget(routeID: routeID) : .deleteRemote(routeID: routeID))
        }

        for routeID in localByID.keys.sorted() where !state.pendingDeletes.contains(routeID) {
            let route = localByID[routeID]!
            let baseline = state.synced[routeID]
            guard let server = remoteByID[routeID] else {
                if baseline != nil {
                    actions.append(.deleteLocal(routeID: routeID))
                } else if let hash = route.contentHash, state.refused[routeID] != hash {
                    actions.append(.upload(routeID: routeID))
                }
                continue
            }
            if let hash = route.contentHash, hash != server.contentHash,
               route.revision > (server.routeRevision ?? 0), state.refused[routeID] != hash {
                // The upload carries the phone's title too.
                actions.append(.upload(routeID: routeID))
                continue
            }
            if let title = route.title, title != server.title {
                if baseline?.title == server.title {
                    actions.append(.renameRemote(routeID: routeID, title: title))
                } else {
                    actions.append(.renameLocal(routeID: routeID, title: server.title))
                }
            } else if baseline != AccountRouteSyncStateV1.Entry(contentHash: server.contentHash, title: server.title) {
                actions.append(.adopt(routeID: routeID, contentHash: server.contentHash, title: server.title))
            }
        }

        for routeID in remoteByID.keys.sorted()
        where localByID[routeID] == nil && !state.pendingDeletes.contains(routeID) {
            let server = remoteByID[routeID]!
            guard server.providerID == gpxProviderID else { continue }
            actions.append(.download(routeID: routeID, contentID: server.id, title: server.title))
        }
        return actions
    }
}

/// The phone's route library as the account sync needs it.
@MainActor
protocol AccountRouteLibraryStoreV1: AnyObject {
    func accountSyncRoutes() -> [AccountLocalRouteV1]
    /// The exact stored archive, its hash payload, the display name and any
    /// ascent the phone already knows.
    func accountSyncUpload(routeID: String) throws -> AccountRouteUploadV1
    /// Saves a verified archive from the account and applies its account title.
    func accountSyncImport(_ archive: Data, title: String) throws
    func accountSyncRename(routeID: String, title: String)
    func accountSyncDelete(routeID: String) throws
}

struct AccountRouteUploadV1: Equatable, Sendable {
    let archive: String
    let hashPayload: String
    let title: String
    let contentHash: String
    let pointCount: Int
    let elevationGainMeters: Double?
}

/// Runs sync rounds for the signed-in account, one at a time.
@MainActor
final class AccountRouteLibrarySync: ObservableObject {
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private let client: any SocialRideNetworking
    private weak var store: (any AccountRouteLibraryStoreV1)?
    private let defaults: UserDefaults
    private let currentGeneration: () -> UUID
    private let currentOwner: () -> String?
    private let now: () -> Date
    private var requestedOwner: String?
    private var rerunRequested = false
    private var applyingSyncDeletion = false
    static let stateKey = "accountRouteLibrarySync.v1"
    static let deletionLogKey = "accountRouteLibrarySync.deletions.v1"
    /// Rider deletions are retried against every account for this long.
    static let deletionLogLifetime: TimeInterval = 90 * 24 * 60 * 60

    init(client: any SocialRideNetworking, store: any AccountRouteLibraryStoreV1,
         defaults: UserDefaults = .standard, currentGeneration: @escaping () -> UUID,
         currentOwner: @escaping () -> String?, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.store = store
        self.defaults = defaults
        self.currentGeneration = currentGeneration
        self.currentOwner = currentOwner
        self.now = now
    }

    // MARK: State, kept per account

    private func allStates() -> [String: AccountRouteSyncStateV1] {
        guard let data = defaults.data(forKey: Self.stateKey),
              let value = try? JSONDecoder().decode([String: AccountRouteSyncStateV1].self, from: data) else { return [:] }
        return value
    }

    func state(owner: String) -> AccountRouteSyncStateV1 { allStates()[owner] ?? AccountRouteSyncStateV1() }

    private func save(_ state: AccountRouteSyncStateV1, owner: String) {
        var states = allStates()
        states[owner] = state
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Self.stateKey) }
    }

    /// Route IDs the rider deleted on this phone, with when. Kept apart from
    /// round state so a round in flight can never overwrite a new deletion.
    func deletionLog() -> [String: Date] {
        guard let data = defaults.data(forKey: Self.deletionLogKey),
              let value = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return value
    }

    private func saveDeletionLog(_ log: [String: Date]) {
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.deletionLogKey) }
    }

    /// The rider deleted a route on this phone (or a Strava disconnect purged
    /// it). Every account that holds it deletes it on its next round, including
    /// one that is signed out now or whose upload was still in flight.
    func recordLocalDeletion(routeID: UUID) {
        guard !applyingSyncDeletion else { return }
        var log = deletionLog()
        log[routeID.uuidString.uppercased()] = now()
        saveDeletionLog(log)
    }

    // MARK: Rounds

    /// One round for `owner`. Requests during a round coalesce into one more
    /// round for the latest requested account.
    func sync(owner: String) async {
        requestedOwner = owner
        guard !isSyncing else { rerunRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            if let owner = requestedOwner { await round(owner: owner) }
        } while rerunRequested
    }

    /// The round's account is still the signed-in one.
    private func bound(_ owner: String, _ generation: UUID) -> Bool {
        generation == currentGeneration() && currentOwner() == owner
    }

    private func round(owner: String) async {
        guard let store else { return }
        let generation = currentGeneration()
        guard bound(owner, generation) else { return }
        var log = deletionLog()
        let horizon = now().addingTimeInterval(-Self.deletionLogLifetime)
        if log.contains(where: { $0.value < horizon }) {
            log = log.filter { $0.value >= horizon }
            saveDeletionLog(log)
        }
        var state = state(owner: owner)
        state.pendingDeletes = Set(log.keys)
        do {
            let page = try JSONDecoder().decode(LibraryPage.self, from: await client.request(
                "library/routes", method: "GET", body: nil, contentType: "application/json", query: []))
            guard bound(owner, generation) else { return }
            let actions = AccountRouteSyncPlannerV1.plan(local: store.accountSyncRoutes(), remote: page.items, state: state)
            var stopUploads = false
            var failure: String?
            for action in actions {
                guard bound(owner, generation) else { return }
                do {
                    try await apply(action, to: &state, store: store, stopUploads: &stopUploads)
                } catch let error as SocialFailure where error == .accountChanged || error.endsAccountSession {
                    return
                } catch SocialFailure.server(let code) where Self.permanentRefusals.contains(code) {
                    if case .upload(let routeID) = action, let hash = (try? store.accountSyncUpload(routeID: routeID))?.contentHash {
                        state.refused[routeID] = hash
                    }
                } catch SocialFailure.server(let code) where ["content_quota", "rate_limited"].contains(code) {
                    stopUploads = true
                    failure = code
                } catch {
                    // One route (an unreadable archive, a lapsed lease, a dropped
                    // request) must not hold up the others; it is retried next round.
                    failure = (error as? SocialFailure).map { "\($0)" } ?? error.localizedDescription
                }
                guard bound(owner, generation) else { return }
                save(state, owner: owner)
            }
            // Deletions live in the log, not in round state.
            state.pendingDeletes = []
            save(state, owner: owner)
            lastSyncedAt = now()
            lastError = failure
        } catch {
            lastError = (error as? SocialFailure).map { "\($0)" } ?? error.localizedDescription
        }
    }

    static let permanentRefusals: Set<String> = ["route_not_redistributable", "route_id_mismatch", "stale_route_revision"]

    private func apply(_ action: AccountRouteSyncActionV1, to state: inout AccountRouteSyncStateV1,
                       store: any AccountRouteLibraryStoreV1, stopUploads: inout Bool) async throws {
        switch action {
        case .upload(let routeID):
            guard !stopUploads else { return }
            let upload = try store.accountSyncUpload(routeID: routeID)
            guard AccountRouteSyncPlannerV1.fitsAccountLibrary(upload) else {
                // Over the library's point or size limits: never sent, kept on the phone.
                state.refused[routeID] = upload.contentHash
                return
            }
            var body: [String: Any] = ["title": upload.title, "archive": upload.archive, "hashPayload": upload.hashPayload]
            if let ascent = upload.elevationGainMeters, ascent.isFinite, ascent >= 0 { body["elevationGainMeters"] = ascent }
            let row = try await libraryRequest("library/routes/\(routeID)", method: "PUT", body: body)
            state.synced[routeID] = .init(contentHash: row.contentHash, title: row.title)
            state.refused[routeID] = nil
        case .renameRemote(let routeID, let title):
            let row = try await libraryRequest("library/routes/\(routeID)", method: "PATCH", body: ["title": title])
            state.synced[routeID] = .init(contentHash: row.contentHash, title: row.title)
        case .deleteRemote(let routeID):
            do {
                _ = try await client.request("library/routes/\(routeID)", method: "DELETE", body: nil,
                                             contentType: "application/json", query: [])
            } catch SocialFailure.server("not_found") {}
            state.synced[routeID] = nil
        case .download(let routeID, let contentID, let title):
            let item = try JSONDecoder().decode(SocialContent.self, from: await client.request(
                "routes/\(contentID)", method: "GET", body: nil, contentType: "application/json", query: []))
            guard let raw = item.body.archive, let expected = item.body.sha256,
                  SHA256.hash(data: Data(raw.utf8)).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw SocialFailure.invalidResponse
            }
            try store.accountSyncImport(Data(raw.utf8), title: title)
            let hash = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["contentHash"] as? String
            state.synced[routeID] = .init(contentHash: hash, title: title)
        case .renameLocal(let routeID, let title):
            store.accountSyncRename(routeID: routeID, title: title)
            state.synced[routeID] = .init(contentHash: state.synced[routeID]?.contentHash, title: title)
        case .deleteLocal(let routeID):
            applyingSyncDeletion = true
            defer { applyingSyncDeletion = false }
            try store.accountSyncDelete(routeID: routeID)
            state.synced[routeID] = nil
        case .adopt(let routeID, let contentHash, let title):
            state.synced[routeID] = .init(contentHash: contentHash, title: title)
        case .forget(let routeID):
            state.synced[routeID] = nil
        }
    }

    private func libraryRequest(_ path: String, method: String, body: [String: Any]) async throws -> AccountLibraryRouteV1 {
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try JSONDecoder().decode(AccountLibraryRouteV1.self, from: await client.request(
            path, method: method, body: encoded, contentType: "application/json", query: []))
    }

    private struct LibraryPage: Decodable { let items: [AccountLibraryRouteV1] }
}
