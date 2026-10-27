import CryptoKit
import Foundation

// Exercises OfflineMapManager's real direct-job and catalog download, save,
// relaunch and replacement paths with maps signed by the backend producer
// (map-platform/backend/tests/contour_companion_fixture.py). The UIKit overlay
// is exercised separately by OfflineMapContourOverlayTests (Mac Catalyst).

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

final class ContourCompanionURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, Data)
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [String] = []
    private static let lock = NSLock()

    static func configure(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    static var requestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.recorded.append(request.url?.path ?? "")
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func waitForIdle(_ manager: OfflineMapManager, timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var observedBusy = false
    while Date() < deadline {
        observedBusy = observedBusy || manager.isBusy
        if !manager.isBusy &&
            (observedBusy || manager.downloadedPackURL != nil || manager.errorMessage != nil) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

struct ContourScenario {
    let defaults: UserDefaults
    let suiteName: String
    let cache: URL
    let session: URLSession
    let serverURL: String

    /// Direct jobs use an unmanaged server (no App Attest); catalog maps use
    /// the development generation server so development-tier grants apply.
    init(_ name: String, serverURL: String = "https://contour-companion.example") {
        self.serverURL = serverURL
        suiteName = "contour-companion-\(name)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("contour-companion-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContourCompanionURLProtocol.self]
        session = URLSession(configuration: configuration)
        defaults.set(serverURL, forKey: "offlineMap.serverURL")
        try! OfflineMapInstallationCredentialStore(defaults: defaults).save(
            Self.credential,
            serverURLString: serverURL
        )
    }

    static let credential = OfflineMapInstallationCredential(
        clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
        clientInstallationToken: "v1." + String(repeating: "C", count: 43)
    )

    static let appIdentity = MapStreamAppBuildIdentity(
        schemaVersion: 1,
        build: "100",
        gitSha: String(repeating: "a", count: 40),
        componentSha256: String(repeating: "b", count: 64)
    )

    func cleanup() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cache)
    }

    @MainActor
    func manager(
        fixture: ContourFixture,
        payloads: [String: Data]? = nil,
        metadataSave: @escaping SavedMapArtifactMetadataSaveOperation = { metadata, url in
            try SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    ) -> OfflineMapManager {
        let payloads = payloads ?? fixture.payloads()
        return OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            cacheDirectory: cache,
            mapStreamTrustStore: fixture.trustStore,
            catalogAppIdentity: Self.appIdentity,
            catalogHost: OfflineMapCatalogConfig.developmentHost,
            catalogClient: try! OfflineMapCatalogClient(
                baseURL: URL(string: "https://\(OfflineMapCatalogConfig.developmentHost)")!,
                session: session
            ),
            packDownload: { _, constraints, onProgress, _ in
                guard let sha = constraints.artifactSHA256, let data = payloads[sha] else {
                    throw URLError(.fileDoesNotExist)
                }
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                return url
            },
            metadataSave: metadataSave
        )
    }

    /// Serves a READY job whose artifact list is exactly `artifacts`.
    func serveJob(jobID: String, mapID: String, artifacts: [OfflineMapArtifact]) {
        ContourCompanionURLProtocol.configure { request in
            let path = request.url?.path ?? ""
            if path == "/v1/installations" {
                return (200, try! JSONEncoder().encode(Self.credential))
            }
            if path == "/v1/map-jobs/\(jobID)" {
                let payload: [String: Any] = [
                    "jobId": jobID,
                    "status": "ready",
                    "mapId": mapID,
                    "createdAt": "2026-10-26T00:00:00Z",
                    "sourceRegion": ["id": "fixture", "name": "Fixture", "provider": "test"],
                    "artifacts": try! JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(artifacts)
                    ),
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            }
            let prefix = "/v1/map-packs/\(mapID)/artifacts/"
            if path.hasPrefix(prefix), path.hasSuffix("/download-url") {
                let format = String(path.dropFirst(prefix.count).dropLast("/download-url".count))
                let receipt = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "signedManifestReceipt" })?.value
                guard let artifact = artifacts.first(where: {
                    $0.format == format && (receipt == nil || $0.signedManifestReceipt == receipt)
                }) else { return (404, Data()) }
                var response = try! JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(artifact)
                ) as! [String: Any]
                response["url"] = "/immutable/\(artifact.sha256)"
                response["expiresAt"] = 2_000_000_000
                response["expiresInSeconds"] = 900
                return (200, try! JSONSerialization.data(withJSONObject: response))
            }
            if path == "/v1/map-jobs" {
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": []]))
            }
            if path.hasSuffix("/downloads") || path.hasSuffix("/display-name") {
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "jobId": jobID, "downloadCount": 1,
                ]))
            }
            return (404, Data())
        }
        // Each run downloads the job again, so replacements exercise the
        // real save path rather than reusing the previous pack.
        OfflineMapJobPersistence.clear(defaults: defaults)
        OfflineMapJobPersistence.save(
            jobId: jobID,
            serverURLString: serverURL,
            defaults: defaults
        )
    }

    /// Serves one catalog grant for `stream` plus an optional companion.
    func serveCatalogGrant(
        map: OfflineMapCatalogMap,
        stream: OfflineMapCatalogArtifact,
        companion: OfflineMapCatalogArtifact?
    ) {
        let libraryID = "lib_v1_" + String(repeating: "L", count: 43)
        ContourCompanionURLProtocol.configure { request in
            if request.url?.path == "/v1/libraries/bootstrap" {
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "libraryId": libraryID,
                    "credential": "cat_v1_" + String(repeating: "K", count: 43),
                ]))
            }
            guard request.url?.path == "/v1/library/maps/\(map.mapEntryId)/download-grants" else {
                return (404, Data())
            }
            var grant: [String: Any] = [
                "downloadURL": "https://\(OfflineMapCatalogConfig.developmentHost)/v1/downloads/stream",
                "expiresAt": "2030-01-01T00:00:00Z",
                "artifact": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(stream)),
            ]
            if let companion {
                grant["companion"] = [
                    "downloadURL": "https://\(OfflineMapCatalogConfig.developmentHost)/v1/downloads/companion",
                    "expiresAt": "2030-01-01T00:00:00Z",
                    "artifact": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(companion)),
                ]
            }
            return (200, try! JSONSerialization.data(withJSONObject: grant))
        }
    }

    func savedCompanion(associationID: String) -> SavedTopographyCompanionAssociation? {
        let url = cache.appendingPathComponent("topography-\(associationID).btopo")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: SavedTopographyCompanionStorage.associationURL(for: url)) else {
            return nil
        }
        return try? JSONDecoder().decode(SavedTopographyCompanionAssociation.self, from: data)
    }

    var savedCompanionFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
            .filter { $0.hasSuffix(".btopo") }
            .sorted()
    }
}

private func replacing(
    _ artifacts: [OfflineMapArtifact],
    companion transform: (OfflineMapArtifact) -> OfflineMapArtifact
) -> [OfflineMapArtifact] {
    artifacts.map { $0.isTopographyCompanion ? transform($0) : $0 }
}

private func companionArtifact(
    _ base: OfflineMapArtifact,
    sha256: String? = nil,
    intermediateSha256: String? = nil,
    objectKey: String? = nil
) -> OfflineMapArtifact {
    let digest = sha256 ?? base.sha256
    return OfflineMapArtifact(
        format: base.format,
        mediaType: base.mediaType,
        filename: base.filename,
        objectKey: objectKey ?? base.objectKey.replacingOccurrences(of: base.sha256, with: digest),
        bytes: base.bytes,
        sha256: digest,
        manifestReceipt: base.manifestReceipt,
        mapContentReceipt: base.mapContentReceipt,
        intermediateSha256: intermediateSha256 ?? base.intermediateSha256,
        sourcePolicySha256: base.sourcePolicySha256,
        attributionSha256: base.attributionSha256
    )
}

@MainActor
private func runDirectJob(
    _ scenario: ContourScenario,
    fixture: ContourFixture,
    variant: String,
    artifacts: [OfflineMapArtifact],
    payloads: [String: Data]? = nil,
    metadataSave: SavedMapArtifactMetadataSaveOperation? = nil
) async -> OfflineMapManager {
    scenario.serveJob(
        jobID: fixture.string("\(variant)_job_id"),
        mapID: fixture.string("\(variant)_map_id"),
        artifacts: artifacts
    )
    let manager = metadataSave.map {
        scenario.manager(fixture: fixture, payloads: payloads, metadataSave: $0)
    } ?? scenario.manager(fixture: fixture, payloads: payloads)
    manager.resumePendingMapJobIfNeeded()
    let finished = await waitForIdle(manager)
    check(finished, "\(variant) direct job finishes")
    return manager
}

@MainActor
private func expectReady(
    _ manager: OfflineMapManager,
    associationID: String,
    stream: String,
    _ message: String
) {
    guard case .ready(let id, _, let association) = manager.topographyCompanionSelection else {
        fail("\(message): \(manager.topographyCompanionSelection)")
    }
    check(id == associationID, "\(message): selected association")
    check(association.streamArtifactSHA256 == stream, "\(message): bound stream")
}

@main
struct OfflineMapContourCompanionTests {
    @MainActor
    static func main() async {
        let fixture = ContourFixture.load()
        await testDirectJobDeliversCombinedCompanion(fixture)
        await testDirectJobContourFreeMapNeedsNoCompanion(fixture)
        await testDirectJobRejectsInvalidCompanionSets(fixture)
        await testFailedReplacementsPreserveThePreviousPair(fixture)
        testInterruptedCompanionReplacementRecovery(fixture)
        await testCatalogDeliversCombinedCompanion(fixture)
        await testCatalogRejectsInconsistentCompanionGrants(fixture)
        testSupersededLibraryCopyPolicy()
        await testLibraryUpdateReplacesAttachedDirectJobCopy(fixture)
        await testUnsupportedSavedContourContractIsExplicit(fixture)
        print("Offline map contour companion tests passed")
    }

    @MainActor
    static func testDirectJobDeliversCombinedCompanion(_ fixture: ContourFixture) async {
        let scenario = ContourScenario("direct-combined")
        defer { scenario.cleanup() }
        let associationID = "job_v1_\(fixture.string("combined_job_id"))"
        let stream = fixture.stream("combined").sha256
        let manager = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: fixture.artifacts("combined")
        )
        check(manager.errorMessage == nil, "combined job downloads: \(manager.errorMessage ?? "")")
        guard let packURL = manager.downloadedPackURL,
              var metadata = SavedMapArtifactMetadataStore.load(for: packURL) else {
            fail("combined job saves its signed stream")
        }
        check(metadata.rendererFormatVersion == 5, "combined map is renderer target 5")
        check(metadata.topography != nil, "signed manifest declares the contours layer")
        guard let association = scenario.savedCompanion(associationID: associationID) else {
            fail("a combined POI+contour job saves its matching iPhone companion")
        }
        check(association.streamArtifactSHA256 == stream, "the companion is bound to the exact saved stream")
        check(
            association.receipt.sha256 == fixture.companion("combined")!.sha256,
            "the saved companion is the generated companion"
        )
        check(metadata.topographyCompanion == association.receipt, "the saved map records its companion")
        let contentReceipt = fixture.artifacts("combined").first(where: \.isStoredZip)!.manifestReceipt
        check(
            association.receipt.mapContentReceipt == contentReceipt,
            "the companion is bound to the job's map content receipt"
        )
        expectReady(manager, associationID: associationID, stream: stream, "downloaded companion is selected")

        // Reopening the app keeps the association.
        let relaunched = scenario.manager(fixture: fixture)
        expectReady(relaunched, associationID: associationID, stream: stream, "relaunch keeps the companion")

        // Display switches act on downloaded layers only.
        let requestsBeforeToggle = ContourCompanionURLProtocol.requestPaths.count
        relaunched.topographicMapsEnabled = false
        relaunched.topographicMapsEnabled = true
        check(
            ContourCompanionURLProtocol.requestPaths.count == requestsBeforeToggle,
            "contour display switches never contact the map service"
        )
        expectReady(relaunched, associationID: associationID, stream: stream, "display switch keeps the companion")

        // Later library attachment cannot re-key which companion belongs here.
        metadata.catalogMapEntryID = "map_v1_" + String(repeating: "A", count: 43)
        try! SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        let attached = scenario.manager(fixture: fixture)
        expectReady(attached, associationID: associationID, stream: stream, "catalog attachment keeps the companion")

        // Deleting the map removes exactly its companion.
        attached.deleteCachedPack(at: packURL)
        check(scenario.savedCompanionFiles.isEmpty, "deleting a contour map deletes its companion")
        check(attached.topographyCompanionSelection == .none, "no contour map remains")
    }

    @MainActor
    static func testDirectJobContourFreeMapNeedsNoCompanion(_ fixture: ContourFixture) async {
        let scenario = ContourScenario("direct-plain")
        defer { scenario.cleanup() }
        let manager = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "plain",
            artifacts: fixture.artifacts("plain")
        )
        check(manager.errorMessage == nil, "contour-free job downloads: \(manager.errorMessage ?? "")")
        guard let packURL = manager.downloadedPackURL,
              let metadata = SavedMapArtifactMetadataStore.load(for: packURL) else {
            fail("contour-free job saves its stream")
        }
        check(metadata.topography == nil, "contour-free map declares no contours")
        check(metadata.topographyCompanion == nil, "contour-free map records no companion")
        check(scenario.savedCompanionFiles.isEmpty, "contour-free map saves no companion")
        check(manager.topographyCompanionSelection == .none, "a contour-free map needs no companion")
    }

    @MainActor
    static func testDirectJobRejectsInvalidCompanionSets(_ fixture: ContourFixture) async {
        let combined = fixture.artifacts("combined")
        let companion = fixture.companion("combined")!
        let tampered: [String: Data] = {
            var payloads = fixture.payloads()
            var bytes = payloads[companion.sha256]!
            bytes[bytes.count - 1] ^= 0xff
            payloads[companion.sha256] = bytes
            return payloads
        }()
        let cases: [(String, String, [OfflineMapArtifact], [String: Data]?, OfflineMapTopographyCompanionError)] = [
            ("missing", "combined", combined.filter { !$0.isTopographyCompanion }, nil, .missing),
            ("undeclared", "plain", fixture.artifacts("plain") + [companion], nil, .undeclared),
            ("duplicate", "combined", combined + [companionArtifact(
                companion, sha256: String(repeating: "4", count: 64)
            )], nil, .ambiguous),
            ("mismatched", "combined", replacing(combined) {
                companionArtifact($0, intermediateSha256: String(repeating: "5", count: 64))
            }, nil, .mismatched),
            ("foreign-object", "combined", replacing(combined) {
                companionArtifact($0, objectKey: "maps/other/topography-ios-v1/\($0.mapContentReceipt!)/\($0.sha256).btopo")
            }, nil, .mismatched),
            ("tampered", "combined", combined, tampered, .unverified),
        ]
        for (name, variant, artifacts, payloads, expected) in cases {
            let scenario = ContourScenario("direct-\(name)")
            defer { scenario.cleanup() }
            let manager = await runDirectJob(
                scenario,
                fixture: fixture,
                variant: variant,
                artifacts: artifacts,
                payloads: payloads
            )
            check(
                manager.errorMessage?.contains(expected.errorDescription!) == true,
                "\(name) companion set fails clearly: \(manager.errorMessage ?? "no error")"
            )
            check(manager.cachedPackURLs.isEmpty, "\(name) companion set saves no map")
            check(scenario.savedCompanionFiles.isEmpty, "\(name) companion set saves no companion")
        }
    }

    @MainActor
    static func testFailedReplacementsPreserveThePreviousPair(_ fixture: ContourFixture) async {
        let scenario = ContourScenario("direct-replacement")
        defer { scenario.cleanup() }
        let associationID = "job_v1_\(fixture.string("combined_job_id"))"
        let original = fixture.stream("combined")
        let restamped = fixture.restampedStream
        let initial = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: fixture.artifacts("combined")
        )
        check(initial.errorMessage == nil, "initial combined map installs")
        let restampedArtifacts = fixture.artifacts("combined").map {
            $0.isBikeMapStream ? restamped : $0
        }

        func expectOriginalPair(_ message: String) {
            let packURL = scenario.cache.appendingPathComponent("\(fixture.string("combined_map_id")).bmap")
            check(
                SavedMapArtifactMetadataStore.load(for: packURL)?.primaryArtifact?.sha256 == original.sha256,
                "\(message): previous map remains"
            )
            check(
                scenario.savedCompanion(associationID: associationID)?.streamArtifactSHA256 == original.sha256,
                "\(message): previous companion binding remains"
            )
            let relaunched = scenario.manager(fixture: fixture)
            expectReady(relaunched, associationID: associationID, stream: original.sha256, message)
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: scenario.cache.path)) ?? [])
                .filter { $0.contains(".backup") || $0.hasSuffix(".topography-replacement.json") }
            check(leftovers.isEmpty, "\(message): no replacement residue \(leftovers)")
        }

        // A replacement whose companion fails verification never touches the pair.
        var tampered = fixture.payloads()
        var bytes = tampered[fixture.companion("combined")!.sha256]!
        bytes[100] ^= 0xff
        tampered[fixture.companion("combined")!.sha256] = bytes
        let rejected = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: restampedArtifacts,
            payloads: tampered
        )
        check(rejected.errorMessage != nil, "tampered replacement fails")
        expectOriginalPair("tampered replacement")

        // A map replacement that fails after the companion was staged restores
        // the previous companion with the previous map.
        struct InterruptedSave: Error {}
        let interrupted = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: restampedArtifacts,
            metadataSave: { _, _ in throw InterruptedSave() }
        )
        check(interrupted.errorMessage != nil, "interrupted replacement fails")
        expectOriginalPair("interrupted replacement")

        // The same replacement succeeds as one unit.
        let replaced = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: restampedArtifacts
        )
        check(replaced.errorMessage == nil, "replacement succeeds: \(replaced.errorMessage ?? "")")
        expectReady(replaced, associationID: associationID, stream: restamped.sha256, "replacement rebinds the companion")
    }

    /// Recovery after process termination between the map and companion
    /// commits keeps the companion that matches the saved map.
    @MainActor
    static func testInterruptedCompanionReplacementRecovery(_ fixture: ContourFixture) {
        let companionData = fixture.bytes("combined_companion_hex")
        let receipt = TopographyCompanionReceipt(
            mapEntryID: "job_v1_recovery",
            mapContentReceipt: fixture.companion("combined")!.mapContentReceipt!,
            mapID: fixture.string("combined_map_id"),
            sha256: fixture.companion("combined")!.sha256,
            bytes: Int64(companionData.count),
            intermediateSha256: fixture.companion("combined")!.intermediateSha256!,
            sourcePolicySha256: fixture.companion("combined")!.sourcePolicySha256!,
            attributionSha256: fixture.companion("combined")!.attributionSha256!
        )
        func association(_ stream: String) -> SavedTopographyCompanionAssociation {
            SavedTopographyCompanionAssociation(
                schemaVersion: SavedTopographyCompanionAssociation.currentSchemaVersion,
                localArtifactFilename: "topography-job_v1_recovery.btopo",
                streamArtifactSHA256: stream,
                receipt: receipt
            )
        }
        let oldStream = String(repeating: "a", count: 64)
        let newStream = String(repeating: "b", count: 64)
        func saveMap(_ mapURL: URL, stream: String) {
            try! Data([1]).write(to: mapURL)
            try! SavedMapArtifactMetadataStore.save(SavedMapArtifactMetadata(
                schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
                mapID: "recovery",
                displayName: nil,
                localArtifactFilename: mapURL.lastPathComponent,
                streamFormatVersion: 1,
                rendererFormatVersion: 5,
                jobID: nil,
                serverURLString: nil,
                clientInstallationID: nil,
                primaryArtifact: OfflineMapArtifact(
                    format: OfflineMapArtifact.bikeMapStreamFormat,
                    mediaType: "application/vnd.openbikecomputer.map-stream",
                    filename: "recovery.bmap",
                    objectKey: "maps/recovery/bike-map-stream-v1/key/recovery.bmap",
                    bytes: 1,
                    sha256: stream
                ),
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
                expectedActiveMapID: nil,
                expectedActiveSessionID: nil,
                lastTransferOutcome: nil
            ), for: mapURL)
        }
        enum MapState { case saved, uncommittedReplacement, unreadableJournal }
        for (savedStream, staged, mapState, expectedStream) in [
            (newStream, true, MapState.saved, newStream),   // map committed: roll forward
            (oldStream, true, .saved, oldStream),           // map rolled back: restore
            (newStream, false, .saved, oldStream),          // staging incomplete: restore
            // New metadata is written but its map journal never committed:
            // the map rolls back first, so the companion must too.
            (oldStream, true, .uncommittedReplacement, oldStream),
            // Map recovery cannot run: companion journals stay untouched.
            (oldStream, true, .unreadableJournal, newStream),
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("contour-recovery-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let companionURL = directory.appendingPathComponent("topography-job_v1_recovery.btopo")
            try! companionData.write(to: companionURL)
            try! SavedTopographyCompanionStorage.save(association(oldStream), for: companionURL)
            let mapURL = directory.appendingPathComponent("recovery.bmap")
            saveMap(mapURL, stream: savedStream)
            if mapState == .uncommittedReplacement {
                let mapJournal = try! SavedMapReplacementJournal.begin(at: mapURL)
                let mapBackup = mapJournal.backup(in: directory)
                try! FileManager.default.moveItem(at: mapURL, to: mapBackup)
                try! FileManager.default.moveItem(
                    at: SavedMapArtifactMetadataStore.metadataURL(for: mapURL),
                    to: SavedMapArtifactMetadataStore.metadataURL(for: mapBackup)
                )
                saveMap(mapURL, stream: newStream)
            }
            let unreadableJournal = directory.appendingPathComponent(".other.bmap.replacement.json")
            if mapState == .unreadableJournal {
                try! Data(repeating: 0x20, count: 8192).write(to: unreadableJournal)
            }
            var journal = try! SavedTopographyCompanionReplacementJournal.begin(
                at: companionURL,
                mapArtifactFilename: mapURL.lastPathComponent,
                streamArtifactSHA256: newStream
            )
            let backup = journal.backup(in: directory)
            try! FileManager.default.moveItem(at: companionURL, to: backup)
            try! FileManager.default.moveItem(
                at: SavedTopographyCompanionStorage.associationURL(for: companionURL),
                to: SavedTopographyCompanionStorage.associationURL(for: backup)
            )
            if staged {
                try! companionData.write(to: companionURL)
                try! SavedTopographyCompanionStorage.save(association(newStream), for: companionURL)
                journal.staged = true
                try! journal.save(in: directory)
            }
            if mapState == .unreadableJournal {
                check(
                    (try? SavedTopographyCompanionReplacementJournal.recoverBoundToSavedMaps(in: directory)) == nil,
                    "an unreadable map journal stops companion recovery"
                )
                check(
                    FileManager.default.fileExists(atPath: journal.url(in: directory).path) &&
                        FileManager.default.fileExists(atPath: backup.path),
                    "companion journal and previous companion stay for a later recovery"
                )
                continue
            }
            try! SavedTopographyCompanionReplacementJournal.recoverBoundToSavedMaps(in: directory)
            check(
                SavedMapArtifactMetadataStore.load(for: mapURL)?.primaryArtifact?.sha256 == savedStream,
                "map recovery settles the saved map first"
            )
            let recovered = try? JSONDecoder().decode(
                SavedTopographyCompanionAssociation.self,
                from: Data(contentsOf: SavedTopographyCompanionStorage.associationURL(for: companionURL))
            )
            check(
                recovered?.streamArtifactSHA256 == expectedStream,
                "recovery for saved stream \(savedStream.prefix(1)) staged=\(staged) keeps \(expectedStream.prefix(1))"
            )
            check(
                FileManager.default.fileExists(atPath: companionURL.path),
                "recovery leaves exactly one companion file"
            )
            let leftovers = (try! FileManager.default.contentsOfDirectory(atPath: directory.path))
                .filter { $0.contains(".backup") || $0.hasSuffix("replacement.json") }
            check(leftovers.isEmpty, "recovery removes replacement residue \(leftovers)")
        }
    }

    @MainActor
    static func testCatalogDeliversCombinedCompanion(_ fixture: ContourFixture) async {
        for variant in ["combined", "plain"] {
            let scenario = ContourScenario(
                "catalog-\(variant)",
                serverURL: OfflineMapServiceConfig.developmentServerURLString
            )
            defer { scenario.cleanup() }
            let map = fixture.catalogMap(variant)
            let stream = map.artifacts.first { $0.platformArtifact.isBikeMapStream }!
            let companion = map.artifacts.first { $0.platformArtifact.isTopographyCompanion }
            scenario.serveCatalogGrant(map: map, stream: stream, companion: companion)
            let manager = scenario.manager(fixture: fixture)
            check(manager.catalogAvailability(for: map).canDownload, "\(variant) catalog map is downloadable")
            manager.downloadCatalogMap(map)
            let finished = await waitForIdle(manager)
            check(finished, "\(variant) catalog download finishes")
            check(manager.errorMessage == nil, "\(variant) catalog map downloads: \(manager.errorMessage ?? "")")
            guard let packURL = manager.downloadedPackURL,
                  let metadata = SavedMapArtifactMetadataStore.load(for: packURL) else {
                fail("\(variant) catalog map is saved")
            }
            guard let companion else {
                check(metadata.topography == nil, "contour-free catalog map declares no contours")
                check(scenario.savedCompanionFiles.isEmpty, "contour-free catalog map saves no companion")
                check(manager.topographyCompanionSelection == .none, "contour-free catalog map needs no companion")
                continue
            }
            guard let association = scenario.savedCompanion(associationID: map.mapEntryId) else {
                fail("a combined catalog map saves its granted companion")
            }
            check(association.receipt.sha256 == companion.sha256, "catalog companion is the granted artifact")
            check(association.streamArtifactSHA256 == stream.sha256, "catalog companion is bound to the saved stream")
            check(association.receipt.mapContentReceipt == map.contentReceipt, "catalog companion is bound to the entry content")
            check(metadata.topographyCompanion == association.receipt, "catalog map records its companion")
            let relaunched = scenario.manager(fixture: fixture)
            expectReady(relaunched, associationID: map.mapEntryId, stream: stream.sha256, "catalog import survives relaunch")
        }
    }

    @MainActor
    static func testCatalogRejectsInconsistentCompanionGrants(_ fixture: ContourFixture) async {
        let combined = fixture.catalogMap("combined")
        let plain = fixture.catalogMap("plain")
        let combinedCompanion = combined.artifacts.first { $0.platformArtifact.isTopographyCompanion }!
        let cases: [(String, OfflineMapCatalogMap, OfflineMapCatalogArtifact?, OfflineMapTopographyCompanionError)] = [
            ("missing", combined, nil, .missing),
            ("undeclared", plain, combinedCompanion, .undeclared),
        ]
        for (name, map, companion, expected) in cases {
            let scenario = ContourScenario(
                "catalog-\(name)",
                serverURL: OfflineMapServiceConfig.developmentServerURLString
            )
            defer { scenario.cleanup() }
            let stream = map.artifacts.first { $0.platformArtifact.isBikeMapStream }!
            scenario.serveCatalogGrant(map: map, stream: stream, companion: companion)
            let manager = scenario.manager(fixture: fixture)
            manager.downloadCatalogMap(map)
            let finished = await waitForIdle(manager)
            check(finished, "\(name) catalog grant finishes")
            check(
                manager.errorMessage?.contains(expected.errorDescription!) == true,
                "\(name) catalog grant fails clearly: \(manager.errorMessage ?? "no error")"
            )
            check(manager.cachedPackURLs.isEmpty, "\(name) catalog grant saves no map")
            check(scenario.savedCompanionFiles.isEmpty, "\(name) catalog grant saves no companion")
        }
    }

    /// Only another saved copy of the same library entry is superseded, and a
    /// copy that anything still uses stays.
    static func testSupersededLibraryCopyPolicy() {
        func record(_ filename: String, entry: String?) -> SavedMapLocalRecord {
            SavedMapLocalRecord(
                packURL: URL(fileURLWithPath: "/maps/\(filename)"),
                mapID: "map",
                acceptedSessionIDs: [],
                displayName: filename,
                catalogMapEntryID: entry
            )
        }
        let jobCopy = record("map.bmap", entry: "entry")
        let records = [
            record("catalog-entry.bmap", entry: "entry"),
            jobCopy,
            record("other.bmap", entry: "other"),
            record("unattached.bmap", entry: nil),
        ]
        func retirable(_ usage: SupersededLibraryCopyPolicy.Usage) -> [URL] {
            SupersededLibraryCopyPolicy.retirableCopies(
                of: "entry",
                keeping: URL(fileURLWithPath: "/maps/./catalog-entry.bmap"),
                in: records,
                usage: usage
            )
        }
        check(retirable(.init()) == [jobCopy.packURL],
              "only the entry's other copy is superseded: \(retirable(.init()))")
        check(retirable(.init(transferRunning: true)).isEmpty,
              "nothing is removed while a transfer runs")
        check(retirable(.init(operationFilenames: ["map.bmap"])).isEmpty,
              "an unfinished device operation keeps its copy")
        check(retirable(.init(pausedUploadFilenames: ["map.bmap"])).isEmpty,
              "a paused upload keeps its copy")
        check(retirable(.init(pendingInstallFilename: "map.bmap")).isEmpty,
              "a direct job waiting to install keeps its copy")
        for outcome in ["preparing", "uploading", "activating", "unconfirmed", "a-later-state"] {
            check(retirable(.init(lastTransferFilename: "map.bmap", lastTransferOutcome: outcome)).isEmpty,
                  "the last transfer keeps its copy while \(outcome)")
            check(retirable(.init(lastTransferFilename: "other.bmap", lastTransferOutcome: outcome)) ==
                    [jobCopy.packURL],
                  "another file's \(outcome) transfer does not keep this copy")
        }
        for outcome in ["", "installed", "failed", "cancelled", "unknown"] {
            check(retirable(.init(lastTransferFilename: "map.bmap", lastTransferOutcome: outcome)) ==
                    [jobCopy.packURL],
                  "a settled '\(outcome)' transfer no longer keeps its copy")
        }
    }

    /// Updating a direct-job map from its library entry leaves one saved copy:
    /// the library download replaces the attached direct-job file and its
    /// companion, unless an activation or a device install still waits on it.
    @MainActor
    static func testLibraryUpdateReplacesAttachedDirectJobCopy(_ fixture: ContourFixture) async {
        let map = fixture.catalogMap("combined")
        let stream = map.artifacts.first { $0.platformArtifact.isBikeMapStream }!
        let companion = map.artifacts.first { $0.platformArtifact.isTopographyCompanion }!
        let jobID = fixture.string("combined_job_id")
        for state in ["idle", "awaiting activation", "pending install"] {
            let kept = state != "idle"
            let scenario = ContourScenario("library-update-\(state.replacingOccurrences(of: " ", with: "-"))")
            defer { scenario.cleanup() }
            let jobManager = await runDirectJob(
                scenario,
                fixture: fixture,
                variant: "combined",
                artifacts: fixture.artifacts("combined")
            )
            guard let jobCopy = jobManager.downloadedPackURL,
                  var metadata = SavedMapArtifactMetadataStore.load(for: jobCopy) else {
                fail("\(state): the direct job is saved")
            }
            // As inventory sync records the job's library entry.
            metadata.catalogMapEntryID = map.mapEntryId
            metadata.catalogSyncState = "synced"
            try! SavedMapArtifactMetadataStore.save(metadata, for: jobCopy)
            if state == "awaiting activation" {
                // The job copy was uploaded to the bike before a relaunch, and
                // its activation is not confirmed yet.
                let sessionID = "session-awaiting-activation"
                let descriptor = BackgroundMapUploadDescriptor(
                    mapID: map.mapId,
                    sessionID: sessionID,
                    protocolVersion: 2,
                    streamFormatVersion: 1,
                    artifactFilename: jobCopy.lastPathComponent
                )
                BackgroundMapUploadStateStore.markStarted(
                    taskID: 7, descriptor: descriptor, defaults: scenario.defaults
                )
                BackgroundMapUploadStateStore.markCompleted(
                    taskID: 7, succeeded: true, errorCode: nil, defaults: scenario.defaults
                )
                scenario.defaults.set(map.mapId, forKey: "offlineMap.lastTransfer.mapId")
                scenario.defaults.set("activating", forKey: "offlineMap.lastTransfer.outcome")
                scenario.defaults.set(sessionID, forKey: "offlineMap.lastTransfer.sessionId")
                scenario.defaults.set(
                    jobCopy.lastPathComponent,
                    forKey: "offlineMap.lastTransfer.artifactFilename"
                )
            } else if state == "pending install" {
                // The job was created to install on the bike, which has not
                // accepted it yet; the job stays active until it does.
                OfflineMapJobPersistence.save(
                    jobId: jobID,
                    installOnDevice: true,
                    serverURLString: scenario.serverURL,
                    defaults: scenario.defaults
                )
                OfflineMapJobPersistence.markPackDownloaded(
                    jobId: jobID, mapId: map.mapId, defaults: scenario.defaults
                )
            }
            // Relaunch on the development generation server, whose catalog
            // channel downloads this development-tier library entry.
            scenario.defaults.set(
                OfflineMapServiceConfig.developmentServerURLString,
                forKey: "offlineMap.serverURL"
            )
            scenario.serveCatalogGrant(map: map, stream: stream, companion: companion)
            let manager = scenario.manager(fixture: fixture)
            check(manager.isAwaitingMapActivationConfirmation(jobCopy) == (state == "awaiting activation"),
                  "\(state): activation state of the job copy")
            check(manager.hasDownloadedPendingDeviceInstall == (state == "pending install"),
                  "\(state): pending device install before the update")
            manager.downloadCatalogMap(map)
            let finished = await waitForIdle(manager)
            check(finished, "\(state): library update finishes")
            check(manager.errorMessage == nil,
                  "\(state): library update downloads: \(manager.errorMessage ?? "")")
            guard let libraryCopy = manager.downloadedPackURL,
                  libraryCopy != jobCopy else {
                fail("\(state): the library copy is saved")
            }
            check(FileManager.default.fileExists(atPath: jobCopy.path) == kept,
                  "\(state): the direct-job copy is replaced only when nothing uses it")
            check(manager.hasDownloadedPendingDeviceInstall == (state == "pending install"),
                  "\(state): a pending device install survives the update")
            let entryRows = manager.savedMapListItems(activeDeviceMap: nil).filter {
                $0.localRecord?.catalogMapEntryID == map.mapEntryId
            }
            check(entryRows.count == (kept ? 2 : 1),
                  "\(state): Saved Maps rows for the entry: \(entryRows.map(\.id))")
            check(entryRows.contains {
                    $0.packURL?.standardizedFileURL.path == libraryCopy.standardizedFileURL.path &&
                        $0.catalogMap != nil
                  },
                  "\(state): the library copy is the library row: " +
                    "\(entryRows.map { "\($0.id) library=\($0.catalogMap != nil)" }), " +
                    "saved \(libraryCopy.path)")
            let jobCompanion = "topography-job_v1_\(jobID).btopo"
            check(scenario.savedCompanionFiles.contains(jobCompanion) == kept,
                  "\(state): the job companion goes with its map: \(scenario.savedCompanionFiles)")
            expectReady(manager, associationID: map.mapEntryId, stream: stream.sha256,
                        "\(state): the library copy keeps its own companion")
        }
    }

    /// Contour maps saved before the companion receipt was part of saved map
    /// metadata are not adapted; they ask for a fresh download.
    @MainActor
    static func testUnsupportedSavedContourContractIsExplicit(_ fixture: ContourFixture) async {
        let scenario = ContourScenario("old-contract")
        defer { scenario.cleanup() }
        let manager = await runDirectJob(
            scenario,
            fixture: fixture,
            variant: "combined",
            artifacts: fixture.artifacts("combined")
        )
        guard let packURL = manager.downloadedPackURL,
              var metadata = SavedMapArtifactMetadataStore.load(for: packURL) else {
            fail("combined map installs before contract downgrade")
        }
        metadata.topographyCompanion = nil
        try! SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        let relaunched = scenario.manager(fixture: fixture)
        check(
            relaunched.topographyCompanionSelection == .unavailable(mapID: metadata.mapID),
            "an old saved contour contract asks for a fresh download"
        )
    }
}
