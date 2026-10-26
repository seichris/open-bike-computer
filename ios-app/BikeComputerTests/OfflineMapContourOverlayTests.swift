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
        print("Offline map contour overlay tests passed")
    }
}
