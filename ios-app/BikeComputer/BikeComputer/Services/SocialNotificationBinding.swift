import Foundation

/// This app installation's push identity. The ID names the binding; the secret
/// proves possession of it, so neither an ID nor a push token alone can move it.
nonisolated struct SocialInstallation: Codable, Equatable, Sendable {
    var version = 1
    let id: String
    let secret: String
    /// Profile currently bound on the server, as confirmed by the last bind.
    var boundOwner: String?
    /// The bound account stopped representing this phone and its binding must be
    /// released. Persisted so offline sign-out, relaunch and forced sign-out finish it.
    var releasePending = false
}

/// Keeps the push binding attached to whichever account is signed in on this
/// installation. Alert failures never fail the rider's core social actions.
@MainActor
final class SocialNotificationBinding {
    enum Status: Equatable {
        case inactive
        case registered
        case unavailable(String)
    }

    static let storageKey = "push-installation-v1"
    private(set) var status: Status = .inactive {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?
    private let store: any SocialSecureStore
    private let client: any SocialRideNetworking
    private let anonymous: any SocialAnonymousNetworking
    private let environment: String
    private var tail: Task<Void, Never>?

    init(store: any SocialSecureStore, client: any SocialRideNetworking,
         anonymous: any SocialAnonymousNetworking, environment: String) {
        self.store = store; self.client = client; self.anonymous = anonymous; self.environment = environment
    }

    /// The durable installation identity, created once per app installation.
    func installation() throws -> SocialInstallation {
        if let data = try store.read(Self.storageKey),
           let value = try? JSONDecoder().decode(SocialInstallation.self, from: data) {
            return value
        }
        let value = SocialInstallation(id: UUID().uuidString, secret: SocialSecret.make())
        try save(value)
        return value
    }

    /// Binds this installation's push token to the signed-in account, handing it
    /// over from a previous account on this phone with the installation proof.
    @discardableResult
    func bind(token: String) async -> Bool {
        await serialized { [self] in
            do {
                var value = try installation()
                let body = try JSONSerialization.data(withJSONObject: [
                    "token": token, "environment": environment, "secret": value.secret], options: [.sortedKeys])
                let data = try await client.request("notification-devices/\(value.id)", method: "PUT", body: body,
                                                    contentType: "application/json", query: [])
                guard let owner = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["owner"] as? String else {
                    throw SocialFailure.invalidResponse
                }
                value.boundOwner = owner
                value.releasePending = false
                try save(value)
                status = .registered
                return true
            } catch SocialFailure.server("notification_binding_in_use") {
                status = .unavailable("Alerts for this phone are linked to another Bicino installation.")
            } catch {
                status = .unavailable("Request and invitation alerts are temporarily unavailable.")
            }
            return false
        }
    }

    /// The bound account no longer represents this phone: sign-out, forced
    /// sign-out, account switch or deletion. Records the obligation first, then
    /// releases with the installation proof, which needs no account token.
    func accountEnded() async {
        await serialized { [self] in
            guard var value = try? installation(), value.boundOwner != nil else { return }
            value.releasePending = true
            try? save(value)
            status = .inactive
            await releaseLocked()
        }
    }

    /// Completes a release left pending by an offline or interrupted sign-out.
    func releaseIfPending() async {
        await serialized { [self] in await releaseLocked() }
    }

    /// The server already removed every binding of a deleted account.
    func forget(owner: String) async {
        await serialized { [self] in
            guard var value = try? installation(), value.boundOwner == owner else { return }
            value.boundOwner = nil
            value.releasePending = false
            try? save(value)
            status = .inactive
        }
    }

    private func releaseLocked() async {
        guard var value = try? installation(), value.releasePending, let owner = value.boundOwner else { return }
        do {
            // The expected owner keeps a late release from removing a binding
            // already handed to the next account on this installation.
            let body = try JSONSerialization.data(withJSONObject: ["secret": value.secret, "owner": owner],
                                                  options: [.sortedKeys])
            _ = try await anonymous.anonymousRequest("notification-devices/\(value.id)/release", body: body)
            value.boundOwner = nil
            value.releasePending = false
            try? save(value)
        } catch {
            // Keep the persisted obligation for the next launch or sign-in.
        }
    }

    private func save(_ value: SocialInstallation) throws {
        try store.write(JSONEncoder().encode(value), for: Self.storageKey)
    }

    /// Binding and release run strictly in order, so a delayed release can never
    /// observe or overwrite the result of a newer bind.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            _ = await previous?.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
