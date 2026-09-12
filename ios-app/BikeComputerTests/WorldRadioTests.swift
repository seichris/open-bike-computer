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
