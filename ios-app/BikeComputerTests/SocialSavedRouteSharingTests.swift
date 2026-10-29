import Foundation

@MainActor
private final class SavedRouteSharingFixture: SocialRideNetworking {
    var generation = UUID()
    var records: [String: [String: Any]] = [:]
    var posts = 0
    var patches = 0
    var failPatch = false
    var changeAccountAfterRead = false

    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        let payload = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        var result: [String: Any]
        if method == "POST", path == "routes" {
            posts += 1
            let id = "route-\(posts)"
            result = ["id": id, "owner": "owner", "kind": "route", "revision": 1,
                "title": payload!["title"]!, "visibility": payload!["visibility"]!,
                "body": ["archive": payload!["archive"]!]]
            records[id] = result
        } else {
            let id = String(path.dropFirst("routes/".count))
            guard var value = records[id] else { throw SocialFailure.server("not_found") }
            if method == "PATCH" {
                if failPatch { throw SocialFailure.server("service_unavailable") }
                precondition(value["revision"] as? Int == payload?["revision"] as? Int, "uses the latest server revision")
                patches += 1
                value["revision"] = (value["revision"] as! Int) + 1
                value["title"] = payload!["title"]!
                value["visibility"] = payload!["visibility"]!
                records[id] = value
            } else if changeAccountAfterRead { generation = UUID() }
            result = value
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    func socket(rideID: String) async throws -> any SocialSocket { throw SocialFailure.unavailable }
}

@MainActor
enum SocialSavedRouteSharingTests {
    static func run() async throws {
        let name = "bicino.savedRouteSharing.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let fixture = SavedRouteSharingFixture()
        func service() -> SocialSavedRouteSharing {
            SocialSavedRouteSharing(client: fixture, defaults: defaults, currentGeneration: { fixture.generation })
        }
        let sharing = service()
        let generation = fixture.generation
        let missing = try await sharing.load(owner: "owner", hash: "hash", generation: generation)
        precondition(missing == nil)
        precondition(fixture.posts == 0, "opening a private saved route must not upload it")
        let first = try await sharing.save(owner: "owner", hash: "hash", archive: "{\"contentHash\":\"hash\"}",
            hashPayload: "payload", title: "My route", visibility: "private", generation: generation)
        precondition(first.visibility == "private" && fixture.posts == 1, "group snapshot defaults to private")
        let same = try await service().save(owner: "owner", hash: "hash", archive: "unused", hashPayload: "unused",
            title: "My route", visibility: "private", generation: generation)
        precondition(same.id == first.id && fixture.posts == 1 && fixture.patches == 0,
            "relaunching and starting another group reuses the exact saved snapshot")
        let linked = try await sharing.save(owner: "owner", hash: "hash", archive: "unused", hashPayload: "unused",
            title: "Renamed", visibility: "link", generation: generation)
        precondition(linked.id == first.id && linked.revision == 2 && linked.visibility == "link")
        fixture.failPatch = true
        do {
            _ = try await sharing.save(owner: "owner", hash: "hash", archive: "unused", hashPayload: "unused",
                title: "Renamed", visibility: "friends", generation: generation)
            preconditionFailure("failed preference save must surface")
        } catch SocialFailure.server("service_unavailable") { }
        fixture.failPatch = false
        let privateAgain = try await sharing.save(owner: "owner", hash: "hash", archive: "unused", hashPayload: "unused",
            title: "Renamed", visibility: "private", generation: generation)
        precondition(privateAgain.revision == 3 && privateAgain.visibility == "private", "can revoke link sharing")
        let other = try await sharing.load(owner: "other", hash: "hash", generation: generation)
        precondition(other == nil,
            "another account never inherits a snapshot binding")
        let changed = try await sharing.load(owner: "owner", hash: "new-version", generation: generation)
        precondition(changed == nil,
            "a changed route must get a new snapshot")
        fixture.changeAccountAfterRead = true
        do {
            _ = try await sharing.save(owner: "owner", hash: "hash", archive: "unused", hashPayload: "unused",
                title: "Renamed", visibility: "friends", generation: generation)
            preconditionFailure("account switch must cancel a queued write")
        } catch SocialFailure.accountChanged { }
        precondition(fixture.patches == 2, "no mutation after an account change")
        fixture.changeAccountAfterRead = false
        fixture.records = [:]
        let deleted = try await sharing.load(owner: "owner", hash: "hash", generation: fixture.generation)
        precondition(deleted == nil,
            "deleted remote snapshots are forgotten and can be prepared again")
        print("Saved-route sharing tests passed")
    }
}
