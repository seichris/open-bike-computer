import Combine
import CoreLocation
import Foundation

/// Route-independent, one-way friend sharing. This installation remembers explicit
/// consents and revalidates their epochs and original deadlines before resuming.
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
    private let store: any SocialSecureStore
    private var owner: String?
    private var persisted: Data?
    private struct RememberedConsent: Codable, Equatable {
        let epoch: String
        let expiresAt: Double
    }
    private struct RememberedSharing: Codable {
        let consents: [String: RememberedConsent]
        let nextSequence: Int
    }
    private var remembered: [String: RememberedConsent] = [:]
    private var reservedSequence = 0
    private var persistenceKey: String? { owner.map { "friend-sharing.v1.\(SocialSecret.digest($0))" } }
    private let uptime: () -> TimeInterval
    private let pollNanoseconds: UInt64
    private let idlePollNanoseconds: UInt64
    private let sleep: (UInt64) async throws -> Void
    private var applicationActive = true
    private var enabled = false
    private var pollingGeneration = UUID()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var leases: [String: (epoch: String, deadline: Double)] = [:]
    private var latestLocation: CLLocation?
    private var progress = SharedRideProgress()
    private var startedAt = 0.0
    private var sequence = 0
    private var lastPublished: Date?
    /// Monotonic start/end of the latest publication attempt. The server rejects a
    /// whole batch when any recipient received a fix less than two seconds earlier.
    private var lastPublicationAttempt: TimeInterval?
    static let minimumPublicationInterval: TimeInterval = 2.2

    init(client: any SocialRideNetworking,
         store: any SocialSecureStore = SocialMemoryStore(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pollNanoseconds: UInt64 = 3_000_000_000,
         idlePollNanoseconds: UInt64 = 60_000_000_000,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.client = client; self.store = store; self.uptime = uptime; self.pollNanoseconds = pollNanoseconds
        self.idlePollNanoseconds = idlePollNanoseconds; self.sleep = sleep
    }

    func updateLocation(_ location: CLLocation?) {
        latestLocation = location
        guard isSharing, let location, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else { return }
        progress.add(location)
    }

    func start(owner: String? = nil) {
        if self.owner != owner {
            reset()
            self.owner = owner
            do {
                if let key = persistenceKey, let data = try store.read(key) {
                    let value = try JSONDecoder().decode(RememberedSharing.self, from: data)
                    guard value.consents.count <= 100, value.nextSequence >= 0,
                          value.nextSequence < 9_007_199_254_740_928,
                          value.consents.allSatisfy({ !$0.key.isEmpty && !$0.value.epoch.isEmpty && $0.value.expiresAt.isFinite }) else {
                        throw SocialFailure.invalidResponse
                    }
                    remembered = value.consents
                    persisted = data
                    // Previously reserved numbers may have reached the server even
                    // if this process never received their replies.
                    sequence = value.nextSequence; reservedSequence = sequence
                }
            } catch {
                self.error = "Your previous friend sharing could not be restored. Turn sharing on again."
            }
        }
        enabled = true
        guard task == nil else { return }
        resumePolling()
    }

    /// No idle network traffic while backgrounded; active streams stay timely.
    var nextPollNanoseconds: UInt64? {
        if isSharing || (applicationActive && !remembered.isEmpty) || riders.contains(where: { $0.age(at: Date()) < 60 }) { return pollNanoseconds }
        return applicationActive ? idlePollNanoseconds : nil
    }

    func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        if enabled { resumePolling() }
    }

    private func resumePolling() {
        pollingGeneration = UUID(); task?.cancel(); task = nil
        guard enabled, nextPollNanoseconds != nil else { return }
        let expected = generation
        let polling = pollingGeneration
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, expected == self.generation {
                await self.tick()
                guard !Task.isCancelled, let delay = self.nextPollNanoseconds else { break }
                do { try await self.sleep(delay) } catch { break }
            }
            if polling == self.pollingGeneration { self.task = nil }
        }
    }

    func setSharing(_ enabled: Bool, with id: String) async throws {
        guard !busyIDs.contains(id) else { return }
        let expected = generation
        busyIDs.insert(id)
        defer { if expected == generation { busyIDs.remove(id) } }
        var persistenceError: Error?
        if enabled {
            guard await prepareLocation?() == true else { throw SocialFailure.server("location_access_required") }
            guard expected == generation else { throw SocialFailure.cancelled }
        } else {
            // Stop GPS publication before any network await, including offline revocation.
            leases[id] = nil; remembered[id] = nil; updateSharing()
            // A crash or offline stop must not restore this recipient on launch.
            do { try persist() } catch { persistenceError = error }
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
                progress = SharedRideProgress(); startedAt = uptime()
            }
            remembered[id] = RememberedConsent(epoch: consent.epoch, expiresAt: expiry)
            do { try persist() }
            catch { remembered[id] = nil; leases[id] = nil; updateSharing(); throw error }
            leases[id] = (consent.epoch, requestedAt + min(4*3600, max(0, expiry-consent.serverTime)))
            lastPublished = nil
        }
        error = nil
        updateSharing()
        self.enabled = true
        resumePolling()
        if let persistenceError { throw persistenceError }
    }

    private func persist() throws {
        guard let key = persistenceKey else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = remembered.isEmpty ? nil : try encoder.encode(
            RememberedSharing(consents: remembered, nextSequence: reservedSequence))
        guard data != persisted else { return }
        try store.write(data, for: key)
        persisted = data
    }

    private func persistRemoval() {
        do { try persist() }
        catch { self.error = "Your sharing change could not be saved on this iPhone." }
    }

    private func updateSharing() {
        let ids = Set(leases.keys)
        if sharingIDs != ids { sharingIDs = ids }
        if isSharing != !leases.isEmpty { isSharing = !leases.isEmpty }
    }

    private func updateRiders(_ values: [SocialRider]) {
        guard riders.count != values.count || !zip(riders, values).allSatisfy({ $0.displaysSameState(as: $1) }) else { return }
        riders = values
        onRidersChanged?(values)
    }

    /// Also used by portable runtime tests; all response application is fenced
    /// against account changes and consent changes made while a poll was in flight.
    func tick() async {
        let expected = generation
        for (id, lease) in leases where lease.deadline <= uptime() { remembered[id] = nil }
        leases = leases.filter { $0.value.deadline > uptime() }
        persistRemoval()
        updateSharing()
        let requestedEpochs = leases.mapValues(\.epoch)
        let requestedConsents = remembered
        let requestedAt = uptime()
        do {
            let data = try await client.request("friend-sharing", method: "GET", body: nil, contentType: "application/json", query: [])
            guard expected == generation, !Task.isCancelled else { return }
            let snapshot = try JSONDecoder().decode(SocialFriendSnapshot.self, from: data)
            let remote = Dictionary(uniqueKeysWithValues: snapshot.outgoing.map { ($0.profileID, $0.epoch) })
            for (id, epoch) in requestedEpochs where leases[id]?.epoch == epoch && remote[id] != epoch {
                leases[id] = nil
            }
            for (id, consent) in requestedConsents where remembered[id] == consent && remote[id] != consent.epoch {
                remembered[id] = nil
            }
            persistRemoval()
            updateSharing()
            updateRiders(snapshot.riders.filter { $0.age(at: Date()) < 60 })
            let candidates = snapshot.outgoing.filter {
                requestedConsents[$0.profileID] == remembered[$0.profileID] && remembered[$0.profileID]?.epoch == $0.epoch
                    && leases[$0.profileID] == nil && !busyIDs.contains($0.profileID)
            }
            // Never cold-start a When-In-Use stream from a background launch.
            if applicationActive, !candidates.isEmpty, await prepareLocation?() == true {
                guard expected == generation, !Task.isCancelled, applicationActive else { return }
                for consent in candidates {
                    let id = consent.profileID
                    guard !busyIDs.contains(id), remembered[id] == requestedConsents[id],
                          leases[id] == nil, let saved = remembered[id], let expiry = consent.sharingExpiresAt else { continue }
                    let remaining = min(4*3600, min(saved.expiresAt, expiry)-snapshot.serverTime)
                    let deadline = requestedAt + remaining
                    guard deadline > uptime() else { remembered[id] = nil; continue }
                    if leases.isEmpty { progress = SharedRideProgress(); startedAt = uptime() }
                    leases[id] = (saved.epoch, deadline)
                }
                persistRemoval()
                updateSharing()
            }
        } catch {
            guard expected == generation, !Task.isCancelled else { return }
            updateRiders(riders.filter { $0.age(at: Date()) < 60 })
            if case SocialFailure.server(let code) = error,
               ["feature_unavailable", "account_unavailable", "account_deleting"].contains(code) {
                reset(); return
            }
        }
        guard expected == generation, !Task.isCancelled, !leases.isEmpty, let location = latestLocation,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
              abs(location.timestamp.timeIntervalSinceNow) < 30,
              location.timestamp != lastPublished else { return }
        // An immediate foreground or consent wake waits for the next poll instead
        // of tripping the server's per-recipient publication rate.
        if let lastPublicationAttempt, uptime() - lastPublicationAttempt < Self.minimumPublicationInterval { return }
        lastPublicationAttempt = uptime()
        let epochs = leases.mapValues(\.epoch)
        var state: [String: Any] = ["epochs": epochs, "sequence": sequence,
            "latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
            "capturedAt": location.timestamp.timeIntervalSince1970,
            "horizontalAccuracy": location.horizontalAccuracy,
            "distanceMeters": progress.distanceMeters, "movingSeconds": progress.movingSeconds,
            "elapsedSeconds": max(0, uptime()-startedAt)]
        if location.course >= 0 { state["course"] = location.course }
        if location.speed >= 0 { state["speed"] = min(60, location.speed) }
        // Reserve a small block durably before sending any number from it. This
        // avoids replaying sequences after a force-close without writing GPS fixes
        // or repeatedly updating the Keychain on every location publication.
        if sequence >= reservedSequence {
            guard sequence < 9_007_199_254_740_928 else { return }
            reservedSequence = sequence + 64
            do { try persist() }
            catch { reservedSequence = sequence; self.error = "Your friend location update could not be saved for sharing."; return }
        }
        sequence += 1 // A lost reply must never lead to sequence reuse.
        do {
            let result = try await client.json("friend-sharing/state", method: "POST", body: state)
            guard expected == generation else { return }
            // The server committed before replying, so the interval restarts here.
            lastPublicationAttempt = uptime()
            lastPublished = location.timestamp
            // A poll superseded by a wake or consent change leaves the audience to its successor.
            guard !Task.isCancelled else { return }
            let accepted = Set(result["accepted"] as? [String] ?? [])
            for (id, epoch) in epochs where leases[id]?.epoch == epoch && !accepted.contains(id) {
                leases[id] = nil; remembered[id] = nil
            }
            persistRemoval()
            updateSharing()
            if error != nil { error = nil }
        } catch {
            guard expected == generation else { return }
            // A cancelled or lost request may still have been committed.
            lastPublicationAttempt = uptime()
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            // A fresher fix from this phone was just accepted; nothing was lost.
            if case SocialFailure.server(let code) = error, code == "publish_rate" { return }
            self.error = "Your last friend location update could not be shared."
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func stopAll() async {
        let hadConsent = !remembered.isEmpty || !leases.isEmpty || !busyIDs.isEmpty
        // Fence pending starts before the first await. One batched revocation
        // keeps sign-out bounded even when many friends were selected.
        reset()
        if hadConsent { _ = try? await client.json("friend-sharing", method: "DELETE") }
    }

    func forget(_ id: String) {
        leases[id] = nil; remembered[id] = nil; persistRemoval(); updateSharing()
        riders.removeAll { $0.id == id }
    }

    func reset() {
        remembered = [:]; persistRemoval(); owner = nil; persisted = nil
        generation = UUID(); task?.cancel(); task = nil
        enabled = false; pollingGeneration = UUID()
        leases = [:]; sharingIDs = []; busyIDs = []; isSharing = false
        riders = []; latestLocation = nil; error = nil; lastPublished = nil
        lastPublicationAttempt = nil
        progress = SharedRideProgress(); sequence = 0; reservedSequence = 0
    }
}
