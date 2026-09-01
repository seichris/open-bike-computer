import Foundation
#if canImport(AVFoundation) && !HOST_TESTING
import AVFoundation
#endif
#if canImport(MediaPlayer) && !HOST_TESTING
import MediaPlayer
#endif

nonisolated enum WorldRadioDirectoryError: Error, Equatable, Sendable {
    case invalidResponse
    case noStations
}

nonisolated struct WorldRadioDirectoryClient: Sendable {
    let nearby: @Sendable (_ latitude: Double, _ longitude: Double) async throws -> [WorldRadioStation]
    let random: @Sendable () async throws -> [WorldRadioStation]
    let recordClick: @Sendable (_ stationUUID: String) async -> Void

    static func live() -> Self {
        let directory = RadioBrowserDirectory()
        return Self(
            nearby: { latitude, longitude in
                try await directory.nearby(latitude: latitude, longitude: longitude)
            },
            random: {
                try await directory.randomStations()
            },
            recordClick: { uuid in
                await directory.recordClick(stationUUID: uuid)
            }
        )
    }
}

private nonisolated struct RadioBrowserStationDTO: Decodable, Sendable {
    let stationuuid: String
    let name: String
    let country: String
    let countrycode: String
    let state: String
    let codec: String
    let bitrate: Int
    let hls: Int
    let lastcheckok: Int
    let sslError: Int
    let url: String
    let urlResolved: String
    let geoLat: Double?
    let geoLong: Double?
    let geoDistance: Double?
    let clickcount: Int

    enum CodingKeys: String, CodingKey {
        case stationuuid
        case name
        case country
        case countrycode
        case state
        case codec
        case bitrate
        case hls
        case lastcheckok
        case sslError = "ssl_error"
        case url
        case urlResolved = "url_resolved"
        case geoLat = "geo_lat"
        case geoLong = "geo_long"
        case geoDistance = "geo_distance"
        case clickcount
    }

    var station: WorldRadioStation? {
        guard lastcheckok == 1,
              sslError == 0,
              let latitude = geoLat,
              let longitude = geoLong,
              latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        let candidate = urlResolved.isEmpty ? url : urlResolved
        guard let streamURL = URL(string: candidate),
              streamURL.scheme?.lowercased() == "https" else {
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !stationuuid.isEmpty else { return nil }
        let place = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPlace = country.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorldRadioStation(
            uuid: stationuuid,
            name: trimmedName,
            place: place.isEmpty ? fallbackPlace : place,
            countryCode: countrycode.uppercased(),
            latitudeE7: Int32((latitude * 10_000_000).rounded()),
            longitudeE7: Int32((longitude * 10_000_000).rounded()),
            bitrateKbps: UInt16(clamping: bitrate),
            streamURL: streamURL,
            clickCount: max(0, clickcount),
            distanceMeters: geoDistance
        )
    }
}

private actor RadioBrowserDirectory {
    private static let nearbyRadii = [75_000, 200_000, 500_000, 1_500_000]
    private static let userAgent =
        "Bicino/0.1 (World Radio; github.com/seichris/open-bike-computer)"

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://all.api.radio-browser.info")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func nearby(latitude: Double, longitude: Double) async throws -> [WorldRadioStation] {
        for radius in Self.nearbyRadii {
            let stations = try await search(queryItems: [
                URLQueryItem(name: "geo_lat", value: String(latitude)),
                URLQueryItem(name: "geo_long", value: String(longitude)),
                URLQueryItem(name: "geo_distance", value: String(radius)),
                URLQueryItem(name: "has_geo_info", value: "true"),
                URLQueryItem(name: "hidebroken", value: "true"),
                URLQueryItem(name: "order", value: "clickcount"),
                URLQueryItem(name: "reverse", value: "true"),
                URLQueryItem(name: "limit", value: "40"),
            ])
            if stations.count >= 3 || radius == Self.nearbyRadii.last {
                guard !stations.isEmpty else { throw WorldRadioDirectoryError.noStations }
                return stations
            }
        }
        throw WorldRadioDirectoryError.noStations
    }

    func randomStations() async throws -> [WorldRadioStation] {
        let stations = try await search(queryItems: [
            URLQueryItem(name: "has_geo_info", value: "true"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "random"),
            URLQueryItem(name: "limit", value: "40"),
        ])
        guard !stations.isEmpty else { throw WorldRadioDirectoryError.noStations }
        return stations
    }

    func recordClick(stationUUID: String) async {
        guard stationUUID.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...70).contains(byte) ||
                (97...102).contains(byte) || byte == 45
        }) else { return }
        let url = baseURL
            .appendingPathComponent("json")
            .appendingPathComponent("url")
            .appendingPathComponent(stationUUID)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
    }

    private func search(queryItems: [URLQueryItem]) async throws -> [WorldRadioStation] {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("json")
                .appendingPathComponent("stations")
                .appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw WorldRadioDirectoryError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WorldRadioDirectoryError.invalidResponse
        }
        let decoded = try JSONDecoder().decode([RadioBrowserStationDTO].self, from: data)
        var seen = Set<String>()
        let stations = decoded.compactMap(\.station).filter { station in
            seen.insert(station.uuid).inserted
        }
        return stations.sorted { lhs, rhs in
            let leftDistance = lhs.distanceMeters ?? .greatestFiniteMagnitude
            let rightDistance = rhs.distanceMeters ?? .greatestFiniteMagnitude
            if abs(leftDistance - rightDistance) > 1 {
                return leftDistance < rightDistance
            }
            if lhs.clickCount != rhs.clickCount {
                return lhs.clickCount > rhs.clickCount
            }
            let leftBitratePenalty = abs(Int(lhs.bitrateKbps) - 96)
            let rightBitratePenalty = abs(Int(rhs.bitrateKbps) - 96)
            return leftBitratePenalty < rightBitratePenalty
        }.prefix(12).map { $0 }
    }
}

@MainActor
protocol WorldRadioAudioPlaying: AnyObject {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)? { get set }
    func play(_ station: WorldRadioStation)
    func pause()
    func resume()
    func stop()
}

nonisolated enum WorldRadioAudioEvent: Equatable, Sendable {
    case connecting
    case buffering
    case playing
    case paused
    case failed(String)
}

@MainActor
private final class SilentWorldRadioPlayer: WorldRadioAudioPlaying {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)?

    func play(_ station: WorldRadioStation) {
        _ = station
        eventHandler?(.failed("Audio playback is unavailable"))
    }
    func pause() { eventHandler?(.paused) }
    func resume() { eventHandler?(.failed("Audio playback is unavailable")) }
    func stop() {}
}

#if canImport(AVFoundation) && !HOST_TESTING
@MainActor
private final class IPhoneWorldRadioPlayer: WorldRadioAudioPlaying {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)?

    private let player = AVPlayer()
    private var itemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentStation: WorldRadioStation?

    func play(_ station: WorldRadioStation) {
        currentStation = station
        itemObservation = nil
        timeControlObservation = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            eventHandler?(.failed("Could not start iPhone audio"))
            return
        }

        eventHandler?(.connecting)
        let item = AVPlayerItem(url: station.streamURL)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor [weak self, item] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.player.play()
                case .failed:
                    self.eventHandler?(.failed(
                        item.error?.localizedDescription ?? "Station could not be played"
                    ))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] player, _ in
            Task { @MainActor [weak self, player] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.updateNowPlaying(rate: 1)
                    self.eventHandler?(.playing)
                case .waitingToPlayAtSpecifiedRate:
                    self.updateNowPlaying(rate: 0)
                    self.eventHandler?(.buffering)
                case .paused:
                    self.updateNowPlaying(rate: 0)
                @unknown default:
                    break
                }
            }
        }
        player.play()
        updateNowPlaying(rate: 0)
    }

    func pause() {
        player.pause()
        updateNowPlaying(rate: 0)
        eventHandler?(.paused)
    }

    func resume() {
        guard player.currentItem != nil else {
            eventHandler?(.failed("Choose a station first"))
            return
        }
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        timeControlObservation = nil
        currentStation = nil
#if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func updateNowPlaying(rate: Double) {
#if canImport(MediaPlayer)
        guard let station = currentStation else { return }
        let subtitle = [station.place, station.countryCode]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: station.name,
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPMediaItemPropertyArtist: "Bicino World Radio",
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
#endif
    }
}
#endif

@MainActor
final class WorldRadioService {
    typealias StatusSink = (WorldRadioStatus) -> Void

    private let directory: WorldRadioDirectoryClient
    private let player: WorldRadioAudioPlaying
    private let statusSink: StatusSink
    private var requestTask: Task<Void, Never>?
    private var candidates: [WorldRadioStation] = []
    private var stationIndex = 0
    private var failedStationUUIDs = Set<String>()
    private var requestID: UInt32 = 0
    private(set) var currentStatus: WorldRadioStatus?

    init(
        directory: WorldRadioDirectoryClient = .live(),
        player: WorldRadioAudioPlaying? = nil,
        statusSink: @escaping StatusSink
    ) {
        self.directory = directory
#if canImport(AVFoundation) && !HOST_TESTING
        self.player = player ?? IPhoneWorldRadioPlayer()
#else
        self.player = player ?? SilentWorldRadioPlayer()
#endif
        self.statusSink = statusSink
        self.player.eventHandler = { [weak self] event in
            self?.handleAudioEvent(event)
        }
    }

    func handle(_ request: WorldRadioRequest) {
        requestID = request.requestID
        switch request.command {
        case .selectLocation:
            let latitude = Double(request.latitudeE7) / 10_000_000
            let longitude = Double(request.longitudeE7) / 10_000_000
            startSearch(requestID: request.requestID) { [directory] in
                try await directory.nearby(latitude, longitude)
            }
        case .randomStation:
            startSearch(requestID: request.requestID) { [directory] in
                try await directory.random()
            }
        case .playPause:
            guard !candidates.isEmpty else {
                emit(state: .noStations, message: "Choose a place first")
                return
            }
            if currentStatus?.state == .playing || currentStatus?.state == .buffering ||
                currentStatus?.state == .connecting {
                player.pause()
            } else if currentStatus?.state == .paused {
                player.resume()
            } else {
                playCurrent()
            }
        case .previousStation:
            moveStation(by: -1)
        case .nextStation:
            moveStation(by: 1)
        case .stop:
            requestTask?.cancel()
            player.stop()
            emit(state: .idle, message: "Stopped")
        }
    }

    /// Stop all radio work and release the feature's station/player state.
    /// The coordinator calls this when the World Radio screen is disabled;
    /// a temporary BLE disconnect deliberately does not call it so phone-side
    /// playback can continue.
    func stop() {
        requestTask?.cancel()
        requestTask = nil
        player.stop()
        candidates = []
        stationIndex = 0
        failedStationUUIDs = []
        requestID = 0
        currentStatus = nil
    }

    /// Re-send the last state without restarting discovery or playback after
    /// the authenticated BLE session comes back.
    func resendCurrentStatus() {
        guard let currentStatus else { return }
        statusSink(currentStatus)
    }

    private func startSearch(
        requestID: UInt32,
        operation: @escaping @Sendable () async throws -> [WorldRadioStation]
    ) {
        requestTask?.cancel()
        player.stop()
        candidates = []
        stationIndex = 0
        failedStationUUIDs = []
        emit(state: .searching, message: "Finding stations...")
        requestTask = Task { [weak self] in
            do {
                let stations = try await operation()
                guard !Task.isCancelled,
                      let self,
                      self.requestID == requestID else { return }
                self.candidates = stations
                self.stationIndex = 0
                self.failedStationUUIDs = []
                self.playCurrent()
            } catch is CancellationError {
                return
            } catch WorldRadioDirectoryError.noStations {
                guard let self, self.requestID == requestID else { return }
                self.emit(state: .noStations, message: "No playable stations nearby")
            } catch {
                guard let self, self.requestID == requestID else { return }
                self.emit(state: .error, message: "Radio directory unavailable")
            }
        }
    }

    private func moveStation(by offset: Int) {
        guard !candidates.isEmpty else {
            emit(state: .noStations, message: "Choose a place first")
            return
        }
        player.stop()
        stationIndex = (stationIndex + offset + candidates.count) % candidates.count
        failedStationUUIDs = []
        playCurrent()
    }

    private func playCurrent() {
        guard candidates.indices.contains(stationIndex) else {
            emit(state: .noStations, message: "No playable stations nearby")
            return
        }
        emit(state: .connecting, message: "Connecting...")
        player.play(candidates[stationIndex])
    }

    private func handleAudioEvent(_ event: WorldRadioAudioEvent) {
        switch event {
        case .connecting:
            emit(state: .connecting, message: "Connecting...")
        case .buffering:
            emit(state: .buffering, message: "Buffering...")
        case .playing:
            emit(state: .playing, message: "Playing on iPhone")
            if let station = currentStation {
                Task { [directory] in
                    await directory.recordClick(station.uuid)
                }
            }
        case .paused:
            emit(state: .paused, message: "Paused")
        case .failed:
            guard let station = currentStation else {
                emit(state: .error, message: "Station unavailable")
                return
            }
            failedStationUUIDs.insert(station.uuid)
            if failedStationUUIDs.count < candidates.count {
                repeat {
                    stationIndex = (stationIndex + 1) % candidates.count
                } while failedStationUUIDs.contains(candidates[stationIndex].uuid) &&
                    failedStationUUIDs.count < candidates.count
                playCurrent()
            } else {
                emit(state: .error, message: "No station could be played")
            }
        }
    }

    private var currentStation: WorldRadioStation? {
        candidates.indices.contains(stationIndex) ? candidates[stationIndex] : nil
    }

    private func emit(state: WorldRadioPlaybackState, message: String) {
        let status = WorldRadioStatus(
            state: state,
            stationIndex: stationIndex,
            stationCount: candidates.count,
            requestID: requestID,
            station: currentStation,
            message: message
        )
        currentStatus = status
        statusSink(status)
    }
}
