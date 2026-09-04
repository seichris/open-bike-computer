from pathlib import Path

root = Path.cwd()
ble_path = root / "ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift"
test_path = root / "ios-app/BikeComputerTests/NavigationProtocolTests.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


ble = ble_path.read_text(encoding="utf-8")
start_marker = (
    "    private func flushPendingNavigationWrites("
    "endpoint: NavigationWriteEndpoint) {\n"
)
end_marker = "    private func logNavigationQueueMetricsInterval() {\n"
if ble.count(start_marker) != 1 or ble.count(end_marker) != 1:
    raise SystemExit("unexpected navigation flush function boundaries")
start = ble.index(start_marker)
end = ble.index(end_marker, start)
flush = '''    private func flushPendingNavigationWrites(endpoint: NavigationWriteEndpoint) {
        var madeProgress = false
        navigationLatestStateWriteQueue.flush(maxWrites: 1) { write in
            madeProgress = true
            write.perform(using: endpoint.write)
            log("Sent \\(write.label): \\(write.data.count) bytes")
        }
        // Preserve the established independent no-response bypass for
        // non-renderer traffic. Renderer replay no longer enters this lane:
        // its route and RBS1 writes share the acknowledged ordered queue.
        if navigationLatestStateWriteQueue.count == 0 {
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

'''
ble = ble[:start] + flush + ble[end:]

method_marker = '''    /// Queues benchmark route state on the acknowledged native route
    /// characteristic. The matching RBS1 sample uses the same ordered queue,
    /// so a newer sample cannot overtake route geometry that was queued first.
    @discardableResult
    func sendRendererBenchmarkRouteGeometry(_ data: Data) -> Bool {
'''
method_replacement = '''    private func discardPendingRendererBenchmarkSample() {
        navigationWriteQueue.removePendingWrites(
            withCoalescingKey:
                DeviceBLEProtocol.rendererBenchmarkSampleCoalescingKey
        )
    }

    /// Queues benchmark route state on the acknowledged native route
    /// characteristic. The matching RBS1 sample uses the same ordered queue,
    /// so a newer sample cannot overtake route geometry that was queued first.
    @discardableResult
    func sendRendererBenchmarkRouteGeometry(_ data: Data) -> Bool {
'''
ble = replace_once(
    ble,
    method_marker,
    method_replacement,
    "renderer route helper insertion",
)

route_guard = '''        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "native renderer benchmark route geometry",
'''
route_guard_replacement = '''        // If a previous sample has not reached CoreBluetooth yet, its route
        // context is also replaceable. Remove that pending sample before the
        // newer route is admitted; emitCurrentSample() immediately stages the
        // matching newest sample behind this route.
        discardPendingRendererBenchmarkSample()
        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "native renderer benchmark route geometry",
'''
ble = replace_once(
    ble,
    route_guard,
    route_guard_replacement,
    "renderer route pending-sample purge",
)

helper_guard = '''    func enqueueRendererBenchmarkRouteWriteForTesting(
        _ data: Data,
        canSend: @escaping () -> Bool,
        write: @escaping (Data) -> Void
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint else { return false }
        return enqueueNavigationWrite(
'''
helper_guard_replacement = '''    func enqueueRendererBenchmarkRouteWriteForTesting(
        _ data: Data,
        canSend: @escaping () -> Bool,
        write: @escaping (Data) -> Void
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint else { return false }
        discardPendingRendererBenchmarkSample()
        return enqueueNavigationWrite(
'''
ble = replace_once(
    ble,
    helper_guard,
    helper_guard_replacement,
    "renderer route test helper",
)
ble_path.write_text(ble, encoding="utf-8")


tests = test_path.read_text(encoding="utf-8")
main_call = '''        await testRendererLatestStateScheduling()
        testNavigationWriteAcknowledgementTimeoutPolicy()
'''
main_call_replacement = '''        await testRendererLatestStateScheduling()
        testRendererPendingSampleCannotOvertakeNewRoute()
        testNavigationWriteAcknowledgementTimeoutPolicy()
'''
tests = replace_once(
    tests,
    main_call,
    main_call_replacement,
    "renderer pending-route test registration",
)

insert_before = '''    @MainActor
    static func testNavigationDrainIncludesAcknowledgement() {
'''
new_test = '''    @MainActor
    static func testRendererPendingSampleCannotOvertakeNewRoute() {
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
            assert(false, "sample-before-route fixture acquires the GPS lease")
            return
        }

        assert(manager.enqueueRendererBenchmarkSampleWriteForTesting(
            Data([0x41]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "an old sample is initially pending")
        assert(manager.enqueueRendererBenchmarkRouteWriteForTesting(
            Data([0x60]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "a newer route supersedes the old pending sample")
        assert(manager.enqueueRendererBenchmarkSampleWriteForTesting(
            Data([0x42]),
            canSend: { transportReady },
            write: { data in
                writes.append(data[0])
                transportReady = false
            }
        ), "the sample paired with the newer route is retained")
        assertEqual(
            manager.navigationPendingWriteCountForTesting,
            2,
            "only the newer route and its matching sample remain"
        )

        transportReady = true
        manager.flushPendingNavigationWritesForTesting()
        assertEqual(writes, [0x60],
                    "the newer route reaches CoreBluetooth first")
        transportReady = true
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(writes, [0x60, 0x42],
                    "the obsolete sample never overtakes the newer route")
        transportReady = true
        manager.completeNavigationWriteForTesting(error: nil)
        manager.endDeviceGPSOverride(replayToken)
    }

'''
tests = replace_once(
    tests,
    insert_before,
    new_test + insert_before,
    "renderer pending-route test insertion",
)
test_path.write_text(tests, encoding="utf-8")
