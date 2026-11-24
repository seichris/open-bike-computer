import Foundation
import MapKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Zoom range

/// Where the Bike Lanes layer is drawn.
///
/// MapKit draws a level-z tile from map zoom z - 1 up to z: it shrinks tiles
/// but never enlarges them. With z13 as the lowest tile level, the layer
/// therefore disappeared at zoom 12.0 (measured in the iOS 26.5 Simulator).
/// It now stays on until the map is zoomed out 1.5x further, to about 11.4.
/// Tile levels are whole numbers, so the overlay asks for z12 tiles, which
/// cover zoom 11 to 12, and the renderer hides the layer below the exact
/// threshold.
nonisolated enum BikeLanesZoomRange {
    static let minimumTileZoom = 12
    static let maximumTileZoom = 18
    /// The zoom at which the layer used to disappear, with z13 tiles.
    static let previousMinimumZoom = 12.0
    static let zoomOutFactor = 1.5
    /// 12 - log2(1.5), about 11.415.
    static let minimumVisibleZoom = previousMinimumZoom - log2(zoomOutFactor)

    /// The Web Mercator zoom level of a map scale, with 256-point tiles:
    /// at zoom 0 the whole world is 256 points wide.
    static func zoomLevel(pointsPerMapPoint: Double) -> Double? {
        guard pointsPerMapPoint.isFinite, pointsPerMapPoint > 0 else { return nil }
        return log2(pointsPerMapPoint * MKMapSize.world.width / 256)
    }

    /// An unknown scale keeps the layer on rather than hiding it.
    static func isVisible(atZoom zoom: Double?) -> Bool {
        guard let zoom else { return true }
        return zoom >= minimumVisibleZoom
    }

    /// The zoom level at the middle of the map view. A horizontal line through
    /// the centre keeps its scale under pitch and heading, unlike
    /// `visibleMapRect`, which grows toward the horizon when the map tilts.
    @MainActor static func centerZoomLevel(of mapView: MKMapView) -> Double? {
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let halfSpan = min(bounds.width / 4, 64)
        let start = MKMapPoint(mapView.convert(
            CGPoint(x: bounds.midX - halfSpan, y: bounds.midY), toCoordinateFrom: mapView))
        let end = MKMapPoint(mapView.convert(
            CGPoint(x: bounds.midX + halfSpan, y: bounds.midY), toCoordinateFrom: mapView))
        return zoomLevel(screenDistance: Double(halfSpan * 2), from: start, to: end)
    }

    /// The zoom for a screen distance that covers the map between two points,
    /// taking the short way round when the line crosses the antimeridian.
    static func zoomLevel(screenDistance: Double, from start: MKMapPoint, to end: MKMapPoint) -> Double? {
        let world = MKMapSize.world.width
        var dx = abs(end.x - start.x)
        if dx > world / 2 { dx = world - dx }
        let distance = hypot(dx, end.y - start.y)
        guard distance > 0 else { return nil }
        return zoomLevel(pointsPerMapPoint: screenDistance / distance)
    }
}

// MARK: - Memory cache

/// A least-recently-used cache of encoded tile images, bounded by both total
/// bytes and entry count. Unlike `NSCache`, its limits are exact.
nonisolated final class BikeLanesTileMemoryCache: @unchecked Sendable {
    private final class Entry {
        let key: String
        let data: Data
        var older: Entry?
        weak var newer: Entry?

        init(key: String, data: Data) {
            self.key = key
            self.data = data
        }
    }

    let byteLimit: Int
    let countLimit: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var newest: Entry?
    private weak var oldest: Entry?
    private var storedBytes = 0

    init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    var totalBytes: Int { lock.withLock { storedBytes } }
    var count: Int { lock.withLock { entries.count } }

    /// Returns the tile and marks it as the most recently used.
    func data(for key: String) -> Data? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            unlink(entry)
            pushNewest(entry)
            return entry.data
        }
    }

    /// Stores the tile, evicting the least recently used ones to stay within
    /// both limits. Empty data, or a tile larger than the whole budget, is not kept.
    func insert(_ data: Data, for key: String) {
        guard !data.isEmpty, data.count <= byteLimit, countLimit > 0 else { return }
        lock.withLock {
            if let existing = entries[key] { remove(existing) }
            let entry = Entry(key: key, data: data)
            entries[key] = entry
            pushNewest(entry)
            storedBytes += data.count
            while storedBytes > byteLimit || entries.count > countLimit, let victim = oldest {
                remove(victim)
            }
        }
    }

    func removeAll() {
        lock.withLock {
            // Unlink one by one so releasing a long chain cannot recurse deeply.
            while let entry = newest { remove(entry) }
            entries.removeAll()
            storedBytes = 0
        }
    }

    private func pushNewest(_ entry: Entry) {
        entry.older = newest
        entry.newer = nil
        newest?.newer = entry
        newest = entry
        if oldest == nil { oldest = entry }
    }

    private func unlink(_ entry: Entry) {
        if let newer = entry.newer { newer.older = entry.older } else { newest = entry.older }
        if let older = entry.older { older.newer = entry.newer } else { oldest = entry.newer }
        entry.older = nil
        entry.newer = nil
    }

    private func remove(_ entry: Entry) {
        unlink(entry)
        entries[entry.key] = nil
        storedBytes -= entry.data.count
    }
}

// MARK: - Tile store

enum BikeLanesTileError: Error, Equatable {
    /// The server answered, but not with a usable image.
    case unusableResponse(status: Int?)
}

/// Loads bike-lane tiles through a memory cache and an HTTP disk cache.
///
/// - The memory cache answers tiles seen earlier in this session at once.
/// - The disk `URLCache` follows the server's `Cache-Control` and `ETag`:
///   fresh tiles come from disk, stale ones are revalidated. Both caches are
///   bounded, and only successful image responses are kept.
/// - Concurrent requests for one tile share a single network load.
nonisolated final class BikeLanesTileStore: @unchecked Sendable {
    enum Source: String, Sendable {
        case memory, disk, revalidated, network, stale
    }

    struct TransportResult: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
        var source: Source = .network
    }

    typealias Transport = @Sendable (URLRequest, @escaping @Sendable (TransportResult) -> Void) -> Void
    typealias Completion = @Sendable (Result<Data, Error>, Source?) -> Void

    static let memoryByteLimit = 12 * 1024 * 1024
    static let memoryCountLimit = 1024
    static let diskByteLimit = 64 * 1024 * 1024
    static let requestTimeout: TimeInterval = 20

    static let shared = BikeLanesTileStore(
        diskDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appending(path: "BikeLanesTiles", directoryHint: .isDirectory))

    let memory: BikeLanesTileMemoryCache
    let urlCache: URLCache?
    private let transport: Transport
    private let lock = NSLock()
    private var waiting: [String: [Completion]] = [:]
#if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
#endif

    init(memory: BikeLanesTileMemoryCache, urlCache: URLCache?, transport: @escaping Transport) {
        self.memory = memory
        self.urlCache = urlCache
        self.transport = transport
#if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [memory] _ in memory.removeAll() }
#endif
    }

    /// The app's configuration: the memory cache plus a dedicated disk cache.
    convenience init(diskDirectory: URL?) {
        let urlCache = URLCache(memoryCapacity: 0, diskCapacity: Self.diskByteLimit, directory: diskDirectory)
        let session = BikeLanesTileSession(urlCache: urlCache)
        self.init(
            memory: BikeLanesTileMemoryCache(byteLimit: Self.memoryByteLimit, countLimit: Self.memoryCountLimit),
            urlCache: urlCache,
            transport: { request, completion in session.load(request, completion: completion) }
        )
    }

    deinit {
#if canImport(UIKit)
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
#endif
    }

    /// Only a complete HTTP 200 image is worth keeping. Errors, redirects,
    /// empty bodies and captive-portal pages never enter either cache.
    static func isCacheableTile(_ response: URLResponse?, data: Data?) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data, !data.isEmpty else { return false }
        return http.mimeType?.lowercased().hasPrefix("image/") == true
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: requestTimeout)
        request.httpShouldHandleCookies = false
        return request
    }

    func loadTile(at url: URL, completion: @escaping Completion) {
        let key = url.absoluteString
        if let data = memory.data(for: key) {
            completion(.success(data), .memory)
            return
        }
        let isFirst: Bool = lock.withLock {
            let isFirst = waiting[key] == nil
            waiting[key, default: []].append(completion)
            return isFirst
        }
        guard isFirst else { return }
        let request = Self.request(for: url)
        transport(request) { [self] result in
            finish(key: key, request: request, result: result)
        }
    }

    private func finish(key: String, request: URLRequest, result: TransportResult) {
        let outcome: (Result<Data, Error>, Source?)
        if let data = result.data, Self.isCacheableTile(result.response, data: data) {
            memory.insert(data, for: key)
            outcome = (.success(data), result.source)
        } else {
            let status = (result.response as? HTTPURLResponse)?.statusCode
            let cached = urlCache?.cachedResponse(for: request)
            let cachedIsTile = cached.map { Self.isCacheableTile($0.response, data: $0.data) } ?? false
            if cached != nil, !cachedIsTile {
                // A failure that reached the disk cache must not be served later.
                urlCache?.removeCachedResponse(for: request)
            }
            if let cached, cachedIsTile, result.response == nil || (status ?? 0) >= 500 {
                // Offline or a server error: an expired tile beats an empty map.
                // It stays out of memory so the next request tries the network.
                outcome = (.success(cached.data), .stale)
            } else {
                outcome = (.failure(result.error ?? BikeLanesTileError.unusableResponse(status: status)), nil)
            }
        }
        let callbacks = lock.withLock { waiting.removeValue(forKey: key) ?? [] }
        for callback in callbacks { callback(outcome.0, outcome.1) }
    }
}

/// A `URLSession` with its own disk cache. It uses delegate callbacks rather
/// than completion handlers, because only the delegate can refuse to cache a
/// response; `URLCache` otherwise stores a 404 like any other answer.
nonisolated final class BikeLanesTileSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Load {
        let completion: @Sendable (BikeLanesTileStore.TransportResult) -> Void
        var data = Data()
        var source: BikeLanesTileStore.Source = .network

        init(completion: @escaping @Sendable (BikeLanesTileStore.TransportResult) -> Void) {
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var loads: [Int: Load] = [:]
    private var session: URLSession?

    init(urlCache: URLCache, protocolClasses: [AnyClass]? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = BikeLanesTileStore.requestTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.name = "BikeLanesTileSession"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func load(_ request: URLRequest, completion: @escaping @Sendable (BikeLanesTileStore.TransportResult) -> Void) {
        guard let session else {
            completion(.init(error: URLError(.cancelled)))
            return
        }
        let task = session.dataTask(with: request)
        lock.withLock { loads[task.taskIdentifier] = Load(completion: completion) }
        task.resume()
    }

    /// Ends the session. The app's store lives for the whole process; tests call this.
    func invalidate() {
        let session = lock.withLock { () -> URLSession? in
            defer { self.session = nil }
            return self.session
        }
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { loads[dataTask.taskIdentifier]?.data.append(data) }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        let keep = BikeLanesTileStore.isCacheableTile(proposedResponse.response, data: proposedResponse.data)
        completionHandler(keep ? proposedResponse : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        let source: BikeLanesTileStore.Source
        if transactions.contains(where: { ($0.response as? HTTPURLResponse)?.statusCode == 304 }) {
            source = .revalidated
        } else if let last = transactions.last, last.resourceFetchType == .localCache {
            source = .disk
        } else {
            source = .network
        }
        lock.withLock { loads[task.taskIdentifier]?.source = source }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let load = lock.withLock({ loads.removeValue(forKey: task.taskIdentifier) }) else { return }
        load.completion(.init(
            data: error == nil ? load.data : nil, response: error == nil ? task.response : nil,
            error: error, source: load.source))
    }
}

// MARK: - Overlay and renderer

/// The Bike Lanes tile overlay. One instance stays on the map while the layer
/// is on, and every instance shares `BikeLanesTileStore.shared`, so turning the
/// layer off and on again still finds its tiles in memory.
nonisolated class BikeLanesTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let customStore: BikeLanesTileStore?
    private let zoomLock = NSLock()
    private var showsAtCurrentZoom = true

    /// Without a store, tiles go through `BikeLanesTileStore.shared`, which
    /// is created on the first tile load.
    init(urlTemplate: String?, store: BikeLanesTileStore? = nil) {
        customStore = store
        super.init(urlTemplate: urlTemplate)
        canReplaceMapContent = false
        minimumZ = BikeLanesZoomRange.minimumTileZoom
        maximumZ = BikeLanesZoomRange.maximumTileZoom
    }

    /// Whether the map is zoomed in far enough to draw the layer.
    var isShownAtCurrentZoom: Bool { zoomLock.withLock { showsAtCurrentZoom } }

    /// Records the map's zoom; returns true when that shows or hides the layer.
    @discardableResult
    func updateZoom(_ zoom: Double?) -> Bool {
        let shows = BikeLanesZoomRange.isVisible(atZoom: zoom)
        return zoomLock.withLock {
            defer { showsAtCurrentZoom = shows }
            return showsAtCurrentZoom != shows
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // MapKit's callback predates @Sendable; it may be called on any thread.
        nonisolated(unsafe) let result = result
        let z = path.z
        (customStore ?? .shared).loadTile(at: url(forTilePath: path)) { outcome, source in
            BikeLanesTileDiagnostics.note(z: z, source: source)
            switch outcome {
            case .success(let data): result(data, nil)
            case .failure(let error): result(nil, error)
            }
        }
    }
}

/// Draws bike-lane tiles only while the map is zoomed in past
/// `BikeLanesZoomRange.minimumVisibleZoom`. The overlay itself stays on the
/// map, so hiding it never changes the realistic-terrain state.
nonisolated final class BikeLanesTileRenderer: MKTileOverlayRenderer {
    // No initializer of its own: MKTileOverlayRenderer's init(tileOverlay:)
    // calls init(overlay:), which a Swift subclass then has to inherit.
    static func make(for overlay: BikeLanesTileOverlay) -> BikeLanesTileRenderer {
        let renderer = BikeLanesTileRenderer(tileOverlay: overlay)
        renderer.alpha = overlay.isShownAtCurrentZoom ? 1 : 0
        return renderer
    }

    private var isShown: Bool {
        (overlay as? BikeLanesTileOverlay)?.isShownAtCurrentZoom ?? true
    }

    /// Below the threshold nothing is drawn or downloaded.
    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        guard isShown else { return false }
        return super.canDraw(mapRect, zoomScale: zoomScale)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard isShown else { return }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }

    /// Applies the overlay's current zoom state after it changed.
    func zoomVisibilityChanged() {
        alpha = isShown ? 1 : 0
        setNeedsDisplay()
    }
}

// MARK: - Diagnostics

/// With `--bike-lanes-tile-diagnostics`, DEBUG builds log where each tile came
/// from and running totals. Tile coordinates are left out because they reveal
/// where the map is.
nonisolated enum BikeLanesTileDiagnostics {
#if DEBUG
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--bike-lanes-tile-diagnostics")
#endif

    static func note(z: Int, source: BikeLanesTileStore.Source?) {
#if DEBUG
        guard isEnabled else { return }
        let name = source?.rawValue ?? "failed"
        let summary: String = lock.withLock {
            counts[name, default: 0] += 1
            return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        print("BIKE_LANES_TILE z=\(z) source=\(name) totals \(summary)")
#endif
    }

    static func noteZoom(_ zoom: Double?, shown: Bool) {
#if DEBUG
        guard isEnabled else { return }
        print("BIKE_LANES_ZOOM zoom=\(zoom.map { String(format: "%.3f", $0) } ?? "unknown") shown=\(shown)")
#endif
    }
}
