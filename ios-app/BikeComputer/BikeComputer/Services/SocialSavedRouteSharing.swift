import Foundation

/// Associates an exact local archive with its server snapshot. The local record
/// contains only an account-scoped content ID; route geometry stays in the library.
@MainActor
final class SocialSavedRouteSharing {
    let client: any SocialRideNetworking
    let defaults: UserDefaults
    let currentGeneration: @MainActor () -> UUID

    init(client: any SocialRideNetworking, defaults: UserDefaults = .standard,
         currentGeneration: @escaping @MainActor () -> UUID) {
        self.client = client
        self.defaults = defaults
        self.currentGeneration = currentGeneration
    }

    func load(owner: String, hash: String, generation: UUID) async throws -> SocialContent? {
        try check(generation)
        guard let id = defaults.string(forKey: key(owner, hash)) else { return nil }
        do {
            let value = try await client.json("routes/\(id)")
            try check(generation)
            let item = try decode(value)
            try validate(item, owner: owner, hash: hash)
            return item
        } catch SocialFailure.server("not_found") {
            try check(generation)
            defaults.removeObject(forKey: key(owner, hash))
            return nil
        }
    }

    /// No separate Publish action: sharing or starting a group prepares/reuses
    /// the selected archive, retaining the existing server ownership checks.
    func save(owner: String, hash: String, archive: String, hashPayload: String,
              title: String, visibility: String, generation: UUID) async throws -> SocialContent {
        try check(generation)
        let existing = try await load(owner: owner, hash: hash, generation: generation)
        try check(generation)
        if let existing, existing.visibility == visibility, existing.title == title { return existing }
        let value: [String: Any]
        if let existing {
            value = try await client.json("routes/\(existing.id)", method: "PATCH", body: [
                "revision": existing.revision, "title": title, "visibility": visibility])
        } else {
            value = try await client.json("routes", method: "POST", body: [
                "archive": archive, "hashPayload": hashPayload, "title": title,
                "visibility": visibility, "sharingRightsConfirmed": true])
        }
        try check(generation)
        let item = try decode(value)
        try validate(item, owner: owner, hash: hash)
        defaults.set(item.id, forKey: key(owner, hash))
        return item
    }

    private func key(_ owner: String, _ hash: String) -> String {
        "bicino.social.savedRoute.\(owner).\(hash)"
    }

    private func validate(_ item: SocialContent, owner: String, hash: String) throws {
        guard item.owner == owner, item.kind == "route", let raw = item.body.archive,
              let archive = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              archive["contentHash"] as? String == hash else { throw SocialFailure.invalidResponse }
    }

    private func check(_ generation: UUID) throws {
        guard currentGeneration() == generation else { throw SocialFailure.accountChanged }
    }

    private func decode(_ value: [String: Any]) throws -> SocialContent {
        try JSONDecoder().decode(SocialContent.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
