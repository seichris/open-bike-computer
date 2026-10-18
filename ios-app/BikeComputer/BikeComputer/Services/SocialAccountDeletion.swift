import Foundation

/// A deletion this app sent or is about to send. Only its receipt secret, whose
/// digest the server commits together with an accepted deletion, can confirm it.
nonisolated struct SocialPendingDeletion: Codable, Equatable, Sendable {
    var version = 1
    let profileID: String
    /// Firebase UID of the account being deleted, so completion never signs out
    /// an account the rider switched to afterwards.
    let accountUID: String?
    let receipt: String
    let createdAt: Double
}

/// Native account deletion with recovery after lost responses, app restarts,
/// identity cleanup or automatic sign-out.
@MainActor
final class SocialAccountDeletion {
    static let storageKey = "pending-account-deletion-v1"
    /// An unconfirmed receipt younger than this may belong to a request still in flight.
    static let unconfirmedGrace: TimeInterval = 600
    /// Server failures that cannot prove the deletion was not committed.
    static let ambiguousCodes: Set<String> = ["service_unavailable", "database_busy", "identity_unavailable",
                                               "apple_revocation_unavailable", "concurrent_update_retry"]
    private let store: any SocialSecureStore
    private let client: any SocialRideNetworking
    private let anonymous: any SocialAnonymousNetworking
    private let now: () -> Date

    init(store: any SocialSecureStore, client: any SocialRideNetworking,
         anonymous: any SocialAnonymousNetworking, now: @escaping () -> Date = Date.init) {
        self.store = store; self.client = client; self.anonymous = anonymous; self.now = now
    }

    var pending: SocialPendingDeletion? {
        guard let data = try? store.read(Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(SocialPendingDeletion.self, from: data)
    }

    /// Confirms an earlier accepted deletion with its receipt alone: no sign-in,
    /// no provider re-authentication. Unknown receipts and missing identities are
    /// never treated as completion.
    func recoverPending() async -> SocialPendingDeletion? {
        guard let pending else { return nil }
        switch await resolve(pending) {
        case .confirmed:
            clear()
            return pending
        case .unknown:
            if now().timeIntervalSince1970-pending.createdAt > Self.unconfirmedGrace { clear() }
            return nil
        case .unreachable:
            return nil
        }
    }

    /// Deletes `profileID`. An earlier accepted deletion of the same account is
    /// confirmed first, so a rider whose identity was already cleaned up is never
    /// asked to sign in again (which could recreate an identity).
    func delete(profileID: String, accountUID: String?,
                reauthenticate: @MainActor () async throws -> String?,
                beforeSending: @MainActor () async -> Void = {}) async throws -> SocialPendingDeletion {
        if let recovered = await recoverPending(), recovered.profileID == profileID {
            return recovered
        }
        let appleCode = try await reauthenticate()
        // Reuse an unconfirmed receipt for this account: an earlier request that may
        // still commit can then be confirmed with the same secret.
        let record: SocialPendingDeletion
        if let existing = pending, existing.profileID == profileID {
            record = existing
        } else {
            record = SocialPendingDeletion(profileID: profileID, accountUID: accountUID,
                                           receipt: SocialSecret.make(), createdAt: now().timeIntervalSince1970)
        }
        // Persist before the server can accept it; an app kill mid-request stays recoverable.
        try store.write(JSONEncoder().encode(record), for: Self.storageKey)
        await beforeSending()
        var body: [String: Any] = ["expectedProfileID": profileID, "receiptDigest": SocialSecret.digest(record.receipt)]
        if let appleCode { body["appleAuthorizationCode"] = appleCode }
        do {
            _ = try await client.json("me/deletion", method: "POST", body: body)
            clear()
            return record
        } catch SocialFailure.server(let code) where ["account_deleting", "account_deleted"].contains(code) {
            // The account's own authenticated server response: deletion is under way.
            clear()
            return record
        } catch let SocialFailure.server(code) where !Self.ambiguousCodes.contains(code) {
            // A definitive rejection commits nothing, unless an earlier transport
            // attempt with this receipt was accepted before the retry was refused.
            switch await resolve(record) {
            case .confirmed: clear(); return record
            case .unknown: clear()
            case .unreachable: break
            }
            throw SocialFailure.server(code)
        } catch {
            // Lost responses, identity loss and service faults are ambiguous:
            // confirm immediately if possible, otherwise keep the receipt.
            if case .confirmed = await resolve(record) {
                clear()
                return record
            }
            throw error
        }
    }

    /// Local sign-out after a completed deletion applies only to the deleted
    /// account, never to an account signed in later on this phone.
    nonisolated static func shouldSignOut(_ completed: SocialPendingDeletion, currentUID: String?) -> Bool {
        guard let currentUID, let deleted = completed.accountUID else { return false }
        return currentUID == deleted
    }

    private enum Resolution { case confirmed, unknown, unreachable }

    private func resolve(_ pending: SocialPendingDeletion) async -> Resolution {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["receipt": pending.receipt])
            let data = try await anonymous.anonymousRequest("deletion-receipts/resolve", body: body)
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard value?["profileID"] as? String == pending.profileID,
                  ["deleting", "deleted"].contains(value?["status"] as? String ?? "") else { return .unknown }
            return .confirmed
        } catch SocialFailure.server("unknown_receipt") {
            return .unknown
        } catch {
            return .unreachable
        }
    }

    private func clear() { try? store.write(nil, for: Self.storageKey) }
}
