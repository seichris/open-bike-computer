import Combine
import Foundation

struct SocialRidePreview: Decodable {
    let title: String
    let route: SocialContentBody
}

/// Ephemeral link data belongs to the account and exact link that authorized
/// its read. A failed replacement read must never expose an earlier preview.
@MainActor
final class SocialLinkLoader: ObservableObject {
    enum Value {
        case profile(SocialProfile)
        case content(SocialContent)
        case ride(SocialRidePreview)
    }
    private struct Snapshot {
        let generation: UUID
        let url: URL
        let value: Value
    }
    @Published private var snapshot: Snapshot?
    private var revision = UUID()
    private let client: any SocialRideNetworking
    private let currentGeneration: () -> UUID

    init(client: any SocialRideNetworking, currentGeneration: @escaping () -> UUID) {
        self.client = client
        self.currentGeneration = currentGeneration
    }

    func value(for url: URL?) -> Value? {
        guard let snapshot, snapshot.generation == currentGeneration(), snapshot.url == url else { return nil }
        return snapshot.value
    }

    func reset() {
        revision = UUID()
        snapshot = nil
    }

    func load(_ url: URL) async throws {
        reset()
        let expected = currentGeneration()
        let request = revision
        guard let target = SocialLinkTarget(url: url) else { throw SocialFailure.invalidResponse }
        let value: Value
        switch target.kind {
        case "profile":
            value = .profile(try JSONDecoder().decode(SocialProfile.self, from: await client.request(
                "profiles/\(target.id)", method: "GET", body: nil, contentType: "application/json", query: [])))
        case "shared", "ride":
            let path = target.kind == "shared" ? "shared/resolve" : "group-rides/preview"
            let data = try await client.request(path, method: "POST",
                body: JSONSerialization.data(withJSONObject: ["code": target.id]), contentType: "application/json", query: [])
            if target.kind == "shared" { value = .content(try JSONDecoder().decode(SocialContent.self, from: data)) }
            else { value = .ride(try JSONDecoder().decode(SocialRidePreview.self, from: data)) }
        default:
            throw SocialFailure.invalidResponse
        }
        guard expected == currentGeneration(), request == revision, !Task.isCancelled else { throw SocialFailure.cancelled }
        snapshot = Snapshot(generation: expected, url: url, value: value)
    }
}
