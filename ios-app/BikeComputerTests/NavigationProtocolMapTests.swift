import Foundation
import CoreLocation
import CoreBluetooth
import CryptoKit
import MapKit
#if os(iOS)
import NetworkExtension
#endif

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}

private final class MapOperationRecoveryTestBLEManager: BLEManager {
    var recoveryDeviceID: String?
    var requestedOperationIDs: [String] = []

    override var activeDeviceID: String? {
        get { recoveryDeviceID }
        set { recoveryDeviceID = newValue }
    }

    override func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    override func requestMapOperationStatus(operationID: String) -> Bool {
        requestedOperationIDs.append(operationID)
        return true
    }
}


extension NavigationProtocolTests {
    static func testOfflineMapJobRecoverySelection() {
        let jobs = [
            offlineMapJob(
                jobId: "job-other",
                status: "converting_features",
                createdAt: "2026-07-12T01:00:00Z",
                clientInstallationId: "installation-other"
            ),
            offlineMapJob(
                jobId: "job-cached-old",
                status: "ready",
                mapId: "map-same-area",
                createdAt: "2026-07-12T02:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-running",
                status: "converting_features",
                createdAt: "2026-07-12T03:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-regenerated",
                status: "ready",
                mapId: "map-same-area",
                createdAt: "2026-07-12T04:00:00Z",
                clientInstallationId: "installation-mine",
                installOnDevice: true
            ),
            offlineMapJob(
                jobId: "job-failed",
                status: "failed",
                createdAt: "2026-07-12T05:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-expired",
                status: "expired",
                createdAt: "2026-07-12T06:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-cancelled",
                status: "cancelled",
                createdAt: "2026-07-12T07:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-ready-without-map",
                status: "ready",
                createdAt: "2026-07-12T08:00:00Z",
                clientInstallationId: "installation-mine"
            ),
        ].compactMap { $0 }

        let selected = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine"
        )

        assertEqual(selected?.jobId, "job-regenerated", "recovery selects the regenerated same-area job")
        assertEqual(selected?.mapId, "map-same-area", "same stable map ID does not suppress a new job")
        assertEqual(selected?.installOnDevice, true, "recovery restores install workflow intent")

        let afterHandling = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine",
            excludedJobIds: ["job-regenerated"]
        )
        assertEqual(
            afterHandling?.status,
            "converting_features",
            "recovery does not redownload a handled ready job"
        )
        assertEqual(afterHandling?.jobId, "job-running", "handled exclusion removes only that job")

        let none = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine",
            excludedJobIds: ["job-regenerated", "job-running", "job-cached-old"]
        )
        assertEqual(none, nil, "terminal and ready-without-map jobs are not recoverable")

        guard let legacyRetry = offlineMapJob(
            jobId: "job-legacy-retry",
            status: "failed",
            errorCode: "map_build_failed",
            attempts: 1,
            maxAttempts: 3,
            createdAt: "2026-07-12T09:00:00Z",
            updatedAt: "2026-07-12T09:00:00Z",
            clientInstallationId: "installation-mine"
        ) else {
            assert(false, "legacy retry recovery fixture should decode")
            return
        }
        let legacySelection = OfflineMapJobRecoverySelector.select(
            jobs: [legacyRetry],
            clientInstallationId: "installation-mine",
            now: Date(timeIntervalSince1970: 1_783_846_805)
        )
        assertEqual(
            legacySelection?.jobId,
            "job-legacy-retry",
            "recovery discovers an old worker's transient failed-to-queued job"
        )
        let staleLegacySelection = OfflineMapJobRecoverySelector.select(
            jobs: [legacyRetry],
            clientInstallationId: "installation-mine",
            now: Date(timeIntervalSince1970: 1_783_846_840)
        )
        assertEqual(
            staleLegacySelection,
            nil,
            "recovery does not repeatedly adopt a permanent legacy-shaped failure"
        )

    }

    static func testOfflineMapDownloadResponseValidation() {
        let success = HTTPURLResponse(
            url: URL(string: "https://maps.example/download")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        do {
            try OfflineMapDownloadResponseValidator.validate(
                response: success,
                errorBody: "unused"
            )
        } catch {
            assert(false, "successful map download response should validate")
        }

        let forbidden = HTTPURLResponse(
            url: URL(string: "https://maps.example/download")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )
        do {
            try OfflineMapDownloadResponseValidator.validate(
                response: forbidden,
                errorBody: "download URL expired"
            )
            assert(false, "HTTP error body must not be cached as a map pack")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(let status, let body) = error else {
                assert(false, "HTTP error should retain its server status")
                return
            }
            assertEqual(status, 403, "download validation preserves HTTP status")
            assertEqual(body, "download URL expired", "download validation preserves error body")
        } catch {
            assert(false, "HTTP error should use OfflineMapPlatformError")
        }
    }

    @MainActor
    static func testOfflineMapPackDownloaderRejectsHTTPError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        OfflineMapTestURLProtocol.configure { _ in
            (403, Data("download URL expired".utf8))
        }
        defer { OfflineMapTestURLProtocol.reset() }

        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/expired.zip")!,
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "real downloader must reject an HTTP error body")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(let status, let body) = error else {
                assert(false, "real downloader should surface the HTTP status")
                return
            }
            assertEqual(status, 403, "real downloader preserves HTTP failure status")
            assert(
                body.contains("download URL expired"),
                "real downloader preserves the server error body"
            )
        } catch {
            assert(false, "real downloader should use OfflineMapPlatformError")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (403, Data(repeating: 0x41, count: 32 * 1024))
        }
        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/large-error.zip")!,
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "large HTTP error bodies must not be cached as maps")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(_, let body) = error else {
                assert(false, "large HTTP error should retain its status")
                return
            }
            assert(
                body.utf8.count <= 4 * 1024 + 3,
                "map download diagnostics retain only a bounded error prefix"
            )
        } catch {
            assert(false, "large HTTP error should use OfflineMapPlatformError")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (200, Data(repeating: 0x42, count: 5))
        }
        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/oversized.bmap")!,
                constraints: OfflineMapDownloadConstraints(
                    exactBytes: 4,
                    maximumBytes: BikeMapStreamFormat.maximumArtifactBytes
                ),
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "a map artifact cannot exceed its declared byte count")
        } catch let error as BikeMapStreamFormatError {
            guard case .invalidArtifactMetadata = error else {
                assert(false, "oversized map download reports metadata mismatch")
                return
            }
        } catch {
            assert(false, "oversized map download reports a typed format error")
        }
    }

    @MainActor
    static func testDurableMapDownloads() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); OfflineMapTestURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let payload = Data("durable".utf8)
        let constraints = OfflineMapDownloadConstraints(exactBytes: Int64(payload.count), maximumBytes: 1024,
            allowedDownloadHosts: ["maps.example"], artifactSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        OfflineMapTestURLProtocol.configure { _ in (200, payload) }
        do {
            let first = DurableMapDownloadCoordinator(configuration: configuration, directory: root)
            let downloaded = try await first.download(from: URL(string: "https://maps.example/first-grant")!,
                constraints: constraints, onProgress: { _ in }, onByteProgress: { _ in })
            assertEqual(try Data(contentsOf: downloaded), payload, "durable download retains completed bytes")
            let second = DurableMapDownloadCoordinator(configuration: configuration, directory: root)
            OfflineMapTestURLProtocol.configure { _ in (403, Data()) }
            let restored = try await second.download(from: URL(string: "https://maps.example/renewed-grant")!,
                constraints: constraints, onProgress: { _ in }, onByteProgress: { _ in })
            assertEqual(restored, downloaded, "fresh coordinator reuses immutable completion across grant URLs")
            assertEqual(OfflineMapTestURLProtocol.requests().count, 0, "restored completion needs no second GET")
            try FileManager.default.removeItem(at: downloaded)
            do {
                _ = try await second.download(from: URL(string: "https://maps.example/expired")!,
                    constraints: constraints, onProgress: { _ in }, onByteProgress: { _ in })
                assert(false, "HTTP rejection cannot publish a durable download")
            } catch { /* Expected HTTP/size rejection. */ }
        } catch { assert(false, "durable download test failed: \(error)") }
    }

    static func testOfflineMapProgressPresentation() {
        let legacy = offlineMapJob(status: "converting_features")
        let progressPayload = Data(
            """
            {"jobId":"progress-job","status":"converting_features","progress":{"completedBlocks":4,"totalBlocks":10}}
            """.utf8
        )
        let progressJob = try? JSONDecoder().decode(OfflineMapJob.self, from: progressPayload)
        let cacheWaitPayload = Data(
            """
            {"jobId":"cache-wait-job","status":"converting_features","progress":{"phase":"building_preprocessing","unit":"source_cache_wait","completedBlocks":0,"totalBlocks":10,"indeterminate":true}}
            """.utf8
        )
        let cacheWaitJob = try? JSONDecoder().decode(OfflineMapJob.self, from: cacheWaitPayload)

        assertEqual(
            OfflineMapProgressPresentation.value(job: legacy, downloadProgress: 0),
            0.1,
            "conversion begins at a stable staged percentage on older servers"
        )
        assert(
            abs(
                (OfflineMapProgressPresentation.value(
                    job: progressJob,
                    downloadProgress: 0
                ) ?? 0) - 0.42
            ) < 0.000_001,
            "generation block progress advances through the conversion range"
        )
        assert(
            abs(
                (OfflineMapProgressPresentation.value(
                    job: progressJob,
                    downloadProgress: 0.75
                ) ?? 0) - 0.42
            ) < 0.000_001,
            "generation progress takes precedence while conversion is active"
        )
        assertEqual(
            OfflineMapProgressPresentation.value(job: cacheWaitJob, downloadProgress: 0),
            0.1,
            "source cache waits retain a determinate staged percentage"
        )
        assertEqual(
            cacheWaitJob?.progress?.detail,
            "Waiting for the verified map source",
            "source cache waits have a distinct progress explanation"
        )
        let stagedStatuses: [(String, Double)] = [
            ("queued", 0.02),
            ("validating", 0.04),
            ("resolving_source", 0.06),
            ("extracting_pbf", 0.08),
            ("packaging", 0.95),
        ]
        assertEqual(
            OfflineMapProgressPresentation.value(job: nil, downloadProgress: 0),
            0.01,
            "job creation starts with visible progress"
        )
        for (status, expected) in stagedStatuses {
            assertEqual(
                OfflineMapProgressPresentation.value(
                    job: offlineMapJob(status: status),
                    downloadProgress: 0
                ),
                expected,
                "\(status) uses a friendly staged percentage"
            )
        }
        assert(
            abs(
                (OfflineMapProgressPresentation.value(
                    job: offlineMapJob(status: "ready"),
                    downloadProgress: 0.5
                ) ?? 0) - 0.975
            ) < 0.000_001,
            "file download completes the final five percent"
        )
        assertEqual(
            OfflineMapProgressPresentation.value(
                job: offlineMapJob(status: "ready"),
                downloadProgress: 1
            ),
            0.99,
            "a pending map does not claim completion before verification and saving"
        )
    }

    static func testOfflineMapByteProgressPresentation() {
        assertEqual(
            OfflineMapByteProgress(completedBytes: 25, totalBytes: 100).fraction,
            0.25,
            "map download fraction uses completed and total bytes"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 256, totalBytes: 1_024).percentage,
            25,
            "map download percentage is suitable for the settings UI"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 125, totalBytes: 100).percentage,
            100,
            "map download percentage clamps oversized progress"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 10, totalBytes: 0).percentage,
            0,
            "map download percentage handles a missing byte total safely"
        )
    }

    static func testProvisionalActiveMapVisibility() {
        let boot = String(repeating: "a", count: 32)
        let operation = String(repeating: "b", count: 32)
        // Firmware reports installer roots without /sdcard (safeActiveRoot).
        let currentRoot = "/VECTMAP/.maps/current-session"
        for root in [currentRoot, "/VECTMAP", "/VECTMAP/.maps/map-prod_1.2"] {
            assert(MapSelectionHealth.isInstallerRoot(root), "firmware installer root \(root) is accepted")
        }
        for root in ["/maps/current", "/sdcard/VECTMAP/.maps/current-session", "/VECTMAP/.maps/",
                     "/VECTMAP/.maps/a/b", "/VECTMAP/.maps/.hidden", "/VECTMAP/.maps/a..b",
                     "/VECTMAP/.maps/" + String(repeating: "a", count: 81), "VECTMAP"] {
            assert(!MapSelectionHealth.isInstallerRoot(root), "non-installer root \(root) is rejected")
        }
        func health(_ state: String, _ revision: UInt64, bootID: String? = nil,
                    root: String = "/VECTMAP/.maps/current-session", mapID: String = "candidate",
                    sessionID: String = "current-session") -> MapSelectionHealth {
            MapSelectionHealth(schemaVersion: 1, bootID: bootID ?? boot, revision: revision,
                state: state, root: root, operationID: operation, mapID: mapID,
                sessionID: sessionID, affectedOperationID: state == "ready" ? "" : operation)
        }
        var projection = MapSelectionHealthProjection()
        func apply(_ value: MapSelectionHealth?, present: Bool = true) -> Bool {
            projection.apply(value, fieldPresent: present, activeRoot: currentRoot,
                mapID: "candidate", sessionID: "current-session")
        }
        assert(apply(nil, present: false), "old firmware preserves legacy visibility policy")
        assert(!apply(health("unknown", 0)), "unknown never grants green presence")
        assert(apply(health("ready", 1)), "grounded current ready selection is visible")
        assert(!apply(health("degraded", 2)), "runtime degradation hides historical installed selection")
        assert(projection.health?.state == "degraded", "current health records degradation independently")
        assert(!apply(health("ready", 1)), "stale ready cannot erase degradation")
        assert(!apply(health("ready", 2)), "conflicting same revision is rejected")
        assert(!apply(health("ready", 3, root: "/VECTMAP/.maps/wrong-session")), "wrong root is rejected")
        assert(!apply(health("ready", 3, mapID: "other")), "wrong map is rejected")
        assert(!apply(health("ready", 3, sessionID: "old")), "wrong session is rejected")
        assert(!apply(health("ready", 3, bootID: String(repeating: "c", count: 32))), "wrong boot is rejected")
        let wrongOperation = MapSelectionHealth(schemaVersion: 1, bootID: boot, revision: 3,
            state: "ready", root: currentRoot, operationID: String(repeating: "d", count: 32),
            mapID: "candidate", sessionID: "current-session", affectedOperationID: "")
        assert(!apply(wrongOperation), "same root and content cannot silently change operation identity")
        assert(projection.health?.revision == 2, "rejected observations never replace saved health")
        assert(!apply(nil, present: false), "missing new health cannot downgrade to legacy fallback")
        assert(!apply(health("rolling_back", 3)), "rollback pending is not healthy")
        assert(!apply(health("rollback_failed", 4)), "failed rollback remains hidden")
        assert(apply(health("ready", 5)), "fresh grounded recovery can restore current presence")
        assert(apply(health("ready", 5)), "identical health replay is idempotent")
        var malformed = MapSelectionHealthProjection()
        assert(!malformed.apply(nil, fieldPresent: true, activeRoot: nil, mapID: nil, sessionID: nil),
               "malformed advertised health cannot fall back to legacy green")
        assert(!malformed.apply(nil, fieldPresent: false, activeRoot: nil, mapID: nil, sessionID: nil),
               "malformed capability remains conservative in this connection")
        let legacyHealth = MapSelectionHealth(schemaVersion: 1, bootID: boot, revision: 1,
            state: "ready", root: "/VECTMAP", operationID: "", mapID: "legacy",
            sessionID: "", affectedOperationID: "")
        var legacyProjection = MapSelectionHealthProjection()
        assert(legacyProjection.apply(legacyHealth, fieldPresent: true,
            activeRoot: "/VECTMAP", mapID: "legacy", sessionID: ""),
            "legacy selections are grounded by exact root and map without a session")

        let ble = BLEManager()
        ble.isConnected = true
        ble.setConnectedDeviceIDForTesting("health-device")
        ble.deviceTransferSessionToken = "health-token"
        let context = ble.captureMapTransferHTTPStatusContext()!
        func statusData(_ state: String, _ revision: UInt64) -> Data {
            Data("""
            {"activeRoot":"\(currentRoot)","activeMapId":"candidate","activeSessionId":"current-session",
             "selectionHealth":{"schemaVersion":1,"bootID":"\(boot)","revision":\(revision),
             "state":"\(state)","root":"\(currentRoot)","operationID":"\(operation)",
             "mapID":"candidate","sessionID":"current-session","affectedOperationID":""}}
            """.utf8)
        }
        let historicalReceipt = Data("""
        {"operation":{"schemaVersion":1,"deviceID":"health-device",
        "operationID":"\(operation)","phase":"installed","revision":7}}
        """.utf8)
        assert(ble.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + historicalReceipt))
        let readyData = statusData("ready", 1)
        let ready = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: readyData)
        assert(ble.applyAuthenticatedMapTransferStatus(ready, context: context))
        assert(ble.activeDeviceMap?.mapID == "candidate", "HTTP ready grants grounded current presence")
        assert(ble.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + statusData("degraded", 2)))
        assert(ble.activeDeviceMap == nil && ble.mapSelectionHealth?.state == "degraded",
               "native BLE degradation immediately removes green presence")
        assert(ble.mapOperationStatus?.phase == "installed" && ble.mapOperationStatus?.revision == 7,
               "runtime health does not rewrite the historical Installed receipt")
        assert(ble.applyAuthenticatedMapTransferStatus(ready, context: context))
        assert(ble.activeDeviceMap == nil && ble.mapSelectionHealth?.revision == 2,
               "late HTTP ready cannot undo newer native BLE health")
        let accepted = Data("""
        {"operation":{"schemaVersion":1,"deviceID":"health-device",
        "operationID":"\(operation)","phase":"accepted","revision":6}}
        """.utf8)
        assert(ble.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + accepted))
        assert(ble.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + statusData("ready", 3)))
        assert(ble.activeDeviceMap == nil && ble.mapOperationStatus?.phase == "accepted",
               "renderer ready does not promote a live Accepted operation before durable Installed")
        ble.setConnectedDeviceIDForTesting("another-device")
        assert(!ble.applyAuthenticatedMapTransferStatus(ready, context: context),
               "health uses the same exact-device HTTP context fence")
        assert(ble.activeDeviceMap == nil, "wrong-device health never restores presence")
        assert(ble.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + statusData("ready", 4)))
        assert(ble.activeDeviceMap == nil && ble.mapSelectionHealth?.revision == 3,
               "native health remains bound to its original connected device")

        for mapID in ["", "stale-map", "candidate"] {
            for status in ["activating", "failed", "accepted", "ready"] {
                assert(MapActivationVisibilityPolicy.hidesActiveSelection(
                    activeMapID: "candidate", activeSessionID: "current-session",
                    activationStatus: status, activationMapID: mapID,
                    activationSessionID: "current-session"),
                    "current activating session stays hidden even with missing/stale activation map ID")
            }
        }
        assert(!MapActivationVisibilityPolicy.hidesActiveSelection(
            activeMapID: "candidate", activeSessionID: "previous-session",
            activationStatus: "activating", activationMapID: "candidate",
            activationSessionID: "current-session"),
            "different verified prior session stays visible despite equal map ID")
        for status in ["installed", "idle"] {
            assert(!MapActivationVisibilityPolicy.hidesActiveSelection(
                activeMapID: "candidate", activeSessionID: "current-session",
                activationStatus: status, activationMapID: "candidate",
                activationSessionID: "current-session"),
                "terminal installed and idle selections stay visible")
        }
        assert(MapActivationVisibilityPolicy.hidesActiveSelection(
            activeMapID: "candidate", activeSessionID: nil,
            activationStatus: "activating", activationMapID: "candidate",
            activationSessionID: "current-session"),
            "legacy sessionless provisional candidate remains hidden")
    }

    static func testMapActivationProgressPresentation() {
        let progress = MapActivationProgressPresentation.make(
            status: "activating",
            step: 1,
            stepCount: 5,
            percentage: 6
        )
        assertEqual(progress?.label, "Step 1/5 - 6%", "activation progress includes the total step count")
        assertEqual(progress?.fraction, 0.06, "activation percentage drives the progress bar")
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "receiving",
                step: 1,
                stepCount: 3,
                percentage: 50
            )?.label,
            "Step 1/3 - 50%",
            "stream reception uses the dynamic three-step presentation"
        )
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "finalizing",
                step: 2,
                stepCount: 3,
                percentage: 1
            )?.label,
            "Step 2/3 - 1%",
            "device-owned finalization remains visible after upload"
        )
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "installed",
                step: 4,
                stepCount: 5,
                percentage: 100
            ),
            nil,
            "completed activation hides the in-progress presentation"
        )
        assert(
            MapActivationProgressPresentation.shouldClear(
                forTransferOutcome: "installed"
            ) &&
                MapActivationProgressPresentation.shouldClear(
                    forTransferOutcome: "failed"
                ) &&
                !MapActivationProgressPresentation.shouldClear(
                    forTransferOutcome: "unconfirmed"
                ),
            "terminal transfer outcomes clear restored activation progress"
        )
    }

    static func testMapUploadProgressReconciliation() {
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: 10,
                durableDevicePercentage: 32
            ),
            32,
            "a retry does not display less than the durable device checkpoint"
        )
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: 40,
                durableDevicePercentage: 32
            ),
            40,
            "retry transport progress takes over after reaching the checkpoint"
        )
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: nil,
                durableDevicePercentage: 32
            ),
            32,
            "restoration can present a device checkpoint without a live task"
        )
    }

    static func testOfflineMapDownloadingSectionPresentation() {
        assert(
            OfflineMapDownloadingSectionPresentation.isRecoveryOnly(
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "a background server probe without map state is recovery-only"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isRecoveryOnly(
                isServerRecoveryCheckPending: true,
                hasCurrentJob: true,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "a recovered job is user-visible map state"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "paused persisted jobs keep the resume section reachable"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "idle map settings omit an empty downloading section"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: true,
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "device-owned activation keeps its status section visible"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "launch recovery checks stay hidden until a real map job is found"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: true,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "device activation remains visible during a server recovery check"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: "Map server unavailable"
            ),
            "launch recovery errors remain visible"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: true,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "a recovered map job remains visible"
        )
        assert(
            OfflineMapAutomaticRecoveryTrigger.shouldResume(
                hasPendingInstall: true,
                isBusy: false,
                isConnected: true,
                isNavigationReady: true
            ),
            "pending device install resumes when BLE becomes ready"
        )
        assert(
            !OfflineMapAutomaticRecoveryTrigger.shouldResume(
                hasPendingInstall: true,
                isBusy: false,
                isConnected: true,
                isNavigationReady: false
            ),
            "pending device install waits for navigation readiness"
        )
    }

    static func testOfflineMapActivityCounterOverlappingOperations() {
        var counter = OfflineMapActivityCounter()
        counter.begin()
        counter.begin()
        counter.end()
        assert(
            counter.isBusy,
            "finishing a cancelled older operation keeps a newer map operation busy"
        )
        counter.end()
        assert(!counter.isBusy, "busy state clears after the final operation finishes")
    }

    static func testSavedMapDeviceTransferPolicy() {
        assert(
            SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "server map processing does not block an independent saved-map transfer"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: true,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "a foreground device transfer blocks a second transfer"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: true,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "a background upload blocks a different saved map"
        )
        assert(
            SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: true,
                isPausedUpload: true,
                isNavigationReady: true
            ),
            "a paused upload remains resumable through background arbitration"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: false
            ),
            "BLE navigation readiness remains required"
        )
    }

    @MainActor
    static func testPendingOfflineMapJobBlocksEveryCreationIngress() {
        let suite = "offline-map-pending-ingress-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "pending job ingress test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        OfflineMapJobPersistence.save(jobId: "job-existing", defaults: defaults)
        let manager = OfflineMapManager(defaults: defaults)

        manager.beginMapAreaSelection()
        manager.createCustomCutoutJob()
        manager.createJobFromSelectedMapArea(bleManager: BLEManager())
        manager.installCurrentLocationMap(
            location: CLLocation(latitude: 31.2304, longitude: 121.4737),
            bleManager: BLEManager()
        )

        assert(
            !manager.isMapAreaSelectionActive,
            "pending job blocks the area-selection creation ingress"
        )
        assert(
            !manager.isBusy,
            "pending job blocks all creation tasks before network work starts"
        )
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            "job-existing",
            "all creation ingresses preserve the paused job recovery ID"
        )

        manager.discardPendingMapAndBeginSelection()
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            nil,
            "discarding an unrecoverable job clears its durable lock"
        )
        assert(
            manager.isMapAreaSelectionActive,
            "discarding a pending job atomically starts new-map selection"
        )
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: defaults).contains("job-existing"),
            "forgotten server job stays excluded from future discovery"
        )
    }

    @MainActor
    static func testOfflineMapJobCreatorReconcilesAmbiguousResponse() async {
        let request = OfflineMapJobRequest
            .customBBox(OfflineMapBounds(minLon: 10, minLat: 20, maxLon: 11, maxLat: 21))
            .identified(
                clientInstallationId: "installation-test",
                clientRequestId: "request-test-123",
                installOnDevice: false
            )
        guard let committed = offlineMapJob(
            jobId: "job-committed",
            status: "queued",
            clientInstallationId: "installation-test",
            clientRequestId: "request-test-123"
        ) else {
            assert(false, "committed job fixture should decode")
            return
        }
        var createRequestIds: [String?] = []
        var listCount = 0
        let recovered = try? await OfflineMapJobCreator.create(
            request: request,
            create: { attempt in
                createRequestIds.append(attempt.clientRequestId)
                throw URLError(.networkConnectionLost)
            },
            list: {
                listCount += 1
                return [committed]
            },
            sleep: { _ in
                assert(false, "committed ambiguous response should reconcile before retry sleep")
            },
            onRetry: {}
        )

        assertEqual(recovered?.jobId, "job-committed", "ambiguous POST response reconciles by request ID")
        assertEqual(createRequestIds, ["request-test-123"], "reconciliation preserves the submitted request ID")
        assertEqual(listCount, 1, "ambiguous create checks durable server jobs")

        var retryRequestIds: [String?] = []
        let retried = try? await OfflineMapJobCreator.create(
            request: request,
            create: { attempt in
                retryRequestIds.append(attempt.clientRequestId)
                if retryRequestIds.count == 1 {
                    throw URLError(.timedOut)
                }
                return committed
            },
            list: { [] },
            sleep: { _ in },
            onRetry: {}
        )
        assertEqual(retried?.jobId, "job-committed", "ambiguous create retries when reconciliation is empty")
        assertEqual(
            retryRequestIds,
            ["request-test-123", "request-test-123"],
            "every transport retry reuses the idempotency token"
        )
    }

    @MainActor
    static func testOfflineMapRecoveryRoutes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }

        func jobData(
            jobId: String,
            mapId: String,
            installationId: String? = nil,
            installOnDevice: Bool? = nil,
            sourceRegionName: String? = nil,
            artifacts: [OfflineMapArtifact]? = nil,
            createdAt: String = "2026-07-12T04:00:00Z"
        ) -> Data {
            var payload: [String: Any] = [
                "jobId": jobId,
                "status": "ready",
                "mapId": mapId,
                "createdAt": createdAt,
            ]
            if let installationId { payload["clientInstallationId"] = installationId }
            if let installOnDevice { payload["installOnDevice"] = installOnDevice }
            if let sourceRegionName {
                payload["sourceRegion"] = [
                    "id": "geofabrik-asia-china",
                    "name": sourceRegionName,
                    "provider": "geofabrik",
                ]
            }
            if let artifacts {
                payload["artifacts"] = try! JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(artifacts)
                )
            }
            return try! JSONSerialization.data(withJSONObject: payload)
        }

        func downloadURLData(mapId: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "mapId": mapId,
                "url": "/downloads/\(mapId).zip",
                "expiresAt": 2_000_000_000,
                "expiresInSeconds": 900,
            ])
        }

        func packData(
            mapId: String,
            displayName: String = "Recovery Test",
            storedMapData: Data = Data([0x01]),
            hashedMapData: Data? = nil
        ) -> Data {
            let mapPath = "VECTMAP/0/0/0.pbf"
            let declaredData = hashedMapData ?? storedMapData
            let manifest = try! JSONSerialization.data(withJSONObject: [
                "mapId": mapId,
                "displayName": displayName,
                "files": [[
                    "path": mapPath,
                    "bytes": declaredData.count,
                    "sha256": FirmwareUpdateManager.sha256Hex(declaredData),
                ]],
            ])
            return makeStoredZip(entries: [
                ("manifest.json", manifest),
                (mapPath, storedMapData),
            ])
        }

        let corruptCacheSuite = "offline-map-corrupt-cache-route-\(UUID().uuidString)"
        let corruptCacheDefaults = UserDefaults(suiteName: corruptCacheSuite)!
        defer { corruptCacheDefaults.removePersistentDomain(forName: corruptCacheSuite) }
        let corruptCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-corrupt-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: corruptCache) }
        try! FileManager.default.createDirectory(at: corruptCache, withIntermediateDirectories: true)
        let corruptCachedPack = corruptCache.appendingPathComponent("map-corrupt-cache.zip")
        try! packData(
            mapId: "map-corrupt-cache",
            storedMapData: Data([0x02]),
            hashedMapData: Data([0x01])
        ).write(to: corruptCachedPack)
        let corruptCacheManager = OfflineMapManager(
            defaults: corruptCacheDefaults,
            mapPlatformSession: session,
            cacheDirectory: corruptCache
        )
        corruptCacheManager.transferCachedPack(at: corruptCachedPack, bleManager: BLEManager())
        let corruptCacheDeadline = Date().addingTimeInterval(3)
        while corruptCacheManager.errorMessage == nil && Date() < corruptCacheDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            corruptCacheManager.errorMessage?.contains(
                "cannot be installed securely"
            ) == true,
            "unsigned cached ZIPs are rejected before device transfer"
        )

        let persistedSuite = "offline-map-persisted-route-\(UUID().uuidString)"
        let persistedDefaults = UserDefaults(suiteName: persistedSuite)!
        defer { persistedDefaults.removePersistentDomain(forName: persistedSuite) }
        persistedDefaults.set("https://persisted.example", forKey: "offlineMap.serverURL")
        let persistedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistedCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted",
            installOnDevice: true,
            serverURLString: "https://persisted.example",
            defaults: persistedDefaults
        )
        persistedDefaults.set("https://current-setting.example", forKey: "offlineMap.serverURL")
        persistedDefaults.set("legacy-shared-token", forKey: "offlineMap.apiToken")
        persistedDefaults.set("legacy-job-token", forKey: "offlineMap.activeJobAPIToken")
        var persistedDownloadCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-persisted" {
                return (
                    200,
                    jobData(
                        jobId: "job-persisted",
                        mapId: "map-persisted",
                        sourceRegionName: "China"
                    )
                )
            }
            if request.url?.path == "/v1/map-packs/map-persisted/download-url" {
                return (200, downloadURLData(mapId: "map-persisted"))
            }
            return (404, Data())
        }
        let persistedManager = OfflineMapManager(
            defaults: persistedDefaults,
            mapPlatformSession: session,
            cacheDirectory: persistedCache,
            packDownload: { _, _, onProgress, _ in
                persistedDownloadCount += 1
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(
                    mapId: "map-persisted",
                    displayName: "COVID-19 Rides"
                ).write(to: url)
                return url
            }
        )
        let disconnectedBLE = BLEManager()
        persistedManager.resumePendingMapJobIfNeeded(bleManager: disconnectedBLE)
        let firstPersistedPassCompleted = await waitForMapTaskCompletion(persistedManager)
        assert(firstPersistedPassCompleted, "persisted recovery should finish its first pass")
        assert(persistedManager.hasPendingMapJob, "disconnected device preserves pending install intent")
        assert(
            persistedManager.hasDownloadedPendingDeviceInstall,
            "downloaded deferred install becomes eligible for BLE-ready auto-resume"
        )
        if let downloadedURL = persistedManager.downloadedPackURL {
            assertEqual(
                persistedManager.displayName(forCachedPack: downloadedURL),
                "COVID-19 Rides",
                "legacy ZIP download preserves an explicit manifest name over its source"
            )
        } else {
            assert(false, "persisted recovery should expose its downloaded ZIP")
        }
        assertEqual(
            OfflineMapJobPersistence.downloadedJobId(defaults: persistedDefaults),
            "job-persisted",
            "downloaded persisted job is reusable for a later install"
        )
        assert(
            OfflineMapTestURLProtocol.requests().contains { $0.url?.host == "persisted.example" },
            "persisted recovery uses its originating server"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer legacy-job-token"
            },
            "persisted custom-server recovery uses its migrated scoped bearer credential"
        )
        assert(
            persistedDefaults.object(forKey: "offlineMap.apiToken") == nil &&
                persistedDefaults.object(forKey: "offlineMap.activeJobAPIToken") == nil,
            "app launch removes previously persisted shared API credentials"
        )
        try! OfflineMapInstallationCredentialStore(defaults: persistedDefaults).save(
            OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
                clientInstallationToken: "v1." + String(repeating: "A", count: 43)
            ),
            serverURLString: "https://persisted.example"
        )
        let relaunchedPersistedManager = OfflineMapManager(
            defaults: persistedDefaults,
            mapPlatformSession: session,
            cacheDirectory: persistedCache,
            packDownload: { _, _, _, _ in
                persistedDownloadCount += 1
                throw URLError(.cannotConnectToHost)
            }
        )
        OfflineMapTestURLProtocol.configure { _ in
            throw URLError(.cannotConnectToHost)
        }
        relaunchedPersistedManager.resumePendingMapJobIfNeeded(bleManager: disconnectedBLE)
        let localRestoreDeadline = Date().addingTimeInterval(3)
        while relaunchedPersistedManager.downloadedPackURL == nil &&
                Date() < localRestoreDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            relaunchedPersistedManager.downloadedPackURL != nil,
            "app relaunch restores the deferred local pack without the map server"
        )
        assertEqual(
            OfflineMapTestURLProtocol.requests().count,
            0,
            "deferred local install does not poll the map server"
        )
        assertEqual(persistedDownloadCount, 1, "deferred device install reuses the downloaded pack")
        if let url = relaunchedPersistedManager.downloadedPackURL {
            relaunchedPersistedManager.deleteCachedPack(at: url)
        }
        relaunchedPersistedManager.forgetPendingMapJob()

        let signedFixtureURL = URL(
            fileURLWithPath: "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt"
        )
        let signedFixtureText = try! String(contentsOf: signedFixtureURL, encoding: .utf8)
        let signedFixture = Dictionary(
            uniqueKeysWithValues: signedFixtureText.split(separator: "\n").map { line in
                let parts = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                return (String(parts[0]), String(parts[1]))
            }
        )
        let signedStream = Data(hex: signedFixture["stream_hex"]!)!
        let signedPublicKey = Data(hex: signedFixture["public_key_x963_hex"]!)!
        let signedPublicKeyHash = FirmwareUpdateManager.sha256Hex(signedPublicKey)
        let signedArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "golden-map.bmap",
            objectKey: "maps/golden-map/bike-map-stream-v1/map-test-2026-01/" +
                "\(signedPublicKeyHash)/\(String(repeating: "1", count: 64))/" +
                "\(String(repeating: "2", count: 64))/" +
                "\(signedFixture["signed_manifest_receipt"]!).bmap",
            bytes: Int64(signedStream.count),
            sha256: FirmwareUpdateManager.sha256Hex(signedStream),
            manifestReceipt: signedFixture["manifest_receipt"],
            signedManifestReceipt: signedFixture["signed_manifest_receipt"],
            signatureKeyId: "map-test-2026-01",
            signatureKeySha256: signedPublicKeyHash,
            producerBuildSha256: String(repeating: "1", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
            requiredIosBuild: "100",
            requiredIosGitSha: String(repeating: "a", count: 40),
            requiredIosBuildSha256: String(repeating: "b", count: 64),
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        let signedTrustStore = BikeMapStreamTrustStore(publicKeysByID: [
            "map-test-2026-01": signedPublicKey,
        ])

        func runSignedRecovery(
            jobID: String,
            userDefinedName: String?
        ) async {
            let suite = "offline-map-signed-recovery-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
                "offline-map-signed-recovery-cache-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: cache) }
            try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

            let serverURL = "https://signed-recovery.example"
            let credential = OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
                clientInstallationToken: "v1." + String(repeating: "A", count: 43)
            )
            let refreshedCredential = OfflineMapInstallationCredential(
                clientInstallationId: credential.clientInstallationId,
                clientInstallationToken: "v1." + String(repeating: "B", count: 43)
            )
            try! OfflineMapInstallationCredentialStore(defaults: defaults).save(
                credential,
                serverURLString: serverURL
            )
            defaults.set(serverURL, forKey: "offlineMap.serverURL")
            OfflineMapJobPersistence.save(
                jobId: jobID,
                serverURLString: serverURL,
                defaults: defaults
            )

            let legacyURL = cache.appendingPathComponent("golden-map.zip")
            if let userDefinedName {
                try! packData(mapId: "golden-map", displayName: "Golden Map")
                    .write(to: legacyURL)
                defaults.set(
                    [legacyURL.lastPathComponent: userDefinedName],
                    forKey: "offlineMap.packDisplayNames"
                )
                try! SavedMapArtifactMetadataStore.save(
                    SavedMapArtifactMetadata(
                        schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
                        mapID: "golden-map",
                        displayName: userDefinedName,
                        localArtifactFilename: legacyURL.lastPathComponent,
                        streamFormatVersion: nil,
                        rendererFormatVersion: nil,
                        jobID: "older-job",
                        serverURLString: serverURL,
                        clientInstallationID: credential.clientInstallationId,
                        primaryArtifact: nil,
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
                        expectedActiveMapID: "golden-map",
                        expectedActiveSessionID: nil,
                        lastTransferOutcome: nil,
                        userDefinedDisplayName: true
                    ),
                    for: legacyURL
                )
            }

            OfflineMapTestURLProtocol.configure { request in
                switch request.url?.path {
                case "/v1/installations":
                    assertEqual(
                        request.value(forHTTPHeaderField: "X-Installation-Token"),
                        credential.clientInstallationToken,
                        "recovery refreshes its persisted installation token"
                    )
                    return (200, try! JSONEncoder().encode(refreshedCredential))
                case "/v1/map-jobs/\(jobID)":
                    assertEqual(
                        request.value(forHTTPHeaderField: "X-Map-Stream-Trust"),
                        signedTrustStore.capabilityHeaderValue,
                        "signed recovery advertises the manager's configured trust store"
                    )
                    return (
                        200,
                        jobData(
                            jobId: jobID,
                            mapId: "golden-map",
                            sourceRegionName: "China",
                            artifacts: [signedArtifact]
                        )
                    )
                case "/v1/map-packs/golden-map/artifacts/bike-map-stream-v1/download-url":
                    var response = try! JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(signedArtifact)
                    ) as! [String: Any]
                    response["url"] = "/immutable/golden-map.bmap"
                    response["expiresAt"] = 2_000_000_000
                    response["expiresInSeconds"] = 900
                    return (200, try! JSONSerialization.data(withJSONObject: response))
                case "/v1/map-jobs":
                    return (200, try! JSONSerialization.data(withJSONObject: ["jobs": []]))
                case "/v1/map-jobs/\(jobID)/downloads",
                     "/v1/map-jobs/\(jobID)/display-name":
                    return (
                        200,
                        try! JSONSerialization.data(withJSONObject: [
                            "jobId": jobID,
                            "downloadCount": 1,
                        ])
                    )
                default:
                    return (404, Data())
                }
            }
            let manager = OfflineMapManager(
                defaults: defaults,
                mapPlatformSession: session,
                cacheDirectory: cache,
                mapStreamTrustStore: signedTrustStore,
                packDownload: { _, _, onProgress, _ in
                    onProgress(1)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("bmap")
                    try signedStream.write(to: url)
                    return url
                }
            )
            manager.resumePendingMapJobIfNeeded()
            let signedRecoveryCompleted = await waitForMapTaskCompletion(manager)
            assert(
                signedRecoveryCompleted,
                "signed BMAP recovery should complete"
            )
            assertEqual(
                OfflineMapInstallationCredentialStore(defaults: defaults).load(
                    serverURLString: serverURL
                ),
                refreshedCredential,
                "recovery persists the current installation token"
            )
            guard let downloadedURL = manager.downloadedPackURL else {
                assert(false, "signed BMAP recovery should publish its downloaded artifact")
                return
            }
            assertEqual(
                downloadedURL.pathExtension,
                "bmap",
                "signed recovery publishes the canonical BMAP extension"
            )
            let expectedName = userDefinedName ?? "Golden Map"
            assertEqual(
                manager.displayName(forCachedPack: downloadedURL),
                expectedName,
                userDefinedName == nil
                    ? "signed manifest displayName outranks the source-region fallback"
                    : "signed replacement preserves an explicit user name"
            )
            let downloadedMetadata = SavedMapArtifactMetadataStore.load(for: downloadedURL)
            assertEqual(
                downloadedMetadata?.displayName,
                expectedName,
                "signed recovery persists the resolved display name"
            )
            assertEqual(
                downloadedMetadata?.userDefinedDisplayName,
                userDefinedName != nil,
                "signed replacement preserves display-name provenance"
            )
            assertEqual(
                downloadedMetadata?.primaryArtifact,
                signedArtifact,
                "signed recovery persists the verified stream artifact"
            )
            assert(
                OfflineMapTestURLProtocol.requests().contains {
                    $0.url?.path ==
                        "/v1/map-packs/golden-map/artifacts/bike-map-stream-v1/download-url"
                },
                "signed recovery exercises the immutable artifact URL path"
            )
            if userDefinedName != nil {
                assert(
                    !FileManager.default.fileExists(atPath: legacyURL.path),
                    "signed replacement removes the obsolete ZIP"
                )
                assert(
                    SavedMapArtifactMetadataStore.load(for: legacyURL) == nil,
                    "signed replacement removes the obsolete ZIP metadata"
                )
                assert(
                    defaults.dictionary(forKey: "offlineMap.packDisplayNames")?[
                        legacyURL.lastPathComponent
                    ] == nil,
                    "signed replacement removes the obsolete ZIP display-name entry"
                )
            }
        }

        await runSignedRecovery(jobID: "job-signed-name", userDefinedName: nil)
        await runSignedRecovery(
            jobID: "job-signed-replacement",
            userDefinedName: "Weekend Ride"
        )

        let managedSuite = "offline-map-managed-token-route-\(UUID().uuidString)"
        let managedDefaults = UserDefaults(suiteName: managedSuite)!
        defer { managedDefaults.removePersistentDomain(forName: managedSuite) }
        let managedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-managed-token-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-managed-token",
            serverURLString: "https://maps.8o.vc:443/",
            defaults: managedDefaults
        )
        managedDefaults.set("https://unrelated-custom.example", forKey: "offlineMap.serverURL")
        managedDefaults.set("unrelated-custom-token", forKey: "offlineMap.apiToken")
        let managedManager = OfflineMapManager(
            defaults: managedDefaults,
            mapPlatformSession: session,
            cacheDirectory: managedCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-managed-token").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-managed-token" {
                return (200, jobData(jobId: "job-managed-token", mapId: "map-managed-token"))
            }
            if request.url?.path == "/v1/map-packs/map-managed-token/download-url" {
                return (200, downloadURLData(mapId: "map-managed-token"))
            }
            return (404, Data())
        }
        managedManager.resumePendingMapJobIfNeeded()
        let managedCompleted = await waitForMapTaskCompletion(managedManager)
        assert(managedCompleted, "managed-server recovery should complete without a bundled secret")
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == URL(string: OfflineMapServiceConfig.productionServerURLString)?.host &&
                    $0.value(forHTTPHeaderField: "Authorization") == nil
            },
            "managed-server recovery uses the production endpoint without global authorization"
        )
        assert(
            managedDefaults.object(forKey: "offlineMap.apiToken") == nil &&
                managedDefaults.object(forKey: "offlineMap.activeJobAPIToken") == nil,
            "managed-server recovery removes stale shared credentials"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host != "unrelated-custom.example"
            },
            "managed recovery ignores unrelated current custom settings"
        )
        if let url = managedManager.downloadedPackURL {
            managedManager.deleteCachedPack(at: url)
        }

        let rotatedCustomSuite = "offline-map-rotated-custom-token-\(UUID().uuidString)"
        let rotatedCustomDefaults = UserDefaults(suiteName: rotatedCustomSuite)!
        defer { rotatedCustomDefaults.removePersistentDomain(forName: rotatedCustomSuite) }
        let rotatedCustomCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-rotated-custom-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rotatedCustomCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-rotated-custom-token",
            serverURLString: "https://custom-rotation.example:443/",
            defaults: rotatedCustomDefaults
        )
        rotatedCustomDefaults.set("https://custom-rotation.example", forKey: "offlineMap.serverURL")
        rotatedCustomDefaults.set("new-custom-token", forKey: "offlineMap.apiToken")
        let rotatedCustomManager = OfflineMapManager(
            defaults: rotatedCustomDefaults,
            mapPlatformSession: session,
            cacheDirectory: rotatedCustomCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-rotated-custom-token").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-rotated-custom-token" {
                return (200, jobData(jobId: "job-rotated-custom-token", mapId: "map-rotated-custom-token"))
            }
            if request.url?.path == "/v1/map-packs/map-rotated-custom-token/download-url" {
                return (200, downloadURLData(mapId: "map-rotated-custom-token"))
            }
            return (404, Data())
        }
        rotatedCustomManager.resumePendingMapJobIfNeeded()
        let rotatedCustomCompleted = await waitForMapTaskCompletion(rotatedCustomManager)
        assert(rotatedCustomCompleted, "same-origin custom recovery should preserve its scoped token")
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == "custom-rotation.example" &&
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-custom-token"
            },
            "same-origin custom recovery uses its migrated bearer credential"
        )
        if let url = rotatedCustomManager.downloadedPackURL {
            rotatedCustomManager.deleteCachedPack(at: url)
        }

        let discoverySuite = "offline-map-discovery-route-\(UUID().uuidString)"
        let discoveryDefaults = UserDefaults(suiteName: discoverySuite)!
        defer { discoveryDefaults.removePersistentDomain(forName: discoverySuite) }
        discoveryDefaults.set("https://discovery.example", forKey: "offlineMap.serverURL")
        let discoveryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-discovery-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: discoveryCache) }
        let discoveryManager = OfflineMapManager(
            defaults: discoveryDefaults,
            mapPlatformSession: session,
            cacheDirectory: discoveryCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-discovered").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let job = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-discovered",
                        mapId: "map-discovered",
                        installationId: discoveryManager.clientInstallationId,
                        installOnDevice: false
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [job]]))
            }
            if request.url?.path == "/v1/map-jobs/job-discovered" {
                return (
                    200,
                    jobData(
                        jobId: "job-discovered",
                        mapId: "map-discovered",
                        installationId: discoveryManager.clientInstallationId,
                        installOnDevice: false
                    )
                )
            }
            if request.url?.path == "/v1/map-packs/map-discovered/download-url" {
                return (200, downloadURLData(mapId: "map-discovered"))
            }
            return (404, Data())
        }
        discoveryManager.resumePendingMapJobIfNeeded()
        let discoveryCompleted = await waitForMapTaskCompletion(discoveryManager)
        assert(discoveryCompleted, "launch discovery should complete")
        assert(!discoveryManager.hasPendingMapJob, "download-only discovery clears durable pending state")
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: discoveryDefaults).contains("job-discovered"),
            "launch discovery marks the exact recovered job handled"
        )
        if let url = discoveryManager.downloadedPackURL {
            discoveryManager.deleteCachedPack(at: url)
        }

        let completedSuite = "offline-map-completed-download-\(UUID().uuidString)"
        let completedDefaults = UserDefaults(suiteName: completedSuite)!
        defer { completedDefaults.removePersistentDomain(forName: completedSuite) }
        let completedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-completed-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: completedCache) }
        try! FileManager.default.createDirectory(at: completedCache, withIntermediateDirectories: true)
        let completedPack = completedCache.appendingPathComponent("map-completed.zip")
        try! packData(mapId: "map-completed").write(to: completedPack)
        OfflineMapJobPersistence.save(jobId: "job-completed", defaults: completedDefaults)
        OfflineMapJobPersistence.markPackDownloaded(
            jobId: "job-completed", mapId: "map-completed", defaults: completedDefaults
        )
        let completedManager = OfflineMapManager(
            defaults: completedDefaults,
            mapPlatformSession: session,
            cacheDirectory: completedCache,
            packDownload: { _, _, _, _ in
                assertionFailure("a saved completed map must not download again")
                throw OfflineMapPlatformError.invalidResponse
            }
        )
        assert(completedManager.hasLocallySavedPendingMap, "saved completed map is recognized at launch")
        completedManager.resumePendingMapJobIfNeeded()
        let localCompletionDeadline = Date().addingTimeInterval(3)
        while completedManager.hasPendingMapJob && Date() < localCompletionDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(!completedManager.hasPendingMapJob, "local completed map clears the stale pending row")
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: completedDefaults).contains("job-completed"),
            "local completion marks only the exact job handled"
        )
        assert(FileManager.default.fileExists(atPath: completedPack.path), "local completion preserves the saved map")

        let downloadRetrySuite = "offline-map-download-retry-\(UUID().uuidString)"
        let downloadRetryDefaults = UserDefaults(suiteName: downloadRetrySuite)!
        defer { downloadRetryDefaults.removePersistentDomain(forName: downloadRetrySuite) }
        downloadRetryDefaults.set("https://download-retry.example", forKey: "offlineMap.serverURL")
        downloadRetryDefaults.set(
            ["map-download-retry.zip": "Shanghai Riverside"],
            forKey: "offlineMap.packDisplayNames"
        )
        OfflineMapJobPersistence.save(
            jobId: "job-download-retry",
            serverURLString: "https://download-retry.example",
            defaults: downloadRetryDefaults
        )
        let downloadRetryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-download-retry-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: downloadRetryCache) }
        try! FileManager.default.createDirectory(
            at: downloadRetryCache,
            withIntermediateDirectories: true
        )
        let downloadRetryPack = downloadRetryCache.appendingPathComponent("map-download-retry.zip")
        let originalDownloadRetryPackData = packData(mapId: "map-download-retry")
        try! originalDownloadRetryPackData.write(to: downloadRetryPack)
        let originalDownloadRetryMetadata = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": SavedMapArtifactMetadata.currentSchemaVersion,
            "mapID": "map-download-retry",
            "displayName": "Shanghai Riverside",
            "localArtifactFilename": downloadRetryPack.lastPathComponent,
            "userDefinedDisplayName": true,
        ])
        try! originalDownloadRetryMetadata.write(
            to: SavedMapArtifactMetadataStore.metadataURL(for: downloadRetryPack)
        )
        var downloadURLIssueCount = 0
        var packDownloadAttemptCount = 0
        var rejectedTemporaryURLs: [URL] = []
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-download-retry" {
                return (200, jobData(jobId: "job-download-retry", mapId: "map-download-retry"))
            }
            if request.url?.path == "/v1/map-packs/map-download-retry/download-url" {
                downloadURLIssueCount += 1
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: [
                        "mapId": "map-download-retry",
                        "url": "/downloads/map-download-retry-\(downloadURLIssueCount).zip",
                        "expiresAt": 2_000_000_000,
                        "expiresInSeconds": 900,
                    ])
                )
            }
            return (404, Data())
        }
        let downloadRetryManager = OfflineMapManager(
            defaults: downloadRetryDefaults,
            mapPlatformSession: session,
            cacheDirectory: downloadRetryCache,
            packDownload: { _, _, onProgress, _ in
                packDownloadAttemptCount += 1
                if packDownloadAttemptCount <= 2 {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("zip")
                    if packDownloadAttemptCount == 1 {
                        try packData(mapId: "map-from-wrong-job").write(to: url)
                    } else {
                        try packData(
                            mapId: "map-download-retry",
                            storedMapData: Data([0x02]),
                            hashedMapData: Data([0x01])
                        ).write(to: url)
                    }
                    rejectedTemporaryURLs.append(url)
                    return url
                }
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-download-retry").write(to: url)
                return url
            }
        )
        downloadRetryManager.resumePendingMapJobIfNeeded()
        let firstDownloadAttemptCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(firstDownloadAttemptCompleted, "failed download attempt should stop cleanly")
        assert(downloadRetryManager.hasPendingMapJob, "failed download remains recoverable")
        assertEqual(downloadRetryManager.downloadURL, nil, "failed signed URL is discarded")
        assert(
            rejectedTemporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "mismatched downloaded archive is removed"
        )
        assertEqual(
            try? Data(contentsOf: downloadRetryPack),
            originalDownloadRetryPackData,
            "wrong-map replacement preserves the existing cached map"
        )

        downloadRetryManager.resumePendingMapJobIfNeeded()
        let corruptAttemptDeadline = Date().addingTimeInterval(3)
        while downloadURLIssueCount < 2 && Date() < corruptAttemptDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let corruptDownloadAttemptCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(corruptDownloadAttemptCompleted, "corrupt download attempt should stop cleanly")
        assert(downloadRetryManager.hasPendingMapJob, "corrupt download remains recoverable")
        assertEqual(downloadRetryManager.downloadURL, nil, "corrupt download URL is discarded")
        assert(
            rejectedTemporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "hash-mismatched archive is removed"
        )
        assertEqual(
            try? Data(contentsOf: downloadRetryPack),
            originalDownloadRetryPackData,
            "corrupt replacement preserves the existing cached map"
        )

        downloadRetryManager.resumePendingMapJobIfNeeded()
        let retryDeadline = Date().addingTimeInterval(3)
        while downloadURLIssueCount < 3 && Date() < retryDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let retriedDownloadCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(retriedDownloadCompleted, "download retry should complete")
        assertEqual(downloadURLIssueCount, 3, "each download retry obtains a fresh exact-job URL")
        assertEqual(packDownloadAttemptCount, 3, "download retry performs a clean third transfer")
        assert(!downloadRetryManager.hasPendingMapJob, "successful download retry clears recovery state")
        assertEqual(
            downloadRetryManager.displayName(forCachedPack: downloadRetryPack),
            "Shanghai Riverside",
            "same-map replacement preserves the user rename"
        )
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: downloadRetryPack)?.displayName,
            "Shanghai Riverside",
            "same-map replacement persists the user rename in artifact metadata"
        )
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: downloadRetryPack)?.userDefinedDisplayName,
            true,
            "same-map replacement preserves explicit user-name provenance"
        )
        downloadRetryManager.deleteCachedPack(at: downloadRetryPack)

        let stalledSuite = "offline-map-stalled-retry-\(UUID().uuidString)"
        let stalledDefaults = UserDefaults(suiteName: stalledSuite)!
        defer { stalledDefaults.removePersistentDomain(forName: stalledSuite) }
        stalledDefaults.set(
            "https://stalled-retry.example",
            forKey: "offlineMap.serverURL"
        )
        OfflineMapJobPersistence.save(
            jobId: "job-stalled-retry",
            serverURLString: "https://stalled-retry.example",
            defaults: stalledDefaults
        )
        let stalledCache = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "offline-map-stalled-retry-cache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stalledCache) }
        var stalledDownloadURLCount = 0
        var stalledPackAttemptCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-stalled-retry" {
                return (
                    200,
                    jobData(
                        jobId: "job-stalled-retry",
                        mapId: "map-stalled-retry",
                        sourceRegionName: "Shanghai"
                    )
                )
            }
            if request.url?.path == "/v1/map-packs/map-stalled-retry/download-url" {
                stalledDownloadURLCount += 1
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: [
                        "mapId": "map-stalled-retry",
                        "url": "/downloads/map-stalled-retry-\(stalledDownloadURLCount).zip",
                        "expiresAt": 2_000_000_000,
                        "expiresInSeconds": 900,
                    ])
                )
            }
            return (404, Data())
        }
        let stalledManager = OfflineMapManager(
            defaults: stalledDefaults,
            mapPlatformSession: session,
            cacheDirectory: stalledCache,
            packDownload: { _, _, onProgress, onByteProgress in
                stalledPackAttemptCount += 1
                if stalledPackAttemptCount == 1 {
                    onProgress(0.49)
                    onByteProgress(
                        OfflineMapByteProgress(
                            completedBytes: 49,
                            totalBytes: 100
                        )
                    )
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw URLError(.timedOut)
                }
                onProgress(1)
                onByteProgress(
                    OfflineMapByteProgress(
                        completedBytes: 100,
                        totalBytes: 100
                    )
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-stalled-retry").write(to: url)
                return url
            }
        )
        stalledManager.resumePendingMapJobIfNeeded()
        let stalledDeadline = Date().addingTimeInterval(3)
        while stalledManager.downloadByteProgress?.percentage != 49,
              Date() < stalledDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertEqual(
            stalledManager.downloadByteProgress?.percentage,
            49,
            "the fixture reaches the same visible stalled state as production"
        )
        stalledManager.retryPendingMapJob()
        let stalledRetryCompleted = await waitForMapTaskCompletion(
            stalledManager,
            timeout: 5
        )
        assert(stalledRetryCompleted, "retry cancels the stalled attempt and finishes")
        assertEqual(
            stalledDownloadURLCount,
            2,
            "retry obtains a fresh signed URL for the same pending job"
        )
        assertEqual(
            stalledPackAttemptCount,
            2,
            "retry starts exactly one replacement transfer"
        )
        assert(
            !stalledManager.hasPendingMapJob,
            "successful replacement clears the durable pending lock"
        )
        assertEqual(
            stalledManager.downloadProgress,
            1,
            "replacement progress reaches completion instead of retaining 49 percent"
        )
        if let url = stalledManager.downloadedPackURL {
            stalledManager.deleteCachedPack(at: url)
        }

        let retrySuite = "offline-map-discovery-retry-\(UUID().uuidString)"
        let retryDefaults = UserDefaults(suiteName: retrySuite)!
        defer { retryDefaults.removePersistentDomain(forName: retrySuite) }
        retryDefaults.set("https://retry.example", forKey: "offlineMap.serverURL")
        let retryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-retry-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: retryCache) }
        let retryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache
        )
        OfflineMapTestURLProtocol.configure { _ in
            throw URLError(.notConnectedToInternet)
        }
        retryManager.resumePendingMapJobIfNeeded()
        let retryStarted = await waitForMapBusyState(retryManager, expected: true)
        assert(retryStarted, "transient launch discovery enters a retryable busy state")
        assert(retryManager.hasPendingMapJob, "transient launch discovery exposes pause and resume")
        retryManager.pausePendingMapJob()
        let retryPaused = await waitForMapBusyState(retryManager, expected: false)
        assert(retryPaused, "server recovery retry can be paused")
        assert(retryManager.hasPendingMapJob, "paused discovery remains resumable")
        retryManager.forgetPendingMapJob()
        assert(!retryManager.hasPendingMapJob, "paused discovery can be explicitly forgotten")
        let relaunchedRetryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let oldJob = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-forgotten-before-discovery",
                        mapId: "map-forgotten-before-discovery",
                        installationId: relaunchedRetryManager.clientInstallationId,
                        createdAt: "1970-01-01T00:00:00Z"
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [oldJob]]))
            }
            return (404, Data())
        }
        relaunchedRetryManager.resumePendingMapJobIfNeeded()
        let forgottenDeadline = Date().addingTimeInterval(3)
        while relaunchedRetryManager.hasPendingMapJob && Date() < forgottenDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            !relaunchedRetryManager.hasPendingMapJob,
            "forgotten discovery cutoff survives relaunch"
        )
        assertEqual(
            relaunchedRetryManager.currentJob,
            nil,
            "durable forget does not rediscover server jobs that already existed"
        )
        assert(!relaunchedRetryManager.isBusy, "durable forget leaves the app ready for a new map")
        assert(
            !OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: "https://retry.example",
                defaults: retryDefaults
            ),
            "successful discovery consumes the forget marker"
        )

        let futureDiscoveryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-created-after-forget").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let futureJob = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-created-after-forget",
                        mapId: "map-created-after-forget",
                        installationId: futureDiscoveryManager.clientInstallationId,
                        createdAt: "2099-01-01T00:00:00Z"
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [futureJob]]))
            }
            if request.url?.path == "/v1/map-jobs/job-created-after-forget" {
                return (200, jobData(jobId: "job-created-after-forget", mapId: "map-created-after-forget"))
            }
            if request.url?.path == "/v1/map-packs/map-created-after-forget/download-url" {
                return (200, downloadURLData(mapId: "map-created-after-forget"))
            }
            return (404, Data())
        }
        futureDiscoveryManager.resumePendingMapJobIfNeeded()
        let futureDiscoveryCompleted = await waitForMapTaskCompletion(futureDiscoveryManager)
        assert(futureDiscoveryCompleted, "later same-server discovery should complete")
        assert(
            futureDiscoveryManager.downloadedPackURL != nil,
            "one-shot forget does not suppress a map created later"
        )
        if let url = futureDiscoveryManager.downloadedPackURL {
            futureDiscoveryManager.deleteCachedPack(at: url)
        }

        let launch401Suite = "offline-map-launch-401-\(UUID().uuidString)"
        let launch401Defaults = UserDefaults(suiteName: launch401Suite)!
        defer { launch401Defaults.removePersistentDomain(forName: launch401Suite) }
        launch401Defaults.set("https://launch-401.example", forKey: "offlineMap.serverURL")
        let launch401Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-launch-401-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: launch401Cache) }
        let launch401Manager = OfflineMapManager(
            defaults: launch401Defaults,
            mapPlatformSession: session,
            cacheDirectory: launch401Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (401, Data("unauthorized".utf8)) }
        launch401Manager.resumePendingMapJobIfNeeded()
        let launch401Completed = await waitForMapTaskCompletion(launch401Manager)
        assert(launch401Completed, "nonretryable launch discovery should stop")
        assert(launch401Manager.errorMessage?.contains("401") == true, "launch 401 is visible")
        assert(launch401Manager.hasPendingMapJob, "launch 401 remains explicitly dismissible")
        launch401Manager.forgetPendingMapJob()
        assert(!launch401Manager.hasPendingMapJob, "launch 401 escape hatch clears recovery state")

        let deferred401Suite = "offline-map-deferred-refresh-401-\(UUID().uuidString)"
        let deferred401Defaults = UserDefaults(suiteName: deferred401Suite)!
        defer { deferred401Defaults.removePersistentDomain(forName: deferred401Suite) }
        let deferred401Server = "https://deferred-refresh-401.example"
        let staleCredential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
            clientInstallationToken: "v1." + String(repeating: "A", count: 43)
        )
        let replacementCredential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_abcdef1234567890abcdef1234567890",
            clientInstallationToken: "v1." + String(repeating: "B", count: 43)
        )
        deferred401Defaults.set(deferred401Server, forKey: "offlineMap.serverURL")
        try! OfflineMapInstallationCredentialStore(defaults: deferred401Defaults).save(
            staleCredential,
            serverURLString: deferred401Server
        )
        OfflineMapInstallationRefreshBackoff.deferRefresh(
            serverURLString: deferred401Server,
            defaults: deferred401Defaults
        )
        var deferred401RegistrationCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/installations" {
                deferred401RegistrationCount += 1
                if request.url?.query != nil {
                    return (401, Data("retired installation token".utf8))
                }
                return (200, try! JSONEncoder().encode(replacementCredential))
            }
            if request.url?.path == "/v1/map-jobs" {
                if request.value(forHTTPHeaderField: "X-Installation-Token") ==
                    staleCredential.clientInstallationToken {
                    return (401, Data("retired installation token".utf8))
                }
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: ["jobs": []])
                )
            }
            return (404, Data())
        }
        let deferred401Manager = OfflineMapManager(
            defaults: deferred401Defaults,
            mapPlatformSession: session
        )
        deferred401Manager.resumePendingMapJobIfNeeded()
        let deferred401Deadline = Date().addingTimeInterval(3)
        var deferred401Completed = false
        while Date() < deferred401Deadline {
            let savedCredential = OfflineMapInstallationCredentialStore(
                defaults: deferred401Defaults
            ).load(serverURLString: deferred401Server)
            if savedCredential == replacementCredential && !deferred401Manager.isBusy {
                deferred401Completed = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(deferred401Completed, "deferred refresh recovers when its token is retired")
        assertEqual(
            deferred401RegistrationCount,
            2,
            "401 validation bypasses backoff, then issues one replacement credential"
        )
        assertEqual(
            OfflineMapInstallationCredentialStore(defaults: deferred401Defaults).load(
                serverURLString: deferred401Server
            ),
            replacementCredential,
            "401 during refresh backoff persists a usable replacement credential"
        )

        let persisted401Suite = "offline-map-persisted-401-\(UUID().uuidString)"
        let persisted401Defaults = UserDefaults(suiteName: persisted401Suite)!
        defer { persisted401Defaults.removePersistentDomain(forName: persisted401Suite) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted-401",
            serverURLString: "https://persisted-401.example",
            defaults: persisted401Defaults
        )
        let persisted401Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-401-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persisted401Cache) }
        let persisted401Manager = OfflineMapManager(
            defaults: persisted401Defaults,
            mapPlatformSession: session,
            cacheDirectory: persisted401Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (401, Data("unauthorized".utf8)) }
        persisted401Manager.resumePendingMapJobIfNeeded()
        let persisted401Completed = await waitForMapTaskCompletion(persisted401Manager)
        assert(persisted401Completed, "persisted 401 should stop without spinning")
        assert(persisted401Manager.hasPendingMapJob, "persisted 401 retains the recoverable job ID")
        persisted401Manager.forgetPendingMapJob()
        assert(!persisted401Manager.hasPendingMapJob, "persisted 401 can be forgotten")

        let persisted404Suite = "offline-map-persisted-404-\(UUID().uuidString)"
        let persisted404Defaults = UserDefaults(suiteName: persisted404Suite)!
        defer { persisted404Defaults.removePersistentDomain(forName: persisted404Suite) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted-404",
            serverURLString: "https://persisted-404.example",
            defaults: persisted404Defaults
        )
        let persisted404Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-404-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persisted404Cache) }
        let persisted404Manager = OfflineMapManager(
            defaults: persisted404Defaults,
            mapPlatformSession: session,
            cacheDirectory: persisted404Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (404, Data("missing".utf8)) }
        persisted404Manager.resumePendingMapJobIfNeeded()
        let persisted404Completed = await waitForMapTaskCompletion(persisted404Manager)
        assert(persisted404Completed, "persisted 404 should stop")
        assert(!persisted404Manager.hasPendingMapJob, "persisted 404 clears stale durable state")
        assert(persisted404Manager.errorMessage?.contains("404") == true, "persisted 404 is visible")

        let failedSuite = "offline-map-persisted-failure-\(UUID().uuidString)"
        let failedDefaults = UserDefaults(suiteName: failedSuite)!
        defer { failedDefaults.removePersistentDomain(forName: failedSuite) }
        let failedServer = "https://persisted-failure.example"
        let failedInstallationID = "inst_v2_1234567890abcdef1234567890abcdef"
        failedDefaults.set(failedServer, forKey: "offlineMap.serverURL")
        failedDefaults.set(failedInstallationID, forKey: "offlineMap.clientInstallationId")
        try! OfflineMapInstallationCredentialStore(defaults: failedDefaults).save(
            OfflineMapInstallationCredential(
                clientInstallationId: failedInstallationID,
                clientInstallationToken: "v1." + String(repeating: "C", count: 43)
            ),
            serverURLString: failedServer
        )
        OfflineMapJobPersistence.save(
            jobId: "job-persisted-failure",
            serverURLString: failedServer,
            defaults: failedDefaults
        )
        let failedResponse = try! JSONSerialization.data(withJSONObject: [
            "jobId": "job-persisted-failure",
            "status": "failed",
            "errorCode": "building_relation_incomplete",
            "error": "selected building relation closure is incomplete",
            "sourceRegion": [
                "id": "geofabrik-asia-china",
                "name": "Sichuan",
                "provider": "geofabrik",
            ],
        ])
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-persisted-failure" {
                return (200, failedResponse)
            }
            return (404, Data())
        }
        let failedManager = OfflineMapManager(
            defaults: failedDefaults,
            mapPlatformSession: session
        )
        failedManager.resumePendingMapJobIfNeeded()
        let failedJobStopped = await waitForMapTaskCompletion(failedManager)
        assert(failedJobStopped, "failed job recovery should stop")
        assert(failedManager.hasPendingMapJob, "terminal failure stays visible in Saved Maps")
        assert(failedManager.hasTerminalMapJobFailure, "terminal failure is not retryable")
        assertEqual(failedManager.currentJob?.sourceRegion?.name, "Sichuan", "failed map keeps its name")
        assert(
            failedManager.errorMessage?.contains("Some buildings") == true,
            "failed map keeps the actionable server error"
        )

        let relaunchedFailedManager = OfflineMapManager(
            defaults: failedDefaults,
            mapPlatformSession: session
        )
        relaunchedFailedManager.resumePendingMapJobIfNeeded()
        let relaunchedFailedJobStopped = await waitForMapTaskCompletion(relaunchedFailedManager)
        assert(
            relaunchedFailedJobStopped,
            "failed job recovery should also stop after relaunch"
        )
        assert(relaunchedFailedManager.hasPendingMapJob, "failed map survives app relaunch")
        assert(relaunchedFailedManager.hasTerminalMapJobFailure, "relaunch restores terminal state")
        relaunchedFailedManager.forgetPendingMapJob()
        assert(!relaunchedFailedManager.hasPendingMapJob, "failed map can be explicitly discarded")
    }

    @MainActor
    static func testOfflineMapPollerOutlivesLegacyAttemptLimit() async {
        guard let running = offlineMapJob(status: "converting_features"),
              let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "poller test jobs should decode")
            return
        }
        var fetchCount = 0
        let result = try? await OfflineMapJobPoller.waitForReady(
            jobId: "long-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                fetchCount += 1
                return fetchCount <= 1_801 ? running : ready
            },
            sleep: { _ in },
            onUpdate: { _ in },
            onRetry: {}
        )

        assertEqual(fetchCount, 1_802, "poller continues beyond the former 1,800-attempt limit")
        assertEqual(result?.mapId, "map-ready", "poller returns the eventual ready map")
    }

    @MainActor
    static func testOfflineMapPollerRetriesTransientFailure() async {
        guard let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "retry test job should decode")
            return
        }
        var fetchCount = 0
        var retryCount = 0
        var delays: [UInt64] = []
        let result = try? await OfflineMapJobPoller.waitForReady(
            jobId: "retry-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                fetchCount += 1
                if fetchCount == 1 {
                    throw URLError(.timedOut)
                }
                return ready
            },
            sleep: { delays.append($0) },
            onUpdate: { _ in },
            onRetry: { retryCount += 1 }
        )

        assertEqual(result?.mapId, "map-ready", "transient polling failure recovers")
        assertEqual(retryCount, 1, "transient polling failure reports reconnecting state")
        assertEqual(delays, [2_000_000_000], "first retry uses bounded backoff")
        assert(!OfflineMapPollingRetryPolicy.shouldRetry(
            OfflineMapPlatformError.serverStatus(401, "unauthorized")
        ), "authentication failures remain terminal")
    }

    @MainActor
    static func testOfflineMapPollerStopsOnTerminalAndCancellation() async {
        guard let failed = offlineMapJob(
            status: "failed",
            error: "selected building scope exceeds policy; jobId=failed-job",
            errorCode: "building_scope_exceeded"
        ),
              let running = offlineMapJob(status: "converting_features"),
              let exhausted = offlineMapJob(
                status: "failed",
                error: "worker failed; jobId=exhausted-job",
                errorCode: "map_build_failed"
              ),
              let cancelled = offlineMapJob(status: "cancelled"),
              let expired = offlineMapJob(status: "expired"),
              let legacyRetryFailure = offlineMapJob(
                status: "failed",
                error: "temporary worker failure; jobId=legacy-retry-job",
                errorCode: "map_build_failed",
                attempts: 1,
                maxAttempts: 3
              ),
              let queued = offlineMapJob(status: "queued", attempts: 1, maxAttempts: 3),
              let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "terminal poller test jobs should decode")
            return
        }

        var legacyRetryFetchCount = 0
        let legacyRetryResult = try? await OfflineMapJobPoller.waitForReady(
            jobId: "legacy-retry-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                legacyRetryFetchCount += 1
                switch legacyRetryFetchCount {
                case 1...3: return legacyRetryFailure
                case 4: return queued
                default: return ready
                }
            },
            sleep: { _ in },
            onUpdate: { _ in },
            onRetry: {}
        )
        assertEqual(
            legacyRetryResult?.mapId,
            "map-ready",
            "poller tolerates the old worker's transient failed-to-queued transition"
        )
        assertEqual(
            legacyRetryFetchCount,
            5,
            "poller tolerates repeated legacy failures within the bounded grace window"
        )

        var inlineFailureFetchCount = 0
        var inlineFailureClock: TimeInterval = 0
        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "inline-failed-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in
                    inlineFailureFetchCount += 1
                    return legacyRetryFailure
                },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {},
                legacyFailedGraceSeconds: 1,
                monotonicNow: {
                    defer { inlineFailureClock += 2 }
                    return inlineFailureClock
                }
            )
            assert(false, "repeated legacy-shaped failure should be terminal")
        } catch OfflineMapPlatformError.mapJobFailed {
            assertEqual(
                inlineFailureFetchCount,
                2,
                "inline failure stops when the compatibility grace window ends"
            )
        } catch {
            assert(false, "repeated legacy-shaped failure should use platform error")
        }

        assert(exhausted.isTerminal, "a failed final attempt is terminal")

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "failed-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in failed },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "terminal map job should throw")
        } catch OfflineMapPlatformError.mapJobFailed(let code, let message) {
            assertEqual(code, "building_scope_exceeded", "terminal map job preserves typed server code")
            assert(message.contains("selected building scope"), "terminal map job preserves diagnostic detail")
            let displayMessage = OfflineMapPlatformError
                .mapJobFailed(code: code, message: message)
                .localizedDescription
            assert(
                displayMessage.contains("Choose a smaller area"),
                "building scope failure provides an actionable recovery"
            )
            assert(
                !displayMessage.contains("jobId="),
                "building scope failure hides internal diagnostics from the user"
            )
        } catch {
            assert(false, "terminal map job should use platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "exhausted-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in exhausted },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "exhausted map job should throw")
        } catch OfflineMapPlatformError.mapJobFailed(let code, _) {
            assertEqual(code, "map_build_failed", "exhausted map job preserves its stable code")
        } catch {
            assert(false, "exhausted map job should use platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "cancelled-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in cancelled },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "cancelled map job should throw")
        } catch OfflineMapPlatformError.mapJobCancelled {
            assert(
                OfflineMapPlatformError.mapJobCancelled.localizedDescription
                    .contains("was cancelled"),
                "cancelled map job explains what happened"
            )
        } catch {
            assert(false, "cancelled map job should use its typed platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "expired-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in expired },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "expired map job should throw")
        } catch OfflineMapPlatformError.mapJobExpired {
            assert(
                OfflineMapPlatformError.mapJobExpired.localizedDescription
                    .contains("Start a new download"),
                "expired map job provides the recovery action"
            )
        } catch {
            assert(false, "expired map job should use its typed platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "cancel-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in running },
                sleep: { _ in throw CancellationError() },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "cancelled polling should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled polling should preserve CancellationError")
        }
    }

    static func testOfflineMapJobFailureMessages() {
        let internalDiagnostic = "internal details; jobId=failed-job; /private/server/path"
        let expectations: [(String?, String)] = [
            ("building_scope_exceeded", "Choose a smaller area"),
            ("building_source_snapshot_changed", "Retry the same area"),
            ("source_cache_unavailable", "temporarily unavailable"),
            ("building_relation_incomplete", "Adjust the selected area slightly"),
            ("building_calibration_unavailable", "3D building data could not be prepared"),
            ("building_scope_policy_invalid", "temporarily misconfigured"),
            ("map_build_failed", "after several attempts"),
            ("map_stream_format_invalid", "generated map data was invalid"),
            ("map_stream_build_failed", "could not be prepared"),
            ("map_stream_signing_failed", "secured for download"),
            ("artifact_storage_failed", "stored for download"),
            ("future_failure_code", "couldn't build this map"),
            (nil, "couldn't build this map"),
        ]

        for (code, recoveryText) in expectations {
            let codeLabel = code ?? "missing code"
            let displayMessage = OfflineMapPlatformError
                .mapJobFailed(code: code, message: internalDiagnostic)
                .localizedDescription
            assert(
                displayMessage.contains(recoveryText),
                "\(codeLabel) provides actionable recovery guidance"
            )
            assert(
                !displayMessage.contains("jobId=") &&
                    !displayMessage.contains("/private/server/path"),
                "\(codeLabel) hides internal diagnostics from the user"
            )
        }
    }

    static func offlineMapJob(
        jobId: String? = nil,
        status: String,
        mapId: String? = nil,
        error: String? = nil,
        errorCode: String? = nil,
        attempts: Int? = nil,
        maxAttempts: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        clientInstallationId: String? = nil,
        clientRequestId: String? = nil,
        installOnDevice: Bool? = nil
    ) -> OfflineMapJob? {
        var payload: [String: Any] = ["jobId": jobId ?? "job-\(status)", "status": status]
        if let mapId { payload["mapId"] = mapId }
        if let error { payload["error"] = error }
        if let errorCode { payload["errorCode"] = errorCode }
        if let attempts { payload["attempts"] = attempts }
        if let maxAttempts { payload["maxAttempts"] = maxAttempts }
        if let createdAt { payload["createdAt"] = createdAt }
        if let updatedAt { payload["updatedAt"] = updatedAt }
        if let clientInstallationId { payload["clientInstallationId"] = clientInstallationId }
        if let clientRequestId { payload["clientRequestId"] = clientRequestId }
        if let installOnDevice { payload["installOnDevice"] = installOnDevice }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(OfflineMapJob.self, from: data)
    }

    static func testOfflineMapCreateJobURLRequest() {
        let request = OfflineMapJobRequest
            .customBBox(
                OfflineMapBounds(minLon: 10, minLat: 20, maxLon: 11, maxLat: 21)
            )
            .identified(
                clientInstallationId: "installation-test",
                clientRequestId: "request-test-123",
                installOnDevice: false
            )
        guard let url = URL(string: "https://maps.example.com/api") else {
            assert(false, "base URL should parse")
            return
        }
        guard let urlRequest = try? OfflineMapPlatformClient.makeCreateJobURLRequest(
            baseURL: url,
            jobRequest: request
        ) else {
            assert(false, "create job URL request should build")
            return
        }
        assertEqual(urlRequest.url?.absoluteString, "https://maps.example.com/api/v1/map-jobs", "create job URL appends API path")
        assert(
            urlRequest.value(forHTTPHeaderField: "Authorization") == nil,
            "create job request contains no shared authorization token"
        )
        let body = String(data: urlRequest.httpBody ?? Data(), encoding: .utf8) ?? ""
        assert(body.contains("\"mode\":\"custom_bbox\""), "create job body includes mode")
        assert(body.contains("\"bbox\":[10,20,11,21]"), "create job body includes bbox")
        assert(body.contains("\"clientInstallationId\":\"installation-test\""), "create job body includes installation identity")
        assert(body.contains("\"clientRequestId\":\"request-test-123\""), "create job body includes request identity")
        assert(body.contains("\"installOnDevice\":false"), "create job body includes workflow intent")
    }

    static func testOfflineMapListJobsURLRequest() {
        guard let baseURL = URL(string: "https://maps.example.com/api"),
              let request = try? OfflineMapPlatformClient.makeListJobsURLRequest(
                baseURL: baseURL,
                clientInstallationId: "installation-test"
              ) else {
            assert(false, "list jobs URL request should build")
            return
        }

        assertEqual(
            request.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs?clientInstallationId=installation-test",
            "list jobs request filters by installation identity"
        )
        assert(request.value(forHTTPHeaderField: "Authorization") == nil,
               "list jobs request contains no shared authorization token")
        guard let jobRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            path: "/v1/map-jobs/job-12345678",
            method: "GET",
            clientInstallationId: "installation-test"
        ),
        let downloadRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            path: "/v1/map-packs/map-12345678/download-url",
            method: "POST",
            clientInstallationId: "installation-test",
            additionalQueryItems: [
                URLQueryItem(name: "jobId", value: "job-12345678")
            ]
        ) else {
            assert(false, "installation-scoped requests should build")
            return
        }
        assertEqual(
            jobRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678?clientInstallationId=installation-test",
            "job polling is scoped to the installation"
        )
        assertEqual(downloadRequest.httpMethod, "POST", "download URL keeps its POST method")
        assert(
            downloadRequest.url?.query?.contains("clientInstallationId=installation-test") == true,
            "download URL lookup is scoped to the installation"
        )
        assert(
            downloadRequest.url?.query?.contains("jobId=job-12345678") == true,
            "download URL lookup stays bound to the recovered job"
        )
    }

    static func testOfflineMapInventoryMutationURLRequests() {
        guard let baseURL = URL(string: "https://maps.example.com/api"),
              let displayNameRequest = try? OfflineMapPlatformClient.makeUpdateDisplayNameURLRequest(
                baseURL: baseURL,
                clientInstallationId: "installation-test",
                jobId: "job-12345678",
                displayName: "Shanghai and Suzhou"
              ),
              let downloadReceiptRequest = try? OfflineMapPlatformClient.makeRecordDownloadURLRequest(
                baseURL: baseURL,
                clientInstallationId: "installation-test",
                jobId: "job-12345678",
                receipt: OfflineMapDownloadReceiptRequest(
                    receiptId: "receipt-12345678",
                    artifactFormat: "bike-map-stream-v1",
                    sha256: "0123456789abcdef",
                    bytes: 1_234_567
                )
              ) else {
            assert(false, "inventory mutation URL requests should build")
            return
        }

        assertEqual(displayNameRequest.httpMethod, "PATCH", "display name update uses PATCH")
        assertEqual(
            displayNameRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678/display-name?clientInstallationId=installation-test",
            "display name update is scoped to the installation"
        )
        assert(displayNameRequest.value(forHTTPHeaderField: "Authorization") == nil,
               "display name update contains no shared authorization token")
        assertEqual(
            displayNameRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json",
            "display name update sends JSON"
        )
        let displayNameBody = (try? JSONSerialization.jsonObject(
            with: displayNameRequest.httpBody ?? Data()
        )) as? [String: Any]
        assertEqual(
            displayNameBody?["displayName"] as? String,
            "Shanghai and Suzhou",
            "display name update encodes the user label"
        )

        assertEqual(downloadReceiptRequest.httpMethod, "POST", "download receipt uses POST")
        assertEqual(
            downloadReceiptRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678/downloads?clientInstallationId=installation-test",
            "download receipt is scoped to the installation"
        )
        assert(downloadReceiptRequest.value(forHTTPHeaderField: "Authorization") == nil,
               "download receipt contains no shared authorization token")
        assertEqual(
            downloadReceiptRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json",
            "download receipt sends JSON"
        )
        let receiptBody = (try? JSONSerialization.jsonObject(
            with: downloadReceiptRequest.httpBody ?? Data()
        )) as? [String: Any]
        assertEqual(receiptBody?["receiptId"] as? String, "receipt-12345678", "receipt ID is encoded")
        assertEqual(receiptBody?["artifactFormat"] as? String, "bike-map-stream-v1", "artifact format is encoded")
        assertEqual(receiptBody?["sha256"] as? String, "0123456789abcdef", "artifact digest is encoded")
        assertEqual(receiptBody?["bytes"] as? Int, 1_234_567, "artifact size is encoded")
    }

    static func testOfflineMapManagerMigratesProductionConfig() {
        let suite = "offline-map-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io", forKey: "offlineMap.serverURL")
        defaults.set("stale-bundled-token", forKey: "offlineMap.apiToken")

        assertEqual(
            OfflineMapManager.resolvedServerURL(defaults: defaults),
            "https://maps.8o.vc",
            "legacy offline map server URL migrates to production domain"
        )
        OfflineMapSharedSecretMigration.removeLegacyValues(defaults: defaults)
        assert(
            defaults.object(forKey: "offlineMap.apiToken") == nil,
            "app launch removes the legacy shared map API token"
        )
    }

    static func testSavedMapReplacementCrashRecovery() {
        let migrationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        do {
            let legacy = migrationRoot.appendingPathComponent("Caches")
            let saved = migrationRoot.appendingPathComponent("Saved")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("saved".utf8).write(to: legacy.appendingPathComponent("one.zip"))
            _ = try SavedMapStorageDirectory.prepare(directory: saved, legacy: legacy)
            assert(FileManager.default.fileExists(atPath: saved.appendingPathComponent("one.zip").path), "legacy artifact moves outside caches")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("older".utf8).write(to: legacy.appendingPathComponent("one.zip"))
            try Data("other".utf8).write(to: legacy.appendingPathComponent("two.zip"))
            _ = try SavedMapStorageDirectory.prepare(directory: saved, legacy: legacy)
            assertEqual(try Data(contentsOf: saved.appendingPathComponent("one.zip")), Data("saved".utf8), "downgrade migration preserves current map")
            assert(FileManager.default.fileExists(atPath: saved.appendingPathComponent("two.zip").path), "downgrade migration merges missing map")
            assert(FileManager.default.fileExists(atPath: migrationRoot.appendingPathComponent("OfflineMapLegacyRecovery").path), "conflicting legacy bytes retained outside caches")
        } catch { assert(false, "saved map directory migration failed: \(error)") }
        for boundary in 0...4 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let artifact = root.appendingPathComponent("map.zip")
                let metadata = SavedMapArtifactMetadataStore.metadataURL(for: artifact)
                try Data("old".utf8).write(to: artifact)
                try Data("old-meta".utf8).write(to: metadata)
                var journal = try SavedMapReplacementJournal.begin(at: artifact)
                let backup = journal.backup(in: root)
                if boundary >= 1 { try FileManager.default.moveItem(at: artifact, to: backup) }
                if boundary >= 2 {
                    try FileManager.default.moveItem(at: metadata, to: SavedMapArtifactMetadataStore.metadataURL(for: backup))
                    try Data("new".utf8).write(to: artifact)
                }
                if boundary >= 3 { try Data("new-meta".utf8).write(to: metadata) }
                if boundary == 4 { journal.committed = true; try journal.save(in: root) }
                // New process-equivalent state: no in-memory rollback flags.
                try SavedMapReplacementJournal.recover(in: root)
                try SavedMapReplacementJournal.recover(in: root)
                let actual = try String(contentsOf: artifact, encoding: .utf8)
                let actualMetadata = try String(contentsOf: metadata, encoding: .utf8)
                assertEqual(actual, boundary == 4 ? "new" : "old", "crash artifact decision")
                assertEqual(actualMetadata, boundary == 4 ? "new-meta" : "old-meta", "crash metadata decision")
                assert(!FileManager.default.fileExists(atPath: journal.url(in: root).path), "completed recovery removes journal")
            } catch {
                assert(false, "replacement crash recovery failed: \(error)")
            }
        }
        let constraints = OfflineMapDownloadConstraints(
            exactBytes: 100, maximumBytes: 1024,
            allowedDownloadHosts: ["download.example"], artifactSHA256: String(repeating: "a", count: 64)
        )
        let descriptor = DurableMapDownloadCoordinator.Descriptor(constraints: constraints)
        assertEqual(descriptor.key, String(repeating: "a", count: 64) + "-100", "download identity pins digest and bytes")
        assert(descriptor.allows(URL(string: "https://download.example/map")), "approved download host")
        assert(!descriptor.allows(URL(string: "https://127.0.0.1/map")), "download redirects reject other origins")
    }

    static func testSavedMapDefaultNamePolicy() {
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "custom-map-4dc48b9bcb",
                sourceRegionName: "China",
                mapID: "custom-map-4dc48b9bcb"
            ),
            "China",
            "a generated artifact ID never outranks the Geofabrik area name"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "Shanghai Suzhou",
                sourceRegionName: "China",
                mapID: "shanghai-suzhou"
            ),
            "Shanghai Suzhou",
            "an explicit pack name still outranks the source area"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "COVID-19 Rides",
                sourceRegionName: "China",
                mapID: "covid-19-rides"
            ),
            "COVID-19 Rides",
            "explicit artifact punctuation and casing are preserved"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "gravel loop",
                sourceRegionName: "China",
                mapID: "gravel-loop"
            ),
            "gravel loop",
            "explicit lowercase artifact names are preserved"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.preferredSourceName("china-latest.osm.pbf"),
            "China",
            "legacy Geofabrik filenames become readable area names"
        )
        assert(
            !SavedMapDisplayNamePolicy.isGeneratedGenericName("custom-map-weekend"),
            "a user label sharing the old prefix is not mistaken for a generated ID"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "custom-map-deadbeef00",
                sourceRegionName: nil,
                mapID: "custom-map-deadbeef00"
            ),
            "Offline Map",
            "generic IDs are never shown even when legacy metadata has no source"
        )
    }

    @MainActor
    static func testOfflineMapManagerRepairsGeneratedPackDefaults() {
        let suite = "offline-map-default-repair-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "default repair test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-default-repair-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let mapID = "custom-map-4dc48b9bcb"
        let packURL = cacheDirectory.appendingPathComponent("\(mapID).zip")
        let sourceName = "Shanghai and Suzhou"
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": mapID,
            "displayName": mapID,
            "bounds": [120.90, 30.70, 121.95, 31.55],
            "source": [
                "provider": "geofabrik",
                "region": "geofabrik-asia-china",
                "name": sourceName,
                "url": "https://download.geofabrik.de/asia/china-latest.osm.pbf",
            ],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("VECTMAP/\(mapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: packURL)

        let explicitMapID = "marina-bay-rides-deadbeef00"
        let explicitPackURL = cacheDirectory.appendingPathComponent("\(explicitMapID).zip")
        let explicitManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": explicitMapID,
            "displayName": "COVID-19 Rides",
            "bounds": [103.80, 1.25, 103.90, 1.35],
            "source": [
                "provider": "geofabrik",
                "region": "geofabrik-asia-malaysia-singapore-brunei",
                "name": "Malaysia, Singapore, and Brunei",
            ],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", explicitManifest),
            ("VECTMAP/\(explicitMapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: explicitPackURL)

        let prefixedUserMapID = "custom-map-aabbccddee"
        let prefixedUserPackURL = cacheDirectory
            .appendingPathComponent("\(prefixedUserMapID).zip")
        let prefixedUserManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": prefixedUserMapID,
            "displayName": prefixedUserMapID,
            "bounds": [120.90, 30.70, 121.95, 31.55],
            "source": ["name": "China"],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", prefixedUserManifest),
            ("VECTMAP/\(prefixedUserMapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: prefixedUserPackURL)

        let streamMapID = "custom-map-cafebabe00"
        let streamPackURL = cacheDirectory.appendingPathComponent("\(streamMapID).bmap")
        let streamManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": streamMapID,
            "displayName": streamMapID,
            "boundsE7": [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000],
            "source": ["name": "Yangtze Delta"],
        ])
        try! makePreviewReadableBikeMapStream(manifest: streamManifest)
            .write(to: streamPackURL)
        defaults.set(
            [
                packURL.lastPathComponent: mapID,
                prefixedUserPackURL.lastPathComponent: "custom-map-weekend",
            ],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )

        assertEqual(
            manager.displayName(forCachedPack: packURL),
            sourceName,
            "restart repairs an old generated label from manifest source.name"
        )
        assertEqual(
            manager.displayName(forCachedPack: explicitPackURL),
            "COVID-19 Rides",
            "an explicit ZIP manifest name outranks and preserves source metadata"
        )
        assertEqual(
            manager.displayName(forCachedPack: prefixedUserPackURL),
            "custom-map-weekend",
            "a legacy user label sharing the generated prefix is preserved"
        )
        assertEqual(
            defaults.dictionary(forKey: "offlineMap.packDisplayNames")?[
                prefixedUserPackURL.lastPathComponent
            ] as? String,
            "custom-map-weekend",
            "repair does not rewrite a legacy user label that only shares the prefix"
        )
        assertEqual(
            manager.displayName(forCachedPack: streamPackURL),
            "Yangtze Delta",
            "a BMAP manifest source.name is used through the manager display path"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: packURL)?.bounds,
            OfflineMapPreviewBounds(coordinates: [120.90, 30.70, 121.95, 31.55]),
            "a preview-less legacy artifact still exposes bounds for local rendering"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: packURL)?.imageData,
            nil,
            "the bounds fallback does not pretend a legacy artifact embedded an image"
        )
    }

    @MainActor
    static func testOfflineMapManagerRenamesCachedPack() {
        let suite = "offline-map-rename-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "rename test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let packURL = cacheDirectory.appendingPathComponent("custom-map-shanghai.zip")

        let manager = OfflineMapManager(defaults: defaults, cacheDirectory: cacheDirectory)
        var renameInteraction = SavedMapRenameInteraction()
        assertEqual(
            renameInteraction.begin(
                filename: packURL.lastPathComponent,
                currentName: "Shanghai"
            ),
            nil,
            "starting a rename has no previous draft to commit"
        )
        renameInteraction.updateDraft("  Shanghai Riverside  ")
        assertEqual(
            renameInteraction.finishIfFocusMoved(to: packURL.lastPathComponent),
            nil,
            "tapping within the active name field keeps editing"
        )
        guard let tapAwayCommit = renameInteraction.finishIfFocusMoved(to: nil) else {
            assert(false, "tapping elsewhere should produce a rename commit")
            return
        }
        assertEqual(
            tapAwayCommit.filename,
            packURL.lastPathComponent,
            "tap-away commit retains the edited map identity"
        )
        assertEqual(
            manager.renameCachedPack(at: packURL, to: tapAwayCommit.proposedName),
            "Shanghai Riverside",
            "tap-away commit trims surrounding whitespace"
        )
        assertEqual(
            manager.displayName(forCachedPack: packURL),
            "Shanghai Riverside",
            "renamed map is shown immediately"
        )

        let restoredManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )
        assertEqual(
            restoredManager.displayName(forCachedPack: packURL),
            "Shanghai Riverside",
            "renamed map survives app restart"
        )
        assertEqual(
            restoredManager.renameCachedPack(at: packURL, to: "   \n "),
            "Shanghai Riverside",
            "blank rename preserves the existing name"
        )
    }

    static func testSavedMapRenameViewWiring() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            assert(false, "settings view source should be available to the integration test")
            return
        }
        assert(
            source.contains("focusedPackFilename: $focusedSavedMapFilename"),
            "settings form passes its focus binding into Saved Maps"
        )
        guard let savedMapsSectionStart = source.range(
            of: "private struct SavedMapsSettingsSection"
        )?.lowerBound,
        let savedMapRowStart = source.range(
            of: "private struct SavedMapRow",
            range: savedMapsSectionStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "saved-map view source boundaries should be present")
            return
        }
        let settingsRootSource = String(source[..<savedMapsSectionStart])
        let savedMapsSectionSource = String(
            source[savedMapsSectionStart..<savedMapRowStart]
        )
        guard let pendingSavedMapRowStart = source.range(
            of: "private struct PendingSavedMapRow",
            range: savedMapsSectionStart..<source.endIndex
        )?.lowerBound,
        let offlineMapProgressRowStart = source.range(
            of: "private struct OfflineMapProgressRow",
            range: pendingSavedMapRowStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "pending saved-map row source boundaries should be present")
            return
        }
        let pendingSavedMapRowSource = String(
            source[pendingSavedMapRowStart..<offlineMapProgressRowStart]
        )
        assert(
            settingsRootSource.contains(
                "item: settingsSheetPresentation,"
            ) &&
                settingsRootSource.contains(
                    "case .savedMapShare(let url):"
                ) &&
                settingsRootSource.contains(
                    "SavedMapShareSheet(url: url)"
                ) &&
                settingsRootSource.contains(
                    "presentCreatedShareIfNeeded"
                ) &&
                !savedMapsSectionSource.contains("createdShareURL") &&
                !savedMapsSectionSource.contains(".sheet("),
            "share-map presentation is item-driven from the stable Settings root"
        )
        assert(
            source.contains("Spacer()\n                    .contentShape(Rectangle())\n                    .onTapGesture {\n                        focusedPackFilename = nil\n                    }"),
            "tapping outside the saved-map name clears focus without covering form controls"
        )
        let normalizedSource = source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        assert(
            normalizedSource.contains(
                "manager.beginMapAreaSelection()\n}\nif manager.isMapAreaSelectionActive {\ndismiss()"
            ) &&
                source.contains("manager.discardPendingMapAndBeginSelection()") &&
                source.contains("requestNewMapSelection()"),
            "Download a new Map resolves a pending map before selection and dismisses Settings"
        )
        assert(
            savedMapsSectionSource.contains("let hasPendingMapRow") &&
                savedMapsSectionSource.contains(
                    "OfflineMapDownloadingSectionPresentation.isRecoveryOnly("
                ) &&
                savedMapsSectionSource.contains(
                    "!manager.hasLocallySavedPendingMap"
                ) &&
                savedMapsSectionSource.contains("PendingSavedMapRow(") &&
                source.contains("private struct PendingSavedMapRow") &&
                !savedMapsSectionSource.contains(".listRowBackground(") &&
                source.contains("title: \"Progress\"") &&
                source.contains("let progressFraction = manager.activityProgress") &&
                !source.contains("title: \"Feature Conversion\"") &&
                !source.contains("title: \"Download Progress\"") &&
                source.contains("preparationEstimatePresentation") &&
                source.contains(
                    "OfflineMapPreparationEstimatePresentation.presentation(for: job)"
                ) &&
                pendingSavedMapRowSource.contains(
                    "Text(preparationEstimatePresentation.value)"
                ) &&
                pendingSavedMapRowSource.contains(
                    ".frame(maxWidth: .infinity, alignment: .trailing)"
                ) &&
                !pendingSavedMapRowSource.contains(
                    "Text(preparationEstimatePresentation.title)"
                ) &&
                source.contains("Label(\"Retry Download\"") &&
                source.contains("Button(\"Choose Another Map\"") &&
                source.contains("if manager.errorMessage != nil"),
            "the pending download uses one friendly progress row and the normal Saved Maps background"
        )
        assert(
            source.contains(".onChange(of: focusedPackFilename) { newValue in\n            scheduleRenameCommitIfNeeded(focusedFilename: newValue)\n        }"),
            "Saved Maps commits a rename when form focus moves away"
        )
        assert(
            !source.contains("title: \"Installed on Device\"") &&
                !source.contains("title: \"Last Transfer\""),
            "Saved Maps omits redundant device and transfer summary rows"
        )
        assert(
            source.contains("if item.isActiveOnDevice {") &&
                source.contains("Image(systemName: \"checkmark.circle.fill\")") &&
                source.contains("? \"arrow.clockwise.circle\"") &&
                source.contains(": \"arrow.up.circle\"") &&
                !source.contains("IPhoneDownloadStatusIcon") &&
                !source.contains("Image(systemName: \"iphone\")") &&
                !source.contains("BikeComputerMapStatusIcon") &&
                !source.contains("Text(\"b\")"),
            "saved maps use the same active check and inactive upload icons regardless of origin"
        )
        assert(
            source.contains("Text(\"No offline maps yet\")"),
            "Saved Maps uses the agreed empty-state copy"
        )
        assert(
            source.contains("This map is not saved on this iPhone") &&
                source.contains("is active on the Bike Computer") &&
                source.contains("Transfer \\(displayName) to device"),
            "saved-map presence indicators expose accessible state labels"
        )
        assert(
            source.contains("manager.resumePausedMapUpload(bleManager: bleManager)") &&
                source.contains("Map upload paused. Tap to resume."),
            "the paused status row resumes the matching map transfer"
        )
        assert(
            source.contains(".alert(\"Already on Device\""),
            "tapping installed status explains that the map is already on the device"
        )
        assert(
            source.contains("manager.isAwaitingMapActivationConfirmation") &&
                source.contains("clock.arrow.circlepath") &&
                source.contains("Waiting for the Bike Computer to confirm") &&
                source.contains("bleManager.requestMapTransferStatus()"),
            "ambiguous activation waits for authenticated status instead of offering another upload"
        )
        assert(
            source.contains("isShowingDeleteConfirmation = true") &&
                source.contains("\"Delete Saved Map?\"") &&
                source.contains("Button(\"Delete\", role: .destructive)"),
            "deleting a saved map requires explicit confirmation"
        )
        assert(
            source.contains("if item.canRemoveFromMapLibrary") &&
                source.contains(
                    "Button(\"Remove from Map Library\", role: .destructive)"
                ) &&
                source.contains("manager.removeCatalogMapFromLibrary(map)"),
            "remote-only maps expose a clearly named confirmed library removal action"
        )
        assert(
            source.contains("catalogAvailability?.statusText") &&
                source.contains("catalogAvailability?.canDownload != true") &&
                source.contains("clock.badge.exclamationmark"),
            "catalog rows explain and disable downloads that are pending or incompatible"
        )
        assert(
            source.contains("DevelopmentMapsSettingsView(manager: offlineMapManager)") &&
                source.contains("scope: .developerMaps") &&
                source.contains("scope: scope") &&
                source.contains("if scope == .savedMaps"),
            "Developer Settings owns development-only rows without a new-map action"
        )
        assert(
            source.contains(
                "let catalogArtifactNeedsRefresh = manager.catalogArtifactNeedsRefresh(for: item)"
            ) &&
                source.contains("Label(\"Updated map available\"") &&
                source.contains(".accessibilityLabel(\"Update \\(displayName) on this iPhone\")") &&
                source.contains("manager.isDeviceTransferBusy ||") &&
                source.contains("manager.hasActiveBackgroundUpload ||") &&
                source.contains("isPausedUpload ||"),
            "a stale local catalog artifact offers a current verified download before transfer"
        )
        assert(
            source.contains("SavedMapDeviceTransferPolicy.canStart(") &&
                source.contains("isDeviceTransferBusy: manager.isDeviceTransferBusy") &&
                source.contains("manager.hasActiveBackgroundUpload") &&
                source.contains("manager.retryPendingMapJob(bleManager: bleManager)"),
            "map controls separate server work from conflicting device transfers"
        )
        assert(
            source.contains("let uploadProgress = packURL.flatMap") &&
                source.contains("title: \"Uploading to Bike Computer\"") &&
                source.contains("title: manager.lastTransferOutcome == \"uploading\"") &&
                source.contains("\"Installing on Bike Computer\""),
            "the matching Saved Maps row shows upload and activation progress beneath its name"
        )
        assert(
            source.contains("SavedMapThumbnail(") &&
                source.contains("let previewImage = manager.previewImage(for: item)") &&
                source.contains("manager.loadPreviewIfNeeded(for: item)") &&
                source.contains(".frame(width: 52, height: 36)"),
            "each saved map shows a fixed-size preview before its editable name"
        )
        assert(
            source.contains("presentedPreview = SavedMapPreviewPresentation(") &&
                source.contains(".sheet(item: $presentedPreview, onDismiss:") &&
                source.contains("SavedMapPreviewSheet(manager: manager, preview: preview)") &&
                source.contains(".accessibilityLabel(\"Show preview for \\(displayName)\")") &&
                source.contains("Button(\"Close\")"),
            "tapping an available saved-map thumbnail opens an accessible preview modal"
        )
        let previewSource = String(source.components(separatedBy: "private struct SavedMapPreviewSheet: View {").last ?? "")
        assert(
            previewSource.contains("Label(\"Share this map\", systemImage: \"square.and.arrow.up\")") &&
                previewSource.contains(".font(.subheadline.weight(.semibold))") &&
                previewSource.contains("RoundedRectangle(cornerRadius: 24, style: .continuous)") &&
                previewSource.contains("onShareRequested()") &&
                source.contains("guard shareAfterPreviewDismissal else { return }") &&
                !source.contains(".accessibilityLabel(\"Share \\(displayName)\")"),
            "sharing lives beneath the preview with workout styling and waits for modal dismissal"
        )
        assert(
            source.contains("manager.detailPreviewImage(for: preview.item)") &&
                source.contains("Loading high-resolution preview") &&
                source.contains(".interpolation(.high)") &&
                source.contains(".task(id: preview.id)") &&
                source.contains(
                    "await manager.loadDetailPreviewIfNeeded(for: preview.item)"
                ),
            "the preview modal upgrades its thumbnail through cancellable Retina loading"
        )
        assert(
            source.contains("manager.savedMapListItems(") &&
                source.contains("activeDeviceMap: bleManager.activeDeviceMap") &&
                source.contains("manager.updateActiveDeviceMap(descriptor)"),
            "Saved Maps includes and tracks the connected Bike Computer inventory"
        )
        let managerSourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift"
        )
        guard let managerSource = try? String(contentsOf: managerSourceURL, encoding: .utf8) else {
            assert(false, "offline map manager source should be available to the integration test")
            return
        }
        assert(
            managerSource.contains("Task.detached(priority: .utility)") &&
                managerSource.contains("OfflineMapPackPreviewReader.content(for: packURL)") &&
                managerSource.contains("OfflineMapFallbackPreviewRenderer.image") &&
                !managerSource.contains("packURLs.forEach(cachePreviewIfAvailable)"),
            "saved-map previews load lazily and render bounds when an old pack has no image"
        )
        assert(
            managerSource.contains("size: CGSize(width: 400, height: 240)") &&
                managerSource.contains("scale: 3") &&
                managerSource.contains("detail-preview-v\\(cacheVersion).png") &&
                managerSource.contains("minimumLongestEdge: UInt32 = 600") &&
                managerSource.contains("SavedMapSnapshotPreviewStore.save(") &&
                managerSource.contains("SavedMapDetailPreviewStore.save("),
            "thumbnail and versioned Retina detail previews use independent cache policies"
        )
        assert(
            managerSource.contains(
                "refreshCachedPacks()\n#if canImport(UIKit)\n        loadPreviewIfNeeded(forCachedPack: destination)"
            ),
            "replacing a pack at the same URL explicitly reloads its invalidated preview"
        )
        assert(
            !managerSource.contains("uploadArchiveInBackground(") &&
                !managerSource.contains("materializeLegacyFallback(") &&
                managerSource.contains(
                    "throw OfflineMapPlatformError.firmwareMapStreamUnsupported"
                ) &&
                managerSource.range(
                    of: #"\btlsCertificateSHA256:\s*transferSession\.tlsCertificateSHA256\s*,"#,
                    options: .regularExpression
                ) != nil,
            "device map installation is signed-stream-only and pins background TLS"
        )
        let platformSourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift"
        )
        let securitySourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferSecurity.swift"
        )
        guard let platformSource = try? String(
            contentsOf: platformSourceURL,
            encoding: .utf8
        ), let securitySource = try? String(
            contentsOf: securitySourceURL,
            encoding: .utf8
        ) else {
            assert(false, "device transfer security sources should be available")
            return
        }
        assert(
            securitySource.contains(
                "_ session: URLSession,\n        didReceive challenge: URLAuthenticationChallenge"
            ) &&
                platformSource.contains("session.getAllTasks { tasks in") &&
                platformSource.contains(
                    "challenge.protectionSpace.port"
                ),
            "foreground and restorable transfers pin connection-level TLS challenges"
        )
    }

    static func testSettingsSheetPresentationWiring() {
        let screensSource = try! String(contentsOfFile:
            "ios-app/BikeComputer/BikeComputer/Views/DeviceScreensSettingsView.swift",
            encoding: .utf8
        )
        let settingsURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        let routesURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift"
        )
        guard let settingsSource = try? String(
            contentsOf: settingsURL,
            encoding: .utf8
        ), let routesSource = try? String(
            contentsOf: routesURL,
            encoding: .utf8
        ) else {
            assert(
                false,
                "settings and saved-routes sources should be available to the integration test"
            )
            return
        }

        assert(
            settingsSource.contains(
                "private enum SettingsSheetDestination: Identifiable, Equatable"
            ) &&
                settingsSource.contains(
                    "@State private var presentedSheet: SettingsSheetDestination?"
                ) &&
                settingsSource.contains(
                    "item: settingsSheetPresentation,"
                ) &&
                settingsSource.contains(
                    "presentedSheet = .stravaRouteImport"
                ) &&
                settingsSource.contains("case .stravaRouteImport:") &&
                settingsSource.contains("StravaRouteImportView("),
            "Strava import is item-driven from the stable Settings root"
        )
        assert(
            routesSource.contains("let onImportFromStrava: () -> Void") &&
                routesSource.contains("onImportFromStrava()") &&
                !routesSource.contains("isImportingStrava") &&
                !routesSource.contains(".sheet("),
            "Saved Routes requests presentation without owning a transient sheet"
        )
        assert(
            settingsSource.contains("presentedSheet = .addDeviceScreen") &&
                settingsSource.contains("case .addDeviceScreen:") &&
                settingsSource.contains("AddDeviceScreenSheet(") &&
                screensSource.contains("let onAddScreen: () -> Void") &&
                screensSource.contains("onAddScreen()") &&
                !screensSource.contains(".sheet(") &&
                screensSource.contains("Button(\"Cancel\") { dismiss() }"),
            "Add Screen is routed from the stable Settings presenter and dismisses only its own sheet"
        )
        let statusFollowsAddScreen: Bool
        if let addScreenMarker = screensSource.range(of: "device-screen-add"),
           let statusMarker = screensSource.range(
               of: "statusContent",
               range: addScreenMarker.upperBound..<screensSource.endIndex
           ) {
            statusFollowsAddScreen = addScreenMarker.lowerBound < statusMarker.lowerBound
        } else {
            statusFollowsAddScreen = false
        }
        assert(
            !screensSource.contains("Reorder Screens") &&
                !screensSource.contains("Done Reordering") &&
                screensSource.contains(".onMove(perform: controller.move)") &&
                !screensSource.contains("Button(\"Save to Bicino\")") &&
                !screensSource.contains("Button(\"Cancel Changes\"") &&
                screensSource.contains("Text(\"Bicino Screens\")") &&
                settingsSource.contains("header: Text(\"Bicino Screens\")") &&
                !screensSource.contains("Changes save automatically.") &&
                !screensSource.contains("Changes will save automatically.") &&
                !screensSource.contains("Saving changes to Bicino…") &&
                screensSource.contains("Text(\"Saving changes\")") &&
                screensSource.contains("Saved to Bicino") &&
                screensSource.contains("2_000_000_000") &&
                statusFollowsAddScreen &&
                !screensSource.contains("Button(\"Save to Bike Computer\")") &&
                !screensSource.contains(".disabled(!controller.canSave)"),
            "Bicino screen actions autosave with transient feedback below Add Screen"
        )
        assert(
            screensSource.contains("Text(\"Preferred\").tag(UInt8(1))") &&
                screensSource.contains("Text(\"Local + Preferred\").tag(UInt8(2))") &&
                screensSource.contains("Text(\"Follow Roads\").tag(UInt8(0))") &&
                screensSource.contains("Text(\"Keep Upright\").tag(UInt8(1))"),
            "per-instance label controls preserve the established wire semantics"
        )
        assert(
            screensSource.contains("TextField(\"Name\", text: instanceBinding.name)") &&
                screensSource.contains("controller.draft?.instances.first(where:") &&
                !screensSource.contains("@State private var instance:"),
            "screen editors bind to current controller state after snapshot refresh"
        )
        guard let remoteStart = settingsSource.range(
            of: "private struct RemoteDeviceDebugSettingsSection"
        )?.lowerBound,
        let replayStart = settingsSource.range(
            of: "private struct RendererBenchmarkReplaySettingsSection",
            range: remoteStart..<settingsSource.endIndex
        )?.lowerBound else {
            assert(false, "remote-debug settings source should be available")
            return
        }
        let remoteSource = String(settingsSource[remoteStart..<replayStart])
        assert(
            remoteSource.contains("NavigationLink {") &&
                remoteSource.contains(
                    "RemoteDeviceDebugConsoleView(session: session)"
                ) &&
                !remoteSource.contains(".sheet("),
            "the secure console stays in Settings navigation instead of presenting a nested sheet"
        )
    }

    static func testStravaRouteCatalogUIWiring() {
        let viewURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/StravaRouteImportView.swift"
        )
        let coordinatorURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Services/StravaIntegrationCoordinator.swift"
        )
        let clientURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Services/StravaIntegrationClient.swift"
        )
        guard let view = try? String(contentsOf: viewURL, encoding: .utf8),
              let coordinator = try? String(
                  contentsOf: coordinatorURL,
                  encoding: .utf8
              ),
              let client = try? String(contentsOf: clientURL, encoding: .utf8)
        else {
            assert(false, "Strava route catalog sources should be available")
            return
        }

        assert(
            view.contains("if coordinator.isRouteCatalogAuthorized {") &&
                view.contains(
                    "routeCatalogSection\n                    routeURLSection"
                ) &&
                view.contains("} else {\n                    connectSection") &&
                view.contains("coordinator.connect()") &&
                view.contains("Text(\"Connect with Strava\")"),
            "the disconnected sheet offers connection while catalog and URL import are authorization-gated"
        )
        assert(
            view.contains("ForEach(coordinator.athleteRoutes)") &&
                view.contains("Text(route.name)") &&
                view.contains("distanceText(route.distanceMeters)") &&
                view.contains("elevationText(route.elevationGainMeters)") &&
                view.contains("route.type.displayName") &&
                view.contains("coordinator.importRoute(route)") &&
                view.contains("Text(\"Import\")"),
            "authorized athlete routes show the required summary and import action"
        )
        assert(
            view.contains("case .idle, .loading:") &&
                view.contains("case .empty, .loaded:") &&
                view.contains("case .loadingMore(let loadedRouteCount):") &&
                view.contains("case .authorizationExpired:") &&
                view.contains("case .failed(let message):") &&
                view.contains("Button(\"Try Again\")"),
            "the route catalog presents loading, empty, pagination, expired, and retryable error states"
        )
        assert(
            coordinator.contains("while true {") &&
                coordinator.contains("client.athleteRoutes(page: page)") &&
                coordinator.contains("guard let nextPage = result.nextPage") &&
                coordinator.contains("page = nextPage") &&
                client.contains("/v1/integrations/strava/routes") &&
                client.contains("URLQueryItem(name: \"page\"") &&
                !view.contains("accessToken") &&
                !view.contains("refreshToken") &&
                !client.contains("accessToken") &&
                !client.contains("refreshToken"),
            "pagination stays behind the installation-authenticated client without exposing Strava tokens"
        )
    }

    static func testLandingMapConnectionStatusPositioning() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/ContentView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let overlayStart = source.range(
                  of: "private var topOverlay: some View"
              )?.lowerBound,
              let overlayEnd = source.range(
                  of: "private var mapAppearance: IPhoneMapAppearance",
                  range: overlayStart..<source.endIndex
              )?.lowerBound
        else {
            assert(false, "landing-map connection overlay source should be available")
            return
        }

        let overlaySource = String(source[overlayStart..<overlayEnd])
        assert(
            overlaySource.contains("ConnectionStatusView(") &&
                overlaySource.contains(".frame(maxWidth: .infinity, alignment: .center)") &&
                overlaySource.contains(".offset(y: -8)"),
            "the landing map raises the Bicino connection status without changing its layout space"
        )
        guard let statusTitleStart = source.range(
            of: "private var offlineMapStatusTitle: String"
        )?.lowerBound,
        let mapViewStart = source.range(
            of: "// MARK: - Map View",
            range: statusTitleStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "offline-map status title source boundaries should be present")
            return
        }
        let statusTitleSource = String(source[statusTitleStart..<mapViewStart])
        assert(
            statusTitleSource.contains("Map is downloading") &&
                statusTitleSource.contains(
                    "Map is ready to upload to your Bicino"
                ) &&
                !statusTitleSource.contains(
                    "return offlineMapManager.statusMessage"
                ),
            "the landing map uses friendly stable download and upload-ready copy"
        )
    }

    static func testDeviceScreenUISettingsWiring() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            assert(false, "settings view source should be available to the integration test")
            return
        }

        assert(
            !source.contains("UICustomizationSettingsView") &&
                !source.contains("UI Customization"),
            "Settings removes the standalone UI Customization destination"
        )

        guard let deviceSectionStart = source.range(
            of: "private struct DeviceScreensSettingsSection"
        )?.lowerBound,
        let overlaySectionStart = source.range(
            of: "private struct NavigationOverlaysSettingsSection",
            range: deviceSectionStart..<source.endIndex
        )?.lowerBound,
        let mapStyleStart = source.range(
            of: "private enum MapStyleScreen",
            range: overlaySectionStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "device-screen settings source boundaries should be present")
            return
        }
        let deviceSection = String(source[deviceSectionStart..<overlaySectionStart])
        let overlaySection = String(source[overlaySectionStart..<mapStyleStart])

        assert(
            deviceSection.contains("HStack(spacing: 4)") &&
                deviceSection.contains("Image(systemName: \"gearshape\")") &&
                deviceSection.contains(
                    "width: 44,\n" +
                        "                                    height: 44,\n" +
                        "                                    alignment: .leading"
                ) &&
                deviceSection.contains(".contentShape(Rectangle())") &&
                deviceSection.contains(".buttonStyle(.borderless)") &&
                deviceSection.contains(".labelsHidden()"),
            "map-screen rows keep a close-leading accessible gear and trailing toggle"
        )
        guard let rowText = deviceSection.range(
            of: "Text(screen.title)"
        ),
        let gearCondition = deviceSection.range(
            of: "if let styleScreen = mapStyleScreen(for: screen)",
            range: rowText.upperBound..<deviceSection.endIndex
        ),
        let gearDestination = deviceSection.range(
            of: "MapStyleSettingsView(",
            range: gearCondition.upperBound..<deviceSection.endIndex
        ),
        let destinationBinding = deviceSection.range(
            of: "screen: styleScreen",
            range: gearDestination.upperBound..<deviceSection.endIndex
        ),
        let gearImage = deviceSection.range(
            of: "Image(systemName: \"gearshape\")",
            range: destinationBinding.upperBound..<deviceSection.endIndex
        ),
        let trailingSpacer = deviceSection.range(
            of: "Spacer()",
            range: gearImage.upperBound..<deviceSection.endIndex
        ),
        let screenToggle = deviceSection.range(
            of: "Toggle(",
            range: trailingSpacer.upperBound..<deviceSection.endIndex
        ),
        let screenGetter = deviceSection.range(
            of: "bleManager.isDeviceScreenEnabled(screen)",
            range: screenToggle.upperBound..<deviceSection.endIndex
        ),
        let screenSetter = deviceSection.range(
            of: "bleManager.setDeviceScreen(",
            range: screenGetter.upperBound..<deviceSection.endIndex
        ),
        let setterScreen = deviceSection.range(
            of: "screen,",
            range: screenSetter.upperBound..<deviceSection.endIndex
        ),
        let setterValue = deviceSection.range(
            of: "enabled: $0",
            range: setterScreen.upperBound..<deviceSection.endIndex
        ),
        let lastScreenGuard = deviceSection.range(
            of: ".disabled(bleManager.isOnlyEnabledDeviceScreen(screen))",
            range: setterValue.upperBound..<deviceSection.endIndex
        ) else {
            assert(
                false,
                "each row should keep its routed gear, screen-specific toggle, and last-screen guard"
            )
            return
        }
        assert(
            rowText.lowerBound < gearCondition.lowerBound &&
                gearCondition.lowerBound < gearDestination.lowerBound &&
                gearDestination.lowerBound < destinationBinding.lowerBound &&
                destinationBinding.lowerBound < gearImage.lowerBound &&
                gearImage.lowerBound < trailingSpacer.lowerBound &&
                trailingSpacer.lowerBound < screenToggle.lowerBound &&
                screenToggle.lowerBound < screenGetter.lowerBound &&
                screenGetter.lowerBound < screenSetter.lowerBound &&
                screenSetter.lowerBound < setterScreen.lowerBound &&
                setterScreen.lowerBound < setterValue.lowerBound &&
                setterValue.lowerBound < lastScreenGuard.lowerBound,
            "each map gear sits beside its label before the trailing screen toggle"
        )
        assert(
            deviceSection.contains("case .map:\n            return .map") &&
                deviceSection.contains("case .mapPlusNavigation:") &&
                deviceSection.contains("? .mapPlusNavigation\n                : .map") &&
                deviceSection.contains(
                    "case .navigation, .rideStats, .batteryStatus, .worldRadio:\n            return nil"
                ),
            "only Map rows receive gears and legacy firmware opens the shared map profile"
        )
        assert(
            deviceSection.contains(
                "This firmware uses one shared style for Map and Map + Navigation."
            ) &&
                deviceSection.contains(
                    "Shared Map Screens UI settings, affects Map and Map + Navigation"
                ),
            "legacy shared-profile behavior is visible and accurately announced"
        )

        guard let developerStart = source.range(
            of: "private struct DeveloperSettingsView"
        )?.lowerBound else {
            assert(false, "developer settings source boundary should be present")
            return
        }
        let developerSource = String(source[developerStart...])
        let rootSettingsSource = String(source[..<developerStart])
        guard let rootBodyStart = source.range(
            of: "var body: some View {"
        )?.lowerBound,
        let rootBodyEnd = source.range(
            of: "private var shouldPromoteBikeComputerSettings",
            range: rootBodyStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "root settings body boundaries should be present")
            return
        }
        let rootBodySource = String(source[rootBodyStart..<rootBodyEnd])
        assert(
            !rootBodySource.contains("MapLibrarySettingsView") &&
                developerSource.contains(
                    "MapLibrarySettingsView(manager: offlineMapManager)"
                ) &&
                developerSource.contains(
                    "Label(\"Map Library\", systemImage: \"map.circle\")"
                ),
            "Map Library is available only from Developer Settings"
        )
        let developerDownloadStatus = developerSource.range(
            of: "DownloadingMapsSettingsSection(manager: offlineMapManager)"
        )
        let developerMapServer = developerSource.range(
            of: "Section(header: Text(\"Map Server\"))"
        )
        assert(
            !rootBodySource.contains(
                "DownloadingMapsSettingsSection(manager: offlineMapManager)"
            ) &&
                developerSource.contains("offlineMapManager.hasActiveBackgroundUpload") &&
                developerDownloadStatus != nil &&
                developerMapServer != nil &&
                developerDownloadStatus!.lowerBound < developerMapServer!.lowerBound,
            "the full active map status appears only at the top of Developer Settings"
        )
        assert(
            developerSource.contains("Button(action: useProductionMapServer)") &&
                developerSource.contains(
                    "OfflineMapServiceConfig.productionServerURLString"
                ) &&
                developerSource.contains("Button(action: useDevelopmentMapServer)") &&
                developerSource.contains(
                    "OfflineMapServiceConfig.developmentServerURLString"
                ),
            "Developer Settings explicitly selects production or development maps"
        )
        assert(
            !rootSettingsSource.contains("title: \"App Version\"") &&
                developerSource.contains("Section(header: Text(\"App\"))") &&
                developerSource.contains("title: \"App Version\"") &&
                developerSource.contains("value: appVersionText"),
            "App Version appears only in Developer Settings"
        )
        assert(
            developerSource.contains(
                "NavigationOverlaysSettingsSection()\n        }\n        .navigationTitle(\"Developer Settings\")"
            ),
            "Navigation Overlays is the final Developer Settings form section"
        )
        assert(
            overlaySection.contains(
                "Toggle(\"Route Line\", isOn: $bleManager.showRouteOverlay)\n" +
                    "                .onChange(of: bleManager.showRouteOverlay) { _ in\n" +
                    "                    bleManager.sendVisibilityMask()"
            ) &&
                overlaySection.contains(
                    "Toggle(\"Current Position\", isOn: $bleManager.showCurrentPosition)\n" +
                        "                .onChange(of: bleManager.showCurrentPosition) { _ in\n" +
                        "                    bleManager.sendVisibilityMask()"
                ) &&
                overlaySection.components(
                    separatedBy: "bleManager.sendVisibilityMask()"
                ).count - 1 == 2 &&
                overlaySection.contains(
                    ".disabled(!bleManager.supportsDeviceSettings)"
                ),
            "Navigation Overlays retains both BLE callbacks and its capability guard"
        )
    }

    static func testSavedRouteNamingAndViewWiring() {
        let suite = "saved-route-name-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "route rename test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstRouteID = UUID()
        let secondRouteID = UUID()
        var names = SavedRouteDisplayNames(defaults: defaults)
        assertEqual(
            names.displayName(routeID: firstRouteID, defaultName: "Original"),
            "Original",
            "a route starts with its archive name"
        )
        assertEqual(
            names.rename(
                routeID: firstRouteID,
                defaultName: "Original",
                to: "  Riverside Ride  "
            ),
            "Riverside Ride",
            "route rename trims surrounding whitespace"
        )
        names.persist(to: defaults)
        var restoredNames = SavedRouteDisplayNames(defaults: defaults)
        assertEqual(
            restoredNames.displayName(
                routeID: firstRouteID,
                defaultName: "Original"
            ),
            "Riverside Ride",
            "route rename survives app restart"
        )
        assertEqual(
            restoredNames.rename(
                routeID: firstRouteID,
                defaultName: "Original",
                to: "  \n "
            ),
            "Riverside Ride",
            "blank route rename preserves the existing name"
        )
        _ = restoredNames.rename(
            routeID: secondRouteID,
            defaultName: "Second",
            to: "Second Ride"
        )
        assert(restoredNames.remove(routeID: secondRouteID),
               "deleting a route removes its local display name")
        assertEqual(
            restoredNames.displayName(
                routeID: secondRouteID,
                defaultName: "Second"
            ),
            "Second",
            "pruned routes fall back to their archive name"
        )

        var interaction = SavedRouteRenameInteraction()
        assertEqual(
            interaction.begin(routeID: firstRouteID, currentName: "Original"),
            nil,
            "starting a route rename has no previous draft"
        )
        interaction.updateDraft("Morning Ride")
        assertEqual(
            interaction.finishIfFocusMoved(to: firstRouteID),
            nil,
            "focus inside the active route field keeps editing"
        )
        assertEqual(
            interaction.finishIfFocusMoved(to: nil),
            SavedRouteRenameCommit(
                routeID: firstRouteID,
                proposedName: "Morning Ride"
            ),
            "moving focus commits the matching route rename"
        )

        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift"
        )
        guard let source = try? String(
            contentsOf: sourceURL,
            encoding: .utf8
        ) else {
            assert(false, "Saved Routes source should be available")
            return
        }
        assert(
            source.contains("Text(\"Saved Routes\")") &&
                source.contains(
                    "Choose an online route to save or preview a saved route. Watch-supported routes are queued automatically."
                ),
            "Saved Routes uses the requested title and explanatory copy"
        )
        assert(
            source.contains("favoriteButton(for: route") &&
                source.contains("Image(systemName: favorite == nil ? \"star\" : \"star.fill\")") &&
                source.contains("Label(\"Save an Online Route\"") &&
                !source.contains("Navigate on iPhone") &&
                !source.contains("Available offline") &&
                !source.contains("Apple Maps · Saved on this iPhone"),
            "Saved Routes merges favorite state and removes obsolete route labels"
        )
        assert(
            source.contains("retrySendButton(route") &&
                !source.contains("arrow.up.circle") &&
                !source.contains("cancelSendButton("),
            "Saved Routes auto-queues Watch routes and only exposes failed-transfer retry"
        )
        assert(
            source.contains("TextField(\n                \"Route name\"") &&
                source.contains("SavedRouteRenameInteraction()"),
            "saved route names are editable inline"
        )
        assert(
            source.contains("case .ready:") &&
                source.contains("Image(systemName: \"checkmark.circle.fill\")") &&
                !source.contains("Ready on Watch"),
            "Watch-ready routes use an inline green status icon without a second-row label"
        )
        assert(
            !source.contains("Powered by Strava") &&
                source.contains("Link(\"View on Strava\", destination: url)"),
            "saved Strava routes keep their source link without the Powered by Strava label"
        )
    }

    @MainActor
    static func testTopographicMapChoicesAreIndependent() {
        let suite = "topographic-map-choices-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = OfflineMapManager(defaults: defaults)
        manager.topographicMapsEnabled = true
        assertEqual(
            try? manager.makeCustomBBoxRequest().target?.rendererFormatVersion,
            3,
            "showing saved iPhone contours does not turn a new map into a topo job"
        )
        manager.serverURLString =
            OfflineMapServiceConfig.developmentServerURLString
        manager.includeTopographyInNewMaps = true
        manager.topographicMapsEnabled = false
        assertEqual(
            try? manager.makeCustomBBoxRequest().target?.rendererFormatVersion,
            4,
            "topographic map detail requests format 4 independently of iPhone visibility"
        )
        let restored = OfflineMapManager(defaults: defaults)
        assert(restored.includeTopographyInNewMaps,
               "topographic map detail remains selected on the supported production server")
        assert(!restored.topographicMapsEnabled,
               "iPhone contour visibility survives independently")

        manager.serverURLString =
            OfflineMapServiceConfig.productionServerURLString
        assert(manager.includeTopographyInNewMaps,
               "switching to production preserves the supported topo choice")
        assertEqual(
            try? manager.makeCustomBBoxRequest().target?.rendererFormatVersion,
            4,
            "production map creation requests topography when selected")

        let contentView = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/ContentView.swift"
        )
        guard let source = try? String(contentsOf: contentView, encoding: .utf8) else {
            assert(false, "content view source should be available")
            return
        }
        assert(source.contains("$offlineMapManager.includeTopographyInNewMaps") &&
               source.contains("$offlineMapManager.topographicMapsEnabled"),
               "active map selection and Layers menu expose separate topo controls")
    }

    @MainActor
    static func testOfflineMapManagerRecoversDurableOperationIndependentlyOfSummary() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deviceID = String(repeating: "a", count: 32)
        let namespace = BackgroundMapUploadSessionNamespace.identifier(
            bundleIdentifier: Bundle.main.bundleIdentifier)

        func cancellationReceipt(for record: DeviceMapOperationRecord) throws -> DeviceMapOperationReceipt {
            try JSONDecoder().decode(DeviceMapOperationReceipt.self,
                from: JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1, "deviceID": record.deviceID,
                    "operationID": record.wireOperationID, "sessionID": record.sessionID,
                    "mapID": record.mapID, "manifestReceipt": record.manifestReceipt,
                    "signedManifestReceipt": record.signedManifestReceipt,
                    "streamSHA256": record.streamSHA256, "streamBytes": record.streamBytes,
                    "phase": "cancelled", "revision": 1]))
        }

        for scenario in ["unknown", "installed", "unconfirmed", "legacy", "other-device", "other-app", "terminal"] {
            let suite = "map-operation-recovery-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                fatalError("test defaults unavailable")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("previous-map", forKey: "offlineMap.lastTransfer.mapId")
            defaults.set("previous-session", forKey: "offlineMap.lastTransfer.sessionId")
            defaults.set("previous.bmap", forKey: "offlineMap.lastTransfer.artifactFilename")
            let previousOutcome = ["unknown", "installed", "unconfirmed"].contains(scenario)
                ? scenario : "unknown"
            defaults.set(previousOutcome, forKey: "offlineMap.lastTransfer.outcome")

            let fixtureDeviceID = scenario == "other-device"
                ? String(repeating: "e", count: 32) : deviceID
            let fixtureNamespace = scenario == "other-app"
                ? "other.app.map-transfer.background" : namespace
            var record = DeviceMapOperationRecord(
                schemaVersion: 1, deviceID: fixtureDeviceID, operationID: UUID(),
                sessionID: "pending-session", mapID: "pending-map",
                manifestReceipt: String(repeating: "b", count: 64),
                signedManifestReceipt: String(repeating: "c", count: 64),
                streamSHA256: String(repeating: "d", count: 64), streamBytes: 123,
                artifactFilename: "pending.bmap", appNamespace: fixtureNamespace,
                createdAt: Date(timeIntervalSince1970: 1), connectionEpoch: 7,
                observation: "result_unknown", cleanup: "pending", usesDurableProtocol: true,
                lastReceipt: nil, cancellationRequestedAt: Date(timeIntervalSince1970: 2))
            if scenario == "legacy" { record.usesDurableProtocol = false }
            if scenario == "installed" { record.observation = "cancel_requested" }
            if scenario == "terminal" {
                let receipt = try! cancellationReceipt(for: record)
                assert(record.apply(receipt), "terminal history requires an exact device receipt")
                record.cleanup = "complete"
            }
            defaults.set(record.operationID.uuidString, forKey: "offlineMap.deviceOperationID")
            let store = DeviceMapOperationStore(url: directory
                .appendingPathComponent("\(scenario)/operations.json"))
            do {
                try store.save(record)
                let original = try store.records()
                let manager = OfflineMapManager(defaults: defaults,
                    cacheDirectory: directory.appendingPathComponent("\(scenario)/cache"))
                manager.useMapOperationStoreForTesting(store)
                let ble = MapOperationRecoveryTestBLEManager()
                ble.recoveryDeviceID = deviceID
                ble.isConnected = true
                ble.isNavigationReady = true
                manager.reconcileLastTransfer(bleManager: ble)

                if ["unknown", "installed", "unconfirmed"].contains(scenario) {
                    assertEqual(ble.requestedOperationIDs, [record.wireOperationID],
                        "an unresolved durable operation is queried independently of the \(scenario) summary")
                    assertEqual(manager.lastTransferMapId, record.mapID,
                        "recovery projects the operation's canonical map identity")
                    assertEqual(defaults.string(forKey: "offlineMap.lastTransfer.sessionId"), record.sessionID,
                        "recovery projects the exact operation session")
                    assertEqual(defaults.string(forKey: "offlineMap.lastTransfer.artifactFilename"), record.artifactFilename,
                        "recovery cannot retain an unrelated artifact filename")
                    assertEqual(manager.lastTransferOutcome, "unconfirmed",
                        "recovery awaits a device receipt instead of inferring success")
                    assert(record.blocksNewTransfer(connectionEpoch: ble.transferConnectionEpoch,
                        processID: DeviceMapOperationStore.observationProcessID),
                        "admission remains fenced until an exact terminal receipt")
                } else {
                    assert(ble.requestedOperationIDs.isEmpty,
                        "\(scenario) history cannot acquire durable recovery")
                    assertEqual(manager.lastTransferMapId, "previous-map",
                        "\(scenario) history cannot replace the transfer summary")
                    assertEqual(manager.lastTransferOutcome, previousOutcome,
                        "\(scenario) history keeps its outcome")
                }
                assertEqual(try store.records(), original,
                    "summary recovery preserves cancellation, receipts and the original observation binding")
                if scenario == "unknown" {
                    let unavailable = try JSONSerialization.data(withJSONObject: [
                        "operation": ["schemaVersion": 1, "deviceID": record.deviceID,
                            "operationID": record.wireOperationID, "status": "result_unavailable"]])
                    assert(ble.handleMapTransferStatusNotification(
                        Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + unavailable),
                        "recovery receives a fresh authenticated exact-operation reply")
                    let queriesBeforeRecovery = ble.requestedOperationIDs.count
                    manager.reconcileLastTransfer(bleManager: ble)
                    assert(manager.isDeviceTransferBusy,
                        "a fresh unavailable result starts the saved precommit cancellation recovery")
                    assertEqual(ble.requestedOperationIDs.count, queriesBeforeRecovery,
                        "polling must not clear the fresh proof before the scheduled recovery uses it")
                    manager.reconcileLastTransfer(bleManager: ble)
                    assertEqual(ble.requestedOperationIDs.count, queriesBeforeRecovery,
                        "polling yields while the foreground recovery owns query and control")
                    assertEqual(try store.records(), original,
                        "starting transport recovery does not infer a terminal map result")
                }
                if ["unknown", "installed", "unconfirmed"].contains(scenario) {
                    let receipt = try cancellationReceipt(for: record)
                    guard let terminal = try store.ingest(receipt) else {
                        fatalError("exact cancellation receipt must reconcile the original operation")
                    }
                    ble.isConnected = false
                    ble.isNavigationReady = false
                    manager.reconcileLastTransfer(bleManager: ble)
                    assertEqual(manager.lastTransferOutcome, "cancelled",
                        "an exact device receipt settles the canonical recovered map")
                    assert(!terminal.blocksNewTransfer(connectionEpoch: ble.transferConnectionEpoch,
                        processID: DeviceMapOperationStore.observationProcessID),
                        "only the exact terminal result releases operation admission")
                }
            } catch {
                fatalError("map operation recovery fixture \(scenario) failed: \(error)")
            }
        }
    }

    @MainActor
    static func testOfflineMapManagerRestoresLastTransferIdentity() {
        let suite = "offline-map-transfer-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("custom-map-shanghai", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("shanghai-session", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set(
            ["custom-map-shanghai.zip": "Shanghai"],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(defaults: defaults)
        assertEqual(manager.lastTransferMapId, "custom-map-shanghai", "last transfer map id survives app restart")
        assertEqual(manager.lastTransferOutcome, "unconfirmed", "last transfer outcome survives app restart")
        assertEqual(manager.lastTransferDescription, "Shanghai — unconfirmed", "last transfer identifies the selected saved map")
        assert(manager.hasPendingDeviceActivation,
               "unconfirmed activation keeps its status visible after app restart")

        let bleManager = BLEManager()
        bleManager.mapTransferActiveMapId = "old-map"
        bleManager.mapTransferActiveSessionId = "old-session"
        bleManager.mapTransferActivationStatus = "idle"
        manager.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(
            manager.statusMessage,
            "Waiting for device map status",
            "a restored transfer waits for fresh authenticated device status"
        )
        for staleState in ["installed", "failed", "activating"] {
            bleManager.mapTransferActiveMapId = "custom-map-shanghai"
            bleManager.mapTransferActiveSessionId = "shanghai-session"
            bleManager.mapTransferActivationMapId = "custom-map-shanghai"
            bleManager.mapTransferActivationSessionId = "shanghai-session"
            bleManager.mapTransferActivationStatus = staleState
            bleManager.mapTransferActivationSequence = 3
            bleManager.mapTransferActivationStep = 2
            bleManager.mapTransferActivationStepCount = 3
            bleManager.mapTransferActivationProgress = 90
            manager.reconcileLastTransfer(bleManager: bleManager)
            assertEqual(manager.lastTransferOutcome, "unconfirmed",
                        "stale cached \(staleState) cannot settle the restored attempt")
            assertEqual(manager.statusMessage, "Waiting for device map status",
                        "stale cached \(staleState) preserves the fresh-status wait")
            assert(manager.activationProgress == nil && manager.errorMessage == nil,
                   "stale progress and failures are not projected before authenticated status")
        }
        bleManager.applyAuthenticatedMapTransferStatus(
            MapTransferDeviceStatus(
                enabled: false,
                activeMapId: "old-map",
                activeSessionId: "old-session",
                activation: nil,
                protocols: [1, 2],
                streamFormatVersions: [1],
                streamTrust: nil,
                firmwareVersion: nil,
                firmwareBuild: nil,
                firmwareGitSha: nil
            )
        )
        manager.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(manager.lastTransferOutcome, "unknown",
                    "an idle rebooted device does not claim activation is still running")
        assertEqual(
            manager.statusMessage,
            "The device result for this map was not observed. Send it again to verify the installation.",
            "an unobservable result asks for a verifying re-send instead of polling forever"
        )
        assert(!manager.hasPendingDeviceActivation, "an unknown result stops activation polling")
    }

    @MainActor
    static func testOfflineMapManagerResendsUnobservedLegacyResult() {
        let suite = "offline-map-unobserved-result-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("map-1-manifest", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set(4, forKey: "offlineMap.lastTransfer.previousSequence")
        // The device rebooted after selecting this session: the pointer remains,
        // but no activation for it survives and no terminal result will arrive.
        let bleManager = BLEManager()
        bleManager.applyAuthenticatedMapTransferStatus(
            try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
            {"activeMapId":"map-1","activeSessionId":"map-1-manifest"}
            """.utf8)))

        let observing = OfflineMapManager(defaults: defaults)
        observing.recordTransferObservationForTesting(connectionEpoch: bleManager.transferConnectionEpoch)
        observing.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(observing.lastTransferOutcome, "unconfirmed",
                    "the observing connection keeps waiting for its own terminal activation")

        let unbound = OfflineMapManager(defaults: defaults)
        unbound.recordTransferObservationForTesting(connectionEpoch: bleManager.transferConnectionEpoch &+ 1)
        unbound.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(unbound.lastTransferOutcome, "unknown",
                    "an exact pointer after a reconnect or reboot is not installation evidence")
        assert(!unbound.hasPendingDeviceActivation && unbound.activationProgress == nil,
               "an unknown result stops polling and clears stale progress")

        for state in ["installed", "failed"] {
            bleManager.applyAuthenticatedMapTransferStatus(
                try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
                {"activeMapId":"map-1","activeSessionId":"map-1-manifest","activation":{"status":"\(state)","sequence":5,"sessionId":"map-1-manifest","mapId":"map-1"}}
                """.utf8)))
            for reconnected in [false, true] {
                defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
                let restored = OfflineMapManager(defaults: defaults)
                if reconnected {
                    restored.recordTransferObservationForTesting(
                        connectionEpoch: bleManager.transferConnectionEpoch &+ 1)
                }
                restored.reconcileLastTransfer(bleManager: bleManager)
                assertEqual(restored.lastTransferOutcome, "unknown",
                            "a terminal \(state) cannot bind after relaunch or reconnect")
                assert(!restored.hasPendingDeviceActivation && restored.activationProgress == nil &&
                       restored.errorMessage == nil,
                       "an unbound terminal result leaves the verifying re-send available")
            }
            defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
            let current = OfflineMapManager(defaults: defaults)
            current.recordTransferObservationForTesting(connectionEpoch: bleManager.transferConnectionEpoch)
            current.reconcileLastTransfer(bleManager: bleManager)
            assertEqual(current.lastTransferOutcome, state,
                        "the original observing connection still accepts matching terminal status")
        }
    }

    @MainActor
    static func testOfflineMapManagerReconcilesInterruptedActivation() {
        let suite = "offline-map-reconcile-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("activating", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("map-1-manifest", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set("map-1", forKey: "offlineMap.lastTransfer.previousMapId")
        defaults.set(4, forKey: "offlineMap.lastTransfer.previousSequence")

        let manager = OfflineMapManager(defaults: defaults)
        assertEqual(manager.lastTransferOutcome, "unconfirmed", "interrupted activation restores as unconfirmed")

        let bleManager = BLEManager()
        let provisional = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
        {"activeMapId":"map-1","activeSessionId":"map-1-manifest","activation":{"status":"finalizing","sequence":5,"sessionId":"map-1-manifest","mapId":"map-1","step":2,"steps":3,"progress":90}}
        """.utf8))
        bleManager.applyAuthenticatedMapTransferStatus(provisional)
        manager.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(manager.lastTransferOutcome, "unconfirmed",
                    "restored candidate pointer cannot complete finalizing activation")
        assert(manager.hasPendingDeviceActivation, "restored operation remains pending before renderer acceptance")
        let terminal = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
        {"activeMapId":"map-1","activeSessionId":"map-1-manifest","activation":{"status":"installed","sequence":5,"sessionId":"map-1-manifest","mapId":"map-1"}}
        """.utf8))
        bleManager.applyAuthenticatedMapTransferStatus(terminal)
        manager.reconcileLastTransfer(bleManager: bleManager)

        assertEqual(manager.lastTransferOutcome, "unknown", "a terminal legacy result cannot bind after app restart")
        assert(!manager.hasPendingDeviceActivation,
               "an unbound terminal result clears pending activation status for a verifying re-send")
        assertEqual(
            manager.activationProgress,
            nil,
            "installed reconciliation clears restored in-progress presentation"
        )
    }

    @MainActor
    static func testOfflineMapManagerReconcilesAcknowledgedFirstInstall() {
        let suite = "offline-map-first-install-reconcile-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("map-1-manifest", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set(9, forKey: "offlineMap.lastTransfer.acceptedSequence")

        let manager = OfflineMapManager(defaults: defaults)
        let bleManager = BLEManager()
        manager.recordTransferObservationForTesting(connectionEpoch: bleManager.transferConnectionEpoch)
        let terminal = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
        {"activeMapId":"map-1","activeSessionId":"map-1-manifest","activation":{"status":"installed","sequence":9,"sessionId":"map-1-manifest","mapId":"map-1"}}
        """.utf8))
        bleManager.applyAuthenticatedMapTransferStatus(terminal)
        manager.reconcileLastTransfer(bleManager: bleManager)

        assertEqual(manager.lastTransferOutcome, "installed",
                    "the original observing connection reconciles its activation acknowledgement")
    }

    static func testOfflineMapPolygonClosesRing() {
        let request = OfflineMapJobRequest.customPolygon(ring: [
            CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 1, longitude: 3),
            CLLocationCoordinate2D(latitude: 2, longitude: 3),
            CLLocationCoordinate2D(latitude: 2, longitude: 2)
        ])
        guard case .polygon(let rings)? = request.geometry?.coordinates else {
            assert(false, "custom polygon should encode polygon coordinates")
            return
        }
        assertEqual(rings[0].first, rings[0].last, "custom polygon closes outer ring")
    }

    static func testOfflineMapStoredZipReader() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-test-\(UUID().uuidString).zip")
        let manifest = Data("{\"schemaVersion\":1}".utf8)
        let block = Data("map-block".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("ATTRIBUTION.txt", Data("OpenStreetMap".utf8)),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", block)
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "stored zip archive should parse")
            return
        }

        assertEqual(archive.mapFileEntries.count, 1, "zip reader exposes VECTMAP file entries")
        assertEqual(archive.manifestEntry?.path, "manifest.json", "zip reader exposes manifest entry")
        assertEqual(try? archive.data(for: archive.mapFileEntries[0]), block, "zip reader reads entry data")
        assert(
            !MapArchiveUploadStrategy.requiresCompatibilityArchive(for: archive),
            "legacy ZIPs without preview entries retain background archive transfer"
        )

        let duplicateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-duplicate-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: duplicateURL) }
        let duplicatePath = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        let duplicateManifest = try! JSONSerialization.data(withJSONObject: [
            "mapId": "map-1",
            "files": [[
                "path": duplicatePath,
                "bytes": block.count,
                "sha256": FirmwareUpdateManager.sha256Hex(block),
            ]],
        ])
        let duplicateZip = makeStoredZip(entries: [
            ("manifest.json", duplicateManifest),
            (duplicatePath, block),
            (duplicatePath, block),
        ])
        try? duplicateZip.write(to: duplicateURL)
        do {
            let duplicateArchive = try OfflineMapPackArchive(url: duplicateURL)
            try duplicateArchive.validate(expectedMapId: "map-1")
            assert(false, "duplicate map entries should be rejected")
        } catch OfflineMapPlatformError.invalidPack {
            // Expected.
        } catch {
            assert(false, "duplicate map entries should produce invalidPack")
        }
    }

    static func testOfflineMapPackPreviewReader() {
        let preview = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let previewMetadata: [String: Any] = [
            "type": "boundary-png",
            "path": "preview.png",
            "width": 1,
            "height": 1,
            "background": "transparent",
            "dataBase64": preview.base64EncodedString(),
        ]
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": "map-1",
            "boundsE7": [1_037_500_000, 12_400_000, 1_039_300_000, 13_700_000],
            "preview": previewMetadata,
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-preview-\(UUID().uuidString).zip")
        try? makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("ATTRIBUTION.txt", Data("OpenStreetMap contributors".utf8)),
            ("LICENSES/OpenStreetMap-ODbL.txt", Data("ODbL".utf8)),
            ("preview.png", preview),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: url),
            preview,
            "stored map packs expose their boundary preview"
        )
        guard let previewArchive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "preview ZIP should parse for transfer strategy")
            return
        }
        assert(
            MapArchiveUploadStrategy.requiresCompatibilityArchive(for: previewArchive),
            "preview ZIPs require a device-compatible upload archive"
        )
        let compatibilityURL = try! OfflineMapPackCompatibilityArchive.make(
            from: previewArchive
        )
        defer { OfflineMapPackCompatibilityArchive.remove(compatibilityURL) }
        let compatibilityArchive = try! OfflineMapPackArchive(url: compatibilityURL)
        let orphanURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bike-map-device-\(UUID().uuidString).zip")
        try! Data("orphan".utf8).write(to: orphanURL)
        OfflineMapPackCompatibilityArchive.removeOrphans()
        assert(
            FileManager.default.fileExists(atPath: compatibilityURL.path),
            "orphan cleanup protects a compatibility archive in active preparation"
        )
        assert(
            !FileManager.default.fileExists(atPath: orphanURL.path),
            "orphan cleanup removes a compatibility archive left by a prior process"
        )
        assert(
            !compatibilityArchive.entries.contains(where: { $0.path == "preview.png" }),
            "device compatibility archive omits the local-only preview"
        )
        assert(
            compatibilityArchive.entries.contains(where: {
                $0.path == "ATTRIBUTION.txt"
            }) && compatibilityArchive.entries.contains(where: {
                $0.path == "LICENSES/OpenStreetMap-ODbL.txt"
            }),
            "device compatibility archive preserves attribution and license files"
        )
        assert(
            !MapArchiveUploadStrategy.requiresCompatibilityArchive(
                for: compatibilityArchive
            ),
            "sanitized ZIP remains on the resumable background upload path"
        )
        assertEqual(
            try? compatibilityArchive.data(for: compatibilityArchive.manifestEntry!),
            manifest,
            "device compatibility archive preserves the manifest"
        )
        assertEqual(
            try? compatibilityArchive.data(for: compatibilityArchive.mapFileEntries[0]),
            Data("map-block".utf8),
            "device compatibility archive preserves map payloads"
        )
        let compatibilityData = try! Data(contentsOf: compatibilityURL)
        let endRecordOffset = compatibilityData.count - 22
        assertEqual(
            readUInt32LE(compatibilityData, offset: endRecordOffset),
            0x0605_4B50,
            "device compatibility archive writes a ZIP end record"
        )
        assertEqual(
            readUInt16LE(compatibilityData, offset: endRecordOffset + 10),
            UInt16(compatibilityArchive.entries.count),
            "device compatibility archive indexes every retained entry"
        )
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", compatibilityURL.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try! unzip.run()
        unzip.waitUntilExit()
        assertEqual(
            unzip.terminationStatus,
            0,
            "device compatibility archive is structurally valid ZIP"
        )
        assertEqual(
            OfflineMapPackPreviewReader.imageData(fromManifestData: manifest),
            preview,
            "stream manifests expose their inline signed boundary preview"
        )
        let stream = makePreviewReadableBikeMapStream(manifest: manifest)
        let streamURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-preview-\(UUID().uuidString).bmap")
        try? stream.write(to: streamURL)
        defer { try? FileManager.default.removeItem(at: streamURL) }
        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: streamURL),
            preview,
            "cached signed streams expose their inline boundary preview"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: streamURL)?.bounds,
            OfflineMapPreviewBounds(coordinates: [103.75, 1.24, 103.93, 1.37]),
            "cached signed streams retain bounds for the local thumbnail fallback"
        )

        var corruptPreview = previewMetadata
        corruptPreview["width"] = "wide"
        let corruptManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": "map-1",
            "preview": corruptPreview,
        ])
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-corrupt-preview-\(UUID().uuidString).zip")
        try? makeStoredZip(entries: [
            ("manifest.json", corruptManifest),
            ("preview.png", Data("not-a-png".utf8)),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        guard let archive = try? OfflineMapPackArchive(url: corruptURL),
              let decodedManifest = try? archive.manifest() else {
            assert(false, "a corrupt optional preview must not invalidate the map archive")
            return
        }
        assertEqual(decodedManifest.preview, nil, "malformed preview metadata is ignored")
        assertEqual(archive.mapFileEntries.count, 1, "map transfer entries remain available")
        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: corruptURL),
            nil,
            "corrupt previews fall back without throwing"
        )
    }

    @MainActor
    static func testOfflineMapPreviewLoadRegistry() {
        let registry = OfflineMapPreviewLoadRegistry()
        let key = "/maps/shanghai.zip"
        let stale = registry.begin(for: key)
        registry.invalidate(key)
        let current = registry.begin(for: key)

        assert(
            !registry.finishIfCurrent(stale, for: key),
            "a stale preview completion cannot retire its replacement load"
        )
        assert(
            registry.finishIfCurrent(current, for: key),
            "the replacement preview load remains current and publishable"
        )
        let invalidated = registry.begin(for: key)
        registry.removeAll()
        assert(
            !registry.finishIfCurrent(invalidated, for: key),
            "cache reset invalidates every outstanding preview load"
        )
    }

    static func testOfflineMapCompatibilityArchiveCancellation() async {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-compat-cancel-\(UUID().uuidString).zip")
        let mapPath = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        try? makeStoredZip(entries: [
            ("manifest.json", Data("{\"mapId\":\"map-1\"}".utf8)),
            ("preview.png", Data("preview".utf8)),
            (mapPath, Data(repeating: 0x5a, count: 2 * 1_048_576)),
        ]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let archive = try? OfflineMapPackArchive(url: sourceURL) else {
            assert(false, "compatibility cancellation archive should parse")
            return
        }
        func temporaryCompatibilityPaths() -> Set<String> {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            return Set(files.filter {
                $0.lastPathComponent.hasPrefix("bike-map-device-") &&
                    $0.pathExtension.lowercased() == "zip"
            }.map { $0.standardizedFileURL.path })
        }

        let pathsBefore = temporaryCompatibilityPaths()
        let gate = AsyncTestGate()
        let preparation = Task.detached {
            await gate.wait()
            return try OfflineMapPackCompatibilityArchive.make(from: archive)
        }
        preparation.cancel()
        await gate.open()
        do {
            let unexpectedURL = try await preparation.value
            OfflineMapPackCompatibilityArchive.remove(unexpectedURL)
            assert(false, "cancelled compatibility preparation should not publish a ZIP")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled compatibility preparation should throw CancellationError")
        }
        assertEqual(
            temporaryCompatibilityPaths(),
            pathsBefore,
            "cancelled compatibility preparation removes its registered partial ZIP"
        )
    }

    static func testOfflineMapArchiveValidationCancellation() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-cancel-test-\(UUID().uuidString).zip")
        let path = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        let block = Data(repeating: 0x5a, count: 2 * 1_048_576)
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "mapId": "map-1",
            "files": [[
                "path": path,
                "bytes": block.count,
                "sha256": FirmwareUpdateManager.sha256Hex(block),
            ]],
        ])
        try? makeStoredZip(entries: [
            ("manifest.json", manifest),
            (path, block),
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "cancellation test archive should parse")
            return
        }
        let validation = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            try archive.validate(expectedMapId: "map-1")
        }
        validation.cancel()
        do {
            try await validation.value
            assert(false, "cancelled archive validation should not publish a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled archive validation should throw CancellationError")
        }
    }

    @MainActor
    static func testCachedMapInstalledIdentityUsesManifestSession() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-1.zip")
        let newManifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\",\"revision\":2}".utf8)
        let oldManifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\",\"revision\":1}".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", newManifest),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8))
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let suite = "cached-map-identity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = OfflineMapManager(defaults: defaults)
        let oldSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: oldManifest
        )
        let newSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: newManifest
        )

        assert(
            !manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: oldSession
            ),
            "a regenerated same-ID cached pack is not marked installed for the old session"
        )
        assert(
            manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: newSession
            ),
            "the exact cached manifest session is marked installed"
        )
        assert(
            !manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: ""
            ),
            "legacy firmware cannot hide upload for a regenerated same-area pack"
        )

        let streamURL = url.deletingPathExtension().appendingPathExtension("bmap")
        try? Data([0x01]).write(to: streamURL)
        defer {
            try? FileManager.default.removeItem(at: streamURL)
            try? SavedMapArtifactMetadataStore.delete(for: streamURL)
        }
        let signedReceipt = String(repeating: "a", count: 64)
        let legacyFallbackSession = "map-1-legacy-session"
        let streamArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map-1.bmap",
            objectKey: "maps/map-1/bike-map-stream-v1/key/\(signedReceipt).bmap",
            bytes: 1,
            sha256: String(repeating: "b", count: 64),
            manifestReceipt: String(repeating: "c", count: 64),
            signedManifestReceipt: signedReceipt,
            signatureKeyId: "key",
            signatureKeySha256: String(repeating: "d", count: 64),
            producerBuildSha256: String(repeating: "1", count: 64),
            requiredIosBuild: nil,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        try? SavedMapArtifactMetadataStore.save(
            SavedMapArtifactMetadata(
                schemaVersion: 1,
                mapID: "map-1",
                displayName: "Map 1",
                localArtifactFilename: streamURL.lastPathComponent,
                streamFormatVersion: 1,
                rendererFormatVersion: nil,
                jobID: "job-1",
                serverURLString: "https://maps.example",
                clientInstallationID: "installation",
                primaryArtifact: streamArtifact,
                legacyArtifact: nil,
                lastTransferProtocol: 1,
                lastTransferStreamFormat: nil,
                lastTransferSessionID: legacyFallbackSession,
                lastBackgroundTaskID: nil,
                lastDeviceSequence: nil,
                lastDeviceState: "installed",
                lastDeviceStep: 3,
                lastDeviceStepCount: 3,
                lastDeviceProgress: 100,
                expectedActiveMapID: "map-1",
                expectedActiveSessionID: legacyFallbackSession,
                lastTransferOutcome: "installed"
            ),
            for: streamURL
        )
        assert(
            manager.isCachedPackInstalled(
                streamURL,
                activeMapId: "map-1",
                activeSessionId: legacyFallbackSession
            ),
            "a canonical stream map installed through v1 recognizes its legacy session"
        )
        assert(
            manager.isCachedPackInstalled(
                streamURL,
                activeMapId: "map-1",
                activeSessionId: signedReceipt
            ),
            "the same canonical stream map still recognizes a later v2 install"
        )
    }

    @MainActor
    static func testSavedMapInventoryMergesOnlyExactDeviceContent() {
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saved-map-inventory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let manifestData = Data("""
        {"schemaVersion":1,"mapId":"map-1","displayName":"Phone Map"}
        """.utf8)
        let packURL = cacheDirectory.appendingPathComponent("map-1.zip")
        try? makeStoredZip(entries: [
            ("manifest.json", manifestData),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: packURL)
        let suite = "saved-map-inventory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )
        let exactSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: manifestData
        )
        let exactDevice = DeviceActiveMapDescriptor(
            mapID: "map-1",
            sessionID: exactSession,
            displayName: "Device Name",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!

        var items = manager.savedMapListItems(activeDeviceMap: exactDevice)
        assertEqual(items.count, 1, "the exact device and iPhone map collapse into one row")
        assert(items[0].isOnIPhone && items[0].isActiveOnDevice,
               "the merged row exposes both presence states")
        assertEqual(items[0].displayName, "Phone Map",
                    "a local saved name wins when exact content is merged")

        let regeneratedDevice = DeviceActiveMapDescriptor(
            mapID: "map-1",
            sessionID: "different-session",
            displayName: "Cloned SD Map",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!
        items = manager.savedMapListItems(activeDeviceMap: regeneratedDevice)
        assertEqual(items.count, 2,
                    "same map ID with different content stays as separate device and phone rows")
        assert(!items[0].isOnIPhone && items[0].isActiveOnDevice,
               "device-only content sorts first and is not claimed by the iPhone")
        assert(items[1].isOnIPhone && !items[1].isActiveOnDevice,
               "the local regenerated map remains uploadable")

        items = manager.savedMapListItems(activeDeviceMap: nil)
        assertEqual(items.count, 1, "disconnect removes live device-only inventory")
        assert(items[0].isOnIPhone && !items[0].isActiveOnDevice,
               "disconnect preserves the iPhone cache without stale device presence")

        let pendingSuite = "saved-map-pending-\(UUID().uuidString)"
        let pendingDefaults = UserDefaults(suiteName: pendingSuite)!
        defer { pendingDefaults.removePersistentDomain(forName: pendingSuite) }
        pendingDefaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        pendingDefaults.set(exactSession, forKey: "offlineMap.lastTransfer.sessionId")
        pendingDefaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        let pendingManager = OfflineMapManager(defaults: pendingDefaults, cacheDirectory: cacheDirectory)
        let pendingItems = pendingManager.savedMapListItems(activeDeviceMap: exactDevice)
        assert(!pendingItems.contains { $0.isActiveOnDevice },
               "a live unconfirmed transfer cannot get a Saved Maps installed badge from its pointer")
        assert(!pendingManager.isCachedPackInstalled(packURL, activeMapId: "map-1", activeSessionId: exactSession),
               "cached identity cannot complete an unconfirmed live transfer")

        manager.deleteCachedPack(at: packURL)
        items = manager.savedMapListItems(activeDeviceMap: exactDevice)
        assertEqual(items.count, 1,
                    "deleting the iPhone copy keeps the active device map visible")
        assert(!items[0].isOnIPhone && items[0].isActiveOnDevice,
               "local deletion converts a merged row into device-only inventory")
        assert(manager.savedMapListItems(activeDeviceMap: nil).isEmpty,
               "no local or connected-device map produces an empty inventory")

        let streamCacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "saved-stream-inventory-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: streamCacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: streamCacheDirectory) }
        let streamURL = streamCacheDirectory.appendingPathComponent("stream-map.bmap")
        try? Data([1, 2, 3, 4]).write(to: streamURL)
        let signedReceipt = String(repeating: "d", count: 64)
        let streamArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: streamURL.lastPathComponent,
            objectKey: "maps/stream-map.bmap",
            bytes: 4,
            sha256: String(repeating: "a", count: 64),
            manifestReceipt: String(repeating: "b", count: 64),
            signedManifestReceipt: signedReceipt
        )
        let streamMetadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: "stream-map",
            displayName: "Stream Map",
            localArtifactFilename: streamURL.lastPathComponent,
            streamFormatVersion: 1,
            rendererFormatVersion: 2,
            jobID: nil,
            serverURLString: nil,
            clientInstallationID: nil,
            primaryArtifact: streamArtifact,
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
        )
        try? SavedMapArtifactMetadataStore.save(streamMetadata, for: streamURL)
        let streamManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: streamCacheDirectory
        )
        let legacySession = "stream-map-legacy-session"
        let legacyDevice = DeviceActiveMapDescriptor(
            mapID: "stream-map",
            sessionID: legacySession
        )!
        assertEqual(
            streamManager.savedMapListItems(activeDeviceMap: legacyDevice).count,
            2,
            "a stream pack does not claim an unknown legacy fallback session"
        )
        streamManager.updateSavedMapTransferMetadata(
            mapID: "stream-map",
            protocolVersion: 1,
            streamFormatVersion: nil,
            sessionID: legacySession,
            outcome: "installed"
        )
        let refreshedItems = streamManager.savedMapListItems(
            activeDeviceMap: legacyDevice
        )
        assertEqual(refreshedItems.count, 1,
                    "recorded legacy transfer identity refreshes the live inventory")
        assert(refreshedItems[0].isOnIPhone && refreshedItems[0].isActiveOnDevice,
               "protocol-v1 fallback installation merges without an app relaunch")
    }

    static func testOfflineMapManifestDecoding() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-manifest-test-\(UUID().uuidString).zip")
        let manifest = Data("""
        {
          "schemaVersion": 1,
          "displayName": "custom-map",
          "source": {
            "region": "geofabrik-asia-malaysia-singapore-brunei",
            "url": "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf"
          }
        }
        """.utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8))
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url),
              let decoded = try? archive.manifest() else {
            assert(false, "stored zip manifest should decode")
            return
        }

        assertEqual(decoded.displayName, "custom-map", "manifest exposes display name")
        assertEqual(decoded.source?.region, "geofabrik-asia-malaysia-singapore-brunei", "manifest exposes source region")
        assertEqual(decoded.source?.url, "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf", "manifest exposes source URL")
    }

    static func testMapTransferUploadURLEncodesPlusPathComponents() {
        let baseURL = URL(string: "http://192.168.4.20:8080")!
        let url = MapTransferDeviceClient.uploadURL(
            baseURL: baseURL,
            sessionId: "session-1",
            relativePath: "VECTMAP/map-1/+0032+0008/123_456.fmb"
        )

        assertEqual(
            url.absoluteString,
            "http://192.168.4.20:8080/map-transfer/sessions/session-1/VECTMAP/map-1/%2B0032%2B0008/123_456.fmb",
            "upload URL percent-encodes plus signs so firmware does not decode them as spaces"
        )
        let archiveRequest = MapTransferDeviceClient.archiveUploadRequest(
            baseURL: baseURL,
            sessionId: "session-1",
            sessionToken: "transfer-secret"
        )
        assertEqual(
            archiveRequest.url?.absoluteString,
            "http://192.168.4.20:8080/map-transfer/sessions/session-1/pack.zip",
            "background map transfer uploads one archive to the session endpoint"
        )
        assertEqual(archiveRequest.httpMethod, "PUT", "archive transfer uses PUT")
        assertEqual(
            archiveRequest.value(forHTTPHeaderField: "X-BikeComputer-Transfer-Token"),
            "transfer-secret",
            "archive transfer carries the BLE-issued session token"
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(400, "unknown path")
            ),
            "older firmware falls back to foreground per-file transfer"
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(413, "archive too large")
            ),
            "oversized archives fall back to the supported per-file protocol"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(500, "write failed")
            ),
            "device failures are not disguised as compatibility fallback"
        )
        let outOfSpace = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: outOfSpace,
                allowLocalStorageFailure: true
            ),
            "compatibility staging falls back when local storage is exhausted"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: outOfSpace
            ),
            "ordinary archive failures do not broaden the compatibility fallback"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: CancellationError(),
                allowLocalStorageFailure: true
            ),
            "cancellation never becomes an implicit foreground transfer"
        )
    }

    static func testMapTransferOutcomePolicy() {
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: CancellationError(),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "cancelling after activation starts remains reconcilable"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: CancellationError(),
                activationMayBeInFlight: false
            ),
            "failed",
            "cancelling before activation does not claim a device-side attempt"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: URLError(.networkConnectionLost),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "an interrupted stream remains resumable and reconcilable"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: OfflineMapPlatformError.serverStatus(408, "stream_paused"),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "device checkpoint timeout remains resumable"
        )
    }

    static func testCachedPackRecoveryDecision() {
        for state in ["activating", "ready", "finalizing"] {
            assertEqual(CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new", activeSessionId: "session-new",
                activationStatus: state, activationSessionId: "session-new"
            ), .pending, "a provisional pointer never completes cached recovery")
            assertEqual(ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: "session-new", activeSessionID: "session-new",
                activationStatus: state, activationSessionID: "session-new"
            ), .awaitDevice, "a provisional pointer never completes stream recovery")
        }
        assertEqual(CachedPackRecoveryDecision.evaluate(
            expectedSessionId: "session-new", activeSessionId: "session-new",
            activationStatus: "installed", activationSessionId: "session-new",
            bindsOriginalObservation: true
        ), .installed, "matching terminal state confirms cached recovery")
        assertEqual(CachedPackRecoveryDecision.evaluate(
            expectedSessionId: "session-new", activeSessionId: "session-new",
            activationStatus: "installed", activationSessionId: "session-new"
        ), .absent, "an unbound terminal result requires a verifying re-send")
        assertEqual(ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: "session-new", activeSessionID: "session-new",
            activationStatus: "installed", activationSessionID: "session-new"
        ), .upload, "a verifying re-send cannot be skipped by an old terminal status")
        assertEqual(ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: "session-new", activeSessionID: "session-new",
            activationStatus: "installed", activationSessionID: "session-new",
            bindsOriginalObservation: true
        ), .installed, "the original observing connection may retain its installed result")
        for activationSessionId in ["session-new", ""] {
            assertEqual(
                CachedPackRecoveryDecision.evaluate(
                    expectedSessionId: "session-new",
                    activeSessionId: "session-new",
                    activationStatus: "idle",
                    activationSessionId: activationSessionId
                ),
                .absent,
                "an exact pointer without a live activation is re-sent for a fresh result"
            )
            assertEqual(ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: "session-new", activeSessionID: "session-new",
                activationStatus: "idle", activationSessionID: activationSessionId
            ), .upload, "an exact pointer never completes installation or blocks a verifying re-send")
        }
        assertEqual(
            CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new",
                activeSessionId: "session-old",
                activationStatus: "activating",
                activationSessionId: "session-new"
            ),
            .pending,
            "matching device activation blocks a redundant archive upload"
        )
        assertEqual(
            CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new",
                activeSessionId: "session-old",
                activationStatus: "failed",
                activationSessionId: "session-new"
            ),
            .absent,
            "failed activation remains eligible for an explicit retry"
        )
    }

    @MainActor
    static func testMapTransferUploadResumeContract() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-upload-resume-\(UUID().uuidString).zip")
        let manifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\"}".utf8)
        let firstBlock = Data("first-block".utf8)
        let secondBlock = Data("second-block".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("preview.png", Data("preview-only-local".utf8)),
            ("VECTMAP/map-1/+0032+0008/001_001.fmb", firstBlock),
            ("VECTMAP/map-1/+0032+0008/002_002.fmb", secondBlock)
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "resume test archive should parse")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        var headPaths: [String] = []
        var manifestHeadAttempts = 0
        var putBodies: [String: Data] = [:]
        FirmwareRequestCaptureProtocol.handler = { request, body in
            let path = request.url!.path
            let method = request.httpMethod ?? ""
            let status: Int
            var headers: [String: String] = [:]
            if method == "HEAD" {
                headPaths.append(path)
                if path.hasSuffix("manifest.json") {
                    manifestHeadAttempts += 1
                    if manifestHeadAttempts == 1 {
                        throw URLError(.timedOut)
                    } else if manifestHeadAttempts == 2 {
                        status = 503
                    } else {
                        status = 200
                        headers["Content-Length"] = String(manifest.count)
                    }
                } else if path.hasSuffix("001_001.fmb") {
                    status = 200
                    headers["Content-Length"] = String(firstBlock.count)
                } else {
                    status = 404
                }
            } else if method == "PUT" {
                status = 200
                putBodies[path] = body
            } else {
                status = 405
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                Data()
            )
        }

        var progress: [(String, Bool)] = []
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session,
            recoveryRetryNanoseconds: 1_000_000
        )
        await runMainActorAsyncTest {
            try await client.upload(
                archive: archive,
                sessionId: "session-1"
            ) { _, _, path, didUpload in
                progress.append((path, didUpload))
            }
        }

        assertEqual(manifestHeadAttempts, 3,
                    "resume waits through timeout and busy recovery responses")
        assertEqual(headPaths.count, 5, "resume checks every declared upload entry")
        assert(
            !headPaths.contains(where: { $0.hasSuffix("preview.png") }),
            "foreground compatibility transfer never stages preview.png on older firmware"
        )
        assertEqual(progress.map { $0.1 }, [false, false, true],
                    "verified entries are skipped while a missing receipt is reuploaded")
        assertEqual(putBodies.count, 1, "resume uploads only the unverified file")
        let uploaded = putBodies.first
        assert(uploaded?.key.hasSuffix("002_002.fmb") == true,
               "resume retries the file whose HEAD check returned missing")
        assertEqual(uploaded?.value, secondBlock,
                    "resume PUT sends the exact archive entry bytes")

        var blindTimeoutAttempts = 0
        FirmwareRequestCaptureProtocol.handler = { _, _ in
            blindTimeoutAttempts += 1
            throw URLError(.timedOut)
        }
        await runMainActorAsyncTest {
            do {
                try await client.upload(
                    archive: archive,
                    sessionId: "session-1"
                ) { _, _, _, _ in }
                assert(false, "an ordinary Wi-Fi outage should not enter the long recovery wait")
            } catch let error as URLError {
                assertEqual(error.code, .timedOut,
                            "blind manifest timeout surfaces the transport error")
            }
        }
        assertEqual(blindTimeoutAttempts, 3,
                    "blind recovery retries are bounded without an explicit device signal")
    }

    @MainActor
    static func testMapTransferActivationAcknowledgementSequence() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 202, httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data("{\"ok\":true,\"sessionId\":\"session-1\",\"sequence\":9}".utf8)
            )
        }
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session
        )
        var acceptedSequence: UInt32?
        await runMainActorAsyncTest {
            acceptedSequence = try await client.activate(sessionId: "session-1")
        }
        assertEqual(acceptedSequence, 9,
                    "activation acknowledgement exposes the queued attempt sequence")
        let operation = DeviceMapOperationRecord(schemaVersion: 1, deviceID: String(repeating: "a", count: 32),
            operationID: UUID(), sessionID: "session-1", mapID: "map-1",
            manifestReceipt: String(repeating: "b", count: 64), signedManifestReceipt: String(repeating: "c", count: 64),
            streamSHA256: String(repeating: "d", count: 64), streamBytes: 123, artifactFilename: "map.bmap",
            appNamespace: "test", createdAt: Date(), connectionEpoch: 1, observation: "in_progress",
            cleanup: "pending", usesDurableProtocol: true, lastReceipt: nil,
            admissionEpoch: String(repeating: "e", count: 32), admissionRevision: 42)
        let responseReceipt = DeviceMapOperationReceipt(schemaVersion: 1, deviceID: operation.deviceID,
            operationID: operation.wireOperationID, sessionID: operation.sessionID, mapID: operation.mapID,
            manifestReceipt: operation.manifestReceipt, signedManifestReceipt: operation.signedManifestReceipt,
            streamSHA256: operation.streamSHA256, streamBytes: operation.streamBytes, phase: "accepted", revision: 3, status: nil)
        var controls: [String] = []
        FirmwareRequestCaptureProtocol.handler = { request, body in
            let action = request.url!.lastPathComponent
            controls.append(action)
            assertEqual(request.httpMethod, "POST", "operation controls are explicit POSTs")
            assertEqual(request.value(forHTTPHeaderField: "X-Map-Operation-ID"), operation.wireOperationID,
                        "commit/cancel retain original operation ID")
            assertEqual(request.value(forHTTPHeaderField: "X-Map-Stream-SHA256"), operation.streamSHA256,
                        "commit/cancel bind exact body digest")
            assert(body.isEmpty, "operation controls use an empty body")
            if action == "cancel" {
                assertEqual(request.value(forHTTPHeaderField: "X-Map-Content-Session"), operation.sessionID,
                            "cancel can fence a pre-manifest upload with full saved identity")
                assertEqual(request.value(forHTTPHeaderField: "X-Map-Operation-Admission-Epoch"), operation.admissionEpoch,
                            "cancel never refreshes admission after reboot")
                assertEqual(request.value(forHTTPHeaderField: "X-Map-Operation-Admission-Revision"), "42", "cancel retains original revision")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: action == "cancel" ? 409 : 200,
                                    httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(responseReceipt))
        }
        var committed: DeviceMapOperationReceipt?
        var lateCancellation: DeviceMapOperationReceipt?
        await runMainActorAsyncTest {
            committed = try await client.commitOperation(operationID: operation.wireOperationID, streamSHA256: operation.streamSHA256)
            lateCancellation = try await client.cancelOperation(record: operation)
        }
        assertEqual(controls, ["commit", "cancel"], "prepare upload is separate from explicit controls")
        assertEqual(committed?.phase, "accepted", "commit returns accepted, never installed by HTTP alone")
        assertEqual(lateCancellation?.phase, "accepted", "409 cancellation retains the accepted winner")
    }

    static func testMapTransferSessionIdentityUsesManifestContent() {
        let first = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-one".utf8)
        )
        let firstRetry = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-one".utf8)
        )
        let regenerated = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-two".utf8)
        )

        assertEqual(first, firstRetry, "the same pack resumes the same staged session")
        assert(first != regenerated, "regenerated same-ID packs use distinct staged sessions")
        assert(first.count <= 80, "content-derived session id fits the firmware contract")
    }

    static func testMapActivationReconciliationMatrix() {
        let settingsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BikeComputer/BikeComputer/Views/SettingsView.swift")
        let settingsSource = try! String(contentsOf: settingsURL, encoding: .utf8)
        assert(settingsSource.contains("manager.cancelCurrentMapOperation(bleManager: bleManager)") &&
               settingsSource.contains("manager.canCancelCurrentMapOperation") &&
               settingsSource.contains("manager.isCurrentMapOperationAccepted"),
               "UI distinguishes requested pregrant cancellation from an accepted operation")
        let operationID = String(repeating: "a", count: 32)
        assertEqual(MapOperationQueryPacket.make(operationID: operationID), Data("MOPQ|\(operationID)".utf8),
                    "operation status query preserves its exact bounded identity")
        for invalidID in ["", String(repeating: "a", count: 31), String(repeating: "a", count: 33),
                          String(repeating: "A", count: 32), String(repeating: "a", count: 31) + "|"] {
            assert(MapOperationQueryPacket.make(operationID: invalidID) == nil,
                   "malformed operation IDs cannot enter the BLE query channel")
        }
        func evaluate(previousMapId: String? = "map-1",
                      previousSessionId: String? = "session-1",
                      previousSequence: UInt32? = 7,
                      acceptedSequence: UInt32? = nil,
                      observedCurrentAttempt: Bool = false,
                      activeMapId: String? = "map-1",
                      activeSessionId: String? = nil,
                      activationStatus: String? = "installed",
                      activationSequence: UInt32? = 7,
                      activationSessionId: String? = "session-1",
                      activationMapId: String? = "map-1",
                      activationError: String? = nil) -> MapActivationEvaluation {
            MapActivationReconciler.evaluate(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: previousMapId,
                previousSessionId: previousSessionId,
                previousSequence: previousSequence,
                acceptedSequence: acceptedSequence,
                observedCurrentAttempt: observedCurrentAttempt,
                activeMapId: activeMapId,
                activeSessionId: activeSessionId,
                activationStatus: activationStatus,
                activationSequence: activationSequence,
                activationSessionId: activationSessionId,
                activationMapId: activationMapId,
                activationError: activationError
            )
        }

        for (previousMap, previousSession) in [(nil, nil), ("old-map", "old-session"), ("map-1", "old-session"), ("map-1", "session-1")] as [(String?, String?)] {
            let activating = evaluate(
                previousMapId: previousMap,
                previousSessionId: previousSession,
                activeSessionId: "session-1",
                activationStatus: "activating",
                activationSequence: 8
            )
            assertEqual(activating.decision, .pending("activating"),
                        "first, replacement and same-ID candidates wait for renderer acknowledgement")
            assertEqual(evaluate(
                previousMapId: previousMap,
                previousSessionId: previousSession,
                observedCurrentAttempt: activating.observedCurrentAttempt,
                activeMapId: previousMap,
                activeSessionId: previousSession,
                activationStatus: "failed",
                activationSequence: 8,
                activationError: "renderer rejected candidate"
            ).decision, .failed("renderer rejected candidate"),
                        "renderer rejection remains a failure after previous pointer restoration")
        }
        assertEqual(evaluate(observedCurrentAttempt: true, activationSequence: 7).decision,
                    .pending("installed"), "an observed attempt cannot promote a duplicate baseline receipt")
        assertEqual(evaluate(activationSequence: 6).decision, .pending("installed"),
                    "out-of-order terminal status is not a new attempt")
        assertEqual(evaluate(previousSequence: UInt32.max, activationSequence: 0).decision,
                    .installed, "activation sequence wrap is a forward transition")
        assertEqual(evaluate(acceptedSequence: 9, activationSequence: 8).decision,
                    .pending("installed"), "another acknowledged attempt cannot complete this operation")
        assertEqual(evaluate(activationSequence: 8, activationSessionId: "foreign-session").decision,
                    .pending("active map is map-1; waiting for current activation"),
                    "another content session cannot complete this operation")
        assertEqual(
            evaluate().decision,
            .pending("installed"),
            "same-ID reinstall rejects a retained installed activation"
        )
        assertEqual(
            evaluate(activationSequence: 8).decision,
            .installed,
            "a newer activation sequence proves same-ID installation"
        )
        assertEqual(
            evaluate(
                previousSequence: nil,
                acceptedSequence: 8,
                activationSequence: 8
            ).decision,
            .installed,
            "the acknowledged activation sequence proves a fast same-session completion"
        )
        assertEqual(
            evaluate(
                previousSessionId: "old-session",
                previousSequence: nil,
                activeSessionId: "session-1"
            ).decision,
            .pending("installed"),
            "an exact active-session transition needs terminal attempt evidence"
        )
        assertEqual(
            evaluate(
                previousMapId: nil,
                previousSessionId: nil,
                previousSequence: nil,
                activeSessionId: "session-1"
            ).decision,
            .pending("installed"),
            "an exact first-install pointer needs terminal attempt evidence"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .pending("active map is map-1; waiting for current activation"),
            "an exact pointer after restart without terminal state remains unconfirmed"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "activating"
            ).decision,
            .pending("activating"),
            "an old exact-session root does not complete an in-progress same-session repair"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "failed"
            ).decision,
            .pending("failed"),
            "an unobserved matching failure is not hidden by an old exact-session root"
        )
        assertEqual(
            evaluate(activeSessionId: "session-1").decision,
            .pending("installed"),
            "a cached terminal state cannot complete a same-session retry"
        )
        assertEqual(
            evaluate(
                previousMapId: "old-map",
                activeMapId: "map-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .pending("active map is map-1; waiting for current activation"),
            "a changed legacy map pointer without terminal state remains unconfirmed"
        )
        assertEqual(
            evaluate(
                activationStatus: "failed",
                activationSequence: 8,
                activationError: "file_sha256"
            ).decision,
            .failed("file_sha256"),
            "matching failed activation surfaces the device error"
        )
        assertEqual(
            evaluate(
                activationSequence: 8,
                activationMapId: "wrong-map"
            ).decision,
            .failed("device activated wrong-map instead of map-1"),
            "matching session rejects a different activated map"
        )
        let inProgress = evaluate(
            activeMapId: nil,
            activationStatus: "activating",
            activationSequence: nil
        )
        assert(inProgress.observedCurrentAttempt, "observing activating proves a response-lost request reached legacy firmware")
        assertEqual(
            evaluate(
                observedCurrentAttempt: inProgress.observedCurrentAttempt,
                activationSequence: nil
            ).decision,
            .installed,
            "legacy firmware installs after an observed activating transition"
        )
        assertEqual(
            evaluate(
                previousMapId: nil,
                activeMapId: "map-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .pending("active map is map-1; waiting for current activation"),
            "an unknown baseline is not proof that a same-ID activation ran"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.timedOut)),
            "activation request timeout enters reconciliation"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.networkConnectionLost)),
            "lost activation response enters reconciliation"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.cannotConnectToHost)),
            "automatic activation may close device HTTP before the redundant POST connects"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.notConnectedToInternet)),
            "accessory AP shutdown proceeds to BLE activation reconciliation"
        )
    }

    @MainActor
    static func testMapActivationConfirmationOrchestration() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        let defaults = UserDefaults(suiteName: "map-confirmation-\(UUID().uuidString)")!
        let manager = OfflineMapManager(defaults: defaults)
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.setConnectedDeviceIDForTesting("map-test-device")
        bleManager.deviceTransferSessionToken = "map-test-token"
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session
        )

        let clock = TestClock()
        var pollWaits: [UInt64] = []
        let advancePollClock: (UInt64) async throws -> Void = { nanoseconds in
            pollWaits.append(nanoseconds)
            clock.advance(by: TimeInterval(nanoseconds) / 1_000_000_000)
        }
        var statusRequests = 0
        FirmwareRequestCaptureProtocol.handler = { _, _ in
            statusRequests += 1
            throw URLError(.timedOut)
        }
        let terminalStatus = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data("""
        {"activeMapId":"map-1","activeSessionId":"session-1","activation":{"status":"installed","sequence":8,"sessionId":"session-1","mapId":"map-1"}}
        """.utf8))
        bleManager.applyAuthenticatedMapTransferStatus(terminalStatus)
        var confirmation: MapActivationConfirmationResult?
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "old-session",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.2,
                pollIntervalNanoseconds: 1_000_000,
                now: clock.now,
                sleep: advancePollClock
            )
        }
        assertEqual(confirmation, .installed, "BLE fallback confirms installation")
        assertEqual(statusRequests, 1, "HTTP status failure falls back to BLE")
        assertEqual(pollWaits.count, 0, "BLE installation confirms without waiting")

        statusRequests = 0
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            statusRequests += 1
            let state = statusRequests == 1 ? "activating" : "installed"
            let activeSession = statusRequests == 1 ? "old-session" : "session-1"
            let body = Data("""
            {"activeMapId":"map-1","activeSessionId":"\(activeSession)","activeManifestReceipt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","activeMapDisplayName":"Singapore new","activeMapBoundsE7":[1038375134,12767316,1038683621,13075725],"activation":{"status":"\(state)","sequence":8,"sessionId":"session-1","mapId":"map-1","step":3,"steps":3,"progress":100}}
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        confirmation = nil
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "old-session",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.2,
                pollIntervalNanoseconds: 1_000_000,
                now: clock.now,
                sleep: advancePollClock
            )
        }
        assertEqual(confirmation, .installed, "HTTP polling confirms installation")
        assertEqual(statusRequests, 2,
                    "confirmation polls from activating through installed")
        assertEqual(bleManager.activeDeviceMap?.mapID, "map-1",
                    "authenticated HTTP status refreshes the active map row")
        assertEqual(bleManager.activeDeviceMap?.sessionID, "session-1",
                    "the active row keeps the exact installed stream session")
        assertEqual(bleManager.activeDeviceMap?.manifestReceipt,
                    String(repeating: "a", count: 64),
                    "the active row keeps the authenticated manifest receipt")
        assertEqual(bleManager.activeDeviceMap?.displayName, "Singapore new",
                    "the active row uses the device-confirmed map name")
        assertEqual(bleManager.mapTransferActivationStep, 3,
                    "HTTP reconciliation projects terminal activation progress")
        assertEqual(bleManager.mapTransferActivationProgress, 100,
                    "HTTP reconciliation projects terminal activation completion")

        statusRequests = 0
        pollWaits.removeAll()
        let pendingStartedAt = clock.now()
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            statusRequests += 1
            let body = Data("""
            {"activeMapId":"map-1","activation":{"status":"installed","sequence":7,"sessionId":"session-1","mapId":"map-1"}}
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        confirmation = nil
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "session-1",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.02,
                pollIntervalNanoseconds: 1_000_000,
                now: clock.now,
                sleep: advancePollClock
            )
        }
        guard let confirmation,
              case .continuesOnDevice = confirmation else {
            assert(false, "retained activation should continue on device without an error")
            return
        }
        assertEqual(manager.statusMessage.hasPrefix("activating map-1"), true,
                    "pending confirmation retains activation status")
        assert(statusRequests > 1, "confirmation limit covers repeated pending polls")
        assertEqual(statusRequests, pollWaits.count,
                    "every pending poll uses the confirmation wait")
        assert(pollWaits.allSatisfy { $0 == 1_000_000 },
               "pending confirmation preserves the requested poll interval")
        let elapsed = clock.now().timeIntervalSince(pendingStartedAt)
        assert(elapsed >= 0.02 && elapsed < 0.022,
               "pending confirmation stops at its deadline within one poll interval")
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { bleManager.deviceTransferSessionToken = "rotated-token" }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { bleManager.deviceTransferSessionToken = "rotated-token" }
                }
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{\"activeMapId\":\"stale-map\",\"activation\":{\"status\":\"installed\",\"sequence\":8,\"sessionId\":\"session-1\",\"mapId\":\"map-1\"}}".utf8))
        }
        var staleConfirmation: MapActivationConfirmationResult?
        await runMainActorAsyncTest {
            staleConfirmation = try await manager.confirmActivatedMap(expectedMapId: "map-1", sessionId: "session-1",
                previousMapId: "old", previousSessionId: "old", previousSequence: 7, acceptedSequence: 8,
                client: client, bleManager: bleManager, timeout: 0.02, pollIntervalNanoseconds: 1_000_000)
        }
        if case .continuesOnDevice? = staleConfirmation {} else {
            assert(false, "a rotated token during HTTP status await cannot complete activation")
        }
        assert(bleManager.mapTransferActiveMapId != "stale-map", "late old-token HTTP status cannot overwrite BLE state")
    }

    static func testMapTransferDeviceStatusDecodesActivationFailure() {
        let body = Data("""
        {
          "enabled": true,
          "activeMapId": "old-map",
          "activeSessionId": "old-map-session",
          "activeManifestReceipt": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "activeMapDisplayName": "Old Map",
          "activeMapBoundsE7": [1037500000, 12400000, 1039300000, 13700000],
          "activation": {
            "status": "failed",
            "sequence": 9,
            "sessionId": "new-map",
            "mapId": "new-map",
            "error": {
              "code": "file_sha256",
              "message": "sha mismatch for VECTMAP/new-map/1.fmb"
            }
          }
        }
        """.utf8)

        guard let status = try? JSONDecoder().decode(MapTransferDeviceStatus.self, from: body) else {
            assert(false, "device transfer status should decode activation failure")
            return
        }

        assertEqual(status.enabled, true, "status exposes transfer mode")
        assertEqual(status.activeMapId, "old-map", "status exposes active map id")
        assertEqual(status.activation?.status, "failed", "status exposes activation state")
        assertEqual(status.activation?.sequence, 9, "status exposes activation sequence")
        assertEqual(status.activation?.error?.code, "file_sha256", "status exposes activation error code")
        assertEqual(status.activation?.error?.message, "sha mismatch for VECTMAP/new-map/1.fmb", "status exposes activation error message")
        assertEqual(status.activeSessionId, "old-map-session", "status exposes durable active session identity")
        assertEqual(status.activeManifestReceipt, String(repeating: "a", count: 64),
                    "HTTP status exposes the active manifest receipt")
        assertEqual(status.activeMapDisplayName, "Old Map",
                    "HTTP status exposes the active display name")
        assertEqual(status.activeMapBoundsE7,
                    [1_037_500_000, 12_400_000, 1_039_300_000, 13_700_000],
                    "HTTP status exposes normalized preview bounds")

        let bleManager = BLEManager()
        bleManager.applyAuthenticatedMapTransferStatus(status)
        assertEqual(bleManager.activeDeviceMap?.mapID, "old-map",
                    "authenticated HTTP status updates the active-device model")
        assertEqual(bleManager.activeDeviceMap?.sessionID, "old-map-session",
                    "authenticated HTTP status preserves the active session")
        assertEqual(bleManager.mapTransferActivationStatus, "failed",
                    "authenticated HTTP status projects activation state")
        assertEqual(
            bleManager.mapTransferActivationError,
            "file_sha256: sha mismatch for VECTMAP/new-map/1.fmb",
            "authenticated HTTP status projects the device activation error"
        )
        bleManager.isConnected = true
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.deviceTransferSessionToken = "token-a"
        let context = bleManager.captureMapTransferHTTPStatusContext()!
        assert(bleManager.applyAuthenticatedMapTransferStatus(status, context: context), "matching HTTP context applies")
        bleManager.deviceTransferSessionToken = "token-b"
        assert(!bleManager.applyAuthenticatedMapTransferStatus(status, context: context), "token rotation fences late response")
        bleManager.deviceTransferSessionToken = "token-a"
        let wrongGeneration = MapTransferHTTPStatusContext(deviceID: context.deviceID,
            selectedDeviceID: context.selectedDeviceID, connectionEpoch: context.connectionEpoch,
            transferGeneration: context.transferGeneration &+ 1, authorizationDigest: context.authorizationDigest)
        assert(!bleManager.applyAuthenticatedMapTransferStatus(status, context: wrongGeneration), "authorization generation is independent of BLE epoch")
        let wrongEpoch = MapTransferHTTPStatusContext(deviceID: context.deviceID,
            selectedDeviceID: context.selectedDeviceID, connectionEpoch: context.connectionEpoch &+ 1,
            transferGeneration: context.transferGeneration, authorizationDigest: context.authorizationDigest)
        assert(!bleManager.applyAuthenticatedMapTransferStatus(status, context: wrongEpoch), "same-device reconnect fences late response")
        bleManager.setConnectedDeviceIDForTesting("device-b")
        assert(!bleManager.applyAuthenticatedMapTransferStatus(status, context: context), "another device cannot receive old HTTP state")
        bleManager.isConnected = false
        assert(bleManager.captureMapTransferHTTPStatusContext() == nil, "disconnected state cannot authorize HTTP projection")
        let operationID = String(repeating: "a", count: 32)
        let operationBody = Data("""
        {"operation":{"schemaVersion":1,"deviceID":"device-a","operationID":"\(operationID)","status":"result_unavailable"}}
        """.utf8)
        let priorObservation = bleManager.mapOperationObservationGeneration
        assert(bleManager.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + operationBody
        ), "operation query response uses authenticated map-status assembly")
        assertEqual(bleManager.mapOperationStatus?.operationID, operationID,
                    "BLE operation response retains exact operation identity")
        assertEqual(bleManager.mapOperationStatus?.status, "result_unavailable",
                    "missing receipt is explicit and never maps to installed")
        assert(bleManager.mapOperationObservationGeneration > priorObservation,
               "a completed BLE response advances freshness independently of durable revision")
        assertEqual(bleManager.mapOperationConnectionEpoch, bleManager.transferConnectionEpoch,
                    "operation observation carries the current connection epoch")
        for state in ["activating", "failed", "installed"] {
            let data = Data("""
            {"activeMapId":"new-map","activeSessionId":"new-session","activation":{"status":"\(state)","sequence":10,"sessionId":"new-session","mapId":"new-map"}}
            """.utf8)
            let candidate = try! JSONDecoder().decode(MapTransferDeviceStatus.self, from: data)
            bleManager.applyAuthenticatedMapTransferStatus(candidate)
            assertEqual(bleManager.activeDeviceMap != nil, state == "installed",
                        "HTTP Saved Maps projection requires renderer acceptance of a candidate")
            let packet = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + data
            assert(bleManager.handleMapTransferStatusNotification(packet), "candidate BLE status is consumed")
            assertEqual(bleManager.activeDeviceMap != nil, state == "installed",
                        "BLE Saved Maps projection requires renderer acceptance of a candidate")
        }
    }

    static func testFirmwareManifestDecodingAndHash() {
        let body = Data("""
        {
          "schemaVersion": 1,
          "target": "WAVESHARE_AMOLED_175",
          "version": "0.4.0",
          "build": 87,
          "gitSha": "abcdef123456",
          "size": 3,
          "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "url": "https://github.com/seichris/open-bike-computer/releases/download/v0.4.0/WAVESHARE_AMOLED_175.bin",
          "minUpdaterProtocol": 1,
          "signature": "MEUCIQCoFhwd6SnmvltHkUu5jfNQce/pPk87c84AcHt2u9DmDQIgfwklONo1MEyfgfX0VhlTDyi/B+dGZdsvckb/rFEGOM8="
        }
        """.utf8)

        guard let manifest = try? JSONDecoder().decode(FirmwareReleaseManifest.self, from: body) else {
            assert(false, "firmware manifest should decode")
            return
        }

        assertEqual(manifest.target, "WAVESHARE_AMOLED_175", "manifest exposes target")
        assertEqual(manifest.build, 87, "manifest exposes build")
        assert(manifest.isSupportedByApp, "manifest updater protocol is supported")
        assertEqual(FirmwareUpdateManager.sha256Hex(Data("abc".utf8)), manifest.sha256, "firmware hash verification uses SHA-256 hex")
        assert(
            FirmwareManifestSignatureVerifier.verify(
                manifest,
                publicKeyBase64: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
            ),
            "firmware manifest signature verifies over canonical release metadata"
        )

        var attested = manifest
        attested.mapMetadataReaderVersion = 1
        let readerKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        attested.mapMetadataReaderSignature = try! readerKey.signature(for: Data(
            FirmwareManifestSignatureVerifier.canonicalPayload(for: attested, readerAttestation: true).utf8))
            .derRepresentation.base64EncodedString()
        let readerPublicKey = readerKey.publicKey.x963Representation.base64EncodedString()
        assert(FirmwareManifestSignatureVerifier.verify(attested, publicKeyBase64: readerPublicKey),
               "additive reader attestation verifies without changing schema1 image signature")
        attested.mapMetadataReaderVersion = 0
        assert(!FirmwareManifestSignatureVerifier.verify(attested, publicKeyBase64: readerPublicKey),
               "reader capability cannot be altered independently of signed exact image")
        attested.mapMetadataReaderVersion = 1
        attested.mapMetadataReaderSignature = nil
        assert(!FirmwareManifestSignatureVerifier.verify(attested, publicKeyBase64: readerPublicKey),
               "unsigned reader declaration cannot bypass downgrade floor")

        let tampered = FirmwareReleaseManifest(
            schemaVersion: manifest.schemaVersion,
            target: manifest.target,
            version: manifest.version,
            build: manifest.build + 1,
            gitSha: manifest.gitSha,
            size: manifest.size,
            sha256: manifest.sha256,
            url: manifest.url,
            minUpdaterProtocol: manifest.minUpdaterProtocol,
            signature: manifest.signature
        )
        assert(
            !FirmwareManifestSignatureVerifier.verify(
                tampered,
                publicKeyBase64: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
            ),
            "firmware manifest signature rejects tampered metadata"
        )
    }

    @MainActor
    static func testFirmwareUpdateManagerRestoresPendingStatus() {
        let suiteName = "FirmwareUpdateManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assert(false, "test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pending = PendingFirmwareUpdate(
            target: "WAVESHARE_AMOLED_175",
            version: "0.4.0",
            build: 87,
            gitSha: "abcdef123456",
            startedAt: Date(timeIntervalSince1970: 10),
            status: "device rebooting"
        )
        let data = try? JSONEncoder().encode(pending)
        defaults.set(data, forKey: "firmware.pendingUpdate")

        let manager = FirmwareUpdateManager(defaults: defaults)
        assertEqual(manager.statusMessage,
                    "device rebooting",
                    "firmware manager restores pending reboot status after app relaunch")
    }

    @MainActor
    static func testFirmwareStorageMigrationFlow() {
        let suiteName = "FirmwareStorageMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assert(false, "test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deviceA = "device-a"
        let deviceB = "device-b"
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting(deviceA)
        let manager = FirmwareUpdateManager(defaults: defaults)
        manager.selectStorageMigrationDevice(deviceA)

        func applyStorageStatus(
            backend: String?,
            powerCycleRequired: Bool?
        ) {
            var object: [String: Any] = [
                "configured": true,
                "enabled": false,
                "firmware": [
                    "status": "idle",
                    "target": "WAVESHARE_AMOLED_175",
                    "version": "0.4.0",
                    "build": 87,
                    "gitSha": "abcdef123456",
                    "receivedBytes": 0,
                    "totalBytes": 0
                ]
            ]
            if let backend, let powerCycleRequired {
                object["storage"] = [
                    "backend": backend,
                    "powerCycleRequired": powerCycleRequired
                ]
            }
            let body = try! JSONSerialization.data(withJSONObject: object)
            let packet = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8)
                + body
            assert(
                bleManager.handleDeviceTransferStatusNotification(packet),
                "storage migration DSTS should be consumed"
            )
            manager.reconcileStorageMigrationStatus(bleManager: bleManager)
        }

        applyStorageStatus(
            backend: "legacy_spi_migration",
            powerCycleRequired: true
        )
        assertEqual(manager.storageMigrationNotice?.deviceID,
                    deviceA,
                    "legacy compatibility mode creates a device-scoped notice")
        assert(manager.isStorageMigrationAlertPresented,
               "legacy compatibility mode presents the user-facing action")
        assertEqual(manager.statusMessage,
                    FirmwareStorageMigrationNotice.statusMessage,
                    "firmware status remains actionable while migration is pending")

        bleManager.setConnectedDeviceIDForTesting(deviceB)
        manager.selectStorageMigrationDevice(deviceB)
        assert(manager.storageMigrationNotice == nil,
               "another device does not inherit the migration notice")
        assert(!manager.isStorageMigrationAlertPresented,
               "another device does not inherit the migration alert")
        assert(manager.statusMessage != FirmwareStorageMigrationNotice.statusMessage,
               "another device does not inherit the migration status text")

        bleManager.setConnectedDeviceIDForTesting(deviceA)
        manager.selectStorageMigrationDevice(deviceA)
        manager.dismissStorageMigrationAlert()
        let restored = FirmwareUpdateManager(defaults: defaults)
        restored.selectStorageMigrationDevice(deviceA)
        assertEqual(restored.storageMigrationNotice?.deviceID,
                    deviceA,
                    "migration guidance survives app relaunch")
        assert(restored.isStorageMigrationAlertPresented,
               "migration guidance is presented again after app relaunch")

        // Firmware predating the optional storage object and an FFat fallback
        // are not proof of native SDMMC, so neither may clear the notice.
        applyStorageStatus(backend: nil, powerCycleRequired: nil)
        assertEqual(manager.storageMigrationNotice?.deviceID,
                    deviceA,
                    "legacy DSTS without storage fields preserves the notice")
        applyStorageStatus(backend: "ffat", powerCycleRequired: false)
        assertEqual(manager.storageMigrationNotice?.deviceID,
                    deviceA,
                    "internal fallback does not falsely complete migration")

        bleManager.setConnectedDeviceIDForTesting(deviceB)
        manager.selectStorageMigrationDevice(deviceB)
        applyStorageStatus(backend: "sdmmc", powerCycleRequired: false)
        manager.selectStorageMigrationDevice(deviceA)
        assertEqual(manager.storageMigrationNotice?.deviceID,
                    deviceA,
                    "native status from another device cannot clear this device")

        bleManager.setConnectedDeviceIDForTesting(deviceA)
        applyStorageStatus(backend: "sdmmc", powerCycleRequired: false)
        assert(manager.storageMigrationNotice == nil,
               "only native SDMMC on the same device clears the notice")
        assertEqual(manager.statusMessage,
                    FirmwareStorageMigrationNotice.completionStatus,
                    "native confirmation reports migration completion")

        let settingsURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        let settingsSource = try? String(
            contentsOf: settingsURL,
            encoding: .utf8
        )
        assert(
            settingsSource?.contains(
                "FirmwareStorageMigrationNotice.title"
            ) == true &&
                settingsSource?.contains(
                    "Section(header: Text(\"SD Card Upgrade\"))"
                ) == true &&
                settingsSource?.contains("Check Device Again") == true,
            "Settings presents both the one-time alert and persistent recovery section"
        )
    }

    @MainActor
    static func testFirmwareUpdateAvailabilitySemantics() {
        let suiteName = "FirmwareUpdateAvailabilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assert(false, "test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = FirmwareUpdateManager(defaults: defaults)
        let bleManager = BLEManager()
        bleManager.firmwareTarget = "WAVESHARE_AMOLED_206"
        bleManager.firmwareVersion = "0.2.4"
        bleManager.firmwareBuild = 88
        bleManager.firmwareGitSha = "abcdef123456abcdef123456abcdef123456abcd"

        let current = FirmwareReleaseManifest(
            schemaVersion: 1,
            target: "WAVESHARE_AMOLED_206",
            version: "0.2.4",
            build: 88,
            gitSha: "abcdef123456abcdef123456abcdef123456abcd",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            url: URL(string: "https://github.com/seichris/open-bike-computer/releases/download/v0.2.4/WAVESHARE_AMOLED_206.bin")!,
            minUpdaterProtocol: 1,
            signature: "signature"
        )
        manager.allowDeveloperDowngrade = true
        assert(!manager.isUpdateAllowed(current, bleManager: bleManager),
               "exactly installed firmware should not be installable as an update even with developer downgrade enabled")
        assert(!manager.isNewerUpdateAvailable(current, bleManager: bleManager),
               "exactly installed firmware should not show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: current, bleManager: bleManager),
                    "firmware is current",
                    "exactly installed firmware reports current")

        let newer = FirmwareReleaseManifest(
            schemaVersion: current.schemaVersion,
            target: current.target,
            version: "0.2.5",
            build: 89,
            gitSha: "bbbbbb123456",
            size: current.size,
            sha256: current.sha256,
            url: current.url,
            minUpdaterProtocol: current.minUpdaterProtocol,
            signature: current.signature
        )
        assert(manager.isUpdateAllowed(newer, bleManager: bleManager),
               "newer build should be installable")
        assert(manager.isNewerUpdateAvailable(newer, bleManager: bleManager),
               "newer build should show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: newer, bleManager: bleManager),
                    "firmware update available",
                    "newer build reports update available")

        let older = FirmwareReleaseManifest(
            schemaVersion: current.schemaVersion,
            target: current.target,
            version: "0.2.3",
            build: 87,
            gitSha: "aaaaaa123456",
            size: current.size,
            sha256: current.sha256,
            url: current.url,
            minUpdaterProtocol: current.minUpdaterProtocol,
            signature: current.signature
        )
        assert(manager.isUpdateAllowed(older, bleManager: bleManager),
               "older build remains installable behind developer downgrade")
        assert(!manager.isNewerUpdateAvailable(older, bleManager: bleManager),
               "developer downgrade should not show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: older, bleManager: bleManager),
                    "developer firmware install available",
                    "developer downgrade is not labeled as a normal update")
    }

    static func testFirmwareOperationReceiptReconciliation() {
        let suite = "FirmwareOperationReceipt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let operation = String(repeating: "a", count: 32)
        let image = String(repeating: "b", count: 64)
        let pending = PendingFirmwareUpdate(target: "WAVESHARE_AMOLED_175", version: "0.4.0", build: 100,
            gitSha: String(repeating: "c", count: 40), startedAt: Date(), status: "device rebooting",
            deviceID: "device-a", transactionStage: .unresolved,
            operationID: operation, imageSHA256: image, requiresOperationReceipt: true)
        for (result, id, hash, device, ready, shouldInstall) in [
            ("accepted", operation, image, "device-a", true, false),
            ("installed", String(repeating: "d", count: 32), image, "device-a", true, false),
            ("installed", operation, String(repeating: "e", count: 64), "device-a", true, false),
            ("installed", operation, image, "device-b", true, false),
            ("installed", operation, image, "device-a", false, false),
            ("failed", operation, image, "device-a", true, false),
            ("installed", operation, image, "device-a", true, true)
        ] {
            defaults.set(try! JSONEncoder().encode(pending), forKey: "firmware.pendingUpdate")
            let manager = FirmwareUpdateManager(defaults: defaults)
            let ble = BLEManager()
            ble.setConnectedDeviceIDForTesting(device)
            ble.isNavigationReady = ready
            let object: [String: Any] = ["enabled": false, "mode": "",
                "firmwareOperation": ["protocolVersion": 1, "operationId": id, "imageSha256": hash, "result": result]]
            let body = try! JSONSerialization.data(withJSONObject: object)
            assert(ble.handleDeviceTransferStatusNotification(Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + body), "receipt parses")
            ble.firmwareTarget = pending.target; ble.firmwareVersion = pending.version
            ble.firmwareBuild = pending.build; ble.firmwareGitSha = pending.gitSha
            ble.setFirmwareBootCheckpointForTesting(normalReady: true)
            manager.reconcilePendingUpdate(bleManager: ble)
            assertEqual(defaults.data(forKey: "firmware.pendingUpdate") == nil, shouldInstall,
                "only exact authenticated operation/image/device plus accepted boot can complete")
            if shouldInstall {
                assert(defaults.data(forKey: "firmware.retainedResult") != nil, "terminal identity retained for explicit device acknowledgement")
            }
            assert(ble.handleDeviceTransferStatusNotification(Data("DSTS{\"enabled\":false,\"mode\":\"\"}".utf8)), "missing receipt parses")
            assert(ble.firmwareOperation == nil, "omitted receipt clears stale evidence")
        }
        let disabled = try! JSONDecoder().decode(FirmwareOperationReceipt.self, from: Data("{\"protocolVersion\":0}".utf8))
        assert(!disabled.matches(operationID: operation, image: image), "disabled capability cannot establish result")
    }

    static func testFirmwareSourceIdentityMigration() {
        let full = String(repeating: "a", count: 40)
        assertEqual(FirmwareSourceIdentity.fullSHA(full, target: "WAVESHARE_AMOLED_175", version: "0.3.4", build: 94), full,
                    "full immutable identity is preserved")
        for target in ["WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"] {
            assertEqual(FirmwareSourceIdentity.fullSHA("02bce8150d2c", target: target, version: "0.3.3", build: 92),
                        "02bce8150d2c0f88fa0481d9b6fcef76da8865ef", "previous immutable release migrates exactly")
            assertEqual(FirmwareSourceIdentity.fullSHA("8a0c9df6db26", target: target, version: "0.3.4", build: 93),
                        FirmwareSourceIdentity.legacySHA, "known immutable release migrates exactly")
            assert(FirmwareSourceIdentity.fullSHA("8a0c9df6db26", target: target, version: "0.3.4", build: 94) == nil,
                   "legacy prefix cannot identify a different build")
        }
        for sha in ["a", String(repeating: "a", count: 12), String(repeating: "A", count: 40), full + "a"] {
            assert(FirmwareSourceIdentity.fullSHA(sha, target: "WAVESHARE_AMOLED_175", version: "0.3.4", build: 94) == nil,
                   "arbitrary prefixes and malformed source identities fail closed")
        }
        assert(!FirmwareHTTPSRedirectPolicy.allows(URL(string: "http://example.test/image")!), "HTTPS downgrade rejected")
        assert(!FirmwareHTTPSRedirectPolicy.allows(URL(string: "https://user:pass@example.test/image")!), "URL credentials rejected")
        assert(FirmwareHTTPSRedirectPolicy.allows(URL(string: "https://release-assets.githubusercontent.com/image")!), "HTTPS CDN redirect allowed")
    }

    static func testFirmwareDownloadBounds() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); FirmwareRequestCaptureProtocol.handler = nil }
        let url = URL(string: "https://example.test/firmware")!
        // URLProtocol delivers decoded bytes, matching the application's
        // boundary after HTTP decompression; Content-Length is never authority.
        for (count, header, shouldPass) in [(2048, nil, true), (2049, nil, false),
                                          (2049, "1", false), (1, "99999999", false)] as [(Int, String?, Bool)] {
            FirmwareRequestCaptureProtocol.handler = { request, _ in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                 headerFields: header.map { ["Content-Length": $0] })!, Data(repeating: 65, count: count))
            }
            runAsyncTest {
                do {
                    let data = try await FirmwareDownload.read(url, session: session, maximumBytes: 2048)
                    assert(shouldPass && data.count == count, "only exactly bounded responses pass")
                } catch {
                    assert(!shouldPass, "at-limit response must not fail: \(error)")
                }
            }
        }
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("abc".utf8))
        }
        runAsyncTest {
            let hash = FirmwareUpdateManager.sha256Hex(Data("abc".utf8))
            let image = try await FirmwareDownload.read(url, session: session, maximumBytes: 3, expectedSHA256: hash)
            assertEqual(image, Data("abc".utf8), "streaming hash verifies exact image")
            for (size, digest) in [(4, hash), (3, String(repeating: "0", count: 64))] {
                do {
                    _ = try await FirmwareDownload.read(url, session: session, maximumBytes: size, expectedSHA256: digest)
                    assert(false, "truncated or corrupt image must fail")
                } catch { }
            }
        }
    }

    @MainActor
    static func testFirmwarePendingIdentityReconciliation() async {
        let suiteName = "FirmwarePendingIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for sha in [FirmwareSourceIdentity.legacySHA, "8a0c9df6db26"] {
            let pending = PendingFirmwareUpdate(target: "WAVESHARE_AMOLED_175", version: "0.3.4", build: 93,
                                                gitSha: sha, startedAt: Date(), status: "device rebooting")
            defaults.set(try! JSONEncoder().encode(pending), forKey: "firmware.pendingUpdate")
            let manager = FirmwareUpdateManager(defaults: defaults) // actual persisted relaunch path
            let ble = BLEManager()
            ble.isNavigationReady = true
            ble.firmwareTarget = pending.target
            ble.firmwareVersion = pending.version
            ble.firmwareBuild = pending.build
            ble.firmwareGitSha = String(repeating: "0", count: 40) // rollback/different image
            ble.setFirmwareBootCheckpointForTesting(normalReady: true)
            manager.refreshDeviceFirmwareStatus(bleManager: ble)
            try? await Task.sleep(nanoseconds: 800_000_000)
            assert(defaults.data(forKey: "firmware.pendingUpdate") != nil, "different running image does not clear pending update")
            ble.firmwareGitSha = FirmwareSourceIdentity.legacySHA
            manager.refreshDeviceFirmwareStatus(bleManager: ble)
            for _ in 0..<100 {
                if defaults.data(forKey: "firmware.pendingUpdate") == nil { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            assert(defaults.data(forKey: "firmware.pendingUpdate") == nil,
                   "exact full running identity clears both new and legacy persisted updates")
            assertEqual(manager.statusMessage, "firmware update installed", "relaunch reports verified identity completion")
        }

        let requested = PendingFirmwareUpdate(
            target: "WAVESHARE_AMOLED_175",
            version: "0.4.0",
            build: 100,
            gitSha: String(repeating: "b", count: 40),
            startedAt: Date(),
            status: "restarting in firmware maintenance",
            deviceID: "device-a",
            maintenanceCorrelation: 77,
            transactionStage: .maintenanceReady
        )
        defaults.set(
            try! JSONEncoder().encode(requested),
            forKey: "firmware.pendingUpdate"
        )
        let cancelledManager = FirmwareUpdateManager(defaults: defaults)
        let cancelledBLE = BLEManager()
        cancelledBLE.isNavigationReady = true
        cancelledBLE.setConnectedDeviceIDForTesting("device-a")
        cancelledBLE.firmwareTarget = requested.target
        cancelledBLE.firmwareVersion = "0.3.4"
        cancelledBLE.firmwareBuild = 96
        cancelledBLE.firmwareGitSha = String(repeating: "a", count: 40)
        cancelledBLE.setFirmwareBootCheckpointForTesting(normalReady: true)
        cancelledManager.refreshDeviceFirmwareStatus(bleManager: cancelledBLE)
        try? await Task.sleep(nanoseconds: 800_000_000)
        assertEqual(
            cancelledManager.statusMessage,
            "firmware update cancelled",
            "a pre-commit transaction returning to the old ready image is cancelled"
        )

        var postCommit = requested
        postCommit.status = "device rebooting"
        postCommit.transactionStage = .rebooting
        defaults.set(
            try! JSONEncoder().encode(postCommit),
            forKey: "firmware.pendingUpdate"
        )
        let rollbackManager = FirmwareUpdateManager(defaults: defaults)
        rollbackManager.refreshDeviceFirmwareStatus(bleManager: cancelledBLE)
        try? await Task.sleep(nanoseconds: 800_000_000)
        assertEqual(
            rollbackManager.statusMessage,
            "firmware update rolled back",
            "a post-commit transaction returning to the old ready image is rollback"
        )

        defaults.set(
            try! JSONEncoder().encode(requested),
            forKey: "firmware.pendingUpdate"
        )
        let maintenanceManager = FirmwareUpdateManager(defaults: defaults)
        let maintenanceBLE = BLEManager()
        maintenanceBLE.isNavigationReady = true
        maintenanceBLE.setConnectedDeviceIDForTesting("device-a")
        let maintenanceStatus = """
        {"enabled":false,"mode":"","maintenance":{"supported":true,"active":true,"stage":"awaiting_authentication","correlation":77},"bootCheckpoint":{"schemaVersion":1,"normalReady":false,"maintenance":true,"bootSequence":10,"bootFingerprint":5678},"firmware":{"status":"idle","target":"WAVESHARE_AMOLED_175","version":"0.3.4","build":96,"gitSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
        """
        assert(maintenanceBLE.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(maintenanceStatus.utf8)
        ), "maintenance reconciliation status should parse")
        maintenanceManager.refreshDeviceFirmwareStatus(
            bleManager: maintenanceBLE
        )
        try? await Task.sleep(nanoseconds: 800_000_000)
        assertEqual(
            maintenanceManager.statusMessage,
            "firmware update awaiting completion",
            "app relaunch recognizes the same maintenance transaction without replay"
        )

        var lostAcknowledgement = requested
        lostAcknowledgement.maintenanceCorrelation = nil
        lostAcknowledgement.transactionStage = .maintenanceRequested
        defaults.set(
            try! JSONEncoder().encode(lostAcknowledgement),
            forKey: "firmware.pendingUpdate"
        )
        let unresolvedManager = FirmwareUpdateManager(defaults: defaults)
        unresolvedManager.refreshDeviceFirmwareStatus(
            bleManager: maintenanceBLE
        )
        try? await Task.sleep(nanoseconds: 800_000_000)
        assertEqual(
            unresolvedManager.statusMessage,
            "firmware update status unresolved",
            "lost acknowledgement remains unresolved and is never replayed blindly"
        )
    }

    static func testFirmwareDeviceClientSendsSignedBeginRequest() {
        let manifest = FirmwareReleaseManifest(
            schemaVersion: 1,
            target: "WAVESHARE_AMOLED_175",
            version: "0.4.0",
            build: 87,
            gitSha: "abcdef123456",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            url: URL(string: "https://github.com/seichris/open-bike-computer/releases/download/v0.4.0/WAVESHARE_AMOLED_175.bin")!,
            minUpdaterProtocol: 1,
            signature: "MEUCIQCoFhwd6SnmvltHkUu5jfNQce/pPk87c84AcHt2u9DmDQIgfwklONo1MEyfgfX0VhlTDyi/B+dGZdsvckb/rFEGOM8="
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }

        FirmwareRequestCaptureProtocol.handler = { request, body in
            assertEqual(request.httpMethod, "POST", "begin request uses POST")
            assertEqual(request.url?.path, "/firmware-update/begin", "begin request uses firmware path")
            assertEqual(request.value(forHTTPHeaderField: "X-BikeComputer-Transfer-Token"), "token-123", "begin request includes transfer token")
            assertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "begin request declares JSON")
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                assert(false, "begin request body should be JSON")
                throw FirmwareUpdateError.invalidManifest
            }
            assertEqual(object["target"] as? String, manifest.target, "begin request sends target")
            assertEqual(object["gitSha"] as? String, manifest.gitSha, "begin request sends git SHA")
            assertEqual(object["manifestSignature"] as? String, manifest.signature, "begin request sends manifest signature")
            assertEqual(object["releaseUrl"] as? String, manifest.url.absoluteString, "begin request sends release URL")
            assertEqual(object["allowDowngrade"] as? Bool, true, "begin request sends developer downgrade flag")

            let data = Data("""
            {
              "status": "receiving",
              "target": "WAVESHARE_AMOLED_175",
              "runningVersion": "0.2.2",
              "runningBuild": 86,
              "runningPartition": "ota_0",
              "inactivePartition": "ota_1",
              "otaState": "valid",
              "maxImageBytes": 3145728,
              "receivedBytes": 0,
              "totalBytes": 3,
              "sha256": null,
              "lastError": null
            }
            """.utf8)
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (response, data)
        }

        runAsyncTest {
            let client = FirmwareUpdateDeviceClient(
                baseURL: URL(string: "http://192.168.4.1:8080")!,
                sessionToken: "token-123",
                session: session
            )
            let status = try await client.begin(manifest: manifest, allowDowngrade: true)
            assertEqual(status.status, "receiving", "begin response decodes firmware status")
            assertEqual(status.totalBytes, 3, "begin response decodes expected byte count")
        }
    }

    nonisolated static func runAsyncTest(
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                try await operation()
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            assert(false, "async test failed: \(failure)")
        }
    }

    @MainActor
    static func runMainActorAsyncTest(
        _ operation: @MainActor @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            assert(false, "main-actor async test failed: \(error)")
        }
    }

    static func testNavigationPacketBuilder() {
        let shortPacket = "2|150|Turn left"
        guard let shortData = NavigationPacketBuilder.data(from: shortPacket, maxLength: NavigationPacketBuilder.protocolMaxBytes) else {
            assert(false, "short packet should encode")
            return
        }
        assertEqual(String(data: shortData, encoding: .utf8), shortPacket, "short packet passes unchanged")

        let longInstruction = String(repeating: "直行", count: 80)
        guard let data = NavigationPacketBuilder.data(
            from: "1|4294967295|\(longInstruction)",
            maxLength: NavigationPacketBuilder.protocolMaxBytes
        ) else {
            assert(false, "long UTF-8 packet should truncate")
            return
        }

        assert(data.count <= NavigationPacketBuilder.protocolMaxBytes, "truncated packet respects byte limit")
        let packet = String(data: data, encoding: .utf8)
        assert(packet?.hasPrefix("1|4294967295|") == true, "truncated packet keeps prefix")
        assert(packet?.contains("\u{FFFD}") == false, "truncated packet remains valid UTF-8")
        let instruction = packet?.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).last
        assert(instruction?.data(using: .utf8)?.count ?? Int.max <= NavigationPacketBuilder.instructionMaxBytes, "instruction respects firmware byte limit")

        assert(NavigationPacketBuilder.data(from: "not-a-packet", maxLength: 8) == nil, "malformed packets fail when truncation is needed")
        assert(NavigationPacketBuilder.data(from: "1|4294967295|Turn", maxLength: 4) == nil, "oversized prefix fails")
        let fallbackData = NavigationPacketBuilder.data(from: "1|100|", maxLength: NavigationPacketBuilder.protocolMaxBytes)
        assertEqual(String(data: fallbackData ?? Data(), encoding: .utf8), "1|100|Continue", "empty instruction falls back to continue")
    }

    static func testNavigationWriteQueue() {
        var queue = NavigationWriteQueue(maxCount: 2)
        queue.enqueue(NavigationWrite(data: Data([1]), label: "first"))
        queue.enqueue(NavigationWrite(data: Data([2]), label: "second"))
        assertEqual(queue.count, 2, "queue stores pending writes")

        let didDrop = queue.enqueue(NavigationWrite(data: Data([3]), label: "third"))
        assert(didDrop, "queue reports overflow")
        assertEqual(queue.count, 2, "queue caps pending writes")

        var sent: [Data] = []
        var labels: [String] = []
        queue.flush(canSend: { sent.count < 1 }) {
            sent.append($0.data)
            labels.append($0.label)
        }
        assertEqual(sent, [Data([2])], "queue drops oldest packet first")
        assertEqual(labels, ["second"], "queue preserves write metadata")
        assertEqual(queue.count, 1, "queue retains unsent packet under backpressure")

        queue.flush(canSend: { true }) {
            sent.append($0.data)
            labels.append($0.label)
        }
        assertEqual(sent, [Data([2]), Data([3])], "queue flushes remaining packet")
        assertEqual(labels, ["second", "third"], "queue flushes write metadata in order")
        assertEqual(queue.count, 0, "queue is empty after flush")
        assertEqual(queue.metrics.enqueuedFrames, 3,
                    "diagnostic metrics count accepted regular frames")
        assertEqual(queue.metrics.flushedFrames, 2,
                    "diagnostic metrics count flushed frames")
        assertEqual(queue.metrics.droppedFrames, 1,
                    "diagnostic metrics count capacity evictions")
        assertEqual(queue.metrics.currentDepth, 0,
                    "diagnostic metrics expose current queue depth")
        assertEqual(queue.metrics.maxDepth, 2,
                    "diagnostic metrics retain peak bounded depth")

        var pacedQueue = NavigationWriteQueue(maxCount: 3)
        pacedQueue.enqueue(NavigationWrite(data: Data([1]), label: "first"))
        pacedQueue.enqueue(NavigationWrite(data: Data([2]), label: "second"))
        var pacedWrites: [Data] = []
        pacedQueue.flush(canSend: { true }, maxWrites: 1) {
            pacedWrites.append($0.data)
        }
        assertEqual(pacedWrites, [Data([1])],
                    "paced flush sends only the configured batch size")
        assertEqual(pacedQueue.count, 1,
                    "paced flush retains later writes for the next transport tick")

        var reconnectQueue = NavigationWriteQueue(
            maxCount: DeviceBLEProtocol.fallbackWriteQueueCapacity
        )
        for index in 0..<30 {
            assert(!reconnectQueue.enqueue(NavigationWrite(
                data: Data([UInt8(index)]),
                label: "reconnect-\(index)"
            )), "bounded automatic reconnect traffic must not evict persisted settings")
        }
        var reconnectWrites: [NavigationWrite] = []
        reconnectQueue.flush(canSend: { true }) { reconnectWrites.append($0) }
        assertEqual(reconnectWrites.count, 30,
                    "fallback queue retains the complete automatic reconnect burst")
        assertEqual(reconnectWrites.first?.label, "reconnect-0",
                    "fallback queue preserves the oldest reconnect setting")

        var didNotifyDrop = false
        var trackedQueue = NavigationWriteQueue(maxCount: 1)
        trackedQueue.enqueue(NavigationWrite(
            data: Data([1]),
            label: "tracked",
            onDrop: { didNotifyDrop = true }
        ))
        assert(trackedQueue.enqueue(NavigationWrite(data: Data([2]), label: "replacement")),
               "overflow reports that the oldest write was dropped")
        assert(didNotifyDrop, "tracked writes are notified when queue overflow evicts them")

        var targetedWrites: [Data] = []
        var fallbackWrites: [Data] = []
        let targetedWrite = NavigationWrite(
            data: Data([3]),
            label: "targeted",
            transportWrite: { targetedWrites.append($0) }
        )
        targetedWrite.perform { fallbackWrites.append($0) }
        assertEqual(targetedWrites, [Data([3])],
                    "targeted writes use their native characteristic transport")
        assertEqual(fallbackWrites.count, 0,
                    "targeted writes do not leak onto the fallback characteristic")

        var atomicQueue = NavigationWriteQueue(maxCount: 3)
        atomicQueue.enqueue(NavigationWrite(data: Data([1]), label: "existing"))
        assert(!atomicQueue.enqueueAtomically([
            NavigationWrite(data: Data([2]), label: "chunk-1"),
            NavigationWrite(data: Data([3]), label: "chunk-2"),
            NavigationWrite(data: Data([4]), label: "chunk-3")
        ]), "an oversized logical message is rejected atomically")
        assertEqual(atomicQueue.count, 1,
                    "atomic rejection leaves existing queue traffic unchanged")
        assert(atomicQueue.enqueueAtomically([
            NavigationWrite(data: Data([2]), label: "chunk-1"),
            NavigationWrite(data: Data([3]), label: "chunk-2")
        ]), "a complete logical message fits in the remaining capacity")
        assertEqual(atomicQueue.remainingCapacity, 0,
                    "remaining queue capacity accounts for atomic writes")

        var protectedBatchQueue = NavigationWriteQueue(maxCount: 3)
        assert(protectedBatchQueue.enqueueAtomically([
            NavigationWrite(data: Data([1]), label: "catalog-1"),
            NavigationWrite(data: Data([2]), label: "catalog-2"),
            NavigationWrite(data: Data([3]), label: "catalog-3")
        ]), "a complete logical message can fill the queue")
        var overflowWasDropped = false
        assert(protectedBatchQueue.enqueue(NavigationWrite(
            data: Data([4]),
            label: "later-write",
            onDrop: { overflowWasDropped = true }
        )), "queue pressure reports a dropped regular write")
        var protectedWrites: [Data] = []
        protectedBatchQueue.flush(canSend: { true }) { protectedWrites.append($0.data) }
        assert(overflowWasDropped,
               "a later regular write is dropped when only atomic chunks are pending")
        assertEqual(protectedWrites, [Data([1]), Data([2]), Data([3])],
                    "later queue pressure cannot fragment an accepted atomic message")

        var protectedSettingQueue = NavigationWriteQueue(maxCount: 1)
        assert(protectedSettingQueue.enqueueAtomically([
            NavigationWrite(data: Data([5]), label: "protected-transfer")
        ]), "a protected transfer can occupy the bounded queue")
        assert(!protectedSettingQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([6]),
                label: "automatic-display-off",
                coalescingKey: DeviceBLEProtocol.automaticDisplayOffSettingCoalescingKey
            ),
            prioritized: false
        ), "automatic display-off rejects a full protected queue instead of reporting success")
        assertEqual(protectedSettingQueue.count, 1,
                    "a rejected automatic display-off write preserves the protected transfer")

        var rejectedCoalescingDropCount = 0
        var fullProtectedCoalescingQueue = NavigationWriteQueue(maxCount: 2)
        assert(fullProtectedCoalescingQueue.enqueueAtomically([
            NavigationWrite(data: Data([1]), label: "atomic-1"),
            NavigationWrite(data: Data([2]), label: "atomic-2"),
        ]), "an atomic batch fills the queue for coalescing rejection coverage")
        assert(!fullProtectedCoalescingQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([3]),
                label: "rejected-telemetry",
                onDrop: { rejectedCoalescingDropCount += 1 },
                coalescingKey: "workout-core"
            ),
            prioritized: false
        ), "a coalesced write reports rejection behind a full protected batch")
        assertEqual(rejectedCoalescingDropCount, 0,
                    "a never-admitted write does not also fire its queued-drop callback")
        assertEqual(fullProtectedCoalescingQueue.count, 2,
                    "coalescing rejection preserves the full atomic batch")

        var retainedReplacementWasDropped = false
        var transactionalReplacementQueue = NavigationWriteQueue(
            maxCount: 2,
            maxPendingBytes: 5
        )
        assert(transactionalReplacementQueue.enqueueAtomically([
            NavigationWrite(
                data: Data([1, 2, 3]),
                label: "protected-batch"
            )
        ]), "a protected batch leaves one small replaceable slot")
        assert(transactionalReplacementQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([4]),
                label: "retained-state",
                onDrop: { retainedReplacementWasDropped = true },
                coalescingKey: "latest-state"
            ),
            prioritized: false
        ), "the first small replaceable state is admitted")
        assert(!transactionalReplacementQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([5, 6, 7]),
                label: "oversized-replacement",
                coalescingKey: "latest-state"
            ),
            prioritized: false
        ), "a larger replacement rejects transactionally at the byte ceiling")
        assert(!retainedReplacementWasDropped,
               "rejected replacement preserves the prior authoritative state")
        var transactionalReplacementWrites: [Data] = []
        transactionalReplacementQueue.flush(canSend: { true }) {
            transactionalReplacementWrites.append($0.data)
        }
        assertEqual(
            transactionalReplacementWrites,
            [Data([1, 2, 3]), Data([4])],
            "transactional rejection leaves the protected batch and old state intact"
        )

        var prioritizedQueue = NavigationWriteQueue(maxCount: 3)
        var droppedRegularWrite = false
        prioritizedQueue.enqueue(NavigationWrite(
            data: Data([1]),
            label: "regular-1",
            onDrop: { droppedRegularWrite = true }
        ))
        prioritizedQueue.enqueue(NavigationWrite(data: Data([2]), label: "regular-2"))
        prioritizedQueue.enqueue(NavigationWrite(data: Data([3]), label: "regular-3"))
        assert(prioritizedQueue.enqueuePrioritizedAtomically([
            NavigationWrite(data: Data([9]), label: "destination-status")
        ]), "a destination status uses its dedicated lane at bulk capacity")
        assert(!droppedRegularWrite,
               "priority admission does not evict ordinary traffic")
        assertEqual(prioritizedQueue.count, 4,
                    "the bounded priority lane is separate from bulk capacity")
        var prioritizedWrites: [Data] = []
        prioritizedQueue.flush(canSend: { true }) {
            prioritizedWrites.append($0.data)
        }
        assertEqual(prioritizedWrites,
                    [Data([9]), Data([1]), Data([2]), Data([3])],
                    "destination status is sent before queued ordinary traffic")

        var catalogAndStatusQueue = NavigationWriteQueue(maxCount: 3)
        assert(catalogAndStatusQueue.enqueueAtomically([
            NavigationWrite(data: Data([4]), label: "catalog-1"),
            NavigationWrite(data: Data([5]), label: "catalog-2"),
            NavigationWrite(data: Data([6]), label: "catalog-3")
        ]), "catalog batch can fill bulk capacity before priority traffic")
        var supersededStatusWasDropped = false
        assert(catalogAndStatusQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([8]),
                label: "calculating-status",
                onDrop: { supersededStatusWasDropped = true },
                coalescingKey: "destination-status"
            )
        ]), "first priority status is admitted despite a full catalog lane")
        assert(catalogAndStatusQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([9]),
                label: "terminal-status",
                coalescingKey: "destination-status"
            )
        ]), "new terminal status replaces an older queued status")
        assert(supersededStatusWasDropped,
               "priority replacement reports the superseded status")
        var catalogAndStatusWrites: [Data] = []
        catalogAndStatusQueue.flush(canSend: { true }) {
            catalogAndStatusWrites.append($0.data)
        }
        assertEqual(catalogAndStatusWrites,
                    [Data([9]), Data([4]), Data([5]), Data([6])],
                    "priority replacement preserves the complete catalog batch")

        var mixedPriorityQueue = NavigationWriteQueue(
            maxCount: 3,
            priorityMaxCount: 2
        )
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([7]),
            label: "workout-core",
            coalescingKey: "workout-telemetry-core"
        ), prioritized: true), "workout core uses one priority slot")
        var replacedDestinationStatusWasDropped = false
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([8]),
            label: "calculating-status",
            onDrop: { replacedDestinationStatusWasDropped = true },
            coalescingKey: "destination-status"
        ), prioritized: true), "calculating status uses the other priority slot")
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([9]),
            label: "terminal-status",
            coalescingKey: "destination-status"
        ), prioritized: true), "terminal status replaces only its predecessor")
        assert(replacedDestinationStatusWasDropped,
               "capacity-two replacement reports the superseded status")
        var mixedPriorityWrites: [Data] = []
        mixedPriorityQueue.flush(canSend: { true }) {
            mixedPriorityWrites.append($0.data)
        }
        assertEqual(mixedPriorityWrites, [Data([7]), Data([9])],
                    "unrelated workout priority survives latest-status replacement")

        var catalogWriteFailureWasReported = false
        var failureTrackingQueue = NavigationWriteQueue(maxCount: 1)
        assert(failureTrackingQueue.enqueueAtomically([
            NavigationWrite(
                data: Data([7]),
                label: "catalog",
                onWriteFailure: { catalogWriteFailureWasReported = true }
            )
        ]), "catalog failure callback is accepted with the atomic batch")
        failureTrackingQueue.flush(canSend: { true }) { write in
            write.onWriteFailure?()
        }
        assert(catalogWriteFailureWasReported,
               "atomic batch protection preserves the transport failure callback")

        var metricsQueue = NavigationWriteQueue(maxCount: 1)
        assert(metricsQueue.enqueueCoalescing(NavigationWrite(
            data: Data([1]),
            label: "gps-1",
            writeClass: .gpsPosition,
            coalescingKey: "gps"
        ), prioritized: false), "first replaceable state is accepted")
        assert(metricsQueue.enqueueCoalescing(NavigationWrite(
            data: Data([2]),
            label: "gps-2",
            writeClass: .gpsPosition,
            coalescingKey: "gps"
        ), prioritized: false), "new state replaces the stale state")
        assert(!metricsQueue.enqueueAtomically([
            NavigationWrite(data: Data([3]), label: "oversized-1"),
            NavigationWrite(data: Data([4]), label: "oversized-2")
        ]), "oversized atomic diagnostics fixture is rejected")
        metricsQueue.flush(canSend: { false }) { _ in
            assert(false, "backpressured queue must not write")
        }
        metricsQueue.noteRetryScheduled()
        metricsQueue.flush(canSend: { true }) { _ in }
        metricsQueue.enqueue(NavigationWrite(data: Data([5]), label: "clear"))
        metricsQueue.removeAll()

        let queueMetrics = metricsQueue.snapshotMetricsAndReset()
        assertEqual(NavigationWriteQueueMetrics.schemaVersion, 3,
                    "queue metrics schema is explicitly versioned")
        assertEqual(queueMetrics.enqueuedFrames, 3,
                    "queue metrics distinguish accepted frames")
        assertEqual(queueMetrics.flushedFrames, 1,
                    "queue metrics count transport writes")
        assertEqual(queueMetrics.rejectedFrames, 2,
                    "queue metrics count rejected atomic frames")
        assertEqual(queueMetrics.coalescedFrames, 1,
                    "queue metrics count superseded replaceable state")
        assertEqual(queueMetrics.coalescedFrames(for: .gpsPosition), 1,
                    "queue metrics attribute coalescing to GPS state")
        assertEqual(queueMetrics.clearedFrames, 1,
                    "queue metrics count disconnect-style clearing")
        assertEqual(queueMetrics.retrySchedules, 1,
                    "queue metrics count retry scheduling")
        assertEqual(queueMetrics.backpressureStops, 1,
                    "queue metrics count transport backpressure")
        assertEqual(queueMetrics.currentDepth, 0,
                    "queue metrics depth returns to zero")
        assertEqual(metricsQueue.metrics.enqueuedFrames, 0,
                    "queue interval metrics reset after a snapshot")
        assertEqual(metricsQueue.metrics.maxDepth, 0,
                    "an empty queue starts the next interval at zero depth")

        var byteQueue = NavigationWriteQueue(
            maxCount: 4,
            priorityMaxCount: 2,
            maxPendingBytes: 4,
            priorityMaxPendingBytes: 3
        )
        assert(byteQueue.enqueueAtomically([
            NavigationWrite(data: Data([1, 2]), label: "byte-1"),
            NavigationWrite(data: Data([3, 4]), label: "byte-2"),
        ]), "an atomic batch may fill the regular byte ceiling")
        assert(!byteQueue.enqueueAtomically([
            NavigationWrite(data: Data([5]), label: "byte-overflow")
        ]), "regular byte overflow rejects the entire new batch")
        assert(byteQueue.enqueuePrioritizedAtomically([
            NavigationWrite(data: Data([6, 7, 8]), label: "priority-bytes")
        ]), "the independent priority byte lane admits its exact ceiling")
        assert(!byteQueue.enqueuePrioritizedAtomically([
            NavigationWrite(data: Data([9]), label: "priority-overflow")
        ]), "priority byte overflow is rejected without eviction")
        assertEqual(byteQueue.pendingByteCount, 7,
                    "queue exposes the combined bounded byte footprint")

        var boundaryQueue = NavigationWriteQueue(maxCount: 3)
        boundaryQueue.enqueue(NavigationWrite(data: Data([6]), label: "pending-1"))
        boundaryQueue.enqueue(NavigationWrite(data: Data([7]), label: "pending-2"))
        let boundarySnapshot = boundaryQueue.snapshotMetricsAndReset()
        assertEqual(boundarySnapshot.enqueuedFrames, 2,
                    "the completed interval retains pre-boundary events")
        assertEqual(boundarySnapshot.currentDepth, 2,
                    "the completed interval reports pending queue depth")

        let nextBoundarySnapshot = boundaryQueue.snapshotMetricsAndReset()
        assertEqual(nextBoundarySnapshot.enqueuedFrames, 0,
                    "the next interval starts with cleared event counters")
        assertEqual(nextBoundarySnapshot.currentDepth, 2,
                    "the next interval retains pending queue depth")
        assertEqual(nextBoundarySnapshot.maxDepth, 2,
                    "the next interval starts at the existing queue depth")

        var boundaryWrites: [Data] = []
        boundaryQueue.flush(canSend: { _ in true }) { write in
            boundaryWrites.append(write.data)
        }
        assertEqual(boundaryWrites, [Data([6]), Data([7])],
                    "metrics snapshots do not mutate pending writes")
    }

    static func testGPSQueuePolicy() {
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 36,
            protectionOverhead: 22,
            withResponseMaximum: 58,
            withoutResponseMaximum: 58
        ), .nativeWithResponse,
                    "protected 36-byte GPS quality packets fit the acknowledged route")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .nativeWithResponse,
                    "map-driving GPS prefers acknowledged native delivery")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: false,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .nativeWithResponse,
                    "GPS remains acknowledged when that is the only native transport")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: false,
            hasNativeWriteWithoutResponse: false,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .navigationFallback,
                    "missing native GPS uses the reliable navigation endpoint")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 20,
            withoutResponseMaximum: 512
        ), .nativeWithoutResponse,
                    "GPS uses native write-without-response only when acknowledgment is unavailable")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 20,
            withoutResponseMaximum: 20
        ), .navigationFallback,
                    "insufficient native MTU falls back without dropping current GPS")

        let channelManager = BLEManager()
        let writeSession = AuthenticatedBLEWriteSession(
            ownerKey: Data((0..<32).map(UInt8.init)),
            deviceID: "00112233445566778899aabbccddeeff",
            clientNonce: "102132435465768798a9babbdcddedef",
            serverNonce: "ffeeddccbbaa99887766554433221100"
        )
        let gpsPayload = DeviceGPSPacketBuilder.data(
            lat: 1.3,
            lon: 103.8,
            heading: 45
        )
        let protectedGPS = channelManager.devicePayloadForTesting(
            gpsPayload,
            for: DeviceBLEProtocol.gpsPositionCharacteristicUUID,
            authenticatedWriteSession: writeSession
        )
        let protectedNavigation = channelManager.devicePayloadForTesting(
            gpsPayload,
            for: DeviceBLEProtocol.navigationCharacteristicUUID,
            authenticatedWriteSession: writeSession
        )
        let protectedScreenConfiguration = channelManager.devicePayloadForTesting(
            gpsPayload,
            for: DeviceBLEProtocol.screenConfigurationCharacteristicUUID,
            authenticatedWriteSession: writeSession
        )
        assertEqual(
            protectedGPS?.count,
            gpsPayload.count + AuthenticatedBLEWriteSession.frameOverhead,
            "native GPS capacity accounts for authenticated framing overhead"
        )
        assert(protectedGPS != protectedNavigation,
               "native GPS uses its characteristic-bound authenticated channel")
        assertEqual(
            protectedScreenConfiguration?.count,
            gpsPayload.count + AuthenticatedBLEWriteSession.frameOverhead,
            "screen configuration uses the protected owner transport"
        )
        assert(protectedScreenConfiguration != protectedNavigation,
               "screen configuration has an independent replay sequence")

        var transportReady = false
        var queue = NavigationWriteQueue(maxCount: 4, priorityMaxCount: 2)
        func gpsWrite(_ value: UInt8) -> NavigationWrite {
            NavigationWrite(
                data: Data([value]),
                label: "gps-\(value)",
                transportCanSend: { transportReady },
                transportExpectsWriteResponse: false,
                writeClass: .gpsPosition,
                coalescingKey: DeviceBLEProtocol.gpsPositionCoalescingKey
            )
        }

        assert(queue.enqueueCoalescing(gpsWrite(1), prioritized: false),
               "first GPS state enters the regular lane")
        assert(queue.enqueueCoalescing(gpsWrite(2), prioritized: false),
               "second GPS state replaces the first pending state")
        assert(queue.enqueueAtomically([
            NavigationWrite(
                data: Data([40]),
                label: "route-1",
                writeClass: .route
            ),
            NavigationWrite(
                data: Data([41]),
                label: "route-2",
                writeClass: .route
            )
        ]), "protected route chunks are admitted atomically")
        assert(queue.enqueueCoalescing(NavigationWrite(
            data: Data([9]),
            label: "maneuver",
            transportCanSend: { true },
            transportExpectsWriteResponse: true,
            writeClass: .navigationSnapshot,
            coalescingKey: DeviceBLEProtocol.navigationSnapshotCoalescingKey
        ), prioritized: true), "complete maneuver state enters the priority lane")

        var sent: [Data] = []
        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }, maxWrites: 1) { sent.append($0.data) }
        assertEqual(sent, [Data([9])],
                    "maneuver state is delivered ahead of stalled GPS and route traffic")

        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }) { _ in
            assert(false, "write-without-response backpressure must stop GPS dequeue")
        }
        assert(queue.enqueueCoalescing(gpsWrite(3), prioritized: false),
               "latest GPS replaces the stalled pending value")
        assert(queue.enqueueCoalescing(gpsWrite(4), prioritized: false),
               "another GPS update still leaves only one pending position")

        transportReady = true
        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }) { sent.append($0.data) }
        assertEqual(sent, [Data([9]), Data([40]), Data([41]), Data([4])],
                    "recovery preserves the atomic route and sends only latest GPS state")
        assertEqual(queue.metrics.coalescedFrames(for: .gpsPosition), 3,
                    "GPS replacements are attributed separately in diagnostics")

        var priorityCapacityQueue = NavigationWriteQueue(
            maxCount: 1,
            priorityMaxCount: 6
        )
        assert(priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([20]),
                label: "workout-core",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
            ),
            NavigationWrite(
                data: Data([21]),
                label: "workout-extended",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
            )
        ]), "complete workout pair retains its existing priority transaction")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([22]),
            label: "destination-status",
            writeClass: .transfer,
            coalescingKey: "destination-status"
        ), prioritized: true), "destination status retains its priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([23]),
            label: "maneuver",
            writeClass: .navigationSnapshot,
            coalescingKey: DeviceBLEProtocol.navigationSnapshotCoalescingKey
        ), prioritized: true), "maneuver has a dedicated fourth priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([24]),
            label: "transfer-control",
            writeClass: .transfer,
            coalescingKey: "transfer.map.control"
        ), prioritized: true), "transfer control has a dedicated fifth priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([25]),
            label: "transfer-status",
            writeClass: .transfer,
            coalescingKey: "transfer.device.status"
        ), prioritized: true), "transfer status has a dedicated sixth priority slot")
        assertEqual(priorityCapacityQueue.count, 6,
                    "workout, navigation, and transfer priority traffic coexist")
        assert(!priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([28]),
                label: "issue-marker",
                writeClass: .transfer
            )
        ]), "an unkeyed issue marker cannot evict active priority controls")
        assertEqual(priorityCapacityQueue.count, 6,
                    "a rejected marker preserves every active priority control")
        assert(priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([26]),
                label: "new-workout-core",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
            ),
            NavigationWrite(
                data: Data([27]),
                label: "new-workout-extended",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
            )
        ]), "new workout pair replaces only its prior complete pair")
        var priorityCapacityWrites: [Data] = []
        priorityCapacityQueue.flush(canSend: { true }) {
            priorityCapacityWrites.append($0.data)
        }
        assertEqual(
            priorityCapacityWrites,
            [
                Data([22]), Data([23]), Data([24]), Data([25]),
                Data([26]), Data([27])
            ],
            "workout replacement preserves navigation and transfer priority state"
        )
        assertEqual(
            priorityCapacityQueue.metrics.coalescedFrames(
                for: .workoutTelemetry
            ),
            2,
            "atomic workout replacement is recorded as class coalescing"
        )

        var dropMetricsQueue = NavigationWriteQueue(maxCount: 1)
        dropMetricsQueue.enqueue(NavigationWrite(
            data: Data([30]),
            label: "old-gps",
            writeClass: .gpsPosition
        ))
        assert(dropMetricsQueue.enqueue(NavigationWrite(
            data: Data([31]),
            label: "new-setting",
            writeClass: .settingsControl
        )), "ordinary overflow evicts the oldest packet")
        assertEqual(dropMetricsQueue.metrics.droppedFrames(for: .gpsPosition), 1,
                    "drop metrics attribute capacity eviction to packet class")

        var uptime: TimeInterval = 10
        var ageQueue = NavigationWriteQueue(
            maxCount: 1,
            now: { uptime }
        )
        assert(ageQueue.enqueueCoalescing(gpsWrite(5), prioritized: false),
               "age fixture admits one pending GPS state")
        uptime = 10.25
        ageQueue.noteRetryScheduled()
        uptime = 10.5
        assert(ageQueue.enqueueCoalescing(gpsWrite(6), prioritized: false),
               "coalescing retains the active transport retry interval")
        uptime = 11
        assertEqual(ageQueue.metrics.oldestPendingAgeMs, 500,
                    "oldest age follows the newest pending GPS replacement")
        assertEqual(ageQueue.metrics.retryAgeMs, 750,
                    "retry age survives replacement while backpressure remains active")
    }

    static func testRendererBenchmarkProtocol() {
        let fixtureURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-shanghai-v1.json"
        )
        guard let fixtureData = try? Data(contentsOf: fixtureURL),
              let fixture = try? RendererBenchmarkFixture.decode(fixtureData) else {
            assert(false, "checked-in renderer benchmark fixture decodes")
            return
        }
        assertEqual(fixture.id, "shanghai-jingan-renderer-v1",
                    "renderer benchmark keeps its pinned fixture identity")
        assertEqual(fixture.cadenceHz, 1,
                    "renderer benchmark fixture stays at exactly 1 Hz")
        assertEqual(fixture.points.count, 120,
                    "renderer benchmark fixture retains the full Shanghai loop")
        assertEqual(fixture.points.map(\.latitude).min(), 31.2245400,
                    "renderer benchmark loop stays south of Jing'an Temple")
        assertEqual(fixture.points.map(\.latitude).max(), 31.2258900,
                    "renderer benchmark loop stays north of Jing'an Temple")
        assertEqual(fixture.points.map(\.longitude).min(), 121.4409173,
                    "renderer benchmark loop starts just east of Jing'an Temple")
        assertEqual(fixture.points.map(\.longitude).max(), 121.4436673,
                    "renderer benchmark loop stays in the Jing'an neighborhood")
        assert(
            !RendererBenchmarkCleanupPolicy.requiresCurrentProfileRestore(
                after: .current
            ),
            "an already-current ordinary replay does not queue redundant cleanup"
        )
        for profile in RendererBenchmarkProfile.allCases
            where profile != .current {
            assert(
                RendererBenchmarkCleanupPolicy.requiresCurrentProfileRestore(
                    after: profile
                ),
                "a non-current ordinary replay restores the production profile"
            )
        }
        guard let broadMapBounds = OfflineMapPreviewBounds(coordinates: [
            121.4403621, 31.2158861, 121.4743744, 31.2449696,
        ]),
        let broadCoverage = RendererBenchmarkRouteCoverage(
            fixture: fixture,
            mapBounds: broadMapBounds
        ) else {
            assert(false, "renderer benchmark evaluates valid map coverage")
            return
        }
        assert(broadCoverage.coversEntireRoute,
               "signed benchmark map bounds cover the Jing'an Temple fixture")
        assertEqual(broadCoverage.firstOutsidePointIndex, nil,
                    "covered fixture has no rejected sample")

        guard let narrowMapBounds = OfflineMapPreviewBounds(coordinates: [
            121.4410, 31.2248, 121.4420, 31.2254,
        ]),
        let narrowCoverage = RendererBenchmarkRouteCoverage(
            fixture: fixture,
            mapBounds: narrowMapBounds
        ) else {
            assert(false, "renderer benchmark evaluates narrow map coverage")
            return
        }
        assert(!narrowCoverage.coversEntireRoute,
               "narrow map bounds reject the full Jing'an Temple fixture")
        assertEqual(narrowCoverage.firstOutsidePointIndex, 0,
                    "coverage reports the first rejected fixture sample")
        assertEqual(
            narrowCoverage.failureDescription(mapBounds: narrowMapBounds),
            "The active signed map does not cover the pinned Shanghai route. " +
                "map=[121.4410000,31.2248000,121.4420000,31.2254000] " +
                "route=[121.4409173,31.2245400,121.4436673,31.2258900] " +
                "firstOutside=0:(121.4409173,31.2250400)",
            "coverage failure exposes only bounded map and route coordinates"
        )
        let shortFixture = Data(
            #"{"schema":1,"id":"short","cadenceHz":1,"nominalSpeedMetersPerSecond":4,"points":[{"latitude":31.2,"longitude":121.4},{"latitude":31.2001,"longitude":121.4001}]}"#.utf8
        )
        assert(
            (try? RendererBenchmarkFixture.decode(shortFixture)) == nil,
            "renderer replay rejects fixtures shorter than the declared 60-second window"
        )

        let fixtureHash = Data(SHA256.hash(data: fixtureData))
        assertEqual(
            fixtureHash.map { String(format: "%02x", $0) }.joined(),
            "0fec6228e89cdb6841b971226c5fdedcc5e711dcb9b0e72bcaf95da4f6452f64",
            "fixture edits require an explicit pinned-hash update"
        )
        guard let geometry = RendererBenchmarkRouteGeometry.data(
            fixture: fixture,
            sampleIndex: 119
        ) else {
            assert(false, "renderer benchmark geometry encodes across loop boundary")
            return
        }
        assertEqual(geometry.count, 164,
                    "40 renderer route points use the bounded wire payload")
        assertEqual(
            readInt32LE(geometry, offset: 0),
            Int32(fixture.points[119].latitude * 1_000_000),
            "renderer geometry starts at the selected fixture sample"
        )

        guard let marker = RendererBenchmarkMarkerPacket.data(
            fixtureSHA256: fixtureHash,
            sampleIndex: 119,
            sampleCount: fixture.points.count,
            loop: 0x1234_5678
        ) else {
            assert(false, "valid renderer benchmark marker encodes")
            return
        }
        assertEqual(marker.count, 44, "renderer marker has the firmware frame size")
        assertEqual(String(data: marker.prefix(4), encoding: .utf8), "RBM1",
                    "renderer marker prefix stays firmware-compatible")
        assertEqual(readUInt16LE(marker, offset: 36), 119,
                    "renderer marker carries its sample index")
        assertEqual(readUInt16LE(marker, offset: 38), 120,
                    "renderer marker carries fixture sample count")
        assertEqual(readUInt32LE(marker, offset: 40), 0x1234_5678,
                    "renderer marker carries replay loop")

        let replayGPS = DeviceGPSPacketBuilder.data(
            lat: fixture.points[119].latitude,
            lon: fixture.points[119].longitude,
            heading: 90,
            speedMetersPerSecond: fixture.nominalSpeedMetersPerSecond,
            altitudeMeters: 8,
            distanceTraveledMeters: 119,
            elapsedSeconds: 119,
            routeRemainingMeters: 4,
            horizontalAccuracyMeters: 3,
            locationTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            includeRideDetectionQuality: true
        )
        guard let sample = RendererBenchmarkSamplePacket.data(
            gpsPosition: replayGPS,
            marker: marker
        ) else {
            assert(false, "valid renderer benchmark sample encodes")
            return
        }
        assertEqual(sample.count, 85,
                    "one protected write contains a 36-byte GPS and marker")
        assertEqual(String(data: sample.prefix(4), encoding: .utf8), "RBS1",
                    "atomic renderer sample uses the negotiated prefix")
        assertEqual(sample[4], 36,
                    "atomic renderer sample bounds its GPS member")
        assertEqual(String(data: sample[41..<45], encoding: .utf8), "RBM1",
                    "marker follows GPS in the same transport payload")
        assert(
            RendererBenchmarkSamplePacket.data(
                gpsPosition: Data(repeating: 0, count: 35),
                marker: marker
            ) == nil,
            "non-canonical GPS members fail closed"
        )

        guard let window = RendererBenchmarkWindowPacket.data(
            profile: .medium,
            repeatNumber: 7,
            runNonce: 0x0102_0304_0506_0708,
            fixtureSHA256: fixtureHash,
            fixtureID: fixture.id
        ) else {
            assert(false, "valid ordinary renderer window encodes")
            return
        }
        assertEqual(String(data: window.prefix(4), encoding: .utf8), "RBW1",
                    "ordinary renderer window prefix stays firmware-compatible")
        assertEqual(window[4], 1, "ordinary renderer window carries schema 1")
        assertEqual(window[5], RendererBenchmarkProfile.medium.rawValue,
                    "ordinary renderer window carries the selected profile")
        assertEqual(readUInt16LE(window, offset: 6), 7,
                    "ordinary renderer window carries repeat number")
        assertEqual(Array(window[8..<16]),
                    [8, 7, 6, 5, 4, 3, 2, 1],
                    "ordinary renderer run nonce is little-endian")
        assertEqual(Int(window[48]), fixture.id.utf8.count,
                    "ordinary renderer window bounds its route identity")

        let body = Data(
            #"{"ok":true,"schema":1,"identity":{},"memory":{},"render":{}}"#.utf8
        )
        var reassembler = RendererDiagnosticsChunkReassembler()
        let chunks = stride(from: 0, to: body.count, by: 17).map {
            body.subdata(in: $0..<min($0 + 17, body.count))
        }
        var completedBody: Data?
        for index in chunks.indices.reversed() {
            var frame = Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
            frame.append(9)
            frame.append(UInt8(index))
            frame.append(UInt8(chunks.count))
            frame.append(chunks[index])
            if case let .complete(reassembled)? = reassembler.consume(frame) {
                completedBody = reassembled
            }
        }
        assertEqual(completedBody, body,
                    "out-of-order renderer chunks reassemble deterministically")
        assert(
            RendererDiagnosticsSnapshotEnvelope.normalizedJSONString(body) != nil,
            "shared renderer snapshot envelope validates"
        )
        var interruptedReassembler = RendererDiagnosticsChunkReassembler()
        var firstInterruptedChunk = Data(
            DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8
        )
        firstInterruptedChunk.append(contentsOf: [3, 0, 2])
        firstInterruptedChunk.append(contentsOf: body.prefix(10))
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .pending,
            "a partial renderer snapshot waits for its remaining chunks"
        )
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .rejected,
            "duplicate renderer chunks fail closed and clear partial state"
        )
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .pending,
            "a fresh renderer transfer can start after duplicate rejection"
        )
        assertEqual(
            interruptedReassembler.consume(
                Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
            ),
            .rejected,
            "malformed renderer chunks clear partial state"
        )
        guard let ordinaryCapture = RendererOrdinaryDiagnosticsCapture.json(
            fixtureID: fixture.id,
            fixtureSHA256: fixtureHash,
            snapshots: [String(decoding: body, as: UTF8.self)],
            generatedAt: Date(timeIntervalSince1970: 0)
        ),
              let ordinaryObject = try? JSONSerialization.jsonObject(
                with: Data(ordinaryCapture.utf8)
              ) as? [String: Any],
              let ordinarySnapshots = ordinaryObject["snapshots"] as? [Any]
        else {
            assert(false, "ordinary diagnostics capture exports valid JSON")
            return
        }
        assertEqual(
            ordinaryObject["kind"] as? String,
            "ordinary-renderer-diagnostics",
            "ordinary capture is machine-identifiable"
        )
        assertEqual(ordinarySnapshots.count, 1,
                    "ordinary capture retains validated snapshots")

        let manager = BLEManager()
        var cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8)
        cap2.append(contentsOf: [1, 0, 0, 0x84, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2),
               "renderer diagnostics CAP2 response is consumed")
        assert(manager.supportsRendererDiagnostics,
               "CAP2 bit 18 enables renderer diagnostics")
        assert(manager.supportsRendererBenchmarkSample,
               "CAP2 bit 23 enables atomic renderer replay samples")
        manager.isConnected = true
        manager.isNavigationReady = true
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185,
            canSend: { true },
            write: { writes.append($0) }
        ))
        assert(manager.beginRendererBenchmarkWindow(
            profile: .medium,
            repeatNumber: 7,
            runNonce: 0x0102_0304_0506_0708,
            fixtureSHA256: fixtureHash,
            fixtureID: fixture.id
        ), "BLE manager queues an ordinary renderer benchmark window")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RBW1", "renderer window uses the authenticated navigation fallback")
        assert(manager.sendRendererBenchmarkMarker(
            fixtureSHA256: fixtureHash,
            sampleIndex: 1,
            sampleCount: fixture.points.count,
            loop: 2
        ), "BLE manager queues renderer benchmark markers")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RBM1", "renderer marker uses the authenticated navigation fallback")
        assert(manager.requestRendererDiagnosticsSnapshot(),
               "BLE manager queues an explicit metrics request")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RDMS", "renderer metrics request uses the shared prefix")

        var direct = Data(DeviceBLEProtocol.rendererMetricsResponsePrefix.utf8)
        var partial = Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
        partial.append(contentsOf: [5, 0, 2])
        partial.append(contentsOf: body.prefix(10))
        assert(manager.handleRendererDiagnosticsNotification(partial),
               "BLE manager accepts a partial renderer snapshot")
        direct.append(body)
        assert(manager.handleRendererDiagnosticsNotification(direct),
               "BLE manager consumes direct renderer snapshots")
        assertEqual(manager.rendererDiagnosticsRevision, 1,
                    "valid renderer snapshots advance the observable revision")
        var staleRemainder = Data(
            DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8
        )
        staleRemainder.append(contentsOf: [5, 1, 2])
        staleRemainder.append(contentsOf: body.dropFirst(10))
        assert(manager.handleRendererDiagnosticsNotification(staleRemainder),
               "stale chunk remainder is consumed as a new incomplete stream")
        assertEqual(manager.rendererDiagnosticsRevision, 1,
                    "a newer direct snapshot invalidates older partial chunks")
    }


    static func testRendererBenchmarkAtomicDelivery() {
        // Full-size atomic samples use the same protected native routing as
        // ordinary GPS, including MTU boundaries and legacy compatibility.
        for (withResponse, withoutResponse, acknowledgedLimit, creditLimit, expected) in [
            (true, true, 107, 107, GPSPositionWriteRoute.nativeWithResponse),
            (true, false, 107, 0, .nativeWithResponse),
            (false, true, 0, 107, .nativeWithoutResponse),
            (true, true, 106, 107, .nativeWithoutResponse),
            (true, true, 106, 106, .navigationFallback),
            (false, false, 512, 512, .navigationFallback),
        ] {
            assertEqual(GPSPositionWriteRouting.route(
                hasNativeWriteWithResponse: withResponse,
                hasNativeWriteWithoutResponse: withoutResponse,
                payloadLength: 85, protectionOverhead: 22,
                withResponseMaximum: acknowledgedLimit,
                withoutResponseMaximum: creditLimit
            ), expected, "atomic replay respects native properties and protected MTU")
        }
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        var ready = false
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185,
            expectsWriteResponse: false,
            canSend: { ready },
            write: { writes.append($0) }
        ))
        let hash = Data(repeating: 0x12, count: 32)
        func send(_ index: Int) -> Bool {
            manager.sendRendererBenchmarkSample(
                gpsPosition: Data(repeating: UInt8(index), count: 36),
                fixtureSHA256: hash, sampleIndex: index,
                sampleCount: 120, loop: 0
            )
        }
        assert(!send(0), "atomic replay requires negotiated firmware capability")
        var cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8)
        cap2.append(contentsOf: [1, 0, 0, 0x84, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2),
               "atomic replay capability is consumed")
        assert(!send(0), "atomic replay requires the exclusive GPS lease")
        guard let lease = manager.beginDeviceGPSOverride() else {
            assert(false, "atomic replay acquires GPS lease")
            return
        }
        assert(send(1), "first complete GPS and marker queue together")
        assert(send(2), "latest complete sample replaces a backpressured sample")
        assertEqual(writes.count, 0, "transport credit is respected")
        ready = true
        manager.flushPendingNavigationWritesForTesting()
        assertEqual(writes.count, 1, "only the newest atomic sample is dispatched")
        assertEqual(String(data: writes[0].prefix(4), encoding: .utf8), "RBS1",
                    "native replay preserves atomic framing")
        assertEqual(writes[0][5], 2, "latest GPS is paired with latest marker")
        assertEqual(readUInt16LE(writes[0], offset: 77), 2,
                    "marker index matches its GPS inside the same payload")
        ready = false
        assert(send(3), "another sample can wait for credit")
        manager.endDeviceGPSOverride(lease)
        ready = true
        manager.flushPendingNavigationWritesForTesting()
        assertEqual(writes.filter {
            String(data: $0.prefix(4), encoding: .utf8) == "RBS1"
        }.count, 1, "stop discards pending replay state")
        assert(writes.count > 1, "stop preserves unrelated setup traffic")
        assert(!send(4), "ended lease cannot emit stale replay")

        let acknowledged = BLEManager()
        assert(acknowledged.handleDeviceCapabilitiesNotification(cap2),
               "acknowledged replay negotiates the same atomic capability")
        acknowledged.isConnected = true
        acknowledged.isNavigationReady = true
        var acknowledgedWrites: [Data] = []
        acknowledged.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185, expectsWriteResponse: true,
            canSend: { true }, write: { acknowledgedWrites.append($0) }
        ))
        guard let acknowledgedLease = acknowledged.beginDeviceGPSOverride() else {
            assert(false, "acknowledged replay obtains exclusive GPS lease")
            return
        }
        func sendAcknowledged(_ index: Int) -> Bool {
            acknowledged.sendRendererBenchmarkSample(
                gpsPosition: Data(repeating: UInt8(index), count: 36),
                fixtureSHA256: hash, sampleIndex: index, sampleCount: 120, loop: 0
            )
        }
        assert(sendAcknowledged(1), "acknowledged native replay is supported")
        assert(acknowledged.hasPendingATTWriteForTesting,
               "atomic replay enters the shared ATT response wait")
        assert(sendAcknowledged(2) && sendAcknowledged(3),
               "ticks during ATT wait retain the newest complete sample")
        assertEqual(acknowledgedWrites.count, 1,
                    "no sample bypasses the outstanding ATT response")
        acknowledged.completeNavigationWriteForTesting(error: nil)
        assertEqual(acknowledgedWrites.count, 2,
                    "next sample progresses on ATT completion without a credit callback")
        assertEqual(acknowledgedWrites[1][5], 3,
                    "acknowledged coalescing retains the latest GPS")
        assertEqual(readUInt16LE(acknowledgedWrites[1], offset: 77), 3,
                    "acknowledged coalescing keeps GPS and marker paired")
        assert(sendAcknowledged(4), "a later tick waits behind the second ATT write")
        acknowledged.endDeviceGPSOverride(acknowledgedLease)
        acknowledged.completeNavigationWriteForTesting(error: nil)
        assertEqual(acknowledgedWrites.count, 2,
                    "Stop drops pending samples without replaying completed writes")
        assert(!acknowledged.hasPendingATTWriteForTesting,
               "the final ATT completion releases the writer")
        assert(!sendAcknowledged(5), "stopped acknowledged replay cannot emit")

        var queue = NavigationWriteQueue(maxCount: 8)
        _ = queue.enqueueCoalescing(NavigationWrite(
            data: Data([1]), label: "one", writeClass: .gpsPosition,
            coalescingKey: "sample"
        ), prioritized: false)
        _ = queue.snapshotMetricsAndReset()
        _ = queue.enqueueCoalescing(NavigationWrite(
            data: Data([2]), label: "two", writeClass: .gpsPosition,
            coalescingKey: "sample"
        ), prioritized: false)
        assertEqual(queue.cumulativeMetrics.enqueuedFrames, 2,
                    "benchmark counters survive logging interval reset")
        assertEqual(queue.cumulativeMetrics.coalescedFrames, 1,
                    "cumulative metrics retain coalescing")
        _ = queue.snapshotMetricsAndReset()
        assertEqual(queue.cumulativeMetrics.enqueuedFrames, 2,
                    "repeated snapshots do not double-count")
        assertEqual(queue.cumulativeMetrics.currentDepth, 1,
                    "cumulative queue depth remains a live gauge")
    }

    static func testRouteSnapshotManagerAdmission() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185, expectsWriteResponse: true,
            canSend: { true }, write: { writes.append($0) }
        ))
        assert(manager.enqueueRouteSnapshotForTesting(Data([1])), "first route enters ATT")
        let originalID = manager.rendererBenchmarkBLETransportEvidence().inFlightWriteID
        for index in 2...100 {
            assert(manager.enqueueRouteSnapshotForTesting(Data([UInt8(index)])),
                   "new unsent route replaces obsolete snapshot through real admission")
        }
        let blocked = manager.rendererBenchmarkBLETransportEvidence()
        assertEqual(writes.count, 1, "route replacement cannot bypass ATT wait")
        assertEqual(blocked.inFlightWriteID, originalID, "pending identity unchanged")
        assertEqual(blocked.queueDepth, 1, "manager bounds pending route backlog")
        assertEqual(blocked.routeCoalescedFrames, 98, "manager uses snapshot admission")
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(writes, [Data([1]), Data([100])], "only newest unsent route recovers")
        assert(manager.enqueueRouteSnapshotForTesting(Data()), "empty clear remains admitted")
        assert(manager.enqueueRouteSnapshotForTesting(Data([101])), "route after clear")
        assert(manager.enqueueRouteSnapshotForTesting(Data([102])), "replace only after clear")
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(writes.last, Data(), "clear boundary is not coalesced away")
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(writes.last, Data([102]), "latest route follows clear")
        manager.completeNavigationWriteForTesting(error: nil)
        assert(!manager.hasPendingATTWriteForTesting, "writer drains normally")
    }

    static func testATTWriteSubmissionEvidence() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185, expectsWriteResponse: true,
            canSend: { true }, write: { _ in }
        ))
        assert(manager.requestDeviceCapabilities(), "diagnostic test queues an ATT write")
        let prepared = manager.rendererBenchmarkBLETransportEvidence()
        guard let writeID = prepared.inFlightWriteID else {
            assert(false, "ATT preparation assigns a correlation ID")
            return
        }
        assertEqual(prepared.inFlightSubmissionStage, .prepared,
                    "dequeuing is not proof of CoreBluetooth submission")
        manager.noteATTWriteSubmissionForTesting(
            writeID: writeID, stage: .submitted, matchingCharacteristic: false
        )
        assertEqual(manager.rendererBenchmarkBLETransportEvidence().inFlightSubmissionStage,
                    .prepared, "a different characteristic cannot tag this write")
        manager.noteATTWriteSubmissionForTesting(writeID: writeID, stage: .callingCoreBluetooth)
        assertEqual(manager.rendererBenchmarkBLETransportEvidence().inFlightSubmissionStage,
                    .callingCoreBluetooth, "API entry is distinct from return")
        manager.noteATTWriteSubmissionForTesting(writeID: writeID, stage: .submitted)
        manager.timeoutATTWriteForTesting()
        let timedOut = manager.rendererBenchmarkBLETransportEvidence()
        assert(timedOut.inFlightWriteID == nil && timedOut.lastTimedOutWriteID == writeID,
               "timeout evidence survives clearing the pending write")
        assertEqual(timedOut.lastTimedOutSubmissionStage, .submitted,
                    "timeout records that CoreBluetooth returned without an ACK")
        let timing = timedOut.lastWriteTiming!
        assertEqual(timing.writeID, writeID, "timing uses the real pending ATT identity")
        assert(timing.apiEntryAtUptimeMs != nil && timing.apiReturnAtUptimeMs != nil,
               "actual manager stage transitions retain API timestamps")
        assert(timing.delegateEntryAtUptimeMs == nil,
               "timeout does not invent a delegate callback")
        assertEqual(timing.outcome, "timeout", "timing retains completion reason")
        assert(timedOut.slowestWriteTiming != nil, "tail evidence survives pending-slot removal")
        assert(manager.requestDeviceCapabilities(), "next ATT write starts independently")
        manager.noteATTWriteSubmissionForTesting(writeID: writeID, stage: .submitted)
        assertEqual(manager.rendererBenchmarkBLETransportEvidence().inFlightSubmissionStage,
                    .prepared, "a delayed return cannot mark a successor write submitted")
        manager.ignoreATTWriteCallbackForTesting()
        let next = manager.rendererBenchmarkBLETransportEvidence()
        assertEqual(next.ignoredWriteCallbacks, 1, "unmatched callbacks are counted")
        assertEqual(next.lastTimedOutSubmissionStage, .submitted,
                    "new activity preserves the last timeout evidence")
        guard let nextID = next.inFlightWriteID else { return }
        manager.noteATTWriteSubmissionForTesting(writeID: nextID, stage: .rejectedBeforeSubmission)
        manager.timeoutATTWriteForTesting()
        let rejected = manager.rendererBenchmarkBLETransportEvidence()
        assertEqual(rejected.lastTimedOutSubmissionStage, .rejectedBeforeSubmission,
                    "a local preparation failure is distinguishable from a missing ACK")
        guard let encoded = try? JSONEncoder().encode(rejected),
              var legacy = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { assert(false, "submission evidence encodes"); return }
        assert(RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(jsonData: encoded),
               "submission evidence contains no credentials or packet contents")
        for key in ["inFlightWriteID", "inFlightSubmissionStage", "lastTimedOutWriteID",
                    "lastTimedOutSubmissionStage", "ignoredWriteCallbacks",
                    "lastWriteTiming", "slowestWriteTiming"] {
            legacy.removeValue(forKey: key)
        }
        let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
        let decoded = try! JSONDecoder().decode(RendererBenchmarkBLETransportEvidence.self,
                                                from: legacyData)
        assert(decoded.lastTimedOutSubmissionStage == nil && decoded.ignoredWriteCallbacks == nil,
               "legacy evidence remains unknown rather than inventing submission state")
        assert(decoded.lastWriteTiming == nil && decoded.slowestWriteTiming == nil,
               "older app traces need no new timing fields")
        for key in ["attemptId", "connectionGeneration", "class", "bytes", "phase", "reason", "kind"] {
            assert(RideDiagnosticsFieldPolicy.isAllowed(key),
                   "submission trace metadata survives the recorder privacy filter")
        }
    }

    static func testNavigationDrainIncludesAcknowledgement() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            expectsWriteResponse: true,
            canSend: { true },
            write: { _ in }
        ))
        assert(manager.requestDeviceCapabilities(), "setup request queues")
        assert(manager.navigationHasUnsettledWritesForTesting,
               "drain must include the outstanding ATT acknowledgement")
        manager.completeNavigationWriteForTesting(error: nil)
        assert(!manager.navigationHasUnsettledWritesForTesting,
               "setup settles only after its acknowledgement")
    }

    static func testDeviceNetworkJoinTimeoutPolicy() {
        let transferManagerURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift"
        )
        guard let transferManagerSource = try? String(
            contentsOf: transferManagerURL,
            encoding: .utf8
        ), let remoteEntryStart = transferManagerSource.range(
            of: "func enterRemoteDebug("
        )?.lowerBound,
        let remoteWaitStart = transferManagerSource.range(
            of: "private func waitForRemoteDebugSession(",
            range: remoteEntryStart..<transferManagerSource.endIndex
        )?.lowerBound else {
            assert(false, "remote-debug transfer source should be available")
            return
        }
        let remoteEntrySource = String(
            transferManagerSource[remoteEntryStart..<remoteWaitStart]
        )
        assert(
            remoteEntrySource.contains("try await joinDeviceNetworkIfNeeded(") &&
                remoteEntrySource.contains(
                    "statusPath: \"device-debug/v1/info\""
                ),
            "hotspot remote debugging joins and probes the pinned device endpoint"
        )
        assert(
            DeviceNetworkJoinPolicy.configurationApplyTimeout >= 45 &&
                DeviceNetworkJoinPolicy.configurationApplyTimeout <= 60,
            "the system hotspot prompt allows foreground confirmation before firmware inactivity"
        )
        assert(
            DeviceNetworkJoinPolicy.currentNetworkFetchTimeout > 0 &&
                DeviceNetworkJoinPolicy.currentNetworkFetchTimeout <= 3,
            "current-network inspection cannot stall accessory association"
        )
        assert(
            !DeviceNetworkJoinPolicy.shouldRetry(
                domain: DeviceNetworkJoinPolicy.joinErrorDomain,
                code: DeviceNetworkJoinPolicy.configurationApplyTimeoutCode
            ),
            "an unresolved system apply cannot overlap a second apply"
        )
        let applyTimeout =
            DeviceNetworkJoinPolicy.configurationApplyTimeoutError
        assertEqual(
            applyTimeout.domain,
            DeviceNetworkJoinPolicy.joinErrorDomain,
            "the bounded apply failure retains its typed diagnostic domain"
        )
        assertEqual(
            applyTimeout.code,
            DeviceNetworkJoinPolicy.configurationApplyTimeoutCode,
            "the bounded apply failure retains its typed diagnostic code"
        )
    }

    static func testRendererCrossRunRetainedMemoryPolicy() {
        assert(
            RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 44_500, 43_000],
                allowedDecline: 1_024
            ),
            "progressive retained DMA decline is rejected"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 44_000, 43_990],
                allowedDecline: 1_024
            ),
            "one-time transition followed by a plateau is accepted"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [46_000, 45_920, 46_010],
                allowedDecline: 1_024
            ),
            "stable retained memory with jitter is accepted"
        )
        assert(
            !RendererBenchmarkEvaluator.progressiveCrossRunDecline(
                [39_307, 37_803, 37_779],
                allowedDecline: 1_024
            ),
            "the physical three-point minimum series is not progressive"
        )

        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Utilities/SecureRendererBenchmarkProtocol.swift"
        )
        guard let source = try? String(
            contentsOf: sourceURL,
            encoding: .utf8
        ), let start = source.range(
            of: "    static func applyCrossRunMemoryGates("
        ), let end = source.range(
            of: "    static func aggregate(",
            range: start.upperBound..<source.endIndex
        ) else {
            assert(false, "cross-run memory source contract is readable")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        assert(
            body.contains("finalSnapshot.memory.dmaHeap.free") &&
                body.contains("finalSnapshot.memory.dmaHeap.largestBlock"),
            "cross-run DMA gates use terminal current state"
        )
        assert(
            !body.contains(".summary.minimumDmaFree") &&
                !body.contains(".summary.minimumDmaLargest"),
            "heterogeneous window minima are not treated as retained state"
        )
    }

    static func testSecureRendererBenchmarkProtocol() {
        let cameraHeader = "1,1,7,3,100,120,20,-900,-910,3590,600,1,1,2,1,0,1,1"
        let camera = RendererCameraEvidence.frameHeader(cameraHeader)
        assertEqual(camera?.frameSequence, 7, "captured frame keeps camera identity")
        assertEqual(camera?.displayedBearingTenths, -900, "camera uses signed bearing")
        assertEqual(camera?.markerAngleTenths, 3590, "camera keeps residual marker angle")
        assertEqual(RendererCameraEvidence.frameHeader("1,1"), nil, "truncated camera header fails closed")
        assertEqual(RendererCameraEvidence.frameHeader(cameraHeader + ",0"), nil, "extra camera field fails closed")
        assertEqual(RendererCameraEvidence.frameHeader(cameraHeader.replacingOccurrences(of: "3590", with: "3600")), nil, "camera angle range is validated")
        if let camera {
            do {
                let roundTrip = try JSONDecoder().decode(RendererCameraEvidence.self,
                    from: JSONEncoder().encode(camera))
                assertEqual(roundTrip, camera, "camera evidence survives export")
            } catch { fatalError("camera evidence round trip failed: \(error)") }
        }
        // Additive timing fields must survive evidence export while older
        // schema-1 snapshots remain readable.
        let callback: [String: Any] = [
            "session": 3, "ordinal": 694, "channel": 2, "startedAtMs": 100,
            "callbackUs": 120, "setupUs": 1, "authenticationUs": 80,
            "allocationUs": 1, "mailboxWaitUs": 1, "mailboxHoldUs": 1,
            "authenticated": true, "mailboxAccepted": true,
            "frameActiveAtEntry": false, "frameActiveAtExit": false
        ]
        let owner: [String: Any] = [
            "session": 3, "ordinal": 694, "channel": 2, "startedAtMs": 100,
            "mailboxAgeUs": 10, "processingUs": 20
        ]
        var timing: [String: Any] = [
            "schema": 1, "session": 3, "completed": 694,
            "latest": callback, "slowestRoute": callback,
            "slowestGps": callback, "latestOwner": owner, "slowestOwner": owner
        ]
        do {
            let old = try JSONDecoder().decode(RendererDeliveryTimingEvidence.self,
                from: JSONSerialization.data(withJSONObject: timing))
            assert(old.latestStarted == nil && old.started == nil,
                   "old timing evidence does not fabricate callback entry proof")
            timing["started"] = 695
            timing["latestStarted"] = [
                "session": 3, "ordinal": 695, "channel": 2,
                "startedAtMs": 200, "updatedAtMs": 201,
                "phase": "waiting_for_mailbox"
            ]
            let updated = try JSONDecoder().decode(RendererDeliveryTimingEvidence.self,
                from: JSONSerialization.data(withJSONObject: timing))
            assertEqual(updated.latestStarted?.ordinal, 695,
                        "incomplete callback remains distinct from latest completed callback")
            assertEqual(updated.latestStarted?.phase, "waiting_for_mailbox",
                        "callback progress is retained")
            let exported = try JSONDecoder().decode(RendererDeliveryTimingEvidence.self,
                from: JSONEncoder().encode(updated))
            assertEqual(exported, updated, "entry evidence survives export round trip")
        } catch {
            assert(false, "delivery timing compatibility: \(error)")
        }
        assertEqual(
            SecureRendererBenchmarkHTTPPolicy.connectionReuseHeaderName,
            "X-BikeComputer-Connection-Reuse",
            "the serial sweep uses the firmware connection-reuse contract"
        )
        assertEqual(
            SecureRendererBenchmarkHTTPPolicy.connectionReuseHeaderValue,
            "1",
            "the serial sweep explicitly opts into connection reuse"
        )
        assertEqual(
            SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout,
            5,
            "control and metrics requests retain the tight five-second bound"
        )
        assertEqual(
            SecureRendererBenchmarkHTTPPolicy.frameRequestTimeout,
            12,
            "large pinned frame bodies receive physical tail headroom"
        )
        assert(
            SecureRendererBenchmarkHTTPPolicy.frameRequestTimeout > 8,
            "the frame deadline exceeds the failed physical deadline"
        )
        assert(
            SecureRendererBenchmarkHTTPPolicy.metricsRecoveryTimeout >
                SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout * 2,
            "metrics recovery permits a fresh pinned-session retry"
        )
        assert(
            SecureRendererBenchmarkHTTPPolicy.screenshotRecoveryTimeout >
                SecureRendererBenchmarkHTTPPolicy.frameRequestTimeout,
            "checkpoint capture can retry after renewing its pinned session"
        )
        assert(
            SecureRendererBenchmarkHTTPPolicy.cleanupRecoveryTimeout >
                SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout * 2,
            "Current cleanup can recover after a poisoned persistent socket"
        )
        assertEqual(
            SecureRendererBenchmarkHTTPPolicy.resourceTimeout,
            20,
            "the session resource ceiling remains bounded above the frame deadline"
        )
        var reuseRequest = URLRequest(url: URL(string: "https://device.invalid")!)
        SecureRendererBenchmarkHTTPPolicy.enableConnectionReuse(
            on: &reuseRequest
        )
        assertEqual(
            reuseRequest.value(forHTTPHeaderField:
                SecureRendererBenchmarkHTTPPolicy.connectionReuseHeaderName),
            "1",
            "the secure sweep request carries only the non-secret reuse marker"
        )
        let appGatesURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-gates-v1.json"
        )
        let firmwareGatesURL = URL(fileURLWithPath:
            "esp32/tools/renderer_benchmark_gates.json"
        )
        guard let appGatesData = try? Data(contentsOf: appGatesURL),
              let firmwareGatesData = try? Data(contentsOf: firmwareGatesURL),
              let gates = try? RendererBenchmarkGates.decode(appGatesData) else {
            assert(false, "secure renderer benchmark gates decode")
            return
        }
        assertEqual(
            appGatesData,
            firmwareGatesData,
            "the in-app sweep uses the exact firmware benchmark gate contract"
        )
        assertEqual(gates.schema, 1, "secure benchmark gates retain schema 1")
        assertEqual(gates.absolute.maximumCoverageRejectedRenders, 4,
                    "temporary coverage allowance remains explicit until issue 402 is resolved")
        assertEqual(gates.absolute.maximumStaleRenders, 3,
                    "temporary coverage allowance does not relax the independent stale gate")
        assertEqual(
            gates.absolute.minimumMetricsSampleFraction,
            0.3,
            "secure benchmark sampling reflects serialized pinned HTTPS frames"
        )

        let mapFixture = RendererBenchmarkMapFixtureIdentity(
            id: "shanghai-map",
            sha256: String(repeating: "a", count: 64)
        )
        let routeFixture = RendererBenchmarkRouteFixtureIdentity(
            id: "shanghai-jingan-renderer-v1",
            sha256: String(repeating: "b", count: 64),
            mode: "ios-fixture-1hz"
        )
        guard let windowRequestData = try?
                RendererBenchmarkWindowWireContract.requestData(
                    profile: "current",
                    runId: "test-run",
                    repeatNumber: 2,
                    mapFixture: mapFixture,
                    routeFixture: routeFixture
                ),
              let windowRequest = try? JSONSerialization.jsonObject(
                with: windowRequestData
              ) as? [String: Any],
              let encodedMapFixture = windowRequest["mapFixture"]
                as? [String: Any],
              let encodedRouteFixture = windowRequest["routeFixture"]
                as? [String: Any] else {
            assert(false, "secure benchmark encodes the renderer-window request")
            return
        }
        assertEqual(
            windowRequest.keys.sorted(),
            [
                "mapFixture", "profile", "repeat", "routeFixture",
                "routeMode", "runId", "schema",
            ],
            "renderer-window request has exactly the firmware top-level fields"
        )
        assertEqual(
            encodedMapFixture.keys.sorted(),
            ["id", "sha256"],
            "renderer-window map identity has exactly two fields"
        )
        assertEqual(
            encodedRouteFixture.keys.sorted(),
            ["id", "sha256"],
            "renderer-window route identity excludes the evidence-only mode field"
        )
        assertEqual(
            windowRequest["routeMode"] as? String,
            routeFixture.mode,
            "renderer-window route mode remains a top-level firmware field"
        )
        assertEqual(
            windowRequest["repeat"] as? Int,
            2,
            "renderer-window repeat uses the firmware field name"
        )
        assertEqual(
            RendererBenchmarkWindowWireContract.acceptedStatusCode,
            202,
            "renderer-window requests accept the firmware asynchronous status"
        )
        assertEqual(
            RendererBenchmarkWindowWireContract.requestID(
                from: Data(#"{"ok":true,"requestId":17}"#.utf8)
            ),
            17,
            "renderer-window response decodes the firmware 202 body"
        )
        assert(
            RendererBenchmarkWindowWireContract.requestID(
                from: Data(#"{"ok":true,"requestId":0}"#.utf8)
            ) == nil,
            "renderer-window response rejects request ID zero"
        )
        assert(
            RendererBenchmarkWindowWireContract.requestID(
                from: Data(#"{"ok":false,"requestId":17}"#.utf8)
            ) == nil,
            "renderer-window response rejects a negative acknowledgement"
        )
        assert(
            RendererBenchmarkWindowWireContract.requestID(
                from: Data(#"{"ok":true}"#.utf8)
            ) == nil,
            "renderer-window response rejects a missing request ID"
        )

        let schedule = SecureRendererBenchmarkPlan.balancedSchedule().map {
            $0.map(\.wireName)
        }
        assertEqual(
            schedule,
            [
                ["flat", "current", "high", "medium"],
                ["current", "medium", "flat", "high"],
                ["medium", "high", "current", "flat"],
            ],
            "secure benchmark reproduces the balanced firmware-tool schedule"
        )
        assertEqual(
            SecureRendererBenchmarkPlan.checkpointIndexes(
                sampleCount: 120,
                fractions: gates.checkpointFractions
            ),
            [0, 30, 60, 90],
            "secure benchmark captures the four route checkpoints"
        )
        assertEqual(
            RendererBenchmarkProfile.allCases.map(\.expectedTuningFingerprint),
            [
                10_406_861_497_667_589_141,
                8_401_707_559_015_286_048,
                12_673_537_785_575_117_931,
                7_901_381_679_465_817_306,
            ],
            "secure benchmark pins the firmware tuning fingerprints"
        )

        let metricsURL = URL(fileURLWithPath:
            "ios-app/BikeComputerTests/Fixtures/renderer-metrics-v1.json"
        )
        guard let metricsData = try? Data(contentsOf: metricsURL),
              let metrics = try? JSONDecoder().decode(
                RendererBenchmarkMetricsSnapshot.self,
                from: metricsData
              ) else {
            assert(false, "secure benchmark decodes the firmware metrics contract")
            return
        }
        let sample = RendererBenchmarkEvaluator.sample(
            snapshot: metrics,
            elapsedSeconds: 42
        )
        assertEqual(metrics.remoteDebug.lastFrameSnapshotWaitUs, 110,
                    "secure benchmark retains frame snapshot wait evidence")
        assertEqual(metrics.replayTransport?.markerRejectedNoActiveWindow, 221,
                    "export retains the missing-window diagnostic counter")
        assertEqual(metrics.memory.dmaHeap.windowMinimumFreeAttribution?.frameTransferActive, true,
                    "export retains DMA minimum attribution")
        let interrupted = RendererBenchmarkInterruptedEvidence(
            schema: 1, source: "bicino-debug-secure-sweep-interrupted-v1",
            automatedPassed: false, stopped: true, reason: "Stopped",
            cleanupRestoredCurrent: true, completedRuns: [],
            partialSamples: [], lastSnapshot: metrics
        )
        let interruptedData = try! JSONEncoder().encode(interrupted)
        let interruptedObject = try! JSONSerialization.jsonObject(
            with: interruptedData
        ) as! [String: Any]
        assertEqual(interruptedObject["automatedPassed"] as? Bool, false,
                    "partial evidence cannot claim a completed passing run")
        assert(RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
            jsonData: interruptedData
        ), "partial evidence uses the same secret-free export policy")
        assertEqual(metrics.remoteDebug.lastHttpActualBytes, 434_344,
                    "secure benchmark retains actual response body bytes")
        assertEqual(metrics.remoteDebug.lastHttpZeroWriteCalls, 4,
                    "secure benchmark retains TLS zero-write evidence")
        assertEqual(metrics.remoteDebug.lastHttpActiveTlsWriteUs, 500_000,
                    "secure benchmark retains active TLS-write time")
        guard let summary = RendererBenchmarkEvaluator.summary(
            snapshots: [metrics],
            samples: [sample]
        ) else {
            assert(false, "secure benchmark summarizes a metrics window")
            return
        }
        assertEqual(
            summary.minimumDmaFree,
            20_000,
            "secure benchmark retains the firmware DMA minimum"
        )
        for (coverage, stale) in [(3, 3), (4, 0), (5, 0), (4, 4)] {
            guard let summaryData = try? JSONEncoder().encode(summary),
                  var object = try? JSONSerialization.jsonObject(with: summaryData)
                    as? [String: Any] else {
                assert(false, "coverage boundary fixture encodes")
                return
            }
            object["coverageRejectedRenders"] = coverage
            object["staleRenders"] = stale
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let boundarySummary = try? JSONDecoder().decode(
                    RendererBenchmarkRunSummary.self, from: data
                  ) else {
                assert(false, "coverage boundary fixture decodes")
                return
            }
            let failures = RendererBenchmarkEvaluator.evaluate(
                snapshots: [metrics], samples: [sample], summary: boundarySummary,
                durationSeconds: 1, screenshotCount: 0, checkpointCount: 0,
                expectedRouteSampleCount: 120, gates: gates
            )
            assertEqual(
                failures.filter { $0.hasPrefix("coverage_rejections:") },
                coverage > 4 ? ["coverage_rejections:5"] : [],
                "coverage allowance accepts four but rejects five"
            )
            assertEqual(
                failures.filter { $0.hasPrefix("stale_renders:") },
                stale > 3 ? ["stale_renders:4"] : [],
                "stale render gate remains independent of coverage allowance"
            )
        }
        assertEqual(
            summary.cryptoHeadroomRejections,
            0,
            "secure benchmark retains the zero crypto-rejection gate"
        )
        assertEqual(
            summary.cryptoOperationFailures,
            0,
            "secure benchmark retains the zero crypto-failure gate"
        )
        guard var diagnosticMetricsObject = try? JSONSerialization.jsonObject(
            with: metricsData
        ) as? [String: Any] else {
            assert(false, "secure benchmark creates diagnostic metrics fixture")
            return
        }
        diagnosticMetricsObject["replayTransport"] = [
            "gpsAuthenticationAccepted": 5,
            "gpsAuthenticationRejected": 1,
            "rbs1Detected": 4,
            "rbs1Decoded": 3,
            "rbs1Malformed": 1,
            "rbs1Unnegotiated": 0,
            "gpsMailboxAccepted": 3,
            "gpsMailboxRejected": 0,
            "markerAccepted": 2,
            "markerRejectedInvalid": 0,
            "markerRejectedNoActiveWindow": 1,
            "markerRejectedActiveFixtureUnavailable": 0,
            "markerRejectedFixtureMismatch": 0,
            "lastTransportEventAtMs": 12_345,
            "lastMarkerAtMs": 12_344,
            "lastActiveWindowId": 41,
            "lastSampleIndex": 12,
            "lastSampleCount": 120,
            "lastLoop": 2,
            "lastCandidateFixtureTag": 0x0fec_6228,
            "lastCandidateFixtureTagValid": true,
            "lastExpectedFixtureTag": 0x0fec_6228,
            "lastExpectedFixtureTagValid": true,
            "lastMarkerResult": "accepted",
        ] as [String: Any]
        if var memory = diagnosticMetricsObject["memory"] as? [String: Any],
           var dmaHeap = memory["dmaHeap"] as? [String: Any] {
            dmaHeap["windowMinimumFreeAttribution"] = [
                "phase": "render_complete",
                "observedAtMs": 12_300,
                "value": 20_000,
                "frameTransferActive": true,
            ] as [String: Any]
            dmaHeap["windowMinimumLargestBlockAttribution"] = [
                "phase": "metrics_snapshot",
                "observedAtMs": 12_345,
                "value": 10_000,
                "frameTransferActive": false,
            ] as [String: Any]
            memory["dmaHeap"] = dmaHeap
            diagnosticMetricsObject["memory"] = memory
        }
        guard let diagnosticMetricsData = try? JSONSerialization.data(
            withJSONObject: diagnosticMetricsObject
        ), let diagnosticMetrics = try? JSONDecoder().decode(
            RendererBenchmarkMetricsSnapshot.self,
            from: diagnosticMetricsData
        ), let replayTransport = diagnosticMetrics.replayTransport,
              let roundTripData = try? JSONEncoder().encode(diagnosticMetrics),
              let roundTripObject = try? JSONSerialization.jsonObject(
                with: roundTripData
              ) as? [String: Any],
              roundTripObject["replayTransport"] != nil else {
            assert(false, "replay transport diagnostics survive evidence decoding and encoding")
            return
        }
        assertEqual(
            replayTransport.markerRejectedNoActiveWindow,
            1,
            "pre-window replay rejection remains available to exported evidence"
        )
        assertEqual(
            replayTransport.lastMarkerResult,
            "accepted",
            "the last firmware admission result survives the evidence round trip"
        )
        assertEqual(
            diagnosticMetrics.memory.dmaHeap
                .windowMinimumFreeAttribution?.phase,
            "render_complete",
            "DMA low-water phase attribution survives evidence decoding"
        )
        assertEqual(
            diagnosticMetrics.memory.dmaHeap
                .windowMinimumFreeAttribution?.frameTransferActive,
            true,
            "DMA attribution retains only the non-secret frame-overlap bit"
        )
        let baseline = RendererBenchmarkEvidenceIdentity(
            deviceId: metrics.identity.deviceId,
            firmwareCommit: metrics.identity.firmwareCommit,
            firmwareVersion: "test",
            firmwareBuild: 1,
            board: metrics.identity.board,
            buildProfile: metrics.identity.buildProfile,
            storageBackend: "sdmmc",
            storagePowerCycleRequired: false,
            bootId: metrics.identity.bootId,
            resetReason: metrics.identity.resetReason
        )
        assertEqual(
            RendererBenchmarkEvaluator.identityFailures(
                snapshot: metrics,
                baseline: baseline,
                profile: .medium,
                runId: metrics.window.runId,
                repeatNumber: metrics.window.repeatNumber,
                mapFixture: metrics.identity.mapFixture,
                routeFixture: metrics.identity.routeFixture,
                windowId: metrics.window.id
            ),
            [],
            "secure benchmark accepts an exact window/build/fixture identity"
        )
        if var legacyMetricsObject = try? JSONSerialization.jsonObject(
            with: metricsData
        ) as? [String: Any],
           var memory = legacyMetricsObject["memory"] as? [String: Any],
           var dmaHeap = memory["dmaHeap"] as? [String: Any] {
            dmaHeap.removeValue(forKey: "cryptoCountersScope")
            memory["dmaHeap"] = dmaHeap
            legacyMetricsObject["memory"] = memory
            if let legacyMetricsData = try? JSONSerialization.data(
                withJSONObject: legacyMetricsObject
            ),
               let legacyMetrics = try? JSONDecoder().decode(
                RendererBenchmarkMetricsSnapshot.self,
                from: legacyMetricsData
               ) {
                assertEqual(
                    RendererBenchmarkEvaluator.identityFailures(
                        snapshot: legacyMetrics,
                        baseline: baseline,
                        profile: .medium,
                        runId: legacyMetrics.window.runId,
                        repeatNumber: legacyMetrics.window.repeatNumber,
                        mapFixture: legacyMetrics.identity.mapFixture,
                        routeFixture: legacyMetrics.identity.routeFixture,
                        windowId: legacyMetrics.window.id
                    ),
                    ["stale_identity:crypto_counter_scope"],
                    "secure benchmark reports old cumulative crypto counters"
                )
            } else {
                assert(false, "secure benchmark decodes the legacy crypto-counter shape")
            }
        } else {
            assert(false, "secure benchmark constructs a legacy crypto-counter fixture")
        }

        let pixels = Data([0x00, 0xf8, 0xe0, 0x07])
        var frame = Data("BCF1".utf8)
        appendUInt16LE(32, to: &frame)
        appendUInt16LE(0, to: &frame)
        appendUInt32LE(7, to: &frame)
        appendUInt32LE(9, to: &frame)
        appendUInt16LE(2, to: &frame)
        appendUInt16LE(1, to: &frame)
        appendUInt16LE(4, to: &frame)
        frame.append(contentsOf: [1, 0])
        appendUInt32LE(UInt32(pixels.count), to: &frame)
        appendUInt32LE(RendererBenchmarkFrameDecoder.crc32(pixels), to: &frame)
        frame.append(pixels)
        guard let decoded = try? RendererBenchmarkFrameDecoder.decode(
            frame,
            expectedPanelWidth: 2,
            expectedPanelHeight: 1,
            rotationQuarters: 1
        ) else {
            assert(false, "secure benchmark frame decoder accepts valid RGB565")
            return
        }
        assertEqual(decoded.sequence, 7, "decoded frame retains its sequence")
        assertEqual(decoded.width, 1, "quarter-turn frame width is rotated")
        assertEqual(decoded.height, 2, "quarter-turn frame height is rotated")
        assertEqual(
            Array(decoded.rgba),
            [0, 255, 0, 255, 255, 0, 0, 255],
            "RGB565 frames are rotated and converted to RGBA deterministically"
        )
        assertEqual(
            RendererBenchmarkCheckpointFramePolicy.decision(
                capturedAtMs: 1_005,
                markerReceivedAtMs: 1_000,
                maximumAgeMs: 2_500
            ),
            .accept(lagMs: 5),
            "the first timestamp-bound checkpoint frame is accepted"
        )
        assertEqual(
            RendererBenchmarkCheckpointFramePolicy.decision(
                capturedAtMs: 999,
                markerReceivedAtMs: 1_000,
                maximumAgeMs: 2_500
            ),
            .beforeMarker,
            "a cached frame from before the marker is consumed but rejected"
        )
        assertEqual(
            RendererBenchmarkCheckpointFramePolicy.decision(
                capturedAtMs: 3_501,
                markerReceivedAtMs: 1_000,
                maximumAgeMs: 2_500
            ),
            .tooLate(lagMs: 2_501),
            "a checkpoint frame outside the marker-age gate is rejected"
        )
        var corruptFrame = frame
        corruptFrame[corruptFrame.count - 1] ^= 0xff
        assert(
            (try? RendererBenchmarkFrameDecoder.decode(
                corruptFrame,
                expectedPanelWidth: 2,
                expectedPanelHeight: 1,
                rotationQuarters: 1
            )) == nil,
            "secure benchmark rejects a corrupt screenshot frame"
        )

        assert(
            RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
                jsonData: Data(#"{"deviceId":"abc","passed":true}"#.utf8)
            ),
            "non-secret benchmark evidence is exportable"
        )
        let transportEvidence = RendererBenchmarkBLETransportEvidence(
            schema: 1,
            capturedAtUptimeMs: 12_345,
            queueDepth: 2,
            queueMaximumDepth: 7,
            oldestPendingAgeMs: 1_200,
            retryAgeMs: 800,
            enqueuedFrames: 100,
            flushedFrames: 90,
            droppedFrames: 0,
            rejectedFrames: 1,
            coalescedFrames: 9,
            retrySchedules: 3,
            backpressureStops: 4,
            gpsCoalescedFrames: 6,
            routeCoalescedFrames: 2,
            settingsCoalescedFrames: 1,
            inFlightClass: NavigationWriteClass.gpsPosition.rawValue,
            inFlightAgeMs: 1_500,
            acknowledgementCompletions: 89,
            acknowledgementErrors: 1,
            acknowledgementTimeouts: 0,
            lastAcknowledgementMs: 40,
            maximumAcknowledgementMs: 1_700
        )
        guard let transportEvidenceData = try? JSONEncoder().encode(
            transportEvidence
        ) else {
            assert(false, "BLE transport evidence encodes")
            return
        }
        assert(
            RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
                jsonData: transportEvidenceData
            ),
            "BLE queue and acknowledgement evidence contains no secret fields"
        )
        let legacyTimingJSON = Data(#"{"schema":1,"emittedSamples":1,"timerCallbacks":0,"lastTimerLatenessMs":0,"maximumTimerLatenessMs":0}"#.utf8)
        guard var timing = try? JSONDecoder().decode(
            RendererBenchmarkReplayTimingEvidence.self, from: legacyTimingJSON
        ) else {
            assert(false, "legacy replay timing evidence decodes")
            return
        }
        assert(timing.schedulerActive == nil,
               "older evidence does not invent a scheduler state")
        timing.schedulerActive = true
        var startupTrace = RendererBenchmarkStartupTrace()
        startupTrace.recordNetworkTransport("hotspot")
        assertEqual(startupTrace.networkTransport, "hotspot", "record network mode, not network identity")
        startupTrace.recordNetworkTransport("private-network-name")
        assert(startupTrace.networkTransport == nil, "unknown transport cannot export an SSID or URL")
        startupTrace.recordNetworkTransport("lan")
        for index in 0..<(RendererBenchmarkStartupTrace.maximumSamples + 3) {
            let startupSample = RendererBenchmarkStartupSample(
                phase: "metrics_\(index)",
                bleTransport: transportEvidence,
                replayTiming: timing,
                window: metrics.window,
                routeReplay: metrics.routeReplay,
                replayTransport: metrics.replayTransport,
                renderCount: metrics.render.jobs.completed,
                psramFree: metrics.memory.psram.free,
                psramLargest: metrics.memory.psram.largestBlock
            )
            startupTrace.record(startupSample)
            startupTrace.recordWarmupBoundary(startupSample)
        }
        assert(startupTrace.samples.count == 128 && startupTrace.droppedSamples == 3,
               "startup trace remains bounded and counts discarded samples")
        assert(startupTrace.samples.first?.phase == "metrics_3" &&
               startupTrace.samples.last?.phase == "metrics_130",
               "startup trace retains the latest failure context")
        assert(startupTrace.warmupBoundaries?.count == 32 &&
               startupTrace.warmupBoundaries?.first?.phase == "metrics_0",
               "bounded warm-up evidence survives failure-ring eviction")
        guard let traceData = try? JSONEncoder().encode(startupTrace),
              let decodedTrace = try? JSONDecoder().decode(
                RendererBenchmarkStartupTrace.self, from: traceData
              ) else {
            assert(false, "startup trace round trips")
            return
        }
        assert(decodedTrace.samples == startupTrace.samples &&
               decodedTrace.droppedSamples == startupTrace.droppedSamples,
               "startup evidence preserves scheduler, queue, window and marker state")
        assert(decodedTrace.warmupBoundaries == startupTrace.warmupBoundaries &&
               decodedTrace.networkTransport == "lan",
               "warm-up boundaries and sanitized network mode survive export")
        let oldTrace = Data(#"{"samples":[],"droppedSamples":0}"#.utf8)
        let decodedOldTrace = try? JSONDecoder().decode(RendererBenchmarkStartupTrace.self,
                                                       from: oldTrace)
        assert(decodedOldTrace != nil && decodedOldTrace?.warmupBoundaries == nil,
               "older startup exports remain readable")
        assert(RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(jsonData: traceData),
               "startup trace follows the same secret-free export policy")
        assert(
            !RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
                jsonData: Data(#"{"sessionToken":"secret"}"#.utf8)
            ),
            "benchmark evidence rejects transfer tokens"
        )
        assert(
            !RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
                jsonData: Data(#"{"baseURL":"https://device"}"#.utf8)
            ),
            "benchmark evidence rejects device session origins"
        )
    }


    static func testSecureRendererBenchmarkReadiness() {
        func blocker(
            isConnected: Bool = true,
            isNavigationReady: Bool = true,
            supportsRendererDiagnostics: Bool = true,
            supportsRendererBenchmarkSample: Bool = true,
            isNavigationActive: Bool = false,
            hasSecureSession: Bool = true,
            hasActiveMap: Bool = true,
            hasManifestReceipt: Bool = true,
            hasMapBounds: Bool = true,
            storageBackend: String? = "sdmmc",
            storagePowerCycleRequired: Bool? = false,
            manualReplayIsRunning: Bool = false
        ) -> SecureRendererBenchmarkReadinessBlocker? {
            SecureRendererBenchmarkReadiness.blocker(
                for: SecureRendererBenchmarkReadinessInputs(
                    isConnected: isConnected,
                    isNavigationReady: isNavigationReady,
                    supportsRendererDiagnostics: supportsRendererDiagnostics,
                    supportsRendererBenchmarkSample:
                        supportsRendererBenchmarkSample,
                    isNavigationActive: isNavigationActive,
                    hasSecureSession: hasSecureSession,
                    hasActiveMap: hasActiveMap,
                    hasManifestReceipt: hasManifestReceipt,
                    hasMapBounds: hasMapBounds,
                    storageBackend: storageBackend,
                    storagePowerCycleRequired: storagePowerCycleRequired,
                    manualReplayIsRunning: manualReplayIsRunning
                )
            )
        }

        assertEqual(blocker(), nil, "complete secure sweep state is ready")
        assertEqual(
            blocker(supportsRendererBenchmarkSample: false),
            .rendererBenchmarkSampleUnsupported,
            "secure sweep requires atomic GPS-plus-marker delivery"
        )
        assertEqual(
            blocker(hasSecureSession: false),
            .secureSessionUnavailable,
            "secure sweep requires the in-memory pinned HTTPS session"
        )
        assertEqual(
            blocker(hasActiveMap: false),
            .activeMapUnavailable,
            "secure sweep reports missing active-map status"
        )
        assertEqual(
            blocker(hasManifestReceipt: false),
            .manifestReceiptUnavailable,
            "secure sweep requires the active manifest receipt"
        )
        assertEqual(
            blocker(hasMapBounds: false),
            .mapBoundsUnavailable,
            "secure sweep requires validated active-map bounds"
        )
        assertEqual(
            blocker(storageBackend: nil),
            .storageStatusUnavailable,
            "secure sweep distinguishes missing storage status"
        )
        assertEqual(
            blocker(storageBackend: "legacy_spi_migration"),
            .nativeSDMMCRequired,
            "secure sweep rejects the migration storage fallback"
        )
        assertEqual(
            blocker(storagePowerCycleRequired: true),
            .nativeSDMMCRequired,
            "secure sweep retains the full-power-cycle SDMMC gate"
        )
        assertEqual(
            blocker(manualReplayIsRunning: true),
            .manualReplayRunning,
            "secure sweep cannot overlap the manual replay"
        )
    }

    static func testDeviceBLEProtocolConstants() {
        assertEqual(DeviceBLEProtocol.serviceUUIDString, "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800", "service UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.navigationCharacteristicUUIDString, "2A6E", "navigation characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.routeGeometryCharacteristicUUIDString, "2A6F", "route characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.gpsPositionCharacteristicUUIDString, "2A72", "GPS characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.settingsCharacteristicUUIDString, "2A73", "settings characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.routeGeometryFallbackPrefix, "MAPR", "route fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.gpsPositionFallbackPrefix, "GPSP", "GPS fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.settingsFallbackPrefix, "MSET", "settings fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.mapTransferControlPrefix, "MTRN", "map transfer control remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.mapTransferStatusPrefix, "MSTS", "map transfer status remains framed over navigation notifications")
        assertEqual(DeviceBLEProtocol.mapTransferStatusChunkPrefix, "MSTC", "chunked map transfer status remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceTransferControlPrefix, "DTRN", "generic transfer control remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceTransferStatusPrefix, "DSTS", "generic transfer status remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.soundPlayPrefix, "SNDP", "sound playback remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.powerButtonHonkPrefix, "SNDH", "PWR honk configuration remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.powerButtonHonkStatusPrefix, "SNHA", "PWR honk acknowledgement remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.destinationCatalogChunkPrefix, "DLST", "destination catalogs use DLST chunks")
        assertEqual(DeviceBLEProtocol.destinationRequestPrefix, "DREQ", "device destination requests use DREQ")
        assertEqual(DeviceBLEProtocol.destinationStatusPrefix, "DNST", "destination route statuses use DNST")
        assertEqual(DeviceBLEProtocol.workoutStartRequestPrefix, "WREQ", "device workout starts use WREQ")
        assertEqual(DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask, 4, "PWR honk acknowledgement uses capability bit 2")
        assertEqual(DeviceBLEProtocol.independentMapProfilesCapabilityMask, 8, "independent map profiles use capability bit 3")
        assertEqual(DeviceBLEProtocol.extendedMapVisibilityCapabilityMask, 16, "extended map visibility uses capability bit 4")
        assertEqual(DeviceBLEProtocol.batteryStatusScreenCapabilityMask, 32, "Battery Status support uses capability bit 5")
        assertEqual(DeviceBLEProtocol.destinationPickerCapabilityMask, 64, "destination picker support uses capability bit 6")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCapabilityMask, 128, "workout telemetry uses capability bit 7")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask, 1, "bird's-eye Map + Navigation uses extended capability bit 0")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask, 2, "bird's-eye perspective uses extended capability bit 1")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask, 4, "stronger bird's-eye perspectives use extended capability bit 2")
        assertEqual(DeviceBLEProtocol.streetLabelsCapabilityMask, 1 << 8, "CAP2 bit 8 advertises street-label profiles")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationCapabilityMask, 1 << 9, "CAP2 bit 9 advertises bird's-eye Map + Navigation")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveCapabilityMask, 1 << 10, "CAP2 bit 10 advertises bird's-eye perspective")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveCapabilityMask, 1 << 11, "CAP2 bit 11 advertises stronger bird's-eye perspectives")
        assertEqual(DeviceBLEProtocol.osm3DBuildingsCapabilityMask, 1 << 12, "CAP2 bit 12 advertises OSM 3D buildings")
        assertEqual(DeviceBLEProtocol.explicitInvalidGPSHeadingCapabilityMask, 1 << 13, "CAP2 bit 13 advertises explicit invalid GPS headings")
        assertEqual(DeviceBLEProtocol.scopedWatchControllerCapabilityMask, 1 << 14, "CAP2 bit 14 advertises scoped Watch control")
        assertEqual(DeviceBLEProtocol.rideAutomationCapabilityMask, 1 << 15, "CAP2 bit 15 advertises ride automation without colliding with Watch control")
        assertEqual(DeviceBLEProtocol.remoteDeviceDebugCapabilityMask, 1 << 16, "CAP2 bit 16 advertises remote device debugging without colliding with ride automation")
        assertEqual(DeviceBLEProtocol.gpsPositionQualityV1CapabilityMask, 1 << 17, "CAP2 bit 17 advertises GPS quality v1")
        assertEqual(DeviceBLEProtocol.rendererDiagnosticsCapabilityMask, 1 << 18, "CAP2 bit 18 advertises renderer diagnostics")
        assertEqual(DeviceBLEProtocol.automaticDisplayOffCapabilityMask, 1 << 19, "CAP2 bit 19 advertises automatic display-off")
        assertEqual(DeviceBLEProtocol.displayInactivityTimeoutsCapabilityMask, 1 << 28, "CAP2 bit 28 advertises configurable display inactivity timeouts")
        assertEqual(DeviceBLEProtocol.rideDiagnosticsCapabilityMask, 1 << 20, "CAP2 bit 20 advertises persistent ride diagnostics")
        assertEqual(DeviceBLEProtocol.detailedRideDiagnosticsCapabilityMask, 1 << 21, "CAP2 bit 21 advertises detailed ride diagnostics")
        assertEqual(DeviceBLEProtocol.rideDeliveryAcknowledgementCapabilityMask, 1 << 22, "CAP2 bit 22 advertises reliable ride delivery")
        assertEqual(DeviceBLEProtocol.screenConfigurationCapabilityMask, 1 << 26, "CAP2 bit 26 advertises configurable screen instances")
        assertEqual(DeviceBLEProtocol.worldRadioCapabilityMask, 1 << 27, "CAP2 bit 27 advertises World Radio without colliding with renderer or Watch capabilities")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkSampleCapabilityMask, 1 << 23, "CAP2 bit 23 advertises atomic renderer replay samples")
        assertEqual(DeviceBLEProtocol.watchGPSMotionEvidenceV1CapabilityMask, 1 << 25, "CAP2 bit 25 advertises Watch GPS motion evidence")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkWindowPrefix, "RBW1", "ordinary renderer windows stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceCapabilitiesVersion, 28, "capability version negotiates signed topographic contours alongside existing capabilities")
        assertEqual(RideBLEGeneratedProtocolV1.workoutZonesV1Feature, 1 << 29, "CAP2 bit 29 advertises versioned workout zones without reusing the display inactivity capability")
        assertEqual(RideBLEGeneratedProtocolV1.workoutZonesV1MinimumClientVersion, 27, "zone negotiation requires protocol 27, independent of the iOS version")
        assertEqual(DeviceBLEProtocol.topographicContoursCapabilityMask, 1 << 30, "CAP2 bit 30 advertises signed topographic contour support")
        assertEqual(RideBLEGeneratedProtocolV1.topographicContoursMinimumClientVersion, 28, "topographic contour negotiation requires protocol 28")
        assertEqual(RideBLEGeneratedProtocolV1.workoutZoneMaximumFrameBytes, 132, "bounded zone frames fit the documented protected ATT write budget")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkSampleCapabilityMask, 1 << 23, "CAP2 bit 23 advertises atomic renderer replay samples")
        assertEqual(DeviceBLEProtocol.watchGPSMotionEvidenceV1CapabilityMask, 1 << 25, "CAP2 bit 25 advertises Watch GPS motion evidence")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkWindowPrefix, "RBW1", "ordinary renderer windows stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationRotationSettingID, 37, "navigation orientation has an independent setting")
        assertEqual(RideBLEGeneratedProtocolV1.mapNavigationOrientationFeature, 1 << 24, "orientation capability has its own bit")
        assertEqual(DeviceBLEProtocol.rendererMetricsRequestPrefix, "RDMS", "renderer metrics requests use RDMS")
        assertEqual(DeviceBLEProtocol.rendererMetricsResponsePrefix, "RDMT", "renderer metrics responses use RDMT")
        assertEqual(DeviceBLEProtocol.rendererMetricsChunkPrefix, "RDMC", "renderer metrics chunks use RDMC")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkMarkerPrefix, "RBM1", "renderer replay markers use RBM1")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCharacteristicUUIDString,
                    "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003",
                    "workout telemetry uses the dedicated 128-bit characteristic")
        assertEqual(DeviceBLEProtocol.screenConfigurationCharacteristicUUIDString,
                    "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1005",
                    "screen configuration uses the dedicated owner-only characteristic")
        assertEqual(DeviceBLEProtocol.workoutTelemetryFallbackPrefix, "WTLM",
                    "workout telemetry fallback remains explicitly framed")
        assertEqual(DeviceBLEProtocol.serviceRoadsVisibilityMask, 0x400, "service roads use visibility bit 10")
        assertEqual(DeviceBLEProtocol.tracksVisibilityMask, 0x800, "tracks use visibility bit 11")
        assertEqual(DeviceBLEProtocol.extendedVisibilityMarker, 0x1000, "extended visibility uses marker bit 12")
        assertEqual(DeviceBLEProtocol.contoursVisibilityMask, 0x2000, "topographic contours use visibility bit 13")
        assertEqual(DeviceBLEProtocol.defaultStreetWidth, 4, "street width defaults to 4 px")
        assertEqual(DeviceBLEProtocol.absoluteStreetWidth(fromLegacyBoost: 0), 4, "legacy zero boost migrates to the default absolute width")
        assertEqual(DeviceBLEProtocol.absoluteStreetWidth(fromLegacyBoost: 4), 8, "legacy boosts migrate relative to the default width")
        assertEqual(DeviceBLEProtocol.legacyStreetWidthBoost(fromAbsoluteWidth: 1), -3, "one-pixel streets retain the legacy wire encoding")
        assertEqual(DeviceBLEProtocol.legacyStreetWidthBoost(fromAbsoluteWidth: 4), 0, "default street width uses a zero wire boost")
        assertEqual(DeviceBLEProtocol.brightnessSettingID, 12, "brightness uses firmware setting ID 12")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(-1), 5, "brightness clamps below the device range")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(65.4), 65, "brightness uses whole-number percent")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(101), 100, "brightness clamps above the device range")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(.nan), 100, "invalid stored brightness restores the compatibility default")
        assertEqual(DeviceBLEProtocol.enabledScreensSettingID, 13, "enabled screens use firmware setting ID 13")
        assertEqual(DeviceBLEProtocol.defaultScreenSettingID, 14, "default screen uses firmware setting ID 14")
        assertEqual(DeviceBLEProtocol.disconnectedSleepTimeoutSettingID, 15, "disconnected sleep timeout uses firmware setting ID 15")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID, 16, "Map + Navigation polygon size uses setting ID 16")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID, 17, "Map + Navigation detail uses setting ID 17")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID, 18, "Map + Navigation route width uses setting ID 18")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID, 19, "Map + Navigation zoom uses setting ID 19")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID, 20, "Map + Navigation visibility uses setting ID 20")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID, 21, "Map + Navigation street width uses setting ID 21")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID, 22, "Map + Navigation marker scale uses setting ID 22")
        assertEqual(DeviceBLEProtocol.phoneBatteryLevelSettingID, 23, "phone battery level uses firmware setting ID 23")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingSettingID, 24, "phone charging state uses firmware setting ID 24")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationBirdsEyeViewSettingID, 25, "bird's-eye Map + Navigation uses setting ID 25")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID, 26, "bird's-eye perspective uses setting ID 26")
        assertEqual(DeviceBLEProtocol.mapLabelDensitySettingID, 27, "Map street-label density uses setting ID 27")
        assertEqual(DeviceBLEProtocol.mapLabelLanguageModeSettingID, 28, "Map street-label language uses setting ID 28")
        assertEqual(DeviceBLEProtocol.mapLabelTextSizeSettingID, 29, "Map street-label size uses setting ID 29")
        assertEqual(DeviceBLEProtocol.mapLabelOrientationSettingID, 30, "Map street-label orientation uses setting ID 30")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelDensitySettingID, 31, "Map + Navigation street-label density uses setting ID 31")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelLanguageModeSettingID, 32, "Map + Navigation street-label language uses setting ID 32")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelTextSizeSettingID, 33, "Map + Navigation street-label size uses setting ID 33")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID, 34, "Map + Navigation street-label orientation uses setting ID 34")
        assertEqual(DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID, 35, "Map + Navigation 3D buildings use setting ID 35")
        assertEqual(DeviceBLEProtocol.automaticDisplayOffSettingID, 36, "automatic display-off uses firmware setting ID 36")
        assertEqual(DeviceBLEProtocol.displayInactivityTimeoutsSettingID, 38, "display inactivity timeouts use firmware setting ID 38")
        assertEqual(
            DeviceBLEProtocol.displayInactivityTimeoutsSettingValue(
                dimAfterSeconds: 15,
                displayOffAfterSeconds: 45
            )!,
            Int32(0x002D000F),
            "display inactivity timeouts use one atomic packed value"
        )
        assertEqual(
            DeviceBLEProtocol.displayInactivityTimeoutsSettingValue(
                dimAfterSeconds: 60,
                displayOffAfterSeconds: 45
            ),
            nil,
            "display inactivity timeout encoding rejects off-before-dim values"
        )
        assertEqual(DeviceBLEProtocol.defaultMapStreetLabelsEnabled, true, "Map street labels default to enabled")
        assertEqual(DeviceBLEProtocol.defaultMapPlusNavigationStreetLabelsEnabled, false, "Map + Navigation street labels default to disabled")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelDensity, 2, "street labels default to Balanced density")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelLanguageMode, 2, "street labels default to Local + Preferred language")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelTextSize, 0, "street labels default to the new Small tier")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelOrientation, 1, "street labels default to Keep Upright")
        assertEqual(DeviceBLEProtocol.effectiveStreetLabelDensity(enabled: true, density: 2), 2, "enabled labels send their selected density")
        assertEqual(DeviceBLEProtocol.effectiveStreetLabelDensity(enabled: false, density: 2), 0, "disabled labels preserve density locally and send wire value zero")
        assertEqual(DeviceBLEProtocol.normalizedStreetLabelDensity(0), 2, "legacy Off density restores Balanced when labels are enabled")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: -1), .standard, "unknown bird's-eye perspectives use Standard")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 0), .gentle, "perspective zero is Gentle")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 2), .strong, "perspective two is Strong")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 3), .veryStrong, "perspective three is Very Strong")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 4), .maximum, "perspective four is Maximum")
        assertEqual(MapNavigationBirdsEyePerspective.maximum.supportedValue(supportsStrongerPerspectives: false), .strong, "older firmware receives Strong instead of Maximum")
        assertEqual(MapNavigationBirdsEyePerspective.maximum.supportedValue(supportsStrongerPerspectives: true), .maximum, "new firmware retains Maximum")
        assertEqual(DeviceBLEProtocol.currentScreenMaskMarker, 1 << 30, "current screen masks use bit 30 as a compatibility marker")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: -1), nil, "unavailable iPhone battery levels stay unknown")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 0), 0, "empty iPhone battery maps to zero percent")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 0.735), 74, "iPhone battery levels round to whole percentages")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 1), 100, "full iPhone battery maps to 100 percent")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingValue(isCharging: false), 0, "unplugged iPhones send not charging")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingValue(isCharging: true), 1, "charging iPhones send charging")
        assertEqual(DeviceScreen.map.rawValue, 0, "Map screen protocol value stays stable")
        assertEqual(DeviceScreen.navigation.rawValue, 1, "Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.rideStats.rawValue, 2, "Ride Stats screen protocol value stays stable")
        assertEqual(DeviceScreen.mapPlusNavigation.rawValue, 3, "Map + Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.batteryStatus.rawValue, 4, "Battery Status screen uses protocol value 4")
        assertEqual(DeviceScreen.worldRadio.rawValue, 5, "World Radio screen uses protocol value 5")
        assertEqual(DeviceScreen.mapPlusNavigation.title, "Map + Navigation", "combined map/navigation screen keeps user-facing label")
        assertEqual(DeviceScreen.batteryStatus.title, "Battery Status", "battery screen has a user-facing label")
        assertEqual(DeviceScreen.worldRadio.title, "World Radio", "World Radio has a user-facing label")
        assertEqual(DeviceScreen.displayOrder,
                    [.mapPlusNavigation, .rideStats, .map, .navigation, .worldRadio, .batteryStatus],
                    "World Radio precedes Battery Status in settings and cycling order")
        assertEqual(DeviceScreen.allScreensMask, 0x3F, "all supported device screens use the low six mask bits")
        assertEqual(DeviceScreen.defaultScreensMask, 0x1F, "World Radio is off by default")
        assertEqual(DeviceScreen.legacyScreensMask, 0x0F, "legacy firmware receives only the original four screen bits")
        assertEqual(DisconnectedSleepTimeout.oneMinute.settingValue, 60, "one-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.twoMinutes.settingValue, 120, "two-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.fiveMinutes.settingValue, 300, "five-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.tenMinutes.settingValue, 600, "ten-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.never.settingValue, 0, "never sleep sends zero seconds")
        assertEqual(DisconnectedSleepTimeout.normalized(rawValue: 999), .twoMinutes, "unknown sleep timeout falls back to two minutes")
    }

    static func testDeviceScreenValidation() {
        assertEqual(DeviceScreen.normalizedMask(0), DeviceScreen.allScreensMask, "zero screen mask falls back to all screens")
        assertEqual(DeviceScreen.normalizedMask(0xFF), DeviceScreen.allScreensMask, "unknown screen mask bits are ignored")
        assertEqual(DeviceScreen.normalizedMask(DeviceScreen.batteryStatus.bit,
                                                supportedMask: DeviceScreen.legacyScreensMask),
                    DeviceScreen.legacyScreensMask,
                    "a Battery-only mask falls back to all screens supported by legacy firmware")

        let rideStatsOnly = DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.mapPlusNavigation.rawValue, mask: rideStatsOnly),
                    .rideStats,
                    "disabled default falls back to the first enabled non-map screen")

        let mapAndStats = DeviceScreen.map.bit | DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.navigation.rawValue, mask: mapAndStats),
                    .rideStats,
                    "disabled default follows the device screen display order")

        let batteryAndStats = DeviceScreen.batteryStatus.bit | DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.map.rawValue, mask: batteryAndStats),
                    .rideStats,
                    "Battery Status remains last in fallback order")
        assertEqual(DeviceScreen.fallbackDefault(
            for: DeviceScreen.batteryStatus.rawValue,
            mask: DeviceScreen.allScreensMask,
            supportedMask: DeviceScreen.legacyScreensMask
        ), .mapPlusNavigation,
        "legacy firmware never receives Battery Status as its default")
    }

    static func workoutDeviceSample(
        state: WorkoutDeviceSessionState = .running,
        sessionToken: UInt16 = 0x1234,
        hasLiveNumerics: Bool = true,
        isCurrentSnapshot: Bool? = nil,
        elapsedSeconds: Double? = 3_661,
        distanceMeters: Double? = 12_345,
        speedMetersPerSecond: Double? = 12.34,
        currentHeartRateBPM: Double? = 157,
        averageHeartRateBPM: Double? = 148,
        activeEnergyKilocalories: Double? = 456.7,
        cyclingPowerWatts: Double? = 321,
        cyclingCadenceRPM: Double? = 87.6,
        currentHeartRateZone: UInt8? = 4,
        altitudeMeters: Double? = -12,
        heartRateZoneCount: UInt8? = 5,
        sourceFlags: WorkoutDeviceSourceFlags = [
            .pairedSpeedSensor,
            .watchSpeed,
            .healthKitDistance,
            .watchAltitude,
            .liveHeartRateZone,
        ],
        pauseOrigin: WorkoutTransitionOrigin? = nil,
        wallElapsedSeconds: Double? = 4_000,
        sessionID: UUID? = UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        ),
        detectorProfileVersion: UInt16? = 1,
        lastTransitionOrigin: WorkoutTransitionOrigin? = .automatic
    ) -> WorkoutDeviceTelemetrySample {
        WorkoutDeviceTelemetrySample(
            state: state,
            sessionToken: sessionToken,
            hasLiveNumerics: hasLiveNumerics,
            isCurrentSnapshot: isCurrentSnapshot ?? hasLiveNumerics,
            elapsedSeconds: elapsedSeconds,
            distanceMeters: distanceMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            currentHeartRateBPM: currentHeartRateBPM,
            averageHeartRateBPM: averageHeartRateBPM,
            activeEnergyKilocalories: activeEnergyKilocalories,
            cyclingPowerWatts: cyclingPowerWatts,
            cyclingCadenceRPM: cyclingCadenceRPM,
            currentHeartRateZone: currentHeartRateZone,
            altitudeMeters: altitudeMeters,
            heartRateZoneCount: heartRateZoneCount,
            sourceFlags: sourceFlags,
            pauseOrigin: pauseOrigin,
            wallElapsedSeconds: wallElapsedSeconds,
            sessionID: sessionID,
            detectorProfileVersion: detectorProfileVersion,
            lastTransitionOrigin: lastTransitionOrigin
        )
    }

    static func testWorkoutDeviceFrameVectors() {
        guard let frames = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        ) else {
            assert(false, "valid workout telemetry produces frames")
            return
        }
        assertEqual(frames.core, Data([
            0x01, 0x02, 0x34, 0x12,
            0x4D, 0x0E, 0x00, 0x00,
            0x39, 0x30, 0x00, 0x00,
            0xD2, 0x04, 0x9D, 0x00,
        ]), "core workout frame matches the protocol byte vector")
        assertEqual(frames.extended, Data([
            0x02, 0x3F, 0x34, 0x12,
            0x94, 0x00, 0xD7, 0x11,
            0x41, 0x01, 0x6C, 0x03,
            0x04, 0xF4, 0xFF, 0x05,
        ]), "extended workout frame matches the protocol byte vector")
        assertEqual(frames.origin, Data([
            0x03, 0x00, 0x34, 0x12,
            0xA0, 0x0F, 0x00, 0x00,
            0x00, 0x11, 0x22, 0x33,
            0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF,
            0x01, 0x00, 0x02, 0x00,
        ]), "origin workout frame matches the protocol byte vector")
        assertEqual(frames.core.count, 16, "core workout frame is exactly 16 bytes")
        assertEqual(frames.extended.count, 16, "extended workout frame is exactly 16 bytes")
        assertEqual(frames.origin.count, 28, "origin workout frame carries the full Watch session UUID")

        let maskedFlags = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            sourceFlags: WorkoutDeviceSourceFlags(rawValue: 0xFF)
        ))
        assertEqual(maskedFlags?.extended[1], 0x3F,
                    "pair-generation bits are assigned only by the relay scheduler")

        assertEqual(WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .running,
            sessionToken: 0
        )), nil, "active workout frames reject token zero")
        assertEqual(WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .idle,
            sessionToken: 1
        )), nil, "idle workout frames require token zero")
        let idle = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .idle,
            sessionToken: 0,
            hasLiveNumerics: false
        ))
        assertEqual(idle?.core[1], WorkoutDeviceSessionState.idle.rawValue,
                    "idle frame explicitly clears device workout state")
        assertEqual(readUInt16LE(idle?.core ?? Data(repeating: 0, count: 16), offset: 2), 0,
                    "idle clear frame carries token zero")
        assert(idle?.originAvailable == false,
               "idle clear frames never publish a synthetic provenance identity")
    }

    static func testWorkoutDeviceFrameSentinelsAndSaturation() {
        let unavailable = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            elapsedSeconds: -.infinity,
            distanceMeters: -1,
            speedMetersPerSecond: .nan,
            currentHeartRateBPM: 0,
            averageHeartRateBPM: -.infinity,
            activeEnergyKilocalories: -0.1,
            cyclingPowerWatts: .nan,
            cyclingCadenceRPM: -1,
            currentHeartRateZone: 6,
            altitudeMeters: .infinity,
            heartRateZoneCount: 5
        ))!
        assertEqual(readUInt32LE(unavailable.core, offset: 4), UInt32.max,
                    "non-finite elapsed time is unavailable")
        assertEqual(readUInt32LE(unavailable.core, offset: 8), UInt32.max,
                    "negative distance is unavailable")
        assertEqual(readUInt16LE(unavailable.core, offset: 12), UInt16.max,
                    "non-finite speed is unavailable")
        assertEqual(readUInt16LE(unavailable.core, offset: 14), UInt16.max,
                    "zero heart rate is unavailable")
        for offset in [4, 6, 8, 10] {
            assertEqual(readUInt16LE(unavailable.extended, offset: offset), UInt16.max,
                        "invalid extended UInt16 metric uses the sentinel")
        }
        assertEqual(unavailable.extended[12], 0,
                    "invalid current zone stays unavailable")
        assertEqual(readUInt16LE(unavailable.extended, offset: 13), 0x8000,
                    "invalid altitude uses Int16.min sentinel")
        assertEqual(unavailable.extended[15], 0,
                    "invalid zone count stays unavailable")
        assertEqual(unavailable.extended[1], 0x20,
                    "a current snapshot remains distinguishable when every metric is unavailable")

        let saturated = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            elapsedSeconds: Double(UInt32.max) * 2,
            distanceMeters: Double(UInt32.max) * 2,
            speedMetersPerSecond: Double(UInt16.max),
            currentHeartRateBPM: Double(UInt16.max) * 2,
            averageHeartRateBPM: Double(UInt16.max) * 2,
            activeEnergyKilocalories: 6_553.5,
            cyclingPowerWatts: Double(UInt16.max) * 2,
            cyclingCadenceRPM: Double(UInt16.max),
            altitudeMeters: Double(Int16.min)
        ))!
        assertEqual(readUInt32LE(saturated.core, offset: 4), UInt32.max - 1,
                    "elapsed time saturates below its sentinel")
        assertEqual(readUInt32LE(saturated.core, offset: 8), UInt32.max - 1,
                    "distance saturates below its sentinel")
        assertEqual(readUInt16LE(saturated.core, offset: 12), UInt16.max - 1,
                    "speed saturates below its sentinel")
        assertEqual(readUInt16LE(saturated.core, offset: 14), UInt16.max - 1,
                    "current heart rate saturates below its sentinel")
        for offset in [4, 6, 8, 10] {
            assertEqual(readUInt16LE(saturated.extended, offset: offset), UInt16.max - 1,
                        "extended values saturate below their sentinel")
        }
        assertEqual(readUInt16LE(saturated.extended, offset: 13), 0x8001,
                    "valid low altitude saturates above Int16.min")

        let stale = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            hasLiveNumerics: false
        ))!
        assertEqual(stale.core[1], WorkoutDeviceSessionState.running.rawValue,
                    "stale frame preserves session state")
        assertEqual(readUInt16LE(stale.core, offset: 2), 0x1234,
                    "stale frame preserves session token")
        assertEqual(readUInt32LE(stale.core, offset: 4), UInt32.max,
                    "stale frame strips core numerics")
        assertEqual(stale.extended[1], 0,
                    "stale frame strips source flags and current-snapshot freshness")
        assertEqual(readUInt16LE(stale.extended, offset: 4), UInt16.max,
                    "stale frame strips extended numerics")
    }

    static func testWorkoutDeviceTelemetryMapping() {
        let date = Date(timeIntervalSince1970: 1_000)
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        func metric(
            _ value: Double,
            _ unit: WorkoutMetricUnitV1,
            source: WorkoutMetricSourceV1? = nil
        ) -> WorkoutMetricV1 {
            WorkoutMetricV1(
                value: value,
                unit: unit,
                capturedAt: date,
                source: source
            )
        }
        let watchLocation = WorkoutLocationV1(
            latitude: 1,
            longitude: 2,
            capturedAt: date,
            horizontalAccuracy: 3,
            altitude: 42,
            verticalAccuracy: 4,
            course: nil,
            speed: 8
        )
        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            currentHeartRate: metric(150, .beatsPerMinute, source: .healthKit),
            averageHeartRate: metric(140, .beatsPerMinute, source: .healthKit),
            activeEnergy: metric(20, .kilocalories, source: .healthKit),
            cyclingDistance: metric(100, .meters, source: .healthKit),
            currentSpeed: metric(8, .metersPerSecond, source: .pairedCyclingSensor),
            cyclingPower: metric(250, .watts, source: .pairedCyclingSensor),
            cyclingCadence: metric(90, .revolutionsPerMinute, source: .pairedCyclingSensor),
            currentHeartRateZone: 3,
            heartRateZoneCount: 5,
            location: watchLocation,
            availability: [
                .elapsedTime, .currentHeartRate, .averageHeartRate,
                .activeEnergy, .cyclingDistance, .currentSpeed,
                .cyclingPower, .cyclingCadence, .heartRateZone,
                .location, .altitude,
            ]
        )
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 1,
            capturedAt: date,
            snapshot: snapshot
        )
        func presentation(
            connectionState: WorkoutMirrorConnectionStateV1,
            snapshot presentedSnapshot: WorkoutSnapshotV1 = snapshot,
            confirmedState: WorkoutSessionStateV1? = nil,
            finalSnapshot: WorkoutSnapshotV1? = nil
        ) -> WorkoutMirrorPresentationV1 {
            WorkoutMirrorPresentationV1(
                connectionState: connectionState,
                snapshot: presentedSnapshot,
                sessionID: sessionID,
                capturedAt: date,
                receivedAt: date,
                confirmedSessionState: confirmedState,
                errorCode: nil,
                pendingControl: nil,
                finalSnapshot: finalSnapshot,
                navigation: .empty
            )
        }

        let live = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .connected),
            envelope: envelope
        )
        assertEqual(live?.state, .running,
                    "mapper preserves authoritative running state")
        assertEqual(live?.sessionToken, 77,
                    "mapper preserves the Watch session token")
        assert(live?.hasLiveNumerics == true,
               "connected coherent snapshots retain live numerics")
        assert(live?.sourceFlags.contains(.pairedSpeedSensor) == true,
               "mapper reports paired speed source")
        assert(live?.sourceFlags.contains(.healthKitDistance) == true,
               "mapper reports HealthKit distance source")
        assert(live?.sourceFlags.contains(.watchAltitude) == true,
               "mapper reports authoritative Watch altitude")
        assert(live?.sourceFlags.contains(.liveHeartRateZone) == true,
               "mapper reports live heart-rate zone availability")

        let stale = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .stale),
            envelope: envelope
        )
        assertEqual(stale?.state, .running,
                    "stale mapping preserves active session state")
        assert(stale?.hasLiveNumerics == false,
               "stale mapping strips live numerics")
        assert(stale?.sessionID == nil,
               "stale mapping strips origin identity with its Watch snapshot")
        assert(stale.flatMap { WorkoutDeviceFrameBuilder.frames(for: $0) }?
            .originAvailable == false,
               "stale relay frames cannot publish zero-identity provenance")

        let stoppedAwaitingFinal = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .connected,
                confirmedState: .ending
            ),
            envelope: envelope
        )
        assertEqual(stoppedAwaitingFinal?.state, .ending,
                    "a connected stopped callback remains ending")
        assert(stoppedAwaitingFinal?.hasLiveNumerics == false,
               "connected ending cannot replay frozen running metrics")
        assert(stoppedAwaitingFinal?.isCurrentSnapshot == true,
               "connected ending remains a current awaiting-final update")

        let awaitingFinal = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .ended,
                confirmedState: .ended
            ),
            envelope: envelope
        )
        assertEqual(awaitingFinal?.state, .ending,
                    "native end without a final Watch snapshot stays ending")
        assert(awaitingFinal?.hasLiveNumerics == false,
               "awaiting-final state cannot heartbeat frozen health metrics")
        assert(awaitingFinal?.isCurrentSnapshot == true,
               "awaiting-final state remains a current mirrored snapshot")
        let awaitingFinalFrames = awaitingFinal.flatMap {
            WorkoutDeviceFrameBuilder.frames(for: $0)
        }
        assertEqual(
            awaitingFinalFrames?.extended[1],
            WorkoutDeviceSourceFlags.currentSnapshot.rawValue,
            "awaiting-final pair distinguishes current unavailable metrics"
        )

        let disconnectedEnding = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .disconnected,
                confirmedState: .ended
            ),
            envelope: envelope
        )
        assertEqual(disconnectedEnding?.state, .ending,
                    "disconnected finalization stays in ending state")
        assert(disconnectedEnding?.isCurrentSnapshot == false,
               "disconnected finalization is not marked current")
        let disconnectedEndingFrames = disconnectedEnding.flatMap {
            WorkoutDeviceFrameBuilder.frames(for: $0)
        }
        assertEqual(disconnectedEndingFrames?.extended[1], 0,
                    "disconnected ending pair carries no freshness bit")

        let endedSnapshot = WorkoutSnapshotV1(
            state: .ended,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            currentHeartRate: metric(150, .beatsPerMinute, source: .healthKit),
            availability: [.elapsedTime, .currentHeartRate],
            terminalOutcome: .saved
        )
        let endedEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 2,
            capturedAt: date,
            snapshot: endedSnapshot
        )
        let ended = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .ended,
                snapshot: endedSnapshot,
                finalSnapshot: endedSnapshot
            ),
            envelope: endedEnvelope
        )
        assertEqual(ended?.state, .ended,
                    "authoritative final Watch snapshot maps to ended")
        assert(ended?.hasLiveNumerics == true,
               "authoritative ended summary retains final numerics")

        let failedSnapshot = WorkoutSnapshotV1(
            state: .failed,
            errorCode: .sessionFailed
        )
        let failedEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 3,
            capturedAt: date,
            snapshot: failedSnapshot
        )
        let failed = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .failed,
                snapshot: failedSnapshot,
                confirmedState: .failed
            ),
            envelope: failedEnvelope
        )
        assertEqual(failed?.state, .failed,
                    "authoritative Watch failure maps to failed")
        assert(failed?.hasLiveNumerics == false,
               "failed sessions do not relay frozen live metrics")
        assert(failed?.isCurrentSnapshot == true,
               "an authoritative failed envelope remains current")
        assertEqual(
            failed.flatMap {
                WorkoutDeviceFrameBuilder.frames(for: $0)
            }?.extended[1],
            WorkoutDeviceSourceFlags.currentSnapshot.rawValue,
            "authoritative failure can cross a same-token collision boundary"
        )

        let phoneLocation = WorkoutLocationV1(
            latitude: 1,
            longitude: 2,
            capturedAt: date,
            horizontalAccuracy: 3,
            altitude: 99,
            verticalAccuracy: 4,
            course: nil,
            speed: 8
        )
        let rawWithoutLocation = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            availability: [.elapsedTime]
        )
        let mergedWithPhoneAltitude = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            location: phoneLocation,
            availability: [.elapsedTime, .location, .altitude]
        )
        let rawEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 4,
            capturedAt: date,
            snapshot: rawWithoutLocation
        )
        let phoneAltitude = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .connected,
                snapshot: mergedWithPhoneAltitude
            ),
            envelope: rawEnvelope
        )
        assertEqual(phoneAltitude?.altitudeMeters, 99,
                    "valid iPhone altitude remains a relay fallback")
        assert(phoneAltitude?.sourceFlags.contains(.watchAltitude) == false,
               "iPhone altitude is not mislabeled as Watch altitude")

        assertEqual(WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .connected),
            envelope: WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: UUID(),
                sessionToken: 77,
                sequence: 1,
                capturedAt: date,
                snapshot: snapshot
            )
        ), nil, "mapper rejects a mismatched session envelope")
    }

    static func testWorkoutDeviceRelayScheduling() {
        let start = Date(timeIntervalSince1970: 10_000)
        let initial = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        )!
        let changed = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            speedMetersPerSecond: 13,
            activeEnergyKilocalories: 457
        ))!
        let paused = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .paused,
            speedMetersPerSecond: 0
        ))!
        let stale = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .paused,
            hasLiveNumerics: false
        ))!
        let currentEnding = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample(
                state: .ending,
                hasLiveNumerics: false,
                isCurrentSnapshot: true
            )
        )!
        let disconnectedEnding = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample(
                state: .ending,
                hasLiveNumerics: false,
                isCurrentSnapshot: false
            )
        )!

        var scheduler = WorkoutDeviceRelayScheduler()
        var schedule = scheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
                    "authentication sends workout metrics and provenance")
        assert(schedule.transmissions.first?.prioritized == true,
               "initial core synchronization uses the priority lane")
        assert(schedule.transmissions.count == 3,
               "initial synchronization includes the complete metric pair and provenance")
        let initialPairGeneration = schedule.transmissions[0].data[1] >> 6
        assert(initialPairGeneration > 0,
               "new relay frames carry a non-zero pair generation")
        assertEqual(schedule.transmissions[1].data[1] >> 6,
                    initialPairGeneration,
                    "core and extended frames share one pair generation")
        assertEqual(schedule.transmissions[0].data[1] & 0x3F,
                    WorkoutDeviceSessionState.running.rawValue,
                    "pair generation leaves the core session state intact")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }

        var legacyScheduler = WorkoutDeviceRelayScheduler()
        let legacyInitial = legacyScheduler.update(
            frames: initial,
            transportReady: true,
            originTransportReady: false,
            at: start
        )
        assertEqual(legacyInitial.transmissions.map(\.kind), [.core, .extended],
                    "legacy peers receive only the original frame pair")
        for transmission in legacyInitial.transmissions {
            legacyScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let legacyIdle = legacyScheduler.update(
            frames: initial,
            transportReady: true,
            originTransportReady: false,
            at: start.addingTimeInterval(0.1)
        )
        assert(legacyIdle.transmissions.isEmpty,
               "unsupported provenance does not create phantom work")
        assertEqual(
            legacyIdle.nextEvaluationAt,
            start.addingTimeInterval(5),
            "legacy scheduling waits for the metric heartbeat"
        )

        schedule = scheduler.update(
            frames: changed,
            transportReady: true,
            at: start.addingTimeInterval(0.2)
        )
        assert(schedule.transmissions.isEmpty,
               "high-rate numeric changes coalesce for one second")
        assertEqual(schedule.nextEvaluationAt, start.addingTimeInterval(1),
                    "coalesced change schedules the next exact deadline")

        schedule = scheduler.update(
            frames: changed,
            transportReady: true,
            at: start.addingTimeInterval(1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "coalesced changed frames send when due")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1)
            )
        }

        schedule = scheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(1.1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "session-state transitions bypass metric coalescing")
        assert(schedule.transmissions[0].prioritized,
               "session-state core transition is prioritized")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1.1)
            )
        }

        schedule = scheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(1.2)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
                    "fresh-to-stale transition sends sentinels immediately")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1.2)
            )
        }

        _ = scheduler.update(
            frames: stale,
            transportReady: false,
            at: start.addingTimeInterval(2)
        )
        schedule = scheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(2.1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
                    "reconnect resynchronizes metrics and provenance once")

        var heartbeatScheduler = WorkoutDeviceRelayScheduler()
        let heartbeatStart = heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        for transmission in heartbeatStart.transmissions {
            heartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        assert(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(4.9)
        ).transmissions.isEmpty, "extended heartbeat waits five seconds")
        let firstLiveHeartbeat = heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(5)
        )
        assertEqual(firstLiveHeartbeat.transmissions.map(\.kind), [.core, .extended],
                    "unchanged live frames heartbeat every five seconds")
        for transmission in firstLiveHeartbeat.transmissions {
            heartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(5)
            )
        }
        assert(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(9.9)
        ).transmissions.isEmpty, "the recurring heartbeat waits for its next interval")
        assertEqual(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(10)
        ).transmissions.map(\.kind), [.core, .extended],
        "live core and extended heartbeats recur beyond the first interval")

        var pausedHeartbeatScheduler = WorkoutDeviceRelayScheduler()
        let pausedHeartbeatStart = pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start
        )
        for transmission in pausedHeartbeatStart.transmissions {
            pausedHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let firstPausedHeartbeat = pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(5)
        )
        assertEqual(firstPausedHeartbeat.transmissions.map(\.kind), [.core, .extended],
                    "a healthy paused workout keeps core freshness alive")
        for transmission in firstPausedHeartbeat.transmissions {
            pausedHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(5)
            )
        }
        assertEqual(pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(10)
        ).transmissions.map(\.kind), [.core, .extended],
        "paused core freshness continues across recurring heartbeat intervals")

        var staleHeartbeatScheduler = WorkoutDeviceRelayScheduler()
        let staleHeartbeatStart = staleHeartbeatScheduler.update(
            frames: stale,
            transportReady: true,
            at: start
        )
        for transmission in staleHeartbeatStart.transmissions {
            staleHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        assertEqual(staleHeartbeatScheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(5)
        ).transmissions.map(\.kind), [.core, .extended],
        "stale heartbeats remain a complete transactional pair")

        var partialPairScheduler = WorkoutDeviceRelayScheduler()
        let partialPair = partialPairScheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        partialPairScheduler.didWrite(
            kind: .core,
            data: partialPair.transmissions[0].data,
            at: start
        )
        partialPairScheduler.didNotWrite(
            kind: .extended,
            data: partialPair.transmissions[1].data
        )
        partialPairScheduler.didNotWrite(
            kind: .origin,
            data: partialPair.transmissions[2].data
        )
        let retriedPair = partialPairScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(0.1)
        )
        assertEqual(retriedPair.transmissions.map(\.kind), [.core, .extended, .origin],
                    "a partial publication retries metrics and provenance")
        assert(retriedPair.transmissions[0].data[1] >> 6 != initialPairGeneration,
               "a retried pair advances its correlation generation")

        var endingFreshnessScheduler = WorkoutDeviceRelayScheduler()
        let currentEndingPair = endingFreshnessScheduler.update(
            frames: currentEnding,
            transportReady: true,
            at: start
        )
        for transmission in currentEndingPair.transmissions {
            endingFreshnessScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let disconnectedEndingPair = endingFreshnessScheduler.update(
            frames: disconnectedEnding,
            transportReady: true,
            at: start.addingTimeInterval(0.1)
        )
        assertEqual(
            disconnectedEndingPair.transmissions.map(\.kind),
            [.core, .extended],
            "current-ending to disconnected-ending bypasses coalescing"
        )
        assert(disconnectedEndingPair.transmissions.first?.prioritized == true,
               "ending freshness loss uses the priority lane")
    }

}
