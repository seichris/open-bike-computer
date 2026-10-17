import CryptoKit
import Foundation
import MapKit
import SQLite3
import SwiftUI
import UIKit

@MainActor private final class ContourTestMap: MKMapView {
    var items: [MKAnnotation] = []
    var lines: [MKOverlay] = []
    var testCenter: CLLocationCoordinate2D?
    override var centerCoordinate: CLLocationCoordinate2D {
        get { testCenter ?? super.centerCoordinate }
        set { testCenter = newValue }
    }
    override func addOverlay(_ overlay: MKOverlay, level: MKOverlayLevel) { lines.append(overlay) }
    override func insertOverlay(_ overlay: MKOverlay, at index: Int, level: MKOverlayLevel) {
        lines.insert(overlay, at: index)
    }
    override func removeOverlays(_ overlays: [MKOverlay]) {
        let ids = Set(overlays.map { ObjectIdentifier($0 as AnyObject) })
        lines.removeAll { ids.contains(ObjectIdentifier($0 as AnyObject)) }
    }
    var added = 0
    var removed = 0
    private var viewport = MKMapRect(
        x: MKMapSize.world.width / 2, y: MKMapSize.world.height / 2 - 27436,
        width: 27436, height: 27436)
    override var visibleMapRect: MKMapRect {
        get { viewport }
        set { viewport = newValue }
    }
    override var annotations: [MKAnnotation] { items }
    override var overlays: [MKOverlay] { lines }
    override func addAnnotations(_ annotations: [MKAnnotation]) {
        added += annotations.count
        items.append(contentsOf: annotations)
    }
    override func removeAnnotations(_ annotations: [MKAnnotation]) {
        removed += annotations.count
        let identifiers = Set(annotations.map { ObjectIdentifier($0 as AnyObject) })
        items.removeAll { identifiers.contains(ObjectIdentifier($0 as AnyObject)) }
    }
    override func convert(_ coordinate: CLLocationCoordinate2D, toPointTo view: UIView?) -> CGPoint {
        let x = coordinate.longitude * .pi / 180 * 6_378_137
        let y = log(tan(.pi / 4 + coordinate.latitude * .pi / 360)) * 6_378_137
        return CGPoint(x: x / 4096 * 400, y: 400 - y / 4096 * 400)
    }
}

@main struct ContourLabelLifecycleTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("labels.btopo")
        let receipt = try fixture(at: url)
        let overlay = try await BicinoTopographyTileOverlay.open(url: url, receipt: receipt)
        let map = ContourTestMap(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let labels = BicinoContourLabels()
        labels.update(on: map, overlay: overlay)
        for _ in 0..<100 where contourAnnotations(map).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let initial = contourAnnotations(map)
        precondition(!initial.isEmpty, "fixture must show numbers")
        let initialIDs = Set(initial.map(ObjectIdentifier.init))
        let initialAdds = map.added
        for _ in 0..<100 { labels.update(on: map, overlay: overlay) }
        try await Task.sleep(for: .milliseconds(200))
        precondition(map.added == initialAdds && map.removed == 0,
                     "GPS refresh with the same inputs must retain annotation objects")

        var points = (0..<6000).map { MKMapPoint(x: Double($0), y: Double($0)) }
        map.lines = [MKPolyline(points: &points, count: points.count)]
        labels.update(on: map, overlay: overlay)
        try await Task.sleep(for: .milliseconds(200))
        precondition(Set(contourAnnotations(map).map(ObjectIdentifier.init)) == initialIDs,
                     "offscreen points in a long route must neither hide nor replace numbers")

        let marker = MKPointAnnotation()
        marker.coordinate = CLLocationCoordinate2D(latitude: 10, longitude: 10)
        map.items.append(marker)
        labels.update(on: map, overlay: overlay)
        try await Task.sleep(for: .milliseconds(200))
        precondition(Set(contourAnnotations(map).map(ObjectIdentifier.init)) == initialIDs,
                     "reservation refresh must apply a delta when the selected anchors are unchanged")
        marker.coordinate = initial[0].coordinate
        labels.update(on: map, overlay: overlay)
        try await Task.sleep(for: .milliseconds(200))
        let movedIDs = Set(contourAnnotations(map).map(ObjectIdentifier.init))
        precondition(!movedIDs.contains(ObjectIdentifier(initial[0])))
        precondition(!movedIDs.intersection(initialIDs).isEmpty,
                     "moving a marker must retain unaffected labels")
        labels.clear(on: map)
        precondition(contourAnnotations(map).isEmpty)
        var grids = try await overlay.terrain(near: overlay.coordinate(worldX: 0, worldY: 0))
        var center: CLLocationCoordinate2D?
        let terrainMap = BicinoTerrainMap(overlay: overlay,
            grids: Binding(get: { grids }, set: { grids = $0 }),
            center: Binding(get: { center }, set: { center = $0 }),
            style: .hillshade, contours: false)
        let coordinator = terrainMap.makeCoordinator()
        map.lines = []
        coordinator.applyStyle(.hillshade, contours: false, to: map)
        let originalX = (map.overlays[0] as! TerrainReliefOverlay).cells[0].points[0].x
        map.testCenter = overlay.coordinate(worldX: 5 * 4096, worldY: 2048)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        for _ in 0..<100 where grids.first?.x != 5 { try await Task.sleep(for: .milliseconds(20)) }
        precondition(grids.first?.x == 5 && center != nil, "pan must update shared terrain state")
        let pannedX = (map.overlays[0] as! TerrainReliefOverlay).cells[0].points[0].x
        precondition(pannedX > originalX)
        coordinator.applyStyle(.slope, contours: false, to: map)
        precondition((map.overlays[0] as! TerrainReliefOverlay).cells[0].points[0].x == pannedX,
                     "style changes must use the panned grids")
        let reopened = terrainMap.makeCoordinator()
        reopened.applyStyle(.hillshade, contours: false, to: map)
        precondition((map.overlays[0] as! TerrainReliefOverlay).cells[0].points[0].x == pannedX,
                     "returning from the 3D view must retain shared grids")
        print("ContourLabelLifecycleTests passed")
    }

    @MainActor private static func contourAnnotations(_ map: ContourTestMap) -> [BicinoContourLabelAnnotation] {
        map.annotations.compactMap { $0 as? BicinoContourLabelAnnotation }
    }

    private static func terrainBytes(x: Int) -> Data {
        var data = Data(repeating: 0, count: 4372)
        data.replaceSubrange(0..<4, with: Data("FME1".utf8))
        data[4] = UInt8(x)
        for p in stride(from: 16, to: data.count, by: 4) { data[p] = 100; data[p+2] = 180 }
        var crc = UInt32.max
        for byte in data[16...] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc ^= UInt32.max
        for i in 0..<4 { data[12+i] = UInt8(truncatingIfNeeded: crc >> (i*8)) }
        return data
    }

    private static func fixture(at url: URL) throws -> TopographyCompanionReceipt {
        let digest = String(repeating: "a", count: 64)
        let metadata = TopographyCompanionMetadata(
            schemaVersion: 2, profileVersion: 1, styleId: "contours-labels-terrain-v2",
            tileScheme: "xyz", tileSize: 256, scales: [1, 2], minimumZoom: 9,
            maximumZoom: 16, mapId: "fixture", intermediateSha256: digest,
            sourcePolicySha256: digest, attributionSha256: digest,
            boundsE7: [0, 0, 2500000, 400000], tileCount: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(metadata) + Data([10]), as: UTF8.self)
        var database: OpaquePointer?
        precondition(sqlite3_open(url.path, &database) == SQLITE_OK)
        func execute(_ sql: String) {
            precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("PRAGMA page_size=4096; PRAGMA application_id=1112821584; PRAGMA user_version=2;")
        execute("CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)")
        execute("CREATE TABLE tiles (z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, scale INTEGER NOT NULL, png BLOB NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY (z, x, y, scale)) WITHOUT ROWID")
        execute("CREATE TABLE labels (x INTEGER NOT NULL, y INTEGER NOT NULL, elevation INTEGER NOT NULL, PRIMARY KEY (x, y, elevation)) WITHOUT ROWID")
        execute("CREATE TABLE terrain (x INTEGER NOT NULL, y INTEGER NOT NULL, grid BLOB NOT NULL, PRIMARY KEY (x, y)) WITHOUT ROWID")
        execute("INSERT INTO metadata VALUES (1, '\(json)')")
        execute("BEGIN")
        for x in stride(from: 256, through: 3840, by: 256) {
            for y in stride(from: 256, through: 3840, by: 256) {
                execute("INSERT INTO labels VALUES (\(x), \(y), 800)")
            }
        }
        for x in 0..<6 {
            let bytes = terrainBytes(x: x)
            execute("INSERT INTO terrain VALUES (\(x), 0, X'\(bytes.map { String(format: "%02x", $0) }.joined())')")
        }
        execute("COMMIT")
        precondition(sqlite3_close(database) == SQLITE_OK)
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return TopographyCompanionReceipt(mapEntryID: "fixture", mapContentReceipt: digest,
            mapID: "fixture", sha256: hash, bytes: Int64(data.count), intermediateSha256: digest,
            sourcePolicySha256: digest, attributionSha256: digest)
    }
}
