#if DEBUG
import Combine
import Foundation
import UIKit

@MainActor
final class RendererBenchmarkReplayCoordinator: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
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

    var progressDescription: String {
        guard isRunning, sampleCount > 0 else { return status }
        return "Sample \(sampleIndex + 1)/\(sampleCount), loop \(loop + 1)"
    }

    func start(bleManager: BLEManager, bundle: Bundle = .main) {
        stop(clearRoute: false, restoreCurrent: false)
        guard bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics else {
            errorMessage =
                "Connect an authenticated diagnostics firmware build first."
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
            capturedRendererRevision = bleManager.rendererDiagnosticsRevision
            ordinarySnapshots.removeAll(keepingCapacity: true)
            ordinarySnapshotCount = 0
            if !bleManager.supportsRemoteDeviceDebug {
                advanceOrdinaryRepeatNumber()
                guard bleManager.beginRendererBenchmarkWindow(
                    profile: selectedOrdinaryProfile,
                    repeatNumber: ordinaryRepeatNumber,
                    runNonce: UInt64.random(in: 1...UInt64.max),
                    fixtureSHA256: loaded.sha256,
                    fixtureID: loaded.fixture.id
                ) else {
                    errorMessage = "The ordinary benchmark window could not be queued."
                    status = "Window failed"
                    return
                }
            }
            errorMessage = nil
            status = "Running at 1 Hz"
            isRunning = true
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            ownsIdleTimerOverride = true
            emitCurrentSample()
            guard isRunning else { return }

            let timer = Timer(
                timeInterval: 1,
                target: self,
                selector: #selector(handleReplayTimer(_:)),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = 0.05
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            errorMessage = error.localizedDescription
            status = "Fixture failed"
        }
    }

    func stop(clearRoute: Bool = true, restoreCurrent: Bool = true) {
        captureLatestOrdinarySnapshot()
        timer?.invalidate()
        timer = nil
        if clearRoute, isRunning {
            bleManager?.clearRouteGeometry()
        }
        if restoreCurrent {
            restoreCurrentProfileIfNeeded()
        }
        if ownsIdleTimerOverride {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            ownsIdleTimerOverride = false
        }
        isRunning = false
        if status == "Running at 1 Hz" {
            status = "Stopped"
        }
        bleManager = nil
        fixture = nil
    }

    func ordinaryCaptureJSON() -> String? {
        RendererOrdinaryDiagnosticsCapture.json(
            fixtureID: fixtureID,
            fixtureSHA256: fixtureSHA256,
            snapshots: ordinarySnapshots
        )
    }

    @objc private func handleReplayTimer(_ timer: Timer) {
        emitCurrentSample()
    }

    private func emitCurrentSample() {
        guard isRunning,
              let bleManager,
              bleManager.isConnected,
              bleManager.isNavigationReady,
              bleManager.supportsRendererDiagnostics,
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
        // Match normal navigation: GPS and the fixture marker are emitted at
        // 1 Hz, while the route window is refreshed every two seconds.
        if emittedSampleCount % 2 == 0 {
            bleManager.sendRouteGeometry(routeData)
        }
        guard bleManager.sendRendererBenchmarkMarker(
            fixtureSHA256: fixtureSHA256,
            sampleIndex: sampleIndex,
            sampleCount: fixture.points.count,
            loop: loop
        ) else {
            errorMessage = "The benchmark marker could not be queued."
            status = "Stopped"
            stop()
            return
        }
        let now = Date()
        bleManager.sendGPSPosition(
            lat: point.latitude,
            lon: point.longitude,
            heading: heading,
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
            locationTimestamp: now
        )
        // HTTP owns the remote-debug sweep. Poll BLE only on ordinary
        // diagnostics firmware so the ranking run is not perturbed twice.
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
