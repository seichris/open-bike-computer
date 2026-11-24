import Foundation
import MapKit

/// Bike Lanes tile caching and zoom range. Run from MapAppearanceTests.
@MainActor
enum BikeLanesTileCacheTests {
    static func run() {
        testMemoryCacheHitMissAndRecency()
        testMemoryCacheByteAndCountBounds()
        testCacheableResponses()
        testStoreServesRepeatTilesFromMemory()
        testStoreNeverCachesFailures()
        testStoreCoalescesConcurrentLoads()
        testStoreServesExpiredTileOnlyWhenTheNetworkFails()
        testStorePurgesACachedFailure()
        testSessionKeepsOnlyImageTilesOnDisk()
        testSessionFallsBackToAnExpiredTileOnDisk()
        testZoomThreshold()
        testOverlayAndRendererFollowTheZoom()
    }

    // MARK: Memory cache

    private static func testMemoryCacheHitMissAndRecency() {
        let cache = BikeLanesTileMemoryCache(byteLimit: 30, countLimit: 10)
        precondition(cache.data(for: "a") == nil, "an empty cache misses")
        cache.insert(bytes(10, 1), for: "a")
        cache.insert(bytes(10, 2), for: "b")
        cache.insert(bytes(10, 3), for: "c")
        precondition(cache.data(for: "a") == bytes(10, 1), "a stored tile is a hit")
        // "a" is now the most recent, so "b" is the oldest and goes first.
        cache.insert(bytes(10, 4), for: "d")
        precondition(cache.data(for: "b") == nil, "the least recently used tile is evicted")
        precondition(cache.data(for: "a") != nil && cache.data(for: "c") != nil && cache.data(for: "d") != nil)
        cache.insert(bytes(5, 9), for: "a")
        precondition(cache.data(for: "a") == bytes(5, 9) && cache.totalBytes == 25, "replacing a tile updates its size")
        cache.removeAll()
        precondition(cache.count == 0 && cache.totalBytes == 0 && cache.data(for: "c") == nil)
    }

    private static func testMemoryCacheByteAndCountBounds() {
        let bytesBound = BikeLanesTileMemoryCache(byteLimit: 100, countLimit: 1_000)
        for index in 0..<50 {
            bytesBound.insert(bytes(7 + index % 5, UInt8(index)), for: "tile-\(index)")
            precondition(bytesBound.totalBytes <= 100, "the byte limit is never exceeded")
        }
        precondition(bytesBound.data(for: "tile-49") != nil, "the newest tile survives eviction")
        precondition(bytesBound.data(for: "tile-0") == nil, "the oldest tile was evicted")
        bytesBound.insert(bytes(101, 1), for: "huge")
        precondition(bytesBound.data(for: "huge") == nil && bytesBound.data(for: "tile-49") != nil,
                     "a tile larger than the budget is skipped without flushing the cache")
        bytesBound.insert(Data(), for: "empty")
        precondition(bytesBound.data(for: "empty") == nil, "an empty tile is not kept")

        let countBound = BikeLanesTileMemoryCache(byteLimit: 1_000_000, countLimit: 3)
        for index in 0..<10 { countBound.insert(bytes(1, UInt8(index)), for: "\(index)") }
        precondition(countBound.count == 3 && countBound.totalBytes == 3, "the entry limit is never exceeded")
        precondition(["7", "8", "9"].allSatisfy { countBound.data(for: $0) != nil })

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BikeLanesTileCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = BikeLanesTileStore(diskDirectory: directory)
        precondition(store.memory.byteLimit == 12 * 1024 * 1024 && store.memory.countLimit == 1024)
        precondition(store.urlCache?.diskCapacity == 64 * 1024 * 1024 && store.urlCache?.memoryCapacity == 0,
                     "the app keeps tiles in a bounded disk cache, and memory only in its own LRU")
    }

    // MARK: Store

    private static func testCacheableResponses() {
        let png = bytes(8, 1)
        precondition(BikeLanesTileStore.isCacheableTile(http(200), data: png))
        precondition(BikeLanesTileStore.isCacheableTile(http(200, type: "image/webp"), data: png))
        precondition(!BikeLanesTileStore.isCacheableTile(http(200), data: Data()), "empty body")
        precondition(!BikeLanesTileStore.isCacheableTile(http(200), data: nil), "no body")
        precondition(!BikeLanesTileStore.isCacheableTile(http(200, type: "text/html"), data: png), "captive portal page")
        for status in [204, 206, 304, 403, 404, 429, 500, 503] {
            precondition(!BikeLanesTileStore.isCacheableTile(http(status), data: png), "status \(status)")
        }
        let octetStream = "application/octet-stream"
        precondition(BikeLanesTileStore.isCacheableTile(http(200, type: octetStream), data: pngBytes),
                     "a PNG from object storage without a content type")
        precondition(BikeLanesTileStore.isCacheableTile(http(200, type: octetStream), data: jpegBytes))
        precondition(BikeLanesTileStore.isCacheableTile(http(200, type: octetStream), data: webpBytes))
        precondition(!BikeLanesTileStore.isCacheableTile(http(200, type: octetStream), data: png), "unknown bytes")
        precondition(!BikeLanesTileStore.isCacheableTile(http(200, type: "text/html"), data: Data("<html>".utf8)))
        precondition(!BikeLanesTileStore.isCacheableTile(http(404, type: octetStream), data: pngBytes),
                     "an image body does not rescue an error status")
        let nonHTTP = URLResponse(url: tileURL, mimeType: "image/png", expectedContentLength: 8, textEncodingName: nil)
        precondition(!BikeLanesTileStore.isCacheableTile(nonHTTP, data: png), "not an HTTP answer")
        let request = BikeLanesTileStore.request(for: tileURL)
        precondition(request.cachePolicy == .useProtocolCachePolicy && !request.httpShouldHandleCookies,
                     "tile requests follow the server's cache headers and send no cookies")
    }

    private static func testStoreServesRepeatTilesFromMemory() {
        let network = FakeTransport { _ in .init(data: bytes(16, 1), response: http(200)) }
        let store = BikeLanesTileStore(memory: memory(), urlCache: nil, transport: network.transport)
        let first = load(store, tileURL)
        precondition(try! first.result.get() == bytes(16, 1) && first.source == .network)
        let second = load(store, tileURL)
        precondition(try! second.result.get() == bytes(16, 1) && second.source == .memory,
                     "a tile seen before comes from memory")
        precondition(network.requests.count == 1, "the repeat load makes no request")
        _ = load(store, otherTileURL)
        precondition(network.requests.count == 2, "another tile is a miss")

        let overlayNetwork = FakeTransport { _ in .init(data: bytes(4, 2), response: http(200)) }
        let overlay = BikeLanesTileOverlay(
            urlTemplate: "https://tiles.example.test/lanes/{z}/{x}/{y}.png",
            store: BikeLanesTileStore(memory: memory(), urlCache: nil, transport: overlayNetwork.transport))
        let path = MKTileOverlayPath(x: 4206, y: 2692, z: 13, contentScaleFactor: 3)
        var delivered: Data?
        overlay.loadTile(at: path) { data, _ in delivered = data }
        overlay.loadTile(at: path) { data, _ in delivered = data }
        precondition(delivered == bytes(4, 2) && overlayNetwork.requests.count == 1)
        precondition(overlayNetwork.requests[0].url?.absoluteString == "https://tiles.example.test/lanes/13/4206/2692.png")
    }

    private static func testStoreNeverCachesFailures() {
        var answer = BikeLanesTileStore.TransportResult(data: bytes(9, 1), response: http(404))
        let network = FakeTransport { _ in answer }
        let store = BikeLanesTileStore(memory: memory(), urlCache: nil, transport: network.transport)
        let missing = load(store, tileURL)
        guard case .failure(BikeLanesTileError.unusableResponse(status: 404)) = missing.result else {
            preconditionFailure("a 404 fails the tile")
        }
        precondition(missing.source == nil && store.memory.count == 0, "a 404 is not cached")
        answer = .init(data: bytes(9, 1), response: http(200, type: "text/html"))
        guard case .failure = load(store, tileURL).result else { preconditionFailure("an HTML page fails the tile") }
        answer = .init(error: URLError(.timedOut))
        guard case .failure(let error) = load(store, tileURL).result, (error as? URLError)?.code == .timedOut else {
            preconditionFailure("a transport error reaches MapKit")
        }
        precondition(store.memory.count == 0 && network.requests.count == 3, "every failure is retried")
        answer = .init(data: bytes(9, 2), response: http(200))
        precondition(try! load(store, tileURL).result.get() == bytes(9, 2) && store.memory.count == 1,
                     "the tile is cached once it loads")
    }

    private static func testStoreCoalescesConcurrentLoads() {
        let network = FakeTransport(reply: nil)
        let store = BikeLanesTileStore(memory: memory(), urlCache: nil, transport: network.transport)
        let results = DataListBox()
        for _ in 0..<3 {
            store.loadTile(at: tileURL) { result, _ in
                if case .success(let data) = result { results.values.append(data) }
            }
        }
        precondition(network.requests.count == 1, "one request serves every waiting load")
        network.complete(.init(data: bytes(3, 7), response: http(200)))
        precondition(results.values == [bytes(3, 7), bytes(3, 7), bytes(3, 7)], "every waiting load gets the tile")
        _ = load(store, tileURL)
        precondition(network.requests.count == 1)
    }

    private static func testStoreServesExpiredTileOnlyWhenTheNetworkFails() {
        let urlCache = temporaryURLCache()
        let request = BikeLanesTileStore.request(for: tileURL)
        urlCache.storeCachedResponse(CachedURLResponse(response: http(200), data: bytes(12, 5)), for: request)
        var answer = BikeLanesTileStore.TransportResult(error: URLError(.notConnectedToInternet))
        let network = FakeTransport { _ in answer }
        let store = BikeLanesTileStore(memory: memory(), urlCache: urlCache, transport: network.transport)
        let offline = load(store, tileURL)
        precondition(try! offline.result.get() == bytes(12, 5) && offline.source == .stale,
                     "an expired tile shows while offline")
        precondition(store.memory.count == 0, "an expired tile stays out of memory so the next load retries")
        answer = .init(data: Data("busy".utf8), response: http(503, type: "text/plain"))
        precondition(load(store, tileURL).source == .stale, "a server error also falls back")
        answer = .init(data: Data("gone".utf8), response: http(404, type: "text/plain"))
        guard case .failure = load(store, tileURL).result else { preconditionFailure("a 404 is an answer, not an outage") }
        precondition(network.requests.count == 3)
    }

    private static func testStorePurgesACachedFailure() {
        let urlCache = temporaryURLCache()
        let request = BikeLanesTileStore.request(for: tileURL)
        urlCache.storeCachedResponse(CachedURLResponse(response: http(404), data: bytes(5, 1)), for: request)
        precondition(urlCache.cachedResponse(for: request) != nil)
        let network = FakeTransport { _ in .init(data: bytes(5, 1), response: http(404)) }
        let store = BikeLanesTileStore(memory: memory(), urlCache: urlCache, transport: network.transport)
        guard case .failure = load(store, tileURL).result else { preconditionFailure("the tile is missing") }
        precondition(urlCache.cachedResponse(for: request) == nil, "a failure found on disk is removed")
    }

    /// The real session, answered by a stub protocol: only a 200 image may
    /// reach the disk cache, and the store then serves it from memory.
    private static func testSessionKeepsOnlyImageTilesOnDisk() {
        let urlCache = temporaryURLCache()
        let session = BikeLanesTileSession(urlCache: urlCache, protocolClasses: [BikeLanesStubProtocol.self])
        defer { session.invalidate() }
        let cases: [(path: String, status: Int, type: String, body: Data, kept: Bool)] = [
            ("ok", 200, "image/png", bytes(20, 1), true),
            ("missing", 404, "image/png", bytes(20, 2), false),
            ("throttled", 429, "image/png", bytes(20, 3), false),
            ("portal", 200, "text/html", Data("<html>".utf8), false),
            ("untyped", 200, "application/octet-stream", pngBytes, true),
            ("untyped-page", 200, "application/octet-stream", Data("<html>".utf8), false),
            ("blank", 200, "image/png", Data(), false),
        ]
        for item in cases {
            let url = URL(string: "https://tiles.example.test/\(item.path).png")!
            BikeLanesStubProtocol.set(url, status: item.status, type: item.type, body: item.body)
            let result = waitForLoad(session, BikeLanesTileStore.request(for: url))
            precondition((result.response as? HTTPURLResponse)?.statusCode == item.status && result.error == nil)
            precondition((urlCache.cachedResponse(for: BikeLanesTileStore.request(for: url)) != nil) == item.kept,
                         "disk cache keeps \(item.path): \(item.kept)")
        }

        let store = BikeLanesTileStore(memory: memory(), urlCache: urlCache) { request, completion in
            session.load(request, completion: completion)
        }
        let url = URL(string: "https://tiles.example.test/fresh.png")!
        BikeLanesStubProtocol.set(url, status: 200, type: "image/png", body: bytes(30, 4))
        let loaded = DispatchSemaphore(value: 0)
        store.loadTile(at: url) { _, _ in loaded.signal() }
        precondition(loaded.wait(timeout: .now() + 10) == .success)
        let before = BikeLanesStubProtocol.requestCount
        precondition(load(store, url).source == .memory && BikeLanesStubProtocol.requestCount == before)
    }

    /// The real session with a tile already on disk: a later outage or
    /// server error shows that tile, and a vetoed error keeps it on disk.
    private static func testSessionFallsBackToAnExpiredTileOnDisk() {
        let urlCache = temporaryURLCache()
        let session = BikeLanesTileSession(urlCache: urlCache, protocolClasses: [BikeLanesStubProtocol.self])
        defer { session.invalidate() }
        let store = BikeLanesTileStore(memory: memory(), urlCache: urlCache) { request, completion in
            session.load(request, completion: completion)
        }
        let url = URL(string: "https://tiles.example.test/expired.png")!
        let request = BikeLanesTileStore.request(for: url)
        urlCache.storeCachedResponse(
            CachedURLResponse(response: http(200, url: url), data: pngBytes), for: request)

        BikeLanesStubProtocol.set(url, status: 503, type: "text/plain", body: Data("busy".utf8))
        let serverError = waitForStoreLoad(store, url)
        precondition(try! serverError.result.get() == pngBytes && serverError.source == .stale)
        precondition(urlCache.cachedResponse(for: request)?.data == pngBytes, "the 503 did not replace the tile on disk")

        BikeLanesStubProtocol.set(url, status: 0, type: "", body: Data())
        let offline = waitForStoreLoad(store, url)
        precondition(try! offline.result.get() == pngBytes && offline.source == .stale)
        precondition(store.memory.count == 0, "an expired tile is never promoted to memory")

        BikeLanesStubProtocol.set(url, status: 404, type: "text/plain", body: Data("gone".utf8))
        guard case .failure = waitForStoreLoad(store, url).result else { preconditionFailure("a 404 fails the tile") }
    }

    // MARK: Zoom

    private static func testZoomThreshold() {
        let threshold = BikeLanesZoomRange.minimumVisibleZoom
        precondition(abs(pow(2, BikeLanesZoomRange.previousMinimumZoom - threshold) - 1.5) < 1e-12,
                     "the layer shows 1.5x further out than before")
        precondition(abs(threshold - 11.415) < 0.001)
        // MapKit draws level-z tiles from zoom z - 1 to z, so the lowest
        // level must reach below the threshold.
        precondition(Double(BikeLanesZoomRange.minimumTileZoom - 1) < threshold,
                     "tiles exist at every zoom the layer shows")
        precondition(BikeLanesZoomRange.isVisible(atZoom: 12) && BikeLanesZoomRange.isVisible(atZoom: 11.42))
        precondition(!BikeLanesZoomRange.isVisible(atZoom: 11.41) && !BikeLanesZoomRange.isVisible(atZoom: 11))
        precondition(BikeLanesZoomRange.isVisible(atZoom: nil), "an unknown scale keeps the layer")

        let world = MKMapSize.world.width
        precondition(BikeLanesZoomRange.zoomLevel(pointsPerMapPoint: 256 / world) == 0)
        precondition(abs(BikeLanesZoomRange.zoomLevel(pointsPerMapPoint: 8192 * 256 / world)! - 13) < 1e-12)
        precondition(BikeLanesZoomRange.zoomLevel(pointsPerMapPoint: 0) == nil)
        precondition(BikeLanesZoomRange.zoomLevel(pointsPerMapPoint: .infinity) == nil)
        // 128 points across 128 * 2^(20-13) map points is zoom 13, measured
        // either across the antimeridian or straight across the map.
        let span: Double = 128 * 128 // 128 points at 2^(20 - 13) map points each
        let across = BikeLanesZoomRange.zoomLevel(
            screenDistance: 128, from: MKMapPoint(x: world - span / 2, y: 1000), to: MKMapPoint(x: span / 2, y: 1000))
        let straight = BikeLanesZoomRange.zoomLevel(
            screenDistance: 128, from: MKMapPoint(x: 1000, y: 1000), to: MKMapPoint(x: 1000 + span, y: 1000))
        precondition(abs(across! - 13) < 1e-9 && abs(straight! - 13) < 1e-9)
        precondition(BikeLanesZoomRange.zoomLevel(
            screenDistance: 128, from: MKMapPoint(x: 5, y: 5), to: MKMapPoint(x: 5, y: 5)) == nil)
    }

    private static func testOverlayAndRendererFollowTheZoom() {
        let overlay = BikeLanesTileOverlay(
            urlTemplate: "https://tiles.example.test/{z}/{x}/{y}.png",
            store: BikeLanesTileStore(memory: memory(), urlCache: nil, transport: FakeTransport(reply: nil).transport))
        precondition(overlay.minimumZ == 12 && overlay.maximumZ == 18 && !overlay.canReplaceMapContent)
        precondition(overlay.isShownAtCurrentZoom, "the layer starts shown")
        let renderer = BikeLanesTileRenderer.make(for: overlay)
        precondition(renderer.alpha == 1)

        precondition(overlay.updateZoom(11.3) && !overlay.isShownAtCurrentZoom, "zooming out past 11.415 hides it")
        precondition(!overlay.updateZoom(10), "staying zoomed out is no change")
        renderer.zoomVisibilityChanged()
        precondition(renderer.alpha == 0)
        precondition(!renderer.canDraw(overlay.boundingMapRect, zoomScale: pow(2, 12 - 20)),
                     "a hidden layer neither draws nor downloads")
        precondition(BikeLanesTileRenderer.make(for: overlay).alpha == 0, "a new renderer starts hidden")

        precondition(overlay.updateZoom(11.5) && overlay.isShownAtCurrentZoom, "zooming back in shows it")
        renderer.zoomVisibilityChanged()
        precondition(renderer.alpha == 1)
        precondition(!overlay.updateZoom(nil), "an unknown scale keeps it shown")
    }

    // MARK: Helpers

    private static let tileURL = URL(string: "https://tiles.example.test/13/4206/2692.png")!
    private static let otherTileURL = URL(string: "https://tiles.example.test/13/4207/2692.png")!

    private static func bytes(_ count: Int, _ value: UInt8) -> Data { Data(repeating: value, count: count) }
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16])
    private static let webpBytes = Data(Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WEBPVP8 ".utf8))

    private static func memory() -> BikeLanesTileMemoryCache {
        BikeLanesTileMemoryCache(byteLimit: 1_000_000, countLimit: 100)
    }

    private static func http(_ status: Int, type: String = "image/png", url: URL = tileURL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": type, "Cache-Control": "max-age=86400"])!
    }

    private static func temporaryURLCache() -> URLCache {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BikeLanesTileCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return URLCache(memoryCapacity: 1_000_000, diskCapacity: 4_000_000, directory: directory)
    }

    private static func load(
        _ store: BikeLanesTileStore, _ url: URL
    ) -> (result: Result<Data, Error>, source: BikeLanesTileStore.Source?) {
        let box = ResultBox()
        store.loadTile(at: url) { result, source in box.value = (result, source) }
        guard let value = box.value else { preconditionFailure("the fake transport answers at once") }
        return value
    }

    private static func waitForStoreLoad(
        _ store: BikeLanesTileStore, _ url: URL
    ) -> (result: Result<Data, Error>, source: BikeLanesTileStore.Source?) {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        store.loadTile(at: url) { result, source in
            box.value = (result, source)
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 10) == .success, "the stub answers")
        return box.value!
    }

    private static func waitForLoad(
        _ session: BikeLanesTileSession, _ request: URLRequest
    ) -> BikeLanesTileStore.TransportResult {
        let box = TransportBox()
        let done = DispatchSemaphore(value: 0)
        session.load(request) { result in
            box.value = result
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 10) == .success, "the stub answers")
        return box.value!
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: (result: Result<Data, Error>, source: BikeLanesTileStore.Source?)?
}

private final class DataListBox: @unchecked Sendable {
    var values: [Data] = []
}

private final class TransportBox: @unchecked Sendable {
    var value: BikeLanesTileStore.TransportResult?
}

/// Records requests; answers at once with `reply`, or holds them for `complete`.
private final class FakeTransport: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var held: [@Sendable (BikeLanesTileStore.TransportResult) -> Void] = []
    private let reply: ((URLRequest) -> BikeLanesTileStore.TransportResult)?

    init(reply: ((URLRequest) -> BikeLanesTileStore.TransportResult)?) {
        self.reply = reply
    }

    var transport: BikeLanesTileStore.Transport {
        { [self] request, completion in
            requests.append(request)
            if let reply { completion(reply(request)) } else { held.append(completion) }
        }
    }

    func complete(_ result: BikeLanesTileStore.TransportResult) {
        let waiting = held
        held.removeAll()
        waiting.forEach { $0(result) }
    }
}

/// Serves canned HTTP answers, as a server would, including cache headers.
/// Status 0 fails the request as if the device were offline.
private final class BikeLanesStubProtocol: URLProtocol {
    private struct Answer {
        let status: Int
        let type: String
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [URL: Answer] = [:]
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { lock.withLock { requests } }

    static func set(_ url: URL, status: Int, type: String, body: Data) {
        lock.withLock { answers[url] = Answer(status: status, type: type, body: body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tiles.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let answer = Self.lock.withLock({ () -> Answer? in
                  Self.requests += 1
                  return Self.answers[url]
              }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        guard answer.status != 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": answer.type, "Cache-Control": "max-age=86400", "ETag": "\"stub\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
