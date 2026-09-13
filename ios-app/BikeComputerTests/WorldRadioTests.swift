import Foundation

private final class WorldRadioTestPlayer: WorldRadioAudioPlaying {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)?
    private(set) var played: [WorldRadioStation] = []
    private(set) var pauseCount = 0

    func play(_ station: WorldRadioStation) {
        played.append(station)
        eventHandler?(.playing)
    }

    func pause() {
        pauseCount += 1
        eventHandler?(.paused)
    }

    func resume() {
        eventHandler?(.playing)
    }

    func stop() {}
}

@MainActor
func runWorldRadioTests() async {
    var request = Data("WRQ1".utf8)
    request.append(contentsOf: [1, WorldRadioCommand.selectLocation.rawValue, 0, 0])
    request.append(contentsOf: [0x78, 0x56, 0x34, 0x12])
    request.append(contentsOf: [0x80, 0x61, 0x9D, 0x12])
    request.append(contentsOf: [0x68, 0x6A, 0x67, 0x48])
    let decoded = WorldRadioRequest(request)
    precondition(decoded?.requestID == 0x12345678)
    precondition(decoded?.latitudeE7 == 312_304_000)
    precondition(decoded?.longitudeE7 == 1_214_737_000)

    let station = WorldRadioStation(
        uuid: "12345678-1234-1234-1234-123456789abc",
        name: "Tokyo Community Radio",
        place: "Tokyo",
        countryCode: "JP",
        latitudeE7: 356_817_000,
        longitudeE7: 1_397_671_000,
        bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/live.mp3")!,
        clickCount: 100,
        distanceMeters: 2500
    )
    let status = WorldRadioStatus(
        state: .playing,
        stationIndex: 0,
        stationCount: 1,
        requestID: 0x12345678,
        station: station,
        message: "Playing on iPhone"
    )
    let encoded = status.encoded()
    precondition(encoded?.starts(with: Data("WRS1".utf8)) == true)
    precondition(encoded?.count ?? 0 <= WorldRadioStatus.maximumBytes)

    let directory = WorldRadioDirectoryClient(
        nearby: { _, _ in [station] },
        random: { [station] },
        recordClick: { _ in }
    )
    let player = WorldRadioTestPlayer()
    var statuses: [WorldRadioStatus] = []
    let service = WorldRadioService(
        directory: directory,
        player: player,
        statusSink: { statuses.append($0) }
    )
    guard let serviceRequest = decoded else {
        preconditionFailure("request did not decode")
    }
    service.handle(serviceRequest)
    for _ in 0..<20 {
        await Task.yield()
    }
    precondition(statuses.first?.state == .searching)
    precondition(statuses.last?.state == .playing)
    precondition(player.played == [station])

    service.handle(WorldRadioRequest.makeForTesting(
        command: .playPause,
        requestID: 0x12345679
    ))
    precondition(player.pauseCount == 1)

    let other = WorldRadioStation(
        uuid: "other", name: "Other station", place: "Berlin", countryCode: "DE",
        latitudeE7: 525_200_000, longitudeE7: 134_050_000, bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/other.mp3")!,
        clickCount: 1, distanceMeters: 3000
    )
    let randomPlayer = WorldRadioTestPlayer()
    let global = WorldRadioStation(
        uuid: "global", name: "中文电台", place: "Espan\u{0303}a", countryCode: "ES",
        latitudeE7: 404_000_000, longitudeE7: -37_000_000, bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/global.mp3")!,
        clickCount: 1, distanceMeters: nil
    )
    let globalStatus = WorldRadioStatus(state: .playing, stationIndex: 0,
        stationCount: 1, requestID: 1, station: global, message: "")
    let globalBytes = globalStatus.encoded()!
    let nameStart = WorldRadioStatus.headerBytes
    let placeStart = nameStart + Int(globalBytes[26])
    precondition(String(data: globalBytes[nameStart..<placeStart], encoding: .utf8) == "中文电台")
    precondition(Array(globalBytes[placeStart..<(placeStart + Int(globalBytes[27]))]) == Array("España".utf8))
    let randomService = WorldRadioService(
        directory: WorldRadioDirectoryClient(
            nearby: { _, _ in [station, other] },
            random: { [global] }, recordClick: { _ in }
        ),
        player: randomPlayer,
        chooseIndex: { $0 - 1 },
        statusSink: { _ in }
    )
    randomService.handle(serviceRequest)
    for _ in 0..<100 where randomPlayer.played.count < 1 { await Task.yield() }
    // Random selection is not pinned to the first ranked local result.
    precondition(randomPlayer.played == [other])
    randomService.handle(WorldRadioRequest.makeForTesting(command: .randomStation, requestID: 20))
    for _ in 0..<100 where randomPlayer.played.count < 2 { await Task.yield() }
    // Global is absent from the nearby list: this proves worldwide routing.
    precondition(randomPlayer.played == [other, global])
    randomService.handle(WorldRadioRequest.makeForTesting(command: .selectLocation, requestID: 21))
    for _ in 0..<100 where randomPlayer.played.count < 3 { await Task.yield() }
    precondition(randomPlayer.played == [other, global, other])
    // A failed random choice still falls back through the remaining candidates.
    randomPlayer.eventHandler?(.failed("unavailable"))
    precondition(randomPlayer.played.last == station)
    randomPlayer.eventHandler?(.failed("unavailable"))
    precondition(randomService.currentStatus?.state == .error)
}

@main
@MainActor
struct WorldRadioTestRunner {
    static func main() async {
        await runWorldRadioTests()
    }
}

private extension WorldRadioRequest {
    static func makeForTesting(
        command: WorldRadioCommand,
        requestID: UInt32
    ) -> WorldRadioRequest {
        var data = Data("WRQ1".utf8)
        data.append(contentsOf: [1, command.rawValue, 0, 0])
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: requestID),
            UInt8(truncatingIfNeeded: requestID >> 8),
            UInt8(truncatingIfNeeded: requestID >> 16),
            UInt8(truncatingIfNeeded: requestID >> 24),
        ])
        data.append(Data(repeating: 0, count: 8))
        return WorldRadioRequest(data)!
    }
}
