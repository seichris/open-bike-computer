import Foundation
import MapKit

/// Local transparent contours only. A caller must separately enforce saved-map
/// scope and regional MapKit alignment eligibility before attaching the layer.
nonisolated final class BicinoTopographyTileOverlay: MKTileOverlay, @unchecked Sendable {
    let receipt: TopographyCompanionReceipt
    private let store: TopographyCompanionStore
    private let mapBounds: MKMapRect

    private init(store: TopographyCompanionStore, metadata: TopographyCompanionMetadata) {
        self.store = store
        self.receipt = store.receipt
        let bounds = metadata.boundsE7.map { Double($0) / 10_000_000 }
        let northwest = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[0]))
        let southeast = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[2]))
        mapBounds = MKMapRect(x: northwest.x, y: northwest.y, width: southeast.x - northwest.x, height: southeast.y - northwest.y)
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = metadata.minimumZoom
        maximumZ = metadata.maximumZoom
        isGeometryFlipped = false
    }

    static func open(url: URL, receipt: TopographyCompanionReceipt) async throws -> BicinoTopographyTileOverlay {
        let store = TopographyCompanionStore(url: url, receipt: receipt)
        let metadata = try await store.validate()
        try Task.checkCancellation()
        return BicinoTopographyTileOverlay(store: store, metadata: metadata)
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
        Task {
            do {
                let data = try await store.tile(z: z, x: x, y: y, scale: scale)
                reply.complete(data ?? Self.transparentPNG, nil)
            } catch {
                reply.complete(nil, error)
            }
        }
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
