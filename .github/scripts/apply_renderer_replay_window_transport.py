from pathlib import Path
import re

root = Path.cwd()

def read(path: str) -> str:
    return (root / path).read_text(encoding="utf-8")

def write(path: str, text: str) -> None:
    (root / path).write_text(text, encoding="utf-8")

def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one literal match, found {count}")
    write(path, text.replace(old, new, 1))

def regex_once(path: str, pattern: str, replacement: str, flags: int = 0) -> None:
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"{path}: expected one regex match, found {count}: {pattern[:80]}")
    write(path, updated)

ble = "ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift"
replay = "ios-app/BikeComputer/BikeComputer/Managers/RendererBenchmarkReplayCoordinator.swift"
controller = "ios-app/BikeComputer/BikeComputer/Managers/SecureRendererBenchmarkController.swift"
tests = "ios-app/BikeComputerTests/NavigationProtocolTests.swift"

replace_once(
    ble,
    '''enum RendererBenchmarkSampleWriteRoute: Equatable {
    case nativeWithoutResponse
    case unavailable
}

enum RendererBenchmarkSampleWriteRouting {
    static func route(
        hasNativeWriteWithoutResponse: Bool,
        payloadLength: Int,
        protectionOverhead: Int,
        withoutResponseMaximum: Int
    ) -> RendererBenchmarkSampleWriteRoute {
        if hasNativeWriteWithoutResponse,
           payloadLength + protectionOverhead <= withoutResponseMaximum {
            return .nativeWithoutResponse
        }
        return .unavailable
    }
}
''',
    '''enum RendererBenchmarkSampleWriteRoute: Equatable {
    case nativeWithResponse
    case unavailable
}

enum RendererBenchmarkSampleWriteRouting {
    static func route(
        hasNativeWriteWithResponse: Bool,
        payloadLength: Int,
        protectionOverhead: Int,
        withResponseMaximum: Int
    ) -> RendererBenchmarkSampleWriteRoute {
        if hasNativeWriteWithResponse,
           payloadLength + protectionOverhead <= withResponseMaximum {
            return .nativeWithResponse
        }
        return .unavailable
    }
}
'''
)

replace_once(
    ble,
    '''    static let rendererBenchmarkSampleCoalescingKey =
        "renderer.benchmark.sample"
''',
    '''    static let rendererBenchmarkSampleCoalescingKey =
        "renderer.benchmark.sample"
    static let rendererBenchmarkRouteCoalescingKey =
        "renderer.benchmark.route"
'''
)

replace_once(
    ble,
    '''    /// Clear route geometry on ESP32.
    func clearRouteGeometry() {
''',
    '''    /// Queues benchmark route state on the acknowledged native route
    /// characteristic. The matching RBS1 sample uses the same ordered queue,
    /// so a newer sample cannot overtake route geometry that was queued first.
    @discardableResult
    func sendRendererBenchmarkRouteGeometry(_ data: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let characteristic = routeGeometryCharacteristic,
              let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady,
              characteristic.properties.contains(.write) else {
            log("Cannot send renderer benchmark geometry: acknowledged native route transport unavailable")
            return false
        }

        let protectedLength = data.count + (authenticatedWriteSession == nil
            ? 0
            : AuthenticatedBLEWriteSession.frameOverhead)
        guard data.count <= endpoint.maximumWriteLength,
              protectedLength <= peripheral.maximumWriteValueLength(
                for: .withResponse
              ) else {
            log("Cannot send renderer benchmark geometry: acknowledged write limit exceeded")
            return false
        }

        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "native renderer benchmark route geometry",
            writeClass: .route,
            coalescingKey:
                DeviceBLEProtocol.rendererBenchmarkRouteCoalescingKey,
            transportWrite: {
                [weak self, weak peripheral, weak characteristic] payload in
                guard let self, let peripheral, let characteristic else {
                    return
                }
                self.writeDeviceData(
                    payload,
                    to: characteristic,
                    on: peripheral,
                    type: .withResponse
                )
            },
            transportCanSend: { [weak self] in
                self?.writeWithResponseInFlight == false
            },
            transportExpectsWriteResponse: true
        ) else {
            log("Renderer benchmark geometry not queued: write queue unavailable")
            return false
        }
        log("Queued native renderer benchmark route geometry: \\(data.count) bytes")
        return true
    }

    /// Clear route geometry on ESP32.
    func clearRouteGeometry() {
'''
)

replace_once(
    ble,
    '''    func endDeviceGPSOverride(_ token: UUID) {
        guard deviceGPSOverrideToken == token else { return }
        navigationLatestStateWriteQueue.removeAll()
        deviceGPSOverrideToken = nil
        onDeviceGPSOverrideEnded?()
    }
''',
    '''    func endDeviceGPSOverride(_ token: UUID) {
        guard deviceGPSOverrideToken == token else { return }
        navigationWriteQueue.removePendingWrites(
            withCoalescingKey:
                DeviceBLEProtocol.rendererBenchmarkRouteCoalescingKey
        )
        navigationWriteQueue.removePendingWrites(
            withCoalescingKey:
                DeviceBLEProtocol.rendererBenchmarkSampleCoalescingKey
        )
        navigationLatestStateWriteQueue.removeAll()
        deviceGPSOverrideToken = nil
        onDeviceGPSOverrideEnded?()
    }
'''
)

regex_once(
    ble,
    r'''    @discardableResult
    private func sendNativeRendererBenchmarkSample\(
        _ data: Data,
        label: String
    \) -> Bool \{.*?
    \}

    private var navigationPendingWriteCount: Int \{''',
    '''    @discardableResult
    private func sendNativeRendererBenchmarkSample(
        _ data: Data,
        label: String
    ) -> Bool {
        guard isConnected,
              isNavigationReady,
              let peripheral = connectedPeripheral,
              let characteristic = gpsPositionCharacteristic,
              let endpoint = navigationWriteEndpoint,
              RendererBenchmarkSampleWriteRouting.route(
                hasNativeWriteWithResponse:
                    characteristic.properties.contains(.write),
                payloadLength: data.count,
                protectionOverhead: authenticatedWriteSession == nil
                    ? 0
                    : AuthenticatedBLEWriteSession.frameOverhead,
                withResponseMaximum: peripheral.maximumWriteValueLength(
                    for: .withResponse
                )
              ) == .nativeWithResponse else {
            return false
        }
        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "native \\(label)",
            writeClass: .gpsPosition,
            coalescingKey:
                DeviceBLEProtocol.rendererBenchmarkSampleCoalescingKey,
            transportWrite: {
                [weak self, weak peripheral, weak characteristic] payload in
                guard let self, let peripheral, let characteristic else {
                    return
                }
                self.writeDeviceData(
                    payload,
                    to: characteristic,
                    on: peripheral,
                    type: .withResponse
                )
            },
            transportCanSend: { [weak self] in
                self?.writeWithResponseInFlight == false
            },
            transportExpectsWriteResponse: true
        ) else {
            return false
        }
        log("Queued native \\(label): \\(data.count) bytes")
        return true
    }

    private var navigationPendingWriteCount: Int {''',
    flags=re.S
)

regex_once(
    ble,
    r'''    private func flushPendingNavigationWrites\(endpoint: NavigationWriteEndpoint\) \{.*?
    \}

    private func logNavigationQueueMetricsInterval\(\) \{''',
    '''    private func flushPendingNavigationWrites(endpoint: NavigationWriteEndpoint) {
        var madeProgress = false
        navigationWriteQueue.flush(canSend: { [weak self] write in
            guard let self else { return false }
            let expectsWriteResponse = write.transportExpectsWriteResponse
                ?? endpoint.expectsWriteResponse
            if expectsWriteResponse && self.writeWithResponseInFlight {
                return false
            }
            return write.transportCanSend?() ?? endpoint.canSend()
        }, maxWrites: 1) { write in
            madeProgress = true
            let expectsWriteResponse = write.transportExpectsWriteResponse
                ?? endpoint.expectsWriteResponse
            if expectsWriteResponse {
                beginNavigationWriteResponseWait(for: write)
            }
            write.perform(using: endpoint.write)
            log("Sent \\(write.label): \\(write.data.count) bytes")
        }

        // The former renderer lane is retained only for compatibility with
        // already-queued host fixtures. It may run only after the ordered
        // transaction queue is empty, and therefore can never block or
        // overtake route, settings, transfer, or acknowledged GPS writes.
        if navigationWriteQueue.count == 0 && !writeWithResponseInFlight {
            navigationLatestStateWriteQueue.flush(maxWrites: 1) { write in
                madeProgress = true
                write.perform(using: endpoint.write)
                log("Sent \\(write.label): \\(write.data.count) bytes")
            }
        }

        updateNavigationBackpressureWatchdog(
            madeProgress: madeProgress,
            hasPendingWrites: navigationPendingWriteCount > 0
        )
        if navigationPendingWriteCount == 0 {
            navigationFlushRetryTimer?.invalidate()
            navigationFlushRetryTimer = nil
            lastNavigationQueuePendingLogAt = .distantPast
        } else if Date().timeIntervalSince(lastNavigationQueuePendingLogAt) >= 1 {
            log("Navigation write queue pending: \\(navigationPendingWriteCount)")
            lastNavigationQueuePendingLogAt = Date()
        }
        if madeProgress,
           hasReceivedDeviceCapabilities,
           supportsDeviceSettings,
           supportsAutomaticDisplayOff,
           !hasSentAutomaticDisplayOffForConnection {
            DispatchQueue.main.async { [weak self] in
                self?.sendAutomaticDisplayOffSettingAfterCapabilityNegotiation()
            }
        }
    }

    private func logNavigationQueueMetricsInterval() {''',
    flags=re.S
)

replace_once(
    ble,
    '''        // A renderer replay deliberately owns a bounded, replaceable one-slot
        // state lane. CoreBluetooth can withhold another no-response credit
        // while the ESP32 is rendering or serving the pinned HTTPS session.
        // Keep coalescing to the newest complete GPS-plus-marker sample and let
        // the benchmark's unchanged freshness/cadence gates measure the stall.
        // The replay has its own bounded warm-up/window lifetimes and clears
        // the lane on stop. Outside that explicit lease, the normal watchdog
        // still reconnects a persistently backpressured BLE session.
        if deviceGPSOverrideToken != nil,
           navigationLatestStateWriteQueue.count > 0 {
            navigationBackpressureStartedAt = nil
            return
        }

''',
    ''
)

replace_once(
    ble,
    '''    private func completeNavigationWrite(error: Error?) {
        let writeFailureHandler = navigationWriteWithResponseFailureHandler
        recordNavigationWriteAcknowledgement(error: error)
        resetNavigationWriteResponseWait()
        if error != nil {
            writeFailureHandler?()
        }
''',
    '''    private func completeNavigationWrite(error: Error?) {
        let writeFailureHandler = navigationWriteWithResponseFailureHandler
        let label = navigationWriteWithResponseLabel ?? "unknown write"
        let durationMs = navigationWriteAcknowledgementAgeMs()
        recordNavigationWriteAcknowledgement(error: error)
        if let error {
            log(
                "Acknowledged BLE write failed: \\(label); " +
                    "durationMs=\\(durationMs); " +
                    "error=\\(error.localizedDescription)"
            )
        } else {
            log(
                "Acknowledged BLE write completed: \\(label); " +
                    "durationMs=\\(durationMs)"
            )
        }
        resetNavigationWriteResponseWait()
        if error != nil {
            writeFailureHandler?()
        }
'''
)

replace_once(
    ble,
    '''    var navigationPendingWriteCountForTesting: Int {
        navigationPendingWriteCount
    }
''',
    '''    @discardableResult
    func enqueueRendererBenchmarkRouteWriteForTesting(
        _ data: Data,
        canSend: @escaping () -> Bool,
        write: @escaping (Data) -> Void
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint else { return false }
        return enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "test renderer route",
            writeClass: .route,
            coalescingKey:
                DeviceBLEProtocol.rendererBenchmarkRouteCoalescingKey,
            transportWrite: write,
            transportCanSend: canSend,
            transportExpectsWriteResponse: true
        )
    }

    @discardableResult
    func enqueueRendererBenchmarkSampleWriteForTesting(
        _ data: Data,
        canSend: @escaping () -> Bool,
        write: @escaping (Data) -> Void
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint else { return false }
        return enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "test renderer sample",
            writeClass: .gpsPosition,
            coalescingKey:
                DeviceBLEProtocol.rendererBenchmarkSampleCoalescingKey,
            transportWrite: write,
            transportCanSend: canSend,
            transportExpectsWriteResponse: true
        )
    }

    var navigationPendingWriteCountForTesting: Int {
        navigationPendingWriteCount
    }
'''
)

new_replay = r'''#if DEBUG
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
'''
write(replay, new_replay)

replace_once(
    controller,
    '''            status = "Starting pinned 1 Hz replay"
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
''',
    '''            status = "Arming pinned 1 Hz replay"
            replay.prepare(
                bleManager: bleManager,
                isNavigationActive: false,
                bundle: bundle
            )
            guard replay.isRunning, !replay.isCadenceActive else {
                throw SecureRendererBenchmarkControllerError.unavailable(
                    replay.errorMessage ??
                        "The pinned 1 Hz replay could not be armed."
                )
            }
            try checkContinuity()
'''
)

replace_once(
    controller,
    '''            status = "Restoring Current profile"
            cleanupRestoredCurrent = await restoreCurrentProfile(
''',
    '''            replay.pauseCadence()
            status = "Restoring Current profile"
            cleanupRestoredCurrent = await restoreCurrentProfile(
'''
)

replace_once(
    controller,
    '''        } catch {
            if profileMayNeedRestoration {
''',
    '''        } catch {
            replay.pauseCadence()
            if profileMayNeedRestoration {
'''
)

replace_once(
    controller,
    '''        let windowID = try await beginTrackedWindow(
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
''',
    '''        let activation = try await activateReplayWindow(
            client: client,
            profile: profile,
            repeatNumber: repeatNumber,
            runID: runID,
            mapFixture: mapFixture,
            routeFixture: routeFixture,
            expectedRouteSampleCount: expectedRouteSampleCount,
            gates: gates
        )
        let windowID = activation.windowID
        let initialSnapshot = activation.initialSnapshot
'''
)

regex_once(
    controller,
    r'''    private func warmUp\(
        client: SecureRendererBenchmarkHTTPClient,
        profile: RendererBenchmarkProfile,
        repeatNumber: Int,
        runID: String,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity,
        gates: RendererBenchmarkGates
    \) async throws \{.*?
    \}

    private func waitForWindow\(''',
    r'''    private func activateReplayWindow(
        client: SecureRendererBenchmarkHTTPClient,
        profile: RendererBenchmarkProfile,
        repeatNumber: Int,
        runID: String,
        mapFixture: RendererBenchmarkMapFixtureIdentity,
        routeFixture: RendererBenchmarkRouteFixtureIdentity,
        expectedRouteSampleCount: Int,
        gates: RendererBenchmarkGates
    ) async throws -> (
        windowID: UInt32,
        initialSnapshot: RendererBenchmarkMetricsSnapshot
    ) {
        guard let replay, let bleManager else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The authenticated renderer replay is unavailable."
            )
        }

        replay.pauseCadence()
        let freshnessSeconds =
            Double(gates.absolute.maximumRouteMarkerAgeMs) / 1_000
        guard freshnessSeconds == 2.5 else {
            throw SecureRendererBenchmarkControllerError.invalidResponse(
                "The checked-in route-marker freshness gate changed."
            )
        }
        guard await bleManager.waitForNavigationWritesToDrain(
            timeoutSeconds: freshnessSeconds
        ) else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The previous acknowledged replay transaction did not settle within the 2.5-second freshness gate."
            )
        }

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

        let acceptanceDeadline = Date().addingTimeInterval(freshnessSeconds)
        guard replay.emitInitialSample() else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                replay.errorMessage ??
                    "The first acknowledged renderer sample could not be queued."
            )
        }

        let acknowledgementBudget = acceptanceDeadline.timeIntervalSinceNow
        guard acknowledgementBudget > 0,
              await bleManager.waitForNavigationWritesToDrain(
                timeoutSeconds: acknowledgementBudget
              ) else {
            throw SecureRendererBenchmarkControllerError.unavailable(
                "The device did not acknowledge the first route and renderer sample within the 2.5-second freshness gate."
            )
        }

        var lastMetricsError: Error?
        while Date() < acceptanceDeadline {
            try checkContinuity()
            do {
                let remaining = max(
                    acceptanceDeadline.timeIntervalSinceNow,
                    0.05
                )
                let snapshot = try await metricsWithRetry(
                    client: client,
                    timeoutSeconds: min(0.6, remaining)
                )
                if snapshot.window.id == windowID,
                   snapshot.window.runId == runID,
                   snapshot.window.repeatNumber == repeatNumber,
                   snapshot.tuning.profile == profile.wireName,
                   snapshot.routeReplay.valid,
                   snapshot.routeReplay.fixtureMatches,
                   snapshot.routeReplay.sampleCount ==
                    expectedRouteSampleCount {
                    guard replay.startCadence() else {
                        throw SecureRendererBenchmarkControllerError.unavailable(
                            "The confirmed renderer replay cadence could not start."
                        )
                    }
                    return (windowID, snapshot)
                }
            } catch {
                lastMetricsError = error
            }
            if Date() < acceptanceDeadline {
                try await pause(seconds: min(
                    0.1,
                    max(acceptanceDeadline.timeIntervalSinceNow, 0)
                ))
            }
        }

        try checkContinuity()
        if let lastMetricsError,
           !(lastMetricsError is SecureRendererBenchmarkControllerError) {
            throw lastMetricsError
        }
        throw SecureRendererBenchmarkControllerError.unavailable(
            "The acknowledged renderer sample was not accepted for the active window within the 2.5-second freshness gate."
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
        _ = try await activateReplayWindow(
            client: client,
            profile: profile,
            repeatNumber: repeatNumber,
            runID: runID,
            mapFixture: mapFixture,
            routeFixture: routeFixture,
            expectedRouteSampleCount:
                replay?.sampleCount ?? 0,
            gates: gates
        )
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

    private func waitForWindow(''',
    flags=re.S
)

replace_once(
    tests,
    '''        testRendererLatestStateScheduling()
''',
    '''        await testRendererLatestStateScheduling()
'''
)

replace_once(
    tests,
    '''        testSecureRendererBenchmarkProtocol()
        testDeviceBLEProtocolConstants()
''',
    '''        testSecureRendererBenchmarkProtocol()
        testSecureRendererReplayWindowOrdering()
        testDeviceBLEProtocolConstants()
'''
)

replace_once(
    tests,
    '''    override func sendRouteGeometry(_ data: Data) -> Bool {
        guard isConnected, isNavigationReady else {
            return false
        }

        sentRouteGeometry.append(data)
        return true
    }
''',
    '''    override func sendRouteGeometry(_ data: Data) -> Bool {
        guard isConnected, isNavigationReady else {
            return false
        }

        sentRouteGeometry.append(data)
        return true
    }

    override func sendRendererBenchmarkRouteGeometry(_ data: Data) -> Bool {
        sendRouteGeometry(data)
    }
'''
)

regex_once(
    tests,
    r'''    static func testRendererLatestStateScheduling\(\) \{.*?
    \}

    @MainActor
    static func testNavigationDrainIncludesAcknowledgement\(\) \{''',
    r'''    @MainActor
    static func testRendererLatestStateScheduling() async {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        var transportReady = false
        var writes: [UInt8] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 512,
            expectsWriteResponse: true,
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ))

        guard let replayToken = manager.beginDeviceGPSOverride() else {
            assert(false, "renderer transaction fixture acquires the GPS lease")
            return
        }
        assert(manager.enqueueRendererBenchmarkRouteWriteForTesting(
            Data([0x40]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "an earlier route enters the acknowledged ordered queue")
        assert(manager.enqueueRendererBenchmarkSampleWriteForTesting(
            Data([0x41]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "the corresponding sample follows its route")

        for value in UInt8(0x42)...UInt8(0x50) {
            if value.isMultiple(of: 2) {
                assert(manager.enqueueRendererBenchmarkRouteWriteForTesting(
                    Data([value &+ 0x20]),
                    canSend: { transportReady },
                    write: { data in
                        writes.append(data[0])
                        transportReady = false
                    }
                ), "new route state coalesces while transport is blocked")
            }
            assert(manager.enqueueRendererBenchmarkSampleWriteForTesting(
                Data([value]),
                canSend: { transportReady },
                write: { data in
                    writes.append(data[0])
                    transportReady = false
                }
            ), "new sample state coalesces while transport is blocked")
        }

        assertEqual(
            manager.navigationPendingWriteCountForTesting,
            2,
            "prolonged backpressure retains one newest route and one newest sample"
        )
        assert(writes.isEmpty, "blocked transport submits no replay state")

        transportReady = true
        manager.flushPendingNavigationWritesForTesting()
        assertEqual(
            writes,
            [0x70],
            "the newest route advances before its corresponding newest sample"
        )
        assertEqual(
            manager.navigationPendingWriteCountForTesting,
            1,
            "the sample remains pending until the route acknowledgement"
        )

        transportReady = true
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(
            writes,
            [0x70, 0x50],
            "the newest sample cannot overtake its acknowledged route"
        )

        transportReady = true
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(
            manager.navigationPendingWriteCountForTesting,
            0,
            "both halves settle after their acknowledgements"
        )

        transportReady = true
        assert(manager.enqueueRendererBenchmarkRouteWriteForTesting(
            Data([0x71]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "bounded-ack fixture submits a route")
        let drained = await manager.waitForNavigationWritesToDrain(
            timeoutSeconds: 0.02
        )
        assert(!drained, "a missing acknowledged completion fails in bounded time")
        manager.completeNavigationWriteForTesting(
            error: NSError(domain: "RendererReplayTests", code: 1)
        )

        transportReady = false
        assert(manager.enqueueRendererBenchmarkRouteWriteForTesting(
            Data([0x72]),
            canSend: { transportReady },
            write: { _ in }
        ), "cleanup fixture stages a route")
        assert(manager.enqueueRendererBenchmarkSampleWriteForTesting(
            Data([0x52]),
            canSend: { transportReady },
            write: { _ in }
        ), "cleanup fixture stages a sample")
        manager.endDeviceGPSOverride(replayToken)
        assertEqual(
            manager.navigationPendingWriteCountForTesting,
            0,
            "ending the replay lease clears every unsent benchmark transaction"
        )
    }

    @MainActor
    static func testNavigationDrainIncludesAcknowledgement() {''',
    flags=re.S
)

regex_once(
    tests,
    r'''        assertEqual\(RendererBenchmarkSampleWriteRouting\.route\(
            hasNativeWriteWithoutResponse: true,
            payloadLength: RendererBenchmarkSamplePacket\.maximumByteCount,
            protectionOverhead: AuthenticatedBLEWriteSession\.frameOverhead,
            withoutResponseMaximum: 107
        \), \.nativeWithoutResponse,
                    "the protected atomic renderer sample fits one latest-state write"\)
        assertEqual\(RendererBenchmarkSampleWriteRouting\.route\(
            hasNativeWriteWithoutResponse: true,
            payloadLength: RendererBenchmarkSamplePacket\.maximumByteCount,
            protectionOverhead: AuthenticatedBLEWriteSession\.frameOverhead,
            withoutResponseMaximum: 106
        \), \.unavailable,
                    "an atomic sample that cannot fit fails closed"\)
''',
    '''        assertEqual(RendererBenchmarkSampleWriteRouting.route(
            hasNativeWriteWithResponse: true,
            payloadLength: RendererBenchmarkSamplePacket.maximumByteCount,
            protectionOverhead: AuthenticatedBLEWriteSession.frameOverhead,
            withResponseMaximum: 107
        ), .nativeWithResponse,
                    "the protected atomic renderer sample requires acknowledged native delivery")
        assertEqual(RendererBenchmarkSampleWriteRouting.route(
            hasNativeWriteWithResponse: true,
            payloadLength: RendererBenchmarkSamplePacket.maximumByteCount,
            protectionOverhead: AuthenticatedBLEWriteSession.frameOverhead,
            withResponseMaximum: 106
        ), .unavailable,
                    "an acknowledged sample that cannot fit fails closed")
        assertEqual(RendererBenchmarkSampleWriteRouting.route(
            hasNativeWriteWithResponse: false,
            payloadLength: RendererBenchmarkSamplePacket.maximumByteCount,
            protectionOverhead: AuthenticatedBLEWriteSession.frameOverhead,
            withResponseMaximum: 512
        ), .unavailable,
                    "write-without-response is never a secure-sweep fallback")
''',
    flags=re.S
)

insert_marker = '''    static func testSecureRendererBenchmarkReadiness() {
'''
ordering_test = r'''    static func testSecureRendererReplayWindowOrdering() {
        let replayURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/RendererBenchmarkReplayCoordinator.swift"
        )
        let controllerURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/SecureRendererBenchmarkController.swift"
        )
        guard let replaySource = try? String(
            contentsOf: replayURL,
            encoding: .utf8
        ), let controllerSource = try? String(
            contentsOf: controllerURL,
            encoding: .utf8
        ) else {
            assert(false, "renderer replay sources are readable")
            return
        }

        assert(
            replaySource.contains("func prepare(") &&
                replaySource.contains("func emitInitialSample()") &&
                replaySource.contains("func startCadence()"),
            "replay exposes an armed state separate from emission and cadence"
        )
        guard let activationStart = controllerSource.range(
            of: "private func activateReplayWindow("
        )?.lowerBound,
        let warmUpStart = controllerSource.range(
            of: "private func warmUp(",
            range: activationStart..<controllerSource.endIndex
        )?.lowerBound else {
            assert(false, "secure controller contains the activation helper")
            return
        }
        let activation = String(
            controllerSource[activationStart..<warmUpStart]
        )
        guard let beginWindow = activation.range(
            of: "beginTrackedWindow("
        )?.lowerBound,
        let confirmedWindow = activation.range(
            of: "waitForWindow(",
            range: beginWindow..<activation.endIndex
        )?.lowerBound,
        let firstSample = activation.range(
            of: "emitInitialSample()",
            range: confirmedWindow..<activation.endIndex
        )?.lowerBound,
        let firstDrain = activation.range(
            of: "waitForNavigationWritesToDrain(",
            range: firstSample..<activation.endIndex
        )?.lowerBound,
        let acceptedMarker = activation.range(
            of: "snapshot.routeReplay.valid",
            range: firstDrain..<activation.endIndex
        )?.lowerBound,
        let cadence = activation.range(
            of: "startCadence()",
            range: acceptedMarker..<activation.endIndex
        )?.lowerBound else {
            assert(false, "activation contains every ordered replay stage")
            return
        }
        assert(
            beginWindow < confirmedWindow &&
                confirmedWindow < firstSample &&
                firstSample < firstDrain &&
                firstDrain < acceptedMarker &&
                acceptedMarker < cadence,
            "window confirmation, acknowledged submission, firmware acceptance, and cadence are ordered"
        )
        assert(
            activation.contains(
                "Double(gates.absolute.maximumRouteMarkerAgeMs) / 1_000"
            ) &&
                activation.contains("freshnessSeconds == 2.5"),
            "initial transport and acceptance retain the exact 2.5-second gate"
        )
        guard let sweepArm = controllerSource.range(
            of: "replay.prepare("
        )?.lowerBound,
        let comparisonStart = controllerSource.range(
            of: "let rootRunID",
            range: sweepArm..<controllerSource.endIndex
        )?.lowerBound else {
            assert(false, "secure sweep arms replay before its run plan")
            return
        }
        let startup = String(controllerSource[sweepArm..<comparisonStart])
        assert(
            !startup.contains("emitInitialSample()") &&
                !startup.contains("startCadence()"),
            "secure sweep startup cannot emit before its first confirmed window"
        )
    }

'''
replace_once(tests, insert_marker, ordering_test + insert_marker)

ble_text = read(ble)
secure_sample = ble_text[
    ble_text.index("private func sendNativeRendererBenchmarkSample"):
    ble_text.index("private var navigationPendingWriteCount")
]
if "hasNativeWriteWithoutResponse:" in secure_sample:
    raise SystemExit("secure renderer sample still references WNR routing")
if ".withoutResponse" in secure_sample:
    raise SystemExit("secure renderer sample still writes without response")

for path in (ble, replay, controller, tests):
    text = read(path)
    if "\r\n" in text:
        raise SystemExit(f"{path}: unexpected CRLF")
