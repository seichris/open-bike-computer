import CoreLocation
import Foundation

@MainActor
private final class FriendNetwork: SocialRideNetworking {
    var seconds = 0.0
    var consents: [String: [String: Any]] = [:]
    var publications: [[String: Any]] = []
    var holdSnapshot = false
    var holdConsent = false
    var held: CheckedContinuation<Void, Never>?
    func consent(_ id: String) -> [String: Any] {
        consents[id] ?? ["profileID": id, "epoch": UUID().uuidString, "sharing": false, "serverTime": 1000.0]
    }
    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data {
        var value: [String: Any]
        if path == "friend-sharing" {
            value = ["outgoing": Array(consents.values.filter { $0["sharing"] as? Bool == true }), "riders": [], "serverTime": 1000.0]
            if holdSnapshot {
                holdSnapshot = false
                await withCheckedContinuation { held = $0 }
            }
        } else if path == "friend-sharing/state" {
            let state = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            publications.append(state)
            let epochs = state["epochs"] as! [String: String]
            value = ["accepted": Array(epochs.keys)]
        } else {
            let id = path.split(separator: "/")[1].description
            value = consent(id)
            consents[id] = value
            if method == "POST" {
                let data = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
                if holdConsent {
                    holdConsent = false
                    await withCheckedContinuation { held = $0 }
                }
                value = ["profileID": id, "epoch": UUID().uuidString, "sharing": data["location"]!,
                         "sharingExpiresAt": 15400.0, "serverTime": 1000.0]
                consents[id] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func socket(rideID: String) async throws -> any SocialSocket { throw SocialFailure.unavailable }
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
        let network = FriendNetwork()
        let service = FriendLiveService(client: network, uptime: { network.seconds }, pollNanoseconds: 3_600_000_000_000)
        service.prepareLocation = { false }
        do { try await service.setSharing(true, with: "bob"); preconditionFailure("Location permission required") }
        catch SocialFailure.server("location_access_required") { }
        check(network.consents.isEmpty && !service.isSharing, "permission denial cannot create consent")
        service.prepareLocation = { true }
        try await service.setSharing(true, with: "bob")
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
        print("Direct friend sharing permission, audience, expiry, relaunch and consent race regressions passed")
    }
}
