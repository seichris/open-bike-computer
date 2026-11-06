import Foundation
import MapKit
import UIKit

// Mac Catalyst coverage for the UIKit contour overlay. Saved state is built
// from the backend-signed fixture with the production storage types; the
// download and save paths themselves are covered by
// OfflineMapContourCompanionTests, which needs the macOS Keychain fallback.

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

final class ContourOverlayURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        requestCount += 1
        lock.unlock()
        return false
    }
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@main
struct OfflineMapContourOverlayTests {
    @MainActor
    static func main() async {
        let fixture = ContourFixture.load()
        let suite = "contour-overlay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("contour-overlay-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContourOverlayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // A downloaded combined map exactly as the save path records it.
        let mapID = fixture.string("combined_map_id")
        let stream = fixture.stream("combined")
        let packURL = cache.appendingPathComponent("\(mapID).bmap")
        try! fixture.bytes("combined_stream_hex").write(to: packURL)
        let verified: VerifiedBikeMapArtifact
        do {
            verified = try BikeMapStreamArtifactValidator.validate(
                url: packURL,
                artifact: stream,
                expectedMapID: mapID,
                trustStore: fixture.trustStore
            )
        } catch {
            fail("fixture stream verifies: \(error)")
        }
        guard let topography = verified.topography else {
            fail("fixture stream declares contours")
        }
        let companion = fixture.companion("combined")!
        let companionData = fixture.bytes("combined_companion_hex")
        let receipt = TopographyCompanionReceipt(
            mapEntryID: "job_v1_overlayfixture",
            mapContentReceipt: companion.mapContentReceipt!,
            mapID: mapID,
            sha256: companion.sha256,
            bytes: Int64(companionData.count),
            intermediateSha256: companion.intermediateSha256!,
            sourcePolicySha256: companion.sourcePolicySha256!,
            attributionSha256: companion.attributionSha256!
        )
        let companionURL = cache.appendingPathComponent("topography-\(receipt.mapEntryID).btopo")
        try! companionData.write(to: companionURL)
        try! SavedTopographyCompanionStorage.save(
            SavedTopographyCompanionAssociation(
                schemaVersion: SavedTopographyCompanionAssociation.currentSchemaVersion,
                localArtifactFilename: companionURL.lastPathComponent,
                streamArtifactSHA256: stream.sha256,
                receipt: receipt
            ),
            for: companionURL
        )
        let metadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: mapID,
            displayName: nil,
            localArtifactFilename: packURL.lastPathComponent,
            streamFormatVersion: 1,
            rendererFormatVersion: verified.rendererFormatVersion,
            jobID: fixture.string("combined_job_id"),
            serverURLString: nil,
            clientInstallationID: nil,
            primaryArtifact: stream,
            legacyArtifact: nil,
            lastTransferProtocol: nil,
            lastTransferStreamFormat: nil,
            lastTransferSessionID: nil,
            lastBackgroundTaskID: nil,
            lastDeviceSequence: nil,
            lastDeviceState: nil,
            lastDeviceStep: nil,
            lastDeviceStepCount: nil,
            lastDeviceProgress: nil,
            expectedActiveMapID: mapID,
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil,
            topography: topography,
            topographyCompanion: receipt
        )
        try! SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        defaults.set(true, forKey: "offlineMap.topographicMapsEnabled.v1")

        func manager() -> OfflineMapManager {
            OfflineMapManager(
                defaults: defaults,
                mapPlatformSession: session,
                cacheDirectory: cache,
                mapStreamTrustStore: fixture.trustStore,
                mapSnapshot: { _ in nil }
            )
        }

        let shown = manager()
        let opened = await waitUntil { shown.topographyOverlay != nil }
        check(opened, "the saved companion opens as the iPhone overlay: \(shown.topographyOverlayStatus)")
        check(
            (shown.topographyOverlay as? BicinoTopographyTileOverlay)?.receipt == receipt,
            "the overlay reads the saved map's own companion"
        )

        // Display switches act on downloaded layers only.
        shown.topographicMapsEnabled = false
        check(shown.topographyOverlay == nil, "turning contours off removes the overlay")
        check(
            shown.topographyOverlayStatus == "Topographic contours are turned off.",
            "turning contours off is explicit"
        )
        shown.topographicMapsEnabled = true
        let reopened = await waitUntil { shown.topographyOverlay != nil }
        check(reopened, "turning contours on reopens the downloaded companion")
        check(shown.currentJob == nil && !shown.isBusy, "display switches never start a map job")
        check(ContourOverlayURLProtocol.count == 0, "display switches never contact the map service")

        // A contour map saved without its companion receipt asks for a fresh
        // download instead of showing nothing silently.
        var unsupported = metadata
        unsupported.topographyCompanion = nil
        try! SavedMapArtifactMetadataStore.save(unsupported, for: packURL)
        let outdated = manager()
        check(outdated.topographyOverlay == nil, "an old saved contour contract shows no overlay")
        check(
            outdated.topographyOverlayStatus.contains("Download the map again"),
            "an old saved contour contract asks for a fresh download: \(outdated.topographyOverlayStatus)"
        )

        // A tampered companion fails its byte verification.
        try! SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        var tampered = companionData
        tampered[tampered.count / 2] ^= 0xff
        try! tampered.write(to: companionURL)
        let rejected = manager()
        let settled = await waitUntil {
            rejected.topographyOverlayStatus.contains("could not be verified")
        }
        check(settled, "a tampered companion is rejected: \(rejected.topographyOverlayStatus)")
        check(rejected.topographyOverlay == nil, "a tampered companion shows no overlay")

        // Apple Maps draws mainland China in GCJ-02 and its neighbours in
        // WGS-84. Any selection reaching the mainland is warped point by point,
        // so one across the border lines up on both sides.
        func alignsChina(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> Bool {
            BicinoTopographyTileOverlay.alignsChina(
                boundsE7: [west, south, east, north].map { Int(($0 * 10_000_000).rounded()) }
            )
        }
        check(alignsChina(113.2, 23.0, 113.5, 23.2), "a Guangzhou selection is drawn in GCJ-02")
        check(!alignsChina(114.13, 22.24, 114.22, 22.29), "a Hong Kong Island selection stays in WGS-84")
        check(alignsChina(113.9, 22.45, 114.2, 22.6),
              "a Shenzhen selection reaching Hong Kong is shown, aligned point by point")
        // Labels in a view across the border come from both sides' WGS-84
        // areas: a Shenzhen hill drawn shifted and a Hong Kong hill drawn in
        // place.
        let shenzhenHill = (latitude: 22.5300, longitude: 114.0830)
        let shenzhenDrawn = GCJ02.mapKit(fromWGS84: shenzhenHill.latitude, longitude: shenzhenHill.longitude)
        let hongKongHill = (latitude: 22.5011, longitude: 114.1281)
        let shownAt = [
            MKMapPoint(CLLocationCoordinate2D(latitude: shenzhenDrawn.latitude, longitude: shenzhenDrawn.longitude)),
            MKMapPoint(CLLocationCoordinate2D(latitude: hongKongHill.latitude, longitude: hongKongHill.longitude)),
        ]
        let view = MKMapRect(
            x: shownAt.map(\.x).min()!, y: shownAt.map(\.y).min()!,
            width: abs(shownAt[0].x - shownAt[1].x), height: abs(shownAt[0].y - shownAt[1].y)
        ).insetBy(dx: -10, dy: -10)
        let area = BicinoTopographyTileOverlay.labelArea(for: view, alignsChina: true)
        let unshiftedArea = BicinoTopographyTileOverlay.labelArea(for: view, alignsChina: false)
        func covers(_ area: (west: Int, south: Int, east: Int, north: Int), _ hill: (latitude: Double, longitude: Double)) -> Bool {
            let point = BicinoTopographyTileOverlay.worldPoint(latitude: hill.latitude, longitude: hill.longitude)
            return Double(area.west) <= point.0 && point.0 <= Double(area.east) &&
                Double(area.south) <= point.1 && point.1 <= Double(area.north)
        }
        check(covers(area, shenzhenHill) && covers(area, hongKongHill),
              "labels across the border are queried from both sides' WGS-84 areas")
        check(!covers(unshiftedArea, shenzhenHill),
              "the view's own area alone would miss the Shenzhen hill's labels")
        // Beside the border a MapKit pixel takes the mainland reading, so a
        // Hong Kong label there would sit on shifted Shenzhen contours.
        func label(_ hill: (latitude: Double, longitude: Double), alignsChina: Bool = true) -> CLLocationCoordinate2D? {
            let point = BicinoTopographyTileOverlay.worldPoint(latitude: hill.latitude, longitude: hill.longitude)
            return BicinoTopographyTileOverlay.drawnCoordinate(worldX: point.0, worldY: point.1, alignsChina: alignsChina)
        }
        func near(_ coordinate: CLLocationCoordinate2D?, _ latitude: Double, _ longitude: Double) -> Bool {
            guard let coordinate else { return false }
            return abs(coordinate.latitude - latitude) < 1e-7 && abs(coordinate.longitude - longitude) < 1e-7
        }
        let besideBorder = (latitude: 22.52727, longitude: 114.08211)
        check(label(besideBorder) == nil && near(label(besideBorder, alignsChina: false), 22.52727, 114.08211),
              "a Hong Kong label beside the border is skipped where the tile shows Shenzhen")
        check(near(label(hongKongHill), hongKongHill.latitude, hongKongHill.longitude) &&
              near(label(shenzhenHill), shenzhenDrawn.latitude, shenzhenDrawn.longitude),
              "labels elsewhere sit where their own contours are drawn")
        // A terrain-relief cell moves whole with its centre, so a Shenzhen
        // cell across the border keeps its shape, and a Hong Kong cell in the
        // strip is not drawn over the shifted Shenzhen terrain there.
        func world(_ place: (latitude: Double, longitude: Double)) -> (Double, Double) {
            BicinoTopographyTileOverlay.worldPoint(latitude: place.latitude, longitude: place.longitude)
        }
        func relief(_ center: (Double, Double), alignsChina: Bool = true) -> [CLLocationCoordinate2D]? {
            BicinoTopographyTileOverlay.reliefCorners(
                worldX: center.0 - 64, worldY: center.1 - 64, size: 128, alignsChina: alignsChina)
        }
        func same(_ a: [CLLocationCoordinate2D]?, _ b: [CLLocationCoordinate2D]?) -> Bool {
            guard let a, let b else { return false }
            return zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
        let shenzhen = (latitude: 22.5431, longitude: 114.0579)
        var inMainland = shenzhen
        var inHongKong = hongKongHill
        for _ in 0..<50 {
            let middle = (latitude: (inMainland.latitude + inHongKong.latitude) / 2,
                          longitude: (inMainland.longitude + inHongKong.longitude) / 2)
            if MainlandChinaRegion.contains(latitude: middle.latitude, longitude: middle.longitude) {
                inMainland = middle
            } else {
                inHongKong = middle
            }
        }
        let border = world(inMainland), inland = world(shenzhen)
        let length = hypot(inland.0 - border.0, inland.1 - border.1)
        let straddling = (border.0 + (inland.0 - border.0) / length * 20,
                          border.1 + (inland.1 - border.1) / length * 20)
        let inPlace = relief(straddling, alignsChina: false)!
        check(inPlace.contains { !MainlandChinaRegion.contains(latitude: $0.latitude, longitude: $0.longitude) },
              "the Shenzhen test cell reaches across the border")
        guard let drawn = relief(straddling) else { fail("a Shenzhen cell at the border is drawn") }
        let metersPerPoint = MKMetersPerMapPointAtLatitude(inMainland.latitude)
        let moves = zip(inPlace, drawn).map { from, to in
            ((MKMapPoint(to).x - MKMapPoint(from).x) * metersPerPoint,
             (MKMapPoint(to).y - MKMapPoint(from).y) * metersPerPoint)
        }
        check(hypot(moves[0].0, moves[0].1) > 100 &&
              moves.allSatisfy { hypot($0.0 - moves[0].0, $0.1 - moves[0].1) < 1 },
              "a Shenzhen cell across the border moves whole and keeps its shape")
        check(relief(world(besideBorder)) == nil && relief(world(besideBorder), alignsChina: false) != nil,
              "a Hong Kong relief cell in the strip is not drawn over shifted Shenzhen terrain")
        check(same(relief(world(hongKongHill)), relief(world(hongKongHill), alignsChina: false)),
              "Hong Kong relief cells beyond the strip stay in place")
        print("Offline map contour overlay tests passed")
    }
}
