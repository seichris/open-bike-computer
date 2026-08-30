#if DEBUG
import Combine
import CryptoKit
import Foundation
import UIKit

private enum SecureRendererBenchmarkControllerError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case httpStatus(Int, String?)
    case network(String, Int)
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message):
            return message
        case .httpStatus(let status, let code):
            return "The secure device endpoint returned HTTP \(status)" +
                (code.map { " (\($0))" } ?? "") + "."
        case .network(let domain, let code):
            return "The secure device request failed (\(domain) \(code))."
        case .stopped:
            return "The secure renderer benchmark was stopped."
        }
    }
}

private struct RendererBenchmarkWindowRequest: Encodable {
    let schema = 1
    let profile: String
    let runId: String
    let repeatNumber: Int
    let mapFixture: RendererBenchmarkMapFixtureIdentity
    let routeFixture: RendererBenchmarkRouteFixtureIdentity
    let routeMode: String

    enum CodingKeys: String, CodingKey {
        case schema, profile, runId, mapFixture, routeFixture, routeMode
        case repeatNumber = "repeat"
    }
}

private struct RendererBenchmarkWindowResponse: Decodable {
    let ok: Bool
    let schema: Int
    let requestId: UInt32
}

private final class SecureRendererBenchmarkHTTPClient: @unchecked Sendable {
    private static let tokenHeader = "X-BikeComputer-Transfer-Token"
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init?(deviceSession: DeviceTransferSession) {
        guard deviceSession.mode == .debug,
              deviceSession.secureTransferV1,
              let token = deviceSession.sessionToken,
              DeviceTransferSecurityPolicy.normalizedTransferToken(token) == token,
              DeviceTransferSecurityPolicy.validate(
                baseURL: deviceSession.baseURL,
                certificateSHA256: deviceSession.tlsCertificateSHA256,
                identityVersion: deviceSession.tlsIdentityVersion,
                transferGeneration: deviceSession.transferGeneration,
                secureTransferV1: deviceSession.secureTransferV1
              ) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        guard let session = DeviceTransferPinnedSessionFactory.make(
            configuration: configuration,
            baseURL: deviceSession.baseURL,
            certificateSHA256: deviceSession.tlsCertificateSHA256
        ) else { return nil }
        baseURL = deviceSession.baseURL
        self.token = token
        self.session = session
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func info() async throws -> RendererBenchmarkDeviceInfo {
        try await decodeJSON(
            RendererBenchmarkDeviceInfo.self,
            data: request(path: "device-debug/v1/info"),
            maximumBytes: 65_536,
            invalidMessage: "The device returned invalid benchmark identity."
        )
    }

    func metrics() async throws -> RendererBenchmarkMetricsSnapshot {
        try await decodeJSON(
            RendererBenchmarkMetricsSnapshot.self,
            data: request(path: "device-debug/v1/metrics"),
            maximumBytes: 262_144,
            invalidMessage: "The device returned invalid renderer metrics."
        )
    }

    func beginWindow(
        profile: RendererBenchmarkProfile,
        runId: String,
        repeatNumber: Int,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity
    ) async throws -> UInt32 {
        let body = try JSONEncoder().encode(RendererBenchmarkWindowRequest(
            profile: profile.wireName,
            runId: runId,
            repeatNumber: repeatNumber,
            mapFixture: mapFixture,
            routeFixture: routeFixture,
            routeMode: SecureRendererBenchmarkPlan.routeMode
        ))
        let response = try await decodeJSON(
            RendererBenchmarkWindowResponse.self,
            data: request(
                path: "device-debug/v1/metrics/window",
                method: "POST",
                body: body
            ),
            maximumBytes: 4_096,
            invalidMessage: "The device returned an invalid benchmark-window response."
        )
        guard response.ok, response.schema == 1, response.requestId != 0 else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The device rejected the benchmark-window identity."
            )
        }
        return response.requestId
    }

    func frame(after sequence: UInt32) async throws -> Data? {
        try await request(
            path: "device-debug/v1/frame",
            queryItems: [URLQueryItem(name: "after", value: String(sequence))],
            allowNoContent: true,
            maximumBytes: 1_048_576
        )
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        data: Data?,
        maximumBytes: Int,
        invalidMessage: String
    ) throws -> T {
        guard let data,
              !data.isEmpty,
              data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                invalidMessage
            )
        }
        return value
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        allowNoContent: Bool = false,
        maximumBytes: Int = 262_144
    ) async throws -> Data? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url,
              url.scheme == "https",
              url.host == baseURL.host,
              url.port == baseURL.port else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The secure device endpoint could not be constructed."
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    "The secure device endpoint returned no HTTP status."
                )
            }
            if allowNoContent, response.statusCode == 204 { return nil }
            guard response.statusCode == 200 else {
                throw SecureRendererBenchmarkControllerError.httpStatus(
                    response.statusCode,
                    Self.safeErrorCode(data)
                )
            }
            guard data.count <= maximumBytes else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    "The secure device response exceeded its size limit."
                )
            }
            return data
        } catch let error as SecureRendererBenchmarkControllerError {
            throw error
        } catch {
            let value = error as NSError
            throw SecureRendererBenchmarkControllerError.network(
                value.domain,
                value.code
            )
        }
    }

    private static func safeErrorCode(_ data: Data) -> String? {
        guard data.count <= 2_048,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? String,
              !code.isEmpty,
              code.utf8.count <= 64,
              code.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { return nil }
        return code
    }
}

@MainActor
final class SecureRendererBenchmarkController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"
    @Published private(set) var completedRunCount = 0
    @Published private(set) var totalRunCount =
        SecureRendererBenchmarkPlan.totalComparisonRunCount + 1
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportURL: URL?
    @Published private(set) var automatedPassed: Bool?

    private weak var replay: RendererBenchmarkReplayCoordinator?
    private weak var bleManager: BLEManager?
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var client: SecureRendererBenchmarkHTTPClient?
    private var lastFrameSequence: UInt32 = 0
    private var screenshotEntries: [(String, Data)] = []
    private var previousIdleTimerDisabled: Bool?

    var progressDescription: String {
        guard isRunning else { return status }
        return "\(status) (\(completedRunCount)/\(totalRunCount))"
    }

    func start(
        bleManager: BLEManager,
        replay: RendererBenchmarkReplayCoordinator,
        isNavigationActive: Bool,
        bundle: Bundle = .main
    ) {
        guard !isRunning else { return }
        let deviceSession = RemoteDeviceDebugSessionPolicy.activeSession(
            bleManager: bleManager
        )
        let map = bleManager.activeDeviceMap
        let readiness = SecureRendererBenchmarkReadiness.blocker(
            for: SecureRendererBenchmarkReadinessInputs(
                isConnected: bleManager.isConnected,
                isNavigationReady: bleManager.isNavigationReady,
                supportsRendererDiagnostics:
                    bleManager.supportsRendererDiagnostics,
                isNavigationActive: isNavigationActive,
                hasSecureSession: deviceSession != nil,
                hasActiveMap: map != nil,
                hasManifestReceipt: map?.manifestReceipt != nil,
                hasMapBounds: map?.bounds != nil,
                storageBackend: bleManager.deviceStorageBackend,
                storagePowerCycleRequired:
                    bleManager.deviceStoragePowerCycleRequired,
                manualReplayIsRunning: replay.isRunning
            )
        )
        if let readiness {
            failStart(readiness.message)
            return
        }
        guard let deviceSession,
              let map,
              let mapReceipt = map.manifestReceipt,
              let mapBounds = map.bounds else {
            failStart(
                "The secure sweep readiness changed before it could start. Refresh and try again."
            )
            return
        }
        guard let client = SecureRendererBenchmarkHTTPClient(
            deviceSession: deviceSession
        ) else {
            failStart("The in-memory pinned HTTPS session is unavailable.")
            return
        }
        let mapFixture = RendererBenchmarkMapFixtureIdentity(
            id: map.mapID,
            sha256: mapReceipt
        )
        self.client = client
        self.replay = replay
        self.bleManager = bleManager
        stopRequested = false
        completedRunCount = 0
        totalRunCount = SecureRendererBenchmarkPlan.totalComparisonRunCount + 1
        screenshotEntries.removeAll(keepingCapacity: true)
        lastFrameSequence = 0
        errorMessage = nil
        exportURL = nil
        automatedPassed = nil
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        isRunning = true
        status = "Loading pinned inputs"
        task = Task { @MainActor [weak self] in
            await self?.run(
                deviceSession: deviceSession,
                mapFixture: mapFixture,
                mapBounds: mapBounds,
                bundle: bundle
            )
        }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        status = "Stopping and restoring Current"
    }

    private func failStart(_ message: String) {
        errorMessage = message
        status = "Unavailable"
        automatedPassed = nil
    }

    private func run(
        deviceSession: DeviceTransferSession,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        mapBounds: OfflineMapPreviewBounds,
        bundle: Bundle
    ) async {
        guard let client, let replay, let bleManager else {
            finishFailure("The benchmark controller lost its runtime state.")
            return
        }
        var cleanupRestoredCurrent = false
        var cleanupRouteFixture: RendererBenchmarkRouteFixtureIdentity?
        do {
            let routeLoaded = try RendererBenchmarkFixture.load(bundle: bundle)
            let gatesLoaded = try RendererBenchmarkGates.load(bundle: bundle)
            let routeHash = Self.sha256Hex(routeLoaded.sha256)
            guard routeLoaded.fixture.id == "shanghai-jingan-renderer-v1",
                  routeLoaded.fixture.cadenceHz == 1,
                  routeLoaded.fixture.points.count == 120,
                  routeHash ==
                    "bf3ad5176e188cb56ecdcedd9dea740dfa57487ea36eb50d2280668a96b7f0c9"
            else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "The checked-in Shanghai renderer fixture identity changed."
                )
            }
            guard routeLoaded.fixture.points.allSatisfy({ point in
                point.longitude >= mapBounds.minLongitude &&
                    point.longitude <= mapBounds.maxLongitude &&
                    point.latitude >= mapBounds.minLatitude &&
                    point.latitude <= mapBounds.maxLatitude
            }) else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "The active signed map does not cover the pinned Shanghai route."
                )
            }
            let routeFixture = RendererBenchmarkRouteFixtureIdentity(
                id: routeLoaded.fixture.id,
                sha256: routeHash,
                mode: SecureRendererBenchmarkPlan.routeMode
            )
            cleanupRouteFixture = routeFixture
            let gatesSHA256 = Self.sha256Hex(
                Data(SHA256.hash(data: gatesLoaded.data))
            )
            guard let currentAppIdentity = MapStreamAppBuildIdentity.current else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "Install a clean, exact-head Debug app build before collecting acceptance evidence."
                )
            }
            let appIdentity = RendererBenchmarkAppBuildIdentity(
                schemaVersion: currentAppIdentity.schemaVersion,
                build: currentAppIdentity.build,
                gitSha: currentAppIdentity.gitSha,
                componentSha256: currentAppIdentity.componentSha256
            )

            status = "Starting pinned 1 Hz replay"
            replay.start(
                bleManager: bleManager,
                isNavigationActive: false,
                bundle: bundle
            )
            guard replay.isRunning else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    replay.errorMessage ?? "The pinned 1 Hz replay could not start."
                )
            }
            try checkContinuity()
            status = "Validating exact device identity"
            let info = try await client.info()
            let initialMetrics = try await metricsWithRetry(client: client)
            let baseline = try validatePreflight(
                info: info,
                metrics: initialMetrics,
                storageBackend: bleManager.deviceStorageBackend,
                storagePowerCycleRequired:
                    bleManager.deviceStoragePowerCycleRequired
            )
            guard baseline.board == "WAVESHARE_AMOLED_175" ||
                    baseline.board == "WAVESHARE_AMOLED_206" else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    "The renderer benchmark target is unsupported."
                )
            }

            let rootRunID = Self.makeRootRunID()
            var runs: [RendererBenchmarkRunEvidence] = []
            for item in SecureRendererBenchmarkPlan.comparisonRuns() {
                try checkContinuity()
                let index = runs.count + 1
                status = "Run \(index)/\(SecureRendererBenchmarkPlan.totalComparisonRunCount): \(item.profile.title)"
                let evidence = try await executeRun(
                    client: client,
                    baseline: baseline,
                    profile: item.profile,
                    repeatNumber: item.repeatNumber,
                    durationSeconds: gatesLoaded.gates.comparisonDurationSeconds,
                    soak: false,
                    rootRunID: rootRunID,
                    mapFixture: mapFixture,
                    routeFixture: routeFixture,
                    expectedRouteSampleCount: routeLoaded.fixture.points.count,
                    gates: gatesLoaded.gates
                )
                runs.append(evidence)
                completedRunCount = runs.count
            }
            RendererBenchmarkEvaluator.applyCrossRunMemoryGates(
                runs: &runs,
                gates: gatesLoaded.gates
            )
            let aggregate = RendererBenchmarkEvaluator.aggregate(runs: runs)
            let selection = RendererBenchmarkEvaluator.selectCandidate(
                aggregate: aggregate,
                gates: gatesLoaded.gates
            )
            var soakRun: RendererBenchmarkRunEvidence?
            if let selectedName = selection.selected,
               let selected = RendererBenchmarkProfile(wireName: selectedName) {
                status = "300-second soak: \(selected.title)"
                soakRun = try await executeRun(
                    client: client,
                    baseline: baseline,
                    profile: selected,
                    repeatNumber:
                        SecureRendererBenchmarkPlan.comparisonRepeats + 1,
                    durationSeconds:
                        SecureRendererBenchmarkPlan.soakDurationSeconds,
                    soak: true,
                    rootRunID: rootRunID,
                    mapFixture: mapFixture,
                    routeFixture: routeFixture,
                    expectedRouteSampleCount: routeLoaded.fixture.points.count,
                    gates: gatesLoaded.gates
                )
                completedRunCount = totalRunCount
            }

            status = "Restoring Current profile"
            cleanupRestoredCurrent = await restoreCurrentProfile(
                client: client,
                rootRunID: rootRunID,
                mapFixture: mapFixture,
                routeFixture: routeFixture
            )
            replay.stop(clearRoute: true, restoreCurrent: false)
            let passed = runs.allSatisfy(\.passed) &&
                soakRun?.passed == true && cleanupRestoredCurrent
            let report = SecureRendererBenchmarkEvidenceReport(
                schema: 1,
                source: "bicino-debug-secure-sweep-v1",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                appIdentity: appIdentity,
                identity: baseline,
                mapFixture: mapFixture,
                routeFixture: routeFixture,
                gatesSHA256: gatesSHA256,
                gates: gatesLoaded.gates,
                schedule: SecureRendererBenchmarkPlan.balancedSchedule().map {
                    $0.map(\.wireName)
                },
                runs: runs,
                aggregate: aggregate,
                selection: selection,
                soakRun: soakRun,
                cleanupRestoredCurrent: cleanupRestoredCurrent,
                automatedPassed: passed,
                remainingPhysicalGates: [
                    "AMOLED motion, tearing, color, and brightness",
                    "daylight usefulness versus 3D clutter",
                    "physical capacitive touch",
                    "natural Core Location and BLE jitter ride",
                    "battery and thermal impact",
                    "full-power-cycle SDMMC and repeated iPhone authentication",
                    "Waveshare board-family physical acceptance",
                ]
            )
            status = "Exporting secret-free evidence"
            exportURL = try exportEvidence(
                report: report,
                forbiddenValues: [
                    deviceSession.sessionToken ?? "",
                    deviceSession.baseURL.absoluteString,
                    deviceSession.tlsCertificateSHA256,
                    deviceSession.accessPointPassphrase ?? "",
                ]
            )
            automatedPassed = passed
            status = passed ? "Automated gates passed" : "Evidence exported with failures"
            errorMessage = passed ? nil :
                "One or more automated gates failed; review the exported report."
        } catch {
            if !cleanupRestoredCurrent {
                status = "Restoring Current profile"
                cleanupRestoredCurrent = await restoreCurrentProfile(
                    client: client,
                    rootRunID: Self.makeRootRunID(),
                    mapFixture: mapFixture,
                    routeFixture: cleanupRouteFixture
                )
            }
            replay.stop(clearRoute: true, restoreCurrent: false)
            automatedPassed = false
            let message = (error as? LocalizedError)?.errorDescription ??
                "The secure renderer benchmark failed."
            errorMessage = cleanupRestoredCurrent ? message :
                message + " Current-profile cleanup was not confirmed."
            status = stopRequested ? "Stopped" : "Failed"
        }
        client.invalidate()
        self.client = nil
        self.bleManager = nil
        self.replay = nil
        restoreIdleTimer()
        task = nil
        isRunning = false
        stopRequested = false
    }

    private func validatePreflight(
        info: RendererBenchmarkDeviceInfo,
        metrics: RendererBenchmarkMetricsSnapshot,
        storageBackend: String?,
        storagePowerCycleRequired: Bool?
    ) throws -> RendererBenchmarkEvidenceIdentity {
        let expectedGeometry: [String: (Int, Int, Int)] = [
            "WAVESHARE_AMOLED_175": (466, 466, 1),
            "WAVESHARE_AMOLED_206": (410, 502, 0),
        ]
        guard let geometry = expectedGeometry[info.target],
              info.ok,
              info.schema == 1,
              info.session.active,
              info.session.mode == "debug",
              info.width == geometry.0,
              info.height == geometry.1,
              info.viewRotation == geometry.2,
              info.pixelFormat == "rgb565le",
              info.deviceId.utf8.count == 16,
              Self.isLowercaseHex(info.deviceId, count: 16),
              info.firmware.target == info.target,
              Self.isLowercaseHex(info.firmware.gitSha, count: 40),
              !info.firmware.version.isEmpty,
              info.buildProfile == "\(info.target)_REMOTE_DEBUG",
              metrics.ok,
              metrics.schema == 1,
              metrics.identity.deviceId == info.deviceId,
              metrics.identity.firmwareCommit == info.firmware.gitSha,
              metrics.identity.board == info.target,
              metrics.identity.buildProfile == info.buildProfile,
              storageBackend == "sdmmc",
              storagePowerCycleRequired == false,
              metrics.remoteDebug.active else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The secure endpoint did not prove an exact remote-debug build and boot identity."
            )
        }
        return RendererBenchmarkEvidenceIdentity(
            deviceId: info.deviceId,
            firmwareCommit: info.firmware.gitSha,
            firmwareVersion: info.firmware.version,
            firmwareBuild: info.firmware.build,
            board: info.target,
            buildProfile: info.buildProfile,
            storageBackend: storageBackend ?? "",
            storagePowerCycleRequired: storagePowerCycleRequired ?? true,
            bootId: metrics.identity.bootId,
            resetReason: metrics.identity.resetReason
        )
    }

    private func executeRun(
        client: SecureRendererBenchmarkHTTPClient,
        baseline: RendererBenchmarkEvidenceIdentity,
        profile: RendererBenchmarkProfile,
        repeatNumber: Int,
        durationSeconds: Int,
        soak: Bool,
        rootRunID: String,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity,
        expectedRouteSampleCount: Int,
        gates: RendererBenchmarkGates
    ) async throws -> RendererBenchmarkRunEvidence {
        let runKind = soak ? "s" : "r"
        let runID = "\(rootRunID)-\(runKind)-\(profile.wireName.first!)-\(repeatNumber)"
        try await warmUp(
            client: client,
            profile: profile,
            repeatNumber: repeatNumber,
            runID: "\(rootRunID)-w-\(profile.wireName.first!)-\(repeatNumber)",
            mapFixture: mapFixture,
            routeFixture: routeFixture,
            gates: gates
        )
        let windowID = try await client.beginWindow(
            profile: profile,
            runId: runID,
            repeatNumber: repeatNumber,
            mapFixture: mapFixture,
            routeFixture: routeFixture
        )
        _ = try await waitForWindow(
            client: client,
            windowID: windowID,
            runID: runID,
            repeatNumber: repeatNumber,
            profile: profile,
            timeoutSeconds: 10
        )
        let checkpoints = SecureRendererBenchmarkPlan.checkpointIndexes(
            sampleCount: expectedRouteSampleCount,
            fractions: gates.checkpointFractions
        )
        var pending = Set(checkpoints)
        var screenshots: [RendererBenchmarkScreenshotEvidence] = []
        var snapshots: [RendererBenchmarkMetricsSnapshot] = []
        var samples: [RendererBenchmarkEvidenceSample] = []
        var failures: [String] = []
        var previousSequence: UInt32?
        var previousTimestamp: UInt32?
        let started = Date()
        while Date().timeIntervalSince(started) < Double(durationSeconds) {
            try checkContinuity()
            let snapshot = try await metricsWithRetry(client: client)
            let identityFailures = RendererBenchmarkEvaluator.identityFailures(
                snapshot: snapshot,
                baseline: baseline,
                profile: profile,
                runId: runID,
                repeatNumber: repeatNumber,
                mapFixture: mapFixture,
                routeFixture: routeFixture,
                windowId: windowID
            )
            guard identityFailures.isEmpty else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    identityFailures.joined(separator: ", ")
                )
            }
            if let previousSequence {
                let delta = snapshot.sequence &- previousSequence
                guard delta != 0, delta < 0x8000_0000 else {
                    throw SecureRendererBenchmarkControllerError.invalidResponse(
                        "Renderer metrics sequence regressed or repeated."
                    )
                }
            }
            if let previousTimestamp {
                let delta = snapshot.timestampMs &- previousTimestamp
                guard delta != 0, delta < 0x8000_0000 else {
                    throw SecureRendererBenchmarkControllerError.invalidResponse(
                        "Device uptime regressed or repeated during the sweep."
                    )
                }
            }
            previousSequence = snapshot.sequence
            previousTimestamp = snapshot.timestampMs
            let elapsed = Date().timeIntervalSince(started)
            snapshots.append(snapshot)
            samples.append(RendererBenchmarkEvaluator.sample(
                snapshot: snapshot,
                elapsedSeconds: elapsed
            ))
            if snapshot.routeReplay.valid,
               snapshot.routeReplay.fixtureMatches,
               snapshot.routeReplay.sampleCount == expectedRouteSampleCount {
                for checkpoint in pending.sorted() where
                    SecureRendererBenchmarkPlan.circularSampleDistance(
                        snapshot.routeReplay.sampleIndex,
                        checkpoint,
                        count: expectedRouteSampleCount
                    ) <= gates.checkpointToleranceSamples {
                    do {
                        screenshots.append(try await captureScreenshot(
                            client: client,
                            profile: profile,
                            repeatNumber: repeatNumber,
                            checkpoint: checkpoint,
                            routeReplay: snapshot.routeReplay,
                            baseline: baseline,
                            gates: gates
                        ))
                    } catch {
                        failures.append(
                            (error as? LocalizedError)?.errorDescription ??
                                "checkpoint_screenshot_failed"
                        )
                    }
                    pending.remove(checkpoint)
                }
            }
            let remaining = Double(durationSeconds) -
                Date().timeIntervalSince(started)
            if remaining > 0 {
                try await pause(
                    seconds: min(gates.pollIntervalSeconds, remaining)
                )
            }
        }
        guard let summary = RendererBenchmarkEvaluator.summary(
            snapshots: snapshots,
            samples: samples
        ), let finalSnapshot = snapshots.last else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The benchmark window produced no renderer metrics."
            )
        }
        failures += RendererBenchmarkEvaluator.evaluate(
            snapshots: snapshots,
            samples: samples,
            summary: summary,
            durationSeconds: durationSeconds,
            screenshotCount: screenshots.count,
            checkpointCount: checkpoints.count,
            expectedRouteSampleCount: expectedRouteSampleCount,
            gates: gates
        )
        let postInfo = try await client.info()
        if postInfo.deviceId != baseline.deviceId ||
            postInfo.firmware.gitSha != baseline.firmwareCommit ||
            postInfo.buildProfile != baseline.buildProfile {
            failures.append("device_reset_or_replaced")
        }
        failures = Array(Set(failures)).sorted()
        return RendererBenchmarkRunEvidence(
            schema: 1,
            runId: runID,
            windowId: windowID,
            profile: profile.wireName,
            repeatNumber: repeatNumber,
            durationSeconds: durationSeconds,
            soak: soak,
            passed: failures.isEmpty,
            failures: failures,
            summary: summary,
            samples: samples,
            screenshots: screenshots,
            finalSnapshot: finalSnapshot
        )
    }

    private func warmUp(
        client: SecureRendererBenchmarkHTTPClient,
        profile: RendererBenchmarkProfile,
        repeatNumber: Int,
        runID: String,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity,
        gates: RendererBenchmarkGates
    ) async throws {
        let windowID = try await client.beginWindow(
            profile: profile,
            runId: runID,
            repeatNumber: repeatNumber,
            mapFixture: mapFixture,
            routeFixture: routeFixture
        )
        _ = try await waitForWindow(
            client: client,
            windowID: windowID,
            runID: runID,
            repeatNumber: repeatNumber,
            profile: profile,
            timeoutSeconds: 10
        )
        let markerDeadline = Date().addingTimeInterval(12)
        var markerConfirmed = false
        while Date() < markerDeadline {
            try checkContinuity()
            let snapshot = try await metricsWithRetry(client: client)
            if snapshot.routeReplay.valid && snapshot.routeReplay.fixtureMatches {
                markerConfirmed = true
                break
            }
            try await pause(seconds: 0.5)
        }
        guard markerConfirmed else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The device did not confirm the in-app 1 Hz route marker."
            )
        }
        let warmDeadline = Date().addingTimeInterval(
            Double(gates.warmupSeconds)
        )
        while Date() < warmDeadline {
            try checkContinuity()
            _ = try await metricsWithRetry(client: client)
            try await pause(seconds: min(
                gates.pollIntervalSeconds,
                max(warmDeadline.timeIntervalSinceNow, 0)
            ))
        }
    }

    private func waitForWindow(
        client: SecureRendererBenchmarkHTTPClient,
        windowID: UInt32,
        runID: String,
        repeatNumber: Int,
        profile: RendererBenchmarkProfile,
        timeoutSeconds: TimeInterval,
        enforceContinuity: Bool = true
    ) async throws -> RendererBenchmarkMetricsSnapshot {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if enforceContinuity { try checkContinuity() }
            let snapshot = try await metricsWithRetry(
                client: client,
                timeoutSeconds: min(2, max(deadline.timeIntervalSinceNow, 0.1)),
                enforceContinuity: enforceContinuity
            )
            if snapshot.window.id == windowID,
               snapshot.window.runId == runID,
               snapshot.window.repeatNumber == repeatNumber,
               snapshot.tuning.profile == profile.wireName {
                return snapshot
            }
            try await pause(seconds: 0.35)
        }
        throw SecureRendererBenchmarkControllerError.invalidResponse(
            "The device did not apply the requested renderer window."
        )
    }

    private func metricsWithRetry(
        client: SecureRendererBenchmarkHTTPClient,
        timeoutSeconds: TimeInterval = 5,
        enforceContinuity: Bool = true
    ) async throws -> RendererBenchmarkMetricsSnapshot {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        repeat {
            if enforceContinuity { try checkContinuity() }
            do {
                return try await client.metrics()
            } catch {
                lastError = error
                if Date() < deadline { try await pause(seconds: 0.3) }
            }
        } while Date() < deadline
        throw lastError ?? SecureRendererBenchmarkControllerError.invalidResponse(
            "Renderer metrics became unavailable."
        )
    }

    private func captureScreenshot(
        client: SecureRendererBenchmarkHTTPClient,
        profile: RendererBenchmarkProfile,
        repeatNumber: Int,
        checkpoint: Int,
        routeReplay: RendererBenchmarkMetricsSnapshot.RouteReplay,
        baseline: RendererBenchmarkEvidenceIdentity,
        gates: RendererBenchmarkGates
    ) async throws -> RendererBenchmarkScreenshotEvidence {
        let geometry = baseline.board == "WAVESHARE_AMOLED_175"
            ? (width: 466, height: 466, rotation: 1)
            : (width: 410, height: 502, rotation: 0)
        let deadline = Date().addingTimeInterval(4)
        var consumedCachedFrame = false
        var lastError: Error?
        while Date() < deadline {
            try checkContinuity()
            do {
                guard let data = try await client.frame(after: lastFrameSequence) else {
                    try await pause(seconds: 0.25)
                    continue
                }
                let decoded = try RendererBenchmarkFrameDecoder.decode(
                    data,
                    expectedPanelWidth: geometry.width,
                    expectedPanelHeight: geometry.height,
                    rotationQuarters: geometry.rotation
                )
                lastFrameSequence = decoded.sequence
                if !consumedCachedFrame {
                    consumedCachedFrame = true
                    continue
                }
                let lag = decoded.capturedAtMs &- routeReplay.receivedAtMs
                guard lag < 0x8000_0000,
                      lag <= gates.absolute.maximumRouteMarkerAgeMs else {
                    throw SecureRendererBenchmarkControllerError.invalidResponse(
                        "A checkpoint frame missed its route-marker window."
                    )
                }
                guard let png = Self.pngData(decoded) else {
                    throw SecureRendererBenchmarkControllerError.invalidResponse(
                        "A checkpoint frame could not be encoded as PNG."
                    )
                }
                let path = String(format:
                    "screenshots/%@-repeat-%02d-checkpoint-%03d-sample-%03d.png",
                    profile.wireName,
                    repeatNumber,
                    checkpoint,
                    routeReplay.sampleIndex
                )
                screenshotEntries.append((path, png))
                return RendererBenchmarkScreenshotEvidence(
                    checkpointSampleIndex: checkpoint,
                    observedSampleIndex: routeReplay.sampleIndex,
                    frameSequence: decoded.sequence,
                    capturedAtMs: decoded.capturedAtMs,
                    markerReceivedAtMs: routeReplay.receivedAtMs,
                    captureLagMs: lag,
                    path: path,
                    bytes: png.count,
                    sha256: Self.sha256Hex(Data(SHA256.hash(data: png)))
                )
            } catch {
                lastError = error
                try await pause(seconds: 0.25)
            }
        }
        throw lastError ?? SecureRendererBenchmarkControllerError.invalidResponse(
            "A checkpoint frame was unavailable."
        )
    }

    private func restoreCurrentProfile(
        client: SecureRendererBenchmarkHTTPClient,
        rootRunID: String,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity?
    ) async -> Bool {
        guard let routeFixture else { return false }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            do {
                let runID = "\(rootRunID)-cleanup"
                let windowID = try await client.beginWindow(
                    profile: .current,
                    runId: runID,
                    repeatNumber: 1,
                    mapFixture: mapFixture,
                    routeFixture: routeFixture
                )
                _ = try await waitForWindow(
                    client: client,
                    windowID: windowID,
                    runID: runID,
                    repeatNumber: 1,
                    profile: .current,
                    timeoutSeconds: 1.5,
                    enforceContinuity: false
                )
                return true
            } catch {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        return false
    }

    private func checkContinuity() throws {
        guard !stopRequested else {
            throw SecureRendererBenchmarkControllerError.stopped
        }
        guard let replay, replay.isRunning,
              let bleManager,
              bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics,
              bleManager.deviceStorageBackend == "sdmmc",
              bleManager.deviceStoragePowerCycleRequired == false,
              RemoteDeviceDebugSessionPolicy.activeSession(
                bleManager: bleManager
              ) != nil else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The authenticated replay or secure debug session ended."
            )
        }
    }

    private func pause(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(
            nanoseconds: UInt64(min(seconds, 60) * 1_000_000_000)
        )
    }

    private func exportEvidence(
        report: SecureRendererBenchmarkEvidenceReport,
        forbiddenValues: [String]
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        guard RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
            jsonData: reportData
        ) else {
            throw SecureRendererBenchmarkProtocolError.invalidEvidence
        }
        var entries = screenshotEntries
        entries.append(("renderer-benchmark.json", reportData))
        entries.append(("renderer-benchmark.csv", Self.csvData(report)))
        entries.append(("renderer-benchmark.md", Self.markdownData(report)))
        entries.sort { $0.0 < $1.0 }
        try Self.validateTextEvidence(entries, forbiddenValues: forbiddenValues)

        let files = entries.map { path, data in
            [
                "path": path,
                "bytes": data.count,
                "sha256": Self.sha256Hex(Data(SHA256.hash(data: data))),
            ] as [String: Any]
        }
        let manifestObject: [String: Any] = [
            "schema": 1,
            "kind": "bicino-renderer-benchmark-evidence",
            "automatedPassed": report.automatedPassed,
            "files": files,
        ]
        let manifest = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        guard RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
            jsonData: manifest
        ) else {
            throw SecureRendererBenchmarkProtocolError.invalidEvidence
        }
        entries.append(("manifest.json", manifest))
        let checksumText = entries.sorted { $0.0 < $1.0 }.map { path, data in
            "\(Self.sha256Hex(Data(SHA256.hash(data: data))))  \(path)"
        }.joined(separator: "\n") + "\n"
        entries.append(("checksums.sha256", Data(checksumText.utf8)))
        try Self.validateTextEvidence(entries, forbiddenValues: forbiddenValues)
        entries.sort { $0.0 < $1.0 }

        let nonce = UUID().uuidString.prefix(8).lowercased()
        let filename =
            "Bicino-Renderer-Benchmark-\(Int(Date().timeIntervalSince1970))-\(nonce).zip"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            filename,
            isDirectory: false
        )
        try RideDiagnosticsStoredZipWriter.write(entries: entries, to: url)
        return url
    }

    private static func validateTextEvidence(
        _ entries: [(String, Data)],
        forbiddenValues: [String]
    ) throws {
        let forbidden = forbiddenValues.filter { !$0.isEmpty }.map { Data($0.utf8) }
        for (path, data) in entries where
            path.hasSuffix(".json") || path.hasSuffix(".csv") ||
                path.hasSuffix(".md") || path.hasSuffix(".sha256") {
            if forbidden.contains(where: { data.range(of: $0) != nil }) {
                throw SecureRendererBenchmarkProtocolError.invalidEvidence
            }
        }
    }

    private static func csvData(
        _ report: SecureRendererBenchmarkEvidenceReport
    ) -> Data {
        let header = [
            "runId", "profile", "repeat", "durationSeconds", "soak", "passed",
            "failures", "renderP95Ms", "uiMaximumGapMs", "flushP95Ms",
            "minimumInternalFree", "minimumInternalLargest", "minimumPsramFree",
            "minimumPsramLargest", "minimumDmaFree", "minimumDmaLargest",
            "cryptoHeadroomRejections", "cryptoOperationFailures",
        ]
        let rows = report.runs + (report.soakRun.map { [$0] } ?? [])
        let lines = [header] + rows.map { run in
            let summary = run.summary
            return [
                run.runId, run.profile, String(run.repeatNumber),
                String(run.durationSeconds), String(run.soak), String(run.passed),
                run.failures.joined(separator: ";"), String(summary.renderP95Ms),
                String(summary.uiMaximumGapMs), String(summary.flushP95Ms),
                String(summary.minimumInternalFree),
                String(summary.minimumInternalLargest),
                String(summary.minimumPsramFree), String(summary.minimumPsramLargest),
                String(summary.minimumDmaFree), String(summary.minimumDmaLargest),
                String(summary.cryptoHeadroomRejections),
                String(summary.cryptoOperationFailures),
            ]
        }
        return Data((lines.map { row in
            row.map(Self.csvField).joined(separator: ",")
        }.joined(separator: "\n") + "\n").utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") ||
                value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func markdownData(
        _ report: SecureRendererBenchmarkEvidenceReport
    ) -> Data {
        var lines = [
            "# Secure renderer benchmark",
            "",
            "- Automated gates: \(report.automatedPassed ? "passed" : "failed")",
            "- iOS commit/component: `\(report.appIdentity.gitSha)` / `\(report.appIdentity.componentSha256)`",
            "- Firmware commit: `\(report.identity.firmwareCommit)`",
            "- Target/profile: `\(report.identity.board)` / `\(report.identity.buildProfile)`",
            "- Storage: `\(report.identity.storageBackend)` / power-cycle required: \(report.identity.storagePowerCycleRequired)",
            "- Map: `\(report.mapFixture.id)` (`\(report.mapFixture.sha256)`)",
            "- Route: `\(report.routeFixture.id)` (`\(report.routeFixture.sha256)`)",
            "- Selected soak profile: `\(report.selection.selected ?? "none")`",
            "- Current profile restored: \(report.cleanupRestoredCurrent ? "yes" : "no")",
            "",
            "| Profile | Repeat | Kind | Result | Render p95 | DMA minimum | Crypto rejects | Crypto failures |",
            "|---|---:|---|---|---:|---:|---:|---:|",
        ]
        for run in report.runs + (report.soakRun.map { [$0] } ?? []) {
            lines.append(
                "| \(run.profile) | \(run.repeatNumber) | \(run.soak ? "soak" : "comparison") | \(run.passed ? "pass" : "fail") | \(run.summary.renderP95Ms) | \(run.summary.minimumDmaFree) | \(run.summary.cryptoHeadroomRejections) | \(run.summary.cryptoOperationFailures) |"
            )
        }
        lines += ["", "Physical acceptance remains required.", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func pngData(
        _ frame: RendererBenchmarkDecodedFrame
    ) -> Data? {
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let image = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    private static func makeRootRunID() -> String {
        let epoch = String(UInt64(Date().timeIntervalSince1970), radix: 16)
        let nonce = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(6)
        return "rb-\(epoch)-\(nonce)"
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func finishFailure(_ message: String) {
        client?.invalidate()
        client = nil
        restoreIdleTimer()
        task = nil
        errorMessage = message
        automatedPassed = false
        status = "Failed"
        isRunning = false
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }
}
#endif
