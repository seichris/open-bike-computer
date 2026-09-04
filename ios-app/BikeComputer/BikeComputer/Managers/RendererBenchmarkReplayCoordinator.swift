#if DEBUG
import Combine
import Foundation
import UIKit

@MainActor
final class RendererBenchmarkReplayCoordinator: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCadenceActive = false
    @Published private(set) var fixtureID = ""
    @Published private(set) var sampleIndex = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var loop: UInt32 = 0
    @Published private(set) var status = "Idle"
    @Published private(set) var errorMessage: String?
    @Published private(set) var ordinarySnapshotCount = 0
    @Published var selectedOrdinaryProfile = RendererBenchmarkProfile.current

    private weak var bleManager: BLEManager?
    private var fixture: RendererBenchmarkFixture?
    private var fixtureSHA256 = Data()
    private var timer: Timer?
    private var emittedSampleCount: UInt64 = 0
    private var capturedRendererRevision: UInt64 = 0
    private var ordinarySnapshots: [String] = []
    private var ordinaryRepeatNumber: UInt16 = 0
    private var idleTimerWasDisabled = false
    private var ownsIdleTimerOverride = false
    private var deviceGPSOverrideToken: UUID?
    private var expectedReplayTimerUptime: TimeInterval?
    private var replayTimerCallbacks: UInt64 = 0
    private var lastReplayTimerLatenessMs: Int = 0
    private var maximumReplayTimerLatenessMs: Int = 0

    deinit {
        timer?.invalidate()
        let manager = bleManager
        let token = deviceGPSOverrideToken
        let shouldRestoreIdleTimer = ownsIdleTimerOverride
        let priorIdleTimerState = idleTimerWasDisabled
        Task { @MainActor [weak manager] in
            if let token {
                manager?.endDeviceGPSOverride(token)
            }
            if shouldRestoreIdleTimer {
                UIApplication.shared.isIdleTimerDisabled = priorIdleTimerState
            }
        }
    }

    var progressDescription: String {
        guard isRunning, sampleCount > 0 else { return status }
        return "Sample \(sampleIndex + 1)/\(sampleCount), loop \(loop + 1)"
    }

    /// Manual developer replay keeps its historical one-tap behavior. The
    /// secure sweep uses prepare(), then emits only after its HTTP measurement
    /// window has been confirmed.
    func start(
        bleManager: BLEManager,
        isNavigationActive: Bool,
        bundle: Bundle = .main
    ) {
        prepare(
            bleManager: bleManager,
            isNavigationActive: isNavigationActive,
            bundle: bundle
        )
        guard isRunning, let loadedFixture = fixture else { return }

        if !bleManager.supportsRemoteDeviceDebug {
            advanceOrdinaryRepeatNumber()
            guard bleManager.beginRendererBenchmarkWindow(
                profile: selectedOrdinaryProfile,
                repeatNumber: ordinaryRepeatNumber,
                runNonce: UInt64.random(in: 1...UInt64.max),
                fixtureSHA256: fixtureSHA256,
                fixtureID: loadedFixture.id
            ) else {
                errorMessage = "The ordinary benchmark window could not be queued."
                status = "Window failed"
                stop(clearRoute: false, restoreCurrent: false)
                return
            }
        }

        guard emitInitialSample(), startCadence() else {
            if isRunning {
                errorMessage = "The renderer replay could not begin."
                status = "Stopped"
                stop()
            }
            return
        }
    }

    /// Acquires and validates every replay resource, but deliberately emits no
    /// route, GPS, or marker and starts no timer. This is the secure sweep's
    /// armed state.
    func prepare(
        bleManager: BLEManager,
        isNavigationActive: Bool,
        bundle: Bundle = .main
    ) {
        stop(clearRoute: false, restoreCurrent: false)
        guard !isNavigationActive else {
            errorMessage = "Stop navigation before starting the renderer replay."
            status = "Navigation active"
            return
        }
        guard bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics,
              bleManager.supportsRendererBenchmarkSample else {
            errorMessage =
                "Connect diagnostics firmware with atomic renderer replay support first."
            status = "Unavailable"
            return
        }

        do {
            let loaded = try RendererBenchmarkFixture.load(bundle: bundle)
            self.bleManager = bleManager
            fixture = loaded.fixture
            fixtureSHA256 = loaded.sha256
            fixtureID = loaded.fixture.id
            sampleIndex = 0
            sampleCount = loaded.fixture.points.count
            loop = 0
            emittedSampleCount = 0
            expectedReplayTimerUptime = nil
            replayTimerCallbacks = 0
            lastReplayTimerLatenessMs = 0
            maximumReplayTimerLatenessMs = 0
            capturedRendererRevision = bleManager.rendererDiagnosticsRevision
            ordinarySnapshots.removeAll(keepingCapacity: true)
            ordinarySnapshotCount = 0
            guard let overrideToken = bleManager.beginDeviceGPSOverride() else {
                errorMessage = "Another developer GPS override is already active."
                status = "GPS unavailable"
                self.bleManager = nil
                return
            }
            deviceGPSOverrideToken = overrideToken
            errorMessage = nil
            status = "Armed"
            isRunning = true
            isCadenceActive = false
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            ownsIdleTimerOverride = true
        } catch {
            errorMessage = error.localizedDescription
            status = "Fixture failed"
        }
    }

    func pauseCadence() {
        timer?.invalidate()
        timer = nil
        expectedReplayTimerUptime = nil
        isCadenceActive = false
        if isRunning {
            status = "Armed"
        }
    }

    /// Emits exactly one forced route-plus-RBS1 transaction while cadence is
    /// paused. The controller calls this only after firmware confirms the
    /// corresponding measurement window.
    @discardableResult
    func emitInitialSample() -> Bool {
        guard isRunning, !isCadenceActive else { return false }
        let previousCount = emittedSampleCount
        emitCurrentSample(forceRoute: true)
        return isRunning && emittedSampleCount == (previousCount &+ 1)
    }

    /// Starts the one-Hz timer without an immediate extra emission.
    @discardableResult
    func startCadence() -> Bool {
        guard isRunning, !isCadenceActive, timer == nil else { return false }
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(handleReplayTimer(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.05
        self.timer = timer
        expectedReplayTimerUptime =
            ProcessInfo.processInfo.systemUptime + 1
        replayTimerCallbacks = 0
        RunLoop.main.add(timer, forMode: .common)
        isCadenceActive = true
        status = "Running at 1 Hz"
        return true
    }

    func stop(clearRoute: Bool = true, restoreCurrent: Bool = true) {
        captureLatestOrdinarySnapshot()
        pauseCadence()
        if clearRoute, isRunning {
            bleManager?.clearRouteGeometry()
        }
        if restoreCurrent {
            restoreCurrentProfileIfNeeded()
        }
        releaseDeviceGPSOverride()
        if ownsIdleTimerOverride {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            ownsIdleTimerOverride = false
        }
        isRunning = false
        isCadenceActive = false
        if status == "Armed" || status == "Running at 1 Hz" {
            status = "Stopped"
        }
        bleManager = nil
        fixture = nil
    }

    private func releaseDeviceGPSOverride() {
        guard let token = deviceGPSOverrideToken else { return }
        bleManager?.endDeviceGPSOverride(token)
        deviceGPSOverrideToken = nil
    }

    func ordinaryCaptureJSON() -> String? {
        RendererOrdinaryDiagnosticsCapture.json(
            fixtureID: fixtureID,
            fixtureSHA256: fixtureSHA256,
            snapshots: ordinarySnapshots
        )
    }

    @objc private func handleReplayTimer(_ timer: Timer) {
        guard isRunning, isCadenceActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let expectedReplayTimerUptime {
            let latenessMs = Int(max(
                0,
                (now - expectedReplayTimerUptime) * 1_000
            ).rounded())
            lastReplayTimerLatenessMs = latenessMs
            maximumReplayTimerLatenessMs = max(
                maximumReplayTimerLatenessMs,
                latenessMs
            )
            self.expectedReplayTimerUptime = max(
                expectedReplayTimerUptime + 1,
                now + 1
            )
        } else {
            expectedReplayTimerUptime = now + 1
        }
        replayTimerCallbacks &+= 1
        emitCurrentSample()
    }

    func rendererBenchmarkReplayTimingEvidence()
        -> RendererBenchmarkReplayTimingEvidence {
        RendererBenchmarkReplayTimingEvidence(
            schema: 1,
            emittedSamples: emittedSampleCount,
            timerCallbacks: replayTimerCallbacks,
            lastTimerLatenessMs: lastReplayTimerLatenessMs,
            maximumTimerLatenessMs: maximumReplayTimerLatenessMs
        )
    }

    private func emitCurrentSample(forceRoute: Bool = false) {
        guard isRunning,
              let bleManager,
              bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics,
              bleManager.supportsRendererBenchmarkSample,
              let fixture,
              fixture.points.indices.contains(sampleIndex),
              let routeData = RendererBenchmarkRouteGeometry.data(
                fixture: fixture,
                sampleIndex: sampleIndex
              ) else {
            errorMessage = "The benchmark replay lost its BLE connection."
            status = "Stopped"
            stop()
            return
        }

        captureLatestOrdinarySnapshot()

        let point = fixture.points[sampleIndex]
        let nextIndex = (sampleIndex + 1) % fixture.points.count
        let next = fixture.points[nextIndex]
        let heading = NavigationHeading.bearing(
            from: point.coordinate,
            to: next.coordinate
        )
        if forceRoute || emittedSampleCount % 2 == 0 {
            guard bleManager.sendRendererBenchmarkRouteGeometry(routeData) else {
                errorMessage =
                    "The acknowledged benchmark route window could not be queued."
                status = "Stopped"
                stop()
                return
            }
        }

        let now = Date()
        let gpsPosition = DeviceGPSPacketBuilder.data(
            lat: point.latitude,
            lon: point.longitude,
            heading: DeviceGPSHeadingWirePolicy.heading(
                heading,
                supportsExplicitInvalidHeading:
                    bleManager.supportsExplicitInvalidGPSHeading
            ),
            speedMetersPerSecond: fixture.nominalSpeedMetersPerSecond,
            altitudeMeters: 8,
            distanceTraveledMeters:
                Double(emittedSampleCount) *
                fixture.nominalSpeedMetersPerSecond,
            elapsedSeconds: Double(emittedSampleCount),
            routeRemainingMeters:
                Double(fixture.points.count - sampleIndex) *
                fixture.nominalSpeedMetersPerSecond,
            horizontalAccuracyMeters: 3,
            locationTimestamp: now,
            includeRideDetectionQuality:
                bleManager.supportsGPSPositionQualityV1
        )
        guard bleManager.sendRendererBenchmarkSample(
            gpsPosition: gpsPosition,
            fixtureSHA256: fixtureSHA256,
            sampleIndex: sampleIndex,
            sampleCount: fixture.points.count,
            loop: loop
        ) else {
            errorMessage =
                "The acknowledged atomic benchmark sample could not be queued."
            status = "Stopped"
            stop()
            return
        }

        if !bleManager.supportsRemoteDeviceDebug &&
            emittedSampleCount > 0 &&
            emittedSampleCount % 5 == 0 {
            _ = bleManager.requestRendererDiagnosticsSnapshot()
        }

        emittedSampleCount &+= 1
        if nextIndex == 0 {
            loop &+= 1
        }
        sampleIndex = nextIndex
    }

    private func captureLatestOrdinarySnapshot() {
        guard let bleManager,
              !bleManager.supportsRemoteDeviceDebug,
              bleManager.rendererDiagnosticsRevision !=
                capturedRendererRevision,
              let snapshot = bleManager.rendererDiagnosticsSnapshotJSON else {
            return
        }
        capturedRendererRevision = bleManager.rendererDiagnosticsRevision
        ordinarySnapshots.append(snapshot)
        if ordinarySnapshots.count >
            RendererOrdinaryDiagnosticsCapture.maximumSnapshotCount {
            ordinarySnapshots.removeFirst(
                ordinarySnapshots.count -
                    RendererOrdinaryDiagnosticsCapture.maximumSnapshotCount
            )
        }
        ordinarySnapshotCount = ordinarySnapshots.count
    }

    private func restoreCurrentProfileIfNeeded() {
        guard isRunning,
              let bleManager,
              !bleManager.supportsRemoteDeviceDebug,
              RendererBenchmarkCleanupPolicy.requiresCurrentProfileRestore(
                after: selectedOrdinaryProfile
              ),
              fixture != nil,
              fixtureSHA256.count == 32,
              !fixtureID.isEmpty else {
            return
        }
        advanceOrdinaryRepeatNumber()
        let queued = bleManager.beginRendererBenchmarkWindow(
            profile: .current,
            repeatNumber: ordinaryRepeatNumber,
            runNonce: UInt64.random(in: 1...UInt64.max),
            fixtureSHA256: fixtureSHA256,
            fixtureID: fixtureID
        )
        if !queued {
            errorMessage =
                "Current-profile cleanup could not be queued; disconnect the Bike Computer to restore it."
            status = "Cleanup failed"
        }
    }

    private func advanceOrdinaryRepeatNumber() {
        ordinaryRepeatNumber = ordinaryRepeatNumber == UInt16.max ?
            1 : ordinaryRepeatNumber + 1
    }
}
#endif
