import CryptoKit
import Foundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    let value = try condition()
    precondition(value, message)
}

@MainActor
final class SocialTestStore: SocialSecureStore {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws { values[key] = data }
}

private func object(_ data: Data?) -> [String: Any] {
    (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private func reply(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }

/// Mirrors the server's installation-proof rules for push bindings.
@MainActor
private final class PushServer: SocialRideNetworking, SocialAnonymousNetworking {
    struct Binding: Equatable { var owner: String; var token: String; var secretDigest: String }
    var bindings: [String: Binding] = [:]
    var account = "alice"
    var offline = false
    var log: [String] = []

    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        log.append("\(account) \(method) \(path)")
        let id = path.split(separator: "/")[1].lowercased()
        let payload = object(body)
        let token = payload["token"] as! String, digest = SocialSecret.digest(payload["secret"] as! String)
        if let current = bindings[id], current.secretDigest != digest { throw SocialFailure.server("notification_binding_in_use") }
        if let holder = bindings.first(where: { $0.key != id && $0.value.token == token }) {
            guard holder.value.owner == account else { throw SocialFailure.server("notification_binding_in_use") }
            bindings[holder.key] = nil
        }
        bindings[id] = Binding(owner: account, token: token, secretDigest: digest)
        return reply(["registered": true, "id": id, "owner": account])
    }
    func socket(rideID: String) async throws -> any SocialSocket { fatalError("unused") }
    func anonymousRequest(_ path: String, body: Data) async throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        log.append("anonymous POST \(path)")
        let id = path.split(separator: "/")[1].lowercased()
        let payload = object(body)
        if let current = bindings[id], current.owner == payload["owner"] as? String,
           current.secretDigest == SocialSecret.digest(payload["secret"] as! String) {
            bindings[id] = nil
        }
        return reply(["released": true])
    }
}

/// Server side of a native deletion: receipts are committed with acceptance.
@MainActor
private final class DeletionServer: SocialRideNetworking, SocialAnonymousNetworking {
    var state = "active"
    var identityPresent = true
    var receipts: [String: String] = [:]
    var lostResponses = 0
    var resolveOffline = false
    var deletionRequests = 0
    var resolutions = 0

    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        precondition(path == "me/deletion")
        deletionRequests += 1
        guard identityPresent else { throw SocialFailure.identityMissing }
        guard state == "active" else { throw SocialFailure.server(state == "deleting" ? "account_deleting" : "account_deleted") }
        let payload = object(body)
        receipts[payload["receiptDigest"] as! String] = payload["expectedProfileID"] as? String
        state = "deleting"
        if lostResponses > 0 { lostResponses -= 1; throw URLError(.networkConnectionLost) }
        return reply(["status": "deleting"])
    }
    func socket(rideID: String) async throws -> any SocialSocket { fatalError("unused") }
    func anonymousRequest(_ path: String, body: Data) async throws -> Data {
        precondition(path == "deletion-receipts/resolve")
        resolutions += 1
        if resolveOffline { throw URLError(.notConnectedToInternet) }
        let receipt = object(body)["receipt"] as! String
        guard let profile = receipts[SocialSecret.digest(receipt)], state != "active" else {
            throw SocialFailure.server("unknown_receipt")
        }
        return reply(["status": state, "profileID": profile])
    }
    /// The worker finished: Firebase identity and social rows are gone.
    func cleanUp() { state = "deleted"; identityPresent = false }
}

/// Minimal GRUP v1 device emulator following `social_riders_protocol.hpp`.
@MainActor
private final class FirmwareLink: SocialRelayLink {
    struct Slot { var present = false; var sequence: UInt32 = 0; var hash = Data(count: 32)
                  var imageHash = Data(count: 32); var imageReady = false }
    weak var engine: SocialRiderRelayEngine?
    var isReady = true
    var epoch: UInt32 = 0
    var slots = Array(repeating: Slot(), count: 8)
    var staging: (slot: Int, hash: Data, bytes: Data)?
    var log: [(op: UInt8, slot: Int)] = []

    func write(_ packet: Data) -> Bool {
        let op = packet[5], incoming = packet.uint32(6), slot = packet.count > 10 ? Int(packet[10]) : 255
        log.append((op, slot))
        var result: UInt8 = 0
        if op == 0 {
            if incoming != epoch { epoch = incoming; slots = Array(repeating: Slot(), count: 8); staging = nil }
        } else if incoming != epoch {
            result = 1
        } else {
            switch op {
            case 1:
                let sequence = packet.uint32(11), hash = packet.subdata(in: 33..<65)
                if slots[slot].present && sequence < slots[slot].sequence { result = 1; break }
                slots[slot].present = true; slots[slot].sequence = sequence; slots[slot].hash = hash
                slots[slot].imageReady = hash == slots[slot].imageHash && hash.contains { $0 != 0 }
            case 2:
                slots[slot] = Slot()
                if staging?.slot == slot { staging = nil }
            case 3:
                let hash = packet.subdata(in: 11..<43)
                guard slots[slot].present, hash == slots[slot].hash else { result = 2; break }
                if !(staging?.slot == slot && staging?.hash == hash) { staging = (slot, hash, Data()) }
            case 4:
                let offset = Int(packet[11]) | Int(packet[12]) << 8
                guard staging?.slot == slot else { result = 2; break }
                if offset != staging!.bytes.count { result = 1; break }
                staging!.bytes.append(packet.subdata(in: 13..<packet.count))
            case 5:
                if slots[slot].imageReady && slots[slot].imageHash == slots[slot].hash { break }
                guard let stage = staging, stage.slot == slot, stage.bytes.count == 3200, stage.hash == slots[slot].hash,
                      Data(SHA256.hash(data: stage.bytes)) == stage.hash else { result = 3; break }
                slots[slot].imageHash = stage.hash; slots[slot].imageReady = true; staging = nil
            default:
                result = 2
            }
        }
        var ack = Data("GACK".utf8)
        ack.append(packet.subdata(in: 6..<10))
        ack.append(UInt8(truncatingIfNeeded: slot))
        let offset = UInt16(staging?.bytes.count ?? 0)
        ack.append(UInt8(offset & 0xff)); ack.append(UInt8(offset >> 8))
        ack.append(result); ack.append(op)
        let sequence = slot < 8 ? slots[slot].sequence : 0
        for shift in stride(from: 0, to: 32, by: 8) { ack.append(UInt8((sequence >> UInt32(shift)) & 0xff)) }
        engine?.receive(ack)
        return true
    }
    func operations(since mark: Int, _ op: UInt8) -> [Int] { log[mark...].filter { $0.op == op }.map(\.slot) }
}

private extension Data {
    func uint32(_ index: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[index+$1]) << ($1*8) } }
}

@MainActor
enum SocialMaintenanceTests {
    static func run() async throws {
        try await pushInstallationLifecycle()
        try await deletionRecoveryOrchestration()
        await stableRelaySlots()
        print("Social push installation, deletion recovery and stable relay slot regressions passed")
    }

    static func pushInstallationLifecycle() async throws {
        let store = SocialTestStore(), server = PushServer()
        func launch() -> SocialNotificationBinding {
            SocialNotificationBinding(store: store, client: server, anonymous: server, environment: "development")
        }
        var binding = launch()
        let installation = try binding.installation()
        check(installation.secret.count >= 43 && UUID(uuidString: installation.id) != nil, "Installation identity is a UUID with a 256-bit secret")
        try check(try launch().installation() == installation, "Relaunch reuses the persisted installation identity")
        var bound = await binding.bind(token: "a1")
        check(bound, "Alice binds this installation")
        check(server.bindings[installation.id.lowercased()]?.owner == "alice" && binding.status == .registered, "Binding confirmed")

        // Alice signs out offline. The obligation survives a relaunch and completes later.
        server.offline = true
        await binding.accountEnded()
        try check(try binding.installation().releasePending, "Offline sign-out persists the pending release")
        server.offline = false
        binding = launch()
        await binding.releaseIfPending()
        try check(server.bindings.isEmpty && !(try binding.installation().releasePending), "Relaunch releases with the installation proof")
        check(server.log.last == "anonymous POST notification-devices/\(installation.id)/release",
              "Release needs no account token and keeps its secret out of the URL")

        // Account switch: Alice's release never reached the server; Bob's bind hands the installation over.
        bound = await binding.bind(token: "a1")
        check(bound, "Alice binds again")
        server.offline = true
        await binding.accountEnded()
        server.offline = false
        server.account = "bob"
        binding = launch()
        bound = await binding.bind(token: "a1")
        check(bound, "Bob binds after an account switch")
        check(server.bindings[installation.id.lowercased()]?.owner == "bob", "The proven installation moved to Bob")
        try check(try binding.installation() == SocialInstallation(id: installation.id, secret: installation.secret,
                  boundOwner: "bob", releasePending: false), "Bob's bind supersedes Alice's pending release")
        await binding.releaseIfPending()
        check(server.bindings[installation.id.lowercased()]?.owner == "bob", "A superseded release cannot remove Bob's binding")

        // Forced sign-out (revoked or deleted identity): the release still completes anonymously.
        let before = server.log.count
        await binding.accountEnded()
        check(server.bindings.isEmpty && server.log[before...].allSatisfy { $0.hasPrefix("anonymous") },
              "Forced sign-out releases without any account request")

        // An attacker who learned the installation ID and token but not the secret is rejected.
        bound = await binding.bind(token: "a1")
        check(bound, "Bob binds once more")
        let attackerStore = SocialTestStore()
        attackerStore.values[SocialNotificationBinding.storageKey] = try JSONEncoder().encode(
            SocialInstallation(id: installation.id, secret: SocialSecret.make()))
        server.account = "mallory"
        let attacker = SocialNotificationBinding(store: attackerStore, client: server, anonymous: server, environment: "development")
        bound = await attacker.bind(token: "a1")
        check(!bound, "Knowing an installation ID and token is not proof")
        if case .unavailable = attacker.status {} else { preconditionFailure("A rejected bind reports unavailable alerts without throwing") }
        let impostor = SocialNotificationBinding(store: SocialTestStore(), client: server, anonymous: server, environment: "development")
        bound = await impostor.bind(token: "a1")
        check(!bound, "A known push token cannot be moved to another account")
        check(server.bindings[installation.id.lowercased()]?.owner == "bob", "Bob keeps his binding")
        // The deleted account's bindings were removed by the server; forget them locally.
        await binding.forget(owner: "bob")
        try check(try binding.installation().boundOwner == nil, "A deleted owner is forgotten locally")
    }

    static func deletionRecoveryOrchestration() async throws {
        // Both responses lost, then worker cleanup and an app restart.
        let store = SocialTestStore(), server = DeletionServer()
        var reauthentications = 0
        server.lostResponses = 1
        server.resolveOffline = true
        do {
            _ = try await SocialAccountDeletion(store: store, client: server, anonymous: server)
                .delete(profileID: "profile-a", accountUID: "uid-a", reauthenticate: { reauthentications += 1; return nil })
            preconditionFailure("A lost response is not reported as complete before confirmation")
        } catch is URLError {}
        check(server.state == "deleting" && reauthentications == 1, "The server accepted the deletion")
        let receipt = SocialAccountDeletion(store: store, client: server, anonymous: server).pending
        check(receipt?.profileID == "profile-a" && receipt?.accountUID == "uid-a", "The receipt was persisted before sending")
        server.cleanUp()
        server.resolveOffline = false
        let restarted = SocialAccountDeletion(store: store, client: server, anonymous: server)
        let completed = try await restarted.delete(profileID: "profile-a", accountUID: "uid-a",
            reauthenticate: { reauthentications += 1; throw SocialFailure.identityMissing })
        check(completed.receipt == receipt?.receipt && reauthentications == 1 && server.deletionRequests == 1,
              "An accepted deletion is confirmed by receipt before any provider re-authentication")
        check(restarted.pending == nil, "A confirmed receipt is cleared")

        // Recovery after automatic sign-out signs out only the deleted account.
        check(SocialAccountDeletion.shouldSignOut(completed, currentUID: "uid-a"), "The deleted account is signed out")
        check(!SocialAccountDeletion.shouldSignOut(completed, currentUID: "uid-b"), "A newly switched account stays signed in")
        check(!SocialAccountDeletion.shouldSignOut(completed, currentUID: nil), "Nothing to sign out when signed out")

        // Unknown receipts and missing identities never imply completion.
        var clock = Date(timeIntervalSince1970: 10_000)
        let unknownStore = SocialTestStore(), stranger = DeletionServer()
        let pending = SocialPendingDeletion(profileID: "profile-c", accountUID: "uid-c", receipt: SocialSecret.make(),
                                            createdAt: clock.timeIntervalSince1970)
        unknownStore.values[SocialAccountDeletion.storageKey] = try JSONEncoder().encode(pending)
        let orchestrator = SocialAccountDeletion(store: unknownStore, client: stranger, anonymous: stranger, now: { clock })
        var recovered = await orchestrator.recoverPending()
        check(recovered == nil && orchestrator.pending != nil,
              "A fresh unknown receipt is neither completion nor discarded while a request may be in flight")
        clock += 601
        recovered = await orchestrator.recoverPending()
        check(recovered == nil && orchestrator.pending == nil,
              "An unknown receipt is discarded after the in-flight grace period")
        stranger.identityPresent = false
        do {
            _ = try await orchestrator.delete(profileID: "profile-c", accountUID: "uid-c", reauthenticate: { nil })
            preconditionFailure("A missing identity is not proof of deletion")
        } catch SocialFailure.identityMissing {}
        check(orchestrator.pending != nil, "The unconfirmed receipt is kept for later confirmation")

        // An authenticated server answer that deletion is under way completes it (e.g. started on the website).
        let website = DeletionServer()
        website.state = "deleting"
        let viaWebsite = SocialAccountDeletion(store: SocialTestStore(), client: website, anonymous: website)
        let viaServer = try await viaWebsite.delete(profileID: "profile-d", accountUID: "uid-d", reauthenticate: { nil })
        check(viaServer.profileID == "profile-d" && viaWebsite.pending == nil, "The account's own server response completes deletion")
    }

    static func stableRelaySlots() async {
        var clock: TimeInterval = 1_000
        let link = FirmwareLink()
        let engine = SocialRiderRelayEngine(link: link, uptime: { clock }, pause: { _ in await Task.yield() })
        link.engine = engine
        func rider(_ index: Int, age: Double = 0) -> SocialRelayRider {
            SocialRelayRider(id: "rider-\(index)", latitude: Double(index) * 0.01, longitude: 0, ageSeconds: age,
                             accuracy: 5, course: nil, initials: "R\(index)",
                             pixels: Data(repeating: UInt8(index), count: SocialRiderRelayEngine.portraitBytes))
        }
        let own = (latitude: 0.0, longitude: 0.0)
        var started = await engine.begin(epoch: 7)
        check(started, "A device session starts")
        await engine.update(riders: (1...8).map { rider($0) }, own: own)
        check(link.operations(since: 0, 5).count == 8 && link.slots.allSatisfy(\.imageReady), "Eight portraits are committed once")
        let placement = engine.slots

        // A ninth, nearer rider replaces only the farthest rider's slot.
        var mark = link.log.count
        let farthest = placement.firstIndex(of: "rider-8")!
        await engine.update(riders: [rider(0)] + (1...8).map { rider($0) }, own: own)
        check(link.operations(since: mark, 2) == [farthest], "Only the replaced slot is cleared")
        check(link.operations(since: mark, 3) == [farthest] && link.operations(since: mark, 5) == [farthest],
              "Only the newcomer's portrait is uploaded")
        check(zip(placement, engine.slots).enumerated().allSatisfy { $0.offset == farthest || $0.element.0 == $0.element.1 },
              "Every unchanged rider keeps its slot")

        // Rider 3's position expires during a coverage gap, then the rider returns.
        mark = link.log.count
        clock += 61
        let slot3 = engine.slots.firstIndex(of: "rider-3")!
        await engine.update(riders: [0, 1, 2, 4, 5, 6, 7].map { rider($0) }, own: own)
        check(link.operations(since: mark, 2).isEmpty && link.operations(since: mark, 3).isEmpty,
              "An expired rider is parked, not cleared, and nobody's portrait is re-sent")
        mark = link.log.count
        await engine.update(riders: [0, 1, 2, 3, 4, 5, 6, 7].map { rider($0) }, own: own)
        check(engine.slots[slot3] == "rider-3" && link.slots[slot3].imageReady, "The returning rider resumes its slot and portrait")
        check(link.operations(since: mark, 3).isEmpty && link.operations(since: mark, 2).isEmpty,
              "A return needs no portrait upload")

        // Rider 5 stops sharing before expiry: cleared immediately, others untouched.
        mark = link.log.count
        let slot5 = engine.slots.firstIndex(of: "rider-5")!
        await engine.update(riders: [0, 1, 2, 3, 4, 6, 7].map { rider($0) }, own: own)
        check(link.operations(since: mark, 2) == [slot5] && link.operations(since: mark, 3).isEmpty,
              "A rider who left is cleared at once without disturbing other slots")

        // The device lost the session (for example a reset): the engine asks for a new one.
        link.epoch = 0
        await engine.update(riders: [0, 1, 2, 3].map { rider($0) }, own: own)
        check(engine.needsSessionRestart, "A device-side session loss requests a new session")
        mark = link.log.count
        started = await engine.begin(epoch: 8)
        check(started, "A new session starts")
        await engine.update(riders: [0, 1, 2, 3].map { rider($0) }, own: own)
        check(link.operations(since: mark, 5).count == 4, "Only a real session change re-sends portraits")
    }
}
