import Combine
import CoreLocation
import Foundation

@MainActor
private final class FriendNetwork: SocialRideNetworking {
    var seconds = 0.0
    var serverTime = 1000.0
    var snapshotFailure: Error?
    var consentFailure: Error?
    var consentWrites = 0
    var lastSequences: [String: Int] = [:]
    var consents: [String: [String: Any]] = [:]
    var publications: [[String: Any]] = []
    var snapshotReads = 0
    var riders: [[String: Any]] = []
    var holdSnapshot = false
    var holdConsent = false
    var holdPublication = false
    var publicationFailure: Error?
    var held: CheckedContinuation<Void, Never>?
    func consent(_ id: String) -> [String: Any] {
        consents[id] ?? ["profileID": id, "epoch": UUID().uuidString, "sharing": false, "serverTime": serverTime]
    }
    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        var value: [String: Any]
        if path == "friend-sharing" {
            if method == "GET" { snapshotReads += 1 }
            if method == "GET", let snapshotFailure { throw snapshotFailure }
            if method == "DELETE" { consents = [:] }
            value = ["outgoing": Array(consents.values.filter {
                $0["sharing"] as? Bool == true && ($0["sharingExpiresAt"] as? Double ?? 0) > serverTime
            }), "riders": riders, "serverTime": serverTime]
            if holdSnapshot {
                holdSnapshot = false
                await withCheckedContinuation { held = $0 }
            }
        } else if path == "friend-sharing/state" {
            if holdPublication {
                holdPublication = false
                await withCheckedContinuation { held = $0 }
                // URLSession abandons a cancelled task's request.
                if Task.isCancelled { throw CancellationError() }
            }
            if let failure = publicationFailure { publicationFailure = nil; throw failure }
            let state = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            publications.append(state)
            let epochs = state["epochs"] as! [String: String]
            let sequence = state["sequence"] as! Int
            let accepted = epochs.filter { id, epoch in
                consents[id]?["epoch"] as? String == epoch && sequence > (lastSequences[epoch] ?? -1)
            }
            for epoch in accepted.values { lastSequences[epoch] = sequence }
            value = ["accepted": Array(accepted.keys)]
        } else {
            if let consentFailure { throw consentFailure }
            let id = path.split(separator: "/")[1].description
            value = consent(id)
            consents[id] = value
            if method == "POST" {
                consentWrites += 1
                let data = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
                if holdConsent {
                    holdConsent = false
                    await withCheckedContinuation { held = $0 }
                }
                value = ["profileID": id, "epoch": UUID().uuidString, "sharing": data["location"]!,
                         "sharingExpiresAt": serverTime+14400, "serverTime": serverTime]
                consents[id] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func socket(rideID: String) async throws -> any SocialSocket { throw SocialFailure.unavailable }
}

@MainActor
private final class FriendPersistence: SocialSecureStore {
    var values: [String: Data] = [:]
    var writes = 0
    var failWrites = false
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws {
        if failWrites { throw SocialFailure.unavailable }
        writes += 1; values[key] = data
    }
}

@MainActor
struct FriendLiveServiceTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Friend sharing async condition timed out")
    }
    static func fix(_ offset: Double = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 1, longitude: 2), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: 5, course: 20, speed: 6,
                   timestamp: Date().addingTimeInterval(offset))
    }
    static func run() async throws {
        let idleNetwork = FriendNetwork()
        var delays: [UInt64] = []
        let idle = FriendLiveService(client: idleNetwork, sleep: { delay in
            delays.append(delay)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        var changes = 0
        let subscription = idle.objectWillChange.sink { changes += 1 }
        idle.start()
        try await wait { delays.count == 1 }
        check(idleNetwork.snapshotReads == 1 && delays == [60_000_000_000], "idle polling waits a minute after a single read")
        check(changes == 0, "empty idle polls do not publish unchanged map state")
        idle.setApplicationActive(false)
        await Task.yield()
        check(idle.nextPollNanoseconds == nil && idleNetwork.snapshotReads == 1, "background idle has no poll task")
        idle.setApplicationActive(true)
        try await wait { delays.count == 2 }
        check(idleNetwork.snapshotReads == 2, "foreground resumes discovery immediately")
        idleNetwork.riders = [["profile": ["id": "friend", "displayName": "Friend"],
            "latitude": 1.0, "longitude": 2.0, "capturedAt": 1000.0, "receivedAt": 1000.0,
            "horizontalAccuracy": 5.0, "sequence": 1, "age": 0.0]]
        await idle.tick()
        check(idle.nextPollNanoseconds == 3_000_000_000, "incoming riders use fast polling")
        let previousChanges = changes
        await idle.tick()
        check(changes == previousChanges, "unchanged publications do not reload the map")
        idle.setApplicationActive(false)
        check(idle.nextPollNanoseconds == 3_000_000_000, "active incoming stream remains timely in background")
        idleNetwork.riders = []
        await idle.tick()
        check(idle.nextPollNanoseconds == nil, "background receiver pauses after its last rider disappears")
        idle.reset()
        withExtendedLifetime(subscription) {}
        let network = FriendNetwork()
        let service = FriendLiveService(client: network, uptime: { network.seconds }, pollNanoseconds: 3_600_000_000_000)
        service.prepareLocation = { false }
        do { try await service.setSharing(true, with: "bob"); preconditionFailure("Location permission required") }
        catch SocialFailure.server("location_access_required") { }
        check(network.consents.isEmpty && !service.isSharing, "permission denial cannot create consent")
        service.prepareLocation = { true }
        try await service.setSharing(true, with: "bob")
        service.setApplicationActive(false)
        check(service.nextPollNanoseconds == 3_600_000_000_000, "outgoing sharing continues in background")
        service.updateLocation(fix())
        await service.tick()
        check(service.sharingIDs == ["bob"], "only selected friends receive this phone's stream")
        check(network.publications.last?["speed"] as? Double == 6, "GPS ride stats accompany location")
        // A poll read before a new consent must not revoke that new consent.
        network.holdSnapshot = true
        let poll = Task { await service.tick() }
        try await wait { network.held != nil }
        try await service.setSharing(true, with: "carol")
        network.held?.resume(); network.held = nil
        await poll.value
        check(service.sharingIDs == ["bob", "carol"], "stale snapshot cannot erase a newer friend toggle")
        // Stopping is local immediately, even while the network stop is pending.
        network.holdConsent = true
        let stop = Task { try await service.setSharing(false, with: "bob") }
        try await wait { network.held != nil }
        check(service.sharingIDs == ["carol"], "a pending offline stop already removes its GPS recipient")
        network.seconds = 3  // Outside the server's two-second publication window.
        service.updateLocation(fix(0.01))
        await service.tick()
        let epochs = network.publications.last?["epochs"] as? [String: String]
        check(epochs?.keys.contains("bob") == false && epochs?.keys.contains("carol") == true, "stopped audience cannot receive a subsequent fix")
        network.held?.resume(); network.held = nil
        try await stop.value
        // A new instance can receive friends but never resumes an old publisher.
        let reopened = FriendLiveService(client: network)
        await reopened.tick()
        check(!reopened.isSharing, "server consent alone cannot restart GPS after relaunch")
        network.seconds = 14401
        await service.tick()
        check(!service.isSharing, "four-hour limit uses monotonic time")
        // An accepted response from an account cleared during the request is ignored.
        network.holdConsent = true
        let start = Task { try await service.setSharing(true, with: "bob") }
        try await wait { network.held != nil }
        await service.stopAll()
        network.held?.resume(); network.held = nil
        do { try await start.value; preconditionFailure("cleared request must be cancelled") }
        catch SocialFailure.cancelled { }
        check(!service.isSharing && service.riders.isEmpty, "account changes retire pending GPS publication")
        reopened.reset(); service.reset()
        try await publicationPacing()
        try await rememberedSharing()
        print("Direct friend sharing permission, audience, expiry, relaunch, consent race and publication pacing regressions passed")
    }

    static func rememberedSharing() async throws {
        func make(_ network: FriendNetwork, _ store: FriendPersistence) -> FriendLiveService {
            let service = FriendLiveService(client: network, store: store, uptime: { network.seconds },
                sleep: { _ in throw CancellationError() })
            service.prepareLocation = { true }
            return service
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func seed() async throws -> (FriendNetwork, FriendPersistence, FriendLiveService) {
            let network = FriendNetwork(), store = FriendPersistence()
            let service = make(network, store)
            service.start(owner: "alice"); await settle()
            try await service.setSharing(true, with: "bob"); await settle()
            network.seconds = 3
            service.updateLocation(fix()); await service.tick()
            check(service.isSharing && !network.publications.isEmpty, "seed publishes an explicitly selected friend")
            return (network, store, service)
        }
        let (network, store, first) = try await seed()
        let originalExpiry = network.consents["bob"]?["sharingExpiresAt"] as! Double
        let originalSequence = network.publications.last?["sequence"] as! Int
        let storageWrites = store.writes
        network.seconds = 6; first.updateLocation(fix(0.01)); await first.tick()
        check(store.writes == storageWrites, "sequence block does not rewrite Keychain for every GPS fix")
        let saved = store.values
        check(!String(decoding: saved.values.first!, as: UTF8.self).contains("latitude"), "remembered sharing contains no location fixes")
        network.serverTime = 4600; network.seconds = 3600
        let consentWrites = network.consentWrites
        let reopened = make(network, store)
        reopened.start(owner: "alice"); await settle()
        check(reopened.sharingIDs == ["bob"], "same installation and account resume the remembered recipient")
        reopened.updateLocation(fix(0.02)); await reopened.tick()
        check(reopened.isSharing, "the server accepts the restored publication sequence")
        check((network.publications.last?["sequence"] as! Int) > originalSequence+1, "relaunch skips previously reserved sequences")
        check(network.consentWrites == consentWrites && network.consents["bob"]?["sharingExpiresAt"] as? Double == originalExpiry,
              "restoring never renews the original server lease")
        network.seconds = 14401; await reopened.tick()
        check(!reopened.isSharing && store.values.isEmpty, "restored sharing expires at the original deadline, not four hours after relaunch")

        // A reboot and a changed wall clock cannot extend the server's deadline.
        let expiredStore = FriendPersistence(); expiredStore.values = saved
        network.seconds = 0; network.serverTime = originalExpiry+1
        let expired = make(network, expiredStore); expired.start(owner: "alice"); await settle()
        check(!expired.isSharing && expiredStore.values.isEmpty, "expired server leases are discarded even with a fresh uptime")

        let (multipleNetwork, multipleStore, multiple) = try await seed()
        multipleNetwork.serverTime = 2000
        try await multiple.setSharing(true, with: "carol"); await settle()
        multipleNetwork.serverTime = 15401; multipleNetwork.seconds = 0
        let partial = make(multipleNetwork, multipleStore); partial.start(owner: "alice"); await settle()
        check(partial.sharingIDs == ["carol"], "each friend keeps its own original expiry when restoring multiple recipients")
        multipleNetwork.seconds = 1000; await partial.tick()
        check(!partial.isSharing, "the remaining friend expires without extending its lease")

        let (offlineNetwork, offlineStore, _) = try await seed()
        offlineNetwork.snapshotFailure = URLError(.notConnectedToInternet)
        let offline = make(offlineNetwork, offlineStore)
        offline.start(owner: "alice"); await settle()
        check(!offline.isSharing, "offline relaunch cannot send before server revalidation")
        offlineNetwork.snapshotFailure = nil
        await offline.tick()
        check(offline.sharingIDs == ["bob"], "pending restoration retries when the server is reachable")
        offlineNetwork.consentFailure = URLError(.notConnectedToInternet)
        do { try await offline.setSharing(false, with: "bob"); preconditionFailure("offline revocation should report the network failure") }
        catch is URLError { }
        let stopped = make(offlineNetwork, offlineStore)
        stopped.start(owner: "alice"); await settle()
        check(!stopped.isSharing && offlineStore.values.isEmpty, "offline Stop is durable despite a still-active server lease")

        let (revokedNetwork, revokedStore, _) = try await seed()
        revokedNetwork.consents["bob"]?["epoch"] = UUID().uuidString
        let revoked = make(revokedNetwork, revokedStore); revoked.start(owner: "alice"); await settle()
        check(!revoked.isSharing && revokedStore.values.isEmpty, "rotated consent, unfriend or block cannot resurrect a remembered recipient")

        let (accountNetwork, accountStore, signedIn) = try await seed()
        let other = make(accountNetwork, accountStore); other.start(owner: "another-account"); await settle()
        check(!other.isSharing, "a different signed-in account never inherits sharing")
        await signedIn.stopAll()
        let signedBackIn = make(accountNetwork, accountStore); signedBackIn.start(owner: "alice"); await settle()
        check(!signedBackIn.isSharing && accountStore.values.isEmpty, "sign-out clears the account's remembered consents")

        let (raceNetwork, raceStore, _) = try await seed()
        let racing = make(raceNetwork, raceStore)
        var permission: CheckedContinuation<Bool, Never>?
        racing.prepareLocation = { await withCheckedContinuation { permission = $0 } }
        racing.start(owner: "alice")
        try await wait { permission != nil }
        try await racing.setSharing(false, with: "bob")
        permission?.resume(returning: true); permission = nil; await settle()
        check(!racing.isSharing && raceStore.values.isEmpty, "a pending permission response cannot undo a newer Stop")

        let (backgroundNetwork, backgroundStore, _) = try await seed()
        let background = make(backgroundNetwork, backgroundStore)
        background.setApplicationActive(false); background.start(owner: "alice")
        await background.tick()
        check(!background.isSharing, "a background launch cannot cold-start restored GPS")
        background.setApplicationActive(true); await settle()
        check(background.isSharing, "opening the app resumes a valid remembered stream")

        let (failureNetwork, failureStore, _) = try await seed()
        let failure = make(failureNetwork, failureStore); failure.start(owner: "alice"); await settle()
        failureStore.failWrites = true
        let sent = failureNetwork.publications.count
        failureNetwork.seconds = 6; failure.updateLocation(fix(0.03)); await failure.tick()
        check(failureNetwork.publications.count == sent && failure.error != nil, "a sequence reservation must persist before publication")
        failureStore.failWrites = false
        failureNetwork.seconds = 9; await failure.tick()
        check(failureNetwork.publications.count == sent+1 && failure.isSharing, "publication retries with a durably reserved sequence")
        print("Remembered friend sharing relaunch, original expiry, revocation, account, offline Stop, permission race and sequence durability checks passed")
    }

    /// Wakes cancel an in-flight poll and restart immediately; neither may report a
    /// false failure, drop the audience, or republish inside the server's rate window.
    static func publicationPacing() async throws {
        let network = FriendNetwork()
        let service = FriendLiveService(client: network, uptime: { network.seconds }, pollNanoseconds: 3_600_000_000_000)
        service.prepareLocation = { true }
        service.updateLocation(fix())
        network.holdPublication = true
        try await service.setSharing(true, with: "dana")
        try await wait { network.held != nil }
        let reads = network.snapshotReads
        service.setApplicationActive(false)
        try await wait { network.snapshotReads > reads }
        for _ in 0..<5 { await Task.yield() }
        network.held?.resume(); network.held = nil
        for _ in 0..<5 { await Task.yield() }
        check(network.publications.isEmpty, "a wake never sends a second fix while the first is in flight")
        check(service.error == nil && service.sharingIDs == ["dana"], "a superseded publication is neither a failure nor a revocation")
        network.seconds = 3
        network.publicationFailure = SocialFailure.server("publish_rate")
        service.updateLocation(fix(0.02))
        await service.tick()
        check(service.error == nil && service.sharingIDs == ["dana"], "the server's rate window is not a sharing failure")
        network.seconds = 6
        network.publicationFailure = URLError(.notConnectedToInternet)
        service.updateLocation(fix(0.03))
        await service.tick()
        check(service.error != nil, "a real publication failure is still reported")
        network.seconds = 9
        service.updateLocation(fix(0.04))
        await service.tick()
        check(network.publications.count == 1 && service.error == nil, "the next accepted fix clears the failure")
        network.seconds = 10
        service.updateLocation(fix(0.05))
        let wakeReads = network.snapshotReads
        service.setApplicationActive(true)
        try await wait { network.snapshotReads > wakeReads }
        for _ in 0..<5 { await Task.yield() }
        check(network.publications.count == 1, "an immediate wake inside the rate window waits for the next poll")
        network.seconds = 11.5
        await service.tick()
        check(network.publications.count == 2 && service.error == nil, "publication resumes once the window has passed")
        service.reset()
    }
}
