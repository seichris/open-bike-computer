#if DEBUG
import Combine
import CryptoKit
import Foundation
import UIKit

private enum SecureRendererBenchmarkControllerError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case httpStatus(Int, String?)
    case network(String, String, Int)
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message):
            return message
        case .httpStatus(let status, let code):
            return "The secure device endpoint returned HTTP \(status)" +
                (code.map { " (\($0))" } ?? "") + "."
        case .network(let path, let domain, let code):
            return "The secure device request failed at /\(path) " +
                "(\(domain) \(code))."
        case .stopped:
            return "The secure renderer benchmark was stopped."
        }
    }
}

private final class SecureRendererBenchmarkHTTPClient: @unchecked Sendable {
    private static let tokenHeader = "X-BikeComputer-Transfer-Token"
    private let baseURL: URL
    private let token: String
    private let certificateSHA256: String
    private var session: URLSession?

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
        guard let session = Self.makeSession(
            baseURL: deviceSession.baseURL,
            certificateSHA256: deviceSession.tlsCertificateSHA256
        ) else { return nil }
        baseURL = deviceSession.baseURL
        self.token = token
        certificateSHA256 = deviceSession.tlsCertificateSHA256
        self.session = session
    }

    private static func makeSession(
        baseURL: URL,
        certificateSHA256: String
    ) -> URLSession? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest =
            SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout
        configuration.timeoutIntervalForResource =
            SecureRendererBenchmarkHTTPPolicy.resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        return DeviceTransferPinnedSessionFactory.make(
            configuration: configuration,
            baseURL: baseURL,
            certificateSHA256: certificateSHA256
        )
    }

    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
    }

    @discardableResult
    private func renewPinnedSession() -> Bool {
        session?.invalidateAndCancel()
        session = Self.makeSession(
            baseURL: baseURL,
            certificateSHA256: certificateSHA256
        )
        return session != nil
    }

    func info() async throws -> RendererBenchmarkDeviceInfo {
        try await decodeJSON(
            RendererBenchmarkDeviceInfo.self,
            data: request(path: "device-debug/v1/info"),
            maximumBytes: 65_536,
            invalidMessage: "The device returned invalid benchmark identity."
        )
    }

    func metrics(
        timeoutInterval: TimeInterval =
            SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout
    ) async throws -> RendererBenchmarkMetricsSnapshot {
        try await decodeJSON(
            RendererBenchmarkMetricsSnapshot.self,
            data: request(
                path: "device-debug/v1/metrics",
                timeoutInterval: timeoutInterval
            ),
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
        let body = try RendererBenchmarkWindowWireContract.requestData(
            profile: profile.wireName,
            runId: runId,
            repeatNumber: repeatNumber,
            mapFixture: mapFixture,
            routeFixture: routeFixture
        )
        let response = try await request(
            path: "device-debug/v1/metrics/window",
            method: "POST",
            body: body,
            acceptedStatusCode:
                RendererBenchmarkWindowWireContract.acceptedStatusCode,
            maximumBytes: 4_096
        )
        guard let response,
              let requestID = RendererBenchmarkWindowWireContract.requestID(
                from: response
              ) else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The device returned an invalid benchmark-window response."
            )
        }
        return requestID
    }

    func frame(
        after sequence: UInt32,
        capturedAtOrAfter timestampMs: UInt32,
        timeoutInterval: TimeInterval =
            SecureRendererBenchmarkHTTPPolicy.frameRequestTimeout
    ) async throws -> Data? {
        try await request(
            path: "device-debug/v1/frame",
            queryItems: [
                URLQueryItem(name: "after", value: String(sequence)),
                URLQueryItem(
                    name: "capturedAtOrAfter",
                    value: String(timestampMs)
                ),
            ],
            allowNoContent: true,
            maximumBytes: 1_048_576,
            timeoutInterval: timeoutInterval
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
        acceptedStatusCode: Int = 200,
        maximumBytes: Int = 262_144,
        timeoutInterval: TimeInterval =
            SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout
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
        request.timeoutInterval = timeoutInterval
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        SecureRendererBenchmarkHTTPPolicy.enableConnectionReuse(on: &request)
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            guard let session else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "The in-memory pinned HTTPS session is unavailable."
                )
            }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    "The secure device endpoint returned no HTTP status."
                )
            }
            if allowNoContent, response.statusCode == 204 { return nil }
            guard response.statusCode == acceptedStatusCode else {
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
            let renewed = renewPinnedSession()
            print(
                "Secure renderer transport renewed path=/\(path) " +
                "domain=\(value.domain) code=\(value.code) " +
                "ready=\(renewed)"
            )
            throw SecureRendererBenchmarkControllerError.network(
                path,
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
    private var profileMayNeedRestoration = false
    private var expectedSession: DeviceTransferSession?
    private var lastMeasuredSnapshot: RendererBenchmarkMetricsSnapshot?
    private var partialSamples: [RendererBenchmarkEvidenceSample] = []
    private var startupTrace = RendererBenchmarkStartupTrace()
    private var collectingStartupEvidence = false

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
                supportsRendererBenchmarkSample:
                    bleManager.supportsRendererBenchmarkSample,
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
        expectedSession = deviceSession
        lastMeasuredSnapshot = nil
        partialSamples = []
        startupTrace = RendererBenchmarkStartupTrace()
        collectingStartupEvidence = true
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
        profileMayNeedRestoration = false
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

    func stop(clearRoute: Bool = true) {
        guard isRunning else { return }
        captureStartupEvidence(phase: "stop_requested")
        stopRequested = true
        // Stop GPS immediately; HTTPS cleanup may take several seconds.
        replay?.stop(clearRoute: clearRoute, restoreCurrent: false)
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
        var runs: [RendererBenchmarkRunEvidence] = []
        let forbiddenValues = [
            deviceSession.sessionToken ?? "",
            deviceSession.baseURL.absoluteString,
            deviceSession.tlsCertificateSHA256,
            deviceSession.accessPointPassphrase ?? "",
        ]
        do {
            let routeLoaded = try RendererBenchmarkFixture.load(bundle: bundle)
            let gatesLoaded = try RendererBenchmarkGates.load(bundle: bundle)
            let routeHash = Self.sha256Hex(routeLoaded.sha256)
            guard routeLoaded.fixture.id == "shanghai-jingan-renderer-v1",
                  routeLoaded.fixture.cadenceHz == 1,
                  routeLoaded.fixture.points.count == 120,
                  routeHash ==
                    "0fec6228e89cdb6841b971226c5fdedcc5e711dcb9b0e72bcaf95da4f6452f64"
            else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "The checked-in Shanghai renderer fixture identity changed."
                )
            }
            guard let routeCoverage = RendererBenchmarkRouteCoverage(
                fixture: routeLoaded.fixture,
                mapBounds: mapBounds
            ) else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "The checked-in Shanghai renderer fixture has invalid bounds."
                )
            }
            guard routeCoverage.coversEntireRoute else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    routeCoverage.failureDescription(mapBounds: mapBounds)
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

            try checkSecureSessionContinuity()
            status = "Settling authenticated BLE setup"
            guard await bleManager.waitForNavigationWritesToDrain(
                timeoutSeconds: 15
            ) else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    "Authenticated BLE setup traffic did not settle before the benchmark."
                )
            }
            try checkSecureSessionContinuity()
            status = "Validating exact device identity"
            let info = try await client.info()
            let initialMetrics = try await metricsWithRetry(
                client: client,
                enforceContinuity: false
            )
            try checkSecureSessionContinuity()
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

            // Prove the HTTP window and fixtures before emitting any GPS/marker.
            let rootRunID = Self.makeRootRunID()
            let setupRunID = "\(rootRunID)-setup"
            status = "Opening and verifying measurement window"
            let setupWindowID = try await beginTrackedWindow(
                client: client, profile: .current, runId: setupRunID,
                repeatNumber: 1, mapFixture: mapFixture,
                routeFixture: routeFixture
            )
            let setupSnapshot = try await waitForWindow(
                client: client, windowID: setupWindowID, runID: setupRunID,
                repeatNumber: 1, profile: .current, timeoutSeconds: 10,
                enforceContinuity: false
            )
            try checkSecureSessionContinuity()
            let setupFailures = RendererBenchmarkEvaluator.identityFailures(
                snapshot: setupSnapshot, baseline: baseline, profile: .current,
                runId: setupRunID, repeatNumber: 1, mapFixture: mapFixture,
                routeFixture: routeFixture, windowId: setupWindowID
            )
            guard setupFailures.isEmpty else {
                throw SecureRendererBenchmarkControllerError.invalidResponse(
                    setupFailures.joined(separator: ", ")
                )
            }
            lastMeasuredSnapshot = setupSnapshot
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
                partialSamples = []
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
                forbiddenValues: forbiddenValues
            )
            automatedPassed = passed
            status = passed ? "Automated gates passed" : "Evidence exported with failures"
            errorMessage = passed ? nil :
                "One or more automated gates failed; review the exported report."
        } catch {
            captureStartupEvidence(phase: "failure_before_cleanup")
            if profileMayNeedRestoration {
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
            errorMessage = profileMayNeedRestoration ?
                message + " Current-profile cleanup was not confirmed." : message
            status = stopRequested ? "Stopped" : "Failed"
            do {
                let interrupted = RendererBenchmarkInterruptedEvidence(
                    schema: 1, source: "bicino-debug-secure-sweep-interrupted-v1",
                    automatedPassed: false, stopped: stopRequested,
                    reason: errorMessage ?? message,
                    cleanupRestoredCurrent: cleanupRestoredCurrent,
                    completedRuns: runs, partialSamples: partialSamples,
                    lastSnapshot: lastMeasuredSnapshot
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                exportURL = try exportArchive(
                    entries: screenshotEntries + [
                        ("renderer-benchmark-interrupted.json",
                         try encoder.encode(interrupted)),
                    ],
                    automatedPassed: false, forbiddenValues: forbiddenValues
                )
                status += " — partial evidence available"
            } catch {
                errorMessage = (errorMessage ?? message) +
                    " Partial evidence could not be exported safely."
            }
        }
        client.invalidate()
        self.client = nil
        expectedSession = nil
        self.bleManager = nil
        self.replay = nil
        restoreIdleTimer()
        task = nil
        isRunning = false
        stopRequested = false
        profileMayNeedRestoration = false
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
        let windowID = try await beginTrackedWindow(
            client: client,
            profile: profile,
            runId: runID,
            repeatNumber: repeatNumber,
            mapFixture: mapFixture,
            routeFixture: routeFixture
        )
        let initialSnapshot = try await waitForWindow(
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
        partialSamples = []
        var failures: [String] = []
        var previousSequence: UInt32? = initialSnapshot.sequence
        var previousTimestamp: UInt32? = initialSnapshot.timestampMs
        let started = Date()
        func record(
            _ snapshot: RendererBenchmarkMetricsSnapshot,
            captureCheckpoints: Bool = true
        ) async throws {
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
                elapsedSeconds: elapsed,
                bleTransport:
                    self.bleManager?.rendererBenchmarkBLETransportEvidence(),
                replayTiming:
                    self.replay?.rendererBenchmarkReplayTimingEvidence()
            ))
            lastMeasuredSnapshot = snapshot
            partialSamples = samples
            if captureCheckpoints,
               snapshot.routeReplay.valid,
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
        }
        while Date().timeIntervalSince(started) < Double(durationSeconds) {
            try checkContinuity()
            try await record(try await metricsWithRetry(client: client))
            let remaining = Double(durationSeconds) -
                Date().timeIntervalSince(started)
            if remaining > 0 {
                try await pause(
                    seconds: min(gates.pollIntervalSeconds, remaining)
                )
            }
        }
        // A blocking checkpoint-frame response can cross the window deadline.
        // Always collect one terminal snapshot so cadence, job, memory, and
        // crypto counters include the complete measurement interval.
        try checkContinuity()
        let pendingBeforeTerminalSnapshot = pending.count
        try await record(try await metricsWithRetry(client: client))
        if pending.count < pendingBeforeTerminalSnapshot {
            // A terminal checkpoint frame extends the window. Capture final
            // cadence, memory, job, and crypto counters after that response.
            try checkContinuity()
            try await record(
                try await metricsWithRetry(client: client),
                captureCheckpoints: false
            )
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
        collectingStartupEvidence = true
        captureStartupEvidence(phase: "opening_\(profile.wireName)_warmup")
        let windowID = try await beginTrackedWindow(
            client: client,
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
        status = "Warm-up: waiting for 1 Hz marker (\(profile.title))"
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
        status = "Warming up \(profile.title)"
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
        collectingStartupEvidence = false
        status = "Measuring \(profile.title), repeat \(repeatNumber)"
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
        var lastError: Error?
        while Date() < deadline {
            if enforceContinuity { try checkContinuity() }
            do {
                let snapshot = try await metricsWithRetry(
                    client: client,
                    timeoutSeconds: min(
                        2,
                        max(deadline.timeIntervalSinceNow, 0.1)
                    ),
                    enforceContinuity: enforceContinuity
                )
                if snapshot.window.id == windowID,
                   snapshot.window.runId == runID,
                   snapshot.window.repeatNumber == repeatNumber,
                   snapshot.tuning.profile == profile.wireName {
                    return snapshot
                }
            } catch {
                lastError = error
            }
            if Date() < deadline { try await pause(seconds: 0.35) }
        }
        if let lastError {
            throw lastError
        }
        throw SecureRendererBenchmarkControllerError.invalidResponse(
            "The device did not apply the requested renderer window."
        )
    }

    private func metricsWithRetry(
        client: SecureRendererBenchmarkHTTPClient,
        timeoutSeconds: TimeInterval =
            SecureRendererBenchmarkHTTPPolicy.metricsRecoveryTimeout,
        enforceContinuity: Bool = true
    ) async throws -> RendererBenchmarkMetricsSnapshot {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        repeat {
            if enforceContinuity { try checkContinuity() }
            if collectingStartupEvidence {
                captureStartupEvidence(phase: "before_metrics")
            }
            do {
                let snapshot = try await client.metrics(
                    timeoutInterval: min(
                        SecureRendererBenchmarkHTTPPolicy.controlRequestTimeout,
                        max(deadline.timeIntervalSinceNow, 0.1)
                    )
                )
                if enforceContinuity { lastMeasuredSnapshot = snapshot }
                if collectingStartupEvidence {
                    captureStartupEvidence(phase: "metrics_received", snapshot: snapshot)
                }
                return snapshot
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
        // A stale buffered frame is rejected cheaply by the firmware with
        // HTTP 204 before it captures the marker-bound successor. Leave room
        // for one bounded physical-tail frame attempt and a fresh pinned-
        // session retry if the persistent connection has to be discarded.
        let deadline = Date().addingTimeInterval(
            SecureRendererBenchmarkHTTPPolicy.screenshotRecoveryTimeout
        )
        var lastError: Error?
        while Date() < deadline {
            try checkContinuity()
            do {
                guard let data = try await client.frame(
                    after: lastFrameSequence,
                    capturedAtOrAfter: routeReplay.receivedAtMs,
                    timeoutInterval: min(
                        SecureRendererBenchmarkHTTPPolicy.frameRequestTimeout,
                        max(deadline.timeIntervalSinceNow, 0.1)
                    )
                ) else {
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
                switch RendererBenchmarkCheckpointFramePolicy.decision(
                    capturedAtMs: decoded.capturedAtMs,
                    markerReceivedAtMs: routeReplay.receivedAtMs,
                    maximumAgeMs: gates.absolute.maximumRouteMarkerAgeMs
                ) {
                case .beforeMarker:
                    continue
                case .tooLate:
                    throw SecureRendererBenchmarkControllerError.invalidResponse(
                        "A checkpoint frame missed its route-marker window."
                    )
                case .accept(let lag):
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
                }
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
        let deadline = Date().addingTimeInterval(
            SecureRendererBenchmarkHTTPPolicy.cleanupRecoveryTimeout
        )
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
                profileMayNeedRestoration = false
                return true
            } catch {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        return false
    }

    private func beginTrackedWindow(
        client: SecureRendererBenchmarkHTTPClient,
        profile: RendererBenchmarkProfile,
        runId: String,
        repeatNumber: Int,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity
    ) async throws -> UInt32 {
        let restorationWasAlreadyNeeded = profileMayNeedRestoration
        do {
            let requestID = try await client.beginWindow(
                profile: profile,
                runId: runId,
                repeatNumber: repeatNumber,
                mapFixture: mapFixture,
                routeFixture: routeFixture
            )
            profileMayNeedRestoration = true
            return requestID
        } catch let error as SecureRendererBenchmarkControllerError {
            if case .httpStatus = error {
                profileMayNeedRestoration = restorationWasAlreadyNeeded
            } else {
                profileMayNeedRestoration = true
            }
            throw error
        } catch {
            profileMayNeedRestoration = true
            throw error
        }
    }

    private func checkContinuity() throws {
        try checkSecureSessionContinuity()
        guard let replay, replay.isRunning else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The authenticated renderer replay ended."
            )
        }
    }

    private func checkSecureSessionContinuity() throws {
        guard !stopRequested else {
            throw SecureRendererBenchmarkControllerError.stopped
        }
        guard let bleManager,
              bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics,
              bleManager.supportsRendererBenchmarkSample,
              bleManager.deviceStorageBackend == "sdmmc",
              bleManager.deviceStoragePowerCycleRequired == false,
              let expectedSession,
              RemoteDeviceDebugSessionPolicy.hasSameAuthorizationIdentity(
                RemoteDeviceDebugSessionPolicy.activeSession(bleManager: bleManager),
                as: expectedSession
              ) else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The authenticated secure debug session ended."
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
        return try exportArchive(
            entries: entries, automatedPassed: report.automatedPassed,
            forbiddenValues: forbiddenValues
        )
    }

    private func exportArchive(
        entries initialEntries: [(String, Data)],
        automatedPassed: Bool,
        forbiddenValues: [String]
    ) throws -> URL {
        var entries = initialEntries
        let traceEncoder = JSONEncoder()
        traceEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        entries.append((
            "renderer-benchmark-startup.json",
            try traceEncoder.encode(startupTrace)
        ))
        for (path, data) in entries where path.hasSuffix(".json") {
            guard RendererBenchmarkEvidenceSecurityPolicy.isSecretFree(
                jsonData: data
            ) else { throw SecureRendererBenchmarkProtocolError.invalidEvidence }
        }
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
            "automatedPassed": automatedPassed,
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

    private func captureStartupEvidence(
        phase: String,
        snapshot: RendererBenchmarkMetricsSnapshot? = nil
    ) {
        guard let bleManager, let replay else { return }
        startupTrace.record(RendererBenchmarkStartupSample(
            phase: phase,
            bleTransport: bleManager.rendererBenchmarkBLETransportEvidence(),
            replayTiming: replay.rendererBenchmarkReplayTimingEvidence(),
            window: snapshot?.window,
            routeReplay: snapshot?.routeReplay,
            replayTransport: snapshot?.replayTransport
        ))
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
