import Combine
import CoreLocation
import Foundation

/// Route-independent, one-way friend sharing. Consents are deliberately volatile:
/// opening the app never resumes GPS publication from a previous phone session.
@MainActor
final class FriendLiveService: ObservableObject {
    @Published private(set) var riders: [SocialRider] = []
    @Published private(set) var sharingIDs: Set<String> = []
    @Published private(set) var busyIDs: Set<String> = []
    @Published private(set) var isSharing = false
    @Published private(set) var error: String?
    var prepareLocation: (() async -> Bool)?
    var onRidersChanged: (([SocialRider]) -> Void)?
    private let client: any SocialRideNetworking
    private let uptime: () -> TimeInterval
    private let pollNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var leases: [String: (epoch: String, deadline: Double)] = [:]
    private var latestLocation: CLLocation?
    private var progress = SharedRideProgress()
    private var startedAt = 0.0
    private var sequence = 0
    private var lastPublished: Date?

    init(client: any SocialRideNetworking,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pollNanoseconds: UInt64 = 3_000_000_000) {
        self.client = client; self.uptime = uptime; self.pollNanoseconds = pollNanoseconds
    }

    func updateLocation(_ location: CLLocation?) {
        latestLocation = location
        guard isSharing, let location, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else { return }
        progress.add(location)
    }

    func start() {
        guard task == nil else { return }
        let expected = generation
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, expected == self.generation {
                await self.tick()
                try? await Task.sleep(nanoseconds: self.pollNanoseconds)
            }
        }
    }

    func setSharing(_ enabled: Bool, with id: String) async throws {
        guard !busyIDs.contains(id) else { return }
        let expected = generation
        busyIDs.insert(id)
        defer { if expected == generation { busyIDs.remove(id) } }
        if enabled {
            guard await prepareLocation?() == true else { throw SocialFailure.server("location_access_required") }
            guard expected == generation else { throw SocialFailure.cancelled }
        } else {
            // Stop GPS publication before any network await, including offline revocation.
            leases[id] = nil; updateSharing()
        }
        let path = "friend-sharing/\(id)/consent"
        let current = try await client.json(path)
        guard expected == generation, let epoch = current["epoch"] as? String else { throw SocialFailure.cancelled }
        let requestedAt = uptime()
        let value = try await client.json(path, method: "POST", body: ["epoch": epoch, "location": enabled, "stats": enabled])
        guard expected == generation else { throw SocialFailure.cancelled }
        let consent = try JSONDecoder().decode(SocialFriendConsent.self, from: JSONSerialization.data(withJSONObject: value))
        if enabled {
            guard consent.sharing, let expiry = consent.sharingExpiresAt else { throw SocialFailure.server("sharing_disabled") }
            if leases.isEmpty {
                progress = SharedRideProgress(); startedAt = uptime(); sequence = 0
            }
            leases[id] = (consent.epoch, requestedAt + min(4*3600, max(0, expiry-consent.serverTime)))
            lastPublished = nil
        }
        error = nil
        updateSharing()
        start()
    }

    private func updateSharing() {
        sharingIDs = Set(leases.keys)
        isSharing = !leases.isEmpty
    }

    /// Also used by portable runtime tests; all response application is fenced
    /// against account changes and consent changes made while a poll was in flight.
    func tick() async {
        let expected = generation
        leases = leases.filter { $0.value.deadline > uptime() }
        updateSharing()
        let requestedEpochs = leases.mapValues(\.epoch)
        do {
            let data = try await client.request("friend-sharing", method: "GET", body: nil, contentType: "application/json", query: [])
            guard expected == generation else { return }
            let snapshot = try JSONDecoder().decode(SocialFriendSnapshot.self, from: data)
            let remote = Dictionary(uniqueKeysWithValues: snapshot.outgoing.map { ($0.profileID, $0.epoch) })
            for (id, epoch) in requestedEpochs where leases[id]?.epoch == epoch && remote[id] != epoch {
                leases[id] = nil
            }
            updateSharing()
            riders = snapshot.riders.filter { $0.age(at: Date()) < 60 }
            onRidersChanged?(riders)
        } catch {
            guard expected == generation else { return }
            riders.removeAll { $0.age(at: Date()) >= 60 }
            if case SocialFailure.server(let code) = error,
               ["feature_unavailable", "account_unavailable", "account_deleting"].contains(code) {
                reset(); return
            }
        }
        guard expected == generation, !leases.isEmpty, let location = latestLocation,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
              abs(location.timestamp.timeIntervalSinceNow) < 30,
              location.timestamp != lastPublished else { return }
        let epochs = leases.mapValues(\.epoch)
        var state: [String: Any] = ["epochs": epochs, "sequence": sequence,
            "latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
            "capturedAt": location.timestamp.timeIntervalSince1970,
            "horizontalAccuracy": location.horizontalAccuracy,
            "distanceMeters": progress.distanceMeters, "movingSeconds": progress.movingSeconds,
            "elapsedSeconds": max(0, uptime()-startedAt)]
        if location.course >= 0 { state["course"] = location.course }
        if location.speed >= 0 { state["speed"] = min(60, location.speed) }
        sequence += 1 // A lost reply must never lead to sequence reuse.
        do {
            let result = try await client.json("friend-sharing/state", method: "POST", body: state)
            guard expected == generation else { return }
            let accepted = Set(result["accepted"] as? [String] ?? [])
            for (id, epoch) in epochs where leases[id]?.epoch == epoch && !accepted.contains(id) { leases[id] = nil }
            updateSharing()
            lastPublished = location.timestamp
            error = nil
        } catch {
            guard expected == generation else { return }
            self.error = "Your last friend location update could not be shared."
        }
    }

    func stopAll() async {
        let ids = Set(leases.keys).union(busyIDs)
        // Fence pending starts before the first await; a sign-out must not let
        // an earlier permission request restart GPS while revocations run.
        reset()
        let expected = generation
        for id in ids {
            guard expected == generation else { return }
            let path = "friend-sharing/\(id)/consent"
            guard let current = try? await client.json(path), expected == generation,
                  let epoch = current["epoch"] as? String else { continue }
            _ = try? await client.json(path, method: "POST", body: ["epoch": epoch, "location": false, "stats": false])
        }
    }

    func forget(_ id: String) {
        leases[id] = nil; updateSharing()
        riders.removeAll { $0.id == id }
    }

    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        leases = [:]; sharingIDs = []; busyIDs = []; isSharing = false
        riders = []; latestLocation = nil; error = nil; lastPublished = nil
        progress = SharedRideProgress(); sequence = 0
    }
}
