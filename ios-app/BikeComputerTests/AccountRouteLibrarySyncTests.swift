import CryptoKit
import Foundation

private let gpx = AccountRouteSyncPlannerV1.gpxProviderID
private let strava = AccountRouteSyncPlannerV1.stravaProviderID

private func local(_ id: String, _ title: String?, hash: String?, revision: Int = 1, provider: String = gpx) -> AccountLocalRouteV1 {
    AccountLocalRouteV1(routeID: id, title: title, contentHash: hash, revision: revision, providerID: provider)
}

private func remote(_ id: String, _ title: String, hash: String?, revision: Int = 1, provider: String = gpx,
                    content: String? = nil) -> AccountLibraryRouteV1 {
    AccountLibraryRouteV1(id: content ?? "content-\(id)", routeID: id, title: title, revision: 1,
                          contentHash: hash, routeRevision: revision, providerID: provider)
}

/// An in-memory account library speaking the `/library/routes` contract.
@MainActor
private final class LibraryServer: SocialRideNetworking {
    struct Row { var title: String; var archive: String; var hash: String; var routeRevision: Int; var provider: String; var revision: Int }
    var rows: [String: Row] = [:]
    var generation = UUID()
    var owner: String? = "me"
    var changeAccountOnNextPut = false
    var refuseUploads: String?
    var onPut: (() -> Void)?
    var calls: [String] = []

    func item(_ routeID: String) -> [String: Any] {
        let row = rows[routeID]!
        return ["id": "content-\(routeID)", "routeID": routeID, "title": row.title, "revision": row.revision,
                "contentHash": row.hash, "routeRevision": row.routeRevision, "providerID": row.provider]
    }

    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        calls.append("\(method) \(path)")
        let payload = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        if path == "library/routes", method == "GET" {
            return try JSONSerialization.data(withJSONObject: ["items": rows.keys.sorted().map(item)])
        }
        if path.hasPrefix("routes/content-") {
            let routeID = String(path.dropFirst("routes/content-".count))
            guard let row = rows[routeID] else { throw SocialFailure.server("not_found") }
            let sha = SHA256.hash(data: Data(row.archive.utf8)).map { String(format: "%02x", $0) }.joined()
            return try JSONSerialization.data(withJSONObject: ["id": "content-\(routeID)", "owner": "me", "kind": "route",
                "title": row.title, "visibility": "private", "revision": row.revision,
                "body": ["archive": row.archive, "sha256": sha]])
        }
        let routeID = String(path.dropFirst("library/routes/".count))
        switch method {
        case "PUT":
            if changeAccountOnNextPut { generation = UUID(); throw SocialFailure.accountChanged }
            onPut?()
            if let refuseUploads { throw SocialFailure.server(refuseUploads) }
            let archive = payload!["archive"] as! String
            let decoded = try JSONSerialization.jsonObject(with: Data(archive.utf8)) as! [String: Any]
            let route = decoded["route"] as! [String: Any]
            let revision = (rows[routeID]?.revision ?? 0) + 1
            rows[routeID] = Row(title: payload!["title"] as! String, archive: archive, hash: decoded["contentHash"] as! String,
                                routeRevision: route["revision"] as! Int, provider: route["provider"] as! String, revision: revision)
        case "PATCH":
            guard rows[routeID] != nil else { throw SocialFailure.server("not_found") }
            rows[routeID]!.title = payload!["title"] as! String
            rows[routeID]!.revision += 1
        case "DELETE":
            guard rows.removeValue(forKey: routeID) != nil else { throw SocialFailure.server("not_found") }
            return try JSONSerialization.data(withJSONObject: ["deleted": true])
        default:
            throw SocialFailure.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: item(routeID))
    }

    func socket(rideID: String) async throws -> any SocialSocket { throw SocialFailure.unavailable }
}

/// The phone's saved routes, reduced to what the sync touches.
@MainActor
private final class PhoneLibrary: AccountRouteLibraryStoreV1 {
    struct Route { var title: String; var hash: String?; var revision: Int; var provider: String; var points = 100 }
    var routes: [String: Route] = [:]
    var unreadable: Set<String> = []
    var onDelete: ((String) -> Void)?

    static func archive(_ routeID: String, hash: String, revision: Int, provider: String) -> String {
        "{\"contentHash\":\"\(hash)\",\"route\":{\"id\":\"\(routeID)\",\"revision\":\(revision),\"provider\":\"\(provider)\"}}"
    }

    func accountSyncRoutes() -> [AccountLocalRouteV1] {
        routes.map { AccountLocalRouteV1(routeID: $0.key, title: $0.value.title, contentHash: $0.value.hash,
                                         revision: $0.value.revision, providerID: $0.value.provider) }
    }

    func accountSyncUpload(routeID: String) throws -> AccountRouteUploadV1 {
        guard let route = routes[routeID], let hash = route.hash, !unreadable.contains(routeID) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return AccountRouteUploadV1(archive: Self.archive(routeID, hash: hash, revision: route.revision, provider: route.provider),
                                    hashPayload: "payload", title: route.title, contentHash: hash,
                                    pointCount: route.points, elevationGainMeters: 812)
    }

    func accountSyncImport(_ archive: Data, title: String) throws {
        let value = try JSONSerialization.jsonObject(with: archive) as! [String: Any]
        let route = value["route"] as! [String: Any]
        routes[route["id"] as! String] = Route(title: title, hash: value["contentHash"] as? String,
                                               revision: route["revision"] as! Int, provider: route["provider"] as! String)
    }

    func accountSyncRename(routeID: String, title: String) { routes[routeID]?.title = title }

    func accountSyncDelete(routeID: String) throws {
        routes[routeID] = nil
        onDelete?(routeID)
    }

    /// The rider deletes on the phone: the library calls its deletion hook.
    func riderDeletes(_ routeID: String) {
        routes[routeID] = nil
        onDelete?(routeID)
    }
}

@MainActor
enum AccountRouteLibrarySyncTests {
    static func run() async throws {
        planner()
        try await roundTrip()
        print("Account route library sync tests passed")
    }

    static func planner() {
        let empty = AccountRouteSyncStateV1()
        let fresh = AccountRouteSyncPlannerV1.plan(
            local: [local("A", "Alpe", hash: "a1"), local("S", "Strava loop", hash: "s1", provider: strava),
                    local("M", "Apple", hash: "m1", provider: "apple.mapkit")],
            remote: [remote("W", "Website route", hash: "w1"), remote("X", "Other phone's Strava", hash: "x1", provider: strava)],
            state: empty)
        precondition(fresh == [.upload(routeID: "A"), .upload(routeID: "S"),
                               .download(routeID: "W", contentID: "content-W", title: "Website route")],
                     "GPX and Strava go up; only GPX comes down; Apple Maps stays on the phone")

        var synced = AccountRouteSyncStateV1()
        synced.synced["A"] = .init(contentHash: "a1", title: "Alpe")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Alpe", hash: "a1")], remote: [], state: synced)
                     == [.deleteLocal(routeID: "A")], "a route deleted on bicino.com is deleted on the phone")
        precondition(AccountRouteSyncPlannerV1.plan(local: [], remote: [remote("A", "Alpe", hash: "a1")], state: synced)
                     == [.download(routeID: "A", contentID: "content-A", title: "Alpe")],
                     "a synced GPX route that vanished without a rider deletion is restored")

        var pending = synced
        pending.pendingDeletes = ["A", "B"]
        precondition(AccountRouteSyncPlannerV1.plan(local: [], remote: [remote("A", "Alpe", hash: "a1")], state: pending)
                     == [.deleteRemote(routeID: "A"), .forget(routeID: "B")], "phone deletions reach the account")

        precondition(AccountRouteSyncPlannerV1.plan(local: [local("S", "Loop", hash: "s2", revision: 2, provider: strava)],
                     remote: [remote("S", "Loop", hash: "s1", revision: 1, provider: strava)], state: empty)
                     == [.upload(routeID: "S")], "a reloaded Strava route replaces the older revision")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("S", "Loop", hash: "s1", provider: strava)],
                     remote: [remote("S", "Loop", hash: "s2", revision: 2, provider: strava)], state: empty)
                     == [.adopt(routeID: "S", contentHash: "s2", title: "Loop")], "an older phone copy never overwrites")

        var expired = AccountRouteSyncStateV1()
        expired.synced["S"] = .init(contentHash: "s1", title: "Loop")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("S", nil, hash: nil, provider: strava)],
                     remote: [remote("S", "Loop", hash: "s1", provider: strava)], state: expired).isEmpty,
                     "an expired Strava lease is neither uploaded nor deleted from the account")

        var renamed = AccountRouteSyncStateV1()
        renamed.synced["A"] = .init(contentHash: "a1", title: "Alpe")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Alpe d'Huez", hash: "a1")],
                     remote: [remote("A", "Alpe", hash: "a1")], state: renamed)
                     == [.renameRemote(routeID: "A", title: "Alpe d'Huez")], "a phone rename goes up")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Alpe", hash: "a1")],
                     remote: [remote("A", "Huez", hash: "a1")], state: renamed)
                     == [.renameLocal(routeID: "A", title: "Huez")], "a website rename comes down")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Phone", hash: "a1")],
                     remote: [remote("A", "Web", hash: "a1")], state: empty)
                     == [.renameLocal(routeID: "A", title: "Web")], "without a baseline the account's title wins")

        var refused = AccountRouteSyncStateV1()
        refused.refused["A"] = "a1"
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Huge", hash: "a1")], remote: [], state: refused).isEmpty,
                     "content the server refused is not retried")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("A", "Huge", hash: "a2", revision: 2)], remote: [], state: refused)
                     == [.upload(routeID: "A")], "changed content is tried again")
        precondition(AccountRouteSyncPlannerV1.plan(local: [local("a", "Alpe", hash: "a1")], remote: [remote("A", "Alpe", hash: "a1")],
                     state: synced).isEmpty, "route IDs compare without case")
    }

    static func roundTrip() async throws {
        let suite = "bicino.accountRouteLibrarySync.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = LibraryServer()
        let phone = PhoneLibrary()
        let sync = AccountRouteLibrarySync(client: server, store: phone, defaults: defaults,
                                           currentGeneration: { server.generation }, currentOwner: { server.owner })
        phone.onDelete = { sync.recordLocalDeletion(routeID: UUID(uuidString: $0)!) }
        let a = UUID().uuidString, s = UUID().uuidString, w = UUID().uuidString
        phone.routes[a] = .init(title: "Alpe", hash: "a1", revision: 1, provider: gpx)
        phone.routes[s] = .init(title: "Strava loop", hash: "s1", revision: 1, provider: strava)
        server.rows[w] = .init(title: "From bicino.com",
                               archive: PhoneLibrary.archive(w, hash: "w1", revision: 1, provider: gpx),
                               hash: "w1", routeRevision: 1, provider: gpx, revision: 1)

        await sync.sync(owner: "me")
        precondition(sync.lastError == nil, "first round succeeds: \(String(describing: sync.lastError))")
        precondition(Set(server.rows.keys) == [a, s, w] && server.rows[s]?.provider == strava, "phone routes reached the account")
        precondition(phone.routes[w]?.title == "From bicino.com", "the website's route reached the phone")
        let settled = server.calls.count
        await sync.sync(owner: "me")
        precondition(server.calls.count == settled + 1, "a settled library costs one listing")

        server.rows[w]!.title = "Renamed on the web"
        phone.routes[a]!.title = "Alpe d'Huez"
        await sync.sync(owner: "me")
        precondition(phone.routes[w]?.title == "Renamed on the web" && server.rows[a]?.title == "Alpe d'Huez",
                     "renames cross in both directions")

        phone.riderDeletes(a)
        server.rows[s] = nil
        await sync.sync(owner: "me")
        precondition(server.rows[a] == nil, "a phone deletion reaches the account")
        precondition(phone.routes[s] == nil, "a website deletion reaches the phone")
        precondition(sync.state(owner: "me").synced[a] == nil && sync.state(owner: "me").pendingDeletes.isEmpty)
        precondition(sync.deletionLog()[a] != nil, "the rider's deletion stays logged for other accounts")
        precondition(server.rows[w] != nil && phone.routes[w] != nil, "the deletion from bicino.com did not echo back")

        let b = UUID().uuidString
        phone.routes[b] = .init(title: "Too dense", hash: "b1", revision: 1, provider: gpx)
        server.refuseUploads = "route_not_redistributable"
        await sync.sync(owner: "me")
        precondition(sync.state(owner: "me").refused[b] == "b1", "a permanent refusal is remembered")
        let refusedCalls = server.calls.count
        await sync.sync(owner: "me")
        precondition(server.calls.count == refusedCalls + 1, "and not retried for the same content")
        server.refuseUploads = nil

        let broken = "00000000-0000-4000-8000-000000000000", after = "FFFFFFFF-0000-4000-8000-000000000000"
        phone.routes[broken] = .init(title: "Unreadable", hash: "x1", revision: 1, provider: gpx)
        phone.routes[after] = .init(title: "After it", hash: "y1", revision: 1, provider: gpx)
        phone.unreadable = [broken]
        await sync.sync(owner: "me")
        precondition(server.rows[after] != nil && server.rows[broken] == nil, "one unreadable route does not block the rest")
        precondition(sync.lastError != nil, "and the failure is reported")
        phone.unreadable = []
        await sync.sync(owner: "me")
        precondition(server.rows[broken] != nil && sync.lastError == nil, "it uploads once readable")

        // A deletion recorded while a round is in flight is never overwritten.
        let d = UUID().uuidString, e = UUID().uuidString
        phone.routes[d] = .init(title: "Deleted mid-round", hash: "d1", revision: 1, provider: gpx)
        await sync.sync(owner: "me")
        precondition(server.rows[d] != nil)
        phone.routes[e] = .init(title: "Triggers a PUT", hash: "e1", revision: 1, provider: gpx)
        server.onPut = { phone.riderDeletes(d) }
        await sync.sync(owner: "me")
        server.onPut = nil
        await sync.sync(owner: "me")
        precondition(server.rows[d] == nil && phone.routes[d] == nil, "the mid-round deletion reached the account")

        // Over the library's limits: never sent, remembered.
        let huge = UUID().uuidString
        phone.routes[huge] = .init(title: "Dense track", hash: "h1", revision: 1, provider: gpx, points: 30_000)
        let beforeHuge = server.calls.count
        await sync.sync(owner: "me")
        precondition(server.calls.count == beforeHuge + 1 && server.rows[huge] == nil && sync.state(owner: "me").refused[huge] == "h1",
                     "an oversized route is not uploaded")
        precondition(AccountRouteSyncPlannerV1.accountTitle(String(repeating: "é", count: 200)).unicodeScalars.count == 160)

        // A round never acts for an account that is not the signed-in one.
        server.owner = "other"
        let quiet = server.calls.count
        await sync.sync(owner: "me")
        precondition(server.calls.count == quiet, "a stale account's round does nothing")
        server.owner = "me"
        server.onPut = { server.owner = "other"; server.generation = UUID() }
        let f = UUID().uuidString, g = UUID().uuidString
        phone.routes[f] = .init(title: "First", hash: "f1", revision: 1, provider: gpx)
        phone.routes[g] = .init(title: "Second", hash: "g1", revision: 1, provider: gpx)
        let phoneBefore = Set(phone.routes.keys)
        await sync.sync(owner: "me")
        precondition(server.calls.filter { $0.hasPrefix("PUT") }.count >= 1 && Set(phone.routes.keys) == phoneBefore,
                     "an account switch mid-round stops it without touching the phone")
        precondition(server.rows[f] == nil || server.rows[g] == nil, "no action runs after the switch")
        server.onPut = nil
        server.owner = "me"

        let c = UUID().uuidString
        phone.routes[c] = .init(title: "Mid-switch", hash: "c1", revision: 1, provider: gpx)
        phone.routes[b]!.hash = "b2"; phone.routes[b]!.revision = 2
        server.changeAccountOnNextPut = true
        await sync.sync(owner: "me")
        precondition(server.rows[c] == nil && server.rows[b] == nil, "an account switch ends the round")
        server.changeAccountOnNextPut = false
        precondition(sync.state(owner: "other").synced.isEmpty, "each account keeps its own sync state")
    }
}
