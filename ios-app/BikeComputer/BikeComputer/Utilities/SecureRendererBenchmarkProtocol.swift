#if DEBUG || HOST_TESTING
import Foundation

nonisolated enum SecureRendererBenchmarkHTTPPolicy {
    // Only the serial benchmark client opts into firmware connection reuse.
    // The secure console intentionally omits this header so WebKit's parallel
    // and speculative sockets cannot retain the device's single HTTP worker.
    static let connectionReuseHeaderName =
        "X-BikeComputer-Connection-Reuse"
    static let connectionReuseHeaderValue = "1"
    static let controlRequestTimeout: TimeInterval = 5
    // A full 1.75-inch RGB565 frame is 434,312 bytes. Physical measurements
    // initially put the pinned HTTPS body at 4.4-5.9 seconds, while the
    // loop-three physical sweep exceeded the former eight-second deadline.
    // Keep a bounded frame-specific budget without relaxing control requests.
    static let frameRequestTimeout: TimeInterval = 12
    // A timed-out persistent frame can take the firmware's bounded response
    // and idle deadlines to release the single TLS worker. Leave room for one
    // failed control attempt followed by a fresh pinned-session retry.
    static let metricsRecoveryTimeout: TimeInterval = 12
    static let screenshotRecoveryTimeout: TimeInterval = 20
    static let cleanupRecoveryTimeout: TimeInterval = 12
    static let resourceTimeout: TimeInterval = 20

    static func enableConnectionReuse(on request: inout URLRequest) {
        request.setValue(
            connectionReuseHeaderValue,
            forHTTPHeaderField: connectionReuseHeaderName
        )
    }
}

nonisolated enum SecureRendererBenchmarkProtocolError: LocalizedError,
                                                        Equatable,
                                                        Sendable {
    case invalidGates
    case invalidFrame
    case invalidEvidence

    var errorDescription: String? {
        switch self {
        case .invalidGates:
            return "The checked-in renderer benchmark gates are invalid."
        case .invalidFrame:
            return "The device returned an invalid renderer frame."
        case .invalidEvidence:
            return "The renderer benchmark evidence contains a secret or invalid field."
        }
    }
}

nonisolated struct RendererBenchmarkGates: Codable, Equatable, Sendable {
    static let resourceName = "renderer-benchmark-gates-v1"

    nonisolated struct Absolute: Codable, Equatable, Sendable {
        let minimumMetricsSampleFraction: Double
        let minimumRenderSamples: Int
        let minimumBuildingCandidates: Double
        let minimumSelectedBuildings: Double
        let minimumExtrudedBuildingsFor3DProfile: Double
        let minimumGpsPacketsPerMinute: Int
        let minimumRouteMarkersPerMinute: Int
        let maximumRouteMarkerAgeMs: UInt32
        let maximumRouteMarkerStallMs: UInt32
        let minimumInternalFreeBytes: UInt32
        let minimumInternalLargestBlockBytes: UInt32
        let minimumPsramFreeBytes: UInt32
        let minimumPsramLargestBlockBytes: UInt32
        let minimumDmaFreeBytes: UInt32
        let minimumDmaLargestBlockBytes: UInt32
        let maximumCryptoHeadroomRejections: UInt32
        let maximumCryptoOperationFailures: UInt32
        let maximumRenderP95Ms: UInt32
        let maximumUiGapMs: UInt32
        let maximumFlushP95Ms: UInt32
        let maximumFlushMs: UInt32
        let maximumGpsPacketGapMs: UInt32
        let maximumStaleRenders: UInt32
        let maximumCancelledRenders: UInt32
        let maximumInterruptedRenders: UInt32
        let maximumCoverageRejectedRenders: UInt32
        let maximumPredictionExhaustionEntries: UInt32
        let maximumInvariantFailures: UInt32
        let maximumRemoteDebugCaptureErrors: UInt32
    }

    nonisolated struct Trend: Codable, Equatable, Sendable {
        let minimumSamples: Int
        let internalFreeAllowedDeclineBytes: UInt32
        let internalLargestAllowedDeclineBytes: UInt32
        let psramFreeAllowedDeclineBytes: UInt32
        let psramLargestAllowedDeclineBytes: UInt32
        let dmaFreeAllowedDeclineBytes: UInt32
        let dmaLargestAllowedDeclineBytes: UInt32
        let crossRunInternalAllowedDeclineBytes: UInt32
        let crossRunPsramAllowedDeclineBytes: UInt32
        let crossRunDmaAllowedDeclineBytes: UInt32
    }

    nonisolated struct CandidateRelativeToCurrent: Codable,
                                                          Equatable,
                                                          Sendable {
        let maximumRenderP95Multiplier: Double
        let maximumUiGapMultiplier: Double
        let maximumInternalHeadroomLossBytes: UInt32
        let maximumPsramHeadroomLossBytes: UInt32
        let maximumDmaHeadroomLossBytes: UInt32
        let minimumReachGainFraction: Double
    }

    let schema: Int
    let warmupSeconds: Int
    let pollIntervalSeconds: Double
    let comparisonDurationSeconds: Int
    let checkpointFractions: [Double]
    let checkpointToleranceSamples: Int
    let absolute: Absolute
    let trend: Trend
    let candidateRelativeToCurrent: CandidateRelativeToCurrent

    static func decode(_ data: Data) throws -> RendererBenchmarkGates {
        guard data.count <= 32_768,
              let gates = try? JSONDecoder().decode(Self.self, from: data),
              gates.schema == 1,
              gates.warmupSeconds >= 0,
              gates.pollIntervalSeconds.isFinite,
              gates.pollIntervalSeconds > 0,
              gates.comparisonDurationSeconds >= 120,
              gates.checkpointToleranceSamples >= 0,
              !gates.checkpointFractions.isEmpty,
              gates.checkpointFractions.allSatisfy({
                  $0.isFinite && $0 >= 0 && $0 < 1
              }),
              gates.absolute.minimumMetricsSampleFraction > 0,
              gates.absolute.minimumMetricsSampleFraction <= 1,
              gates.trend.minimumSamples > 0,
              gates.candidateRelativeToCurrent.maximumRenderP95Multiplier > 0,
              gates.candidateRelativeToCurrent.maximumUiGapMultiplier > 0,
              gates.candidateRelativeToCurrent.minimumReachGainFraction >= 0 else {
            throw SecureRendererBenchmarkProtocolError.invalidGates
        }
        return gates
    }

    static func load(bundle: Bundle = .main) throws -> (
        gates: RendererBenchmarkGates,
        data: Data
    ) {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            throw SecureRendererBenchmarkProtocolError.invalidGates
        }
        return (try decode(data), data)
    }
}

extension RendererBenchmarkProfile {
    nonisolated var wireName: String {
        switch self {
        case .flat: return "flat"
        case .current: return "current"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    nonisolated init?(wireName: String) {
        switch wireName {
        case "flat": self = .flat
        case "current": self = .current
        case "medium": self = .medium
        case "high": self = .high
        default: return nil
        }
    }

    nonisolated var expectedExtrusionQuota: RendererBenchmarkQuota {
        switch self {
        case .flat:
            return RendererBenchmarkQuota(
                records: 0, points: 0, projectedPixels: 0
            )
        case .current:
            return RendererBenchmarkQuota(
                records: 32, points: 3_072, projectedPixels: 90_000
            )
        case .medium:
            return RendererBenchmarkQuota(
                records: 40, points: 3_840, projectedPixels: 112_500
            )
        case .high:
            return RendererBenchmarkQuota(
                records: 48, points: 4_608, projectedPixels: 135_000
            )
        }
    }

    nonisolated var expectedTuningFingerprint: UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603
        let quota = expectedExtrusionQuota
        for part in [
            UInt64(rawValue), 96, 8_192, 220_000,
            UInt64(quota.records), UInt64(quota.points),
            UInt64(quota.projectedPixels), 6,
        ] {
            value ^= part
            value = value &* 1_099_511_628_211
        }
        return value
    }
}

nonisolated struct RendererBenchmarkRunPlanItem: Equatable, Sendable {
    let profile: RendererBenchmarkProfile
    let repeatNumber: Int
}

nonisolated struct SecureRendererBenchmarkReadinessInputs: Equatable, Sendable {
    let isConnected: Bool
    let isNavigationReady: Bool
    let supportsRendererDiagnostics: Bool
    let supportsRendererBenchmarkSample: Bool
    let isNavigationActive: Bool
    let hasSecureSession: Bool
    let hasActiveMap: Bool
    let hasManifestReceipt: Bool
    let hasMapBounds: Bool
    let storageBackend: String?
    let storagePowerCycleRequired: Bool?
    let manualReplayIsRunning: Bool
}

nonisolated enum SecureRendererBenchmarkReadinessBlocker: Equatable, Sendable {
    case deviceDisconnected
    case navigationNotReady
    case rendererDiagnosticsUnsupported
    case rendererBenchmarkSampleUnsupported
    case navigationActive
    case manualReplayRunning
    case secureSessionUnavailable
    case activeMapUnavailable
    case manifestReceiptUnavailable
    case mapBoundsUnavailable
    case storageStatusUnavailable
    case nativeSDMMCRequired

    var message: String {
        switch self {
        case .deviceDisconnected:
            return "Connect the bike computer before running the secure sweep."
        case .navigationNotReady:
            return "Wait for authenticated BLE navigation to become ready."
        case .rendererDiagnosticsUnsupported:
            return "The connected firmware does not expose renderer diagnostics."
        case .rendererBenchmarkSampleUnsupported:
            return "The connected firmware cannot deliver each benchmark GPS sample and marker atomically."
        case .navigationActive:
            return "Stop navigation before running the renderer benchmark."
        case .manualReplayRunning:
            return "Stop the manual pinned replay before starting the full sweep."
        case .secureSessionUnavailable:
            return "Start Remote Device Debugging and wait for its pinned HTTPS session."
        case .activeMapUnavailable:
            return "The active-map status is unavailable. Refresh sweep readiness over BLE."
        case .manifestReceiptUnavailable:
            return "The active map lacks a verified manifest receipt. Reinstall it from Saved Maps before benchmarking."
        case .mapBoundsUnavailable:
            return "The active map lacks validated bounds. Reinstall it from Saved Maps before benchmarking."
        case .storageStatusUnavailable:
            return "The storage status is unavailable. Refresh sweep readiness over BLE."
        case .nativeSDMMCRequired:
            return "Fully power-cycle the device and confirm native SDMMC storage before benchmarking."
        }
    }
}

nonisolated enum SecureRendererBenchmarkReadiness {
    static func blocker(
        for inputs: SecureRendererBenchmarkReadinessInputs
    ) -> SecureRendererBenchmarkReadinessBlocker? {
        guard inputs.isConnected else { return .deviceDisconnected }
        guard inputs.isNavigationReady else { return .navigationNotReady }
        guard inputs.supportsRendererDiagnostics else {
            return .rendererDiagnosticsUnsupported
        }
        guard inputs.supportsRendererBenchmarkSample else {
            return .rendererBenchmarkSampleUnsupported
        }
        guard !inputs.isNavigationActive else { return .navigationActive }
        guard !inputs.manualReplayIsRunning else {
            return .manualReplayRunning
        }
        guard inputs.hasSecureSession else { return .secureSessionUnavailable }
        guard inputs.hasActiveMap else { return .activeMapUnavailable }
        guard inputs.hasManifestReceipt else {
            return .manifestReceiptUnavailable
        }
        guard inputs.hasMapBounds else { return .mapBoundsUnavailable }
        guard inputs.storageBackend != nil,
              inputs.storagePowerCycleRequired != nil else {
            return .storageStatusUnavailable
        }
        guard inputs.storageBackend == "sdmmc",
              inputs.storagePowerCycleRequired == false else {
            return .nativeSDMMCRequired
        }
        return nil
    }
}

nonisolated enum SecureRendererBenchmarkPlan {
    static let comparisonRepeats = 3
    static let soakDurationSeconds = 300
    static let routeMode = "ios-fixture-1hz"
    static let totalComparisonRunCount =
        RendererBenchmarkProfile.allCases.count * comparisonRepeats

    static func balancedSchedule(
        repeats: Int = comparisonRepeats,
        profiles: [RendererBenchmarkProfile] =
            RendererBenchmarkProfile.allCases
    ) -> [[RendererBenchmarkProfile]] {
        guard repeats > 0,
              !profiles.isEmpty,
              Set(profiles.map(\.rawValue)).count == profiles.count else {
            return []
        }
        if profiles.count == 1 {
            return Array(repeating: profiles, count: repeats)
        }
        var firstRow = [0]
        var low = 1
        var high = profiles.count - 1
        while firstRow.count < profiles.count {
            firstRow.append(low)
            low += 1
            if firstRow.count < profiles.count {
                firstRow.append(high)
                high -= 1
            }
        }
        return (0..<repeats).map { repeatIndex in
            firstRow.map {
                profiles[($0 + repeatIndex) % profiles.count]
            }
        }
    }

    static func comparisonRuns() -> [RendererBenchmarkRunPlanItem] {
        balancedSchedule().enumerated().flatMap { repeatIndex, row in
            row.map {
                RendererBenchmarkRunPlanItem(
                    profile: $0,
                    repeatNumber: repeatIndex + 1
                )
            }
        }
    }

    static func checkpointIndexes(
        sampleCount: Int,
        fractions: [Double]
    ) -> [Int] {
        guard sampleCount > 0 else { return [] }
        return Array(Set(fractions.map {
            Int((Double(sampleCount) * $0).rounded()) % sampleCount
        })).sorted()
    }

    static func circularSampleDistance(
        _ left: Int,
        _ right: Int,
        count: Int
    ) -> Int {
        guard count > 0 else { return Int.max }
        let direct = abs(left - right)
        return min(direct, count - direct)
    }
}

nonisolated struct RendererBenchmarkQuota: Codable, Equatable, Sendable {
    let records: Int
    let points: Int
    let projectedPixels: Int
}

nonisolated struct RendererBenchmarkDeviceInfo: Codable, Equatable, Sendable {
    nonisolated struct Firmware: Codable, Equatable, Sendable {
        let target: String
        let gitSha: String
        let version: String
        let build: Int
    }

    nonisolated struct Session: Codable, Equatable, Sendable {
        let active: Bool
        let mode: String
    }

    nonisolated struct Counters: Codable, Equatable, Sendable {
        let pointerLastSequence: UInt32
        let pointerSequenceInitialized: Bool
    }

    let ok: Bool
    let schema: Int
    let target: String
    let width: Int
    let height: Int
    let viewRotation: Int
    let pixelFormat: String
    let deviceId: String
    let buildProfile: String
    let uptimeMs: UInt32
    let firmware: Firmware
    let session: Session
    let counters: Counters
}

nonisolated struct RendererBenchmarkMapFixtureIdentity: Codable,
                                                               Equatable,
                                                               Sendable {
    let id: String
    let sha256: String
}

nonisolated struct RendererBenchmarkRouteFixtureIdentity: Codable,
                                                                 Equatable,
                                                                 Sendable {
    let id: String
    let sha256: String
    let mode: String
}

nonisolated enum RendererBenchmarkWindowWireContract {
    static let acceptedStatusCode = 202

    private struct Fixture: Encodable {
        let id: String
        let sha256: String
    }

    private struct Request: Encodable {
        let schema = 1
        let profile: String
        let runId: String
        let repeatNumber: Int
        let mapFixture: Fixture
        let routeFixture: Fixture
        let routeMode: String

        enum CodingKeys: String, CodingKey {
            case schema, profile, runId, mapFixture, routeFixture, routeMode
            case repeatNumber = "repeat"
        }
    }

    private struct Response: Decodable {
        let ok: Bool
        let requestId: UInt32
    }

    static func requestData(
        profile: String,
        runId: String,
        repeatNumber: Int,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity
    ) throws -> Data {
        try JSONEncoder().encode(Request(
            profile: profile,
            runId: runId,
            repeatNumber: repeatNumber,
            mapFixture: Fixture(
                id: mapFixture.id,
                sha256: mapFixture.sha256
            ),
            routeFixture: Fixture(
                id: routeFixture.id,
                sha256: routeFixture.sha256
            ),
            routeMode: routeFixture.mode
        ))
    }

    static func requestID(from data: Data) -> UInt32? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.ok,
              response.requestId != 0 else { return nil }
        return response.requestId
    }
}

nonisolated struct RendererBenchmarkMetricsSnapshot: Codable,
                                                            Equatable,
                                                            Sendable {
    nonisolated struct Window: Codable, Equatable, Sendable {
        let id: UInt32
        let startedAtMs: UInt32
        let runId: String
        let repeatNumber: Int

        enum CodingKeys: String, CodingKey {
            case id
            case startedAtMs
            case runId
            case repeatNumber = "repeat"
        }
    }

    nonisolated struct Identity: Codable, Equatable, Sendable {
        let deviceId: String
        let firmwareCommit: String
        let board: String
        let buildProfile: String
        let bootId: UInt32
        let resetReason: UInt32
        let mapFixture: RendererBenchmarkMapFixtureIdentity
        let routeFixture: RendererBenchmarkRouteFixtureIdentity
    }

    nonisolated struct Tuning: Codable, Equatable, Sendable {
        let profile: String
        let fingerprint: UInt64
        let minimumExtrusionAreaPx2: Int
        let total: RendererBenchmarkQuota
        let extrusion: RendererBenchmarkQuota
    }

    nonisolated struct MemoryRegion: Codable, Equatable, Sendable {
        let free: UInt32
        let minimumEverFree: UInt32?
        let largestBlock: UInt32
        let windowMinimumFree: UInt32
        let windowMinimumLargestBlock: UInt32
    }

    nonisolated struct DMAMemoryRegion: Codable, Equatable, Sendable {
        nonisolated struct MinimumAttribution: Codable, Equatable, Sendable {
            let phase: String
            let observedAtMs: UInt32
            let value: UInt32
            let frameTransferActive: Bool
        }

        let free: UInt32
        let minimumEverFree: UInt32
        let largestBlock: UInt32
        let windowMinimumFree: UInt32
        let windowMinimumLargestBlock: UInt32
        let windowMinimumFreeAttribution: MinimumAttribution?
        let windowMinimumLargestBlockAttribution: MinimumAttribution?
        let cryptoCountersScope: String?
        let cryptoHeadroomRejections: UInt32
        let cryptoOperationFailures: UInt32
    }

    nonisolated struct Memory: Codable, Equatable, Sendable {
        let internalHeap: MemoryRegion
        let psram: MemoryRegion
        let dmaHeap: DMAMemoryRegion
    }

    nonisolated struct Timing: Codable, Equatable, Sendable {
        let count: UInt32
        let lastMs: UInt32
        let p50Ms: UInt32
        let p95Ms: UInt32
        let maximumMs: UInt32
    }

    nonisolated struct Timings: Codable, Equatable, Sendable {
        let total: Timing
        let blockLoad: Timing
        let draw: Timing
        let buildingProjection: Timing
        let buildingDraw: Timing
        let buildingTotal: Timing
    }

    nonisolated struct LimiterPasses: Codable, Equatable, Sendable {
        let records: UInt32
        let points: UInt32
        let projectedPixels: UInt32
        let extrudedRecords: UInt32
        let extrudedPoints: UInt32
        let extrudedPixels: UInt32
    }

    nonisolated struct Buildings: Codable, Equatable, Sendable {
        let candidates: UInt32
        let selected: UInt32
        let extruded: UInt32
        let flat: UInt32
        let deferred: UInt32
        let oversized: UInt32
        let rendered: UInt32
        let allocationFallback: Bool
        let extrudedP90DistancePx: UInt32
        let extrudedFarthestDistancePx: UInt32
        let limiterFlags: UInt32
        let limiterPasses: LimiterPasses
    }

    nonisolated struct Jobs: Codable, Equatable, Sendable {
        let requested: UInt32
        let started: UInt32
        let completed: UInt32
        let published: UInt32
        let stale: UInt32
        let cancelled: UInt32
        let interrupted: UInt32
        let coverageRejected: UInt32
        let invariantFailed: UInt32
    }

    nonisolated struct Render: Codable, Equatable, Sendable {
        let timings: Timings
        let buildings: Buildings
        let jobs: Jobs
    }

    nonisolated struct UIState: Codable, Equatable, Sendable {
        let maximumGapMs: UInt32
    }

    nonisolated struct GPS: Codable, Equatable, Sendable {
        let packets: UInt32
        let latestPacketGapMs: UInt32
        let maximumPacketGapMs: UInt32
        let predictionGraceEntries: UInt32
        let predictionExhaustionEntries: UInt32
    }

    nonisolated struct RouteReplay: Codable, Equatable, Sendable {
        let valid: Bool
        let fixtureSha256: String
        let fixtureMatches: Bool
        let sampleIndex: Int
        let sampleCount: Int
        let loop: UInt32
        let receivedAtMs: UInt32
        let accepted: UInt32
        let rejected: UInt32
    }

    /// Session-scoped, non-secret firmware evidence for replay ingress and
    /// marker admission. This is optional so an app built from this stack can
    /// still decode metrics from the immediately preceding firmware head.
    nonisolated struct ReplayTransport: Codable, Equatable, Sendable {
        let gpsAuthenticationAccepted: UInt32
        let gpsAuthenticationRejected: UInt32
        let rbs1Detected: UInt32
        let rbs1Decoded: UInt32
        let rbs1Malformed: UInt32
        let rbs1Unnegotiated: UInt32
        let gpsMailboxAccepted: UInt32
        let gpsMailboxRejected: UInt32
        let markerAccepted: UInt32
        let markerRejectedInvalid: UInt32
        let markerRejectedNoActiveWindow: UInt32
        let markerRejectedActiveFixtureUnavailable: UInt32
        let markerRejectedFixtureMismatch: UInt32
        let lastTransportEventAtMs: UInt32
        let lastMarkerAtMs: UInt32
        let lastActiveWindowId: UInt32
        let lastSampleIndex: UInt16
        let lastSampleCount: UInt16
        let lastLoop: UInt32
        let lastCandidateFixtureTag: UInt32
        let lastCandidateFixtureTagValid: Bool
        let lastExpectedFixtureTag: UInt32
        let lastExpectedFixtureTagValid: Bool
        let lastMarkerResult: String
    }

    nonisolated struct RemoteDebug: Codable, Equatable, Sendable {
        let active: Bool
        let snapshotBytes: UInt32
        let captured: UInt32
        let skippedCadence: UInt32
        let skippedLocked: UInt32
        let captureErrors: UInt32
        let lastCopyUs: UInt32
        let maximumCopyUs: UInt32
        let lastHttpResponseMs: UInt32
        let maximumHttpResponseMs: UInt32
        let lastFrameSnapshotWaitUs: UInt32?
        let maximumFrameSnapshotWaitUs: UInt32?
        let lastFrameCrcUs: UInt32?
        let maximumFrameCrcUs: UInt32?
        let lastHttpExpectedBytes: UInt32?
        let lastHttpActualBytes: UInt32?
        let lastHttpWriteCalls: UInt32?
        let lastHttpZeroWriteCalls: UInt32?
        let lastHttpShortWriteCalls: UInt32?
        let lastHttpActiveTlsWriteUs: UInt32?
        let lastHttpNoProgressWaitMs: UInt32?
        let lastHttpIntentionalDelayMs: UInt32?
        let freeBefore: UInt32
        let largestBefore: UInt32
        let freeAfterAllocate: UInt32
        let largestAfterAllocate: UInt32
    }

    let ok: Bool
    let schema: Int
    let sequence: UInt32
    let timestampMs: UInt32
    let window: Window
    let identity: Identity
    let tuning: Tuning
    let memory: Memory
    let render: Render
    let ui: UIState
    let displayFlush: Timing
    let gps: GPS
    let routeReplay: RouteReplay
    let replayTransport: ReplayTransport?
    let remoteDebug: RemoteDebug
}

nonisolated struct RendererBenchmarkReplayTimingEvidence: Codable,
                                                             Equatable,
                                                             Sendable {
    let schema: Int
    let emittedSamples: UInt64
    let timerCallbacks: UInt64
    let lastTimerLatenessMs: Int
    let maximumTimerLatenessMs: Int
}

nonisolated struct RendererBenchmarkEvidenceIdentity: Codable,
                                                           Equatable,
                                                           Sendable {
    let deviceId: String
    let firmwareCommit: String
    let firmwareVersion: String
    let firmwareBuild: Int
    let board: String
    let buildProfile: String
    let storageBackend: String
    let storagePowerCycleRequired: Bool
    let bootId: UInt32
    let resetReason: UInt32
}

nonisolated struct RendererBenchmarkAppBuildIdentity: Codable,
                                                       Equatable,
                                                       Sendable {
    let schemaVersion: Int
    let build: String
    let gitSha: String
    let componentSha256: String
}

nonisolated struct RendererBenchmarkEvidenceSample: Codable,
                                                         Equatable,
                                                         Sendable {
    let elapsedSeconds: Double
    let sequence: UInt32
    let timestampMs: UInt32
    let internalFree: UInt32
    let internalLargest: UInt32
    let psramFree: UInt32
    let psramLargest: UInt32
    let dmaFree: UInt32
    let dmaLargest: UInt32
    let renderCount: UInt32
    let buildings: RendererBenchmarkMetricsSnapshot.Buildings
    let routeReplay: RendererBenchmarkMetricsSnapshot.RouteReplay
    let replayTransport: RendererBenchmarkMetricsSnapshot.ReplayTransport?
    let bleTransport: RendererBenchmarkBLETransportEvidence?
    let replayTiming: RendererBenchmarkReplayTimingEvidence?
}

/// A bounded, secret-free delta for one initial replay-admission attempt.
/// Firmware counters are session-scoped, so the controller compares the last
/// snapshot with the window-confirmation snapshot captured before it emits the
/// route and RBS1 pair.
nonisolated struct RendererBenchmarkReplayTransportDelta: Equatable, Sendable {
    let gpsAuthenticationAccepted: UInt32
    let gpsAuthenticationRejected: UInt32
    let rbs1Detected: UInt32
    let rbs1Decoded: UInt32
    let rbs1Malformed: UInt32
    let rbs1Unnegotiated: UInt32
    let gpsMailboxAccepted: UInt32
    let gpsMailboxRejected: UInt32
    let markerAccepted: UInt32
    let markerRejectedInvalid: UInt32
    let markerRejectedNoActiveWindow: UInt32
    let markerRejectedActiveFixtureUnavailable: UInt32
    let markerRejectedFixtureMismatch: UInt32
    let lastMarkerResult: String
    let lastActiveWindowId: UInt32
    let lastSampleIndex: UInt16
    let lastSampleCount: UInt16

    init?(
        baseline: RendererBenchmarkMetricsSnapshot.ReplayTransport?,
        latest: RendererBenchmarkMetricsSnapshot.ReplayTransport?
    ) {
        guard let latest else { return nil }
        func delta(
            _ value: UInt32,
            _ keyPath: KeyPath<
                RendererBenchmarkMetricsSnapshot.ReplayTransport,
                UInt32
            >
        ) -> UInt32 {
            value &- (baseline?[keyPath: keyPath] ?? 0)
        }

        gpsAuthenticationAccepted = delta(
            latest.gpsAuthenticationAccepted,
            \.gpsAuthenticationAccepted
        )
        gpsAuthenticationRejected = delta(
            latest.gpsAuthenticationRejected,
            \.gpsAuthenticationRejected
        )
        rbs1Detected = delta(latest.rbs1Detected, \.rbs1Detected)
        rbs1Decoded = delta(latest.rbs1Decoded, \.rbs1Decoded)
        rbs1Malformed = delta(latest.rbs1Malformed, \.rbs1Malformed)
        rbs1Unnegotiated = delta(latest.rbs1Unnegotiated, \.rbs1Unnegotiated)
        gpsMailboxAccepted = delta(
            latest.gpsMailboxAccepted,
            \.gpsMailboxAccepted
        )
        gpsMailboxRejected = delta(
            latest.gpsMailboxRejected,
            \.gpsMailboxRejected
        )
        markerAccepted = delta(latest.markerAccepted, \.markerAccepted)
        markerRejectedInvalid = delta(
            latest.markerRejectedInvalid,
            \.markerRejectedInvalid
        )
        markerRejectedNoActiveWindow = delta(
            latest.markerRejectedNoActiveWindow,
            \.markerRejectedNoActiveWindow
        )
        markerRejectedActiveFixtureUnavailable = delta(
            latest.markerRejectedActiveFixtureUnavailable,
            \.markerRejectedActiveFixtureUnavailable
        )
        markerRejectedFixtureMismatch = delta(
            latest.markerRejectedFixtureMismatch,
            \.markerRejectedFixtureMismatch
        )
        lastMarkerResult = latest.lastMarkerResult
        lastActiveWindowId = latest.lastActiveWindowId
        lastSampleIndex = latest.lastSampleIndex
        lastSampleCount = latest.lastSampleCount
    }

    var failureDescription: String {
        "Replay diagnostics for this attempt: " +
            "authAccepted=\(gpsAuthenticationAccepted), " +
            "authRejected=\(gpsAuthenticationRejected), " +
            "rbs1Detected=\(rbs1Detected), " +
            "rbs1Decoded=\(rbs1Decoded), " +
            "rbs1Malformed=\(rbs1Malformed), " +
            "rbs1Unnegotiated=\(rbs1Unnegotiated), " +
            "gpsMailboxAccepted=\(gpsMailboxAccepted), " +
            "gpsMailboxRejected=\(gpsMailboxRejected), " +
            "markerAccepted=\(markerAccepted), " +
            "markerRejectedInvalid=\(markerRejectedInvalid), " +
            "markerRejectedNoActiveWindow=" +
            "\(markerRejectedNoActiveWindow), " +
            "markerRejectedActiveFixtureUnavailable=" +
            "\(markerRejectedActiveFixtureUnavailable), " +
            "markerRejectedFixtureMismatch=" +
            "\(markerRejectedFixtureMismatch), " +
            "lastMarkerResult=\(lastMarkerResult), " +
            "lastActiveWindowId=\(lastActiveWindowId), " +
            "lastSample=\(lastSampleIndex)/\(lastSampleCount)."
    }
}

nonisolated struct RendererBenchmarkRunSummary: Codable, Equatable, Sendable {
    let profile: String
    let repeatNumber: Int
    let renderCount: UInt32
    let renderP50Ms: UInt32
    let renderP95Ms: UInt32
    let renderMaximumMs: UInt32
    let blockLoadP95Ms: UInt32
    let drawP95Ms: UInt32
    let buildingP95Ms: UInt32
    let buildingProjectionP95Ms: UInt32
    let buildingDrawP95Ms: UInt32
    let uiMaximumGapMs: UInt32
    let flushP50Ms: UInt32
    let flushP95Ms: UInt32
    let flushMaximumMs: UInt32
    let minimumInternalFree: UInt32
    let minimumInternalLargest: UInt32
    let minimumPsramFree: UInt32
    let minimumPsramLargest: UInt32
    let minimumDmaFree: UInt32
    let minimumDmaLargest: UInt32
    let cryptoHeadroomRejections: UInt32
    let cryptoOperationFailures: UInt32
    let candidateBuildings: Double
    let selectedBuildings: Double
    let extrudedBuildings: Double
    let flatBuildings: Double
    let deferredBuildings: Double
    let oversizedBuildings: Double
    let renderedBuildings: Double
    let extrudedP90DistancePx: Double
    let extrudedFarthestDistancePx: Double
    let requestedRenders: UInt32
    let completedRenders: UInt32
    let publishedRenders: UInt32
    let staleRenders: UInt32
    let cancelledRenders: UInt32
    let interruptedRenders: UInt32
    let coverageRejectedRenders: UInt32
    let invariantFailures: UInt32
    let maximumGpsPacketGapMs: UInt32
    let gpsPackets: UInt32
    let predictionGraceEntries: UInt32
    let predictionExhaustionEntries: UInt32
    let routeMarkersAccepted: UInt32
    let routeMarkersRejected: UInt32
    let remoteDebugCaptureErrors: UInt32

    enum CodingKeys: String, CodingKey {
        case profile
        case repeatNumber = "repeat"
        case renderCount, renderP50Ms, renderP95Ms, renderMaximumMs
        case blockLoadP95Ms, drawP95Ms, buildingP95Ms
        case buildingProjectionP95Ms, buildingDrawP95Ms
        case uiMaximumGapMs, flushP50Ms, flushP95Ms, flushMaximumMs
        case minimumInternalFree, minimumInternalLargest
        case minimumPsramFree, minimumPsramLargest
        case minimumDmaFree, minimumDmaLargest
        case cryptoHeadroomRejections, cryptoOperationFailures
        case candidateBuildings, selectedBuildings, extrudedBuildings
        case flatBuildings, deferredBuildings, oversizedBuildings
        case renderedBuildings, extrudedP90DistancePx
        case extrudedFarthestDistancePx, requestedRenders
        case completedRenders, publishedRenders, staleRenders
        case cancelledRenders, interruptedRenders
        case coverageRejectedRenders, invariantFailures
        case maximumGpsPacketGapMs, gpsPackets, predictionGraceEntries
        case predictionExhaustionEntries, routeMarkersAccepted
        case routeMarkersRejected, remoteDebugCaptureErrors
    }
}

nonisolated struct RendererBenchmarkScreenshotEvidence: Codable,
                                                              Equatable,
                                                              Sendable {
    let checkpointSampleIndex: Int
    let observedSampleIndex: Int
    let frameSequence: UInt32
    let capturedAtMs: UInt32
    let markerReceivedAtMs: UInt32
    let captureLagMs: UInt32
    let path: String
    let bytes: Int
    let sha256: String
}

nonisolated enum RendererBenchmarkCheckpointFramePolicy {
    enum Decision: Equatable, Sendable {
        case beforeMarker
        case accept(lagMs: UInt32)
        case tooLate(lagMs: UInt32)
    }

    static func decision(
        capturedAtMs: UInt32,
        markerReceivedAtMs: UInt32,
        maximumAgeMs: UInt32
    ) -> Decision {
        let lag = capturedAtMs &- markerReceivedAtMs
        guard lag < 0x8000_0000 else { return .beforeMarker }
        guard lag <= maximumAgeMs else { return .tooLate(lagMs: lag) }
        return .accept(lagMs: lag)
    }
}

nonisolated struct RendererBenchmarkRunEvidence: Codable, Equatable, Sendable {
    let schema: Int
    let runId: String
    let windowId: UInt32
    let profile: String
    let repeatNumber: Int
    let durationSeconds: Int
    let soak: Bool
    var passed: Bool
    var failures: [String]
    let summary: RendererBenchmarkRunSummary
    let samples: [RendererBenchmarkEvidenceSample]
    let screenshots: [RendererBenchmarkScreenshotEvidence]
    let finalSnapshot: RendererBenchmarkMetricsSnapshot

    enum CodingKeys: String, CodingKey {
        case schema, runId, windowId, profile
        case repeatNumber = "repeat"
        case durationSeconds, soak, passed, failures, summary, samples
        case screenshots, finalSnapshot
    }
}

nonisolated struct RendererBenchmarkProfileAggregate: Codable,
                                                           Equatable,
                                                           Sendable {
    let passed: Bool
    let runCount: Int
    let failedRuns: Int
    let renderP95Ms: Double
    let buildingP95Ms: Double
    let uiMaximumGapMs: Double
    let flushP95Ms: Double
    let minimumInternalFree: Double
    let minimumInternalLargest: Double
    let minimumPsramFree: Double
    let minimumPsramLargest: Double
    let minimumDmaFree: Double
    let minimumDmaLargest: Double
    let cryptoHeadroomRejections: Double
    let cryptoOperationFailures: Double
    let candidateBuildings: Double
    let selectedBuildings: Double
    let extrudedBuildings: Double
    let flatBuildings: Double
    let deferredBuildings: Double
    let oversizedBuildings: Double
    let renderedBuildings: Double
    let extrudedP90DistancePx: Double
    let extrudedFarthestDistancePx: Double
}

nonisolated struct RendererBenchmarkCandidateSelection: Codable,
                                                             Equatable,
                                                             Sendable {
    let selected: String?
    let frontier: [String]
    let idealDistances: [String: Double]
    let exclusions: [String: [String]]
}

nonisolated struct SecureRendererBenchmarkEvidenceReport: Codable,
                                                               Equatable,
                                                               Sendable {
    let schema: Int
    let source: String
    let generatedAt: String
    let appIdentity: RendererBenchmarkAppBuildIdentity
    let identity: RendererBenchmarkEvidenceIdentity
    let mapFixture: RendererBenchmarkMapFixtureIdentity
    let routeFixture: RendererBenchmarkRouteFixtureIdentity
    let gatesSHA256: String
    let gates: RendererBenchmarkGates
    let schedule: [[String]]
    let runs: [RendererBenchmarkRunEvidence]
    let aggregate: [String: RendererBenchmarkProfileAggregate]
    let selection: RendererBenchmarkCandidateSelection
    let soakRun: RendererBenchmarkRunEvidence?
    let cleanupRestoredCurrent: Bool
    let automatedPassed: Bool
    let remainingPhysicalGates: [String]
}

nonisolated enum RendererBenchmarkEvidenceSecurityPolicy {
    private static let forbiddenNormalizedKeys: Set<String> = [
        "token",
        "sessiontoken",
        "transferauthtoken",
        "baseurl",
        "tlscertificatesha256",
        "certificate",
        "password",
        "passphrase",
        "accesspointpassphrase",
    ]

    static func isSecretFree(jsonData: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: jsonData) else {
            return false
        }
        return isSecretFree(value)
    }

    private static func isSecretFree(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if forbiddenNormalizedKeys.contains(normalized) ||
                    normalized.hasSuffix("token") ||
                    normalized.hasSuffix("password") ||
                    normalized.hasSuffix("passphrase") {
                    return false
                }
                if !isSecretFree(child) { return false }
            }
            return true
        }
        if let array = value as? [Any] {
            return array.allSatisfy(isSecretFree)
        }
        return true
    }
}

nonisolated enum RendererBenchmarkEvaluator {
    static func sample(
        snapshot: RendererBenchmarkMetricsSnapshot,
        elapsedSeconds: Double,
        bleTransport: RendererBenchmarkBLETransportEvidence? = nil,
        replayTiming: RendererBenchmarkReplayTimingEvidence? = nil
    ) -> RendererBenchmarkEvidenceSample {
        RendererBenchmarkEvidenceSample(
            elapsedSeconds: (elapsedSeconds * 1_000).rounded() / 1_000,
            sequence: snapshot.sequence,
            timestampMs: snapshot.timestampMs,
            internalFree: snapshot.memory.internalHeap.free,
            internalLargest: snapshot.memory.internalHeap.largestBlock,
            psramFree: snapshot.memory.psram.free,
            psramLargest: snapshot.memory.psram.largestBlock,
            dmaFree: snapshot.memory.dmaHeap.free,
            dmaLargest: snapshot.memory.dmaHeap.largestBlock,
            renderCount: snapshot.render.timings.total.count,
            buildings: snapshot.render.buildings,
            routeReplay: snapshot.routeReplay,
            replayTransport: snapshot.replayTransport,
            bleTransport: bleTransport,
            replayTiming: replayTiming
        )
    }

    static func summary(
        snapshots: [RendererBenchmarkMetricsSnapshot],
        samples: [RendererBenchmarkEvidenceSample]
    ) -> RendererBenchmarkRunSummary? {
        guard let final = snapshots.last else { return nil }
        var changing: [RendererBenchmarkMetricsSnapshot.Buildings] = []
        var previousRenderCount: UInt32?
        for sample in samples where sample.renderCount != previousRenderCount {
            changing.append(sample.buildings)
            previousRenderCount = sample.renderCount
        }
        func buildingMedian(
            _ value: (RendererBenchmarkMetricsSnapshot.Buildings) -> UInt32
        ) -> Double {
            median(changing.map { Double(value($0)) })
        }
        let timings = final.render.timings
        let jobs = final.render.jobs
        return RendererBenchmarkRunSummary(
            profile: final.tuning.profile,
            repeatNumber: final.window.repeatNumber,
            renderCount: timings.total.count,
            renderP50Ms: timings.total.p50Ms,
            renderP95Ms: timings.total.p95Ms,
            renderMaximumMs: timings.total.maximumMs,
            blockLoadP95Ms: timings.blockLoad.p95Ms,
            drawP95Ms: timings.draw.p95Ms,
            buildingP95Ms: timings.buildingTotal.p95Ms,
            buildingProjectionP95Ms: timings.buildingProjection.p95Ms,
            buildingDrawP95Ms: timings.buildingDraw.p95Ms,
            uiMaximumGapMs: final.ui.maximumGapMs,
            flushP50Ms: final.displayFlush.p50Ms,
            flushP95Ms: final.displayFlush.p95Ms,
            flushMaximumMs: final.displayFlush.maximumMs,
            minimumInternalFree:
                final.memory.internalHeap.windowMinimumFree,
            minimumInternalLargest:
                final.memory.internalHeap.windowMinimumLargestBlock,
            minimumPsramFree: final.memory.psram.windowMinimumFree,
            minimumPsramLargest:
                final.memory.psram.windowMinimumLargestBlock,
            minimumDmaFree: final.memory.dmaHeap.windowMinimumFree,
            minimumDmaLargest:
                final.memory.dmaHeap.windowMinimumLargestBlock,
            cryptoHeadroomRejections:
                final.memory.dmaHeap.cryptoHeadroomRejections,
            cryptoOperationFailures:
                final.memory.dmaHeap.cryptoOperationFailures,
            candidateBuildings: buildingMedian(\.candidates),
            selectedBuildings: buildingMedian(\.selected),
            extrudedBuildings: buildingMedian(\.extruded),
            flatBuildings: buildingMedian(\.flat),
            deferredBuildings: buildingMedian(\.deferred),
            oversizedBuildings: buildingMedian(\.oversized),
            renderedBuildings: buildingMedian(\.rendered),
            extrudedP90DistancePx: buildingMedian(\.extrudedP90DistancePx),
            extrudedFarthestDistancePx:
                buildingMedian(\.extrudedFarthestDistancePx),
            requestedRenders: jobs.requested,
            completedRenders: jobs.completed,
            publishedRenders: jobs.published,
            staleRenders: jobs.stale,
            cancelledRenders: jobs.cancelled,
            interruptedRenders: jobs.interrupted,
            coverageRejectedRenders: jobs.coverageRejected,
            invariantFailures: jobs.invariantFailed,
            maximumGpsPacketGapMs: final.gps.maximumPacketGapMs,
            gpsPackets: final.gps.packets,
            predictionGraceEntries: final.gps.predictionGraceEntries,
            predictionExhaustionEntries:
                final.gps.predictionExhaustionEntries,
            routeMarkersAccepted: final.routeReplay.accepted,
            routeMarkersRejected: final.routeReplay.rejected,
            remoteDebugCaptureErrors: final.remoteDebug.captureErrors
        )
    }

    static func identityFailures(
        snapshot: RendererBenchmarkMetricsSnapshot,
        baseline: RendererBenchmarkEvidenceIdentity,
        profile: RendererBenchmarkProfile,
        runId: String,
        repeatNumber: Int,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity,
        windowId: UInt32
    ) -> [String] {
        var failures: [String] = []
        if !snapshot.ok || snapshot.schema != 1 {
            failures.append("stale_identity:snapshot_envelope")
        }
        let identity = snapshot.identity
        let expectedPairs: [(String, Bool)] = [
            ("deviceId", identity.deviceId == baseline.deviceId),
            ("firmwareCommit", identity.firmwareCommit == baseline.firmwareCommit),
            ("board", identity.board == baseline.board),
            ("buildProfile", identity.buildProfile == baseline.buildProfile),
            ("bootId", identity.bootId == baseline.bootId),
            ("resetReason", identity.resetReason == baseline.resetReason),
        ]
        failures += expectedPairs.compactMap { key, matches in
            matches ? nil : "stale_identity:\(key)"
        }
        if snapshot.window.id != windowId {
            failures.append("stale_window:id")
        }
        if snapshot.window.runId != runId {
            failures.append("stale_window:runId")
        }
        if snapshot.window.repeatNumber != repeatNumber {
            failures.append("stale_window:repeat")
        }
        if snapshot.tuning.profile != profile.wireName {
            failures.append("stale_tuning:profile")
        }
        if snapshot.tuning.total != RendererBenchmarkQuota(
            records: 96,
            points: 8_192,
            projectedPixels: 220_000
        ) {
            failures.append("stale_tuning:total_quota")
        }
        if snapshot.tuning.extrusion != profile.expectedExtrusionQuota {
            failures.append("stale_tuning:extrusion_quota")
        }
        if snapshot.tuning.minimumExtrusionAreaPx2 != 6 {
            failures.append("stale_tuning:minimum_area")
        }
        if snapshot.tuning.fingerprint != profile.expectedTuningFingerprint {
            failures.append("stale_tuning:fingerprint")
        }
        if snapshot.memory.dmaHeap.cryptoCountersScope != "window" {
            failures.append("stale_identity:crypto_counter_scope")
        }
        if identity.mapFixture != mapFixture {
            failures.append("stale_identity:map_fixture")
        }
        if identity.routeFixture != routeFixture {
            failures.append("stale_identity:route_fixture")
        }
        return failures
    }

    static func evaluate(
        snapshots: [RendererBenchmarkMetricsSnapshot],
        samples: [RendererBenchmarkEvidenceSample],
        summary: RendererBenchmarkRunSummary,
        durationSeconds: Int,
        screenshotCount: Int,
        checkpointCount: Int,
        expectedRouteSampleCount: Int,
        gates: RendererBenchmarkGates
    ) -> [String] {
        var failures: [String] = []
        let absolute = gates.absolute
        let expectedSamples = Int(floor(
            Double(durationSeconds) / gates.pollIntervalSeconds *
                absolute.minimumMetricsSampleFraction
        ))
        if samples.count < expectedSamples {
            failures.append(
                "missing_metrics_samples:\(samples.count)<\(expectedSamples)"
            )
        }
        if summary.renderCount < absolute.minimumRenderSamples {
            failures.append("missing_render_samples")
        }
        if summary.candidateBuildings < absolute.minimumBuildingCandidates {
            failures.append("building_fixture_not_dense_enough")
        }
        if summary.selectedBuildings < absolute.minimumSelectedBuildings {
            failures.append("insufficient_selected_buildings")
        }
        if summary.profile == RendererBenchmarkProfile.flat.wireName {
            if summary.extrudedBuildings != 0 {
                failures.append("flat_control_extruded_buildings")
            }
        } else if summary.extrudedBuildings <
                    absolute.minimumExtrudedBuildingsFor3DProfile {
            failures.append("insufficient_extruded_buildings")
        }
        let requiredGPS = Int(floor(
            Double(durationSeconds) / 60 *
                Double(absolute.minimumGpsPacketsPerMinute)
        ))
        if summary.gpsPackets < requiredGPS {
            failures.append("missing_gps_packets")
        }
        let requiredMarkers = Int(floor(
            Double(durationSeconds) / 60 *
                Double(absolute.minimumRouteMarkersPerMinute)
        ))
        if summary.routeMarkersAccepted < requiredMarkers {
            failures.append("missing_route_markers")
        }
        if summary.routeMarkersRejected != 0 {
            failures.append("rejected_route_marker")
        }
        if screenshotCount != checkpointCount {
            failures.append("missing_checkpoint_screenshot")
        }

        func minimum(
            _ value: UInt32,
            _ limit: UInt32,
            _ label: String
        ) {
            if value < limit { failures.append("\(label):\(value)") }
        }
        func maximum(
            _ value: UInt32,
            _ limit: UInt32,
            _ label: String
        ) {
            if value > limit { failures.append("\(label):\(value)") }
        }
        minimum(summary.minimumInternalFree,
                absolute.minimumInternalFreeBytes, "internal_free_floor")
        minimum(summary.minimumInternalLargest,
                absolute.minimumInternalLargestBlockBytes,
                "internal_largest_floor")
        minimum(summary.minimumPsramFree,
                absolute.minimumPsramFreeBytes, "psram_free_floor")
        minimum(summary.minimumPsramLargest,
                absolute.minimumPsramLargestBlockBytes,
                "psram_largest_floor")
        minimum(summary.minimumDmaFree,
                absolute.minimumDmaFreeBytes, "dma_free_floor")
        minimum(summary.minimumDmaLargest,
                absolute.minimumDmaLargestBlockBytes, "dma_largest_floor")
        maximum(summary.cryptoHeadroomRejections,
                absolute.maximumCryptoHeadroomRejections,
                "crypto_headroom_rejections")
        maximum(summary.cryptoOperationFailures,
                absolute.maximumCryptoOperationFailures,
                "crypto_operation_failures")
        maximum(summary.renderP95Ms,
                absolute.maximumRenderP95Ms, "render_p95")
        maximum(summary.uiMaximumGapMs,
                absolute.maximumUiGapMs, "ui_gap")
        maximum(summary.flushP95Ms,
                absolute.maximumFlushP95Ms, "flush_p95")
        maximum(summary.flushMaximumMs,
                absolute.maximumFlushMs, "flush_maximum")
        maximum(summary.maximumGpsPacketGapMs,
                absolute.maximumGpsPacketGapMs, "gps_packet_gap")
        maximum(summary.staleRenders,
                absolute.maximumStaleRenders, "stale_renders")
        maximum(summary.cancelledRenders,
                absolute.maximumCancelledRenders, "cancelled_renders")
        maximum(summary.interruptedRenders,
                absolute.maximumInterruptedRenders, "interrupted_renders")
        maximum(summary.coverageRejectedRenders,
                absolute.maximumCoverageRejectedRenders,
                "coverage_rejections")
        maximum(summary.predictionExhaustionEntries,
                absolute.maximumPredictionExhaustionEntries,
                "prediction_exhaustion")
        maximum(summary.invariantFailures,
                absolute.maximumInvariantFailures, "invariant_failure")
        maximum(summary.remoteDebugCaptureErrors,
                absolute.maximumRemoteDebugCaptureErrors,
                "remote_debug_capture_error")

        if snapshots.contains(where: { $0.render.buildings.allocationFallback }) {
            failures.append("allocation_fallback")
        }
        if snapshots.contains(where: {
            $0.routeReplay.valid && !$0.routeReplay.fixtureMatches
        }) {
            failures.append("route_fixture_mismatch")
        }
        if snapshots.contains(where: { !$0.remoteDebug.active }) {
            failures.append("remote_debug_inactive")
        }

        var firstMarkerPosition: UInt64?
        var lastMarkerPosition: UInt64?
        var lastMarkerProgressMs: UInt32?
        for (snapshot, sample) in zip(snapshots, samples) {
            let replay = snapshot.routeReplay
            let valid = replay.valid && replay.fixtureMatches &&
                replay.sampleCount == expectedRouteSampleCount &&
                replay.sampleIndex >= 0 &&
                replay.sampleIndex < replay.sampleCount
            if !valid {
                if sample.elapsedSeconds * 1_000 >
                    Double(absolute.maximumRouteMarkerAgeMs) {
                    failures.append("missing_or_invalid_route_marker")
                }
                continue
            }
            let markerAge = snapshot.timestampMs &- replay.receivedAtMs
            if markerAge >= 0x8000_0000 ||
                markerAge > absolute.maximumRouteMarkerAgeMs {
                failures.append("stale_route_marker")
            }
            let position = UInt64(replay.loop) * UInt64(replay.sampleCount) +
                UInt64(replay.sampleIndex)
            if let previous = lastMarkerPosition {
                if position > previous {
                    lastMarkerPosition = position
                    lastMarkerProgressMs = snapshot.timestampMs
                } else if position < previous {
                    failures.append("route_marker_regressed")
                } else if let lastMarkerProgressMs {
                    let stalled = snapshot.timestampMs &- lastMarkerProgressMs
                    if stalled >= 0x8000_0000 ||
                        stalled > absolute.maximumRouteMarkerStallMs {
                        failures.append("stalled_route_marker")
                    }
                }
            } else {
                firstMarkerPosition = position
                lastMarkerPosition = position
                lastMarkerProgressMs = snapshot.timestampMs
            }
        }
        let minimumProgress = max(0, durationSeconds - 2)
        let observedProgress: UInt64
        if let firstMarkerPosition, let lastMarkerPosition {
            observedProgress = lastMarkerPosition - firstMarkerPosition
        } else {
            observedProgress = 0
        }
        if observedProgress < minimumProgress {
            failures.append(
                "incomplete_route_progress:\(observedProgress)<\(minimumProgress)"
            )
        }
        if summary.routeMarkersAccepted < minimumProgress {
            failures.append(
                "incomplete_route_cadence:\(summary.routeMarkersAccepted)<\(minimumProgress)"
            )
        }

        let trendChecks: [([UInt32], UInt32, String)] = [
            (samples.map(\.internalFree),
             gates.trend.internalFreeAllowedDeclineBytes,
             "internal_free_decline"),
            (samples.map(\.internalLargest),
             gates.trend.internalLargestAllowedDeclineBytes,
             "internal_largest_decline"),
            (samples.map(\.psramFree),
             gates.trend.psramFreeAllowedDeclineBytes,
             "psram_free_decline"),
            (samples.map(\.psramLargest),
             gates.trend.psramLargestAllowedDeclineBytes,
             "psram_largest_decline"),
            (samples.map(\.dmaFree),
             gates.trend.dmaFreeAllowedDeclineBytes,
             "dma_free_decline"),
            (samples.map(\.dmaLargest),
             gates.trend.dmaLargestAllowedDeclineBytes,
             "dma_largest_decline"),
        ]
        if samples.count < gates.trend.minimumSamples {
            failures.append(
                "missing_memory_trend_samples:\(samples.count)<\(gates.trend.minimumSamples)"
            )
        }
        for (values, allowed, label) in trendChecks where monotonicDecline(
            values,
            minimumSamples: gates.trend.minimumSamples,
            allowedDecline: allowed
        ) {
            failures.append(label)
        }
        return Array(Set(failures)).sorted()
    }

    static func applyCrossRunMemoryGates(
        runs: inout [RendererBenchmarkRunEvidence],
        gates: RendererBenchmarkGates
    ) {
        struct Check {
            let value: (RendererBenchmarkRunEvidence) -> UInt32
            let allowed: UInt32
            let label: String
        }
        // Per-window minima remain authoritative for the unchanged absolute
        // safety floors. Cross-run retention instead compares the standardized
        // current heap state in each terminal metrics snapshot: a minimum may
        // be set by any transient render, checkpoint, TLS, or polling phase and
        // is therefore not evidence that memory remained allocated.
        let checks = [
            Check(value: { $0.finalSnapshot.memory.internalHeap.free },
                  allowed: gates.trend.crossRunInternalAllowedDeclineBytes,
                  label: "cross_run_internal_decline"),
            Check(value: {
                $0.finalSnapshot.memory.internalHeap.largestBlock
            }, allowed: gates.trend.crossRunInternalAllowedDeclineBytes,
               label: "cross_run_internal_largest_decline"),
            Check(value: { $0.finalSnapshot.memory.psram.free },
                  allowed: gates.trend.crossRunPsramAllowedDeclineBytes,
                  label: "cross_run_psram_decline"),
            Check(value: { $0.finalSnapshot.memory.psram.largestBlock },
                  allowed: gates.trend.crossRunPsramAllowedDeclineBytes,
                  label: "cross_run_psram_largest_decline"),
            Check(value: { $0.finalSnapshot.memory.dmaHeap.free },
                  allowed: gates.trend.crossRunDmaAllowedDeclineBytes,
                  label: "cross_run_dma_decline"),
            Check(value: {
                $0.finalSnapshot.memory.dmaHeap.largestBlock
            }, allowed: gates.trend.crossRunDmaAllowedDeclineBytes,
               label: "cross_run_dma_largest_decline"),
        ]
        for profile in RendererBenchmarkProfile.allCases {
            let indexes = runs.indices.filter {
                runs[$0].profile == profile.wireName
            }.sorted {
                runs[$0].repeatNumber < runs[$1].repeatNumber
            }
            guard indexes.count >=
                    SecureRendererBenchmarkPlan.comparisonRepeats else {
                continue
            }
            for check in checks {
                let values = indexes.map { check.value(runs[$0]) }
                guard progressiveCrossRunDecline(
                    values,
                    allowedDecline: check.allowed
                ) else { continue }
                for index in indexes {
                    runs[index].failures = Array(Set(
                        runs[index].failures + [check.label]
                    )).sorted()
                    runs[index].passed = false
                }
            }
        }
    }

    static func aggregate(
        runs: [RendererBenchmarkRunEvidence]
    ) -> [String: RendererBenchmarkProfileAggregate] {
        var result: [String: RendererBenchmarkProfileAggregate] = [:]
        for profile in RendererBenchmarkProfile.allCases {
            let selected = runs.filter { $0.profile == profile.wireName }
            guard !selected.isEmpty else { continue }
            func medianSummary(
                _ value: (RendererBenchmarkRunSummary) -> Double
            ) -> Double {
                median(selected.map { value($0.summary) })
            }
            result[profile.wireName] = RendererBenchmarkProfileAggregate(
                passed: selected.allSatisfy(\.passed),
                runCount: selected.count,
                failedRuns: selected.filter { !$0.passed }.count,
                renderP95Ms: medianSummary { Double($0.renderP95Ms) },
                buildingP95Ms: medianSummary { Double($0.buildingP95Ms) },
                uiMaximumGapMs:
                    medianSummary { Double($0.uiMaximumGapMs) },
                flushP95Ms: medianSummary { Double($0.flushP95Ms) },
                minimumInternalFree:
                    medianSummary { Double($0.minimumInternalFree) },
                minimumInternalLargest:
                    medianSummary { Double($0.minimumInternalLargest) },
                minimumPsramFree:
                    medianSummary { Double($0.minimumPsramFree) },
                minimumPsramLargest:
                    medianSummary { Double($0.minimumPsramLargest) },
                minimumDmaFree:
                    medianSummary { Double($0.minimumDmaFree) },
                minimumDmaLargest:
                    medianSummary { Double($0.minimumDmaLargest) },
                cryptoHeadroomRejections:
                    medianSummary { Double($0.cryptoHeadroomRejections) },
                cryptoOperationFailures:
                    medianSummary { Double($0.cryptoOperationFailures) },
                candidateBuildings: medianSummary(\.candidateBuildings),
                selectedBuildings: medianSummary(\.selectedBuildings),
                extrudedBuildings: medianSummary(\.extrudedBuildings),
                flatBuildings: medianSummary(\.flatBuildings),
                deferredBuildings: medianSummary(\.deferredBuildings),
                oversizedBuildings: medianSummary(\.oversizedBuildings),
                renderedBuildings: medianSummary(\.renderedBuildings),
                extrudedP90DistancePx:
                    medianSummary(\.extrudedP90DistancePx),
                extrudedFarthestDistancePx:
                    medianSummary(\.extrudedFarthestDistancePx)
            )
        }
        return result
    }

    static func selectCandidate(
        aggregate: [String: RendererBenchmarkProfileAggregate],
        gates: RendererBenchmarkGates
    ) -> RendererBenchmarkCandidateSelection {
        guard let current = aggregate[RendererBenchmarkProfile.current.wireName],
              current.passed else {
            return RendererBenchmarkCandidateSelection(
                selected: nil,
                frontier: [],
                idealDistances: [:],
                exclusions: ["all": ["current baseline did not pass"]]
            )
        }
        let relative = gates.candidateRelativeToCurrent
        let considered: [RendererBenchmarkProfile] = [.current, .medium, .high]
        var candidates: [RendererBenchmarkProfile] = []
        var exclusions: [String: [String]] = [:]
        for profile in considered {
            guard let value = aggregate[profile.wireName], value.passed else {
                exclusions[profile.wireName] = ["absolute gates failed"]
                continue
            }
            var reasons: [String] = []
            if value.renderP95Ms > current.renderP95Ms *
                relative.maximumRenderP95Multiplier {
                reasons.append("render p95 regressed beyond current multiplier")
            }
            if value.uiMaximumGapMs > current.uiMaximumGapMs *
                relative.maximumUiGapMultiplier {
                reasons.append("UI gap regressed beyond current multiplier")
            }
            if value.minimumInternalFree < current.minimumInternalFree -
                Double(relative.maximumInternalHeadroomLossBytes) {
                reasons.append("internal headroom loss exceeded")
            }
            if value.minimumPsramFree < current.minimumPsramFree -
                Double(relative.maximumPsramHeadroomLossBytes) {
                reasons.append("PSRAM headroom loss exceeded")
            }
            if value.minimumDmaFree < current.minimumDmaFree -
                Double(relative.maximumDmaHeadroomLossBytes) {
                reasons.append("DMA headroom loss exceeded")
            }
            if profile != .current {
                let reachGain = max(
                    value.extrudedBuildings /
                        max(current.extrudedBuildings, 1) - 1,
                    value.extrudedP90DistancePx /
                        max(current.extrudedP90DistancePx, 1) - 1,
                    value.extrudedFarthestDistancePx /
                        max(current.extrudedFarthestDistancePx, 1) - 1
                )
                let deferredImproved =
                    value.flatBuildings + value.deferredBuildings <
                    current.flatBuildings + current.deferredBuildings
                if reachGain < relative.minimumReachGainFraction &&
                    !deferredImproved {
                    reasons.append("no material measured reach gain")
                }
            }
            if reasons.isEmpty {
                candidates.append(profile)
            } else {
                exclusions[profile.wireName] = reasons
            }
        }

        func benefits(_ profile: RendererBenchmarkProfile) -> [Double] {
            guard let value = aggregate[profile.wireName] else { return [] }
            return [
                value.extrudedBuildings,
                value.extrudedP90DistancePx,
                value.extrudedFarthestDistancePx,
                -(value.flatBuildings + value.deferredBuildings),
            ]
        }
        func costs(_ profile: RendererBenchmarkProfile) -> [Double] {
            guard let value = aggregate[profile.wireName] else { return [] }
            return [
                value.renderP95Ms,
                value.buildingP95Ms,
                value.uiMaximumGapMs,
                -value.minimumInternalFree,
                -value.minimumPsramFree,
                -value.minimumDmaFree,
            ]
        }
        let frontier = candidates.filter { profile in
            !candidates.contains { other in
                guard other != profile else { return false }
                let otherBenefits = benefits(other)
                let profileBenefits = benefits(profile)
                let otherCosts = costs(other)
                let profileCosts = costs(profile)
                return zip(otherBenefits, profileBenefits)
                    .allSatisfy { $0 >= $1 } &&
                    zip(otherCosts, profileCosts)
                    .allSatisfy { $0 <= $1 } &&
                    (otherBenefits != profileBenefits ||
                        otherCosts != profileCosts)
            }
        }
        guard !frontier.isEmpty else {
            return RendererBenchmarkCandidateSelection(
                selected: nil,
                frontier: [],
                idealDistances: [:],
                exclusions: exclusions
            )
        }
        let benefitRows = Dictionary(uniqueKeysWithValues:
            frontier.map { ($0, benefits($0)) })
        let costRows = Dictionary(uniqueKeysWithValues:
            frontier.map { ($0, costs($0)) })
        func normalizedAverage(
            _ profile: RendererBenchmarkProfile,
            rows: [RendererBenchmarkProfile: [Double]]
        ) -> Double {
            guard let row = rows[profile], !row.isEmpty else { return 0 }
            return row.indices.map { index in
                let column = rows.values.map { $0[index] }
                guard let low = column.min(), let high = column.max() else {
                    return 0.5
                }
                return high == low ? 0.5 : (row[index] - low) / (high - low)
            }.reduce(0, +) / Double(row.count)
        }
        var distances: [String: Double] = [:]
        for profile in frontier {
            let benefitScore = normalizedAverage(profile, rows: benefitRows)
            let costScore = normalizedAverage(profile, rows: costRows)
            distances[profile.wireName] = hypot(1 - benefitScore, costScore)
        }
        let order = RendererBenchmarkProfile.allCases
        let selected = frontier.min {
            let left = distances[$0.wireName] ?? .infinity
            let right = distances[$1.wireName] ?? .infinity
            if left != right { return left < right }
            return (order.firstIndex(of: $0) ?? Int.max) <
                (order.firstIndex(of: $1) ?? Int.max)
        }
        return RendererBenchmarkCandidateSelection(
            selected: selected?.wireName,
            frontier: frontier.map(\.wireName),
            idealDistances: distances,
            exclusions: exclusions
        )
    }

    static func progressiveCrossRunDecline(
        _ values: [UInt32],
        allowedDecline: UInt32
    ) -> Bool {
        guard values.count >= 3 else { return false }
        let normalized = values.map(Int64.init)
        let allowed = max(Int64(0), Int64(allowedDecline))
        let continuationNoise = max(Int64(1), allowed / 4)
        let totalDecline = normalized[0] - normalized[normalized.count - 1]
        guard totalDecline > allowed else { return false }

        var downwardSteps: [Int64] = []
        downwardSteps.reserveCapacity(normalized.count - 1)
        for (previous, current) in zip(
            normalized,
            normalized.dropFirst()
        ) {
            let delta = previous - current
            // A rebound larger than the bounded noise allowance contradicts a
            // progressive retained-state decline.
            if delta < -continuationNoise { return false }
            downwardSteps.append(max(Int64(0), delta))
        }
        guard let largestStep = downwardSteps.max() else { return false }
        // Discount one one-time cache/session transition. A real progressive
        // leak or fragmentation trend must continue beyond that single step.
        let continuedDecline =
            downwardSteps.reduce(Int64(0), +) - largestStep
        return continuedDecline > continuationNoise
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func monotonicDecline(
        _ values: [UInt32],
        minimumSamples: Int,
        allowedDecline: UInt32
    ) -> Bool {
        guard values.count >= minimumSamples else { return false }
        let width = max(3, values.count / 5)
        var sections: [Double] = []
        var index = 0
        while index + width <= values.count {
            sections.append(median(
                values[index..<(index + width)].map(Double.init)
            ))
            index += width
        }
        guard sections.count >= 3 else { return false }
        let totalDecline = sections[0] - sections[sections.count - 1]
        let nonincreasing = zip(sections, sections.dropFirst())
            .filter { $0 >= $1 }.count
        let meanX = Double(values.count - 1) / 2
        let meanY = values.map(Double.init).reduce(0, +) /
            Double(values.count)
        let denominator = values.indices.map {
            pow(Double($0) - meanX, 2)
        }.reduce(0, +)
        let numerator = values.enumerated().map { index, value in
            (Double(index) - meanX) * (Double(value) - meanY)
        }.reduce(0, +)
        let slope = denominator == 0 ? 0 : numerator / denominator
        return totalDecline > Double(allowedDecline) &&
            nonincreasing >= sections.count - 2 &&
            slope < -(Double(allowedDecline) /
                Double(max(values.count - 1, 1)))
    }
}

nonisolated struct RendererBenchmarkDecodedFrame: Equatable, Sendable {
    let sequence: UInt32
    let capturedAtMs: UInt32
    let width: Int
    let height: Int
    let rgba: Data
}

nonisolated enum RendererBenchmarkFrameDecoder {
    static let headerByteCount = 32

    static func decode(
        _ data: Data,
        expectedPanelWidth: Int,
        expectedPanelHeight: Int,
        rotationQuarters: Int
    ) throws -> RendererBenchmarkDecodedFrame {
        guard data.count >= headerByteCount,
              Data(data.prefix(4)) == Data("BCF1".utf8),
              let headerBytes = uint16(data, at: 4),
              let flags = uint16(data, at: 6),
              let sequence = uint32(data, at: 8),
              let capturedAtMs = uint32(data, at: 12),
              let widthValue = uint16(data, at: 16),
              let heightValue = uint16(data, at: 18),
              let strideValue = uint16(data, at: 20),
              let payloadBytes = uint32(data, at: 24),
              let expectedCRC = uint32(data, at: 28),
              headerBytes >= headerByteCount,
              flags == 0,
              data[22] == 1,
              data[23] == 0,
              rotationQuarters >= 0,
              rotationQuarters <= 3 else {
            throw SecureRendererBenchmarkProtocolError.invalidFrame
        }
        let width = Int(widthValue)
        let height = Int(heightValue)
        let stride = Int(strideValue)
        let headerCount = Int(headerBytes)
        guard width == expectedPanelWidth,
              height == expectedPanelHeight,
              stride >= width * 2,
              payloadBytes == UInt32(stride * height),
              data.count == headerCount + Int(payloadBytes) else {
            throw SecureRendererBenchmarkProtocolError.invalidFrame
        }
        let pixels = Data(data[headerCount...])
        guard crc32(pixels) == expectedCRC else {
            throw SecureRendererBenchmarkProtocolError.invalidFrame
        }
        let outputWidth = rotationQuarters.isMultiple(of: 2) ? width : height
        let outputHeight = rotationQuarters.isMultiple(of: 2) ? height : width
        var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * stride + x * 2
                let value = UInt16(pixels[source]) |
                    (UInt16(pixels[source + 1]) << 8)
                let destination: (x: Int, y: Int)
                switch rotationQuarters {
                case 1: destination = (y, width - 1 - x)
                case 2: destination = (width - 1 - x, height - 1 - y)
                case 3: destination = (height - 1 - y, x)
                default: destination = (x, y)
                }
                let offset =
                    (destination.y * outputWidth + destination.x) * 4
                output[offset] = UInt8(((value >> 11) & 0x1f) * 255 / 31)
                output[offset + 1] = UInt8(
                    ((value >> 5) & 0x3f) * 255 / 63
                )
                output[offset + 2] = UInt8((value & 0x1f) * 255 / 31)
                output[offset + 3] = 255
            }
        }
        return RendererBenchmarkDecodedFrame(
            sequence: sequence,
            capturedAtMs: capturedAtMs,
            width: outputWidth,
            height: outputHeight,
            rgba: Data(output)
        )
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xedb8_8320
                    : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard let low = uint16(data, at: offset),
              let high = uint16(data, at: offset + 2) else { return nil }
        return UInt32(low) | (UInt32(high) << 16)
    }
}
#endif
