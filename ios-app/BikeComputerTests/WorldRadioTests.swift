import Foundation

private final class WorldRadioTestPlayer: WorldRadioAudioPlaying {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)?
    private(set) var played: [WorldRadioStation] = []
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    var automaticallyReady = true
    private var playbackSession = WorldRadioPlaybackSession()

    // These closures simulate KVO work already queued before pause/replacement.
    // The production adapter uses the same pure session gate on MainActor.
    func queuedReady() -> () -> Void {
        let generation = playbackSession.generation
        return { [weak self] in
            guard let self, self.playbackSession.shouldPlay(generation) else { return }
            self.eventHandler?(.playing)
        }
    }

    func queuedEvent(_ event: WorldRadioAudioEvent) -> () -> Void {
        let generation = playbackSession.generation
        return { [weak self] in
            guard let self,
                  self.playbackSession.accepts(event, generation: generation) else { return }
            self.eventHandler?(event)
        }
    }

    func play(_ station: WorldRadioStation) {
        _ = playbackSession.begin()
        played.append(station)
        eventHandler?(automaticallyReady ? .playing : .connecting)
    }

    func pause() {
        pauseCount += 1
        playbackSession.pause()
        eventHandler?(.paused)
    }

    func resume() {
        if playbackSession.resume() { eventHandler?(.playing) }
    }

    func stop() {
        stopCount += 1
        playbackSession.stop()
    }
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
        runWorldRadioGoldenTests()
        runWorldRadioPlaybackSessionTests()
        await runWorldRadioTests()
        await runWorldRadioLifecycleTests()
        print("World Radio protocol, playback lifecycle and reconnect tests passed")
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


@MainActor
private func runWorldRadioGoldenTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let text = try! String(contentsOf: root.appendingPathComponent("protocol/fixtures/world-radio-v1.txt"),
                           encoding: .utf8)
    var fixtures: [String: Data] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: " ")
        precondition(fields.count == 2)
        let hex = Array(fields[1])
        precondition(hex.count % 2 == 0)
        fixtures[String(fields[0])] = Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(hex[$0...($0 + 1)]), radix: 16)!
        })
    }
    precondition(fixtures.count == 20)
    for (name, data) in fixtures {
        if name.hasPrefix("request_") {
            precondition(WorldRadioRequest(data) != nil, name)
            let prefixed = Data([0xaa, 0xbb]) + data
            precondition(WorldRadioRequest(prefixed.dropFirst(2)) == WorldRadioRequest(data))
        } else if name.hasPrefix("invalid_request_") {
            precondition(WorldRadioRequest(data) == nil, name)
        }
    }
    let negative = WorldRadioRequest(fixtures["request_negative"]!)!
    precondition(negative.latitudeE7 == -338_688_000 && negative.longitudeE7 == -1_800_000_000)
    precondition(negative.requestID == UInt32.max)
    let limits = WorldRadioRequest(fixtures["request_limits"]!)!
    precondition(limits.latitudeE7 == 900_000_000 && limits.longitudeE7 == 1_800_000_000)

    for name in ["status_tokyo", "status_negative", "status_bounded"] {
        let bounded = name == "status_bounded"
        let negative = name == "status_negative"
        let station = WorldRadioStation(
            uuid: "fixture", name: bounded ? String(repeating: "电", count: 17) :
                (negative ? "Radio" : "Tokyo Community Radio"),
            place: bounded ? String(repeating: "e\u{0301}", count: 15) :
                (negative ? "Espan\u{0303}a" : "Tokyo"),
            countryCode: negative ? "ES" : "JP",
            latitudeE7: negative ? -338_688_000 : 356_817_000,
            longitudeE7: negative ? -1_800_000_000 : 1_397_671_000,
            bitrateKbps: 96, streamURL: URL(string: "https://example.com/live")!,
            clickCount: 0, distanceMeters: nil
        )
        let status = WorldRadioStatus(state: .playing, stationIndex: 0, stationCount: 1,
            requestID: negative ? UInt32.max : 0x12345678, station: station,
            message: bounded ? String(repeating: "台", count: 9) :
                (negative ? "Playing" : "Playing on iPhone"))
        precondition(status.encoded() == fixtures[name], name)
    }
    // Shared helpers operate on unaligned, nonzero-based Data slices as well.
    var slice = Data([0, 0, 0, 0, 0, 0, 0, 0]).dropFirst(1)
    slice.writeWireUInt32LE(0x80000001, at: 1)
    slice.writeWireUInt16LE(0xabcd, at: 5)
    precondition(slice.wireUInt32LE(at: 1) == 0x80000001)
    precondition(slice.wireUInt16LE(at: 5) == 0xabcd)
    var appended = Data()
    appended.appendWireUInt16LE(0xabcd)
    appended.appendWireUInt32LE(UInt32.max)
    precondition(appended == Data([0xcd, 0xab, 0xff, 0xff, 0xff, 0xff]))
    precondition(RideBLEScreenTypeV1.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])
    for screen in RideBLELegacyScreenV1.allCases {
        precondition(screen.rawValue == Int(screen.wireType.rawValue))
    }
}

private func runWorldRadioPlaybackSessionTests() {
    var session = WorldRadioPlaybackSession()
    precondition(!session.resume())
    let first = session.begin()
    precondition(session.shouldPlay(first))
    session.pause()
    precondition(session.isCurrent(first) && !session.shouldPlay(first))
    precondition(!session.accepts(.failed("old"), generation: first))
    precondition(!session.accepts(.playing, generation: first))
    precondition(session.resume() && session.shouldPlay(first))
    let second = session.begin()
    precondition(second != first)
    precondition(!session.isCurrent(first) && !session.accepts(.failed("old"), generation: first))
    session.stop()
    precondition(!session.shouldPlay(second) && !session.accepts(.buffering, generation: second))
}

private actor PendingWorldRadioDirectory {
    private(set) var requestCount = 0
    private var pending: [Int: CheckedContinuation<[WorldRadioStation], Error>] = [:]

    func search() async throws -> [WorldRadioStation] {
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            pending[requestCount] = continuation
        }
    }

    func complete(_ request: Int, with result: Result<[WorldRadioStation], Error>) {
        guard let continuation = pending.removeValue(forKey: request) else {
            preconditionFailure("missing pending directory request")
        }
        continuation.resume(with: result)
    }
}

@MainActor
private func eventually(_ condition: @escaping @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        precondition(ContinuousClock.now < deadline, "radio state did not settle")
        try! await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func runWorldRadioLifecycleTests() async {
    let station = WorldRadioStation(uuid: "one", name: "One", place: "Place", countryCode: "JP",
        latitudeE7: 0, longitudeE7: 0, bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/live")!, clickCount: 0, distanceMeters: nil)
    let other = WorldRadioStation(uuid: "two", name: "Two", place: "Place", countryCode: "JP",
        latitudeE7: 0, longitudeE7: 0, bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/other")!, clickCount: 0, distanceMeters: nil)
    let directory = PendingWorldRadioDirectory()
    let player = WorldRadioTestPlayer()
    player.automaticallyReady = false
    var statuses: [WorldRadioStatus] = []
    let service = WorldRadioService(directory: .init(
        nearby: { _, _ in try await directory.search() },
        random: { try await directory.search() }, recordClick: { _ in }),
        player: player, chooseIndex: { _ in 0 }, statusSink: { statuses.append($0) })

    service.handle(.makeForTesting(command: .randomStation, requestID: 1))
    await eventually { await directory.requestCount == 1 }
    // A new command ID must not invalidate the in-progress discovery operation.
    service.handle(.makeForTesting(command: .playPause, requestID: 2))
    await directory.complete(1, with: .success([station]))
    await eventually { service.currentStatus?.station != nil }
    precondition(service.currentStatus?.state == .paused && player.played.isEmpty)
    precondition(service.currentStatus?.requestID == 2)
    service.handle(.makeForTesting(command: .playPause, requestID: 3))
    precondition(player.played == [station] && service.currentStatus?.state == .connecting)
    let ready = player.queuedReady()
    service.handle(.makeForTesting(command: .playPause, requestID: 4))
    ready() // Readiness after Pause must not restart audio.
    precondition(service.currentStatus?.state == .paused)
    service.handle(.makeForTesting(command: .playPause, requestID: 5))
    precondition(service.currentStatus?.state == .playing && service.currentStatus?.requestID == 5)
    let staleFailure = player.queuedEvent(.failed("previous item failed"))
    let staleBuffering = player.queuedEvent(.buffering)
    service.handle(.makeForTesting(command: .randomStation, requestID: 6))
    await eventually { await directory.requestCount == 2 }
    await directory.complete(2, with: .success([other, station]))
    await eventually { player.played.count == 2 }
    staleFailure()
    staleBuffering()
    precondition(player.played == [station, other])
    precondition(service.currentStatus?.state == .connecting && service.currentStatus?.station == other)
    player.queuedReady()()
    // BLE disconnect does not call stop; replay the existing snapshot on reconnect.
    let beforeReconnect = service.currentStatus
    let stopCount = player.stopCount
    let statusCount = statuses.count
    service.resendCurrentStatus()
    precondition(statuses.count == statusCount + 1 && statuses.last == beforeReconnect)
    precondition(player.played == [station, other] && player.stopCount == stopCount)

    let queuedAfterStop = player.queuedReady()
    service.handle(.makeForTesting(command: .stop, requestID: 7))
    let stoppedCount = statuses.count
    queuedAfterStop()
    staleFailure()
    precondition(statuses.count == stoppedCount && service.currentStatus?.state == .idle)

    service.handle(.makeForTesting(command: .randomStation, requestID: 8))
    await eventually { await directory.requestCount == 3 }
    service.handle(.makeForTesting(command: .randomStation, requestID: 9))
    await eventually { await directory.requestCount == 4 }
    // An old generic directory error must not overwrite a newer search.
    await directory.complete(3, with: .failure(WorldRadioDirectoryError.invalidResponse))
    await directory.complete(4, with: .success([station]))
    await eventually { player.played.count == 3 }
    precondition(service.currentStatus?.requestID == 9 && service.currentStatus?.state == .connecting)

    service.handle(.makeForTesting(command: .randomStation, requestID: 10))
    await eventually { await directory.requestCount == 5 }
    service.stop() // Feature disabled while a directory request is suspended.
    let disabledCount = statuses.count
    await directory.complete(5, with: .success([other]))
    // Yield to the resumed cancelled task, then prove disablement remains terminal.
    for _ in 0..<100 { await Task.yield() }
    service.resendCurrentStatus()
    player.eventHandler?(.playing)
    precondition(statuses.count == disabledCount && service.currentStatus == nil)
    precondition(player.played.count == 3)
}
