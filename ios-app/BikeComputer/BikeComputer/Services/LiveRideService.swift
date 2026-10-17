import Combine
import CoreLocation
import Foundation

@MainActor
final class LiveRideService: ObservableObject {
    @Published private(set) var ride: SocialGroupRide?
    @Published private(set) var invitationCode: String?
    @Published private(set) var riders: [SocialRider] = []
    @Published private(set) var isSharing = false
    @Published private(set) var error: String?
    @Published private(set) var messages: [SocialQuickMessage] = []
    var prepareLocation: (() -> Bool)?
    var onRidersChanged: (([SocialRider]) -> Void)?
    var onCapabilitiesChanged: ((SocialCapabilities) -> Void)?
    private let client: BicinoSocialClient
    private var stream: Task<Void, Never>?
    private var publisher: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private(set) var latestLocation: CLLocation?
    private var previousSharedLocation: CLLocation?
    private var sharedDistance = 0.0
    private var sharedMovingSeconds = 0.0
    private var sharingStartedAt = 0.0
    private var lastPublished: Date?
    private var sequence = 0
    private var localEpoch = UUID()

    init(client: BicinoSocialClient) { self.client = client }

    func updateLocation(_ location: CLLocation?) {
        latestLocation = location
        guard isSharing, let location, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else { return }
        if let previous = previousSharedLocation {
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
            guard seconds > 0 else { return }
            let meters = previous.distance(from: location)
            if seconds <= 30 && meters / seconds <= 60 {
                sharedDistance += meters
                if meters / seconds > 0.5 { sharedMovingSeconds += seconds }
            }
        }
        previousSharedLocation = location
    }

    func select(_ selected: SocialGroupRide) async throws {
        let previousEpoch = localEpoch
        let ride = try JSONDecoder().decode(SocialGroupRide.self,
            from: await client.request("group-rides/\(selected.id)"))
        guard previousEpoch == localEpoch else { return }
        await stopSharing()
        guard previousEpoch == localEpoch else { return }
        reset()
        self.ride = ride
        invitationCode = selected.joinCode
        // Reopening a server session never silently restarts this phone's GPS publication.
        isSharing = false
        let epoch = localEpoch
        stream = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && epoch == self.localEpoch {
                do {
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    let socket = try await self.client.socket(rideID: ride.id)
                    guard !Task.isCancelled, epoch == self.localEpoch else { return }
                    self.socket = socket
                    socket.resume()
                    while !Task.isCancelled && epoch == self.localEpoch {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw SocialFailure.invalidResponse
                        }
                        guard data.count < 4 * 1024 * 1024 else { throw SocialFailure.invalidResponse }
                        var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                        if document["route"] == nil, let route = self.ride?.route {
                            document["route"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))
                        }
                        let next = try JSONDecoder().decode(SocialGroupRide.self, from: JSONSerialization.data(withJSONObject: document))
                        guard epoch == self.localEpoch, next.id == ride.id else { break }
                        if let current = self.ride, next.serverTime < current.serverTime { continue }
                        if let capabilities = document["capabilities"] {
                            self.onCapabilitiesChanged?(try JSONDecoder().decode(SocialCapabilities.self,
                                from: JSONSerialization.data(withJSONObject: capabilities)))
                        }
                        self.ride = next
                        self.riders = next.riders.filter { $0.age(at: Date()) < 60 }
                        if !next.sharing { self.isSharing = false }
                        self.error = nil
                        self.onRidersChanged?(self.riders)
                        try? await self.refreshMessages()
                    }
                } catch {
                    guard !Task.isCancelled, epoch == self.localEpoch else { return }
                    self.riders = []
                    self.onRidersChanged?([])
                    self.error = "Live connection unavailable. Rider positions are hidden."
                    // Re-fetching checks membership; an explicit revoked/ended result
                    // clears the room, while transport loss can reconnect safely.
                    do {
                        _ = try await self.client.request("group-rides/\(ride.id)")
                    } catch SocialFailure.server(let code) {
                        if ["ride_ended", "membership_required", "not_found", "account_unavailable", "feature_unavailable"].contains(code) {
                            self.reset()
                            return
                        }
                    } catch { }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func startSharing(stats: Bool) async throws {
        guard prepareLocation?() == true else { throw SocialFailure.server("allow_precise_location_in_settings_then_start_sharing") }
        guard let ride else { throw SocialFailure.unavailable }
        let selectionEpoch = localEpoch
        let data = try await client.json("group-rides/\(ride.id)/consent", method: "POST",
                                         body: ["location": true, "stats": stats])
        let updated = try JSONDecoder().decode(SocialGroupRide.self,
            from: JSONSerialization.data(withJSONObject: data))
        guard selectionEpoch == localEpoch else { throw SocialFailure.cancelled }
        self.ride = updated
        previousSharedLocation = nil
        sharedDistance = 0; sharedMovingSeconds = 0
        sharingStartedAt = ProcessInfo.processInfo.systemUptime
        isSharing = true
        sequence = 0
        lastPublished = nil
        publisher?.cancel()
        let epoch = localEpoch
        publisher = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && epoch == self.localEpoch && self.isSharing {
                if let location = self.latestLocation,
                   location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
                   abs(location.timestamp.timeIntervalSinceNow) < 30,
                   location.timestamp != self.lastPublished {
                    var state: [String: Any] = ["latitude": location.coordinate.latitude,
                        "longitude": location.coordinate.longitude,
                        "horizontalAccuracy": location.horizontalAccuracy,
                        "capturedAt": location.timestamp.timeIntervalSince1970,
                        "sequence": self.sequence, "epoch": updated.epoch]
                    if location.course >= 0 { state["course"] = location.course }
                    if stats && location.speed >= 0 { state["speed"] = min(60, location.speed) }
                    if stats {
                        state["distanceMeters"] = self.sharedDistance
                        state["movingSeconds"] = self.sharedMovingSeconds
                        state["elapsedSeconds"] = max(0, ProcessInfo.processInfo.systemUptime-self.sharingStartedAt)
                    }
                    do {
                        _ = try await self.client.json("group-rides/\(ride.id)/state", method: "POST", body: state)
                        self.lastPublished = location.timestamp
                        self.sequence += 1
                    } catch {
                        self.error = "Your last location update could not be shared."
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopSharing() async {
        isSharing = false
        publisher?.cancel()
        publisher = nil
        guard let ride else { return }
        _ = try? await client.json("group-rides/\(ride.id)/consent", method: "POST",
                                   body: ["location": false, "stats": false])
    }

    func leave(end: Bool = false) async throws {
        guard let ride else { return }
        await stopSharing()
        reset()
        _ = try await client.json("group-rides/\(ride.id)/\(end ? "end" : "leave")", method: "POST")
    }

    func send(_ status: String) async throws {
        guard let ride else { return }
        _ = try await client.json("group-rides/\(ride.id)/messages", method: "POST", body: ["status": status])
        try await refreshMessages()
    }

    func refreshMessages() async throws {
        guard let ride else { return }
        messages = try JSONDecoder().decode(SocialPage<SocialQuickMessage>.self,
            from: await client.request("group-rides/\(ride.id)/messages")).items
    }

    func reset() {
        localEpoch = UUID()
        stream?.cancel(); stream = nil
        publisher?.cancel(); publisher = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        isSharing = false; ride = nil; riders = []; messages = []; invitationCode = nil
        onRidersChanged?([])
    }
}
