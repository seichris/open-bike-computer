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

/// The contour map of the frozen durable-map corpus
/// (map-platform/backend/tests/fixtures/map-compatibility-v1): a development
/// and a production copy signed by different keys, each with its companion.
private struct CompatibilityCorpusContours {
    static let directory = "map-platform/backend/tests/fixtures/map-compatibility-v1/"
    /// Bicino Dev trusts every corpus signer.
    let appTrust: BikeMapStreamTrustStore
    /// The `streamTrust` that production and ordinary firmware report.
    let productionSigners: [String]
    let map: OfflineMapCatalogMap
    let payloads: [String: Data]

    static func load() -> Self {
        func file(_ name: String) -> Data {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: directory + name)) else {
                fail("compatibility corpus has \(name)")
            }
            return data
        }
        guard let root = try? JSONSerialization.jsonObject(with: file("corpus.json")) as? [String: Any],
              let signers = root["signers"] as? [[String: String]],
              let entry = (root["maps"] as? [[String: Any]])?.first(where: {
                  $0["id"] as? String == "topographic-contours-v1"
              }),
              let mapID = entry["mapId"] as? String,
              let companionFile = entry["companionFile"] as? String,
              let development = entry["development"] as? [String: Any],
              let production = (entry["production"] as? [[String: Any]])?.first(where: {
                  $0["variant"] as? String == "production"
              }),
              let publication = development["publication"] as? [String: Any] else {
            fail("compatibility corpus contour map decodes")
        }
        var keys: [String: Data] = [:]
        for signer in signers {
            guard let keyID = signer["keyId"],
                  let key = signer["publicKeyX963Hex"].flatMap(Data.init(ownershipHex:)) else {
                fail("compatibility corpus signer decodes")
            }
            keys[keyID] = key
        }
        let appTrust = BikeMapStreamTrustStore(publicKeysByID: keys)
        let companion = file(companionFile)
        var artifacts: [[String: Any]] = []
        var payloads: [String: Data] = [:]
        for variant in [development, production] {
            guard let name = variant["file"] as? String,
                  let list = (variant["publication"] as? [String: Any])?["artifacts"] as? [[String: Any]] else {
                fail("compatibility corpus publication decodes")
            }
            for artifact in list where artifact["format"] as? String != OfflineMapArtifact.storedZipFormat {
                guard let sha256 = artifact["sha256"] as? String else {
                    fail("compatibility corpus artifact has a digest")
                }
                artifacts.append(artifact)
                payloads[sha256] = artifact["format"] as? String == OfflineMapArtifact.bikeMapStreamFormat
                    ? file(name) : companion
            }
        }
        let map: [String: Any] = [
            "mapEntryId": publication["mapEntryId"] as Any,
            "mapId": mapID,
            "contentReceipt": publication["contentReceipt"] as Any,
            "alias": "Durable contours",
            "aliasSource": "generated",
            "aliasRevision": 1,
            "canonicalName": publication["canonicalName"] as Any,
            "originChannel": "development",
            "renderer": publication["renderer"] as Any,
            "rendererFormatVersion": publication["rendererFormatVersion"] as Any,
            "features": publication["features"] as Any,
            "deliveryState": "production",
            "addedAt": "2026-10-26T00:00:00Z",
            "updatedAt": "2026-10-26T00:00:00Z",
            "artifacts": artifacts,
        ]
        guard let decoded = try? JSONDecoder().decode(
            OfflineMapCatalogMap.self,
            from: JSONSerialization.data(withJSONObject: map)
        ) else {
            fail("compatibility corpus library map decodes")
        }
        return Self(
            appTrust: appTrust,
            productionSigners: signers
                .filter { $0["channel"] == "production" }
                .compactMap { $0["keyId"] }
                .sorted()
                .compactMap(appTrust.capability(for:)),
            map: decoded,
            payloads: payloads
        )
    }
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

    /// URLSession hands protocol classes a request body as a stream.
    static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
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
        trustStore: BikeMapStreamTrustStore? = nil,
        metadataSave: @escaping SavedMapArtifactMetadataSaveOperation = { metadata, url in
            try SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    ) -> OfflineMapManager {
        let payloads = payloads ?? fixture.payloads()
        return OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            cacheDirectory: cache,
            mapStreamTrustStore: trustStore ?? fixture.trustStore,
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
        serveCatalogGrants(map: map) { _ in (stream, companion) }
    }

    /// Serves each catalog grant that `choose` picks from the request's
    /// accepted `keyId=keySha256` signers; nil answers like the Worker's 409.
    func serveCatalogGrants(
        map: OfflineMapCatalogMap,
        choose: @escaping ([String]) -> (OfflineMapCatalogArtifact, OfflineMapCatalogArtifact?)?
    ) {
        let libraryID = "lib_v1_" + String(repeating: "L", count: 43)
        ContourCompanionURLProtocol.configure { request in
            if request.url?.path == "/v1/libraries/bootstrap" {
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "libraryId": libraryID,
                    "credential": "cat_v1_" + String(repeating: "K", count: 43),
                ]))
            }
            guard request.url?.path == "/v1/library/maps/\(map.mapEntryId)/download-grants",
                  let body = try? JSONSerialization.jsonObject(
                    with: ContourCompanionURLProtocol.bodyData(from: request)
                  ) as? [String: Any],
                  let accepted = body["acceptedSigners"] as? [[String: String]] else {
                return (404, Data())
            }
            guard let (stream, companion) = choose(accepted.map {
                "\($0["keyId"] ?? "")=\($0["keySha256"] ?? "")"
            }) else {
                return (409, Data(#"{"error":"no compatible artifact is available"}"#.utf8))
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
        await testCatalogDownloadFollowsBikeTrust(fixture)
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
            manager.downloadCatalogMap(map, deviceStreamTrust: nil)
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
            manager.downloadCatalogMap(map, deviceStreamTrust: nil)
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

    /// Bicino Dev trusts development and production signers; production and
    /// ordinary firmware only production ones. The grant asks only for signers
    /// the connected bike trusts while the library has such a copy, so Bicino
    /// Dev saves the production copy and its companion for stock firmware.
    /// While no bike reports, the saved copy is judged and updated for the
    /// bike it was chosen for.
    @MainActor
    static func testCatalogDownloadFollowsBikeTrust(_ fixture: ContourFixture) async {
        let corpus = CompatibilityCorpusContours.load()
        func stream(_ tier: String) -> OfflineMapCatalogArtifact {
            corpus.map.artifacts.first { $0.platformArtifact.isBikeMapStream && $0.deliveryTier == tier }!
        }
        func companion(_ tier: String) -> OfflineMapCatalogArtifact? {
            corpus.map.artifacts.first { $0.platformArtifact.isTopographyCompanion && $0.deliveryTier == tier }
        }
        let everySigner = corpus.appTrust.capabilityHeaderValue?
            .split(separator: ",").map(String.init) ?? []
        // Whether Saved Maps offers an update with no bike, a stock bike and a
        // bike that trusts the development key connected.
        let cases: [(
            bike: String, trust: [String]?, requested: [String], tier: String,
            refresh: (none: Bool, stock: Bool, development: Bool)
        )] = [
            ("unreported", nil, everySigner, "development", (false, true, false)),
            ("development", everySigner, everySigner, "development", (false, true, false)),
            ("stock", corpus.productionSigners, corpus.productionSigners, "production",
             (false, false, true)),
        ]
        for item in cases {
            let scenario = ContourScenario(
                "bike-trust-\(item.bike)",
                serverURL: OfflineMapServiceConfig.developmentServerURLString
            )
            defer { scenario.cleanup() }
            var requests: [[String]] = []
            // As the Worker does: development first, then production, taking
            // the first copy whose signer the request accepts.
            scenario.serveCatalogGrants(map: corpus.map) { accepted in
                requests.append(accepted)
                guard let tier = ["development", "production"].first(where: { tier in
                    let candidate = stream(tier)
                    return accepted.contains(
                        "\(candidate.signatureKeyId ?? "")=\(candidate.signatureKeySha256 ?? "")"
                    )
                }) else {
                    return nil
                }
                return (stream(tier), companion(tier))
            }
            let manager = scenario.manager(
                fixture: fixture,
                payloads: corpus.payloads,
                trustStore: corpus.appTrust
            )
            manager.downloadCatalogMap(corpus.map, deviceStreamTrust: item.trust)
            let finished = await waitForIdle(manager)
            check(finished, "\(item.bike) bike: catalog download finishes")
            check(manager.errorMessage == nil,
                  "\(item.bike) bike: catalog map downloads: \(manager.errorMessage ?? "")")
            check(requests == [item.requested],
                  "\(item.bike) bike: grant requests \(item.requested), not \(requests)")
            guard let packURL = manager.downloadedPackURL,
                  let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
                  let association = scenario.savedCompanion(associationID: corpus.map.mapEntryId) else {
                fail("\(item.bike) bike: catalog map and companion are saved")
            }
            check(metadata.primaryArtifact?.sha256 == stream(item.tier).sha256,
                  "\(item.bike) bike: saves the \(item.tier) copy")
            check(association.streamArtifactSHA256 == stream(item.tier).sha256,
                  "\(item.bike) bike: companion is bound to the \(item.tier) copy")
            guard let row = manager.savedMapListItems(activeDeviceMap: nil).first(where: {
                $0.catalogMap?.mapEntryId == corpus.map.mapEntryId
            }) else {
                fail("\(item.bike) bike: the saved copy is a library row")
            }
            check(manager.catalogArtifactNeedsRefresh(for: row, deviceStreamTrust: nil) ==
                    item.refresh.none,
                  "\(item.bike) bike: update offer with no bike connected")
            check(manager.catalogArtifactNeedsRefresh(
                    for: row, deviceStreamTrust: corpus.productionSigners
                  ) == item.refresh.stock,
                  "\(item.bike) bike: update offer on stock firmware")
            check(manager.catalogArtifactNeedsRefresh(for: row, deviceStreamTrust: everySigner) ==
                    item.refresh.development,
                  "\(item.bike) bike: update offer on development firmware")

            // An update with no bike connected keeps choosing for that bike.
            manager.downloadCatalogMap(corpus.map, deviceStreamTrust: nil)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, manager.isBusy || ContourCompanionURLProtocol.requestPaths
                .filter({ $0.hasSuffix("/download-grants") }).count < 2 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(manager.errorMessage == nil,
                  "\(item.bike) bike: update downloads: \(manager.errorMessage ?? "")")
            check(requests == [item.requested, item.requested],
                  "\(item.bike) bike: update requests \(item.requested) again: \(requests)")
            check(manager.downloadedPackURL.flatMap(SavedMapArtifactMetadataStore.load(for:))?
                    .primaryArtifact?.sha256 == stream(item.tier).sha256,
                  "\(item.bike) bike: update keeps the \(item.tier) copy")
        }

        // A grant outside the signers the bike trusts is refused before download.
        let scenario = ContourScenario(
            "bike-trust-refused",
            serverURL: OfflineMapServiceConfig.developmentServerURLString
        )
        defer { scenario.cleanup() }
        scenario.serveCatalogGrant(
            map: corpus.map,
            stream: stream("development"),
            companion: companion("development")
        )
        let manager = scenario.manager(
            fixture: fixture,
            payloads: corpus.payloads,
            trustStore: corpus.appTrust
        )
        manager.downloadCatalogMap(corpus.map, deviceStreamTrust: corpus.productionSigners)
        let finished = await waitForIdle(manager)
        check(finished, "an untrusted grant finishes")
        check(
            manager.errorMessage?.contains(
                OfflineMapCatalogError.missingCompatibleArtifact.errorDescription!
            ) == true,
            "a grant the bike cannot install is refused: \(manager.errorMessage ?? "no error")"
        )
        check(manager.cachedPackURLs.isEmpty, "an untrusted grant saves no map")
        check(scenario.savedCompanionFiles.isEmpty, "an untrusted grant saves no companion")
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
