import Foundation
import MapKit
import UIKit

/// Local transparent contours only. The signed companion stays in WGS-84; only
/// the MapKit presentation is remapped for wholly mainland-China selections.
nonisolated final class BicinoTopographyTileOverlay: MKTileOverlay, @unchecked Sendable {
    let receipt: TopographyCompanionReceipt
    private let store: TopographyCompanionStore
    private let mapBounds: MKMapRect
    private let alignsChina: Bool
    private let taskLock = NSLock()
    private var tileTasks: [UUID: Task<Void, Never>] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init(
        store: TopographyCompanionStore,
        metadata: TopographyCompanionMetadata,
        alignsChina: Bool
    ) {
        self.store = store
        self.receipt = store.receipt
        self.alignsChina = alignsChina
        let bounds = metadata.boundsE7.map { Double($0) / 10_000_000 }
        let northwestCoordinate = CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[0])
        let southeastCoordinate = CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[2])
        let northwest = MKMapPoint(alignsChina
            ? CoordinateConverter.wgs84ToGCJ02(coordinate: northwestCoordinate)
            : northwestCoordinate)
        let southeast = MKMapPoint(alignsChina
            ? CoordinateConverter.wgs84ToGCJ02(coordinate: southeastCoordinate)
            : southeastCoordinate)
        mapBounds = MKMapRect(x: northwest.x, y: northwest.y, width: southeast.x - northwest.x, height: southeast.y - northwest.y)
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = metadata.minimumZoom
        maximumZ = metadata.maximumZoom
        isGeometryFlipped = false
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.purgeDecodedTiles()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        cancelPendingLoads()
    }

    static func open(url: URL, receipt: TopographyCompanionReceipt) async throws -> BicinoTopographyTileOverlay {
        let store = TopographyCompanionStore(url: url, receipt: receipt)
        let metadata = try await store.validate()
        try Task.checkCancellation()
        let bounds = metadata.boundsE7.map { Double($0) / 10_000_000 }
        let corners = [
            (bounds[1], bounds[0]), (bounds[1], bounds[2]),
            (bounds[3], bounds[0]), (bounds[3], bounds[2])
        ]
        let chinaCorners = corners.filter {
            CoordinateConverter.isInChina(lat: $0.0, lon: $0.1)
        }.count
        guard chinaCorners == 0 || chinaCorners == corners.count else {
            throw TopographyMapKitTileWarp.WarpError.extent
        }
        return BicinoTopographyTileOverlay(
            store: store, metadata: metadata, alignsChina: chinaCorners == corners.count
        )
    }

    override var boundingMapRect: MKMapRect { mapBounds }
    override var coordinate: CLLocationCoordinate2D { MKMapPoint(x: mapBounds.midX, y: mapBounds.midY).coordinate }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Objective-C MapKit predates @Sendable on this callback. Its contract
        // permits asynchronous completion. One task owns exactly one reply.
        let reply = TileReply(result)
        let store = store
        let x = path.x, y = path.y, z = path.z
        let scale = path.contentScaleFactor > 1 ? 2 : 1
        let alignsChina = alignsChina
        let taskID = UUID()
        taskLock.lock()
        tileTasks[taskID] = Task { [weak self] in
            defer { self?.finishTask(taskID) }
            do {
                let data: Data?
                if alignsChina {
                    data = try await TopographyMapKitTileWarp.tile(
                        z: z, x: x, y: y, scale: scale
                    ) { z, x, y, scale in
                        try await store.tile(z: z, x: x, y: y, scale: scale)
                    }
                } else {
                    data = try await store.tile(z: z, x: x, y: y, scale: scale)
                }
                try Task.checkCancellation()
                reply.complete(data ?? Self.transparentPNG, nil)
            } catch {
                reply.complete(nil, error)
            }
        }
        taskLock.unlock()
    }

    func cancelPendingLoads() {
        taskLock.lock()
        let tasks = Array(tileTasks.values)
        tileTasks.removeAll()
        taskLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func finishTask(_ id: UUID) {
        taskLock.lock()
        tileTasks.removeValue(forKey: id)
        taskLock.unlock()
    }

    private func purgeDecodedTiles() {
        Task { await store.purgeCache() }
    }

    // A transparent 1x1 PNG is sufficient for a missing tile: MapKit stretches
    // it to the requested geometry. Never substitute a provider/network URL.
    private static let transparentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")!

    private final class TileReply: @unchecked Sendable {
        private let callback: (Data?, Error?) -> Void
        init(_ callback: @escaping (Data?, Error?) -> Void) { self.callback = callback }
        func complete(_ data: Data?, _ error: Error?) { callback(data, error) }
    }
}
