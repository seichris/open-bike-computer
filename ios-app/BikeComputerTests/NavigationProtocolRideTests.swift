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


extension NavigationProtocolTests {
    @MainActor
    static func testWorkoutDeviceRelayPublicationIntegration() {
        let clock = TestClock(Date(timeIntervalSince1970: 20_000))
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let store = WorkoutMetricsStore(now: clock.now)
        store.attachMirroredSession(at: clock.now())
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 91,
                sequence: 1,
                capturedAt: clock.now(),
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: clock.now()
                )
            ),
        ], receivedAt: clock.now())

        let manager = BLEManager()
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 32,
            canSend: { true },
            write: { writes.append($0) }
        ))
        func workoutWrites() -> [Data] {
            writes.filter {
                String(data: $0.prefix(4), encoding: .utf8) ==
                    DeviceBLEProtocol.workoutTelemetryFallbackPrefix
            }
        }
        let relay = WorkoutDeviceRelay(
            store: store,
            bleManager: manager,
            now: clock.now
        )

        manager.isConnected = true
        manager.isNavigationReady = true
        let capability = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.workoutTelemetryCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "publisher integration accepts workout capability")
        assert(waitForMainLoop(timeout: 1) { workoutWrites().count == 2 },
               "legacy workout capability resynchronizes only supported frames")
        assertEqual(workoutWrites().map { $0[4] }, [1, 2],
                    "old firmware never receives the new provenance frame")
        assertEqual(workoutWrites()[0][5] & 0x3F, WorkoutDeviceSessionState.running.rawValue,
                    "readiness publication relays the committed running state")

        writes.removeAll()
        let rideAutomationFlags = UInt32(
            DeviceBLEProtocol.workoutTelemetryCapabilityMask
        ) | DeviceBLEProtocol.rideAutomationCapabilityMask
        let rideAutomationCapability =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([
                1,
                UInt8(rideAutomationFlags & 0xFF),
                UInt8((rideAutomationFlags >> 8) & 0xFF),
                UInt8((rideAutomationFlags >> 16) & 0xFF),
                UInt8((rideAutomationFlags >> 24) & 0xFF),
            ])
        assert(manager.handleDeviceCapabilitiesNotification(
            rideAutomationCapability
        ), "CAP2 ride-automation capability is accepted")
        assert(waitForMainLoop(timeout: 1) { workoutWrites().count == 1 },
               "new capability publishes the deferred provenance frame")
        assertEqual(workoutWrites().map { $0[4] }, [3],
                    "origin telemetry is gated on ride automation support")

        writes.removeAll()
        clock.advance(by: 0.1)
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 91,
                sequence: 2,
                capturedAt: clock.now(),
                snapshot: WorkoutSnapshotV1(
                    state: .paused,
                    startDate: Date(timeIntervalSince1970: 20_000)
                )
            ),
        ], receivedAt: clock.now())
        assert(waitForMainLoop(timeout: 1) { workoutWrites().count == 2 },
               "one presentation publication sends the latest state transition")
        assertEqual(workoutWrites()[0][5] & 0x3F, WorkoutDeviceSessionState.paused.rawValue,
                    "relay reads the committed paused presentation, not the prior revision")

        assert(manager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8)
        ), "malformed capability response disables telemetry for reconnect coverage")
        assert(!manager.supportsWorkoutTelemetry,
               "capability is disabled synchronously before immediate reenable")
        writes.removeAll()
        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "back-to-back valid capability response reenables telemetry")
        assert(waitForMainLoop(timeout: 1) { workoutWrites().count == 2 },
               "legacy reenable resynchronizes only supported latest frames")
        assertEqual(workoutWrites()[0][5] & 0x3F, WorkoutDeviceSessionState.paused.rawValue,
                    "reconnect resynchronization uses the latest committed state")
        withExtendedLifetime(relay) {}
    }

    @MainActor
    static func testWorkoutDeviceRelayMotionDeduplicationIntegration() {
        let clock = TestClock(Date(timeIntervalSince1970: 25_000))
        let sessionID = UUID(
            uuidString: "ABABABAB-CDCD-EFEF-0101-232323232323"
        )!
        let store = WorkoutMetricsStore(now: clock.now)
        store.attachMirroredSession(at: clock.now())
        let firstLocationCapturedAt = clock.now()
        func snapshot(
            locationSequence: UInt32,
            locationCapturedAt: Date
        ) -> WorkoutSnapshotV1 {
            WorkoutSnapshotV1(
                state: .running,
                startDate: Date(timeIntervalSince1970: 24_990),
                location: WorkoutLocationV1(
                    latitude: 31.2304,
                    longitude: 121.4737,
                    capturedAt: locationCapturedAt,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: 0.1,
                    motionSampleEpoch: 7,
                    motionSampleSequence: locationSequence
                ),
                availability: [.location]
            )
        }
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 93,
                sequence: 1,
                capturedAt: clock.now(),
                snapshot: snapshot(
                    locationSequence: 1,
                    locationCapturedAt: firstLocationCapturedAt
                )
            ),
        ], receivedAt: clock.now())

        let manager = BLEManager()
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 32,
            canSend: { true },
            write: { writes.append($0) }
        ))
        func workoutKinds() -> [UInt8] {
            writes.compactMap { write in
                guard String(data: write.prefix(4), encoding: .utf8) ==
                    DeviceBLEProtocol.workoutTelemetryFallbackPrefix,
                    write.count > 4 else { return nil }
                return write[4]
            }
        }
        let relay = WorkoutDeviceRelay(
            store: store,
            bleManager: manager,
            now: clock.now
        )
        manager.isConnected = true
        manager.isNavigationReady = true
        let flags = UInt32(
            DeviceBLEProtocol.workoutTelemetryCapabilityMask
        ) | DeviceBLEProtocol.watchGPSMotionEvidenceV1CapabilityMask
        let capability =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([
                1,
                UInt8(flags & 0xFF),
                UInt8((flags >> 8) & 0xFF),
                UInt8((flags >> 16) & 0xFF),
                UInt8((flags >> 24) & 0xFF),
            ])
        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "Watch-motion capability is accepted")
        assert(waitForMainLoop(timeout: 1) {
            workoutKinds().filter { $0 == 4 }.count == 1
        }, "the initial Watch motion sample is relayed")

        writes.removeAll()
        clock.advance(by: 0.25)
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 93,
                sequence: 2,
                capturedAt: clock.now(),
                snapshot: snapshot(
                    locationSequence: 1,
                    locationCapturedAt: firstLocationCapturedAt
                )
            ),
        ], receivedAt: clock.now())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(
            !workoutKinds().contains(4),
            "changing send age cannot resend one producer sample"
        )

        clock.advance(by: 0.25)
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 93,
                sequence: 3,
                capturedAt: clock.now(),
                snapshot: snapshot(
                    locationSequence: 2,
                    locationCapturedAt: clock.now()
                )
            ),
        ], receivedAt: clock.now())
        assert(waitForMainLoop(timeout: 1) {
            workoutKinds().filter { $0 == 4 }.count == 1
        }, "a distinct Watch producer sample is relayed")
        withExtendedLifetime(relay) {}
    }

    @MainActor
    static func testWorkoutDeviceRelayRegularRetryIntegration() {
        let clock = TestClock(Date(timeIntervalSince1970: 30_000))
        let sessionID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let store = WorkoutMetricsStore(now: clock.now)
        store.attachMirroredSession(at: clock.now())
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 92,
                sequence: 1,
                capturedAt: clock.now(),
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: clock.now()
                )
            ),
        ], receivedAt: clock.now())

        let initialSample = WorkoutDeviceTelemetryMapper.sample(
            presentation: store.presentation,
            envelope: store.currentEnvelope
        )!
        let initialFrames = WorkoutDeviceFrameBuilder.frames(for: initialSample)!
        var primedScheduler = WorkoutDeviceRelayScheduler()
        let initialSchedule = primedScheduler.update(
            frames: initialFrames,
            transportReady: true,
            at: clock.now()
        )
        for transmission in initialSchedule.transmissions {
            primedScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: clock.now()
            )
        }

        let manager = BLEManager()
        manager.installNavigationWriteQueueForTesting(maxCount: 3)
        var transportReady = false
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            expectsWriteResponse: true,
            canSend: { transportReady },
            write: { writes.append($0) }
        ))
        manager.isConnected = true
        manager.isNavigationReady = true
        let capability = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.workoutTelemetryCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "regular retry manager receives workout capability")

        let relay = WorkoutDeviceRelay(
            store: store,
            bleManager: manager,
            now: clock.now,
            scheduler: primedScheduler
        )
        assert(manager.requestDeviceCapabilities(),
               "first ordinary write fills the regular queue")
        assert(manager.requestDeviceCapabilities(),
               "second ordinary write fills the regular queue")
        assert(manager.requestDeviceCapabilities(),
               "third ordinary write fills the regular queue")

        clock.advance(by: 1)
        let heartRate = WorkoutMetricV1(
            value: 130,
            unit: .beatsPerMinute,
            capturedAt: clock.now(),
            source: .healthKit
        )
        _ = store.ingestBatch([
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 92,
                sequence: 2,
                capturedAt: clock.now(),
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: Date(timeIntervalSince1970: 30_000),
                    currentHeartRate: heartRate,
                    availability: [.currentHeartRate]
                )
            ),
        ], receivedAt: clock.now())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(writes.isEmpty,
               "a regular pair exposes neither half when only a full queue is available")

        transportReady = true
        manager.completeNavigationWriteForTesting(error: nil)
        manager.completeNavigationWriteForTesting(error: nil)
        manager.completeNavigationWriteForTesting(error: nil)
        manager.completeNavigationWriteForTesting(error: nil)
        assertEqual(writes.map { String(data: $0.prefix(4), encoding: .utf8) },
                    ["CAPS", "CAPS", "CAPS"],
                    "failed atomic admission preserves existing regular traffic")

        assert(waitForMainLoop(timeout: 1) {
            writes.filter {
                String(data: $0.prefix(4), encoding: .utf8) ==
                    DeviceBLEProtocol.workoutTelemetryFallbackPrefix
            }.count == 1
        }, "relay retries the non-prioritized bundle after capacity becomes available")
        manager.completeNavigationWriteForTesting(error: nil)
        manager.completeNavigationWriteForTesting(error: nil)
        let workoutWrites = writes.filter {
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.workoutTelemetryFallbackPrefix
        }
        assertEqual(workoutWrites.map { $0[4] }, [1, 2],
                    "regular-lane retry delivers one adjacent correlated bundle")
        manager.completeNavigationWriteForTesting(error: nil)
        withExtendedLifetime(relay) {}
    }

    static func testQueuedMotionUsesDispatchAge() {
        for native in [false, true] {
            let manager = BLEManager()
            var uptime: TimeInterval = 10
            manager.workoutMotionUptime = { uptime }
            var ready = false
            var writes: [Data] = []
            let flags = UInt32(DeviceBLEProtocol.workoutTelemetryCapabilityMask)
                | DeviceBLEProtocol.watchGPSMotionEvidenceV1CapabilityMask
            var capability = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8)
            capability.append(1)
            appendUInt32LE(flags, to: &capability)
            assert(manager.handleDeviceCapabilitiesNotification(capability), "motion capability accepted")
            manager.isConnected = true
            manager.isNavigationReady = true
            manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
                maximumWriteLength: 32, canSend: { ready }, write: { writes.append($0) }))
            if native {
                manager.installWorkoutTelemetryWriteEndpoint(WorkoutTelemetryWriteEndpoint(
                    maximumWriteLength: 32, canSend: { ready }, write: { writes.append($0) }))
            }
            var frame = Data(repeating: 0, count: 16)
            frame[0] = 4
            frame[12] = 100
            assert(manager.sendWorkoutTelemetryFrame(frame), "motion admitted behind backpressure")
            assertEqual(writes.count, 0, "blocked writer submits nothing")
            uptime = 12
            ready = true
            manager.flushPendingNavigationWritesForTesting()
            assertEqual(writes.count, 1, "fresh delayed frame dispatches")
            let offset = native ? 0 : 4
            assertEqual(readUInt16LE(writes[0], offset: offset + 12), 2100,
                        "native and fallback encode dispatch age, not enqueue age")
            ready = false
            assert(manager.sendWorkoutTelemetryFrame(frame), "next motion admitted")
            uptime = 16
            ready = true
            manager.flushPendingNavigationWritesForTesting()
            assertEqual(writes.count, 1, "expired motion never reaches the endpoint")
        }
    }

    static func testWorkoutTelemetryBLETransport() {
        let channelManager = BLEManager()
        let nativeWorkoutPayload = Data(ownershipHex:
            "0102030405060708090a0b0c0d0e0f10")!
        let workoutWriteSession = AuthenticatedBLEWriteSession(
            ownerKey: Data((0..<32).map(UInt8.init)),
            deviceID: "00112233445566778899aabbccddeeff",
            clientNonce: "102132435465768798a9babbdcddedef",
            serverNonce: "ffeeddccbbaa99887766554433221100"
        )
        assertEqual(
            channelManager.devicePayloadForTesting(
                nativeWorkoutPayload,
                for: DeviceBLEProtocol.workoutTelemetryCharacteristicUUID,
                authenticatedWriteSession: workoutWriteSession
            ),
            Data(ownershipHex:
                "53320000000127d330a9033a32ec8bf92a85e20f859fa7efe9559f559083f8f9e48720130a16"),
            "production native workout payload path emits the exact protected channel-six frame"
        )
        let capability = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.workoutTelemetryCapabilityMask])
        let frame = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        )!.core
        let extendedFrame = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        )!.extended

        assertEqual(WorkoutTelemetryWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            navigationExpectsWriteResponse: true
        ), .nativeWithResponse,
                    "an acknowledged native workout characteristic is preferred")
        assertEqual(WorkoutTelemetryWriteRouting.route(
            hasNativeWriteWithResponse: false,
            hasNativeWriteWithoutResponse: true,
            navigationExpectsWriteResponse: true
        ), .navigationFallback,
                    "an acknowledged fallback avoids priority-lane no-response head-of-line blocking")
        assertEqual(WorkoutTelemetryWriteRouting.route(
            hasNativeWriteWithResponse: false,
            hasNativeWriteWithoutResponse: true,
            navigationExpectsWriteResponse: false
        ), .nativeWithoutResponse,
                    "native no-response remains available when the command transport is also unacknowledged")
        assertEqual(WorkoutTelemetryWriteRouting.route(
            hasNativeWriteWithResponse: false,
            hasNativeWriteWithoutResponse: false,
            navigationExpectsWriteResponse: false
        ), .navigationFallback,
                    "firmware without a dedicated workout transport uses navigation fallback")

        let unauthenticated = BLEManager()
        assert(unauthenticated.handleDeviceCapabilitiesNotification(capability),
               "workout capability response is consumed")
        unauthenticated.isConnected = true
        unauthenticated.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { _ in }
        ))
        assert(!unauthenticated.sendWorkoutTelemetryFrame(frame),
               "workout telemetry is rejected before authentication readiness")

        let oldFirmware = BLEManager()
        assert(oldFirmware.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) + Data([0])
        ), "legacy capability response is consumed")
        oldFirmware.isConnected = true
        oldFirmware.isNavigationReady = true
        oldFirmware.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { _ in }
        ))
        assert(!oldFirmware.sendWorkoutTelemetryFrame(frame),
               "new app sends no workout frames to old firmware")

        let fallbackManager = BLEManager()
        assert(fallbackManager.handleDeviceCapabilitiesNotification(capability),
               "workout capability enables telemetry")
        assert(fallbackManager.supportsWorkoutTelemetry,
               "CAPS bit 7 is published")
        fallbackManager.isConnected = true
        fallbackManager.isNavigationReady = true
        var fallbackWrites: [Data] = []
        fallbackManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { fallbackWrites.append($0) }
        ))
        assert(fallbackManager.sendWorkoutTelemetryFrame(frame),
               "capable authenticated connection accepts workout telemetry")
        assertEqual(fallbackWrites.count, 1,
                    "fallback emits one workout packet")
        assertEqual(fallbackWrites[0].count, 20,
                    "WTLM plus core frame fits the minimum ATT payload")
        assertEqual(String(data: fallbackWrites[0].prefix(4), encoding: .utf8),
                    "WTLM", "cached-GATT fallback uses WTLM")
        assertEqual(Data(fallbackWrites[0].dropFirst(4)), frame,
                    "WTLM fallback preserves the exact frame bytes")

        var malformedKind = Data(repeating: 0, count: 16)
        malformedKind[0] = 4
        assert(!fallbackManager.sendWorkoutTelemetryFrame(Data(repeating: 1, count: 15)),
               "short workout frame is rejected")
        assert(!fallbackManager.sendWorkoutTelemetryFrame(malformedKind),
               "unknown workout frame kind is rejected")

        let nativeManager = BLEManager()
        assert(nativeManager.handleDeviceCapabilitiesNotification(capability),
               "native manager receives workout capability")
        nativeManager.isConnected = true
        nativeManager.isNavigationReady = true
        var nativeWrites: [Data] = []
        var laterNavigationWrites: [Data] = []
        nativeManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            expectsWriteResponse: false,
            canSend: { true },
            write: { laterNavigationWrites.append($0) }
        ))
        nativeManager.installWorkoutTelemetryWriteEndpoint(
            WorkoutTelemetryWriteEndpoint(
                maximumWriteLength: 20,
                write: { nativeWrites.append($0) }
            )
        )
        assert(nativeManager.sendWorkoutTelemetryFrame(frame),
               "native workout characteristic accepts the frame")
        assert(nativeManager.sendWorkoutTelemetryFrame(extendedFrame),
               "native extended workout frame drains after the core frame")
        assertEqual(nativeWrites, [frame, extendedFrame],
                    "native without-response writes ignore fallback response semantics")
        assert(nativeManager.requestDeviceCapabilities(),
               "navigation traffic still drains after native workout writes")
        assertEqual(laterNavigationWrites,
                    [Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
                        Data([DeviceBLEProtocol.deviceCapabilitiesVersion])],
                    "native workout traffic cannot wedge later response-backed navigation writes")

        let atomicPairManager = BLEManager()
        assert(atomicPairManager.handleDeviceCapabilitiesNotification(capability),
               "atomic pair manager receives workout capability")
        atomicPairManager.isConnected = true
        atomicPairManager.isNavigationReady = true
        var atomicTransportReady = false
        var atomicPairWrites: [Data] = []
        atomicPairManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 20,
                expectsWriteResponse: true,
                canSend: { atomicTransportReady },
                write: { atomicPairWrites.append($0) }
            )
        )
        assert(atomicPairManager.requestDeviceCapabilities(),
               "ordinary reconnect traffic is queued before workout telemetry")
        assert(atomicPairManager.sendWorkoutTelemetryPair(
            core: frame,
            extended: extendedFrame,
            prioritized: true,
            onWrite: { _ in },
            onDrop: { _ in },
            onWriteFailure: { _ in }
        ), "a complete workout pair is admitted atomically under backpressure")
        assert(atomicPairWrites.isEmpty,
               "blocked transport exposes neither half of the pair")
        atomicTransportReady = true
        atomicPairManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(atomicPairWrites.count, 1,
                    "acknowledged transport sends only the core before its response")
        assertEqual(Data(atomicPairWrites[0].dropFirst(4)), frame,
                    "the prioritized core precedes ordinary reconnect traffic")
        atomicPairManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(atomicPairWrites.count, 2,
                    "the response callback drains the paired extended frame")
        assertEqual(Data(atomicPairWrites[1].dropFirst(4)), extendedFrame,
                    "the correlated extended frame remains adjacent to its core")
        atomicPairManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(
            atomicPairWrites[2],
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
                Data([DeviceBLEProtocol.deviceCapabilitiesVersion]),
            "ordinary reconnect traffic drains after the complete workout pair"
        )

        func destinationStatusPrefix(_ data: Data) -> String? {
            String(data: data.prefix(4), encoding: .utf8)
        }

        let statusFirstManager = BLEManager()
        assert(statusFirstManager.handleDeviceCapabilitiesNotification(capability),
               "status-first manager receives workout capability")
        statusFirstManager.isConnected = true
        statusFirstManager.isNavigationReady = true
        var statusFirstReady = false
        var statusFirstWrites: [Data] = []
        statusFirstManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            expectsWriteResponse: true,
            canSend: { statusFirstReady },
            write: { statusFirstWrites.append($0) }
        ))
        assert(statusFirstManager.sendDestinationStatus(
            generation: 7,
            token: 11,
            status: .calculating,
            message: "Starting"
        ), "destination status is admitted before an urgent workout pair")
        assert(statusFirstManager.sendWorkoutTelemetryPair(
            core: frame,
            extended: extendedFrame,
            prioritized: true,
            onWrite: { _ in },
            onDrop: { _ in },
            onWriteFailure: { _ in }
        ), "urgent workout pair coexists with an earlier destination status")
        statusFirstReady = true
        statusFirstManager.completeNavigationWriteForTesting(error: nil)
        statusFirstManager.completeNavigationWriteForTesting(error: nil)
        statusFirstManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(statusFirstWrites.map(destinationStatusPrefix),
                    ["DNST", "WTLM", "WTLM"],
                    "an earlier destination status is preserved ahead of the adjacent pair")

        let pairFirstManager = BLEManager()
        assert(pairFirstManager.handleDeviceCapabilitiesNotification(capability),
               "pair-first manager receives workout capability")
        pairFirstManager.isConnected = true
        pairFirstManager.isNavigationReady = true
        var pairFirstReady = false
        var pairFirstWrites: [Data] = []
        pairFirstManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            expectsWriteResponse: true,
            canSend: { pairFirstReady },
            write: { pairFirstWrites.append($0) }
        ))
        assert(pairFirstManager.sendWorkoutTelemetryPair(
            core: frame,
            extended: extendedFrame,
            prioritized: true,
            onWrite: { _ in },
            onDrop: { _ in },
            onWriteFailure: { _ in }
        ), "urgent workout pair is admitted before a destination status")
        assert(pairFirstManager.sendDestinationStatus(
            generation: 8,
            token: 12,
            status: .started,
            message: "Started"
        ), "destination status coexists with an earlier urgent workout pair")
        pairFirstReady = true
        pairFirstManager.completeNavigationWriteForTesting(error: nil)
        pairFirstManager.completeNavigationWriteForTesting(error: nil)
        pairFirstManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(pairFirstWrites.map(destinationStatusPrefix),
                    ["WTLM", "WTLM", "DNST"],
                    "the adjacent pair is preserved ahead of a later destination status")

        let coalescingManager = BLEManager()
        assert(coalescingManager.handleDeviceCapabilitiesNotification(capability),
               "coalescing manager receives workout capability")
        coalescingManager.isConnected = true
        coalescingManager.isNavigationReady = true
        var transportReady = false
        var coalescedWrites: [Data] = []
        var dropped = 0
        coalescingManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { transportReady },
            write: { coalescedWrites.append($0) }
        ))
        let secondFrame = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            speedMetersPerSecond: 13
        ))!.core
        let latestFrame = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .paused,
            speedMetersPerSecond: 0
        ))!.core
        assert(coalescingManager.sendWorkoutTelemetryFrame(
            frame,
            onDrop: { dropped += 1 }
        ), "first blocked workout frame queues")
        assert(coalescingManager.sendWorkoutTelemetryFrame(
            secondFrame,
            onDrop: { dropped += 1 }
        ), "newer blocked workout frame replaces the first")
        assert(coalescingManager.sendWorkoutTelemetryFrame(
            latestFrame,
            prioritized: true,
            onDrop: { dropped += 1 }
        ), "urgent state replaces older queued workout data")
        assertEqual(dropped, 2,
                    "each obsolete queued workout core reports its drop")
        transportReady = true
        coalescingManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(coalescedWrites.count, 1,
                    "coalescing sends only the latest pending core")
        assertEqual(Data(coalescedWrites[0].dropFirst(4)), latestFrame,
                    "coalescing cannot replay stale workout state")

        let downgradeManager = BLEManager()
        assert(downgradeManager.handleDeviceCapabilitiesNotification(capability),
               "downgrade manager initially receives workout capability")
        downgradeManager.isConnected = true
        downgradeManager.isNavigationReady = true
        var downgradeTransportReady = false
        var downgradeWrites: [Data] = []
        var downgradeDrops = 0
        downgradeManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { downgradeTransportReady },
            write: { downgradeWrites.append($0) }
        ))
        assert(downgradeManager.sendWorkoutTelemetryFrame(
            frame,
            onDrop: { downgradeDrops += 1 }
        ), "blocked core is admitted while capability bit 7 is present")
        assert(downgradeManager.sendWorkoutTelemetryFrame(
            extendedFrame,
            onDrop: { downgradeDrops += 1 }
        ), "blocked extended frame is admitted while capability bit 7 is present")
        assert(downgradeManager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) + Data([0])
        ), "same-connection capability downgrade is consumed")
        assertEqual(downgradeDrops, 2,
                    "capability downgrade purges both queued health frames")
        downgradeTransportReady = true
        downgradeManager.completeNavigationWriteForTesting(error: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(downgradeWrites.allSatisfy {
            String(data: $0.prefix(4), encoding: .utf8) !=
                DeviceBLEProtocol.workoutTelemetryFallbackPrefix
        },
               "purged health frames cannot transmit after bit 7 is revoked")

        let malformedCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8)
        assert(fallbackManager.handleDeviceCapabilitiesNotification(malformedCapabilities),
               "malformed capability response is consumed")
        assert(!fallbackManager.supportsWorkoutTelemetry,
               "malformed capability response disables workout telemetry")
    }

    static func testDeviceSoundProtocol() {
        assertEqual(DeviceSound.allCases.map(\.rawValue), [1, 2, 5], "the picker omits the retired rotating-bell sound ID")
        assertEqual(DeviceSound.defaultSelection, .plasticBicycleHorn, "bicycle horn is the default sound")
        assertEqual(DeviceSound.defaultVolumePercent, 70, "device sound volume defaults to 70 percent")

        let defaultPacket = DeviceSound.plasticBicycleHorn.playPacket(volumePercent: .nan)
        assertEqual(String(data: defaultPacket.prefix(4), encoding: .utf8), "SNDP", "sound packet uses SNDP prefix")
        assertEqual(defaultPacket[4], DeviceSound.plasticBicycleHorn.rawValue, "sound packet contains sound ID")
        assertEqual(defaultPacket[5], 70, "non-finite volume falls back to the default")
        assertEqual(DeviceSound.bellDing.playPacket(volumePercent: -1)[5], 0, "sound volume clamps below zero")
        assertEqual(DeviceSound.squeezeHorn.playPacket(volumePercent: 101)[5], 100, "sound volume clamps above 100")

        let honkPacket = DeviceSound.rotatingBicycleBell.powerButtonHonkPacket(
            enabled: true,
            volumePercent: 45
        )
        assertEqual(String(data: honkPacket.prefix(4), encoding: .utf8), "SNDH", "PWR honk packet uses SNDH prefix")
        assertEqual(honkPacket[4], 1, "PWR honk packet contains enabled state")
        assertEqual(honkPacket[5], DeviceSound.rotatingBicycleBell.rawValue, "PWR honk packet contains sound ID")
        assertEqual(honkPacket[6], 45, "PWR honk packet contains volume")
        assertEqual(DeviceSound.bellDing.powerButtonHonkPacket(enabled: false, volumePercent: 200)[4], 0, "PWR honk packet contains disabled state")
        assertEqual(DeviceSound.bellDing.powerButtonHonkPacket(enabled: false, volumePercent: 200)[6], 100, "PWR honk volume clamps above 100")

        let trackedHonkPacket = DeviceSound.squeezeHorn.powerButtonHonkPacket(
            enabled: true,
            volumePercent: 80,
            requestID: 0xA1B2C3D4
        )
        assertEqual(trackedHonkPacket.count, 11, "tracked PWR honk packet includes the request ID")
        assertEqual(readUInt32LE(trackedHonkPacket, offset: 4), 0xA1B2C3D4,
                    "tracked PWR honk packet stores the request ID little-endian")
        assertEqual(trackedHonkPacket[8], 1, "tracked PWR honk packet contains enabled state")
        assertEqual(trackedHonkPacket[9], DeviceSound.squeezeHorn.rawValue,
                    "tracked PWR honk packet contains sound ID")
        assertEqual(trackedHonkPacket[10], 80, "tracked PWR honk packet contains volume")
    }

    static func testDevicePacketRouting() {
        var attempts: [String] = []
        let preferredSent = DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                attempts.append("preferred")
                return true
            },
            fallback: {
                attempts.append("fallback")
                return true
            }
        )
        assert(preferredSent, "successful preferred route reports success")
        assertEqual(attempts, ["preferred"],
                    "successful preferred route suppresses the fallback")

        attempts.removeAll()
        let fallbackSent = DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                attempts.append("preferred")
                return false
            },
            fallback: {
                attempts.append("fallback")
                return true
            }
        )
        assert(fallbackSent, "fallback success reports success")
        assertEqual(attempts, ["preferred", "fallback"],
                    "failed preferred route attempts the fallback once")

        attempts.removeAll()
        let failed = DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                attempts.append("preferred")
                return false
            },
            fallback: {
                attempts.append("fallback")
                return false
            }
        )
        assert(!failed, "two failed routes report failure")
        assertEqual(attempts, ["preferred", "fallback"],
                    "route failure still attempts each route exactly once")

        assert(
            !DeviceTransferPacketRoutingPolicy.usesNavigationFallback(
                firmwareMaintenanceActive: false,
                maintenanceReconnect: false
            ),
            "normal transfers prefer the native Settings characteristic"
        )
        assert(
            DeviceTransferPacketRoutingPolicy.usesNavigationFallback(
                firmwareMaintenanceActive: false,
                maintenanceReconnect: true
            ),
            "the first maintenance reconnect status bypasses a stale Settings handle"
        )
        assert(
            DeviceTransferPacketRoutingPolicy.usesNavigationFallback(
                firmwareMaintenanceActive: true,
                maintenanceReconnect: false
            ),
            "an active maintenance session keeps transfer control on Navigation"
        )
    }

    static func testDeviceTransferHandshakePolicy() {
        assertEqual(DeviceTransferHandshakePolicy.attemptCount, 32,
                    "transfer handshake retains its eight-second readiness window")
        assertEqual(DeviceTransferHandshakePolicy.remoteDebugAttemptCount, 64,
                    "LAN-first debug startup allows station timeout plus hotspot fallback")
        assertEqual(
            DeviceTransferHandshakePolicy.diagnosticsAttemptCount(lanFirst: true),
            DeviceTransferHandshakePolicy.remoteDebugAttemptCount,
            "LAN-first diagnostics allows station timeout plus hotspot fallback"
        )
        assertEqual(
            DeviceTransferHandshakePolicy.diagnosticsAttemptCount(lanFirst: false),
            DeviceTransferHandshakePolicy.attemptCount,
            "hotspot-only diagnostics keeps the ordinary readiness window"
        )
        assertEqual(DeviceTransferHandshakePolicy.remoteDebugExitAttemptCount, 32,
                    "debug teardown allows the worker's bounded stop path to finish")
        assertEqual(
            DeviceDiagnosticsHotspotFallbackPolicy.maximumAttemptCount,
            2,
            "diagnostics retries one hotspot transition for affected firmware"
        )
        assert(
            DeviceDiagnosticsHotspotFallbackPolicy.shouldRetry(
                error: RemoteDeviceDebugError.missingDiagnosticsSession
            ),
            "a missing fallback DSTS receives one compatibility retry"
        )
        assert(
            DeviceDiagnosticsHotspotFallbackPolicy.shouldRetry(
                error: RemoteDeviceDebugError.rejected(
                    code: "http_worker_stopping",
                    message: "worker is stopping"
                )
            ),
            "a retained LAN worker receives one compatibility retry"
        )
        assert(
            !DeviceDiagnosticsHotspotFallbackPolicy.shouldRetry(
                error: RemoteDeviceDebugError.rejected(
                    code: "transfer_busy",
                    message: "another mode is active"
                )
            ),
            "an unrelated active transfer is not retried"
        )
        assert(DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: 4),
               "transfer handshake refreshes status after one second")
        assert(!DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: 3),
               "transfer handshake does not flood status between refreshes")
        assert(DeviceNetworkJoinPolicy.isAlreadyAssociated(
            domain: DeviceNetworkJoinPolicy.hotspotErrorDomain,
            code: 13,
            message: "associated"
        ), "the public already-associated hotspot code is accepted")
        assert(DeviceNetworkJoinPolicy.shouldRetry(
            domain: DeviceNetworkJoinPolicy.hotspotErrorDomain,
            code: 8
        ), "an internal hotspot error receives one bounded retry")
        assert(!DeviceNetworkJoinPolicy.shouldRetry(
            domain: DeviceNetworkJoinPolicy.hotspotErrorDomain,
            code: 7
        ), "user denial never triggers a second join prompt")
        assert(
            DeviceNetworkJoinPolicy.hasAnotherAssociationAttempt(after: 0),
            "an unconfirmed first association has one bounded retry slot"
        )
        assert(
            !DeviceNetworkJoinPolicy.hasAnotherAssociationAttempt(after: 1),
            "device Wi-Fi association remains bounded to two attempts"
        )
        assert(DeviceNetworkJoinPolicy.associationObservationTimeout >= 10,
               "an accepted local-only network gets time to become current")
        assertEqual(
            DeviceTransferFreshFailurePolicy.failure(
                after: 17,
                currentSequence: 17,
                code: "tls_handshake_allocation_failed",
                message: "non-secret allocator telemetry"
            ),
            nil,
            "retained transfer history never replaces a new network failure"
        )
        assertEqual(
            DeviceTransferFreshFailurePolicy.failure(
                after: nil,
                currentSequence: nil,
                code: "legacy_error",
                message: "legacy firmware has no sequence"
            ),
            nil,
            "legacy firmware keeps the generic endpoint diagnostic"
        )
        assertEqual(
            DeviceTransferFreshFailurePolicy.failure(
                after: 17,
                currentSequence: 18,
                code: "tls_handshake_allocation_failed",
                message: "non-secret allocator telemetry"
            ),
            DeviceTransferFreshFailure(
                code: "tls_handshake_allocation_failed",
                message: "non-secret allocator telemetry"
            ),
            "a new authenticated sequence surfaces its device-side rejection"
        )
        assertEqual(
            DeviceTransferFreshFailurePolicy.failure(
                after: UInt64(UInt32.max),
                currentSequence: 1,
                code: "sd_unavailable",
                message: ""
            ),
            DeviceTransferFreshFailure(
                code: "sd_unavailable",
                message: "sd_unavailable"
            ),
            "sequence wrap and empty messages retain the classified failure"
        )
        assertEqual(DeviceNetworkJoinPolicy.diagnosticMessage(
            domain: DeviceNetworkJoinPolicy.hotspotErrorDomain,
            code: 17,
            message: "System denied configuration"
        ), "System denied configuration [NEHotspotConfigurationErrorDomain 17]",
                    "join failures retain their actionable domain and code")
        let securedConfiguration = DeviceNetworkJoinPolicy.makeHotspotConfiguration(
            ssid: "BikeComputer-Transfer",
            passphrase: "0123456789abcdef",
            open: { "open:\($0)" },
            secured: { "wpa2:\($0):\($1)" }
        )
        assertEqual(
            securedConfiguration,
            "wpa2:BikeComputer-Transfer:0123456789abcdef",
            "a diagnostics passphrase selects the WPA2 configuration path"
        )
        let openConfiguration = DeviceNetworkJoinPolicy.makeHotspotConfiguration(
            ssid: "BikeComputer-Transfer",
            passphrase: nil,
            open: { "open:\($0)" },
            secured: { "wpa2:\($0):\($1)" }
        )
        assertEqual(
            openConfiguration,
            "open:BikeComputer-Transfer",
            "a missing passphrase preserves legacy open-network behavior"
        )
        let emptyConfiguration = DeviceNetworkJoinPolicy.makeHotspotConfiguration(
            ssid: "BikeComputer-Transfer",
            passphrase: "",
            open: { "open:\($0)" },
            secured: { "wpa2:\($0):\($1)" }
        )
        assertEqual(emptyConfiguration, "open:BikeComputer-Transfer",
                    "an empty passphrase never constructs an invalid WPA2 join")
    }

    static func testDeviceCapabilitiesProtocol() {
        let manager = BLEManager()
        let supportedFlags = DeviceBLEProtocol.deviceSoundsCapabilityMask |
            DeviceBLEProtocol.powerButtonHonkCapabilityMask
        let supported = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([supportedFlags])
        assert(manager.handleDeviceCapabilitiesNotification(supported), "CAPS notification should be consumed")
        assert(manager.supportsDeviceSounds, "CAPS bit enables device sounds")
        assert(manager.supportsPowerButtonHonk, "CAPS bit enables PWR honk configuration")
        assert(!manager.supportsPowerButtonHonkAcknowledgement,
               "older PWR-capable firmware remains a one-shot configuration target")
        assert(manager.hasReceivedDeviceCapabilities, "valid CAPS completes capability negotiation")

        let extended = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(extended),
               "extended map visibility CAPS should be consumed")
        assert(manager.supportsExtendedMapVisibility,
               "CAPS bit enables independent service-road and track visibility")

        let independent = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(independent),
               "independent map profile CAPS should be consumed")
        assert(manager.supportsIndependentMapProfiles,
               "CAPS bit enables independent map profile controls")

        let birdsEye = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(birdsEye),
               "extended bird's-eye CAPS should be consumed")
        assert(manager.supportsBirdsEyeMapNavigation,
               "extended CAPS enables the bird's-eye Map + Navigation control")
        assert(!manager.supportsBirdsEyeMapNavigationPerspective,
               "bird's-eye bit zero alone preserves the fixed Standard perspective")

        let birdsEyePerspective =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(birdsEyePerspective),
               "adjustable bird's-eye CAPS should be consumed")
        assert(manager.supportsBirdsEyeMapNavigationPerspective,
               "extended CAPS bit one enables the perspective control")
        assert(!manager.supportsBirdsEyeMapNavigationStrongerPerspective,
               "bit one alone limits the picker to the first three levels")

        let strongerBirdsEyePerspective =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(strongerBirdsEyePerspective),
               "five-level bird's-eye CAPS should be consumed")
        assert(manager.supportsBirdsEyeMapNavigationStrongerPerspective,
               "extended CAPS bit two enables Very Strong and Maximum")

        let acknowledgedFlags = supportedFlags |
            DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask
        let acknowledged = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([acknowledgedFlags])
        assert(manager.handleDeviceCapabilitiesNotification(acknowledged),
               "ACK-capable CAPS should be consumed")
        assert(manager.supportsPowerButtonHonkAcknowledgement,
               "CAPS bit enables PWR honk acknowledgement handling")

        let deviceConfig = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([acknowledgedFlags, 1, DeviceSound.rotatingBicycleBell.rawValue, 65])
        assert(manager.handleDeviceCapabilitiesNotification(deviceConfig),
               "versioned CAPS configuration should be consumed")
        assert(manager.isPowerButtonHonkEnabled,
               "versioned CAPS restores the device-persisted PWR state")
        assertEqual(manager.selectedDeviceSound, .rotatingBicycleBell,
                    "versioned CAPS restores the device-persisted sound")
        assertEqual(manager.deviceSoundVolumePercent, 65,
                    "versioned CAPS restores the device-persisted volume")

        let extendedDeviceConfig =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([acknowledgedFlags, 1,
                  DeviceSound.rotatingBicycleBell.rawValue, 65,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(
            extendedDeviceConfig
        ), "extended CAPS with a PWR configuration should be consumed")
        assert(manager.supportsBirdsEyeMapNavigation,
               "the extended byte follows the complete PWR configuration")
        assert(manager.supportsBirdsEyeMapNavigationPerspective,
               "the PWR configuration response also carries perspective support")
        assert(manager.supportsBirdsEyeMapNavigationStrongerPerspective,
               "the PWR configuration response carries five-level perspective support")

        let invalidDeviceConfig = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([acknowledgedFlags, 2, DeviceSound.bellDing.rawValue, 70])
        assert(manager.handleDeviceCapabilitiesNotification(invalidDeviceConfig),
               "invalid versioned CAPS configuration should be consumed")
        assert(!manager.hasReceivedDeviceCapabilities,
               "invalid versioned CAPS configuration remains retryable")

        let soundOnly = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.deviceSoundsCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(soundOnly), "sound-only CAPS should be consumed")
        assert(manager.supportsDeviceSounds, "sound-only CAPS keeps device sounds enabled")
        assert(!manager.supportsPowerButtonHonk, "clear PWR honk bit disables PWR configuration")
        assert(!manager.supportsPowerButtonHonkAcknowledgement,
               "PWR acknowledgement cannot be advertised without PWR support")
        assert(manager.hasReceivedDeviceCapabilities, "sound-only CAPS still completes negotiation")

        let malformed = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8)
        assert(manager.handleDeviceCapabilitiesNotification(malformed), "malformed CAPS should be consumed")
        assert(!manager.supportsPowerButtonHonk, "malformed CAPS clears PWR honk support")
        assert(!manager.supportsPowerButtonHonkAcknowledgement,
               "malformed CAPS clears PWR honk acknowledgement support")
        assert(!manager.supportsExtendedMapVisibility,
               "malformed CAPS clears extended map visibility support")
        assert(!manager.supportsIndependentMapProfiles,
               "malformed CAPS clears independent map profile support")
        assert(!manager.supportsBirdsEyeMapNavigation,
               "malformed CAPS clears bird's-eye Map + Navigation support")
        assert(!manager.supportsBirdsEyeMapNavigationPerspective,
               "malformed CAPS clears bird's-eye perspective support")
        assert(!manager.supportsBirdsEyeMapNavigationStrongerPerspective,
               "malformed CAPS clears stronger bird's-eye perspective support")
        assert(!manager.supportsRemoteDeviceDebug,
               "malformed CAPS clears remote-debug support")
        assert(!manager.supportsGPSPositionQualityV1,
               "malformed CAPS clears GPS-quality support")
        assert(!manager.hasReceivedDeviceCapabilities, "malformed CAPS does not complete negotiation")

        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0x3F, 0, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2),
               "CAP2 notification should be consumed")
        assert(manager.supportsStreetLabels,
               "CAP2 bit 8 enables street-label map controls")
        assert(manager.supportsBirdsEyeMapNavigation,
               "CAP2 bit 9 preserves bird's-eye Map + Navigation support")
        assert(manager.supportsBirdsEyeMapNavigationPerspective,
               "CAP2 bit 10 preserves bird's-eye perspective support")
        assert(manager.supportsBirdsEyeMapNavigationStrongerPerspective,
               "CAP2 bit 11 preserves stronger bird's-eye perspective support")
        assert(manager.supports3DBuildings,
               "CAP2 bit 12 enables OSM 3D-building maps and controls")
        assert(manager.supportsExplicitInvalidGPSHeading,
               "CAP2 bit 13 enables the explicit missing-course sentinel")
        assert(!manager.supportsScopedWatchController,
               "CAP2 bit 13 does not collide with scoped Watch enrollment")
        assert(!manager.supportsRemoteDeviceDebug,
               "CAP2 bit 13 does not collide with remote device debugging")
        assert(manager.hasReceivedDeviceCapabilities,
               "valid CAP2 completes capability negotiation")

        let cap2WithScopedWatch = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0x7F, 0, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithScopedWatch),
               "CAP2 scoped Watch notification should be consumed")
        assert(manager.supportsExplicitInvalidGPSHeading,
               "CAP2 bit 13 remains the explicit missing-course sentinel")
        assert(manager.supportsScopedWatchController,
               "CAP2 bit 14 enables scoped Watch enrollment")
        assert(!manager.supportsRemoteDeviceDebug,
               "CAP2 bit 14 does not collide with remote device debugging")

        let cap2WithRemoteDebug = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithRemoteDebug),
               "CAP2 remote-debug notification should be consumed")
        assert(manager.supportsRemoteDeviceDebug,
               "CAP2 bit 16 enables remote device debugging")
        assert(!manager.supportsScopedWatchController,
               "CAP2 bit 16 does not collide with scoped Watch enrollment")

        let cap2WithGPSQuality = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 2, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithGPSQuality),
               "CAP2 GPS-quality notification should be consumed")
        assert(manager.supportsGPSPositionQualityV1,
               "CAP2 bit 17 enables the GPS quality v1 tail")
        assert(!manager.supportsRemoteDeviceDebug,
               "CAP2 bit 17 does not collide with remote debugging")

        let cap2WithMainFeatures = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 0x84, 0x03])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithMainFeatures),
               "renderer, orientation and Watch GPS capabilities are accepted together")
        assert(manager.supportsRendererBenchmarkSample &&
               manager.supportsWatchGPSMotionEvidenceV1,
               "existing renderer and Watch GPS features stay negotiated")
        assert(!manager.supportsWorldRadio &&
               !manager.availableDeviceScreens.contains(.worldRadio),
               "main firmware cannot be mistaken for World Radio firmware")

        let cap2WithWorldRadio = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 0x84, 0x0B])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithWorldRadio),
               "World Radio is negotiated alongside main features")
        assert(manager.supportsWorldRadio && manager.supportsRendererBenchmarkSample &&
               manager.supportsWatchGPSMotionEvidenceV1,
               "World Radio does not replace renderer or Watch GPS support")

        let cap2WithConfig = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, acknowledgedFlags, 0x0F, 0, 0, 1, 3, 1,
                  DeviceSound.rotatingBicycleBell.rawValue, 65])
        assert(manager.handleDeviceCapabilitiesNotification(cap2WithConfig),
               "CAP2 power configuration TLV is consumed")
        assert(manager.supportsStreetLabels,
               "CAP2 preserves the extended street-label capability")
        assert(!manager.supportsExplicitInvalidGPSHeading,
               "CAP2 version 10 firmware without bit 13 keeps legacy heading encoding")
        assert(!manager.supportsScopedWatchController,
               "CAP2 firmware without bit 14 keeps scoped Watch control disabled")
        assert(!manager.supportsRemoteDeviceDebug,
               "CAP2 firmware without bit 16 keeps remote debugging disabled")
        assert(!manager.supportsWorldRadio,
               "reconnecting to older firmware clears World Radio support")

        assert(manager.handleDeviceCapabilitiesNotification(cap2WithWorldRadio),
               "World Radio can be negotiated again before a malformed response")

        let duplicateTLV = cap2WithConfig + Data([1, 3, 1, 0, 50])
        assert(manager.handleDeviceCapabilitiesNotification(duplicateTLV),
               "malformed CAP2 is consumed for retry")
        assert(!manager.hasReceivedDeviceCapabilities,
               "duplicate CAP2 TLVs are rejected")
        assert(!manager.supportsExplicitInvalidGPSHeading,
               "malformed capabilities clear explicit invalid-heading support")
        assert(!manager.supportsScopedWatchController,
               "malformed capabilities clear scoped Watch support")
        assert(!manager.supportsWorldRadio && !manager.supportsWatchGPSMotionEvidenceV1,
               "malformed capabilities clear both World Radio and Watch GPS support")

        UserDefaults.standard.removeObject(forKey: "deviceSettings.selectedSound")
        UserDefaults.standard.removeObject(forKey: "deviceSettings.soundVolumePercent")
        UserDefaults.standard.removeObject(forKey: "deviceSettings.powerButtonHonkEnabled")
    }

    static func testBatteryStatusScreenCapabilityNegotiation() {
        func configuredManager() -> (BLEManager, () -> [Data]) {
            let manager = BLEManager()
            manager.isConnected = true
            manager.isNavigationReady = true
            manager.supportsDeviceSettings = true
            manager.enabledDeviceScreensMask = DeviceScreen.allScreensMask
            manager.defaultDeviceScreen = .batteryStatus
            var packets: [Data] = []
            manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
                maximumWriteLength: 20,
                canSend: { true },
                write: { packets.append($0) }
            ))
            return (manager, { packets })
        }

        func screenSettings(in packets: [Data]) -> [UInt8: Int32] {
            var settings: [UInt8: Int32] = [:]
            for packet in packets where packet.count == 9 &&
                String(data: packet.prefix(4), encoding: .utf8) ==
                    DeviceBLEProtocol.settingsFallbackPrefix {
                let id = packet[4]
                if id == DeviceBLEProtocol.enabledScreensSettingID ||
                    id == DeviceBLEProtocol.defaultScreenSettingID {
                    settings[id] = readInt32LE(packet, offset: 5)
                }
            }
            return settings
        }

        let (legacyManager, legacyPackets) = configuredManager()
        let legacyCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([0])
        assert(legacyManager.handleDeviceCapabilitiesNotification(legacyCapabilities),
               "legacy firmware capability response should be consumed")
        assert(!legacyManager.supportsBatteryStatusScreen,
               "firmware without bit 5 does not expose Battery Status")
        assert(!legacyManager.availableDeviceScreens.contains(.batteryStatus),
               "legacy firmware hides Battery Status from device settings")
        let legacySettings = screenSettings(in: legacyPackets())
        assertEqual(legacySettings[DeviceBLEProtocol.enabledScreensSettingID],
                    Int32(DeviceScreen.legacyScreensMask),
                    "legacy firmware receives a four-screen mask")
        assertEqual(legacySettings[DeviceBLEProtocol.defaultScreenSettingID],
                    Int32(DeviceScreen.mapPlusNavigation.rawValue),
                    "legacy firmware receives a supported default screen")

        let (currentManager, currentPackets) = configuredManager()
        let currentCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.batteryStatusScreenCapabilityMask])
        assert(currentManager.handleDeviceCapabilitiesNotification(currentCapabilities),
               "Battery Status capability response should be consumed")
        assert(currentManager.supportsBatteryStatusScreen,
               "firmware bit 5 exposes Battery Status")
        assert(currentManager.availableDeviceScreens.last == .batteryStatus,
               "Battery Status remains the last available screen")
        let currentSettings = screenSettings(in: currentPackets())
        assertEqual(currentSettings[DeviceBLEProtocol.enabledScreensSettingID],
                    Int32(DeviceScreen.allScreensMask & ~DeviceScreen.worldRadio.bit) |
                        DeviceBLEProtocol.currentScreenMaskMarker,
                    "Battery Status firmware receives a marked five-screen mask")
        assertEqual(currentSettings[DeviceBLEProtocol.defaultScreenSettingID],
                    Int32(DeviceScreen.batteryStatus.rawValue),
                    "current firmware may use Battery Status as its default")

        let (radioManager, radioPackets) = configuredManager()
        var radioCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8)
        radioCapabilities.append(1)
        let radioFlags = UInt32(DeviceBLEProtocol.batteryStatusScreenCapabilityMask) |
            DeviceBLEProtocol.worldRadioCapabilityMask
        radioCapabilities.append(UInt8(truncatingIfNeeded: radioFlags))
        radioCapabilities.append(UInt8(truncatingIfNeeded: radioFlags >> 8))
        radioCapabilities.append(UInt8(truncatingIfNeeded: radioFlags >> 16))
        radioCapabilities.append(UInt8(truncatingIfNeeded: radioFlags >> 24))
        assert(radioManager.handleDeviceCapabilitiesNotification(radioCapabilities),
               "World Radio capability response should be consumed")
        assert(radioManager.supportsWorldRadio,
               "firmware bit 27 exposes World Radio")
        assert(radioManager.availableDeviceScreens.contains(.worldRadio),
               "World Radio is available on capable firmware")
        let radioSettings = screenSettings(in: radioPackets())
        assertEqual(radioSettings[DeviceBLEProtocol.enabledScreensSettingID],
                    Int32(DeviceScreen.allScreensMask) |
                        DeviceBLEProtocol.currentScreenMaskMarker,
                    "World Radio firmware receives a marked six-screen mask")

        let (fallbackManager, fallbackPackets) = configuredManager()
        fallbackManager.useDeviceCapabilitiesFallback()
        let fallbackSettings = screenSettings(in: fallbackPackets())
        assertEqual(fallbackSettings[DeviceBLEProtocol.enabledScreensSettingID],
                    Int32(DeviceScreen.legacyScreensMask),
                    "a missing capability response falls back to the legacy mask")
        assertEqual(fallbackSettings[DeviceBLEProtocol.defaultScreenSettingID],
                    Int32(DeviceScreen.mapPlusNavigation.rawValue),
                    "a missing capability response never selects Battery Status")
    }

    static func testMapProfileCapabilityNegotiation() {
        UserDefaults.standard.removeObject(
            forKey: "mapPlusNavigationSettings.birdsEyeViewEnabled"
        )
        UserDefaults.standard.removeObject(
            forKey: "mapPlusNavigationSettings.birdsEyePerspective"
        )
        let defaultManager = BLEManager()
        assert(defaultManager.mapPlusNavigationBirdsEyeViewEnabled,
               "bird's-eye Map + Navigation defaults on")
        assertEqual(defaultManager.mapPlusNavigationBirdsEyePerspective,
                    .standard,
                    "bird's-eye perspective defaults to Standard")

        func configuredManager() -> (BLEManager, () -> [Data]) {
            let manager = BLEManager()
            manager.isConnected = true
            manager.isNavigationReady = true
            manager.detailLevel = 2
            manager.zoomLevel = 5
            manager.showBuildings = true
            manager.mapPlusNavigationDetailLevel = 0
            manager.mapPlusNavigationZoomLevel = 1
            manager.mapPlusNavigationShowBuildings = false
            var packets: [Data] = []
            manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
                maximumWriteLength: 20,
                canSend: { true },
                write: { packets.append($0) }
            ))
            return (manager, { packets })
        }

        let independentFlags = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask])
        let (independentManager, independentPackets) = configuredManager()
        assert(independentManager.handleDeviceCapabilitiesNotification(independentFlags),
               "independent profile capability response should be consumed")
        assertEqual(independentPackets().map { $0[4] },
                    [20, 16, 17, 18, 21, 22, 19, 6, 8, 1, 2, 3, 9, 10, 7],
                    "new firmware receives the independent profile before legacy Map IDs")
        let independentDetail = independentPackets().first { $0[4] == 17 }
        assertEqual(readInt32LE(independentDetail!, offset: 5), 0,
                    "independent Map + Navigation detail remains distinct")

        let rotationKey = "mapPlusNavigationSettings.rotationMode"
        let savedRotation = UserDefaults.standard.object(forKey: rotationKey)
        defer {
            if let savedRotation { UserDefaults.standard.set(savedRotation, forKey: rotationKey) }
            else { UserDefaults.standard.removeObject(forKey: rotationKey) }
        }
        UserDefaults.standard.removeObject(forKey: rotationKey)
        assertEqual(BLEManager().mapPlusNavigationRotationMode, 1, "missing orientation defaults Course Up")
        assert(!independentManager.sendSetting(id: 37, value: 0), "legacy firmware never receives orientation")
        assertEqual(BLEManager().mapPlusNavigationRotationMode, 0, "unsupported device retains local preference")
        assert(!independentPackets().contains { $0.count == 9 && $0[4] == 37 }, "no unsupported orientation packet")
        let orientationCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 8, 0, 0, 1])
        assert(independentManager.handleDeviceCapabilitiesNotification(orientationCapabilities), "late orientation capability is accepted")
        assert(independentManager.supportsMapNavigationOrientation, "orientation capability is exposed")
        let rotationPacket = independentPackets().last { $0.count == 9 && $0[4] == 37 }
        assert(rotationPacket != nil, "late capability resynchronizes retained orientation")
        assertEqual(readInt32LE(rotationPacket!, offset: 5), 0, "retained North Up is sent")
        assert(independentManager.sendSetting(id: 37, value: -1), "supported orientation is sent")
        let normalizedRotation = independentPackets().last { $0.count == 9 && $0[4] == 37 }
        assertEqual(readInt32LE(normalizedRotation!, offset: 5), 1, "invalid orientation normalizes on wire")
        assert(independentManager.handleDeviceCapabilitiesNotification(independentFlags), "capability downgrade is accepted")
        assert(!independentManager.supportsMapNavigationOrientation, "downgrade clears support")
        assert(!independentManager.sendSetting(id: 37, value: 0), "downgraded session does not send orientation")

        let (birdsEyeManager, birdsEyePackets) = configuredManager()
        birdsEyeManager.mapPlusNavigationBirdsEyeViewEnabled = false
        let birdsEyeCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask])
        assert(birdsEyeManager.handleDeviceCapabilitiesNotification(
            birdsEyeCapabilities
        ), "bird's-eye capability response should be consumed")
        assert(birdsEyeManager.supportsBirdsEyeMapNavigation,
               "bird's-eye capability enables the setting")
        assertEqual(birdsEyePackets().map { $0[4] },
                    [20, 16, 17, 18, 21, 22, 19, 25, 6, 8, 1, 2, 3, 9, 10, 7],
                    "supported firmware receives the bird's-eye preference with the Map + Navigation profile")
        let birdsEyeSetting = birdsEyePackets().first { $0[4] == 25 }
        assertEqual(readInt32LE(birdsEyeSetting!, offset: 5), 0,
                    "the disabled bird's-eye preference is sent as zero")
        let restoredManager = BLEManager()
        assert(!restoredManager.mapPlusNavigationBirdsEyeViewEnabled,
               "the disabled bird's-eye preference survives a settings reload")

        let (perspectiveManager, perspectivePackets) = configuredManager()
        perspectiveManager.mapPlusNavigationBirdsEyePerspective = .maximum
        let perspectiveCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask])
        assert(perspectiveManager.handleDeviceCapabilitiesNotification(
            perspectiveCapabilities
        ), "bird's-eye perspective capability response should be consumed")
        assertEqual(perspectivePackets().map { $0[4] },
                    [20, 16, 17, 18, 21, 22, 19, 25, 26, 6, 8, 1, 2, 3, 9, 10, 7],
                    "adjustable firmware receives both bird's-eye settings")
        let perspectiveSetting = perspectivePackets().first { $0[4] == 26 }
        assertEqual(readInt32LE(perspectiveSetting!, offset: 5), 2,
                    "older adjustable firmware receives Strong instead of Maximum")
        let restoredPerspectiveManager = BLEManager()
        assertEqual(restoredPerspectiveManager.mapPlusNavigationBirdsEyePerspective,
                    .maximum,
                    "the bird's-eye perspective survives a settings reload")

        let (strongerPerspectiveManager, strongerPerspectivePackets) = configuredManager()
        strongerPerspectiveManager.mapPlusNavigationBirdsEyePerspective = .maximum
        let strongerPerspectiveCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask,
                  DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask |
                    DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask])
        assert(strongerPerspectiveManager.handleDeviceCapabilitiesNotification(
            strongerPerspectiveCapabilities
        ), "five-level bird's-eye perspective capability should be consumed")
        let strongerPerspectiveSetting = strongerPerspectivePackets().first { $0[4] == 26 }
        assertEqual(readInt32LE(strongerPerspectiveSetting!, offset: 5), 4,
                    "Maximum is sent as four to five-level firmware")

        let (legacyManager, legacyPackets) = configuredManager()
        let baselineCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) + Data([0])
        assert(legacyManager.handleDeviceCapabilitiesNotification(baselineCapabilities),
               "baseline capability response should be consumed")
        assertEqual(legacyPackets().map { $0[4] }, [6, 8, 1, 2, 3, 9, 10, 7],
                    "legacy firmware receives only its shared Map profile IDs")
        assertEqual(legacyManager.mapPlusNavigationZoomLevel, 1,
                    "negotiation preserves the hidden independent local profile")
        legacyManager.detailLevel = 1
        legacyManager.sendSetting(id: 2, value: 1)
        assertEqual(legacyManager.mapPlusNavigationDetailLevel, 1,
                    "live legacy edits synchronize the local shared profile")
        legacyManager.mapPlusNavigationZoomLevel = 1
        legacyManager.showRouteOverlay = false
        legacyManager.sendVisibilityMask()
        assertEqual(legacyManager.mapPlusNavigationZoomLevel, 1,
                    "global overlay edits preserve the hidden independent profile")
        let packetCountBeforeUnsupportedWrite = legacyPackets().count
        legacyManager.sendSetting(id: DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID,
                                  value: 0)
        assertEqual(legacyPackets().count, packetCountBeforeUnsupportedWrite,
                    "unsupported independent setting IDs are not sent")

        let (lateManager, latePackets) = configuredManager()
        lateManager.useDeviceCapabilitiesFallback()
        assertEqual(latePackets().map { $0[4] }, [6, 8, 1, 2, 3, 9, 10, 7],
                    "timeout fallback sends only the legacy shared profile")
        let lateExtendedFlags = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask |
                  DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(lateManager.handleDeviceCapabilitiesNotification(lateExtendedFlags),
               "late independent profile response should still be consumed")
        assertEqual(Array(latePackets().map { $0[4] }.suffix(15)),
                    [20, 16, 17, 18, 21, 22, 19, 6, 8, 1, 2, 3, 9, 10, 7],
                    "late extended response resends both profiles with new semantics")
        let resentMapVisibility = latePackets().last { $0[4] == 8 }
        assert(readInt32LE(resentMapVisibility!, offset: 5) &
               DeviceBLEProtocol.extendedVisibilityMarker != 0,
               "late extended response repairs the folded Map visibility mask")
        UserDefaults.standard.removeObject(
            forKey: "mapPlusNavigationSettings.birdsEyeViewEnabled"
        )
        UserDefaults.standard.removeObject(
            forKey: "mapPlusNavigationSettings.birdsEyePerspective"
        )
    }

    static func testDeviceCapabilitySynchronizesPowerButtonHonkOnce() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.isPowerButtonHonkEnabled = true
        manager.selectedDeviceSound = .squeezeHorn
        manager.deviceSoundVolumePercent = 55

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let flags = DeviceBLEProtocol.deviceSoundsCapabilityMask |
            DeviceBLEProtocol.powerButtonHonkCapabilityMask |
            DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask
        let capabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([flags])

        assert(manager.handleDeviceCapabilitiesNotification(capabilities),
               "first CAPS notification should be consumed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let honkPackets = sentPackets.filter {
            String(data: $0.prefix(4), encoding: .utf8) == DeviceBLEProtocol.powerButtonHonkPrefix
        }
        assertEqual(honkPackets.count, 1,
                    "first PWR capability notification synchronizes configuration")
        assertEqual(String(data: honkPackets[0].prefix(4), encoding: .utf8), "SNDH",
                    "capability synchronization sends a PWR honk frame")

        let staleDeviceConfig = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([flags, 0, DeviceSound.bellDing.rawValue, 20])
        assert(manager.handleDeviceCapabilitiesNotification(staleDeviceConfig),
               "versioned capability response should be consumed during an in-flight update")
        assert(manager.isPowerButtonHonkEnabled,
               "an in-flight local update wins over an older device snapshot")
        assertEqual(manager.selectedDeviceSound, .squeezeHorn,
                    "an older device snapshot does not replace the pending sound")
        assertEqual(manager.deviceSoundVolumePercent, 55,
                    "an older device snapshot does not replace the pending volume")

        let successStatus = powerButtonHonkStatus(for: honkPackets[0], applied: 1)
        assert(manager.handleNavigationCharacteristicNotification(successStatus),
               "capability synchronization acknowledgement should be consumed")

        assert(manager.handleDeviceCapabilitiesNotification(capabilities),
               "duplicate CAPS notification should be consumed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        assertEqual(sentPackets.filter {
            String(data: $0.prefix(4), encoding: .utf8) == DeviceBLEProtocol.powerButtonHonkPrefix
        }.count, 1,
                    "duplicate PWR capability notification does not resend configuration")

        let deviceConfig = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([flags, 1, DeviceSound.rotatingBicycleBell.rawValue, 60])
        assert(manager.handleDeviceCapabilitiesNotification(deviceConfig),
               "versioned capability response should restore device state")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        assertEqual(sentPackets.filter {
            String(data: $0.prefix(4), encoding: .utf8) == DeviceBLEProtocol.powerButtonHonkPrefix
        }.count, 1,
                    "device-authoritative capability state is not written back")
        assert(manager.isPowerButtonHonkEnabled,
               "device-authoritative capability state remains enabled")
        assertEqual(manager.selectedDeviceSound, .rotatingBicycleBell,
                    "device-authoritative capability state selects the device sound")

        let disabledDeviceConfig = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([flags, 0, DeviceSound.bellDing.rawValue, 20])
        assert(manager.handleDeviceCapabilitiesNotification(disabledDeviceConfig),
               "disabled device configuration should still restore the toggle")
        assert(!manager.isPowerButtonHonkEnabled,
               "disabled device configuration restores the disabled PWR state")
        assertEqual(manager.selectedDeviceSound, .rotatingBicycleBell,
                    "dormant PWR configuration does not replace the map-button sound")
        assertEqual(manager.deviceSoundVolumePercent, 60,
                    "dormant PWR configuration does not replace the map-button volume")
    }

    static func testDeviceCapabilityRetryPolicy() {
        assert(DeviceCapabilityRetry.shouldRequest(isNavigationReady: true,
                                                   hasReceivedCapabilities: false,
                                                   attempt: 0),
               "ready devices retry missing capabilities")
        assert(!DeviceCapabilityRetry.shouldRequest(isNavigationReady: false,
                                                    hasReceivedCapabilities: false,
                                                    attempt: 0),
               "disconnected devices do not retry capabilities")
        assert(!DeviceCapabilityRetry.shouldRequest(isNavigationReady: true,
                                                    hasReceivedCapabilities: true,
                                                    attempt: 0),
               "completed capability negotiation stops retries")
        assert(!DeviceCapabilityRetry.shouldRequest(isNavigationReady: true,
                                                    hasReceivedCapabilities: false,
                                                    attempt: DeviceCapabilityRetry.maxAttempts),
               "capability retries stop at the attempt limit")
        assert(DeviceCapabilityRetry.isCurrentSession(4, currentGeneration: 4),
               "retry tokens remain valid within one BLE session")
        assert(!DeviceCapabilityRetry.isCurrentSession(4, currentGeneration: 5),
               "retry tokens from a previous BLE session are rejected")
        assert(PowerButtonHonkRetry.shouldRetry(isNavigationReady: true, attempt: 0),
               "PWR honk acknowledgement retries after the first attempt")
        assert(PowerButtonHonkRetry.shouldRetry(isNavigationReady: true, attempt: 1),
               "PWR honk acknowledgement allows the final attempt")
        assert(!PowerButtonHonkRetry.shouldRetry(isNavigationReady: true, attempt: 2),
               "PWR honk acknowledgement stops after three total attempts")
        assert(!PowerButtonHonkRetry.shouldRetry(isNavigationReady: false, attempt: 0),
               "PWR honk acknowledgement does not retry after disconnect")

        let queue = DispatchQueue(label: "DeviceCapabilityRetryTests")
        let scheduled = DispatchSemaphore(value: 0)
        queue.suspend()
        var didRun = false
        DeviceCapabilityRetry.scheduleInitial(on: queue) {
            didRun = true
            scheduled.signal()
        }
        assert(!didRun, "initial capability retry is deferred past Published willSet")
        queue.resume()
        assertEqual(scheduled.wait(timeout: .now() + 1), .success,
                    "deferred capability retry executes")
        assert(didRun, "deferred capability retry runs its action")
    }

    static func testHardwareLabelPreference() {
        assertEqual(DeviceBLEProtocol.hardwareLabel(model: "BikeComputer-XIAO", hardware: "nRF52840"),
                    "BikeComputer-XIAO",
                    "model number is the preferred hardware label")
        assertEqual(DeviceBLEProtocol.hardwareLabel(model: nil, hardware: "XIAO nRF52840"),
                    "XIAO nRF52840",
                    "hardware revision is used when model is absent")
        assertEqual(DeviceBLEProtocol.hardwareLabel(model: "", hardware: ""),
                    "",
                    "missing device information produces no hardware label")
    }

    static func testBLEPairingAuthenticator() {
        let nonce = "00112233445566778899aabbccddeeff"
        let serverProof = "a88fdf1fe1bc0381314cc68820d92cb8da4942cb49ba2062d7f7750cd1f7eb4b"
        let clientProof = "e6b9765e3a076e348c7145a22b7496974233194b51c051cea3729468025649fd"

        assert(
            BLEPairingAuthenticator.isValidServerResponse("SERVER|\(nonce)|\(serverProof)", nonce: nonce),
            "valid server proof should authenticate"
        )
        assert(
            !BLEPairingAuthenticator.isValidServerResponse("SERVER|ffffffffffffffffffffffffffffffff|\(serverProof)", nonce: nonce),
            "server proof with wrong nonce should fail"
        )
        assert(
            !BLEPairingAuthenticator.isValidServerResponse("SERVER|\(nonce)|\(String(repeating: "0", count: 64))", nonce: nonce),
            "server proof with wrong MAC should fail"
        )
        assertEqual(BLEPairingAuthenticator.clientProof(nonce: nonce), clientProof, "client proof matches firmware vector")
        assertEqual(BLEPairingAuthenticator.makeNonce()?.count, 32, "generated nonce uses 16 random bytes encoded as hex")
    }

    static func testDeviceOwnershipProtocol() {
        var appPrivate = Data(repeating: 0, count: 32)
        appPrivate[31] = 1
        var devicePrivate = Data(repeating: 0, count: 32)
        devicePrivate[31] = 2
        let ownerID = Data((0..<16).map { UInt8(0xF0 + $0) })
        let deviceID = Data((0..<16).map(UInt8.init))
        let peripheralID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let session = try! DevicePairingSession(
            peripheralIdentifier: peripheralID,
            ownerID: ownerID,
            deviceName: "Chris’ bike",
            privateKeyRawRepresentation: appPrivate
        )
        let deviceKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: devicePrivate)
        let response = "PAIRING|\(deviceID.ownershipHex)|\(deviceKey.publicKey.x963Representation.ownershipHex)"
        let material = try! session.material(from: response)
        assert(session.matches(peripheralIdentifier: peripheralID), "pairing sessions bind to their selected peripheral")
        assert(!session.matches(peripheralIdentifier: UUID()), "pairing sessions reject a different peripheral")

        assertEqual(
            material.ownerKey.ownershipHex,
            "024d0fb0b003b6d22569ef8e5a382eaa9bbd29ebeaee683d93992ae1399900cf",
            "P-256 and HKDF owner key matches the firmware vector"
        )
        assertEqual(material.comparisonCode, 983668, "pairing comparison code matches the firmware vector")
        let leadingZeroPrompt = BikeComputerPairingPrompt(
            peripheralIdentifier: peripheralID,
            deviceName: "My bike",
            shortIdentifier: "1234",
            comparisonCode: 42,
            isReplacingExistingRegistration: false
        )
        assertEqual(leadingZeroPrompt.formattedCode, "000042",
                    "comparison codes always display all six digits")
        assert(material.confirmationCommand.hasPrefix("CONFIRM|f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff|"),
               "confirmation binds the installation owner ID")
        assert(material.confirmationCommand.hasSuffix("|4368726973e280992062696b65"),
               "confirmation transmits the normalized device name as UTF-8 hex")

        let ownershipFixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/device-ownership-test-vectors.json")
        let ownershipFixture = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: ownershipFixtureURL)
        ) as! [String: String]
        let advertisement = Data(
            ownershipHex: ownershipFixture["advertisementClaimed"]!
        )!
        let discovered = DiscoveredBikeComputerDevice.parse(
            peripheralIdentifier: peripheralID,
            localName: "Chris’ bike",
            manufacturerData: advertisement,
            rssi: -55
        )
        assertEqual(discovered.identitySuffix, "FA85158D", "iOS consumes the firmware-generated identity suffix fixture")
        assertEqual(discovered.shortIdentifier, "158D", "the UI presents the same short device identifier as firmware")
        assertEqual(discovered.isClaimed, true, "advertising exposes ownership state")
        assertEqual(discovered.advertisedName, "Chris’ bike", "advertising exposes the user-assigned name")
        assertEqual(
            BLEDiscoveryFreshnessPolicy.retained(
                [discovered],
                now: discovered.lastSeenAt.addingTimeInterval(5)
            ).count,
            1,
            "recent Nearby observations remain visible"
        )
        assertEqual(
            BLEDiscoveryFreshnessPolicy.retained(
                [discovered],
                now: discovered.lastSeenAt.addingTimeInterval(7)
            ).count,
            0,
            "Nearby observations expire after the freshness window"
        )
        let otherPeripheralID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        assert(!BLEPairingCancellationPolicy.shouldDisconnect(
            connectedPeripheralIdentifier: peripheralID,
            pairingPeripheralIdentifier: otherPeripheralID,
            hasActivePairing: true
        ), "canceling a handoff to another device preserves the current connection")
        assert(BLEPairingCancellationPolicy.shouldDisconnect(
            connectedPeripheralIdentifier: otherPeripheralID,
            pairingPeripheralIdentifier: otherPeripheralID,
            hasActivePairing: true
        ), "canceling an active candidate connection disconnects only that candidate")
        assert(!BLEPairingCancellationPolicy.shouldDisconnect(
            connectedPeripheralIdentifier: peripheralID,
            pairingPeripheralIdentifier: otherPeripheralID,
            hasActivePairing: false
        ), "closing the pre-Continue naming sheet never disconnects hardware")

        assertEqual(
            BikeComputersMenuPolicy.title(knownDeviceCount: 0),
            "Connect your Bicino",
            "an empty registry presents the connect menu"
        )
        assertEqual(
            BikeComputersMenuPolicy.title(knownDeviceCount: 1),
            "My Bike Computer",
            "one registered device uses the singular menu title"
        )
        assertEqual(
            BikeComputersMenuPolicy.title(knownDeviceCount: 2),
            "My Bike Computers",
            "multiple registered devices use the plural menu title"
        )
        assert(BikeComputersMenuPolicy.shouldStartDiscoveryOnEntry(
            knownDeviceCount: 0
        ), "an empty registry starts discovery on menu entry")
        assert(!BikeComputersMenuPolicy.shouldStartDiscoveryOnEntry(
            knownDeviceCount: 1
        ), "a registered device keeps discovery opt-in")
        assert(!BikeComputersMenuPolicy.shouldShowConnectNewDeviceAction(
            knownDeviceCount: 0
        ), "the empty state does not duplicate its automatic discovery action")
        assert(BikeComputersMenuPolicy.shouldShowConnectNewDeviceAction(
            knownDeviceCount: 1
        ), "a registered device offers an explicit add-another action")
        assert(BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: true,
            isExplicitDiscoveryActive: false,
            pairingCompletedDuringPresentation: false
        ), "an interrupted owned discovery resumes after its sheet closes")
        assert(!BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: true,
            isExplicitDiscoveryActive: false,
            pairingCompletedDuringPresentation: true
        ), "successful pairing does not restart Nearby discovery")
        assert(!BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: false,
            isExplicitDiscoveryActive: false,
            pairingCompletedDuringPresentation: false
        ), "discovery waits for Bluetooth to become available")
        assert(!BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: true,
            isExplicitDiscoveryActive: true,
            pairingCompletedDuringPresentation: false
        ), "an already-active explicit scan is not restarted")
        assertEqual(
            BikeComputerSettingsDiscoveryLifecyclePolicy
                .sensorEnrollmentChanged(
                    isLooking: true,
                    shouldStartDiscovery: true,
                    ownsDiscoveryLifecycle: true
                ),
            BikeComputerSettingsDiscoveryTransition(
                ownsDiscoveryLifecycle: true,
                commands: [.suspendUnknownDiscovery]
            ),
            "sensor enrollment yields the scanner without losing ownership"
        )
        assertEqual(
            BikeComputerSettingsDiscoveryLifecyclePolicy
                .sensorEnrollmentChanged(
                    isLooking: false,
                    shouldStartDiscovery: true,
                    ownsDiscoveryLifecycle: true
                ),
            BikeComputerSettingsDiscoveryTransition(
                ownsDiscoveryLifecycle: true,
                commands: [.resumeUnknownDiscovery]
            ),
            "ending sensor enrollment resumes an already-owned request"
        )
        assertEqual(
            BikeComputerSettingsDiscoveryLifecyclePolicy
                .screenDisappeared(ownsDiscoveryLifecycle: true),
            BikeComputerSettingsDiscoveryTransition(
                ownsDiscoveryLifecycle: false,
                commands: [
                    .cancelOwnedDiscovery,
                    .resumeUnknownDiscovery
                ]
            ),
            "leaving Settings cancels its request before releasing suspension"
        )
        assertEqual(
            BikeComputerSettingsPresentationPolicy.title(
                knownDeviceCount: 0,
                isExplicitBikeComputerSetup: false
            ),
            "Connect your Bicino",
            "empty settings presents the bike-computer setup title"
        )
        assertEqual(
            BikeComputerSettingsPresentationPolicy.settingsLinkTitle(
                knownDeviceCount: 0
            ),
            "Connect your Bicino!",
            "empty settings presents a clear add-device action"
        )
        assertEqual(
            BikeComputerSettingsPresentationPolicy.settingsLinkTitle(
                knownDeviceCount: 1
            ),
            "My Bike Computer",
            "registered settings keeps the existing singular title"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldPromoteSettingsLink(
                knownDeviceCount: 0
            ),
            "the add-device action is promoted only for an empty registry"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy.shouldPromoteSettingsLink(
                knownDeviceCount: 1
            ),
            "a registered bike computer keeps the settings link in its usual position"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy.shouldShowDeviceScreens(
                knownDeviceCount: 0
            ),
            "an empty registry replaces unavailable device screens"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldShowDeviceScreens(
                knownDeviceCount: 1
            ),
            "a registered bike computer keeps device screen settings"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy.shouldShowSensorManagement(
                hasEverConnectedBikeComputer: false,
                sensorProfileCount: 0
            ),
            "first-time Bicino setup stays focused on connecting the device"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldShowSensorManagement(
                hasEverConnectedBikeComputer: true,
                sensorProfileCount: 0
            ),
            "sensor setup remains available after a Bicino was connected"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldShowSensorManagement(
                hasEverConnectedBikeComputer: false,
                sensorProfileCount: 1
            ),
            "an existing sensor profile preserves sensor management during migration"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldShowSensorManagement(
                hasEverConnectedBikeComputer: false,
                sensorProfileCount: 0,
                isExplicitSensorSetup: true
            ),
            "an explicit sensor prompt remains actionable before Bicino setup"
        )
        assert(
            BikeComputerOnboardingPreferencePolicy.prefersIPhoneOnly(
                storedPreference: true,
                knownDeviceCount: 0
            ),
            "skipping setup keeps automatic discovery disabled without a Bicino"
        )
        assert(
            !BikeComputerOnboardingPreferencePolicy.prefersIPhoneOnly(
                storedPreference: true,
                knownDeviceCount: 1
            ),
            "successfully adding a Bicino clears the earlier skip preference"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy.shouldStartDiscovery(
                knownDeviceCount: 0,
                isExplicitBikeComputerSetup: false,
                isSensorLooking: false,
                hasSensorCandidates: false
            ),
            "combined settings does not start unrelated bike discovery"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldShowConnectAction(
                knownDeviceCount: 0,
                isExplicitBikeComputerSetup: false
            ),
            "combined settings offers explicit bike setup"
        )
        assert(
            BikeComputerSettingsPresentationPolicy.shouldStartDiscovery(
                knownDeviceCount: 0,
                isExplicitBikeComputerSetup: true,
                isSensorLooking: false,
                hasSensorCandidates: false
            ),
            "explicit bike-computer setup still starts discovery"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy.shouldStartDiscovery(
                knownDeviceCount: 0,
                isExplicitBikeComputerSetup: true,
                isSensorLooking: true,
                hasSensorCandidates: false
            ),
            "sensor enrollment takes priority over bike discovery"
        )
        assert(BLEPendingScanPolicy.accepts(
            discoveredIdentifier: peripheralID,
            pendingIdentifier: peripheralID
        ), "fallback scanning accepts only the selected Bike Computer")
        assert(!BLEPendingScanPolicy.accepts(
            discoveredIdentifier: otherPeripheralID,
            pendingIdentifier: peripheralID
        ), "fallback scanning ignores a different nearby Bike Computer")
        assertEqual(BLEPendingScanPolicy.timeout, 8,
                    "fallback scanning has a bounded retry window")

        var lifecycle = BLEOwnershipLifecycle()
        lifecycle.beginDiscovery()
        assertEqual(lifecycle.phase, .discovering,
                    "opening Bike Computers begins Nearby discovery")
        assert(lifecycle.beginPairing(
            candidateIdentifier: otherPeripheralID,
            connectedIdentifier: peripheralID
        ), "selecting another Bike Computer requests a connected-device handoff")
        assertEqual(lifecycle.phase, .pairing(otherPeripheralID),
                    "Continue, not the naming screen, begins pairing")
        assert(lifecycle.markComparisonReady(for: otherPeripheralID),
               "the selected Bike Computer can advance to code comparison")
        assert(lifecycle.beginConfirmation(for: otherPeripheralID),
               "the physical matching-code confirmation submits automatically")
        assert(!lifecycle.beginConfirmation(for: otherPeripheralID),
               "an automatic pairing confirmation cannot be submitted twice")
        let handoffCancellation = lifecycle.cancel(
            connectedIdentifier: peripheralID
        )
        assertEqual(handoffCancellation.pairingPeripheralIdentifier, otherPeripheralID,
                    "cancel clears the selected handoff target")
        assert(!handoffCancellation.shouldDisconnectPairingPeripheral,
               "cancel preserves the already-connected Bike Computer")
        assertEqual(lifecycle.phase, .discovering,
                    "cancel returns to Nearby discovery")

        assert(lifecycle.beginPairing(
            candidateIdentifier: otherPeripheralID,
            connectedIdentifier: nil
        ) == false, "pairing without a current connection needs no handoff")
        let candidateCancellation = lifecycle.cancel(
            connectedIdentifier: otherPeripheralID
        )
        assert(candidateCancellation.shouldDisconnectPairingPeripheral,
               "cancel disconnects an actively connected candidate")
        assert(lifecycle.endDiscovery(resumeAutoReconnect: true),
               "leaving Bike Computers resumes trusted-device reconnect")
        assertEqual(lifecycle.phase, .idle,
                    "leaving Bike Computers closes the discovery lifecycle")
        lifecycle.beginDiscovery()
        lifecycle.interrupt()
        assertEqual(lifecycle.phase, .idle,
                    "Bluetooth interruption clears the ownership lifecycle")
        lifecycle.beginDiscovery()
        lifecycle.complete()
        assertEqual(lifecycle.phase, .idle,
                    "successful ownership completion clears the lifecycle")

        let staleDevice = KnownBikeComputerDevice(
            deviceID: String(repeating: "4", count: 24) + "00004f7b",
            peripheralIdentifier: peripheralID,
            name: "BikeComputer",
            lastConnectedAt: .distantPast,
            isLegacy: false
        )
        let differentPeripheralDevice = KnownBikeComputerDevice(
            deviceID: String(repeating: "5", count: 24) + "00005555",
            peripheralIdentifier: UUID(),
            name: "Cargo bike",
            lastConnectedAt: .distantPast,
            isLegacy: false
        )
        assertEqual(
            BLEIdentityObservationPolicy.conflictingDeviceIDs(
                knownDevices: [staleDevice, differentPeripheralDevice],
                peripheralIdentifier: peripheralID,
                observedDeviceID: deviceID.ownershipHex
            ),
            [staleDevice.deviceID],
            "a changed stable identity marks only the saved alias for the same BLE peripheral"
        )
        assertEqual(
            BLEIdentityObservationPolicy.conflictingDeviceIDs(
                knownDevices: [staleDevice],
                peripheralIdentifier: peripheralID,
                observedDeviceID: staleDevice.deviceID
            ),
            [],
            "an unchanged stable identity remains current"
        )

        assertEqual(DeviceOwnershipProtocol.normalizedName("   "), "My bike", "empty names use the privacy-safe default")
        assertEqual(DeviceOwnershipProtocol.normalizedName("Road|Bike"), "RoadBike", "names remove protocol delimiters")
        assert(DeviceOwnershipProtocol.normalizedName(String(repeating: "🚲", count: 10)).utf8.count <= 24,
               "device names are truncated on Character boundaries to the firmware limit")
        assertEqual(
            DeviceOwnershipProtocol.resolvedInfoName(
                reportedName: "Spoofed name",
                isClaimed: true,
                existingName: "Cargo bike",
                peripheralName: "BikeComputer"
            ),
            "Cargo bike",
            "a compact claimed receipt does not erase the current owner's saved name"
        )

        let clientNonce = "00112233445566778899aabbccddeeff"
        let serverNonceA = "102132435465768798a9bacbdcedfe0f"
        let serverNonceB = "ffeeddccbbaa99887766554433221100"
        let serverMessageA = DeviceOwnerAuthenticator.serverMessage(
            deviceID: deviceID.ownershipHex,
            ownerID: ownerID,
            clientNonce: clientNonce,
            serverNonce: serverNonceA
        )
        let serverMessageB = DeviceOwnerAuthenticator.serverMessage(
            deviceID: deviceID.ownershipHex,
            ownerID: ownerID,
            clientNonce: clientNonce,
            serverNonce: serverNonceB
        )
        assert(
            DeviceOwnerAuthenticator.proof(key: material.ownerKey, message: serverMessageA) !=
                DeviceOwnerAuthenticator.proof(key: material.ownerKey, message: serverMessageB),
            "device-generated nonces make captured owner challenges non-replayable"
        )
        assertEqual(BLEReconnectBackoff.delay(attempt: 0), 1, "reconnect starts promptly")
        assertEqual(BLEReconnectBackoff.delay(attempt: 100), 60, "reconnect continues indefinitely at the cap")
        assert(BLEConnectionPersistence.shouldCancelTimedOutConnection(isPairing: true),
               "interactive pairing connections remain time-bounded")
        assert(!BLEConnectionPersistence.shouldCancelTimedOutConnection(isPairing: false),
               "trusted reconnects remain pending for CoreBluetooth background wake")
        var pendingHandoff: UUID? = peripheralID
        assertEqual(
            BLEPendingHandoffPolicy.consume(&pendingHandoff),
            peripheralID,
            "a terminal connection failure consumes its pending successor"
        )
        assertEqual(pendingHandoff, nil, "consumed handoffs cannot fire again later")
        assert(BLEDeviceOperationPolicy.canStartPairing(operationDeviceID: nil),
               "pairing can start when no device mutation is pending")
        assert(!BLEDeviceOperationPolicy.canStartPairing(operationDeviceID: material.deviceID),
               "pairing cannot interrupt a rename or deregistration")
        assertEqual(
            BikeComputerRemovalPolicy.action(isConnected: true, isLegacy: false),
            .deregister,
            "connected ownership-capable devices deregister both sides"
        )
        assertEqual(
            BikeComputerRemovalPolicy.action(isConnected: true, isLegacy: true),
            .forget,
            "connected legacy devices remain locally removable"
        )
        assertEqual(
            BikeComputerRemovalPolicy.action(isConnected: false, isLegacy: false),
            .forget,
            "disconnected devices expose local Forget"
        )
        assert(!BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheralID,
            currentIdentifier: peripheralID,
            forgottenIdentifiers: [peripheralID]
        ), "late callbacks cannot recreate a locally forgotten device")
        assert(BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheralID,
            currentIdentifier: peripheralID,
            forgottenIdentifiers: []
        ), "ordinary current-device callbacks remain enabled")
        assert(!BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheralID,
            currentIdentifier: UUID(),
            forgottenIdentifiers: []
        ), "late callbacks from a replaced peripheral cannot mutate the current session")
        assert(BLELocalForgetPolicy.shouldStopScanning(
            wasActive: true,
            hadPendingTransport: false,
            hasSuccessor: false
        ), "forgetting the sole active device stops fallback scanning")
        assert(!BLELocalForgetPolicy.shouldStopScanning(
            wasActive: true,
            hadPendingTransport: true,
            hasSuccessor: true
        ), "forgetting with a successor keeps reconnection available")
        assert(!BLENavigationNotificationPolicy.accepts(
            isAuthenticated: false,
            isLegacyDevice: false,
            hasProtectedSession: false,
            isProtectedFrame: false
        ), "pre-authentication navigation notifications are rejected")
        assert(!BLENavigationNotificationPolicy.accepts(
            isAuthenticated: true,
            isLegacyDevice: false,
            hasProtectedSession: true,
            isProtectedFrame: false
        ), "v2 sessions reject plaintext navigation notifications")
        assert(BLENavigationNotificationPolicy.accepts(
            isAuthenticated: true,
            isLegacyDevice: false,
            hasProtectedSession: true,
            isProtectedFrame: true
        ), "v2 sessions admit protected navigation notifications for AEAD verification")
        assert(BLENavigationNotificationPolicy.accepts(
            isAuthenticated: true,
            isLegacyDevice: true,
            hasProtectedSession: false,
            isProtectedFrame: false
        ), "authenticated legacy sessions retain plaintext notifications")
        assert(!BLENavigationNotificationPolicy.accepts(
            isAuthenticated: true,
            isLegacyDevice: false,
            hasProtectedSession: false,
            isProtectedFrame: false
        ), "v2 sessions fail closed if their protected transport is missing")

        let restoredA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let restoredB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let restoredMissing = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        assertEqual(
            BLERestorationPolicy.selectedIdentifier(
                from: [restoredA, restoredB],
                trustedIdentifier: restoredB
            ),
            restoredB,
            "restoration selects the trusted current peripheral"
        )
        assertEqual(
            BLERestorationPolicy.selectedIdentifier(
                from: [restoredA, restoredB],
                trustedIdentifier: restoredMissing
            ),
            nil,
            "restoration rejects stale peripherals when the trusted device is absent"
        )
        assertEqual(
            BLERestorationPolicy.selectedIdentifier(
                from: [restoredA, restoredB],
                trustedIdentifier: nil
            ),
            nil,
            "restoration never trusts an arbitrary peripheral without a saved current device"
        )
        assertEqual(
            BLERestorationPolicy.selectedIdentifier(
                from: [restoredA, restoredB],
                trustedIdentifier: restoredB,
                isConnectionExclusiveOperationActive: true
            ),
            nil,
            "restoration cannot bypass an active Watch-direct BLE handoff"
        )
        assertEqual(
            BLERestorationPolicy.identifiersToCancel(
                from: [restoredA, restoredB],
                keeping: restoredB
            ),
            [restoredA],
            "restoration cancels every non-current peripheral"
        )

        let goldenOwnerKey = Data((0..<32).map(UInt8.init))
        let goldenDeviceID = "00112233445566778899aabbccddeeff"
        let goldenClientNonce = "102132435465768798a9babbdcddedef"
        let goldenServerNonce = "ffeeddccbbaa99887766554433221100"
        let revocationProof = DeviceOwnerAuthenticator.proof(
            key: goldenOwnerKey,
            message: DeviceOwnerAuthenticator.revocationMessage(
                deviceID: goldenDeviceID,
                ownerID: ownerID,
                nonce: goldenServerNonce
            )
        )
        assert(DeviceOwnerAuthenticator.isValidRevocationReceipt(
            suppliedProof: revocationProof,
            key: goldenOwnerKey,
            deviceID: goldenDeviceID,
            ownerID: ownerID,
            nonce: goldenServerNonce
        ), "a signed deregistration receipt is accepted")
        let invalidRevocationProof = String(revocationProof.dropLast()) +
            (revocationProof.last == "0" ? "1" : "0")
        assert(!DeviceOwnerAuthenticator.isValidRevocationReceipt(
            suppliedProof: invalidRevocationProof,
            key: goldenOwnerKey,
            deviceID: goldenDeviceID,
            ownerID: ownerID,
            nonce: goldenServerNonce
        ), "a forged deregistration receipt is rejected")
        assert(!DeviceOwnerAuthenticator.isValidRevocationReceipt(
            suppliedProof: revocationProof,
            key: Data(repeating: 0x5A, count: DeviceOwnershipProtocol.ownerKeyLength),
            deviceID: goldenDeviceID,
            ownerID: ownerID,
            nonce: goldenServerNonce
        ), "a retained prior-owner receipt cannot delete the current owner's credential")
        let protectedSession = AuthenticatedBLEWriteSession(
            ownerKey: goldenOwnerKey,
            deviceID: goldenDeviceID,
            clientNonce: goldenClientNonce,
            serverNonce: goldenServerNonce
        )
        let goldenWriteFrame = Data(ownershipHex:
            "533200000001c486d6a2464da1600aab2af46a3ae0e00442af910dcdc23c8164d0336842cfaa426b31")!
        assertEqual(
            protectedSession.frame(
                payload: Data("NAME|4d792062696b65".utf8),
                channel: .auth
            ),
            goldenWriteFrame,
            "AES-GCM app write frame matches the shared mbedTLS vector"
        )
        assertEqual(
            protectedSession.frame(payload: Data(), channel: .route),
            Data(ownershipHex: "533200000001c981669fdeb1b029019459478ef19ff6"),
            "empty protected route payload has a valid authenticated frame"
        )
        let workoutWriteSession = AuthenticatedBLEWriteSession(
            ownerKey: goldenOwnerKey,
            deviceID: goldenDeviceID,
            clientNonce: goldenClientNonce,
            serverNonce: goldenServerNonce
        )
        assertEqual(
            workoutWriteSession.frame(
                payload: Data(ownershipHex: "0102030405060708090a0b0c0d0e0f10")!,
                channel: .workout
            ),
            Data(ownershipHex:
                "53320000000127d330a9033a32ec8bf92a85e20f859fa7efe9559f559083f8f9e48720130a16"),
            "native workout write matches the shared channel-six AES-GCM vector"
        )
        let goldenNotifyFrame = Data(ownershipHex:
            "523200000001f19f6c8cd9263269e34a54aa910f37738270d42cb7d8632c8f0e20bfa6a4588d369304ab9662")!
        assertEqual(
            protectedSession.notificationPayload(
                from: goldenNotifyFrame,
                channel: .auth
            ),
            Data("NAME_OK|4d792062696b65".utf8),
            "AES-GCM device notification matches the shared mbedTLS vector"
        )
        assertEqual(
            protectedSession.notificationPayload(
                from: goldenNotifyFrame,
                channel: .auth
            ),
            nil,
            "protected notification replay is rejected"
        )
        var tamperedNotification = goldenNotifyFrame
        tamperedNotification[tamperedNotification.index(before: tamperedNotification.endIndex)] ^= 1
        let tamperSession = AuthenticatedBLEWriteSession(
            ownerKey: goldenOwnerKey,
            deviceID: goldenDeviceID,
            clientNonce: goldenClientNonce,
            serverNonce: goldenServerNonce
        )
        assertEqual(
            tamperSession.notificationPayload(
                from: tamperedNotification,
                channel: .auth
            ),
            nil,
            "tampered protected notification is rejected"
        )
        let navigationNotifySession = AuthenticatedBLEWriteSession(
            ownerKey: goldenOwnerKey,
            deviceID: goldenDeviceID,
            clientNonce: goldenClientNonce,
            serverNonce: goldenServerNonce
        )
        let destinationRequest = Data([0x44, 0x52, 0x45, 0x51,
                                       1, 0, 0, 0, 2, 0])
        assertEqual(
            navigationNotifySession.notificationPayload(
                from: Data(ownershipHex:
                    "523200000001a0d24a5355c7de1683c4a586dd2fb19a8c19b6a6c0afe3b4f62e")!,
                channel: .navigation
            ),
            destinationRequest,
            "device-originated navigation action matches the protected vector"
        )
        assertEqual(
            navigationNotifySession.notificationPayload(
                from: destinationRequest,
                channel: .navigation
            ),
            nil,
            "plaintext device actions are rejected once a secure session exists"
        )

        let suiteName = "DeviceOwnershipProtocolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryDeviceCredentialStore()
        let registry = BikeComputerDeviceRegistry(defaults: defaults, credentialStore: credentials)
        assert(!registry.hasEverConnectedBikeComputer,
               "a fresh registry has not completed Bicino setup")
        let generatedOwnerID = registry.installationOwnerID()
        assertEqual(generatedOwnerID?.count, 16, "registry creates a 128-bit installation owner ID")
        assertEqual(registry.installationOwnerID(), generatedOwnerID, "installation owner ID is stable")
        assert(registry.saveOwnerKey(material.ownerKey, deviceID: material.deviceID), "registry stores device owner key")

        let first = KnownBikeComputerDevice(
            deviceID: material.deviceID,
            peripheralIdentifier: peripheralID,
            name: "Chris’ bike",
            lastConnectedAt: Date(timeIntervalSince1970: 10),
            isLegacy: false
        )
        let second = KnownBikeComputerDevice(
            deviceID: String(repeating: "a", count: 32),
            peripheralIdentifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Cargo bike",
            lastConnectedAt: Date(timeIntervalSince1970: 20),
            isLegacy: false
        )
        let legacyAlias = KnownBikeComputerDevice(
            deviceID: "legacy:\(peripheralID.uuidString.lowercased())",
            peripheralIdentifier: peripheralID,
            name: "Old identity",
            lastConnectedAt: Date(timeIntervalSince1970: 5),
            isLegacy: true
        )
        registry.upsert(legacyAlias, makeActive: true)
        registry.upsert(first)
        registry.upsert(second)
        assert(registry.hasEverConnectedBikeComputer,
               "registering a Bicino records the durable setup milestone")
        assertEqual(registry.devices.count, 2, "registry supports multiple Bike Computers")
        assert(!registry.devices.contains(where: { $0.isLegacy && $0.peripheralIdentifier == peripheralID }),
               "a stable v2 identity replaces its legacy peripheral alias")
        assertEqual(registry.activeDeviceID, first.deviceID, "adding another device does not silently switch the current device")
        assertEqual(registry.ownerKey(deviceID: first.deviceID), material.ownerKey, "owner key can be retrieved for authentication")
        let secondKey = Data(repeating: 0xA5, count: DeviceOwnershipProtocol.ownerKeyLength)
        assert(registry.saveOwnerKey(secondKey, deviceID: second.deviceID), "each device stores an independent owner credential")
        assertEqual(registry.ownerKey(deviceID: second.deviceID), secondKey, "second device credential is independently addressable")
        let replacementKey = Data(repeating: 0x5A, count: DeviceOwnershipProtocol.ownerKeyLength)
        assert(registry.saveProvisionalOwnerKey(replacementKey, deviceID: first.deviceID),
               "replacement pairing stores a separate provisional credential")
        registry.markProvisionalOwnerKeyConfirmed(deviceID: first.deviceID)
        assert(!registry.hasConfirmedReplacementCredential(deviceID: first.deviceID),
               "confirmation alone does not authorize overwriting a prior credential")
        assert(!registry.promoteProvisionalOwnerKey(deviceID: first.deviceID),
               "ordinary promotion cannot overwrite a different existing credential")
        assertEqual(registry.ownerKey(deviceID: first.deviceID), material.ownerKey,
                    "rejected promotion preserves the existing credential")
        registry.authorizeProvisionalCredentialReplacement(deviceID: first.deviceID)
        assert(registry.hasConfirmedReplacementCredential(deviceID: first.deviceID),
               "confirmed authorized replacement recovery takes priority over an old receipt")
        assert(registry.promoteProvisionalOwnerKey(
            deviceID: first.deviceID,
            allowReplacingExisting: true
        ), "explicit recovery authorization can replace a stale credential")
        assertEqual(registry.ownerKey(deviceID: first.deviceID), replacementKey,
                    "authorized recovery promotes the verified provisional key")
        assert(!DeviceOwnershipFlowPolicy.allowsLegacyFallback(knownDevice: first, pairingCandidate: nil),
               "known v2 devices never downgrade after an INFO timeout")
        assert(DeviceOwnershipFlowPolicy.allowsLegacyFallback(knownDevice: legacyAlias, pairingCandidate: nil),
               "known legacy firmware can use the migration handshake")
        assert(!DeviceOwnershipFlowPolicy.allowsLegacyFallback(knownDevice: nil, pairingCandidate: discovered),
               "advertised v2 pairing candidates never downgrade")
        assert(!DeviceOwnershipFlowPolicy.allowsLegacyFallback(knownDevice: nil, pairingCandidate: nil),
               "an unknown first-time Add never falls back to the shared legacy credential")
        assert(registry.remove(deviceID: first.deviceID),
               "credential removal succeeds before the visible registry entry is deleted")
        assertEqual(registry.activeDeviceID, second.deviceID, "removing the current device selects the remaining device")
        assertEqual(registry.ownerKey(deviceID: first.deviceID), nil, "deregistering deletes the owner key")
        assertEqual(registry.ownerKey(deviceID: second.deviceID), secondKey, "deregistering one device preserves another device credential")
        assert(registry.remove(deviceID: second.deviceID),
               "the final registered device can be removed")
        assert(registry.devices.isEmpty,
               "removing the final device empties the current registry")
        assert(registry.hasEverConnectedBikeComputer,
               "removing every Bicino preserves the setup milestone")
        let reloadedRegistry = BikeComputerDeviceRegistry(
            defaults: defaults,
            credentialStore: credentials
        )
        assert(reloadedRegistry.hasEverConnectedBikeComputer,
               "the Bicino setup milestone survives registry reload")

        let migrationSuiteName =
            "DeviceOwnershipMilestoneMigrationTests.\(UUID().uuidString)"
        let migrationDefaults = UserDefaults(suiteName: migrationSuiteName)!
        defer {
            migrationDefaults.removePersistentDomain(
                forName: migrationSuiteName
            )
        }
        migrationDefaults.set(
            try! JSONEncoder().encode([first]),
            forKey: "ble.knownDevices.v2"
        )
        let migratedRegistry = BikeComputerDeviceRegistry(
            defaults: migrationDefaults,
            credentialStore: InMemoryDeviceCredentialStore()
        )
        assert(migratedRegistry.hasEverConnectedBikeComputer,
               "an existing registered Bicino migrates the setup milestone")

        let failureSuiteName = "DeviceOwnershipRemovalFailureTests.\(UUID().uuidString)"
        let failureDefaults = UserDefaults(suiteName: failureSuiteName)!
        defer { failureDefaults.removePersistentDomain(forName: failureSuiteName) }
        let failingCredentials = InMemoryDeviceCredentialStore()
        let failureRegistry = BikeComputerDeviceRegistry(
            defaults: failureDefaults,
            credentialStore: failingCredentials
        )
        failureRegistry.upsert(first, makeActive: true)
        assert(failureRegistry.saveOwnerKey(material.ownerKey, deviceID: first.deviceID),
               "removal regression fixture stores an owner key")
        failingCredentials.shouldFailRemoval = true
        assert(!failureRegistry.remove(deviceID: first.deviceID),
               "credential deletion failure is surfaced")
        assertEqual(failureRegistry.devices, [first],
                    "credential deletion failure keeps the device visible")
        assertEqual(failureRegistry.ownerKey(deviceID: first.deviceID), material.ownerKey,
                    "credential deletion failure preserves the owner key")
    }

    static func testBLEScanLifecyclePolicy() {
        let trusted = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let selected = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        func context(
            active: Bool = true,
            poweredOn: Bool = true,
            hasSession: Bool = false,
            knownCount: Int = 0,
            trustedIdentifier: UUID? = nil,
            reconnect: Bool = false,
            explicit: Bool = false,
            selectedIdentifier: UUID? = nil,
            suppressed: Bool = false,
            exclusive: Bool = false
        ) -> BLEScanContext {
            BLEScanContext(
                isApplicationActive: active,
                isBluetoothPoweredOn: poweredOn,
                hasActiveBLESession: hasSession,
                knownDeviceCount: knownCount,
                trustedPeripheralIdentifier: trustedIdentifier,
                shouldReconnectTrustedPeripheral: reconnect,
                explicitDiscoveryRequested: explicit,
                selectedPeripheralIdentifier: selectedIdentifier,
                isUnknownDiscoverySuppressed: suppressed,
                isExclusiveOperationActive: exclusive
            )
        }

        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context()),
            .opportunisticDiscovery,
            "an active empty registry starts opportunistic discovery"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(active: false)),
            .none,
            "an empty registry never discovers unknown devices in background"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                active: false,
                knownCount: 1,
                trustedIdentifier: trusted,
                reconnect: true
            )),
            .trustedReconnect(trusted),
            "trusted reconnect remains eligible in background"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                knownCount: 1,
                trustedIdentifier: trusted,
                reconnect: false
            )),
            .none,
            "a non-empty registry does not fall back to unknown discovery"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(explicit: true)),
            .explicitDiscovery,
            "a foreground user-owned setup session starts explicit discovery"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                knownCount: 1,
                trustedIdentifier: trusted,
                reconnect: true,
                explicit: true
            )),
            .explicitDiscovery,
            "explicit foreground discovery outranks trusted reconnect"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                knownCount: 1,
                trustedIdentifier: trusted,
                reconnect: true,
                explicit: true,
                selectedIdentifier: selected
            )),
            .selectedPeripheral(selected),
            "a selected-device handoff outranks every idle scan purpose"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                hasSession: true,
                explicit: true,
                selectedIdentifier: selected
            )),
            .none,
            "connecting, authenticating, restored, and connected sessions prohibit scanning"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(
                knownCount: 1,
                trustedIdentifier: trusted,
                reconnect: true,
                exclusive: true
            )),
            .none,
            "Watch-direct and administration handoffs prohibit scanning"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(suppressed: true)),
            .none,
            "dismissing automatic setup suppresses discovery for the activation"
        )
        assertEqual(
            BLEScanLifecyclePolicy.purpose(for: context(poweredOn: false)),
            .none,
            "Bluetooth-off state prohibits every scan"
        )
        assert(
            !BLEScanPurpose.trustedReconnect(trusted).logDescription
                .contains(trusted.uuidString),
            "scan diagnostics do not expose a trusted peripheral identifier"
        )
        assert(
            !BLEScanPurpose.selectedPeripheral(selected).logDescription
                .contains(selected.uuidString),
            "scan diagnostics do not expose a selected peripheral identifier"
        )

        let scanStoppedAt = Date(timeIntervalSince1970: 50)
        let callbackDrainDelay = BLEScanCallbackDrainPolicy.delay(
            after: scanStoppedAt,
            now: scanStoppedAt
        )
        assert(
            callbackDrainDelay > 0 &&
                callbackDrainDelay <= BLEScanCallbackDrainPolicy.interval,
            "an unknown-device scan waits for callbacks from the prior scan"
        )
        assertEqual(
            BLEScanCallbackDrainPolicy.delay(
                after: scanStoppedAt,
                now: scanStoppedAt.addingTimeInterval(
                    BLEScanCallbackDrainPolicy.interval
                )
            ),
            0,
            "the callback-drain boundary adds no delay after its interval"
        )
        assertEqual(
            BLEScanCallbackDrainPolicy.delay(after: nil, now: scanStoppedAt),
            0,
            "the first scan does not wait for a nonexistent predecessor"
        )
        var observationGate = BLEUnknownScanObservationGate()
        observationGate.begin(generation: 7)
        assert(
            !observationGate.acceptsRepeatedObservation(
                peripheralIdentifier: selected,
                generation: 7
            ),
            "one callback cannot prove that a device belongs to the new scan"
        )
        assert(
            observationGate.acceptsRepeatedObservation(
                peripheralIdentifier: selected,
                generation: 7
            ),
            "a repeated callback admits a device observed during the active scan"
        )
        observationGate.end()
        assert(
            !observationGate.acceptsRepeatedObservation(
                peripheralIdentifier: selected,
                generation: 7
            ),
            "a stopped scan rejects observations from its former generation"
        )
        observationGate.begin(generation: 8)
        assert(
            !observationGate.acceptsRepeatedObservation(
                peripheralIdentifier: selected,
                generation: 8
            ),
            "a callback delayed into a replacement scan is quarantined as its first observation"
        )
        let now = Date(timeIntervalSince1970: 100)
        let candidate = DiscoveredBikeComputerDevice(
            peripheralIdentifier: selected,
            advertisedName: "Bicino",
            shortIdentifier: "158D",
            identitySuffix: "FA85158D",
            isClaimed: false,
            rssi: -45,
            lastSeenAt: now
        )
        let observation = BLEDiscoveryObservation(
            device: candidate,
            generation: 7
        )
        assert(BLEOpportunisticCandidatePolicy.isEligible(
            observation,
            activeGeneration: 7,
            knownDevices: [],
            serviceMatched: true,
            now: now
        ), "a fresh unclaimed v2 observation is eligible")
        var rejected = candidate
        rejected.isClaimed = true
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            BLEDiscoveryObservation(device: rejected, generation: 7),
            activeGeneration: 7,
            knownDevices: [],
            serviceMatched: true,
            now: now
        ), "claimed devices never trigger automatic setup")
        rejected = candidate
        rejected.isClaimed = nil
        rejected.identitySuffix = nil
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            BLEDiscoveryObservation(device: rejected, generation: 7),
            activeGeneration: 7,
            knownDevices: [],
            serviceMatched: true,
            now: now
        ), "legacy or unknown ownership advertisements are ineligible")
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            observation,
            activeGeneration: 8,
            knownDevices: [],
            serviceMatched: true,
            now: now
        ), "a stopped discovery generation rejects delayed callbacks")
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            observation,
            activeGeneration: 7,
            knownDevices: [],
            serviceMatched: false,
            now: now
        ), "automatic setup requires the Bicino service-filtered scan")
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            observation,
            activeGeneration: 7,
            knownDevices: [],
            serviceMatched: true,
            now: now.addingTimeInterval(7)
        ), "stale observations are ineligible")
        let known = KnownBikeComputerDevice(
            deviceID: "00112233445566778899aabbfa85158d",
            peripheralIdentifier: trusted,
            name: "Known Bicino",
            lastConnectedAt: now,
            isLegacy: false
        )
        assert(!BLEOpportunisticCandidatePolicy.isEligible(
            observation,
            activeGeneration: 7,
            knownDevices: [known],
            serviceMatched: true,
            now: now
        ), "any registered Bicino disables automatic unknown discovery")
        let weaker = DiscoveredBikeComputerDevice(
            peripheralIdentifier: UUID(
                uuidString: "99999999-2222-3333-4444-555555555555"
            )!,
            advertisedName: "Bicino",
            shortIdentifier: "2222",
            identitySuffix: "FA852222",
            isClaimed: false,
            rssi: -70,
            lastSeenAt: now
        )
        assertEqual(
            BLEOpportunisticCandidatePolicy.strongest(
                from: [
                    BLEDiscoveryObservation(device: weaker, generation: 7),
                    observation
                ],
                activeGeneration: 7,
                knownDevices: [],
                now: now
            )?.device.peripheralIdentifier,
            selected,
            "the bounded window selects the strongest eligible candidate"
        )
        var unavailableSignal = candidate
        unavailableSignal.rssi = 127
        assertEqual(
            BLEDiscoverySignalPolicy.description(for: 127),
            "Unavailable",
            "Core Bluetooth's RSSI sentinel is not displayed as a real dBm value"
        )
        let initialNearbyObservation = Date(timeIntervalSince1970: 1_000)
        var nearbyOrderStabilizer = BLEExplicitDiscoveryOrderStabilizer()
        var stableNearbyDevices: [DiscoveredBikeComputerDevice] = []
        var initiallyWeaker = weaker
        initiallyWeaker.lastSeenAt = initialNearbyObservation
        var initiallyStronger = candidate
        initiallyStronger.lastSeenAt =
            initialNearbyObservation.addingTimeInterval(0.1)
        nearbyOrderStabilizer.merge(
            initiallyWeaker,
            into: &stableNearbyDevices,
            now: initiallyWeaker.lastSeenAt
        )
        nearbyOrderStabilizer.merge(
            initiallyStronger,
            into: &stableNearbyDevices,
            now: initiallyStronger.lastSeenAt
        )
        assertEqual(
            stableNearbyDevices.map(\.peripheralIdentifier),
            [initiallyWeaker.peripheralIdentifier,
             initiallyStronger.peripheralIdentifier],
            "new Nearby rows append without displacing visible rows"
        )
        initiallyWeaker.rssi = -80
        initiallyWeaker.lastSeenAt =
            initialNearbyObservation.addingTimeInterval(1)
        nearbyOrderStabilizer.merge(
            initiallyWeaker,
            into: &stableNearbyDevices,
            now: initiallyWeaker.lastSeenAt
        )
        assertEqual(
            stableNearbyDevices.map(\.peripheralIdentifier),
            [initiallyWeaker.peripheralIdentifier,
             initiallyStronger.peripheralIdentifier],
            "RSSI updates preserve Nearby row order during the stability window"
        )
        initiallyStronger.lastSeenAt = initialNearbyObservation.addingTimeInterval(
            BLEExplicitDiscoveryOrderStabilizer.minimumReorderInterval
        )
        nearbyOrderStabilizer.merge(
            initiallyStronger,
            into: &stableNearbyDevices,
            now: initiallyStronger.lastSeenAt
        )
        assertEqual(
            stableNearbyDevices.map(\.peripheralIdentifier),
            [initiallyStronger.peripheralIdentifier,
             initiallyWeaker.peripheralIdentifier],
            "Nearby rows refresh by signal strength after five stable seconds"
        )
        assertEqual(
            BLEOpportunisticCandidatePolicy.strongest(
                from: [
                    BLEDiscoveryObservation(
                        device: unavailableSignal,
                        generation: 7
                    ),
                    BLEDiscoveryObservation(device: weaker, generation: 7)
                ],
                activeGeneration: 7,
                knownDevices: [],
                now: now
            )?.device.peripheralIdentifier,
            weaker.peripheralIdentifier,
            "an unavailable Core Bluetooth RSSI never outranks a valid signal"
        )

        assertEqual(
            BLEExplicitDiscoveryStartPolicy.action(
                hasActiveBLESession: false,
                isConnecting: false
            ),
            .start,
            "an idle explicit setup starts immediately"
        )
        assertEqual(
            BLEExplicitDiscoveryStartPolicy.action(
                hasActiveBLESession: true,
                isConnecting: false
            ),
            .confirmDisconnect,
            "a connected device requires confirmation before discovery"
        )
        assertEqual(
            BLEExplicitDiscoveryStartPolicy.action(
                hasActiveBLESession: true,
                isConnecting: true
            ),
            .cancelConnection,
            "a connection attempt exposes cancellation for add-another discovery"
        )
        assert(NearbyBicinoPresentationPolicy.shouldPresent(
            isApplicationActive: true,
            knownDeviceCount: 0,
            hasActiveBLESession: false,
            hasBlockingPresentation: false,
            isMapAreaSelectionActive: false,
            isSuppressed: false
        ), "an eligible candidate can use the centralized item-driven sheet")
        assert(!NearbyBicinoPresentationPolicy.shouldPresent(
            isApplicationActive: true,
            knownDeviceCount: 0,
            hasActiveBLESession: false,
            hasBlockingPresentation: true,
            isMapAreaSelectionActive: false,
            isSuppressed: false
        ), "automatic setup never stacks over another modal")
        assert(
            NearbyBicinoCandidateLifecyclePolicy.suppressesFurtherDiscovery(
                after: .dismissed
            ),
            "closing the nearby offer suppresses repeated prompts for the activation"
        )
        assert(
            !NearbyBicinoCandidateLifecyclePolicy.suppressesFurtherDiscovery(
                after: .expiredBeforePresentation
            ),
            "an offer blocked until expiry can be rediscovered later"
        )
        assertEqual(
            BikeComputerPairingErrorActionPolicy.action(
                hasRetainedNearbyCandidate: true
            ),
            .close,
            "a failed nearby connection closes instead of offering a broken retry"
        )
        assertEqual(
            BikeComputerPairingErrorActionPolicy.action(
                hasRetainedNearbyCandidate: false
            ),
            .retry,
            "explicit discovery retains its restartable retry action"
        )
        assert(
            BikeComputersMenuPolicy.shouldRestartOwnedDiscoveryOnForeground(
                isApplicationActive: true,
                ownsDiscoveryLifecycle: true,
                hasPresentedCandidate: false,
                isSensorEnrollmentActive: false
            ),
            "an open explicit setup resumes discovery on foreground entry"
        )
        assert(
            !BikeComputersMenuPolicy.shouldRestartOwnedDiscoveryOnForeground(
                isApplicationActive: true,
                ownsDiscoveryLifecycle: true,
                hasPresentedCandidate: true,
                isSensorEnrollmentActive: false
            ),
            "an explicit setup does not scan behind its selected candidate"
        )
        assert(
            !BikeComputersMenuPolicy.shouldRestartOwnedDiscoveryOnForeground(
                isApplicationActive: true,
                ownsDiscoveryLifecycle: true,
                hasPresentedCandidate: false,
                isSensorEnrollmentActive: true
            ),
            "sensor enrollment blocks foreground Bike Computer restarts"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy
                .shouldShowExplicitDiscoveryState(
                    scanPurpose: .opportunisticDiscovery
                ),
            "general Settings never renders an opportunistic scan as its owned list"
        )
        assert(
            BikeComputerSettingsPresentationPolicy
                .shouldShowConnectAction(
                    baseEligibility: true,
                    scanPurpose: .opportunisticDiscovery
                ),
            "general Settings keeps the explicit Connect action during opportunistic scanning"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy
                .shouldShowConnectAction(
                    baseEligibility: true,
                    scanPurpose: .explicitDiscovery
                ),
            "an active explicit scan replaces the Connect action with its owned results"
        )
        assert(
            !BikeComputerSettingsPresentationPolicy
                .shouldShowConnectAction(
                    baseEligibility: true,
                    scanPurpose: .none,
                    isExplicitDiscoveryPending: true
                ),
            "a Watch-gated explicit request does not expose a duplicate Connect action"
        )
        var stage = NearbyBicinoSetupStage.offer
        stage.advanceToPairing()
        assertEqual(stage, .pairing,
                    "Connect advances within the same sheet")
        assert(NearbyBicinoPresentationPolicy
            .shouldRetainCandidateDuringConnection(
                discoveryOrigin: .opportunistic,
                hasPendingPairingSession: true
            ), "the sealed Nearby item remains available through secure pairing")
        assert(!NearbyBicinoPresentationPolicy
            .shouldRetainCandidateDuringConnection(
                discoveryOrigin: .explicit,
                hasPendingPairingSession: true
            ), "explicit pairing does not retain an automatic-sheet candidate")
        assert(!NearbyBicinoPresentationPolicy
            .shouldRetainCandidateDuringConnection(
                discoveryOrigin: .opportunistic,
                hasPendingPairingSession: false
            ), "a finished automatic setup releases its sealed candidate")
        assertEqual(
            NearbyBicinoPresentationPolicy.routeID(
                peripheralIdentifier: selected
            ),
            NearbyBicinoPresentationPolicy.routeID(
                peripheralIdentifier: selected
            ),
            "the nearby modal route has stable item identity"
        )
    }

    @MainActor
    static func testBLEManagerDiscoveryLifecycleTransitions() {
        let manager = BLEManager()
        let driver = BLEScanDriverForTesting()
        manager.installScanDriverForTesting(driver)

        manager.setApplicationActive(true)
        assertEqual(
            manager.currentScanPurpose,
            .opportunisticDiscovery,
            "the real manager starts first-device discovery on foreground entry"
        )
        assertEqual(driver.starts.count, 1,
                    "foreground entry starts exactly one physical scan")
        assert(driver.starts[0].allowsDuplicates,
               "unknown-device discovery requests duplicate observations")

        let phoneOnlyManager = BLEManager()
        let phoneOnlyDriver = BLEScanDriverForTesting()
        phoneOnlyManager.installScanDriverForTesting(phoneOnlyDriver)
        phoneOnlyManager.setOpportunisticDiscoveryEnabled(false)
        phoneOnlyManager.setApplicationActive(true)
        assertEqual(
            phoneOnlyManager.currentScanPurpose,
            .none,
            "the iPhone-only onboarding choice suppresses automatic device discovery"
        )
        phoneOnlyManager.startDeviceDiscovery()
        assertEqual(
            phoneOnlyManager.currentScanPurpose,
            .explicitDiscovery,
            "the iPhone-only choice still permits user-initiated device setup"
        )

        manager.setUnknownDeviceDiscoverySuspended(true)
        assertEqual(
            manager.currentScanPurpose,
            .none,
            "sensor enrollment suspends opportunistic Bike Computer discovery"
        )
        manager.setUnknownDeviceDiscoverySuspended(false)
        assert(waitForMainLoop(timeout: 1) {
            manager.currentScanPurpose == .opportunisticDiscovery &&
                driver.starts.count == 2
        }, "ending sensor enrollment restores eligible opportunistic discovery")

        manager.startDeviceDiscovery()
        assertEqual(
            manager.currentScanPurpose,
            .explicitDiscovery,
            "the real manager transfers ownership from opportunistic to explicit discovery"
        )
        assert(manager.isDiscoveringDevices,
               "the explicit transition remains visible while callbacks drain")
        assertEqual(driver.stopCount, 2,
                    "the old physical scan stops before explicit discovery")
        assert(waitForMainLoop(timeout: 1) { driver.starts.count == 3 },
               "explicit discovery starts after the callback-drain boundary")

        manager.setUnknownDeviceDiscoverySuspended(true)
        assertEqual(
            manager.currentScanPurpose,
            .none,
            "sensor enrollment suspends the owned explicit Bike Computer scan"
        )
        assert(!driver.isScanning,
               "sensor enrollment yields the physical scanner")
        assertEqual(
            manager.pairingStatusMessage,
            nil,
            "sensor enrollment hides the paused Bike Computer search status"
        )
        manager.startDeviceDiscovery()
        assertEqual(
            manager.pairingStatusMessage,
            nil,
            "a redundant restart cannot restore status while discovery is yielded"
        )
        manager.setApplicationActive(false)
        manager.setApplicationActive(true)
        assertEqual(
            manager.currentScanPurpose,
            .none,
            "foreground restoration remains yielded during sensor enrollment"
        )
        assertEqual(
            manager.pairingStatusMessage,
            nil,
            "foreground restoration does not show a false search spinner"
        )
        manager.setUnknownDeviceDiscoverySuspended(false)
        assert(waitForMainLoop(timeout: 1) {
            manager.currentScanPurpose == .explicitDiscovery &&
                driver.starts.count == 4
        }, "ending sensor enrollment resumes the same explicit request")
        assertEqual(
            manager.pairingStatusMessage,
            "Looking for nearby Bike Computers…",
            "resuming explicit discovery restores its search status"
        )

        manager.setApplicationActive(false)
        assertEqual(manager.currentScanPurpose, .none,
                    "backgrounding the real manager stops explicit discovery")
        assert(!driver.isScanning,
               "backgrounding leaves no unknown-device radio scan active")

        let handoffManager = BLEManager()
        let handoffDriver = BLEScanDriverForTesting()
        handoffManager.installScanDriverForTesting(handoffDriver)
        handoffManager.setApplicationActive(true)
        handoffManager.setUnknownDeviceDiscoverySuspended(true)
        handoffManager.installExplicitDisconnectHandoffForTesting()
        handoffManager.completeExplicitDisconnectHandoffForTesting()
        assertEqual(
            handoffManager.currentScanPurpose,
            .none,
            "disconnect handoff stays yielded during sensor enrollment"
        )
        assertEqual(
            handoffManager.pairingStatusMessage,
            nil,
            "disconnect handoff cannot show a false search status while yielded"
        )
        handoffManager.setUnknownDeviceDiscoverySuspended(false)
        assert(waitForMainLoop(timeout: 1) {
            handoffManager.currentScanPurpose == .explicitDiscovery &&
                handoffManager.pairingStatusMessage ==
                    "Looking for nearby Bike Computers…"
        }, "ending sensor enrollment resumes the completed disconnect handoff")

        let silentManager = BLEManager()
        let silentDriver = BLEScanDriverForTesting()
        silentDriver.isPoweredOn = false
        silentManager.installScanDriverForTesting(silentDriver)
        silentManager.setApplicationActive(true)
        silentManager.setUnknownDeviceDiscoverySuspended(true)
        silentManager.startDeviceDiscovery()
        assertEqual(
            silentManager.pairingError,
            nil,
            "sensor enrollment hides unrelated Bluetooth guidance"
        )
        silentManager.setUnknownDeviceDiscoverySuspended(false)
        assertEqual(
            silentManager.pairingError,
            "Turn on Bluetooth to add a Bike Computer.",
            "ending sensor enrollment reveals Bluetooth guidance for the queued request"
        )

        let trustedIdentifier = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let known = KnownBikeComputerDevice(
            deviceID: "00112233445566778899aabbccddeeff",
            peripheralIdentifier: trustedIdentifier,
            name: "Known Bicino",
            lastConnectedAt: Date(),
            isLegacy: false
        )
        let trustedManager = BLEManager()
        let trustedDriver = BLEScanDriverForTesting()
        trustedManager.installScanDriverForTesting(
            trustedDriver,
            knownDevices: [known],
            trustedPeripheralIdentifier: trustedIdentifier,
            shouldAutoReconnect: true
        )
        trustedManager.setApplicationActive(false)
        assertEqual(
            trustedManager.currentScanPurpose,
            .trustedReconnect(trustedIdentifier),
            "the real manager preserves trusted reconnect in the background"
        )
        assertEqual(trustedDriver.starts.count, 1,
                    "trusted background reconnect owns one physical scan")
        assert(!trustedDriver.starts[0].allowsDuplicates,
               "trusted reconnect does not run an unknown-device scan")

        trustedManager.setApplicationActive(true)
        trustedManager.installConnectionAttemptForTesting()
        trustedManager.startDeviceDiscovery()
        assertEqual(
            trustedManager.currentScanPurpose,
            .explicitDiscovery,
            "an explicit request replaces a stale trusted connection attempt"
        )
        assert(trustedManager.isDiscoveringDevices,
               "stale reconnect cancellation retains explicit search intent")
        assert(waitForMainLoop(timeout: 1) {
            trustedDriver.starts.count == 2 &&
                trustedDriver.starts.last?.allowsDuplicates == true
        }, "stale reconnect cancellation starts unknown-device discovery")

        let watchHandoffManager = BLEManager()
        let watchHandoffDriver = BLEScanDriverForTesting()
        watchHandoffManager.installScanDriverForTesting(
            watchHandoffDriver,
            knownDevices: [known],
            trustedPeripheralIdentifier: trustedIdentifier,
            shouldAutoReconnect: true,
            isExclusiveOperationActive: true
        )
        watchHandoffManager.setApplicationActive(true)
        assert(
            watchHandoffManager
                .watchDirectRideReconciliationRequestForTesting != nil,
            "foregrounding proactively reconciles a persisted Watch handoff"
        )
        watchHandoffManager.startDeviceDiscovery()
        assertEqual(
            watchHandoffManager.currentScanPurpose,
            .none,
            "explicit discovery does not steal BLE from an unresolved Watch ride"
        )
        assertEqual(
            watchHandoffManager.pairingStatusMessage,
            "Waiting for Apple Watch to release this Bike Computer…",
            "Settings reports the Watch handoff instead of claiming to scan"
        )
        guard let reconciliation = watchHandoffManager
            .watchDirectRideReconciliationRequestForTesting else {
            assertionFailure(
                "explicit discovery queues an exact Watch reconciliation"
            )
            return
        }
        assertEqual(
            reconciliation.deviceID,
            known.deviceID,
            "Watch reconciliation targets the selected Bike Computer"
        )
        let release = try! WatchDirectRidePreparationRequestV1(
            preparationID: reconciliation.preparationID,
            operation: .release,
            deviceID: reconciliation.deviceID
        )
        let releaseResponse = watchHandoffManager
            .handleWatchDirectRidePreparationRequest(
                release,
                phoneNavigationActive: false
            )
        assert(releaseResponse.accepted,
               "the matching durable Watch release is accepted")
        assert(waitForMainLoop(timeout: 1) {
            watchHandoffManager.currentScanPurpose == .explicitDiscovery &&
                watchHandoffDriver.starts.count == 1
        }, "the retained explicit request starts after Watch release")
        assertEqual(
            watchHandoffManager.pairingStatusMessage,
            "Looking for nearby Bike Computers…",
            "the Watch release replaces waiting guidance with real scan status"
        )

        let deferredManager = BLEManager()
        let deferredDriver = BLEScanDriverForTesting()
        deferredDriver.isPoweredOn = false
        deferredManager.installScanDriverForTesting(
            deferredDriver,
            knownDevices: [known],
            trustedPeripheralIdentifier: trustedIdentifier,
            shouldAutoReconnect: true
        )
        deferredManager.setApplicationActive(true)
        deferredManager.startDeviceDiscovery()
        assertEqual(
            deferredManager.currentScanPurpose,
            .none,
            "an explicit request waits without scanning while Bluetooth is off"
        )
        deferredManager.setBluetoothPoweredOnForTesting(true)
        assertEqual(
            deferredManager.currentScanPurpose,
            .explicitDiscovery,
            "Bluetooth-on honors the deferred explicit request before reconnect"
        )
        assertEqual(deferredDriver.starts.count, 1,
                    "Bluetooth-on starts only the explicit discovery scan")
        assert(deferredDriver.starts[0].allowsDuplicates,
               "the deferred request does not become a trusted reconnect")

        deferredManager.setApplicationActive(false)
        assertEqual(
            deferredManager.currentScanPurpose,
            .none,
            "backgrounding suspends the explicit scan without reconnecting"
        )
        assert(!deferredDriver.isScanning,
               "no radio scan survives while explicit discovery is backgrounded")
        deferredManager.setApplicationActive(true)
        assert(waitForMainLoop(timeout: 1) {
            deferredManager.currentScanPurpose == .explicitDiscovery &&
                deferredDriver.starts.count == 2
        }, "foregrounding resumes explicit discovery before trusted reconnect")

        deferredManager.setUnknownDeviceDiscoverySuspended(true)
        let disappearance = BikeComputerSettingsDiscoveryLifecyclePolicy
            .screenDisappeared(ownsDiscoveryLifecycle: true)
        for command in disappearance.commands {
            switch command {
            case .cancelOwnedDiscovery:
                deferredManager.cancelDeviceDiscovery(
                    resumeAutoReconnect: true
                )
            case .resumeUnknownDiscovery:
                deferredManager.setUnknownDeviceDiscoverySuspended(false)
            case .suspendUnknownDiscovery, .beginExplicitDiscovery:
                assertionFailure(
                    "screen disappearance emitted an invalid command"
                )
            }
        }
        assertEqual(
            deferredManager.currentScanPurpose,
            .trustedReconnect(trustedIdentifier),
            "leaving Settings releases explicit intent to trusted reconnect"
        )
        assertEqual(deferredDriver.starts.count, 3,
                    "screen disappearance starts one trusted reconnect scan")

        let cancelledDeferredManager = BLEManager()
        let cancelledDeferredDriver = BLEScanDriverForTesting()
        cancelledDeferredDriver.isPoweredOn = false
        cancelledDeferredManager.installScanDriverForTesting(
            cancelledDeferredDriver,
            knownDevices: [known],
            trustedPeripheralIdentifier: trustedIdentifier,
            shouldAutoReconnect: true
        )
        cancelledDeferredManager.setApplicationActive(true)
        cancelledDeferredManager.startDeviceDiscovery()
        assertEqual(
            cancelledDeferredManager.pairingError,
            "Turn on Bluetooth to add a Bike Computer.",
            "Bluetooth-off explicit discovery presents a scoped error"
        )
        let cancelledDisappearance =
            BikeComputerSettingsDiscoveryLifecyclePolicy
                .screenDisappeared(ownsDiscoveryLifecycle: true)
        for command in cancelledDisappearance.commands {
            switch command {
            case .cancelOwnedDiscovery:
                cancelledDeferredManager.cancelDeviceDiscovery(
                    resumeAutoReconnect: true
                )
            case .resumeUnknownDiscovery:
                cancelledDeferredManager
                    .setUnknownDeviceDiscoverySuspended(false)
            case .suspendUnknownDiscovery, .beginExplicitDiscovery:
                assertionFailure(
                    "screen disappearance emitted an invalid command"
                )
            }
        }
        assertEqual(
            cancelledDeferredManager.pairingError,
            nil,
            "leaving deferred setup clears its Bluetooth-off error"
        )
        cancelledDeferredManager.setBluetoothPoweredOnForTesting(true)
        assertEqual(
            cancelledDeferredManager.currentScanPurpose,
            .trustedReconnect(trustedIdentifier),
            "Bluetooth restoration follows trusted reconnect after cancellation"
        )

        let failedManager = BLEManager()
        let failedDriver = BLEScanDriverForTesting()
        failedManager.installScanDriverForTesting(failedDriver)
        failedManager.setApplicationActive(true)
        failedManager.startDeviceDiscovery()
        failedManager.installPausedExplicitDiscoveryFailureForTesting(
            error: "Could not connect to that Bike Computer.",
            status: "Connecting…"
        )
        failedManager.setApplicationActive(false)
        failedManager.setApplicationActive(true)
        assertEqual(
            failedManager.pairingError,
            "Could not connect to that Bike Computer.",
            "foregrounding preserves an in-flight explicit pairing failure"
        )
        assertEqual(
            failedManager.pairingStatusMessage,
            "Connecting…",
            "foregrounding does not replace a failed pairing with discovery UI"
        )

        let candidateManager = BLEManager()
        let candidateDriver = BLEScanDriverForTesting()
        candidateManager.installScanDriverForTesting(candidateDriver)
        candidateManager.setApplicationActive(true)
        let sealedCandidate = DiscoveredBikeComputerDevice(
            peripheralIdentifier: UUID(
                uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
            )!,
            advertisedName: "Bicino",
            shortIdentifier: "FFFF",
            identitySuffix: "FFFFFFFF",
            isClaimed: false,
            rssi: -42,
            lastSeenAt: Date()
        )
        candidateManager.installNearbyCandidateForTesting(
            sealedCandidate,
            isPresented: false
        )
        candidateManager.setUnknownDeviceDiscoverySuspended(true)
        assert(!candidateManager.isOpportunisticDiscoverySuppressed,
               "sensor interruption releases an unpresented candidate seal")
        candidateManager.setUnknownDeviceDiscoverySuspended(false)
        assert(waitForMainLoop(timeout: 1) {
            candidateManager.currentScanPurpose ==
                .opportunisticDiscovery &&
                candidateDriver.starts.count == 2
        }, "opportunistic discovery resumes after sensor interruption")
        candidateManager.installNearbyCandidateForTesting(
            sealedCandidate,
            isPresented: false
        )
        candidateManager.setBluetoothPoweredOnForTesting(false)
        assert(!candidateManager.isOpportunisticDiscoverySuppressed,
               "Bluetooth loss releases an unpresented candidate seal")
        candidateManager.setBluetoothPoweredOnForTesting(true)
        assert(waitForMainLoop(timeout: 1) {
            candidateManager.currentScanPurpose ==
                .opportunisticDiscovery &&
                candidateDriver.starts.count == 3
        }, "Bluetooth restoration resumes opportunistic discovery")
        candidateManager.installNearbyCandidateForTesting(
            sealedCandidate,
            isPresented: true
        )
        candidateManager.dismissNearbyBicinoCandidate(
            peripheralIdentifier: sealedCandidate.peripheralIdentifier
        )
        assertEqual(
            candidateManager.currentScanPurpose,
            .none,
            "dismissing first-device setup suppresses automatic rediscovery"
        )
        candidateManager.reconnect()
        assert(waitForMainLoop(timeout: 1) {
            candidateManager.currentScanPurpose ==
                .opportunisticDiscovery &&
                candidateDriver.starts.count == 4
        }, "manual reconnect without a trusted device restores sheet discovery")

        let exclusiveManager = BLEManager()
        let exclusiveDriver = BLEScanDriverForTesting()
        exclusiveManager.installScanDriverForTesting(
            exclusiveDriver,
            knownDevices: [known],
            trustedPeripheralIdentifier: trustedIdentifier,
            shouldAutoReconnect: true,
            isExclusiveOperationActive: true
        )
        exclusiveManager.setApplicationActive(true)
        assertEqual(
            exclusiveManager.currentScanPurpose,
            .none,
            "the real manager gives Watch-direct ownership priority over reconnect"
        )
        assert(exclusiveDriver.starts.isEmpty,
               "Watch-direct exclusion starts no physical iPhone scan")
    }

    static func testBLEManagerRequiresNavigationReadinessForWrites() {
        let manager = BLEManager()
        manager.isConnected = true

        var sentPackets: [String] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: NavigationPacketBuilder.protocolMaxBytes,
            canSend: { true },
            write: { data in
                sentPackets.append(String(data: data, encoding: .utf8) ?? "")
            }
        ))

        assert(!manager.sendNavigationData("2|120|Turn left"), "BLEManager should reject writes before navigation characteristic readiness")
        assertEqual(sentPackets.count, 0, "not-ready BLEManager should not write through endpoint")

        manager.isNavigationReady = true
        assert(manager.sendNavigationData("2|120|Turn left"), "BLEManager should write after navigation characteristic readiness")
        assertEqual(sentPackets, ["2|120|Turn left"], "BLEManager writes encoded navigation packet")

        let stalledManager = BLEManager()
        stalledManager.installNavigationWriteQueueForTesting(
            maxCount: 2,
            priorityMaxCount: 2
        )
        var transportReady = false
        var recoveredPackets: [String] = []
        stalledManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: NavigationPacketBuilder.protocolMaxBytes,
            expectsWriteResponse: true,
            canSend: { transportReady },
            write: { data in
                recoveredPackets.append(String(data: data, encoding: .utf8) ?? "")
            }
        ))
        stalledManager.isConnected = true
        stalledManager.isNavigationReady = true
        assert(stalledManager.sendNavigationData("2|120|Turn left"),
               "first stalled maneuver snapshot is queued")
        assert(stalledManager.sendNavigationData("3|80|Turn right"),
               "new stalled maneuver snapshot replaces its predecessor")
        assertEqual(recoveredPackets, [],
                    "stalled transport sends no premature maneuver state")
        transportReady = true
        stalledManager.completeNavigationWriteForTesting(error: nil)
        assertEqual(recoveredPackets, ["3|80|Turn right"],
                    "transport recovery sends only the newest complete maneuver snapshot")

        let watchdogManager = BLEManager()
        watchdogManager.isConnected = true
        watchdogManager.isNavigationReady = true
        var watchdogWrites: [Data] = []
        var watchdogRecoveries = 0
        watchdogManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 20,
                expectsWriteResponse: true,
                canSend: { true },
                write: { watchdogWrites.append($0) }
            )
        )
        watchdogManager.installNavigationWriteStallRecoveryForTesting(
            timeout: 0.01,
            recovery: { watchdogRecoveries += 1 }
        )
        watchdogManager.installRideRecoveryDeadlineForTesting(timeout: 0.01)
        assert(watchdogManager.requestDeviceCapabilities(),
               "watchdog fixture sends one acknowledged write")
        assertEqual(watchdogWrites.count, 1,
                    "watchdog starts only after the write reaches its transport")
        assert(waitForMainLoop(timeout: 1) { watchdogRecoveries == 1 },
               "missing acknowledged completion triggers bounded recovery")
        assert(!watchdogManager.isNavigationReady,
               "stall recovery closes the unusable navigation session")

        assert(waitForMainLoop(timeout: 1) { watchdogManager.rideRecoveryMessage != nil },
               "missing cancellation callback produces an actionable phone warning")
        assertEqual(watchdogManager.rideTransportPhase, .recovering,
                    "deadline never claims that the old connection disconnected")
        assert(!watchdogManager.requestDeviceCapabilities(),
               "blocked recovery does not dispatch new ride work")
        assertEqual(watchdogWrites.count, 1, "no writes reuse the ambiguous connection")
        let lateDeadline = watchdogManager.retireRideRecoveryForTesting()
        watchdogManager.installNavigationWriteStallRecoveryForTesting(timeout: 1, recovery: {})
        lateDeadline()
        assert(watchdogManager.rideRecoveryMessage == nil,
               "retired deadline cannot poison a successor connection")
        assertEqual(watchdogManager.rideTransportPhase, .ready,
                    "real disconnect boundary permits successor readiness")

        let noResponseWatchdogManager = BLEManager()
        noResponseWatchdogManager.isConnected = true
        noResponseWatchdogManager.isNavigationReady = true
        var noResponseRecoveries = 0
        noResponseWatchdogManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 20,
                expectsWriteResponse: false,
                canSend: { false },
                write: { _ in
                    assert(false, "backpressured transport must not write")
                }
            )
        )
        noResponseWatchdogManager.installNavigationWriteStallRecoveryForTesting(
            timeout: 0.01,
            recovery: { noResponseRecoveries += 1 }
        )
        assert(noResponseWatchdogManager.requestDeviceCapabilities(),
               "no-response watchdog fixture admits the pending write")
        assert(waitForMainLoop(timeout: 1) { noResponseRecoveries == 1 },
               "persistent no-response backpressure triggers bounded recovery")
        assert(!noResponseWatchdogManager.isNavigationReady,
               "no-response recovery closes the wedged navigation session")
    }

    static func testRideApplicationAcknowledgementWaitsForATTCallback() {
        let manager = BLEManager()
        let commandID = UUID(
            uuidString: "44444444-4444-4444-4444-444444444444"
        )!
        var completions = 0
        manager.installRideApplicationAcknowledgementRaceForTesting(
            commandID: commandID,
            commandType: .navigationClear,
            stateGeneration: 7,
            completion: { completions += 1 }
        )
        manager.handleRideApplicationAcknowledgementForTesting(.init(
            commandType: .navigationClear,
            result: .success,
            commandID: commandID,
            stateGeneration: 7,
            leaseGeneration: 1
        ))
        assertEqual(completions, 1,
                    "application ACK completes the logical command once")
        assert(!manager.hasPendingRideApplicationDeliveryForTesting,
               "application ACK retires the logical delivery")
        assert(manager.hasPendingATTWriteForTesting,
               "application ACK cannot retire an unidentified ATT callback slot")

        manager.completeNavigationWriteForTesting(error: nil)
        assert(!manager.hasPendingATTWriteForTesting,
               "the matching ATT callback independently releases its slot")
        manager.handleRideApplicationAcknowledgementForTesting(.init(
            commandType: .navigationClear,
            result: .success,
            commandID: commandID,
            stateGeneration: 7,
            leaseGeneration: 1
        ))
        assertEqual(completions, 1,
                    "a duplicated late application ACK remains idempotent")
    }

    static func testBLEManagerSendsFallbackMapSettings() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendSetting(id: 8, value: 7)

        assertEqual(sentPackets.count, 1, "settings without a dedicated characteristic should use fallback navigation writes")
        let packet = sentPackets[0]
        assertEqual(String(data: packet.prefix(4), encoding: .utf8),
                    DeviceBLEProtocol.settingsFallbackPrefix,
                    "fallback settings packet uses MSET prefix")
        assertEqual(packet[4], 8, "fallback settings packet includes setting id")
        let valueBytes = Array(packet[5..<9])
        let value = Int32(valueBytes[0])
            | (Int32(valueBytes[1]) << 8)
            | (Int32(valueBytes[2]) << 16)
            | (Int32(valueBytes[3]) << 24)
        assertEqual(value, 7, "fallback settings packet includes little-endian value")
    }

    static func testBLEManagerSendsSeparateMapProfileSettings() {
        let manager = BLEManager()
        let capabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask |
                  DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(capabilities),
               "extended visibility capability should be accepted")
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.showBuildings = true
        manager.showGreenSpace = false
        manager.showPaths = false
        manager.showTracks = true
        manager.showMajorRoads = false
        manager.showLocalStreets = false
        manager.showServiceRoads = true
        manager.showWater = false
        manager.showRailways = false
        manager.showOtherAreas = false
        manager.showRouteOverlay = true
        manager.showCurrentPosition = false
        manager.mapPlusNavigationShowBuildings = false
        manager.mapPlusNavigationShowGreenSpace = false
        manager.mapPlusNavigationShowPaths = false
        manager.mapPlusNavigationShowTracks = true
        manager.mapPlusNavigationShowMajorRoads = true
        manager.mapPlusNavigationShowLocalStreets = false
        manager.mapPlusNavigationShowServiceRoads = false
        manager.mapPlusNavigationShowWater = false
        manager.mapPlusNavigationShowRailways = false
        manager.mapPlusNavigationShowOtherAreas = false

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendVisibilityMask(for: .map)
        manager.sendVisibilityMask(for: .mapPlusNavigation)

        assertEqual(sentPackets.count, 2, "each map screen sends its own visibility profile")
        assertEqual(sentPackets[0][4], 8, "Map visibility keeps legacy setting ID 8")
        assertEqual(readInt32LE(sentPackets[0], offset: 5), 0x1D01,
                    "Map visibility separates service roads and tracks while retaining overlays")
        assertEqual(sentPackets[1][4], DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID,
                    "Map + Navigation visibility uses its profile setting ID")
        assertEqual(readInt32LE(sentPackets[1], offset: 5), 0x1808,
                    "Map + Navigation visibility sends its independent track bit")
    }

    static func testBLEManagerFoldsExtendedVisibilityForLegacyFirmware() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.showBuildings = false
        manager.showGreenSpace = false
        manager.showPaths = false
        manager.showTracks = true
        manager.showMajorRoads = false
        manager.showLocalStreets = false
        manager.showServiceRoads = true
        manager.showWater = false
        manager.showRailways = false
        manager.showOtherAreas = false
        manager.showRouteOverlay = false
        manager.showCurrentPosition = false

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendVisibilityMask(for: .map)

        assertEqual(sentPackets.count, 1, "legacy firmware receives one visibility packet")
        assertEqual(readInt32LE(sentPackets[0], offset: 5), 0x14,
                    "legacy firmware folds tracks into paths and service roads into local streets")
    }

    static func testBLEManagerGatesTopographicContourVisibility() {
        let manager = BLEManager()
        let capabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 0, 0x40])
        assert(manager.handleDeviceCapabilitiesNotification(capabilities),
               "CAP2 topographic contour capability is accepted")
        assert(manager.supportsTopographicContours,
               "CAP2 bit 30 enables contour-aware transfer and settings")
        let status = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
            """
            {"enabled":true,"activeMapId":"topo-map","activeRendererFormat":4,"topographyProfileVersion":1,"topographyQualityMode":"standard-20m-v1","contourMinorIntervalM":20,"contourIndexIntervalM":100,"contourNoDataMillionths":0,"containsContours":true,"topographySourcePolicyReceiptPrefix":"abcdef012345","topographySectionHealthy":true}
            """.utf8
        )
        assert(manager.handleMapTransferStatusNotification(status),
               "format-4 active map status is accepted")
        assert(manager.topographicContoursAvailable,
               "capability and verified active-map health unlock contour settings")
        assertEqual(manager.activeMapTopographyQualityMode,
                    "standard-20m-v1",
                    "active map exposes its contour quality mode")
        assertEqual(manager.activeMapContourMinorIntervalM, 20,
                    "active map exposes its minor contour interval")
        assertEqual(manager.activeMapContourIndexIntervalM, 100,
                    "active map exposes its index contour interval")
        assert(manager.activeMapContainsContours,
               "active map reports whether contour records exist")

        manager.isConnected = true
        manager.isNavigationReady = true
        manager.showBuildings = false
        manager.showGreenSpace = false
        manager.showPaths = false
        manager.showTracks = false
        manager.showMajorRoads = false
        manager.showLocalStreets = false
        manager.showServiceRoads = false
        manager.showWater = false
        manager.showRailways = false
        manager.showOtherAreas = false
        manager.showRouteOverlay = false
        manager.showCurrentPosition = false
        manager.showContours = true
        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        manager.sendVisibilityMask(for: .map)
        assertEqual(readInt32LE(sentPackets[0], offset: 5), 1 << 13,
                    "healthy format-4 maps send the independent contour bit")

        let legacyStatus = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) +
            Data("{\"enabled\":true,\"activeMapId\":\"legacy\",\"activeRendererFormat\":3}".utf8)
        assert(manager.handleMapTransferStatusNotification(legacyStatus),
               "legacy active map status is accepted")
        assert(!manager.topographicContoursAvailable,
               "a non-topographic active map closes the contour gate")
        sentPackets.removeAll()
        manager.sendVisibilityMask(for: .map)
        assertEqual(readInt32LE(sentPackets[0], offset: 5), 0,
                    "saved contour preference cannot leak to an incompatible map")
    }

    static func testBLEManagerSendsDeviceSoundFallback() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(!manager.playDeviceSound(.squeezeHorn, volumePercent: 62),
               "sound playback rejects devices without the negotiated capability")
        assertEqual(sentPackets.count, 0, "unsupported devices receive no sound packet")

        manager.supportsDeviceSounds = true
        assert(manager.playDeviceSound(.squeezeHorn, volumePercent: 62),
               "sound playback queues when BLE is ready and capability is present")
        assertEqual(sentPackets.count, 1, "sound playback sends one route-equivalent fallback packet")
        assertEqual(String(data: sentPackets[0].prefix(4), encoding: .utf8), "SNDP", "fallback packet uses SNDP prefix")
        assertEqual(sentPackets[0][4], DeviceSound.squeezeHorn.rawValue, "fallback packet includes selected sound")
        assertEqual(sentPackets[0][5], 62, "fallback packet includes selected volume")
    }

    static func testBLEManagerSendsPowerButtonHonkFallback() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var scheduledRetries: [DispatchWorkItem] = []
        manager.installPowerButtonHonkRetrySchedulerForTesting { _, workItem in
            scheduledRetries.append(workItem)
        }

        func runNextScheduledRetry(_ message: String) {
            while !scheduledRetries.isEmpty {
                let workItem = scheduledRetries.removeFirst()
                guard !workItem.isCancelled else { continue }
                workItem.perform()
                return
            }
            assert(false, message)
        }

        func runAllScheduledRetries() {
            while !scheduledRetries.isEmpty {
                let workItem = scheduledRetries.removeFirst()
                if !workItem.isCancelled {
                    workItem.perform()
                }
            }
        }

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(!manager.sendPowerButtonHonkConfiguration(),
               "PWR honk configuration rejects devices without the negotiated capability")
        assertEqual(sentPackets.count, 0, "unsupported devices receive no PWR honk packet")

        manager.supportsPowerButtonHonk = true
        manager.isPowerButtonHonkEnabled = true
        manager.selectedDeviceSound = .plasticBicycleHorn
        manager.deviceSoundVolumePercent = 75
        assert(manager.sendPowerButtonHonkConfiguration(),
               "PWR honk configuration queues when BLE is ready and capability is present")
        assertEqual(sentPackets.count, 1, "PWR honk configuration sends one fallback packet")
        assertEqual(String(data: sentPackets[0].prefix(4), encoding: .utf8), "SNDH", "PWR honk fallback uses SNDH prefix")
        assertEqual(sentPackets[0][4], 1, "PWR honk fallback includes enabled state")
        assertEqual(sentPackets[0][5], DeviceSound.plasticBicycleHorn.rawValue, "PWR honk fallback includes selected sound")
        assertEqual(sentPackets[0][6], 75, "PWR honk fallback includes selected volume")

        var legacyFailedStatus = Data(DeviceBLEProtocol.powerButtonHonkStatusPrefix.utf8)
        legacyFailedStatus.append(contentsOf: [
            0,
            1,
            DeviceSound.plasticBicycleHorn.rawValue,
            75
        ])
        assert(manager.handlePowerButtonHonkStatusNotification(legacyFailedStatus),
               "an unsolicited PWR honk acknowledgement should be consumed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        assertEqual(sentPackets.count, 1,
                    "firmware without ACK capability receives no retry")

        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsPowerButtonHonk = true
        manager.supportsPowerButtonHonkAcknowledgement = true
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        sentPackets.removeAll()
        assert(manager.sendPowerButtonHonkConfiguration(),
               "ACK-capable firmware accepts a tracked PWR honk configuration")
        let failedStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 0)
        assert(manager.handleNavigationCharacteristicNotification(failedStatus),
               "failed PWR honk acknowledgement should be consumed")
        runNextScheduledRetry(
            "failed PWR honk acknowledgement should schedule a retry"
        )
        assertEqual(sentPackets.count, 2,
                    "failed PWR honk acknowledgement retries the configuration")

        let successStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 1)
        assert(manager.handlePowerButtonHonkStatusNotification(successStatus),
               "successful PWR honk acknowledgement should be consumed")
        assert(manager.handlePowerButtonHonkStatusNotification(failedStatus),
               "stale PWR honk acknowledgement should still be consumed")
        runAllScheduledRetries()
        assertEqual(sentPackets.count, 2,
                    "successful acknowledgement cancels further PWR retries")
        assert(manager.powerButtonHonkConfigurationError == nil,
               "successful acknowledgement leaves no configuration error")

        sentPackets.removeAll()
        assert(manager.sendPowerButtonHonkConfiguration(),
               "a new ACK-capable PWR configuration starts cleanly")
        let terminalFailedStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 0)
        for expectedSendCount in 2...3 {
            assert(manager.handlePowerButtonHonkStatusNotification(terminalFailedStatus),
                   "failed PWR honk acknowledgement should be consumed")
            runNextScheduledRetry(
                "failed acknowledgement should schedule the next bounded retry"
            )
            assertEqual(sentPackets.count, expectedSendCount,
                        "failed acknowledgement advances the bounded retry sequence")
        }
        assert(manager.handlePowerButtonHonkStatusNotification(terminalFailedStatus),
               "terminal failed PWR honk acknowledgement should be consumed")
        runNextScheduledRetry(
            "terminal failed acknowledgement should schedule terminal handling"
        )
        assertEqual(sentPackets.count, 3,
                    "PWR honk acknowledgement retries stop after three total attempts")
        assert(manager.powerButtonHonkConfigurationError != nil,
               "terminal PWR honk failure is surfaced to the settings UI")

        sentPackets.removeAll()
        assert(manager.sendPowerButtonHonkConfiguration(),
               "a new PWR honk attempt is accepted after a terminal failure")
        assert(manager.powerButtonHonkConfigurationError == nil,
               "starting a new PWR honk attempt clears the stale error")
        let recoveredStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 1)
        assert(manager.handlePowerButtonHonkStatusNotification(recoveredStatus),
               "successful PWR honk acknowledgement should be consumed after retry exhaustion")

        sentPackets.removeAll()
        manager.selectedDeviceSound = .bellDing
        assert(manager.sendPowerButtonHonkConfiguration(), "first A configuration should send")
        let firstA = sentPackets.last!
        manager.selectedDeviceSound = .squeezeHorn
        assert(manager.sendPowerButtonHonkConfiguration(), "intervening B configuration should send")
        manager.selectedDeviceSound = .bellDing
        assert(manager.sendPowerButtonHonkConfiguration(), "second A configuration should send")
        let secondA = sentPackets.last!
        assert(readUInt32LE(firstA, offset: 4) != readUInt32LE(secondA, offset: 4),
               "repeated configurations use distinct request IDs")
        assert(manager.handlePowerButtonHonkStatusNotification(
            powerButtonHonkStatus(for: firstA, applied: 1)
        ), "delayed first-A acknowledgement should be consumed as stale")
        assert(manager.handlePowerButtonHonkStatusNotification(
            powerButtonHonkStatus(for: secondA, applied: 0)
        ), "current second-A failure should still control retry state")
        runNextScheduledRetry(
            "current second-A failure should schedule its own retry"
        )
        assertEqual(sentPackets.count, 4,
                    "delayed first-A acknowledgement cannot suppress second-A retry")
        assert(manager.handlePowerButtonHonkStatusNotification(
            powerButtonHonkStatus(for: secondA, applied: 1)
        ), "second-A acknowledgement should complete the current request")

        sentPackets.removeAll()
        manager.deviceSoundVolumeEditingChanged(true)
        assertEqual(sentPackets.count, 0,
                    "editing the volume does not send intermediate PWR configuration")
        manager.deviceSoundVolumeEditingChanged(false)
        assertEqual(sentPackets.count, 1,
                    "finishing a volume edit sends one PWR configuration")
        manager.isPowerButtonHonkEnabled = false
        manager.deviceSoundVolumeEditingChanged(false)
        assertEqual(sentPackets.count, 1,
                    "finishing a volume edit while PWR honk is disabled sends nothing")
    }

    static func testPowerButtonHonkTimeoutAndTransportFailures() {
        let manager = BLEManager()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsPowerButtonHonk = true
        manager.supportsPowerButtonHonkAcknowledgement = true
        manager.isPowerButtonHonkEnabled = true
        manager.selectedDeviceSound = .squeezeHorn
        manager.deviceSoundVolumePercent = 65
        manager.installPowerButtonHonkRetryTiming(
            ackTimeout: 0.02,
            failureRetryDelay: 0.01
        )

        assert(!manager.sendPowerButtonHonkConfiguration(),
               "initial PWR honk transport failure is reported")
        assert(manager.powerButtonHonkConfigurationError != nil,
               "initial PWR honk transport failure is visible")

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        assert(manager.sendPowerButtonHonkConfiguration(),
               "missing-ACK timeout test sends the initial configuration")
        assert(waitForMainLoop(timeout: 1) {
            manager.powerButtonHonkConfigurationError != nil
        }, "missing acknowledgement reaches terminal failure")
        assertEqual(sentPackets.count, 3,
                    "missing acknowledgement retries three total attempts")

        sentPackets.removeAll()
        assert(manager.sendPowerButtonHonkConfiguration(),
               "retry transport failure test sends the initial configuration")
        let failedStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 0)
        manager.installNavigationWriteEndpoint(nil)
        assert(manager.handleNavigationCharacteristicNotification(failedStatus),
               "navigation notification dispatcher routes PWR failure status")
        assert(waitForMainLoop(timeout: 1) {
            manager.powerButtonHonkConfigurationError != nil
        }, "retry transport failure reaches terminal failure")
        assertEqual(sentPackets.count, 1,
                    "failed retry transport does not report an unsent packet")

        // Keep ACK deadlines under test control during queue recovery. A real
        // 20 ms timeout can retry before the run-loop observer sees the first
        // write on a busy CI runner.
        var queuedAckRetries: [DispatchWorkItem] = []
        manager.installPowerButtonHonkRetrySchedulerForTesting { _, workItem in
            queuedAckRetries.append(workItem)
        }
        var transportReady = false
        sentPackets.removeAll()
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { transportReady },
            write: { sentPackets.append($0) }
        ))
        assert(manager.sendPowerButtonHonkConfiguration(),
               "backpressured PWR configuration is accepted into the fallback queue")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        assertEqual(sentPackets.count, 0,
                    "backpressured PWR configuration is not reported as written")
        assert(manager.powerButtonHonkConfigurationError == nil,
               "ACK timeout does not start while the PWR configuration is queued")
        assertEqual(queuedAckRetries.count, 0,
                    "queued PWR configuration schedules no ACK deadline")

        transportReady = true
        manager.flushPendingNavigationWritesForTesting()
        assertEqual(sentPackets.count, 1,
                    "queued PWR configuration is handed to the recovered transport")
        assertEqual(queuedAckRetries.count, 1,
                    "the actual PWR transport write starts one ACK deadline")
        let recoveredAfterBackpressure = powerButtonHonkStatus(
            for: sentPackets[0],
            applied: 1
        )
        assert(manager.handlePowerButtonHonkStatusNotification(recoveredAfterBackpressure),
               "queued PWR configuration can be acknowledged after transport recovery")
        assert(queuedAckRetries[0].isCancelled,
               "successful ACK cancels the queued PWR deadline")
        queuedAckRetries[0].perform()
        assertEqual(sentPackets.count, 1,
                    "successful ACK cancels retries after transport recovery")
    }

    static func testBLEManagerSendsDeviceCapabilityFallback() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(manager.requestDeviceCapabilities(), "capability request should queue when BLE is ready")
        assertEqual(sentPackets,
                    [Data("CAPS".utf8) + Data([DeviceBLEProtocol.deviceCapabilitiesVersion])],
                    "capability request negotiates device-persisted configuration")
    }

    static func testBLEManagerSendsMapTransferControlFrames() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 180,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(manager.requestMapTransferMode(enabled: true), "map transfer enter should queue when BLE is ready")
        assert(manager.requestMapTransferStatus(), "map transfer status should queue when BLE is ready")
        assert(manager.requestMapTransferMode(enabled: false), "map transfer exit should queue when BLE is ready")

        assertEqual(sentPackets.count, 3, "map transfer control should write three packets")
        assertEqual(String(data: sentPackets[0], encoding: .utf8), "MTRNenter", "enter command uses MTRN frame")
        assertEqual(String(data: sentPackets[1], encoding: .utf8), "MSTS", "status command uses MSTS frame")
        assertEqual(String(data: sentPackets[2], encoding: .utf8), "MTRNexit", "exit command uses MTRN frame")
    }

    static func testBLEManagerSendsDeviceTransferControlFrames() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 96,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(manager.requestDeviceTransferMode(.firmware), "firmware transfer enter should queue when BLE is ready")
        assert(manager.requestFirmwareMaintenancePreparation(), "firmware maintenance prepare should queue when BLE is ready")
        assert(manager.requestDeviceTransferMode(.debug), "debug transfer enter should queue when BLE is ready")
        assert(manager.requestDeviceTransferStatus(), "device transfer status should queue when BLE is ready")
        assert(manager.requestDeviceTransferExit(), "device transfer exit should queue when BLE is ready")

        assertEqual(sentPackets.count, 5, "device transfer control should write five packets")
        assertEqual(String(data: sentPackets[0], encoding: .utf8), "DTRNenter|firmware", "firmware enter command uses DTRN frame")
        assertEqual(String(data: sentPackets[1], encoding: .utf8), "DTRNprepare|firmware", "firmware maintenance uses the explicit prepare command")
        assertEqual(String(data: sentPackets[2], encoding: .utf8), "DTRNenter|debug", "debug enter command uses DTRN frame")
        assertEqual(String(data: sentPackets[3], encoding: .utf8), "DSTS", "status command uses DSTS frame")
        assertEqual(String(data: sentPackets[4], encoding: .utf8), "DTRNexit", "exit command uses DTRN frame")

        let credentials = RemoteDebugLANCredentials(
            ssid: "Home Wi-Fi",
            password: "local-password"
        )
        assert(credentials != nil, "valid LAN credentials are accepted")
        assert(manager.requestDeviceTransferMode(
            .debug,
            remoteDebugLANCredentials: credentials
        ), "LAN-first debug command should fit one authenticated BLE write")
        let lanPacket = sentPackets[5]
        let lanPrefix = Data("DTRNenter|debug|lan1|".utf8)
        assert(lanPacket.starts(with: lanPrefix),
               "LAN-first debug command uses the versioned binary envelope")
        let lengths = lanPacket.dropFirst(lanPrefix.count).prefix(2)
        assertEqual(Array(lengths), [10, 14],
                    "LAN-first envelope carries bounded SSID/password lengths")
        assert(RemoteDebugLANCredentials(ssid: String(repeating: "s", count: 33),
                                         password: "password") == nil,
               "oversized SSIDs are rejected before BLE transmission")
        assert(RemoteDebugLANCredentials(ssid: "Home", password: "short") == nil,
               "short WPA passwords are rejected before BLE transmission")
        assert(RemoteDebugLANCredentials(ssid: "Home\0Network",
                                         password: "password") == nil,
               "NUL bytes are rejected before BLE transmission")

        assert(manager.requestDeviceTransferMode(
            .diagnostics,
            remoteDebugLANCredentials: credentials
        ), "LAN-first diagnostics command should fit one authenticated BLE write")
        let diagnosticsLANPacket = sentPackets[6]
        assert(
            diagnosticsLANPacket.starts(with: Data("DTRNenter|diagnostics|lan1|".utf8)),
            "LAN-first diagnostics uses its versioned binary envelope"
        )

        assert(manager.requestDeviceTransferMode(
            .debug,
            remoteDebugHotspotFallbackReason: .endpointUnreachable
        ), "endpoint-unreachable fallback command should fit one BLE write")
        assertEqual(
            String(data: sentPackets[7], encoding: .utf8),
            "DTRNenter|debug|h1|e",
            "endpoint fallback reason is persisted by firmware, not only iOS"
        )
        assert(manager.requestDeviceTransferMode(
            .diagnostics,
            remoteDebugHotspotFallbackReason: .endpointUnreachable
        ), "diagnostics endpoint fallback command should fit one BLE write")
        assertEqual(
            String(data: sentPackets[8], encoding: .utf8),
            "DTRNenter|diagnostics|h1|e",
            "diagnostics endpoint fallback requests a protected hotspot"
        )

        let nextTLSFingerprint = String(repeating: "a", count: 64)
        assert(
            manager.requestDeviceTransferTLSIdentityPreparation(),
            "TLS identity preparation queues on the authenticated channel"
        )
        assert(
            manager.requestDeviceTransferTLSIdentityCommit(
                certificateSHA256: nextTLSFingerprint.uppercased()
            ),
            "TLS identity commit normalizes and queues an exact fingerprint"
        )
        assert(
            manager.requestDeviceTransferTLSIdentityCancellation(),
            "TLS identity cancellation queues on the authenticated channel"
        )
        assertEqual(
            String(data: sentPackets[9], encoding: .utf8),
            "DTRNtls|prepare",
            "TLS preparation uses the documented DTRN frame"
        )
        assertEqual(
            String(data: sentPackets[10], encoding: .utf8),
            "DTRNtls|commit|\(nextTLSFingerprint)",
            "TLS commit binds the exact lowercase pending leaf fingerprint"
        )
        assertEqual(
            String(data: sentPackets[11], encoding: .utf8),
            "DTRNtls|cancel",
            "TLS cancellation uses the documented DTRN frame"
        )
        assert(
            !manager.requestDeviceTransferTLSIdentityCommit(
                certificateSHA256: "not-a-fingerprint"
            ),
            "malformed TLS fingerprints never reach BLE"
        )

        assertEqual(
            DeviceTransferSecurityPolicy.normalizedCertificateSHA256(
                nextTLSFingerprint.uppercased()
            ),
            nextTLSFingerprint,
            "TLS pins normalize to one lowercase representation"
        )
        let transferToken = String(repeating: "b", count: 32)
        assertEqual(
            DeviceTransferSecurityPolicy.normalizedTransferToken(
                transferToken
            ),
            transferToken,
            "transfer tokens use the firmware's exact lowercase format"
        )
        assert(
            DeviceTransferSecurityPolicy.normalizedTransferToken(
                transferToken.uppercased()
            ) == nil,
            "noncanonical transfer tokens fail closed"
        )
        assert(
            DeviceTransferSecurityPolicy.validate(
                baseURL: URL(string: "https://192.168.4.1:8080")!,
                certificateSHA256: nextTLSFingerprint,
                identityVersion: 1,
                transferGeneration: 1,
                secureTransferV1: true
            ),
            "complete BLE-delivered HTTPS metadata is accepted"
        )
        assert(
            !DeviceTransferSecurityPolicy.validate(
                baseURL: URL(string: "http://192.168.4.1:8080")!,
                certificateSHA256: nextTLSFingerprint,
                identityVersion: 1,
                transferGeneration: 1,
                secureTransferV1: true
            ),
            "plaintext transfer origins fail closed"
        )
        assert(
            !DeviceTransferSecurityPolicy.validate(
                baseURL: URL(string: "https://192.168.4.1:8080?token=bad")!,
                certificateSHA256: nextTLSFingerprint,
                identityVersion: 1,
                transferGeneration: 1,
                secureTransferV1: true
            ),
            "transfer origins carrying query data fail closed"
        )
        assert(
            !DeviceTransferSecurityPolicy.validate(
                baseURL: URL(string: "https://192.168.4.1:8080/not-an-origin")!,
                certificateSHA256: nextTLSFingerprint,
                identityVersion: 1,
                transferGeneration: 1,
                secureTransferV1: true
            ),
            "transfer base URLs must be clean HTTPS origins"
        )
        assert(
            !DeviceTransferSecurityPolicy.validate(
                baseURL: URL(string: "https://192.168.4.1:8080")!,
                certificateSHA256: nextTLSFingerprint,
                identityVersion: 1,
                transferGeneration: 0,
                secureTransferV1: true
            ),
            "missing authorization generation fails closed"
        )

        let session = DeviceTransferSession(
            mode: .debug,
            baseURL: URL(string: "https://192.168.4.1:8080")!,
            accessPointSSID: "BikeComputer-Transfer",
            accessPointPassphrase: "hotspot-secret",
            sessionToken: String(repeating: "b", count: 32),
            hotspotFallback: true,
            hotspotFallbackReason: "endpoint_unreachable",
            tlsCertificateSHA256: String(repeating: "a", count: 64),
            tlsIdentityVersion: 1,
            transferGeneration: 1,
            secureTransferV1: true
        )
        assertEqual(
            RemoteDeviceDebugSessionPolicy.pageURL(for: session)?.absoluteString,
            "https://192.168.4.1:8080/device-debug/",
            "debug page URL is HTTPS and contains no authorization token"
        )
        let details = RemoteDeviceDebugSessionPolicy.sessionDetails(
            for: session,
            target: "WAVESHARE_AMOLED_175",
            deviceName: "Bicino"
        )
        assert(!details.contains(String(repeating: "b", count: 32)),
               "copyable session details redact the transfer token")
        assert(!details.contains("hotspot-secret"),
               "copyable session details redact the hotspot password")
        assert(details.contains("Fallback reason: endpoint_unreachable"),
               "secret-free diagnostics retain the firmware fallback reason")
        let refreshedSession = DeviceTransferSession(
            mode: .debug,
            baseURL: session.baseURL,
            accessPointSSID: nil,
            sessionToken: session.sessionToken,
            networkTransport: "lan",
            networkSSID: "trusted-network",
            hotspotFallback: false,
            tlsCertificateSHA256: session.tlsCertificateSHA256,
            tlsIdentityVersion: session.tlsIdentityVersion,
            transferGeneration: session.transferGeneration,
            secureTransferV1: true
        )
        assert(
            RemoteDeviceDebugSessionPolicy.hasSameAuthorizationIdentity(
                refreshedSession,
                as: session
            ),
            "non-secret network status refreshes retain the debug authorization"
        )
        let replacedSession = DeviceTransferSession(
            mode: .debug,
            baseURL: session.baseURL,
            accessPointSSID: session.accessPointSSID,
            sessionToken: String(repeating: "c", count: 32),
            tlsCertificateSHA256: session.tlsCertificateSHA256,
            tlsIdentityVersion: session.tlsIdentityVersion,
            transferGeneration: session.transferGeneration,
            secureTransferV1: true
        )
        assert(
            !RemoteDeviceDebugSessionPolicy.hasSameAuthorizationIdentity(
                replacedSession,
                as: session
            ),
            "a replaced transfer token invalidates the open debug console"
        )

        let shortEndpointManager = BLEManager()
        shortEndpointManager.isConnected = true
        shortEndpointManager.isNavigationReady = true
        var shortEndpointPackets: [Data] = []
        shortEndpointManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 20,
                canSend: { true },
                write: { shortEndpointPackets.append($0) }
            )
        )
        assert(!shortEndpointManager.requestDeviceTransferMode(
            .debug,
            remoteDebugLANCredentials: credentials
        ), "LAN credentials that exceed the negotiated fallback endpoint are rejected")
        assert(shortEndpointPackets.isEmpty,
               "oversized LAN credential commands are never queued")

        let diagnosticsManager = BLEManager()
        diagnosticsManager.isConnected = true
        diagnosticsManager.isNavigationReady = true
        let diagnosticsCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 0x30, 0])
        assert(diagnosticsManager.handleDeviceCapabilitiesNotification(
            diagnosticsCapabilities
        ), "diagnostics capture fixture negotiates CAP2 bit 20")
        var diagnosticsPackets: [Data] = []
        diagnosticsManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 80,
                canSend: { true },
                write: { diagnosticsPackets.append($0) }
            )
        )
        let captureID = UUID(
            uuidString: "01234567-89ab-cdef-0123-456789abcdef"
        )!
        assert(diagnosticsManager.sendDiagnosticsCaptureBinding(
            captureID,
            detailed: true
        ), "the emitted detailed mode should queue explicitly")
        assert(diagnosticsManager.sendDiagnosticsCaptureBinding(
            captureID,
            detailed: false
        ), "the emitted standard mode should queue explicitly")
        assertEqual(
            String(data: diagnosticsPackets[0], encoding: .utf8),
            "DTRNcapture|1|detailed|01234567-89ab-cdef-0123-456789abcdef",
            "the @Published willSet callback cannot invert detailed mode"
        )
        assertEqual(
            String(data: diagnosticsPackets[1], encoding: .utf8),
            "DTRNcapture|1|standard|01234567-89ab-cdef-0123-456789abcdef",
            "ending detailed capture explicitly rebinds standard mode"
        )

        let standardOnlyManager = BLEManager()
        standardOnlyManager.isConnected = true
        standardOnlyManager.isNavigationReady = true
        let standardOnlyCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 0x10, 0])
        _ = standardOnlyManager.handleDeviceCapabilitiesNotification(
            standardOnlyCapabilities
        )
        var standardOnlyPackets: [Data] = []
        standardOnlyManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 80,
                canSend: { true },
                write: { standardOnlyPackets.append($0) }
            )
        )
        assert(standardOnlyManager.sendDiagnosticsCaptureBinding(
            captureID,
            detailed: true
        ), "standard-only firmware still receives capture correlation")
        assertEqual(
            String(data: standardOnlyPackets[0], encoding: .utf8),
            "DTRNcapture|1|standard|01234567-89ab-cdef-0123-456789abcdef",
            "production diagnostics downgrade unsupported detailed binding"
        )
        _ = standardOnlyManager.handleDeviceCapabilitiesNotification(
            diagnosticsCapabilities
        )
        assertEqual(
            String(data: standardOnlyPackets.last ?? Data(), encoding: .utf8),
            "DTRNcapture|1|detailed|01234567-89ab-cdef-0123-456789abcdef",
            "a later detailed-capable reconnect restores the requested mode"
        )

        let disconnectedManager = BLEManager()
        let endedCaptureID = UUID(
            uuidString: "fedcba98-7654-3210-fedc-ba9876543210"
        )!
        assert(!disconnectedManager.sendDiagnosticsCaptureBinding(
            endedCaptureID,
            detailed: false
        ), "a disconnected binding is retained even though it cannot queue")
        var reconnectedPackets: [Data] = []
        disconnectedManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 80,
                canSend: { true },
                write: { reconnectedPackets.append($0) }
            )
        )
        disconnectedManager.isConnected = true
        disconnectedManager.isNavigationReady = true
        _ = disconnectedManager.handleDeviceCapabilitiesNotification(
            diagnosticsCapabilities
        )
        let reconnectedCapturePacket = reconnectedPackets.first {
            String(data: $0, encoding: .utf8)?.hasPrefix("DTRNcapture|") == true
        }
        assertEqual(
            String(data: reconnectedCapturePacket ?? Data(), encoding: .utf8),
            "DTRNcapture|1|standard|fedcba98-7654-3210-fedc-ba9876543210",
            "reconnect sends the capture that rotated while capabilities were unavailable"
        )
    }

    static func testBLEManagerSuppressesOptionalWritesDuringFirmwareMaintenance() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 96,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let status = """
        {"enabled":false,"mode":"","maintenance":{"supported":true,"active":true,"stage":"awaiting_authentication","correlation":42}}
        """
        assert(manager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(status.utf8)
        ), "maintenance status should be consumed")

        assert(!manager.sendNavigationData("2|120|Turn left"),
               "optional navigation is rejected while maintenance is active")
        assert(manager.requestDeviceTransferStatus(),
               "maintenance status traffic remains available")
        assertEqual(sentPackets, [Data("DSTS".utf8)],
                    "only the required transfer-control write reaches BLE")
    }

    static func testBLEManagerSuppressesOrdinaryWritesWhileMaintenanceReconnectIsExpected() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 96,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.beginFirmwareMaintenanceReconnect()
        assert(manager.firmwareMaintenanceReconnectExpected,
               "maintenance reconnect expectation survives the reboot boundary")
        assert(!manager.sendNavigationData("2|120|Turn left"),
               "ordinary navigation is rejected before maintenance status arrives")
        assert(!manager.requestMapTransferStatus(),
               "unrelated map transfer polling is rejected during firmware maintenance")
        assert(manager.requestDeviceTransferStatus(
            forMaintenanceReconnect: true
        ), "maintenance status traffic remains available during reconnect")
        assertEqual(sentPackets, [Data("DSTS".utf8)],
                    "only transfer control reaches BLE while reconnect is pending")

        manager.endFirmwareMaintenanceReconnect()
        assert(!manager.firmwareMaintenanceReconnectExpected,
               "ending maintenance restores the normal connection policy")
    }

    @MainActor
    static func testDeviceDiagnosticsTransferPolicy() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let manager = DeviceDiagnosticsTransferManager(
            sessionConfiguration: { configuration }
        )
        let session = DeviceTransferSession(
            mode: .diagnostics,
            baseURL: URL(string: "https://diagnostics.test")!,
            accessPointSSID: nil,
            sessionToken: "test-token",
            tlsCertificateSHA256: String(repeating: "a", count: 64),
            tlsIdentityVersion: 1,
            transferGeneration: 1,
            secureTransferV1: true
        )
        defer { OfflineMapTestURLProtocol.reset() }

        OfflineMapTestURLProtocol.configure { _ in (200, Data([1, 2, 3])) }
        do {
            let data = try await manager.requestForTesting(
                session: session,
                path: "device-diagnostics/v1/index",
                maximumBytes: 4
            )
            assertEqual(data, Data([1, 2, 3]),
                        "diagnostics requests stream a bounded response")
        } catch {
            assert(false, "bounded diagnostics response succeeds: \(error)")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (200, Data([1, 2, 3, 4, 5]))
        }
        do {
            _ = try await manager.requestForTesting(
                session: session,
                path: "device-diagnostics/v1/chunks/1/1",
                maximumBytes: 4
            )
            assert(false, "oversized diagnostics stream is rejected")
        } catch DeviceDiagnosticsTransferError.oversizedChunk {
            // Expected.
        } catch {
            assert(false, "oversized diagnostics stream has the right error")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (500, Data("""
            {"ok":false,"error":{"code":"diagnostics_index_unreadable","message":"chunk could not be read"}}
            """.utf8))
        }
        do {
            _ = try await manager.requestForTesting(
                session: session,
                path: "device-diagnostics/v1/index",
                maximumBytes: 4096
            )
            assert(false, "structured diagnostics rejection is thrown")
        } catch DeviceDiagnosticsTransferError.deviceRejected(
            let code, let message
        ) {
            assertEqual(code, "diagnostics_index_unreadable",
                        "HTTP diagnostics errors retain their firmware code")
            assert(message.contains("chunk could not be read"),
                   "HTTP diagnostics errors retain their firmware detail")
        } catch {
            assert(false, "structured diagnostics rejection has the right error")
        }

        let validIndex = Data("""
        {"schema":1,"source":"firmware","bootSequence":1,"activeChunk":2,"stats":{"enqueued":2,"written":1,"dropped":0,"storageErrors":0},"chunks":[{"bootSequence":1,"chunk":1,"bytes":3,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
        """.utf8)
        assert(
            DeviceDiagnosticsTransferManager.indexShapeIsValidForTesting(
                validIndex
            ),
            "known diagnostics index shape is accepted"
        )
        let unsafeIndex = Data("""
        {"schema":1,"source":"firmware","bootSequence":1,"activeChunk":2,"stats":{"enqueued":2,"written":1,"dropped":0,"storageErrors":0},"chunks":[],"password":"secret123"}
        """.utf8)
        assert(
            !DeviceDiagnosticsTransferManager.indexShapeIsValidForTesting(
                unsafeIndex
            ),
            "unknown credential-shaped index fields are rejected"
        )

        let validStream = Data("""
        {"schema":1,"source":"firmware","sequence":7,"level":"info","category":"boot","event":"ready","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4"}}
        {"schema":1,"source":"firmware","sequence":8,"level":"info","category":"storage","event":"mounted","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4","available":true}}
        """.utf8)
        let validation =
            DeviceDiagnosticsTransferManager.validateJSONLForTesting(
                validStream
            )
        assertEqual(validation?.first, 7,
                    "diagnostics validator retains first sequence")
        assertEqual(validation?.last, 8,
                    "diagnostics validator retains last sequence")
        let validHash = SHA256.hash(data: validStream).map {
            String(format: "%02x", $0)
        }.joined()
        assert(
            DeviceDiagnosticsTransferManager.cachedChunkIsReusableForTesting(
                validStream,
                expectedBytes: validStream.count,
                expectedSHA256: validHash
            ),
            "a complete cached chunk can resume without another HTTP fetch"
        )
        assert(
            !DeviceDiagnosticsTransferManager.cachedChunkIsReusableForTesting(
                Data(validStream.dropLast()),
                expectedBytes: validStream.count,
                expectedSHA256: validHash
            ),
            "a truncated cache entry cannot bypass resume validation"
        )
        let laterStream = Data("""
        {"schema":1,"source":"firmware","sequence":9,"level":"info","category":"boot","event":"later","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4"}}
        """.utf8)
        let otherBootStream = Data("""
        {"schema":1,"source":"firmware","sequence":1,"level":"info","category":"boot","event":"other","fields":{"bootSequence":2,"firmwareFingerprint":"A1B2C3D4"}}
        """.utf8)
        assert(
            DeviceDiagnosticsTransferManager.streamsAreOrderedForTesting([
                (1, validStream), (1, laterStream), (2, otherBootStream),
            ]),
            "sequence tracking is monotonic per boot and independent across boots"
        )
        assert(
            !DeviceDiagnosticsTransferManager.streamsAreOrderedForTesting([
                (1, laterStream), (1, validStream),
            ]),
            "cached or downloaded chunks cannot move a boot sequence backward"
        )
        let replacedFirmwareStream = Data("""
        {"schema":1,"source":"firmware","sequence":10,"level":"info","category":"boot","event":"replaced","fields":{"bootSequence":1,"firmwareFingerprint":"B1C2D3E4"}}
        """.utf8)
        assert(
            !DeviceDiagnosticsTransferManager.streamsAreOrderedForTesting([
                (1, validStream), (1, replacedFirmwareStream),
            ]),
            "chunks from one boot cannot silently change firmware identity"
        )
        let truncatedFirstStream = validStream +
            Data("\n{\"schema\":".utf8)
        assert(
            DeviceDiagnosticsTransferManager.validateJSONLForTesting(
                truncatedFirstStream
            ) != nil,
            "one truncated crash-tail record is recoverable on a final chunk"
        )
        assert(
            !DeviceDiagnosticsTransferManager.streamsAreOrderedForTesting([
                (1, truncatedFirstStream), (1, laterStream),
            ]),
            "a recoverable tail is valid only on the final chunk of a boot"
        )
        let blankMiddleLine = Data("""
        {"schema":1,"source":"firmware","sequence":7,"level":"info","category":"boot","event":"ready","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4"}}

        {"schema":1,"source":"firmware","sequence":8,"level":"info","category":"boot","event":"later","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4"}}
        """.utf8)
        assert(
            DeviceDiagnosticsTransferManager.validateJSONLForTesting(
                blankMiddleLine
            ) == nil,
            "blank middle records cannot pass iOS and later fail Mac validation"
        )
        let booleanNumberStream = Data("""
        {"schema":1,"source":"firmware","sequence":9,"level":"info","category":"boot","event":"invalid","fields":{"bootSequence":true,"firmwareFingerprint":"A1B2C3D4"}}

        """.utf8)
        assert(
            DeviceDiagnosticsTransferManager.validateJSONLForTesting(
                booleanNumberStream
            ) == nil,
            "JSON booleans cannot impersonate firmware number fields"
        )
        let numericBooleanStream = Data("""
        {"schema":1,"source":"firmware","sequence":10,"level":"info","category":"storage","event":"invalid","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4","available":1}}

        """.utf8)
        assert(
            DeviceDiagnosticsTransferManager.validateJSONLForTesting(
                numericBooleanStream
            ) == nil,
            "JSON numbers cannot impersonate firmware boolean fields"
        )
    }

    static func testDeviceDiagnosticsInterruptedChunk() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-diagnostics-interrupted-\(UUID().uuidString)")
        let defaultsSuite = "DeviceDiagnosticsInterrupted.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer {
            OfflineMapTestURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        let recorder = RideDiagnosticsRecorder(rootURL: root, userDefaults: defaults)
        let bleManager = BLEManager()
        let deviceID = "01234567-89ab-cdef-0123-456789abcdef"
        bleManager.setConnectedDeviceIDForTesting(deviceID)
        let fullChunk = Data(repeating: 0x41, count: 7130)
        let digest = SHA256.hash(data: fullChunk).map {
            String(format: "%02x", $0)
        }.joined()
        let index = Data("""
        {"schema":1,"source":"firmware","bootSequence":1,"activeChunk":2,"stats":{"enqueued":1,"written":1,"dropped":0,"storageErrors":0},"chunks":[{"bootSequence":1,"chunk":1,"bytes":7130,"sha256":"\(digest)"}]}
        """.utf8)
        let session = DeviceTransferSession(
            mode: .diagnostics,
            baseURL: URL(string: "https://diagnostics.test")!,
            accessPointSSID: nil,
            sessionToken: "test-token",
            tlsCertificateSHA256: String(repeating: "a", count: 64),
            tlsIdentityVersion: 1,
            transferGeneration: 1,
            secureTransferV1: true
        )
        let controller = TestDeviceDiagnosticsSessionController(session: session)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        OfflineMapTestURLProtocol.configure { request in
            switch request.url?.path {
            case "/device-diagnostics/v1/index": return (200, index)
            case "/device-diagnostics/v1/session/exit":
                return (200, Data("{\"ok\":true}".utf8))
            default: return (404, Data())
            }
        }
        OfflineMapTestURLProtocol.interruptResponse(
            path: "/device-diagnostics/v1/chunks/1/1",
            prefix: Data(fullChunk.prefix(4096)),
            expectedBytes: fullChunk.count
        )
        let manager = DeviceDiagnosticsTransferManager(
            transferManager: controller,
            sessionConfiguration: { configuration }
        )
        do {
            _ = try await manager.downloadDeviceLogs(
                bleManager: bleManager,
                recorder: recorder,
                status: { _ in }
            )
            assert(false, "interrupted diagnostics chunk must fail")
        } catch DeviceDiagnosticsTransferError.transportInterrupted(
            let received, let expected, let code
        ) {
            assertEqual(received, 4096, "transport error retains the exact prefix")
            assertEqual(expected, 7130, "transport error retains declared length")
            assertEqual(code, URLError.networkConnectionLost.rawValue,
                        "transport error retains the URL error")
        } catch {
            assert(false, "interrupted diagnostics has a typed error: \(error)")
        }
        let deviceDigest = recorder.deviceDigest(for: deviceID)
        assertEqual(
            recorder.importedDeviceChunkData(
                deviceDigest: deviceDigest,
                bootSequence: 1,
                chunk: 1,
                sha256: digest
            ),
            nil,
            "an interrupted prefix is never imported as a chunk"
        )
    }

    @MainActor
    static func testDeviceDiagnosticsFailsFastOnFirmwareRejection() async {
        let bleManager = BLEManager()
        let initialRevision = bleManager.deviceTransferStatusRevision
        let manager = DeviceTransferManager()
        let started = Date()
        let wait = Task {
            try await manager.waitForDiagnosticsSessionForTesting(
                bleManager: bleManager,
                afterRevision: initialRevision,
                attemptCount: 32
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let rejectedStatus = """
        {"configured":true,"enabled":false,"mode":"","lastError":{"code":"diagnostics_writable_probe_failed","message":"probe failed"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(rejectedStatus.utf8)
        )
        do {
            _ = try await wait.value
            assert(false, "firmware diagnostics rejection must fail entry")
        } catch RemoteDeviceDebugError.rejected(let code, let message) {
            assertEqual(code, "diagnostics_writable_probe_failed",
                        "diagnostics handshake retains the firmware code")
            assert(message.contains("diagnostics_writable_probe_failed"),
                   "diagnostics rejection presented to the user includes its code")
            assert(Date().timeIntervalSince(started) < 1.5,
                   "fresh firmware rejection bypasses the full polling window")
        } catch {
            assert(false, "firmware diagnostics rejection has the right error")
        }
    }

    @MainActor
    static func testDeviceDiagnosticsRecordsEntryFailure() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "device-diagnostics-entry-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsSuite =
            "DeviceDiagnosticsEntryFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recorder = RideDiagnosticsRecorder(
            rootURL: root,
            userDefaults: defaults
        )
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting(
            "01234567-89ab-cdef-0123-456789abcdef"
        )
        let session = DeviceTransferSession(
            mode: .diagnostics,
            baseURL: URL(string: "https://diagnostics.test")!,
            accessPointSSID: nil,
            sessionToken: "unused-token",
            tlsCertificateSHA256: String(repeating: "a", count: 64),
            tlsIdentityVersion: 1,
            transferGeneration: 1,
            secureTransferV1: true
        )
        let sessionController = TestDeviceDiagnosticsSessionController(
            session: session,
            enterError: RemoteDeviceDebugError.rejected(
                code: "diagnostics_seal_timeout",
                message: "seal timed out [diagnostics_seal_timeout]"
            )
        )
        let manager = DeviceDiagnosticsTransferManager(
            transferManager: sessionController
        )
        do {
            _ = try await manager.downloadDeviceLogs(
                bleManager: bleManager,
                recorder: recorder,
                status: { _ in }
            )
            assert(false, "diagnostics entry rejection must fail download")
        } catch RemoteDeviceDebugError.rejected(let code, _) {
            assertEqual(code, "diagnostics_seal_timeout",
                        "entry rejection reaches the diagnostics caller")
        } catch {
            assert(false, "diagnostics entry failure has the right error")
        }
        recorder.flush()
        assertEqual(sessionController.enterCount, 1,
                    "entry failure performs one diagnostics entry attempt")
        assertEqual(sessionController.exitCount, 0,
                    "entry failure does not exit a session that never opened")

        var failureEvent: RideDiagnosticEvent?
        let appDirectory = root
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(
                recorder.processId.uuidString.lowercased(),
                isDirectory: true
            )
        let eventFiles = (try? FileManager.default.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for fileURL in eventFiles where fileURL.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            for line in text.split(separator: "\n") {
                guard let event = try? JSONDecoder().decode(
                    RideDiagnosticEvent.self,
                    from: Data(line.utf8)
                ), event.event == "diagnostics_download_failed" else {
                    continue
                }
                failureEvent = event
            }
        }
        assertEqual(failureEvent?.fields["reason"], "entry_failed",
                    "iOS records that diagnostics failed during entry")
        assertEqual(
            failureEvent?.fields["code"],
            "diagnostics_seal_timeout",
            "iOS records the exact firmware diagnostics rejection code"
        )
    }

    @MainActor
    static func testDeviceDiagnosticsDownloadEndToEnd() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "device-diagnostics-e2e-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            OfflineMapTestURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let defaultsSuite =
            "DeviceDiagnosticsDownloadEndToEnd.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recorder = RideDiagnosticsRecorder(
            rootURL: root,
            userDefaults: defaults
        )
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting(
            "01234567-89ab-cdef-0123-456789abcdef"
        )
        let stream = Data("""
        {"schema":1,"source":"firmware","sequence":7,"level":"info","category":"boot","event":"ready","fields":{"bootSequence":1,"firmwareFingerprint":"A1B2C3D4"}}
        """.utf8) + Data("\n{\"schema\":1,\"source\":\"firmware\"".utf8)
        let digest = SHA256.hash(data: stream).map {
            String(format: "%02x", $0)
        }.joined()
        let index = Data("""
        {"schema":1,"source":"firmware","bootSequence":1,"activeChunk":2,"stats":{"enqueued":1,"written":1,"dropped":0,"storageErrors":0},"chunks":[{"bootSequence":1,"chunk":1,"bytes":\(stream.count),"sha256":"\(digest)"}]}
        """.utf8)
        let session = DeviceTransferSession(
            mode: .diagnostics,
            baseURL: URL(string: "https://diagnostics.test")!,
            accessPointSSID: nil,
            sessionToken: "test-token",
            tlsCertificateSHA256: String(repeating: "a", count: 64),
            tlsIdentityVersion: 1,
            transferGeneration: 1,
            secureTransferV1: true
        )
        let sessionController = TestDeviceDiagnosticsSessionController(
            session: session
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/device-diagnostics/v1/index"):
                return (200, index)
            case ("GET", "/device-diagnostics/v1/chunks/1/1"):
                return (200, stream)
            case ("POST", "/device-diagnostics/v1/session/exit"):
                return (200, Data("{\"ok\":true}".utf8))
            default:
                return (404, Data())
            }
        }
        let manager = DeviceDiagnosticsTransferManager(
            transferManager: sessionController,
            sessionConfiguration: { configuration }
        )
        var statuses: [String] = []
        do {
            let imported = try await manager.downloadDeviceLogs(
                bleManager: bleManager,
                recorder: recorder,
                status: { statuses.append($0) }
            )
            assertEqual(imported, 1,
                        "end-to-end diagnostics imports one new chunk")
            assertEqual(sessionController.enterCount, 1,
                        "end-to-end diagnostics enters one session")
            assertEqual(sessionController.exitCount, 1,
                        "end-to-end diagnostics exits one session")
            let deviceDigest = recorder.deviceDigest(
                for: "01234567-89ab-cdef-0123-456789abcdef"
            )
            assertEqual(
                recorder.importedDeviceChunkData(
                    deviceDigest: deviceDigest,
                    bootSequence: 1,
                    chunk: 1,
                    sha256: digest
                ),
                stream,
                "end-to-end diagnostics preserves the verified crash-tail chunk"
            )
            let requests = OfflineMapTestURLProtocol.requests()
            assertEqual(
                requests.compactMap { $0.url?.path },
                [
                    "/device-diagnostics/v1/index",
                    "/device-diagnostics/v1/chunks/1/1",
                    "/device-diagnostics/v1/session/exit",
                ],
                "end-to-end diagnostics performs index, chunk, and exit requests"
            )
            assert(
                requests.allSatisfy {
                    $0.value(
                        forHTTPHeaderField: "X-BikeComputer-Transfer-Token"
                    ) == "test-token"
                },
                "end-to-end diagnostics authenticates every HTTP request"
            )
            assertEqual(
                requests.last?.value(forHTTPHeaderField: "Content-Length"),
                "0",
                "end-to-end diagnostics sends an empty authenticated exit"
            )
            assert(statuses.contains("test diagnostics session ready"),
                   "end-to-end diagnostics reports session readiness")
        } catch {
            assert(false, "end-to-end diagnostics succeeds: \(error)")
        }
    }

    static func testDeviceTransferManagerWaitsForFreshDebugToken() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        _ = bleManager.handleDeviceCapabilitiesNotification(cap2)
        assert(bleManager.supportsRemoteDeviceDebug,
               "remote-debug handshake fixture negotiates CAP2 bit 16")

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))
        // Cached credentials are stale, but no live foreign mode is claimed.
        // Active unowned modes are tested separately and must be refused.
        let staleStatus = """
        {"configured":true,"enabled":false,"mode":"","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","sessionToken":"stale-token"}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(staleStatus.utf8)
        )
        let staleRevision = bleManager.deviceTransferStatusRevision

        let task = Task {
            try await manager.enterRemoteDebug(
                bleManager: bleManager,
                status: { _ in }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(String(data: sentPackets.first ?? Data(), encoding: .utf8),
                    "DTRNenter|debug",
                    "remote-debug handshake starts with the dedicated mode")
        try? await Task.sleep(nanoseconds: 25_000_000)
        let tlsFingerprint = String(repeating: "a", count: 64)
        let freshStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"https://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","apPassphrase":"0123456789abcdef01234567","networkTransport":"hotspot","sessionToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tls":{"identityVersion":1,"certificateSha256":"\(tlsFingerprint)"},"transferGeneration":2,"capabilities":{"secureTransferV1":true,"signedMapStreamV1":true,"legacyArchivePolicy":"disabled"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(freshStatus.utf8)
        )
        assert(bleManager.deviceTransferStatusRevision != staleRevision,
               "fresh debug status advances the credential revision")
        do {
            let session = try await task.value
            assertEqual(session.mode, .debug,
                        "fresh remote-debug handshake returns debug mode")
            assertEqual(session.sessionToken, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "stale token is never returned")
        } catch {
            assert(false, "fresh remote-debug handshake should succeed: \(error)")
        }
    }

    static func testDeviceTransferServerProbePolicy() {
        let configuration =
            DeviceTransferServerProbePolicy.makeSessionConfiguration()
        assertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData,
            "local device probes bypass URL caches"
        )
        assert(configuration.urlCache == nil,
               "local device probes do not install a URL cache")
        assert(configuration.httpCookieStorage == nil,
               "local device probes do not inherit cookie storage")
        assert(configuration.connectionProxyDictionary?.isEmpty == true,
               "local device probes explicitly bypass configured proxies")
        assert(!configuration.allowsCellularAccess,
               "local device probes stay on the Wi-Fi route")
        assert(!configuration.waitsForConnectivity,
               "an exact accessory association starts the local request immediately")
        assertEqual(configuration.httpMaximumConnectionsPerHost, 1,
                    "the constrained accessory receives one connection at a time")
        assertEqual(
            configuration.timeoutIntervalForRequest,
            DeviceTransferServerProbePolicy.requestTimeout,
            "local device probe request timeout exceeds the firmware TLS budget"
        )
        assertEqual(
            configuration.timeoutIntervalForResource,
            DeviceTransferServerProbePolicy.resourceTimeout,
            "the complete local request remains bounded by the resource timeout"
        )
        assert(DeviceTransferServerProbePolicy.requestTimeout > 5,
               "iOS must not abandon a handshake before the firmware timeout")
        assertEqual(DeviceTransferServerProbePolicy.maximumAttemptCount, 3,
                    "pinned preflight attempts remain tightly bounded")
        assertEqual(
            DeviceTransferServerProbePolicy.retryDelaysNanoseconds.count,
            DeviceTransferServerProbePolicy.maximumAttemptCount,
            "every bounded probe attempt has an explicit delay"
        )
        assertEqual(DeviceTransferServerProbePolicy.absoluteTimeout, 20,
                    "the complete pinned preflight has one absolute deadline")

        assertEqual(
            DeviceTransferNetworkObservation.classify(
                currentSSID: "BikeComputer-Transfer",
                expectedSSID: "BikeComputer-Transfer"
            ),
            .target,
            "an exact current SSID confirms accessory association"
        )
        assertEqual(
            DeviceTransferNetworkObservation.classify(
                currentSSID: "home-network",
                expectedSSID: "BikeComputer-Transfer"
            ),
            .other,
            "a different current SSID disproves accessory association"
        )
        assertEqual(
            DeviceTransferNetworkObservation.classify(
                currentSSID: nil,
                expectedSSID: "BikeComputer-Transfer"
            ),
            .unavailable,
            "missing Wi-Fi information remains unknown rather than mismatched"
        )

        let timeout = DeviceTransferServerProbeResult(
            outcome: .transportError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut
            ),
            diagnostics: DeviceTransferPinnedSessionSnapshot()
        )
        assert(timeout.shouldRetry,
               "a pre-pin transport timeout receives a bounded retry")
        assertEqual(timeout.diagnosticCode, "network_not_started",
                    "missing connection metrics retain the earliest known layer")

        let secureConnectionFailure = DeviceTransferServerProbeResult(
            outcome: .transportError(
                domain: NSURLErrorDomain,
                code: NSURLErrorSecureConnectionFailed
            ),
            diagnostics: DeviceTransferPinnedSessionSnapshot()
        )
        assertEqual(
            secureConnectionFailure.diagnosticCode,
            "tls_secure_connection_failed_before_challenge",
            "a secure-connection error is not mislabeled as an unstarted network"
        )
        let underlyingDiagnostics = DeviceTransferPinnedSessionDiagnostics()
        underlyingDiagnostics.record(error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorSecureConnectionFailed,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: "kCFErrorDomainCFNetwork",
                    code: -9806
                ),
            ]
        ))
        assertEqual(
            underlyingDiagnostics.snapshot().underlyingErrorDomain,
            "kCFErrorDomainCFNetwork",
            "only the underlying transport error domain is retained"
        )
        assertEqual(
            underlyingDiagnostics.snapshot().underlyingErrorCode,
            -9806,
            "only the underlying transport error code is retained"
        )

        let connectivityWait = DeviceTransferServerProbeResult(
            outcome: .transportError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut
            ),
            diagnostics: DeviceTransferPinnedSessionSnapshot(
                waitedForConnectivity: true
            )
        )
        assertEqual(
            connectivityWait.diagnosticCode,
            "connectivity_wait_without_network_load",
            "a connectivity wait remains distinct from a started network load"
        )

        let pinMismatch = DeviceTransferServerProbeResult(
            outcome: .transportError(
                domain: NSURLErrorDomain,
                code: NSURLErrorServerCertificateUntrusted
            ),
            diagnostics: DeviceTransferPinnedSessionSnapshot(
                tlsChallengeOutcome: .certificateMismatch
            )
        )
        assert(!pinMismatch.shouldRetry,
               "a BLE-pin mismatch fails closed without association churn")
        assertEqual(pinMismatch.diagnosticCode, "tls_certificate_mismatch",
                    "pin failures retain their security layer")

        let unauthorized = DeviceTransferServerProbeResult(
            outcome: .httpStatus(401),
            diagnostics: DeviceTransferPinnedSessionSnapshot(
                tlsChallengeOutcome: .accepted,
                connectStarted: true,
                connectCompleted: true,
                tlsStarted: true,
                tlsCompleted: true,
                remoteEndpointMatched: true
            )
        )
        assert(!unauthorized.shouldRetry,
               "an authenticated HTTP response never triggers Wi-Fi reapply")
        assertEqual(unauthorized.diagnosticCode, "http_401",
                    "HTTP authorization failures stay distinct from reachability")
        let safeFields = unauthorized.diagnostics.diagnosticFields
        assertEqual(safeFields["tlsChallenge"], "accepted",
                    "safe diagnostics retain the pin outcome")
        assertEqual(safeFields["remoteEndpointMatched"], "true",
                    "safe diagnostics retain only endpoint equality")
        assert(safeFields["certificateSha256"] == nil &&
               safeFields["sessionToken"] == nil &&
               safeFields["hotspotPassphrase"] == nil,
               "credentials and certificate material are never diagnostic fields")

        let completeSafeFields = DeviceTransferPinnedSessionSnapshot(
            tlsChallengeOutcome: .accepted,
            waitedForConnectivity: true,
            connectStarted: true,
            connectCompleted: true,
            tlsStarted: true,
            tlsCompleted: true,
            connectDurationMilliseconds: 12,
            tlsDurationMilliseconds: 34,
            remoteEndpointMatched: true,
            localAddressInAccessorySubnet: true,
            networkProtocolName: "http/1.1",
            reusedConnection: false,
            proxyConnection: false,
            underlyingErrorDomain: "kCFErrorDomainCFNetwork",
            underlyingErrorCode: -9806
        ).diagnosticFields
        assert(
            completeSafeFields.keys.allSatisfy(
                RideDiagnosticsFieldPolicy.isAllowed
            ),
            "the privacy allowlist must preserve every non-secret probe field"
        )
        let transferEnvelopeFields = [
            "attempt", "networkObservation", "outcome", "httpStatus",
            "errorDomain", "errorCode", "applyResult", "applyErrorDomain",
            "applyErrorCode",
        ]
        assert(
            transferEnvelopeFields.allSatisfy(
                RideDiagnosticsFieldPolicy.isAllowed
            ),
            "the privacy allowlist must preserve transfer envelope fields"
        )

        assert(
            OfflineMapPlatformError.transferWiFiJoinFailed(
                "BikeComputer-Transfer",
                "association was not confirmed"
            ).errorDescription?.hasPrefix("Could not join device Wi-Fi") == true,
            "association failures remain distinct from endpoint failures"
        )
        assert(
            OfflineMapPlatformError.transferServerProbeFailed(
                "BikeComputer-Transfer",
                "pinned HTTPS returned HTTP 401"
            ).errorDescription?.hasPrefix("Device transfer over") == true,
            "pinned endpoint failures retain their own classification"
        )

        let entitlementURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                "ios-app/BikeComputer/BikeComputer/BikeComputer.entitlements"
            )
        let entitlementData = try! Data(contentsOf: entitlementURL)
        let entitlements = try! PropertyListSerialization.propertyList(
            from: entitlementData,
            options: [],
            format: nil
        ) as! [String: Any]
        assertEqual(
            entitlements["com.apple.developer.networking.wifi-info"] as? Bool,
            true,
            "the signed app can distinguish the current accessory Wi-Fi"
        )
    }

    static func testDeviceTransferManagerKeepsConfirmedLANDebugSession() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        _ = bleManager.handleDeviceCapabilitiesNotification(cap2)

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))
        let credentials = RemoteDebugLANCredentials(
            ssid: "Home Wi-Fi",
            password: "session-secret"
        )!
        var statuses: [String] = []
        let task = Task {
            try await manager.enterRemoteDebug(
                bleManager: bleManager,
                lanCredentials: credentials,
                status: { statuses.append($0) }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let tlsFingerprint = String(repeating: "b", count: 64)
        let lanStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"https://192.168.31.195:8080","networkTransport":"lan","networkSsid":"Home Wi-Fi","sessionToken":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tls":{"identityVersion":1,"certificateSha256":"\(tlsFingerprint)"},"transferGeneration":3,"capabilities":{"secureTransferV1":true,"signedMapStreamV1":true,"legacyArchivePolicy":"disabled"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(lanStatus.utf8)
        )

        do {
            let session = try await task.value
            assertEqual(session.networkTransport, "lan",
                        "firmware-confirmed LAN debug remains on LAN")
            assertEqual(session.baseURL.absoluteString,
                        "https://192.168.31.195:8080",
                        "LAN debug preserves the firmware endpoint")
            assert(statuses.contains("local Wi-Fi ready"),
                   "LAN debug reports browser readiness without a phone probe")
            assert(!sentPackets.contains(Data("DTRNexit".utf8)),
                   "phone reachability never tears down a confirmed LAN session")
        } catch {
            assert(false, "confirmed LAN debug should remain active: \(error)")
        }
    }

    static func testDeviceTransferManagerConfirmsDebugExit() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        _ = bleManager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) + Data([1, 0, 0, 1, 0])
        )
        let entry = Task {
            try await manager.enterRemoteDebug(bleManager: bleManager, status: { _ in })
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let fingerprint = String(repeating: "a", count: 64)
        let activeStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"https://192.168.31.195:8080","networkTransport":"lan","sessionToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tls":{"identityVersion":1,"certificateSha256":"\(fingerprint)"},"transferGeneration":1,"capabilities":{"secureTransferV1":true}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(activeStatus.utf8)
        )
        do { _ = try await entry.value }
        catch { assert(false, "debug exit fixture acquires ownership first: \(error)") }
        sentPackets.removeAll()

        let task = Task {
            try await manager.exitRemoteDebug(
                bleManager: bleManager
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(String(data: sentPackets.first ?? Data(), encoding: .utf8),
                    "DTRNexit",
                    "debug exit starts with an authenticated exit command")
        let stoppedStatus = """
        {"configured":true,"enabled":false,"mode":"","firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(stoppedStatus.utf8)
        )
        do {
            try await task.value
            assert(bleManager.deviceTransferSessionToken == nil,
                   "confirmed debug exit clears the session token")
        } catch {
            assert(false, "fresh empty status should confirm debug exit: \(error)")
        }
    }

    static func testDeviceTransferManagerCompensatesCancelledDebugEntry() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        _ = bleManager.handleDeviceCapabilitiesNotification(cap2)
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let task = Task {
            try await manager.enterRemoteDebug(
                bleManager: bleManager,
                status: { _ in }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        _ = try? await task.value

        assertEqual(String(data: sentPackets.first ?? Data(), encoding: .utf8),
                    "DTRNenter|debug",
                    "cancelled debug entry was queued before cancellation")
        assert(sentPackets.contains(Data("DTRNexit".utf8)),
               "post-enqueue cancellation queues a compensating debug exit")
    }

    @MainActor
    static func testFirmwareTransferSurvivesNetworkStartupReconnect() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        bleManager.setConnectedDeviceIDForTesting("device-a")

        let maintenanceStatus = """
        {"configured":true,"enabled":false,"mode":"","maintenance":{"supported":true,"active":true,"stage":"awaiting_authentication","correlation":42}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(maintenanceStatus.utf8)
        )

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 96,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let task = Task {
            try await manager.enterFirmwareTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(
            String(data: sentPackets.first ?? Data(), encoding: .utf8),
            "DTRNenter|firmware",
            "maintenance firmware entry uses the authenticated fallback"
        )

        bleManager.isConnected = false
        bleManager.isNavigationReady = false
        try? await Task.sleep(nanoseconds: 600_000_000)
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        for _ in 0..<100 where
            !sentPackets.dropFirst().contains(Data("DSTS".utf8)) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            sentPackets.dropFirst().contains(Data("DSTS".utf8)),
            "the first post-reconnect status request uses Navigation"
        )

        let tlsFingerprint = String(repeating: "c", count: 64)
        let readyStatus = """
        {"configured":true,"enabled":true,"mode":"firmware","baseUrl":"https://192.168.31.195:8080","networkTransport":"lan","networkSsid":"Home Wi-Fi","sessionToken":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tls":{"identityVersion":1,"certificateSha256":"\(tlsFingerprint)"},"transferGeneration":3,"capabilities":{"secureTransferV1":true},"maintenance":{"supported":true,"active":true,"stage":"ready","correlation":42}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(readyStatus.utf8)
        )

        do {
            let session = try await task.value
            assertEqual(session.mode, .firmware,
                        "firmware transfer survives the Wi-Fi startup reconnect")
            assertEqual(session.networkTransport, "lan",
                        "reconnected firmware transfer retains its network")
        } catch {
            assert(false, "firmware reconnect should complete: \(error)")
        }
    }

    @MainActor
    static func testFirmwareTransferSurfacesFreshRejectionAndExits() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true

        let staleStatus = """
        {"configured":true,"enabled":false,"mode":"","lastError":{"code":"old_error","message":"old failure","sequence":7}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(staleStatus.utf8)
        )

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let started = Date()
        let task = Task {
            try await manager.enterFirmwareTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(
            String(data: sentPackets.first ?? Data(), encoding: .utf8),
            "DTRNenter|firmware",
            "firmware entry starts with the authenticated enter command"
        )

        let rejectedStatus = """
        {"configured":true,"enabled":false,"mode":"","lastError":{"code":"http_worker","message":"could not start transfer HTTP worker","sequence":8}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(rejectedStatus.utf8)
        )

        do {
            _ = try await task.value
            assert(false, "firmware rejection must fail entry")
        } catch FirmwareUpdateError.deviceTransferRejected(
            let code,
            let message
        ) {
            assertEqual(code, "http_worker",
                        "firmware rejection retains the device error code")
            assertEqual(message, "could not start transfer HTTP worker",
                        "firmware rejection retains the device message")
            assert(Date().timeIntervalSince(started) < 1.5,
                   "fresh firmware rejection bypasses the polling timeout")
        } catch {
            assert(false, "firmware rejection has the right error: \(error)")
        }

        assert(sentPackets.contains(Data("DTRNexit".utf8)),
               "rejected firmware entry queues a compensating exit")
    }

    @MainActor
    static func testFirmwareTransferCancellationExits() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let task = Task {
            try await manager.enterFirmwareTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        _ = try? await task.value

        assertEqual(
            String(data: sentPackets.first ?? Data(), encoding: .utf8),
            "DTRNenter|firmware",
            "cancelled firmware entry was queued before cancellation"
        )
        assert(sentPackets.contains(Data("DTRNexit".utf8)),
               "post-enqueue firmware cancellation queues a compensating exit")
    }

    @MainActor
    static func testFirmwareMaintenancePreparationFlow() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 96,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let eligibility = Task {
            try await manager.requireFirmwareMaintenanceEligibility(
                bleManager: bleManager
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(String(data: sentPackets.first ?? Data(), encoding: .utf8),
                    "DSTS",
                    "maintenance eligibility starts with a fresh status")
        let eligibleStatus = """
        {"enabled":false,"mode":"","capabilities":{"firmwareMaintenanceV1":true},"maintenance":{"supported":true,"active":false,"stage":"normal","correlation":0},"firmware":{"otaEligible":true,"eligibilityCode":"eligible"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(eligibleStatus.utf8)
        )
        do {
            try await eligibility.value
        } catch {
            assert(false, "eligible maintenance firmware is accepted: \(error)")
        }

        sentPackets.removeAll()
        var waitingForMaintenanceReconnect = false
        let preparation = Task {
            try await manager.prepareFirmwareMaintenance(
                bleManager: bleManager,
                status: { message in
                    if message == "waiting for firmware maintenance" {
                        waitingForMaintenanceReconnect = true
                    }
                }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(String(data: sentPackets.first ?? Data(), encoding: .utf8),
                    "DTRNprepare|firmware",
                    "maintenance preparation uses its explicit control frame")
        let acceptedStatus = """
        {"enabled":false,"mode":"","capabilities":{"firmwareMaintenanceV1":true},"maintenance":{"supported":true,"active":false,"stage":"reboot_pending","correlation":42},"firmware":{"otaEligible":true,"eligibilityCode":"eligible"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(acceptedStatus.utf8)
        )
        bleManager.isNavigationReady = false
        // Keep the reboot-pending status available until the preparation task
        // captures its correlation. A fixed sleep can race the task on CI and
        // replace that status with the maintenance boot before it is consumed.
        for _ in 0..<500 where !waitingForMaintenanceReconnect {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(waitingForMaintenanceReconnect,
               "firmware preparation accepts the reboot correlation")
        bleManager.isNavigationReady = true
        let maintenanceStatus = """
        {"enabled":false,"mode":"","capabilities":{"firmwareMaintenanceV1":true},"maintenance":{"supported":true,"active":true,"stage":"awaiting_authentication","correlation":42},"firmware":{"otaEligible":true,"eligibilityCode":"eligible"}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(maintenanceStatus.utf8)
        )
        do {
            try await preparation.value
        } catch {
            assert(false, "correlated maintenance reconnect completes: \(error)")
        }
    }

    static func assertDeviceTransferAdmissionRejectsUnownedSession() async {
        let suiteName = "transfer-admission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = DeviceOperationCoordinator(defaults: defaults)
        let manager = DeviceTransferManager(coordinator: coordinator)
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        var packets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64, canSend: { true }, write: { packets.append($0) }
        ))
        do {
            _ = try await manager.enterMapTransfer(bleManager: bleManager, status: { _ in })
            assert(false, "admission requires stable connected device identity")
        } catch DeviceOperationCoordinator.Failure.busy { }
        catch { assert(false, "missing identity has concrete admission error: \(error)") }
        bleManager.setConnectedDeviceIDForTesting("device-a")
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
            Data(#"{"enabled":true,"mode":"debug","sessionToken":"foreign-token"}"#.utf8)
        )
        do {
            _ = try await manager.enterMapTransfer(bleManager: bleManager, status: { _ in })
            assert(false, "map entry cannot displace an unowned debug session")
        } catch DeviceOperationCoordinator.Failure.busy { }
        catch { assert(false, "foreign session has concrete busy error: \(error)") }
        assert(packets.isEmpty, "failed ownership admission sends neither enter nor exit")
        assert(coordinator.lease == nil, "refused admission creates no lease")
    }

    static func testDeviceTransferManagerWaitsForMapToken() async {
        await assertDeviceTransferAdmissionRejectsUnownedSession()
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let staleDeviceStatus = """
        {"configured":true,"enabled":false,"port":8080,"mode":"","baseUrl":"http://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","sessionToken":"stale-map-token","firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(staleDeviceStatus.utf8)
        )
        let staleRevision = bleManager.deviceTransferStatusRevision

        let transferTask = Task {
            try await manager.enterMapTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }

        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(sentPackets.count, 1,
                    "map transfer handshake starts with one authoritative command")
        if sentPackets.count == 1 {
            assertEqual(String(data: sentPackets[0], encoding: .utf8),
                        "DTRNenter|map",
                        "generic map entry requests mode and fresh HTTP credential atomically")
        }

        let mapStatus = """
        {"configured":true,"enabled":true,"port":8080,"baseUrl":"http://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","sdPresent":true,"mapFound":true,"mapBlocks":1,"activation":{"status":"idle"}}
        """
        _ = bleManager.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(mapStatus.utf8)
        )

        // Reproduce the real notification order: MSTS can arrive before the
        // token-bearing DSTS. The manager must not return a tokenless session.
        try? await Task.sleep(nanoseconds: 25_000_000)
        let tlsFingerprint = String(repeating: "c", count: 64)
        let deviceStatus = """
        {"configured":true,"enabled":true,"port":8080,"mode":"map","baseUrl":"https://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","apPassphrase":"0123456789abcdef01234567","networkTransport":"hotspot","sessionToken":"dddddddddddddddddddddddddddddddd","tls":{"identityVersion":1,"certificateSha256":"\(tlsFingerprint)"},"transferGeneration":4,"capabilities":{"secureTransferV1":true,"signedMapStreamV1":true,"legacyArchivePolicy":"disabled"},"firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(deviceStatus.utf8)
        )
        assert(bleManager.deviceTransferStatusRevision != staleRevision,
               "fresh device status advances the transfer credential revision")

        do {
            let session = try await transferTask.value
            assertEqual(session.mode, .map,
                        "map transfer handshake returns map mode")
            assertEqual(session.baseURL.absoluteString, "https://192.168.4.20:8080",
                        "map transfer handshake binds matching status origins")
            assertEqual(session.sessionToken, "dddddddddddddddddddddddddddddddd",
                        "map transfer handshake waits for the fresh token")
        } catch {
            assert(false, "map transfer handshake should succeed: \(error)")
        }
    }

    static func testDeviceTransferManagerUsesFreshDeviceSessionWithoutMapStatus() async {
        let suiteName = "transfer-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DeviceTransferManager(coordinator: DeviceOperationCoordinator(defaults: defaults))
        let bleManager = BLEManager()
        bleManager.setConnectedDeviceIDForTesting("device-a")
        bleManager.isConnected = true
        bleManager.isNavigationReady = true

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { packet in
                sentPackets.append(packet)
                if packet == Data("DTRNexit".utf8) {
                    Task { @MainActor in
                        _ = bleManager.handleDeviceTransferStatusNotification(
                            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                            Data(#"{"configured":true,"enabled":false,"mode":""}"#.utf8)
                        )
                    }
                }
            }
        ))

        let transferTask = Task {
            try await manager.enterMapTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }

        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(sentPackets.count, 1,
                    "map transfer handshake does not need a separate status command")

        // DSTS is the atomic transfer-session response. A dropped MSTC chunk
        // must not make an otherwise ready authenticated HTTP server unusable.
        let tlsFingerprint = String(repeating: "d", count: 64)
        let deviceStatus = """
        {"configured":true,"enabled":true,"port":8080,"mode":"map","baseUrl":"https://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","apPassphrase":"0123456789abcdef01234567","networkTransport":"hotspot","sessionToken":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","tls":{"identityVersion":1,"certificateSha256":"\(tlsFingerprint)"},"transferGeneration":5,"capabilities":{"secureTransferV1":true,"signedMapStreamV1":true,"legacyArchivePolicy":"disabled"},"firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(deviceStatus.utf8)
        )

        do {
            let session = try await transferTask.value
            assertEqual(session.mode, .map,
                        "fresh device status opens a map session")
            assertEqual(session.baseURL.absoluteString, "https://192.168.4.20:8080",
                        "device status owns the transfer server origin")
            assertEqual(session.sessionToken, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                        "device status owns the transfer credential")
        } catch {
            assert(false, "fresh device status should not require map status: \(error)")
        }
    }

    static func testBLEManagerSendsDisconnectedSleepTimeoutSetting() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.disconnectedSleepTimeout = .fiveMinutes

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendSetting(id: DeviceBLEProtocol.disconnectedSleepTimeoutSettingID,
                            value: manager.disconnectedSleepTimeout.settingValue)

        assertEqual(sentPackets.count, 1, "sleep timeout setting should send one fallback packet")
        assertEqual(String(data: sentPackets[0].prefix(4), encoding: .utf8),
                    DeviceBLEProtocol.settingsFallbackPrefix,
                    "sleep timeout fallback uses MSET prefix")
        assertEqual(sentPackets[0][4],
                    DeviceBLEProtocol.disconnectedSleepTimeoutSettingID,
                    "sleep timeout uses setting ID 15")
        assertEqual(readInt32LE(sentPackets[0], offset: 5),
                    DisconnectedSleepTimeout.fiveMinutes.settingValue,
                    "sleep timeout fallback includes little-endian seconds")
    }

    static func testBLEManagerParsesMapTransferStatus() {
        let manager = BLEManager()
        let json = """
        {"configured":true,"enabled":true,"port":8080,"baseUrl":"http://192.168.4.20:8080","sdPresent":true,"mapStateKnown":true,"mapFound":false,"mapBlocks":0,"activeMapId":"kyoto-v1","activeSessionId":"kyoto-v1-session","activeManifestReceipt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","activeMapDisplayName":"Kyoto Hills","activeMapBoundsE7":[1356000000,349000000,1360000000,352000000],"activeRendererFormat":2,"labelProfileVersion":1,"labelLanguages":["ja","en"],"fontAssetHealthy":true,"activation":{"status":"activating","sequence":12,"sessionId":"tokyo-v2","mapId":"tokyo-v2","step":1,"steps":5,"progress":6},"lastError":{"code":"previous","message":"previous upload failed"}}
        """
        let packet = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(json.utf8)

        assert(manager.handleMapTransferStatusNotification(packet), "MSTS notification should be consumed")
        assert(manager.mapTransferModeEnabled, "status parser exposes enabled transfer mode")
        assertEqual(manager.mapTransferBaseURL?.absoluteString, "http://192.168.4.20:8080", "status parser exposes base URL")
        assertEqual(manager.mapTransferActiveMapId, "kyoto-v1", "status parser exposes active map id")
        assertEqual(manager.mapTransferActiveSessionId, "kyoto-v1-session", "status parser exposes active session id")
        assertEqual(manager.activeMapManifestReceipt,
                    String(repeating: "a", count: 64),
                    "status parser associates label health with the active receipt")
        assertEqual(manager.activeDeviceMap?.mapID, "kyoto-v1",
                    "status parser publishes a device map descriptor")
        assertEqual(manager.activeDeviceMap?.displayName, "Kyoto Hills",
                    "device map descriptor exposes its manifest display name")
        assertEqual(manager.activeDeviceMap?.bounds?.minLongitude, 135.6,
                    "device map descriptor converts integer preview bounds")
        assertEqual(manager.activeMapRendererFormat, 2,
                    "status parser exposes active renderer target")
        assertEqual(manager.activeMapLabelProfileVersion, 1,
                    "status parser exposes active label profile")
        assertEqual(manager.activeMapLabelLanguages, ["ja", "en"],
                    "status parser exposes active label languages")
        assert(manager.activeMapFontAssetHealthy,
               "status parser exposes live FMA1 health")
        assertEqual(manager.mapTransferActivationStatus, "activating", "status parser exposes activation state")
        assertEqual(manager.mapTransferActivationSequence, 12, "status parser exposes activation sequence")
        assertEqual(manager.mapTransferActivationSessionId, "tokyo-v2", "status parser exposes activation session")
        assertEqual(manager.mapTransferActivationMapId, "tokyo-v2", "status parser exposes activating map id")
        assertEqual(manager.mapTransferActivationStep, 1, "status parser exposes activation step")
        assertEqual(manager.mapTransferActivationStepCount, 5, "status parser exposes activation step count")
        assertEqual(manager.mapTransferActivationProgress, 6, "status parser exposes activation percentage")
        assertEqual(manager.deviceHasSDCard, true, "status parser exposes physical SD state")
        assert(manager.deviceMapStateKnown,
               "status parser exposes authoritative renderer coverage state")
        assertEqual(manager.deviceMapFoundForCurrentLocation, false, "status parser exposes current map coverage")
        assertEqual(manager.deviceMapBlockCount, 0, "status parser exposes current map block count")
        assertEqual(manager.mapTransferLastError, "previous: previous upload failed", "status parser exposes last transfer error")

        let legacyPacket = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
            "{\"enabled\":true,\"activeMapId\":\"legacy-map\"}".utf8
        )
        assert(manager.handleMapTransferStatusNotification(legacyPacket),
               "legacy map status should remain supported")
        assertEqual(manager.activeDeviceMap?.mapID, "legacy-map",
                    "older firmware still creates a conservative device-only descriptor")
        assertEqual(manager.activeDeviceMap?.sessionID, nil,
                    "older firmware without a session cannot merge with a local pack")
        assert(!manager.deviceMapStateKnown,
               "older firmware never turns an initial false into an authoritative miss")

        let malformedPresentationPacket =
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
                """
                {"enabled":true,"activeMapId":"safe-map","activeSessionId":"safe-session","activeMapDisplayName":42,"activeMapBoundsE7":[1219500000,315500000,1209000000,307000000]}
                """.utf8
            )
        assert(manager.handleMapTransferStatusNotification(malformedPresentationPacket),
               "malformed optional map presentation should not reject the status")
        assertEqual(manager.activeDeviceMap?.mapID, "safe-map",
                    "valid active identity survives malformed optional presentation")
        assertEqual(manager.activeDeviceMap?.displayName, nil,
                    "malformed optional display name is omitted")
        assertEqual(manager.activeDeviceMap?.bounds, nil,
                    "reversed optional preview bounds are omitted")

        let booleanBoundsPacket =
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
                """
                {"enabled":true,"activeMapId":"safe-map","activeMapBoundsE7":[false,false,true,true]}
                """.utf8
            )
        assert(manager.handleMapTransferStatusNotification(booleanBoundsPacket),
               "boolean optional bounds should not reject the status")
        assertEqual(manager.activeDeviceMap?.bounds, nil,
                    "JSON booleans are not accepted as integer coordinates")

        let oversizedBoundsPacket =
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
                """
                {"enabled":true,"activeMapId":"safe-map","activeMapBoundsE7":[100000000,100000000,200000000,200000000,2147483648]}
                """.utf8
            )
        assert(manager.handleMapTransferStatusNotification(oversizedBoundsPacket),
               "oversized optional bounds should not reject the status")
        assertEqual(manager.activeDeviceMap?.bounds, nil,
                    "invalid extra coordinates cannot be compacted into a valid bounds array")

        let collisionA = DeviceActiveMapDescriptor(
            mapID: "a--b",
            sessionID: "c",
            boundsE7: [100000000, 100000000, 200000000, 200000000]
        )!
        let collisionB = DeviceActiveMapDescriptor(
            mapID: "a",
            sessionID: "b--c",
            boundsE7: [100000000, 100000000, 200000000, 200000000]
        )!
        assert(collisionA.previewFilename != collisionB.previewFilename,
               "preview cache filenames bind unambiguous map and session identities")
        let legacyBoundsA = DeviceActiveMapDescriptor(
            mapID: ".legacy-map",
            boundsE7: [100000000, 100000000, 200000000, 200000000]
        )!
        let legacyBoundsB = DeviceActiveMapDescriptor(
            mapID: ".legacy-map",
            boundsE7: [300000000, 300000000, 400000000, 400000000]
        )!
        assert(legacyBoundsA.previewFilename != legacyBoundsB.previewFilename,
               "sessionless preview identity includes presentation metadata")
        assert(legacyBoundsA.previewFilename.hasPrefix("device-map-"),
               "valid dot-prefixed map IDs cannot create hidden preview files")

        let missingActivePacket = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(
            "{\"enabled\":true,\"activeError\":{\"code\":\"installed_manifest\"}}".utf8
        )
        assert(manager.handleMapTransferStatusNotification(missingActivePacket),
               "active-map error status should be consumed")
        assertEqual(manager.activeDeviceMap, nil,
                    "a complete status without an active map clears device inventory")
    }

    static func testBLEManagerReassemblesChunkedMapTransferStatus() {
        let manager = BLEManager()
        let body = Data("""
        {"enabled":true,"baseUrl":"http://192.168.4.20:8080","activeMapId":"custom-map","activeSessionId":"custom-map-session","activeMapDisplayName":"Custom Map","activeMapBoundsE7":[1209000000,307000000,1219500000,315500000],"activation":{"status":"installed","sequence":9,"sessionId":"custom-map-session"}}
        """.utf8)
        let chunkSize = 13
        let chunkCount = UInt8((body.count + chunkSize - 1) / chunkSize)
        for index in UInt8(0)..<chunkCount {
            let start = Int(index) * chunkSize
            let end = min(start + chunkSize, body.count)
            var frame = Data(DeviceBLEProtocol.mapTransferStatusChunkPrefix.utf8)
            frame.append(contentsOf: [7, index, chunkCount])
            frame.append(body.subdata(in: start..<end))
            assert(frame.count <= 20, "chunked map status fits the minimum ATT payload")
            assert(manager.handleMapTransferStatusNotification(frame),
                   "MSTC chunk should be consumed")
        }

        assertEqual(manager.mapTransferActiveMapId, "custom-map",
                    "chunk reassembly exposes active map")
        assertEqual(manager.mapTransferActiveSessionId, "custom-map-session",
                    "chunk reassembly exposes durable active session")
        assertEqual(manager.activeDeviceMap?.displayName, "Custom Map",
                    "chunk reassembly publishes the device map display name")
        assertEqual(manager.activeDeviceMap?.bounds?.maxLatitude, 31.55,
                    "chunk reassembly publishes the device map preview bounds")
        assertEqual(manager.mapTransferActivationStatus, "installed",
                    "chunk reassembly exposes activation state")
        assertEqual(manager.mapTransferActivationSequence, 9,
                    "chunk reassembly exposes activation sequence")
    }

    static func testBLEManagerCompletesRetransmittedChunkedMapTransferStatus() {
        let manager = BLEManager()
        let previousBody = Data(
            "{\"enabled\":true,\"activeMapId\":\"previous-map\",\"activeSessionId\":\"previous-session\"}".utf8
        )
        assert(manager.handleMapTransferStatusNotification(
            Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + previousBody
        ), "a previous complete map status should seed the live descriptor")
        let body = Data("""
        {"enabled":false,"activeMapId":"shanghai-v2","activeSessionId":"session-v2","activeRendererFormat":2,"labelProfileVersion":1,"labelLanguages":["zh-Hans","en"],"fontAssetHealthy":true,"activation":{"status":"installed","sequence":10,"sessionId":"session-v2","mapId":"shanghai-v2","step":3,"steps":3,"progress":100}}
        """.utf8)
        let chunkSize = 13
        let chunkCount = UInt8((body.count + chunkSize - 1) / chunkSize)

        func frame(index: UInt8) -> Data {
            let start = Int(index) * chunkSize
            let end = min(start + chunkSize, body.count)
            var result = Data(DeviceBLEProtocol.mapTransferStatusChunkPrefix.utf8)
            result.append(contentsOf: [42, index, chunkCount])
            result.append(body.subdata(in: start..<end))
            return result
        }

        let missingIndex = chunkCount / 2
        for index in UInt8(0)..<chunkCount where index != missingIndex {
            assert(manager.handleMapTransferStatusNotification(frame(index: index)),
                   "first lossy status response should retain received chunks")
        }
        assertEqual(manager.mapTransferActiveMapId, "previous-map",
                    "an incomplete response must retain the previous complete state")
        assertEqual(manager.activeDeviceMap?.sessionID, "previous-session",
                    "an incomplete response must retain complete device inventory")

        for index in UInt8(0)..<chunkCount {
            assert(manager.handleMapTransferStatusNotification(frame(index: index)),
                   "same-ID retransmission should be consumed")
        }
        assertEqual(manager.mapTransferActiveMapId, "shanghai-v2",
                    "same-ID retransmission fills a missing chunk")
        assertEqual(manager.mapTransferActivationStatus, "installed",
                    "retransmission publishes the terminal activation state")
        assert(manager.activeMapFontAssetHealthy,
               "retransmission unlocks street-label settings")
    }

    static func testBLEManagerParsesDeviceTransferStatus() {
        let manager = BLEManager()
        let json = """
        {"configured":true,"enabled":true,"port":8080,"mode":"debug","statusRevision":23,"baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","apPassphrase":"session-wpa-key","networkTransport":"hotspot","networkSsid":"BikeComputer-Transfer","hotspotFallback":true,"hotspotFallbackReason":"endpoint_unreachable","sessionToken":"abc123","capabilities":{"firmwareMaintenanceV1":true},"maintenance":{"supported":true,"active":true,"stage":"ready","correlation":42},"resources":{"internalFree":65536,"internalLargest":32768,"dmaFree":49152,"dmaLargest":24576,"psramFree":4194304,"psramLargest":3145728,"minimumInternalFree":61440,"minimumInternalLargest":28672,"minimumDmaFree":45056,"minimumDmaLargest":20480,"minimumPsramFree":4000000,"minimumPsramLargest":3000000,"workerStackHighWaterBytes":7168,"internalOwnerStackHighWaterBytes":4096,"phase":"network_ready"},"bootCheckpoint":{"schemaVersion":1,"target":"WAVESHARE_AMOLED_206","profile":"WAVESHARE_AMOLED_206_PRODUCTION","gitSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"0.2.2","build":86,"bootSequence":9,"bootFingerprint":1234,"normalReady":false,"maintenance":true,"otaState":"valid"},"lastError":{"sequence":17,"code":"transfer_busy","message":"another transfer mode is active"},"storage":{"backend":"legacy_spi_migration","powerCycleRequired":true},"firmware":{"status":"receiving","target":"WAVESHARE_AMOLED_206","version":"0.2.2","build":86,"gitSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","updaterProtocol":1,"otaEligible":true,"eligibilityCode":"eligible","inactivePartition":"ota_1","runningPartition":"ota_0","profile":"WAVESHARE_AMOLED_206_PRODUCTION","otaState":"valid","maxImageBytes":3145728,"receivedBytes":1024,"totalBytes":2048,"flashOwnerStackHighWaterBytes":4096,"lastError":{"code":"previous","message":"previous update failed"}}}
        """
        let packet = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(json.utf8)

        assert(manager.handleDeviceTransferStatusNotification(packet), "DSTS notification should be consumed")
        assertEqual(manager.deviceTransferMode, "debug", "status parser exposes transfer mode")
        assertEqual(manager.deviceTransferBaseURL?.absoluteString, "http://192.168.4.1:8080", "status parser exposes base URL")
        assertEqual(manager.deviceTransferAccessPointSSID, "BikeComputer-Transfer", "status parser exposes SSID")
        assertEqual(manager.deviceTransferAccessPointPassphrase, "session-wpa-key", "status parser exposes the authenticated debug hotspot password")
        assertEqual(manager.deviceTransferNetworkTransport, "hotspot", "status parser exposes network transport")
        assertEqual(manager.deviceTransferNetworkSSID, "BikeComputer-Transfer", "status parser exposes network SSID")
        assert(manager.deviceTransferUsedHotspotFallback, "status parser exposes LAN fallback state")
        assertEqual(manager.deviceTransferHotspotFallbackReason,
                    "endpoint_unreachable",
                    "status parser exposes the persistent fallback reason")
        assertEqual(manager.deviceTransferSessionToken, "abc123", "status parser exposes session token")
        assertEqual(manager.deviceTransferRemoteStatusRevision, 23,
                    "status parser exposes the firmware status revision")
        assert(manager.supportsFirmwareMaintenanceV1,
               "status parser negotiates firmware maintenance")
        assert(manager.firmwareMaintenanceActive,
               "status parser exposes active maintenance mode")
        assertEqual(manager.firmwareMaintenanceStage, "ready",
                    "status parser exposes maintenance readiness")
        assertEqual(manager.firmwareMaintenanceCorrelation, 42,
                    "status parser preserves reboot correlation")
        assertEqual(manager.deviceTransferResourceSnapshot?.phase,
                    "network_ready",
                    "status parser retains the resource sampling phase")
        assertEqual(manager.deviceTransferResourceSnapshot?.minimumDmaFree,
                    45056,
                    "status parser retains the minimum DMA evidence")
        assert(manager.deviceTransferWiFiStartFailure == nil,
               "older firmware omits optional Wi-Fi startup diagnostics")
        let wifiFailure = """
        {"configured":true,"enabled":false,"mode":"","lastError":{"code":"wifi_ram_storage","message":"Wi-Fi startup failed","sequence":18},"wifiStartFailure":{"step":"wifi_ram_storage","espError":258,"before":{"internalFree":44000,"internalLargest":29000,"dmaFree":36000,"dmaLargest":21000},"after":{"internalFree":42000,"internalLargest":27000,"dmaFree":34000,"dmaLargest":19000}}}
        """
        assert(manager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(wifiFailure.utf8)
        ), "classified Wi-Fi failure is consumed")
        assertEqual(manager.deviceTransferWiFiStartFailure?.step,
                    "wifi_ram_storage",
                    "status parser keeps the failed Wi-Fi substep")
        assertEqual(manager.deviceTransferWiFiStartFailure?.espError,
                    258,
                    "status parser keeps the underlying ESP result")
        assertEqual(manager.deviceTransferWiFiStartFailure?.after.dmaLargest,
                    19000,
                    "status parser keeps failure-time DMA headroom")
        assert(manager.handleDeviceTransferStatusNotification(packet),
               "older firmware status remains decodable after a failure")
        assert(manager.deviceTransferWiFiStartFailure == nil,
               "older firmware clears stale optional Wi-Fi diagnostics")
        assertEqual(
            manager.deviceTransferResourceSnapshot?
                .internalOwnerStackHighWaterBytes,
            4096,
            "status parser retains the internal-owner stack margin"
        )
        assertEqual(manager.firmwareBootSequence, 9,
                    "status parser exposes the authenticated boot sequence")
        assertEqual(manager.firmwareBootFingerprint, 1234,
                    "status parser exposes the boot identity fingerprint")
        assert(!manager.firmwareBootNormalReady,
               "maintenance readiness cannot masquerade as normal readiness")
        assert(manager.firmwareBootMaintenance,
               "status parser distinguishes the maintenance checkpoint")
        assertEqual(manager.deviceTransferLastErrorCode, "transfer_busy", "status parser exposes transfer error code")
        assertEqual(manager.deviceTransferLastErrorMessage, "another transfer mode is active", "status parser exposes transfer error message")
        assertEqual(manager.deviceTransferLastErrorSequence, 17,
                    "status parser exposes the monotonic transfer error sequence")
        assertEqual(manager.deviceStorageBackend,
                    "legacy_spi_migration",
                    "status parser exposes the active storage backend")
        assertEqual(manager.deviceStoragePowerCycleRequired,
                    true,
                    "status parser exposes the one-time card power-cycle requirement")
        assertEqual(manager.firmwareTarget, "WAVESHARE_AMOLED_206", "status parser exposes firmware target")
        assertEqual(manager.firmwareVersion, "0.2.2", "status parser exposes firmware version")
        assertEqual(manager.firmwareBuild, 86, "status parser exposes firmware build")
        assertEqual(manager.firmwareUpdateStatus, "receiving", "status parser exposes firmware update status")
        assertEqual(manager.firmwareOTAEligible, true,
                    "status parser exposes OTA partition eligibility")
        assertEqual(manager.firmwareOTAEligibilityCode, "eligible",
                    "status parser exposes the eligibility reason")
        assertEqual(manager.firmwareInactivePartition, "ota_1",
                    "status parser exposes the inactive slot")
        assertEqual(manager.firmwareRunningPartition, "ota_0",
                    "status parser exposes the running slot")
        assertEqual(manager.firmwareBuildProfile,
                    "WAVESHARE_AMOLED_206_PRODUCTION",
                    "status parser exposes the build profile")
        assertEqual(manager.firmwareOTAState, "valid",
                    "status parser exposes the OTA acceptance state")
        assertEqual(manager.firmwareMaximumImageBytes, 3 * 1024 * 1024,
                    "status parser exposes the slot capacity")
        assertEqual(manager.firmwareUpdateReceivedBytes, 1024, "status parser exposes received bytes")
        assertEqual(manager.firmwareUpdateTotalBytes, 2048, "status parser exposes total bytes")
        assertEqual(manager.firmwareFlashOwnerStackHighWaterBytes, 4096,
                    "status parser retains the flash-owner stack margin")
        assertEqual(manager.firmwareUpdateLastError, "previous: previous update failed", "status parser exposes firmware error")

        let clearedPacket = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
            Data("{\"enabled\":false}".utf8)
        assert(manager.handleDeviceTransferStatusNotification(clearedPacket),
               "a status without lastError is consumed")
        assertEqual(manager.deviceTransferLastErrorSequence, nil,
                    "legacy or clear status resets the optional error sequence")

        let invalidPacket = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data("{".utf8)
        assert(manager.handleDeviceTransferStatusNotification(invalidPacket), "invalid DSTS notification should be consumed")
    }

    static func testBLEManagerSendsBrightnessFallbackSetting() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "deviceSettings.brightnessPercent")

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.deviceBrightnessPercent = 65

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendSetting(id: DeviceBLEProtocol.brightnessSettingID, value: Int32(manager.deviceBrightnessPercent))

        assertEqual(sentPackets.count, 1, "brightness without a dedicated characteristic should use fallback navigation writes")
        let packet = sentPackets[0]
        assertEqual(String(data: packet.prefix(4), encoding: .utf8), DeviceBLEProtocol.settingsFallbackPrefix, "brightness fallback uses MSET prefix")
        assertEqual(packet[4], DeviceBLEProtocol.brightnessSettingID, "brightness fallback uses setting ID 12")
        let valueBytes = Array(packet[5..<9])
        let value = Int32(valueBytes[0])
            | (Int32(valueBytes[1]) << 8)
            | (Int32(valueBytes[2]) << 16)
            | (Int32(valueBytes[3]) << 24)
        assertEqual(value, 65, "brightness fallback includes little-endian percent")

        let reloaded = BLEManager()
        assertEqual(Int(reloaded.deviceBrightnessPercent), 65, "brightness setting persists for UI display")
        defaults.removeObject(forKey: "deviceSettings.brightnessPercent")
    }

    static func testBLEManagerResendsBrightnessAfterAuthentication() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "deviceSettings.brightnessPercent")
        defaults.removeObject(forKey: "deviceSettings.automaticDisplayOffEnabled")

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsDeviceSettings = true
        manager.deviceBrightnessPercent = 70
        manager.automaticDisplayOffEnabled = false
        assert(manager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
                Data([1, 0, 0, 8, 0])
        ), "automatic display-off capability response should be consumed")
        assert(manager.supportsAutomaticDisplayOff,
               "CAP2 bit 19 enables automatic display-off")

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendInitialDeviceSettingsAfterAuthenticationForTesting()

        let brightnessPackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.brightnessSettingID
        }
        assertEqual(brightnessPackets.count, 1,
                    "authenticated reconnect sends brightness exactly once")
        let valueBytes = Array(brightnessPackets[0][5..<9])
        let value = Int32(valueBytes[0])
            | (Int32(valueBytes[1]) << 8)
            | (Int32(valueBytes[2]) << 16)
            | (Int32(valueBytes[3]) << 24)
        assertEqual(value, 70,
                    "authenticated reconnect restores the saved brightness")
        let automaticDisplayOffPackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.automaticDisplayOffSettingID
        }
        assertEqual(automaticDisplayOffPackets.count, 1,
                    "authenticated reconnect sends automatic display-off exactly once")
        assertEqual(readInt32LE(automaticDisplayOffPackets[0], offset: 5), 0,
                    "authenticated reconnect restores disabled automatic display-off")
        defaults.removeObject(forKey: "deviceSettings.brightnessPercent")
        defaults.removeObject(forKey: "deviceSettings.automaticDisplayOffEnabled")
    }

    static func testBLEManagerGatesAutomaticDisplayOffForLegacyFirmware() {
        let defaults = UserDefaults.standard
        let key = "deviceSettings.automaticDisplayOffEnabled"
        defaults.removeObject(forKey: key)

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        assert(manager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) + Data([0])
        ), "legacy capability response should be consumed")
        assert(!manager.supportsAutomaticDisplayOff,
               "legacy firmware does not advertise automatic display-off")
        manager.supportsDeviceSettings = true
        manager.automaticDisplayOffEnabled = false

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(!manager.sendSetting(
            id: DeviceBLEProtocol.automaticDisplayOffSettingID,
            value: 0
        ), "legacy firmware rejects unsupported automatic display-off writes")
        assert(sentPackets.isEmpty,
               "legacy firmware receives no automatic display-off packet")
        defaults.removeObject(forKey: key)
    }

    static func testBLEManagerSendsAutomaticDisplayOffAfterCapabilityNegotiation() {
        let defaults = UserDefaults.standard
        let key = "deviceSettings.automaticDisplayOffEnabled"
        defaults.removeObject(forKey: key)

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsDeviceSettings = true
        manager.automaticDisplayOffEnabled = false

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let capability = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 8, 0])
        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "CAP2 capability response should be consumed")
        let automaticDisplayOffPackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.automaticDisplayOffSettingID
        }
        assertEqual(automaticDisplayOffPackets.count, 1,
                    "capability negotiation sends automatic display-off exactly once")
        assertEqual(readInt32LE(automaticDisplayOffPackets[0], offset: 5), 0,
                    "capability negotiation sends the saved disabled value")

        assert(manager.handleDeviceCapabilitiesNotification(capability),
               "duplicate CAP2 capability response should be consumed")
        let duplicatePackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.automaticDisplayOffSettingID
        }
        assertEqual(duplicatePackets.count, 1,
                    "duplicate capability responses do not resend automatic display-off")
        defaults.removeObject(forKey: key)
    }

    static func testBLEManagerSendsAutomaticDisplayOffSetting() {
        let defaults = UserDefaults.standard
        let key = "deviceSettings.automaticDisplayOffEnabled"
        defaults.removeObject(forKey: key)

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsDeviceSettings = true
        assert(manager.automaticDisplayOffEnabled,
               "automatic display-off defaults to enabled")
        manager.automaticDisplayOffEnabled = false
        assert(manager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
                Data([1, 0, 0, 8, 0])
        ), "automatic display-off capability response should be consumed")
        assert(manager.supportsAutomaticDisplayOff,
               "CAP2 bit 19 enables automatic display-off")

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendSetting(
            id: DeviceBLEProtocol.automaticDisplayOffSettingID,
            value: 0
        )

        assertEqual(sentPackets.count, 1,
                    "automatic display-off should send one fallback packet")
        assertEqual(sentPackets[0][4],
                    DeviceBLEProtocol.automaticDisplayOffSettingID,
                    "automatic display-off uses setting ID 36")
        assertEqual(readInt32LE(sentPackets[0], offset: 5), 0,
                    "automatic display-off sends the disabled value")

        let reloaded = BLEManager()
        assert(!reloaded.automaticDisplayOffEnabled,
               "automatic display-off preference persists")
        defaults.removeObject(forKey: key)
    }

    static func testBLEManagerRetriesAutomaticDisplayOffAfterQueuePressure() {
        let defaults = UserDefaults.standard
        let key = "deviceSettings.automaticDisplayOffEnabled"
        defaults.removeObject(forKey: key)

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsDeviceSettings = true
        manager.automaticDisplayOffEnabled = false

        assert(manager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
                Data([1, 0, 0, 8, 0])
        ), "automatic display-off capability response should be consumed")

        var canSend = false
        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { canSend },
            write: { sentPackets.append($0) }
        ))
        manager.installNavigationWriteQueueForTesting(maxCount: 1)

        assert(manager.enqueueProtectedNavigationWriteForTesting(Data([0xA1])),
               "a protected transfer should occupy the test queue")
        assert(!manager.sendSetting(
            id: DeviceBLEProtocol.automaticDisplayOffSettingID,
            value: 0
        ), "automatic display-off reports queue rejection when no slot is available")
        assert(sentPackets.isEmpty,
               "queue pressure must not report an unsent automatic display-off packet")

        canSend = true
        manager.flushPendingNavigationWritesForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let automaticDisplayOffPackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.automaticDisplayOffSettingID
        }
        assertEqual(automaticDisplayOffPackets.count, 1,
                    "automatic display-off retries after protected queue traffic drains")
        assertEqual(readInt32LE(automaticDisplayOffPackets[0], offset: 5), 0,
                    "the retried automatic display-off packet preserves the saved value")
        defaults.removeObject(forKey: key)
    }

    static func testBLEManagerSendsDisplayInactivityTimeouts() {
        let defaults = UserDefaults.standard
        let dimKey = "deviceSettings.displayDimTimeoutSeconds"
        let offKey = "deviceSettings.displayOffTimeoutSeconds"
        defaults.removeObject(forKey: dimKey)
        defaults.removeObject(forKey: offKey)

        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.supportsDeviceSettings = true

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let capableResponse =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 8, 16])
        assert(manager.handleDeviceCapabilitiesNotification(capableResponse),
               "display inactivity timeout capability response should be consumed")
        assert(manager.supportsDisplayInactivityTimeouts,
               "CAP2 bit 28 enables configurable display inactivity timeouts")

        let negotiatedPackets = sentPackets.filter {
            $0.count == 9 &&
            String(data: $0.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.settingsFallbackPrefix &&
            $0[4] == DeviceBLEProtocol.displayInactivityTimeoutsSettingID
        }
        assertEqual(negotiatedPackets.count, 1,
                    "capability negotiation sends display inactivity timeouts once")
        assertEqual(
            readInt32LE(negotiatedPackets[0], offset: 5),
            DeviceBLEProtocol.displayInactivityTimeoutsSettingValue(
                dimAfterSeconds: 15,
                displayOffAfterSeconds: 45
            )!,
            "capability negotiation sends the compatibility defaults"
        )

        manager.displayDimTimeout = .thirtySeconds
        manager.displayOffTimeout = .twoMinutes
        manager.sendDisplayInactivityTimeouts()
        let updatedPackets = sentPackets.filter {
            $0.count == 9 &&
            $0[4] == DeviceBLEProtocol.displayInactivityTimeoutsSettingID
        }
        assertEqual(updatedPackets.count, 2,
                    "changing either picker sends one atomic timeout pair")
        assertEqual(
            readInt32LE(updatedPackets[1], offset: 5),
            DeviceBLEProtocol.displayInactivityTimeoutsSettingValue(
                dimAfterSeconds: 30,
                displayOffAfterSeconds: 120
            )!,
            "the timeout packet preserves both selected stages"
        )

        let reloaded = BLEManager()
        assertEqual(reloaded.displayDimTimeout, .thirtySeconds,
                    "the display dim timeout persists")
        assertEqual(reloaded.displayOffTimeout, .twoMinutes,
                    "the display off timeout persists")

        let legacyManager = BLEManager()
        legacyManager.isConnected = true
        legacyManager.isNavigationReady = true
        legacyManager.supportsDeviceSettings = true
        var legacyPackets: [Data] = []
        legacyManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { legacyPackets.append($0) }
        ))
        assert(legacyManager.handleDeviceCapabilitiesNotification(
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
                Data([1, 0, 0, 8, 0])
        ), "older automatic-display-off capability response should be consumed")
        assert(!legacyManager.supportsDisplayInactivityTimeouts,
               "older firmware keeps fixed 15/45-second behavior")
        let packed = DeviceBLEProtocol.displayInactivityTimeoutsSettingValue(
            dimAfterSeconds: 30,
            displayOffAfterSeconds: 120
        )!
        assert(!legacyManager.sendSetting(
            id: DeviceBLEProtocol.displayInactivityTimeoutsSettingID,
            value: packed
        ), "older firmware rejects unsupported timeout writes")
        assert(legacyPackets.allSatisfy {
            $0.count < 5 ||
            $0[4] != DeviceBLEProtocol.displayInactivityTimeoutsSettingID
        }, "older firmware receives no display inactivity timeout packet")

        defaults.removeObject(forKey: dimKey)
        defaults.removeObject(forKey: offKey)
    }

    static func testBLEManagerSendsDeviceScreenSettings() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.enabledDeviceScreensMask = DeviceScreen.map.bit | DeviceScreen.mapPlusNavigation.bit
        manager.defaultDeviceScreen = .mapPlusNavigation

        var sentPackets: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        manager.sendEnabledDeviceScreensMask()
        manager.sendDefaultDeviceScreen()

        assertEqual(sentPackets.count, 2, "device screen settings should send mask and default packets")
        assertEqual(String(data: sentPackets[0].prefix(4), encoding: .utf8), DeviceBLEProtocol.settingsFallbackPrefix, "screen mask fallback uses MSET prefix")
        assertEqual(sentPackets[0][4], DeviceBLEProtocol.enabledScreensSettingID, "screen mask uses setting ID 13")
        assertEqual(readInt32LE(sentPackets[0], offset: 5),
                    Int32(DeviceScreen.map.bit | DeviceScreen.mapPlusNavigation.bit),
                    "screen mask fallback includes little-endian mask")
        assertEqual(sentPackets[1][4], DeviceBLEProtocol.defaultScreenSettingID, "default screen uses setting ID 14")
        assertEqual(readInt32LE(sentPackets[1], offset: 5),
                    Int32(DeviceScreen.mapPlusNavigation.rawValue),
                    "default screen fallback includes little-endian screen value")
    }

    static func testBLEManagerPersistsNewMapSettings() {
        let defaults = UserDefaults.standard
        let keys = [
            "mapSettings.minPolygonSize",
            "mapSettings.detailLevel",
            "mapSettings.routeLineWidth",
            "mapSettings.streetLineWidth",
            "mapSettings.streetLineWidthBoost",
            "mapSettings.positionMarkerScale",
            "mapSettings.mapRotationMode",
            "mapSettings.zoomLevel",
            "mapSettings.labelsEnabled",
            "mapSettings.labelDensity",
            "mapSettings.labelLanguageMode",
            "mapSettings.labelTextSize",
            "mapSettings.labelOrientation",
            "mapSettings.showBuildings",
            "mapSettings.showGreenSpace",
            "mapSettings.showPaths",
            "mapSettings.showTracks",
            "mapSettings.showMajorRoads",
            "mapSettings.showLocalStreets",
            "mapSettings.showServiceRoads",
            "mapSettings.showWater",
            "mapSettings.showRailways",
            "mapSettings.showOtherAreas",
            "mapSettings.showNature",
            "mapSettings.showMinorRoads",
            "mapPlusNavigationSettings.minPolygonSize",
            "mapPlusNavigationSettings.detailLevel",
            "mapPlusNavigationSettings.routeLineWidth",
            "mapPlusNavigationSettings.streetLineWidth",
            "mapPlusNavigationSettings.streetLineWidthBoost",
            "mapPlusNavigationSettings.positionMarkerScale",
            "mapPlusNavigationSettings.zoomLevel",
            "mapPlusNavigationSettings.labelsEnabled",
            "mapPlusNavigationSettings.labelDensity",
            "mapPlusNavigationSettings.labelLanguageMode",
            "mapPlusNavigationSettings.labelTextSize",
            "mapPlusNavigationSettings.labelOrientation",
            "mapPlusNavigationSettings.showBuildings",
            "mapPlusNavigationSettings.buildingVisibilityDefaultPending.v1",
            "mapPlusNavigationSettings.showGreenSpace",
            "mapPlusNavigationSettings.showPaths",
            "mapPlusNavigationSettings.showTracks",
            "mapPlusNavigationSettings.showMajorRoads",
            "mapPlusNavigationSettings.showLocalStreets",
            "mapPlusNavigationSettings.showServiceRoads",
            "mapPlusNavigationSettings.showWater",
            "mapPlusNavigationSettings.showRailways",
            "mapPlusNavigationSettings.showOtherAreas",
            "mapPlusNavigationSettings.migrated.v1",
            "mapSettings.recommendedDefaults.v2",
            "streetLabels.defaults.v1",
            "deviceSettings.enabledScreensMask",
            "deviceSettings.defaultScreen",
            "deviceSettings.defaultScreen.mapPlusNavigationDefault.v1",
            "deviceSettings.enabledScreensMask.batteryStatus.v1",
            "deviceSettings.disconnectedSleepTimeoutSeconds"
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }

        let freshManager = BLEManager()
        assertEqual(freshManager.defaultDeviceScreen, .mapPlusNavigation, "fresh installs default to Map + Navigation")
        assertEqual(freshManager.detailLevel, 2, "fresh Map profiles default to high detail")
        assertEqual(freshManager.zoomLevel, 3, "fresh Map profiles default to zoom level 3")
        assertEqual(freshManager.routeLineWidth, 4, "fresh Map profiles default to a 4 px route")
        assertEqual(freshManager.streetLineWidth, 4, "fresh Map profiles default to 4 px streets")
        assert(freshManager.mapLabelsEnabled,
               "fresh Map profiles show street labels")
        assertEqual(freshManager.mapLabelDensity, 2,
                    "fresh Map profiles use Balanced label density")
        assertEqual(freshManager.mapLabelLanguageMode, 2,
                    "fresh Map profiles use Local + Preferred labels")
        assertEqual(freshManager.mapLabelTextSize, 0,
                    "fresh Map profiles use the new Small label tier")
        assertEqual(freshManager.mapLabelOrientation, 1,
                    "fresh Map profiles keep labels upright")
        assertEqual(freshManager.mapPlusNavigationDetailLevel, 0,
                    "fresh Map + Navigation profiles default to low detail")
        assertEqual(freshManager.mapPlusNavigationZoomLevel, 3,
                    "fresh Map + Navigation profiles default to zoom level 3")
        assertEqual(freshManager.mapPlusNavigationRouteLineWidth, 15,
                    "fresh Map + Navigation profiles default to a 15 px route")
        assertEqual(freshManager.mapPlusNavigationStreetLineWidth, 4,
                    "fresh Map + Navigation profiles default to 4 px streets")
        assertEqual(freshManager.mapPlusNavigationPositionMarkerScale, 2,
                    "fresh Map + Navigation profiles keep a 2x position marker")
        assert(!freshManager.mapPlusNavigationShowBuildings,
               "fresh Map + Navigation profiles wait for advertised 3D-building support")
        assert(!freshManager.mapPlusNavigationShowGreenSpace,
               "fresh Map + Navigation profiles hide green space")
        assert(!freshManager.mapPlusNavigationShowPaths,
               "fresh Map + Navigation profiles hide paths and footways")
        assert(!freshManager.mapPlusNavigationShowTracks,
               "fresh Map + Navigation profiles hide tracks")
        assert(freshManager.mapPlusNavigationShowMajorRoads,
               "fresh Map + Navigation profiles show major roads")
        assert(freshManager.mapPlusNavigationShowLocalStreets,
               "fresh Map + Navigation profiles show residential and local roads")
        assert(!freshManager.mapPlusNavigationShowServiceRoads,
               "fresh Map + Navigation profiles hide service roads")
        assert(freshManager.mapPlusNavigationShowWater,
               "fresh Map + Navigation profiles keep water visible")
        assert(!freshManager.mapPlusNavigationShowRailways,
               "fresh Map + Navigation profiles hide railways")
        assert(!freshManager.mapPlusNavigationShowOtherAreas,
               "fresh Map + Navigation profiles hide other areas")
        assert(!freshManager.mapPlusNavigationLabelsEnabled,
               "fresh Map + Navigation profiles hide street labels")
        assertEqual(freshManager.mapPlusNavigationLabelDensity, 2,
                    "fresh Map + Navigation profiles retain Balanced as the dormant label density")

        defaults.set(0, forKey: "mapSettings.labelDensity")
        defaults.set(0, forKey: "mapSettings.labelLanguageMode")
        defaults.set(1, forKey: "mapSettings.labelTextSize")
        defaults.set(0, forKey: "mapSettings.labelOrientation")
        defaults.set(2, forKey: "mapPlusNavigationSettings.labelDensity")
        defaults.removeObject(forKey: "streetLabels.defaults.v1")
        let migratedStreetLabelsManager = BLEManager()
        assert(migratedStreetLabelsManager.mapLabelsEnabled,
               "pre-release street-label profiles migrate Map labels on")
        assertEqual(migratedStreetLabelsManager.mapLabelDensity, 2,
                    "pre-release street-label profiles migrate to Balanced")
        assertEqual(migratedStreetLabelsManager.mapLabelLanguageMode, 2,
                    "pre-release street-label profiles migrate to Local + Preferred")
        assertEqual(migratedStreetLabelsManager.mapLabelTextSize, 0,
                    "pre-release street-label profiles migrate to the new Small tier")
        assertEqual(migratedStreetLabelsManager.mapLabelOrientation, 1,
                    "pre-release street-label profiles migrate to Keep Upright")
        assert(!migratedStreetLabelsManager.mapPlusNavigationLabelsEnabled,
               "pre-release street-label profiles migrate Map + Navigation labels off")

        defaults.set(0x0F, forKey: "deviceSettings.enabledScreensMask")
        defaults.removeObject(forKey: "deviceSettings.enabledScreensMask.batteryStatus.v1")
        let batteryScreenMigratedManager = BLEManager()
        assert(batteryScreenMigratedManager.isDeviceScreenEnabled(.batteryStatus),
               "existing four-screen installs enable Battery Status once")

        let restartedFreshManager = BLEManager()
        assert(!restartedFreshManager.mapPlusNavigationShowBuildings,
               "the capability-aware default remains pending across app restarts")
        restartedFreshManager.isConnected = true
        restartedFreshManager.isNavigationReady = true
        var freshProfilePackets: [Data] = []
        restartedFreshManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { freshProfilePackets.append($0) }
        ))
        let independentCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask |
                  DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(restartedFreshManager.handleDeviceCapabilitiesNotification(independentCapabilities),
               "fresh profiles negotiate independent map settings")
        let freshVisibilityPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID
        }
        let freshDetailPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID
        }
        let freshRoutePacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID
        }
        let freshStreetPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID
        }
        let freshZoomPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID
        }
        assert(freshVisibilityPacket != nil,
               "fresh Map + Navigation visibility is sent after capability negotiation")
        assert(freshDetailPacket != nil,
               "fresh Map + Navigation detail is sent after capability negotiation")
        assertEqual(readInt32LE(freshVisibilityPacket!, offset: 5), 0x1038,
                    "older firmware receives major roads, local roads, and water without buildings")
        assertEqual(readInt32LE(freshDetailPacket!, offset: 5), 0,
                    "fresh Map + Navigation sends low detail")
        assertEqual(readInt32LE(freshRoutePacket!, offset: 5), 15,
                    "fresh Map + Navigation sends a 15 px route")
        assertEqual(readInt32LE(freshStreetPacket!, offset: 5), 0,
                    "fresh Map + Navigation encodes its 4 px street width compatibly")
        assertEqual(readInt32LE(freshZoomPacket!, offset: 5), 3,
                    "fresh Map + Navigation sends zoom level 3")

        freshProfilePackets.removeAll()
        let buildingCapabilities =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0x18, 0x10, 0, 0])
        assert(restartedFreshManager.handleDeviceCapabilitiesNotification(buildingCapabilities),
               "CAP2 3D-building support upgrades the fresh visibility default")
        let buildingVisibilityPacket = freshProfilePackets.first {
            $0.count == 9 &&
                $0[4] == DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID
        }
        let buildingExtrusionPacket = freshProfilePackets.first {
            $0.count == 9 &&
                $0[4] == DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID
        }
        assert(restartedFreshManager.mapPlusNavigationShowBuildings,
               "fresh profiles show buildings only after CAP2 advertises 3D support")
        assertEqual(readInt32LE(buildingVisibilityPacket!, offset: 5), 0x1039,
                    "3D-capable firmware receives building visibility")
        assertEqual(readInt32LE(buildingExtrusionPacket!, offset: 5), 1,
                    "setting ID 35 enables 3D extrusion for the fresh profile")
        restartedFreshManager.streetLineWidth = 7
        restartedFreshManager.sendSetting(id: 9, value: 7)
        let customStreetPacket = freshProfilePackets.last { $0.count == 9 && $0[4] == 9 }
        assertEqual(readInt32LE(customStreetPacket!, offset: 5), 3,
                    "a displayed 7 px street width uses the compatible +3 wire value")

        defaults.set(true, forKey: "mapPlusNavigationSettings.migrated.v1")
        defaults.removeObject(forKey: "mapSettings.recommendedDefaults.v2")
        defaults.set(0, forKey: "mapPlusNavigationSettings.detailLevel")
        defaults.set(4.0, forKey: "mapPlusNavigationSettings.routeLineWidth")
        defaults.set(4.0, forKey: "mapPlusNavigationSettings.streetLineWidth")
        defaults.set(2.0, forKey: "mapPlusNavigationSettings.positionMarkerScale")
        defaults.set(2, forKey: "mapPlusNavigationSettings.zoomLevel")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showBuildings")
        defaults.set(true, forKey: "mapPlusNavigationSettings.showGreenSpace")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showPaths")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showTracks")
        defaults.set(true, forKey: "mapPlusNavigationSettings.showMajorRoads")
        defaults.set(true, forKey: "mapPlusNavigationSettings.showLocalStreets")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showServiceRoads")
        defaults.set(true, forKey: "mapPlusNavigationSettings.showWater")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showRailways")
        defaults.set(false, forKey: "mapPlusNavigationSettings.showOtherAreas")
        let recommendedDefaultsMigratedManager = BLEManager()
        assertEqual(recommendedDefaultsMigratedManager.mapPlusNavigationRouteLineWidth, 15,
                    "the former Map + Navigation route default migrates to 15 px")
        assertEqual(recommendedDefaultsMigratedManager.mapPlusNavigationZoomLevel, 3,
                    "the former Map + Navigation zoom default migrates to level 3")
        assert(!recommendedDefaultsMigratedManager.mapPlusNavigationShowGreenSpace,
               "the former Map + Navigation visibility preset drops green space")

        defaults.set(DeviceScreen.map.rawValue, forKey: "deviceSettings.defaultScreen")
        defaults.removeObject(forKey: "deviceSettings.defaultScreen.mapPlusNavigationDefault.v1")
        let migratedManager = BLEManager()
        assertEqual(migratedManager.defaultDeviceScreen, .mapPlusNavigation, "old Map defaults migrate to Map + Navigation")

        defaults.set(1, forKey: "mapSettings.detailLevel")
        defaults.set(4, forKey: "mapSettings.zoomLevel")
        defaults.removeObject(forKey: "mapSettings.streetLineWidth")
        defaults.set(4, forKey: "mapSettings.streetLineWidthBoost")
        defaults.set(false, forKey: "mapSettings.showBuildings")
        defaults.set(false, forKey: "mapSettings.showPaths")
        defaults.set(false, forKey: "mapSettings.showLocalStreets")
        defaults.removeObject(forKey: "mapSettings.showTracks")
        defaults.removeObject(forKey: "mapSettings.showServiceRoads")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.showTracks")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.showServiceRoads")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.migrated.v1")
        let migratedProfileManager = BLEManager()
        assertEqual(migratedProfileManager.streetLineWidth, 8,
                    "legacy Map street boosts migrate to absolute widths")
        assertEqual(migratedProfileManager.mapPlusNavigationDetailLevel, 1,
                    "existing shared detail migrates into Map + Navigation")
        assertEqual(migratedProfileManager.mapPlusNavigationZoomLevel, 4,
                    "existing shared zoom migrates into Map + Navigation")
        assert(!migratedProfileManager.mapPlusNavigationShowBuildings,
               "existing shared visibility migrates into Map + Navigation")
        migratedProfileManager.isConnected = true
        migratedProfileManager.isNavigationReady = true
        var migratedPackets: [Data] = []
        migratedProfileManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { migratedPackets.append($0) }
        ))
        assert(migratedProfileManager.handleDeviceCapabilitiesNotification(
            buildingCapabilities
        ), "3D-capable firmware accepts a migrated profile")
        let migratedVisibilityPacket = migratedPackets.first {
            $0.count == 9 &&
                $0[4] == DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID
        }
        assert(!migratedProfileManager.mapPlusNavigationShowBuildings,
               "CAP2 preserves an existing profile's hidden-building choice")
        assertEqual(readInt32LE(migratedVisibilityPacket!, offset: 5) & 1, 0,
                    "migrated hidden-building visibility remains disabled on 3D firmware")
        assert(!migratedProfileManager.showTracks && !migratedProfileManager.mapPlusNavigationShowTracks,
               "track visibility inherits the previous paths setting")
        assert(!migratedProfileManager.showServiceRoads && !migratedProfileManager.mapPlusNavigationShowServiceRoads,
               "service-road visibility inherits the previous local-streets setting")

        let manager = BLEManager()
        manager.mapRotationMode = 1
        manager.zoomLevel = 5
        manager.mapPlusNavigationDetailLevel = 0
        manager.mapPlusNavigationZoomLevel = 3
        manager.mapPlusNavigationShowBuildings = true
        manager.showTracks = false
        manager.showServiceRoads = false
        manager.mapPlusNavigationShowTracks = false
        manager.mapPlusNavigationShowServiceRoads = false
        manager.mapLabelsEnabled = false
        manager.mapLabelDensity = 1
        manager.mapLabelLanguageMode = 0
        manager.mapLabelTextSize = 2
        manager.mapLabelOrientation = 0
        manager.mapPlusNavigationLabelsEnabled = true
        manager.mapPlusNavigationLabelDensity = 3
        manager.enabledDeviceScreensMask = DeviceScreen.navigation.bit | DeviceScreen.mapPlusNavigation.bit
        manager.defaultDeviceScreen = .mapPlusNavigation
        manager.disconnectedSleepTimeout = .tenMinutes
        manager.saveSettings()

        let reloaded = BLEManager()
        assertEqual(reloaded.mapRotationMode, 1, "map rotation mode should persist across BLEManager reloads")
        assertEqual(reloaded.zoomLevel, 5, "zoom level should persist across BLEManager reloads")
        assertEqual(reloaded.mapPlusNavigationDetailLevel, 0,
                    "Map + Navigation detail should persist independently")
        assertEqual(reloaded.mapPlusNavigationZoomLevel, 3,
                    "Map + Navigation zoom should persist independently")
        assert(reloaded.mapPlusNavigationShowBuildings,
               "Map + Navigation visibility should persist independently")
        assert(!reloaded.showTracks, "Map track visibility should persist")
        assert(!reloaded.showServiceRoads, "Map service-road visibility should persist")
        assert(!reloaded.mapPlusNavigationShowTracks,
               "Map + Navigation track visibility should persist independently")
        assert(!reloaded.mapPlusNavigationShowServiceRoads,
               "Map + Navigation service-road visibility should persist independently")
        assert(!reloaded.mapLabelsEnabled,
               "Map street-label visibility should persist")
        assertEqual(reloaded.mapLabelDensity, 1,
                    "Map street-label density should persist independently from visibility")
        assertEqual(reloaded.mapLabelLanguageMode, 0,
                    "Map street-label language should persist")
        assertEqual(reloaded.mapLabelTextSize, 2,
                    "Map street-label text size should persist")
        assertEqual(reloaded.mapLabelOrientation, 0,
                    "Map street-label orientation should persist")
        assert(reloaded.mapPlusNavigationLabelsEnabled,
               "Map + Navigation street-label visibility should persist")
        assertEqual(reloaded.mapPlusNavigationLabelDensity, 3,
                    "Map + Navigation street-label density should persist independently")
        assertEqual(reloaded.enabledDeviceScreensMask,
                    DeviceScreen.navigation.bit | DeviceScreen.mapPlusNavigation.bit,
                    "enabled device screens should persist across BLEManager reloads")
        assertEqual(reloaded.defaultDeviceScreen, .mapPlusNavigation, "default device screen should persist across BLEManager reloads")
        assertEqual(reloaded.disconnectedSleepTimeout, .tenMinutes, "disconnected sleep timeout should persist across BLEManager reloads")

        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    static func testBLEManagerPersistsDeviceSoundSettings() {
        let defaults = UserDefaults.standard
        let deviceSoundsEnabledKey = "deviceSettings.deviceSoundsEnabled"
        let soundKey = "deviceSettings.selectedSound"
        let volumeKey = "deviceSettings.soundVolumePercent"
        let powerButtonHonkKey = "deviceSettings.powerButtonHonkEnabled"
        defaults.removeObject(forKey: deviceSoundsEnabledKey)
        defaults.removeObject(forKey: soundKey)
        defaults.removeObject(forKey: volumeKey)
        defaults.removeObject(forKey: powerButtonHonkKey)

        let freshManager = BLEManager()
        assert(!freshManager.deviceSoundsEnabled, "fresh installs leave device sounds disabled")
        assertEqual(freshManager.selectedDeviceSound, .plasticBicycleHorn, "fresh installs use the bicycle horn")
        assertEqual(freshManager.deviceSoundVolumePercent, 70, "fresh installs use 70 percent sound volume")
        assert(!freshManager.isPowerButtonHonkEnabled, "fresh installs leave PWR honk disabled")

        freshManager.deviceSoundsEnabled = true
        freshManager.selectedDeviceSound = .squeezeHorn
        freshManager.deviceSoundVolumePercent = 65
        freshManager.isPowerButtonHonkEnabled = true
        freshManager.saveSettings()

        let reloaded = BLEManager()
        assert(reloaded.deviceSoundsEnabled, "device sounds enabled state persists")
        assertEqual(reloaded.selectedDeviceSound, .squeezeHorn, "selected sound persists")
        assertEqual(reloaded.deviceSoundVolumePercent, 65, "sound volume persists")
        assert(reloaded.isPowerButtonHonkEnabled, "PWR honk enabled state persists")

        defaults.set(3, forKey: soundKey)
        let retiredValue = BLEManager()
        assertEqual(retiredValue.selectedDeviceSound, .plasticBicycleHorn,
                    "the retired rotating-bell ID migrates to the default horn")

        defaults.set(4, forKey: soundKey)
        defaults.set(Double.nan, forKey: volumeKey)
        let invalidValues = BLEManager()
        assertEqual(invalidValues.selectedDeviceSound, .plasticBicycleHorn, "unknown sound IDs fall back safely")
        assertEqual(invalidValues.deviceSoundVolumePercent, 70, "non-finite persisted volume falls back safely")

        defaults.removeObject(forKey: deviceSoundsEnabledKey)
        defaults.removeObject(forKey: soundKey)
        defaults.removeObject(forKey: volumeKey)
        defaults.removeObject(forKey: powerButtonHonkKey)
    }

    static func testNavigationSendTrackerReadinessRetry() {
        var tracker = NavigationSendTracker(distanceThreshold: 10)
        let snapshot = NavigationManeuverSnapshot(iconID: NavigationIconID.left, distance: 120, instruction: "Turn left")

        assertEqual(snapshot.packet, "2|120|Turn left", "snapshot builds firmware packet")
        assert(tracker.shouldSend(snapshot), "first snapshot should send")

        tracker.markSent(snapshot)
        assert(!tracker.shouldSend(snapshot), "same snapshot should not resend after successful write")
        assert(!tracker.shouldSend(NavigationManeuverSnapshot(iconID: NavigationIconID.left, distance: 115, instruction: "Turn left")), "small distance delta should not resend")
        assert(tracker.shouldSend(NavigationManeuverSnapshot(iconID: NavigationIconID.left, distance: 110, instruction: "Turn left")), "threshold distance delta should resend")
        assert(tracker.shouldSend(NavigationManeuverSnapshot(iconID: NavigationIconID.right, distance: 120, instruction: "Turn right")), "instruction change should resend")

        tracker.resetForReadinessRetry()
        assert(tracker.shouldSend(snapshot), "readiness retry should resend current snapshot without reprocessing route location")
    }

    static func testNavigationSnapshotTransportDistanceBounds() {
        let oversized = NavigationManeuverSnapshot(
            iconID: NavigationIconID.straight,
            distance: 70_000,
            instruction: "Continue"
        )
        let negative = NavigationManeuverSnapshot(
            iconID: NavigationIconID.straight,
            distance: -10,
            instruction: "Continue"
        )

        assertEqual(
            oversized.packet,
            "1|65535|Continue",
            "navigation packet saturates distance to the firmware UInt16 field"
        )
        assertEqual(
            negative.packet,
            "1|0|Continue",
            "navigation packet does not transmit a negative distance"
        )
    }

    static func testNavigationEngineUsesStepPolylineDistance() {
        let firstStepCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9990)
        ]
        let secondStepCoordinates = [
            firstStepCoordinates[3],
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9970)
        ]
        let firstStep = TestRouteStep(instructions: "Turn right", coordinates: firstStepCoordinates)
        let secondStep = TestRouteStep(instructions: "Continue", coordinates: secondStepCoordinates)
        let route = TestRoute(
            steps: [firstStep, secondStep],
            coordinates: firstStepCoordinates + Array(secondStepCoordinates.dropFirst())
        )
        let start = CLLocation(
            latitude: firstStepCoordinates[0].latitude,
            longitude: firstStepCoordinates[0].longitude
        )
        let endpoint = CLLocation(
            latitude: firstStepCoordinates[3].latitude,
            longitude: firstStepCoordinates[3].longitude
        )
        guard let expectedDistance = RouteProgress.remainingDistance(from: start, in: route.steps[0]) else {
            assert(false, "navigation test step should have measurable geometry")
            return
        }

        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        engine.startNavigation(with: route, initialLocation: start)

        assertEqual(
            engine.distanceToManeuver,
            Int(expectedDistance),
            "navigation engine publishes remaining step polyline distance"
        )
        assert(
            Double(engine.distanceToManeuver) > start.distance(from: endpoint) * 2.5,
            "navigation engine should not publish straight-line endpoint distance"
        )
        assert(
            Double(engine.distanceToManeuver) < route.distance - secondStep.distance / 2,
            "navigation engine uses only the active step rather than whole-route distance"
        )
        assertEqual(manager.sentPackets.count, 1, "initial maneuver is sent to the BLE device")
        let fields = manager.sentPackets[0].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        assertEqual(fields.count, 3, "polyline-distance packet uses firmware fields")
        assertEqual(
            String(fields[1]),
            "\(Int(expectedDistance))",
            "BLE packet carries the active-step polyline distance"
        )
    }

    static func testNavigationEngineDoesNotSkipNearbyCurvedEndpoint() {
        let firstStepCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0006, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0006, longitude: -121.9998),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9998)
        ]
        let secondStepCoordinates = [
            firstStepCoordinates[3],
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9988)
        ]
        let firstStep = TestRouteStep(instructions: "Turn right", coordinates: firstStepCoordinates)
        let secondStep = TestRouteStep(instructions: "Continue", coordinates: secondStepCoordinates)
        let route = TestRoute(
            steps: [firstStep, secondStep],
            coordinates: firstStepCoordinates + Array(secondStepCoordinates.dropFirst())
        )
        let noisyStart = testLocation(latitude: 37.0000, longitude: -121.99979)
        let routeStart = CLLocation(
            latitude: firstStepCoordinates[0].latitude,
            longitude: firstStepCoordinates[0].longitude
        )
        let nearbyEndpoint = CLLocation(
            latitude: firstStepCoordinates[3].latitude,
            longitude: firstStepCoordinates[3].longitude
        )
        let startToEndpointDistance = routeStart.distance(from: nearbyEndpoint)
        assert(
            startToEndpointDistance > 10 && startToEndpointDistance < 20,
            "test curved endpoint is in the 10-to-20-meter arrival band"
        )
        assert(
            noisyStart.distance(from: nearbyEndpoint) < noisyStart.distance(from: routeStart),
            "test sample is closer to the return-leg endpoint than the route start"
        )
        assert(noisyStart.distance(from: nearbyEndpoint) < 20, "test endpoint is inside the arrival radius")

        let engine = NavigationEngine()
        engine.startNavigation(with: route, initialLocation: noisyStart)

        assertEqual(engine.currentInstruction, "Turn right", "nearby curved endpoint does not skip the active step")
        assert(
            Double(engine.distanceToManeuver) > 100,
            "nearby curved endpoint keeps its substantial along-step distance"
        )
    }

    static func testNavigationEngineSeedsCurvedProgressAfterStepTransition() {
        let curvedStepCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0006, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0006, longitude: -121.9998),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9998)
        ]
        let entryStepCoordinates = [
            CLLocationCoordinate2D(latitude: 36.9995, longitude: -122.0000),
            curvedStepCoordinates[0]
        ]
        let exitStepCoordinates = [
            curvedStepCoordinates[3],
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9988)
        ]
        let entryStep = TestRouteStep(instructions: "Continue", coordinates: entryStepCoordinates)
        let curvedStep = TestRouteStep(instructions: "Turn right", coordinates: curvedStepCoordinates)
        let exitStep = TestRouteStep(instructions: "Continue", coordinates: exitStepCoordinates)
        let route = TestRoute(
            steps: [entryStep, curvedStep, exitStep],
            coordinates: entryStepCoordinates
                + Array(curvedStepCoordinates.dropFirst())
                + Array(exitStepCoordinates.dropFirst())
        )
        let routeStart = CLLocation(
            latitude: entryStepCoordinates[0].latitude,
            longitude: entryStepCoordinates[0].longitude
        )
        let noisyTransition = testLocation(latitude: 37.0000, longitude: -121.99979)
        let curvedStart = CLLocation(
            latitude: curvedStepCoordinates[0].latitude,
            longitude: curvedStepCoordinates[0].longitude
        )
        let curvedEndpoint = CLLocation(
            latitude: curvedStepCoordinates[3].latitude,
            longitude: curvedStepCoordinates[3].longitude
        )
        let curvedEndpointSeparation = curvedStart.distance(from: curvedEndpoint)
        assert(
            curvedEndpointSeparation > 10 && curvedEndpointSeparation < 20,
            "transition test endpoint is in the 10-to-20-meter arrival band"
        )

        let engine = NavigationEngine()
        engine.startNavigation(with: route, initialLocation: routeStart)
        engine.processExternalLocation(noisyTransition)
        engine.processExternalLocation(noisyTransition)

        assertEqual(
            engine.currentInstruction,
            "Turn right",
            "noisy transition initializes the curved step at its start rather than its nearby endpoint"
        )
        assert(
            Double(engine.distanceToManeuver) > 100,
            "noisy transition preserves the curved step's substantial remaining distance"
        )
    }

    static func testNavigationEngineReportsDistanceAfterPassingManeuver() {
        let firstStepCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let secondStepCoordinates = [
            firstStepCoordinates[1],
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990)
        ]
        let firstStep = TestRouteStep(instructions: "Turn left", coordinates: firstStepCoordinates)
        let secondStep = TestRouteStep(instructions: "Continue", coordinates: secondStepCoordinates)
        let route = TestRoute(
            steps: [firstStep, secondStep],
            coordinates: firstStepCoordinates + Array(secondStepCoordinates.dropFirst())
        )
        let start = CLLocation(
            latitude: firstStepCoordinates[0].latitude,
            longitude: firstStepCoordinates[0].longitude
        )
        let endpoint = CLLocation(
            latitude: firstStepCoordinates[1].latitude,
            longitude: firstStepCoordinates[1].longitude
        )
        let pastEndpoint = CLLocation(latitude: 37.0030, longitude: -121.9997)
        let expectedDistance = Int(pastEndpoint.distance(from: endpoint))

        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        engine.startNavigation(with: route, initialLocation: start)
        engine.processExternalLocation(start)
        engine.processExternalLocation(pastEndpoint)

        assertEqual(engine.currentInstruction, "Turn left", "passing far from the endpoint does not skip the maneuver")
        assert(
            abs(engine.distanceToManeuver - expectedDistance) <= 1,
            "a beyond-endpoint projection reports physical distance back to the maneuver"
        )
        let fields = manager.sentPackets.last?.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        assertEqual(String(fields?[1] ?? ""), "\(expectedDistance)", "BLE packet does not remain at zero after passing the maneuver")
    }

    static func testNavigationEngineUsesDegenerateStepFallback() {
        let endpointCoordinate = CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        let route = TestRoute(instructions: "Arrive", coordinates: [endpointCoordinate])
        let start = CLLocation(latitude: 37.0005, longitude: -122.0000)
        let endpoint = CLLocation(latitude: endpointCoordinate.latitude, longitude: endpointCoordinate.longitude)
        let expectedDistance = Int(start.distance(from: endpoint))

        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        engine.startNavigation(with: route, initialLocation: start)

        assert(
            abs(engine.distanceToManeuver - expectedDistance) <= 1,
            "one-point step falls back to endpoint distance"
        )
        let fields = manager.sentPackets.last?.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        assertEqual(String(fields?[1] ?? ""), "\(expectedDistance)", "fallback distance is sent to the BLE device")
    }

    static func testNavigationEngineKeepsProgressAtRouteCrossing() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        let start = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
        let finalSegmentStart = CLLocation(latitude: coordinates[2].latitude, longitude: coordinates[2].longitude)
        let crossing = CLLocation(latitude: 37.0005, longitude: -121.9995)
        let endpoint = CLLocation(latitude: coordinates[3].latitude, longitude: coordinates[3].longitude)
        let expectedDistance = Int(crossing.distance(from: endpoint))

        let engine = NavigationEngine()
        engine.startNavigation(with: route, initialLocation: start)
        engine.processExternalLocation(start)
        engine.processExternalLocation(finalSegmentStart)
        engine.processExternalLocation(crossing)

        assert(
            abs(engine.distanceToManeuver - expectedDistance) <= 2,
            "sequential progress keeps the rider on the later segment at a route crossing"
        )
    }

    static func testNavigationEngineResendsWhenBLEBecomesReady() {
        let manager = TestBLEManager()
        manager.isConnected = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            CLLocationCoordinate2D(latitude: 31.2314, longitude: 121.4737)
        ]
        let route = TestRoute(instructions: "Turn left onto Test Road", coordinates: coordinates)
        let initialLocation = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)

        engine.startNavigation(with: route, initialLocation: initialLocation)
        assertEqual(manager.sentPackets.count, 0, "navigation should not mark unsent packet while BLE is not ready")

        manager.isNavigationReady = true
        assert(
            waitForMainLoop(timeout: 1) { manager.sentPackets.count == 1 },
            "navigation readiness should resend the current snapshot"
        )
        let fields = manager.sentPackets[0].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        assertEqual(fields.count, 3, "resent packet uses firmware fields")
        assertEqual(String(fields[0]), "\(NavigationIconID.left)", "resent packet keeps current icon")
        assertEqual(String(fields[2]), "Turn left onto Test Road", "resent packet keeps current instruction")
    }

    static func testNavigationEngineDefersReconnectGPSUntilReadinessCommits() {
        let manager = BLEManager()
        manager.isConnected = true
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 64,
                expectsWriteResponse: false,
                canSend: { true },
                write: { writes.append($0) }
            )
        )

        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        engine.processExternalLocation(
            CLLocation(latitude: 1.305, longitude: 103.855)
        )
        assert(writes.isEmpty,
               "cached GPS remains unsent before authentication readiness")

        manager.isNavigationReady = true
        assert(waitForMainLoop(timeout: 1) {
            writes.contains { data in
                String(data: data.prefix(4), encoding: .utf8) ==
                    DeviceBLEProtocol.gpsPositionFallbackPrefix
            }
        }, "committed readiness resends cached GPS and can open the device map")
    }

    static func testNavigationEngineResendsGPSWhenQualityCapabilityArrives() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 1.305,
                longitude: 103.855
            ),
            altitude: 12,
            horizontalAccuracy: 4,
            verticalAccuracy: 5,
            course: 90,
            speed: 6,
            timestamp: Date()
        )
        engine.processExternalLocation(location)
        assertEqual(manager.sentGPSPositions.last?.count, 30,
                    "pre-capability GPS keeps the legacy packet shape")
        manager.sentGPSPositions.removeAll()

        let qualityCapability =
            Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 2, 0])
        assert(manager.handleDeviceCapabilitiesNotification(qualityCapability),
               "GPS-quality capability is accepted")
        assert(waitForMainLoop(timeout: 1) {
            manager.sentGPSPositions.contains { $0.count == 36 }
        }, "capability transition resends the newest cached GPS fix")
        guard let resent = manager.sentGPSPositions.last(where: {
            $0.count == 36
        }) else { return }
        assertEqual(resent.count, 36,
                    "capability-triggered resend includes the quality tail")
        assertEqual(readUInt16LE(resent, offset: 14), 600,
                    "capability-triggered resend retains idle Core Location speed")
        assertEqual(Int(resent[31]), 3,
                    "capability-triggered resend is detector-ready")
    }

    static func testNavigationEngineResendsRouteGeometryNearLastLocation() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0020, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0030, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        engine.startNavigation(with: route)
        engine.processExternalLocation(CLLocation(latitude: coordinates[2].latitude,
                                                  longitude: coordinates[2].longitude))
        manager.sentRouteGeometry.removeAll()

        manager.isNavigationReady = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        manager.isNavigationReady = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        assertEqual(manager.sentRouteGeometry.count, 1, "navigation readiness should resend route geometry")
        guard let firstCoordinate = routeStartCoordinate(from: manager.sentRouteGeometry[0]) else {
            assert(false, "route geometry should include a start coordinate")
            return
        }
        assertCoordinate(firstCoordinate,
                         latitude: coordinates[2].latitude,
                         longitude: coordinates[2].longitude,
                         "route geometry resend should use the latest device location window")
    }

    static func testNavigationEngineRetriesRejectedRouteGeometryOnSameSegment() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        manager.acceptsRouteGeometry = false
        let clock = TestClock()
        let engine = NavigationEngine(now: clock.now)
        engine.setBLEManager(manager)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37, longitude: -122),
            CLLocationCoordinate2D(latitude: 37.01, longitude: -122)
        ]
        let location = testLocation(latitude: 37, longitude: -122)
        engine.startNavigation(
            with: TestRoute(instructions: "Continue", coordinates: coordinates),
            initialLocation: location
        )
        assert(manager.routeGeometryAttempts > 0, "initial geometry must reach the transport")
        assert(manager.sentRouteGeometry.isEmpty, "simulate temporary queue rejection")
        let rejectedAttempts = manager.routeGeometryAttempts
        manager.acceptsRouteGeometry = true
        clock.advance(by: 3)
        engine.sendRouteGeometryIfNeeded(currentLocation: location)
        assertEqual(manager.routeGeometryAttempts, rejectedAttempts + 1,
                    "rejected geometry must retry without requiring movement to another segment")
        assertEqual(manager.sentRouteGeometry.count, 1,
                    "the recovered transport must receive the initial route window")
        engine.stopNavigation()
    }

    static func testNavigationEngineClearsRouteGeometryOnStop() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        engine.startNavigation(with: route)
        manager.sentRouteGeometry.removeAll()

        engine.stopNavigation()

        assertEqual(manager.sentRouteGeometry, [Data()], "stop navigation should clear route geometry")
    }

    static func testNavigationEngineClearsRouteGeometryWhenReadyAndIdle() {
        let manager = TestBLEManager()
        manager.isConnected = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        manager.isNavigationReady = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        assertEqual(manager.sentRouteGeometry, [Data()], "idle readiness should clear route geometry")
    }

    static func testGPSStartupRetriesUseLatestGeneration() {
        var callbacks: [@MainActor () -> Void] = []
        var cancellations = 0
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine(scheduleRetry: { _, callback in
            callbacks.append(callback)
            return { cancellations += 1 }
        })
        engine.setBLEManager(manager)
        let route = TestRoute(instructions: "Continue", coordinates: [
            CLLocationCoordinate2D(latitude: 37, longitude: -122),
            CLLocationCoordinate2D(latitude: 37.01, longitude: -122)
        ])
        engine.startNavigation(with: route, initialLocation: testLocation(latitude: 37, longitude: -122))
        let retired = callbacks
        engine.processExternalLocation(testLocation(latitude: 37.0001, longitude: -122))
        callbacks.forEach { $0() }
        assertEqual(Int32(bitPattern: readUInt32LE(manager.sentGPSPositions.last!, offset: 0)),
                    37_000_100, "both delayed retries publish the latest GPS, never the initial fix")
        engine.stopNavigation()
        engine.startNavigation(with: route, initialLocation: testLocation(latitude: 37.0002, longitude: -122))
        let count = manager.sentGPSPositions.count
        retired.forEach { $0() }
        assertEqual(manager.sentGPSPositions.count, count, "retired callbacks cannot publish into a successor navigation epoch")
        assert(cancellations >= 2, "stop cancels outstanding retries")
        engine.stopNavigation()
    }

    static func testNavigationEngineRefreshesElapsedWithoutLocationChange() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let clock = TestClock()
        let engine = NavigationEngine(now: clock.now)
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        let initialLocation = testLocation(
            latitude: coordinates[0].latitude,
            longitude: coordinates[0].longitude
        )

        engine.startNavigation(with: route, initialLocation: initialLocation)
        manager.sentGPSPositions.removeAll()
        clock.advance(by: 7)
        engine.refreshRideTelemetryForTesting()

        assertEqual(manager.sentGPSPositions.count, 1,
                    "navigation heartbeat should refresh telemetry without movement")
        guard let packet = manager.sentGPSPositions.first else { return }
        assertEqual(readUInt32LE(packet, offset: 18), 0,
                    "stationary heartbeat should preserve ride distance")
        assertEqual(readUInt32LE(packet, offset: 22), 7,
                    "stationary heartbeat should advance elapsed time")
        engine.stopNavigation()
    }

    static func testNavigationEngineClearsRideTelemetryOnStop() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        let initialLocation = testLocation(
            latitude: coordinates[0].latitude,
            longitude: coordinates[0].longitude
        )
        engine.startNavigation(with: route, initialLocation: initialLocation)
        manager.sentGPSPositions.removeAll()

        engine.stopNavigation()

        assertEqual(manager.sentGPSPositions.count, 1,
                    "stopping navigation should immediately send idle telemetry")
        guard let packet = manager.sentGPSPositions.first else { return }
        assertEqual(readUInt16LE(packet, offset: 14),
                    DeviceGPSPacketBuilder.invalidSpeedCmps,
                    "stopped navigation should clear ride speed")
        assertEqual(readInt16LE(packet, offset: 16), 0,
                    "stopped navigation should clear ride altitude")
        assertEqual(readUInt32LE(packet, offset: 18), 0,
                    "stopped navigation should clear ride distance")
        assertEqual(readUInt32LE(packet, offset: 22), 0,
                    "stopped navigation should clear elapsed time")
        assertEqual(readUInt32LE(packet, offset: 26),
                    DeviceGPSPacketBuilder.invalidRouteRemainingMeters,
                    "stopped navigation should clear route remaining")
    }

    static func testNavigationEngineRestoresPhysicalGPSAfterSimulation() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let initialPhysicalLocation = CLLocation(latitude: 37.1, longitude: -122.1)
        engine.processExternalLocation(initialPhysicalLocation)
        manager.sentGPSPositions.removeAll()

        let route = TestRoute(
            instructions: "Continue",
            coordinates: [
                CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
                CLLocationCoordinate2D(latitude: 1.31, longitude: 103.81)
            ]
        )
        engine.startNavigation(with: route, isTestMode: true)

        let latestPhysicalLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.2, longitude: -122.2),
            altitude: 88,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 45,
            speed: 7,
            timestamp: Date()
        )
        engine.processExternalLocation(latestPhysicalLocation)
        assertEqual(
            manager.sentGPSPositions.count,
            0,
            "physical GPS should be cached without overriding active simulation"
        )

        engine.stopNavigation()

        assertEqual(
            manager.sentGPSPositions.count,
            1,
            "stopping simulation should immediately restore the latest physical GPS"
        )
        guard let packet = manager.sentGPSPositions.first else { return }
        assertEqual(readInt32LE(packet, offset: 0), 37_200_000, "restored GPS should use physical latitude")
        assertEqual(readInt32LE(packet, offset: 4), -122_200_000, "restored GPS should use physical longitude")
        assertEqual(
            readUInt16LE(packet, offset: 14),
            700,
            "restored idle GPS retains raw speed for ride detection"
        )
        assertEqual(readInt16LE(packet, offset: 16), 0, "restored idle GPS should omit altitude")
        assertEqual(readUInt32LE(packet, offset: 18), 0, "restored idle GPS should omit distance")
        assertEqual(readUInt32LE(packet, offset: 22), 0, "restored idle GPS should omit elapsed time")
        assertEqual(
            readUInt32LE(packet, offset: 26),
            DeviceGPSPacketBuilder.invalidRouteRemainingMeters,
            "restored idle GPS should omit route remaining distance"
        )
    }

    static func testNavigationEngineKeepsPhysicalGPSAfterSimulationStepCompletion() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let physicalLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.3, longitude: -122.3),
            altitude: 91,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 50,
            speed: 8,
            timestamp: Date()
        )
        engine.processExternalLocation(physicalLocation)
        manager.sentGPSPositions.removeAll()

        let routeCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
            CLLocationCoordinate2D(latitude: 37.001, longitude: -122.0)
        ]
        let route = TestRoute(
            steps: [
                TestRouteStep(instructions: "Continue", coordinates: routeCoordinates),
                TestRouteStep(instructions: "", coordinates: [])
            ],
            coordinates: routeCoordinates
        )
        engine.startNavigation(with: route, isTestMode: true)
        engine.updateSimulationForTesting(timeInterval: 10)

        assertEqual(
            manager.sentGPSPositions.count,
            1,
            "step-based simulation completion should leave one restored physical GPS packet"
        )
        guard let packet = manager.sentGPSPositions.first else { return }
        assertEqual(readInt32LE(packet, offset: 0), 37_300_000, "completion should retain physical latitude")
        assertEqual(readInt32LE(packet, offset: 4), -122_300_000, "completion should retain physical longitude")
        assertEqual(
            readUInt16LE(packet, offset: 14),
            800,
            "completion restore retains raw speed for ride detection"
        )
    }

    static func testNavigationEngineOmitsRideTelemetryWhenIdle() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let idleLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            altitude: 42,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 5,
            timestamp: Date()
        )
        engine.processExternalLocation(idleLocation)

        let updatedIdleLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0001, longitude: -122.0001),
            altitude: 43,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 95,
            speed: 6,
            timestamp: Date()
        )
        engine.processExternalLocation(updatedIdleLocation)

        assertEqual(manager.sentGPSPositions.count, 2, "every idle map location should update the device position")
        let packet = manager.sentGPSPositions[1]
        assertEqual(readInt32LE(packet, offset: 0), 37_000_100, "idle GPS update should use the latest latitude")
        assertEqual(readInt32LE(packet, offset: 4), -122_000_100, "idle GPS update should use the latest longitude")
        assertEqual(readUInt16LE(packet, offset: 14),
                    600,
                    "idle GPS sync retains speed needed by ride detection")
        assertEqual(readInt16LE(packet, offset: 16), 0, "idle GPS sync should omit altitude telemetry")
        assertEqual(readUInt32LE(packet, offset: 18), 0, "idle GPS sync should omit distance telemetry")
        assertEqual(readUInt32LE(packet, offset: 22), 0, "idle GPS sync should omit elapsed telemetry")
        assertEqual(readUInt32LE(packet, offset: 26),
                    DeviceGPSPacketBuilder.invalidRouteRemainingMeters,
                    "idle GPS sync should omit route remaining telemetry")
    }

    static func testMapTrackingPolicy() {
        assert(
            MainMapSearchLayoutPolicy.showsSupplementaryMapChrome(
                isSearchPanelExpanded: false
            ),
            "collapsed search should leave supporting map controls visible"
        )
        assert(
            !MainMapSearchLayoutPolicy.showsSupplementaryMapChrome(
                isSearchPanelExpanded: true
            ),
            "expanded search should own the keyboard-safe layout"
        )
        assertEqual(
            MapTrackingPolicy.desiredMode(
                isNavigating: false,
                isOfflineMapSelectionActive: false,
                isDestinationSelectionActive: false
            ),
            .follow,
            "dot mode should follow the current location"
        )
        assertEqual(
            MapTrackingPolicy.desiredMode(
                isNavigating: true,
                isOfflineMapSelectionActive: false,
                isDestinationSelectionActive: false
            ),
            .followWithHeading,
            "navigation should follow the current location and heading"
        )
        assertEqual(
            MapTrackingPolicy.desiredMode(
                isNavigating: false,
                isOfflineMapSelectionActive: true,
                isDestinationSelectionActive: false
            ),
            .none,
            "offline map selection should remain free to pan"
        )
        assertEqual(
            MapTrackingPolicy.desiredMode(
                isNavigating: true,
                isOfflineMapSelectionActive: true,
                isDestinationSelectionActive: false
            ),
            .none,
            "offline map selection should override navigation heading-follow"
        )
        assertEqual(
            MapTrackingPolicy.desiredMode(
                isNavigating: false,
                isOfflineMapSelectionActive: false,
                isDestinationSelectionActive: true
            ),
            .none,
            "a selected long-press destination should remain visible while GPS updates"
        )
        assertEqual(
            RideSheetLayoutPolicy.compactHeight(
                isAccessibilitySize: false,
                maximumHeight: 1_000
            ),
            280,
            "the standard compact ride sheet retains its intended height"
        )
        assertEqual(
            RideSheetLayoutPolicy.compactHeight(
                isAccessibilitySize: true,
                maximumHeight: 1_000
            ),
            360,
            "accessibility sizes retain the taller compact ride sheet"
        )
        assertEqual(
            RideSheetLayoutPolicy.compactHeight(
                isAccessibilitySize: false,
                maximumHeight: 300
            ),
            216,
            "compact sheet height remains bounded on short screens"
        )
        assertEqual(
            RideSheetLayoutPolicy.mapControlsBottomPadding(
                isRideSheetPresented: true,
                isCompactDetent: true,
                isAccessibilitySize: false,
                maximumHeight: 1_000,
                safeAreaBottom: 34
            ),
            326,
            "map controls clear the compact ride sheet and bottom safe area"
        )
        assertEqual(
            RideSheetLayoutPolicy.mapControlsBottomPadding(
                isRideSheetPresented: true,
                isCompactDetent: false,
                isAccessibilitySize: false,
                maximumHeight: 1_000,
                safeAreaBottom: 34
            ),
            12,
            "expanded ride sheets do not reserve unreachable background space"
        )
        assertEqual(
            RideSheetLayoutPolicy.mapControlsBottomPadding(
                isRideSheetPresented: false,
                isCompactDetent: true,
                isAccessibilitySize: false,
                maximumHeight: 1_000,
                safeAreaBottom: 34
            ),
            12,
            "map controls use their standard inset without the ride sheet"
        )
    }

    @MainActor
    static func testRideActivityPolicy() {
        let now = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let store = storeForActiveWorkout(at: now)
        var tracker = WorkoutServiceActivityTracker()
        assert(
            tracker.shouldMaintainServices(
                for: store.presentation,
                at: now
            ),
            "a connected live workout should power companion services"
        )
        store.disconnect(error: .watchUnavailable)
        assert(
            tracker.shouldMaintainServices(
                for: store.presentation,
                at: now
            ),
            "a disconnected active workout should start a bounded service grace period"
        )
        assert(
            tracker.shouldMaintainServices(
                for: store.presentation,
                at: now.addingTimeInterval(
                    WorkoutServiceActivityTracker.reconnectionGracePeriod
                )
            ),
            "a disconnected active workout should retain services through the grace boundary"
        )
        assert(
            !tracker.shouldMaintainServices(
                for: store.presentation,
                at: now.addingTimeInterval(
                    WorkoutServiceActivityTracker.reconnectionGracePeriod
                        + 0.001
                )
            ),
            "an unverified active state should not power services indefinitely"
        )

        let staleStore = storeForActiveWorkout(at: now)
        var staleTracker = WorkoutServiceActivityTracker()
        _ = staleTracker.shouldMaintainServices(
            for: staleStore.presentation,
            at: now
        )
        let becameStaleAt = now.addingTimeInterval(
            WorkoutMirrorStateReducer.defaultStaleAfter + 0.001
        )
        staleStore.refreshFreshness(at: becameStaleAt)
        assertEqual(
            staleStore.presentation.connectionState,
            .stale,
            "the service policy test should exercise a genuinely stale mirror"
        )
        assert(
            staleTracker.shouldMaintainServices(
                for: staleStore.presentation,
                at: becameStaleAt
            ),
            "a stale live workout should retain services during reconnection grace"
        )
        assert(
            !staleTracker.shouldMaintainServices(
                for: staleStore.presentation,
                at: becameStaleAt.addingTimeInterval(
                    WorkoutServiceActivityTracker.reconnectionGracePeriod
                        + 0.001
                )
            ),
            "stale workout grace should also be bounded"
        )

        let reconnectedStore = storeForActiveWorkout(
            at: becameStaleAt.addingTimeInterval(30)
        )
        assert(
            staleTracker.shouldMaintainServices(
                for: reconnectedStore.presentation,
                at: becameStaleAt.addingTimeInterval(30)
            ),
            "a verified reconnect should reactivate services and clear expired grace"
        )
        reconnectedStore.disconnect(error: .watchUnavailable)
        assert(
            staleTracker.shouldMaintainServices(
                for: reconnectedStore.presentation,
                at: becameStaleAt.addingTimeInterval(30)
            ),
            "a later disconnect should receive a fresh bounded grace period"
        )
        assert(
            RideActivityPolicy.shouldTrackLocation(
                isNavigating: false,
                isViewingMap: false,
                isWorkoutActive: true,
                isRefreshingDeviceDestinationLocation: false
            ),
            "a live workout should keep location tracking active"
        )
        assert(
            RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: false,
                isWorkoutActive: true,
                isRefreshingDeviceDestinationLocation: false
            ),
            "a live workout should enable background location tracking without navigation"
        )
        assert(
            !RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: false,
                isWorkoutActive: false,
                isRefreshingDeviceDestinationLocation: false
            ),
            "an idle map view should not enable background location tracking"
        )
        assert(
            RideActivityPolicy.shouldTrackLocation(
                isNavigating: false,
                isViewingMap: false,
                isWorkoutActive: false,
                isRefreshingDeviceDestinationLocation: false,
                isRideDetectionArmed: true
            ) && RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: false,
                isWorkoutActive: false,
                isRefreshingDeviceDestinationLocation: false,
                isRideDetectionArmed: true
            ),
            "armed ride detection keeps iPhone GPS active in the background"
        )
        assert(
            RideActivityPolicy.shouldKeepScreenAwake(
                isNavigating: false,
                isWorkoutActive: true,
                isApplicationActive: true
            ),
            "a foreground live workout should keep the iPhone screen awake"
        )
        assert(
            RideActivityPolicy.shouldKeepScreenAwake(
                isNavigating: true,
                isWorkoutActive: false,
                isApplicationActive: true
            ),
            "foreground navigation should continue keeping the screen awake"
        )
        assert(
            !RideActivityPolicy.shouldKeepScreenAwake(
                isNavigating: false,
                isWorkoutActive: true,
                isApplicationActive: false
            ),
            "the app should restore normal idle behavior while backgrounded"
        )
        assert(
            !RideActivityPolicy.shouldKeepScreenAwake(
                isNavigating: false,
                isWorkoutActive: false,
                isApplicationActive: true
            ),
            "an idle foreground app should allow Auto-Lock"
        )
    }

    static func testDeveloperLocationOverride() {
        let coordinate = DeveloperLocationOverride.coordinate(arguments: [
            "BikeComputer",
            "--device-map-location=1.305,103.855"
        ])
        assert(coordinate != nil, "valid developer location override should parse")
        assertCoordinate(
            coordinate!,
            latitude: 1.305,
            longitude: 103.855,
            "developer location override coordinate"
        )
        assert(
            DeveloperLocationOverride.coordinate(arguments: [
                "BikeComputer",
                "--device-map-location=91,103.855"
            ]) == nil,
            "out-of-range developer location override should be rejected"
        )
        assert(
            DeveloperLocationOverride.coordinate(arguments: [
                "BikeComputer",
                "--device-map-location=1.305"
            ]) == nil,
            "incomplete developer location override should be rejected"
        )

        let timestamp = Date(timeIntervalSinceReferenceDate: 800_600_000)
        let source = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 18,
            horizontalAccuracy: 4,
            verticalAccuracy: 6,
            course: 72,
            speed: 8,
            timestamp: timestamp
        )
        let overridden = DeveloperLocationOverride.applying(coordinate!, to: source)
        assertCoordinate(
            overridden.coordinate,
            latitude: 1.305,
            longitude: 103.855,
            "developer location override application"
        )
        assertEqual(overridden.timestamp, timestamp, "override should preserve timestamp")
        assertEqual(overridden.horizontalAccuracy, 4, "override should preserve accuracy")
        assertEqual(overridden.course, 72, "override should preserve course")
        assertEqual(overridden.speed, 8, "override should preserve speed")
    }

    static func testLocationAuthorizationRemediationPolicy() {
        assertEqual(
            LocationAuthorizationRemediationPolicy.action(
                for: .notDetermined
            ),
            .requestInApp,
            "first-use location access presents the native permission prompt"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.buttonTitle(
                for: .notDetermined
            ),
            "Continue",
            "first-use permission copy does not imply that access is already granted"
        )
        assert(
            !LocationAuthorizationRemediationPolicy.allowsDismissal(
                for: .notDetermined
            ),
            "the pre-permission explanation cannot defer the native prompt"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.action(for: .denied),
            .openSettings,
            "denied location access directs the user to Apple Settings"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.buttonTitle(for: .denied),
            "Open iPhone Settings",
            "denied access clearly identifies the post-decision remediation"
        )
        assert(
            LocationAuthorizationRemediationPolicy.allowsDismissal(for: .denied),
            "post-denial remediation remains optional"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.action(for: .restricted),
            .openSettings,
            "restricted location access directs the user to Apple Settings"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.buttonTitle(
                for: .restricted
            ),
            "Open iPhone Settings",
            "restricted access uses the post-decision settings action"
        )
#if !os(macOS)
        assertEqual(
            LocationAuthorizationRemediationPolicy.action(
                for: .authorizedWhenInUse
            ),
            .none,
            "authorized location access needs no remediation"
        )
        assertEqual(
            LocationAuthorizationRemediationPolicy.buttonTitle(
                for: .authorizedWhenInUse
            ),
            nil,
            "authorized access does not show a permission action"
        )
#endif
        assertEqual(
            LocationAuthorizationRemediationPolicy.action(
                for: .authorizedAlways
            ),
            .none,
            "always-authorized location access needs no remediation"
        )
    }

    static func testNavigationEngineIgnoresFarLocationForRouteProgress() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        let coordinates = [
            CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            CLLocationCoordinate2D(latitude: 31.2314, longitude: 121.4737)
        ]
        let route = TestRoute(instructions: "Turn left onto Test Road", coordinates: coordinates)
        let initialLocation = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)

        engine.startNavigation(with: route, initialLocation: initialLocation)
        assertEqual(manager.sentPackets.count, 1, "ready BLE should send initial source-based packet")

        let unrelatedDeviceLocation = CLLocation(latitude: 32.2304, longitude: 121.4737)
        let accepted = engine.processExternalLocation(unrelatedDeviceLocation)

        assert(!accepted, "far live GPS should not advance route progress")
        assertEqual(manager.sentPackets.count, 1, "far live GPS should not overwrite a route started from another source")
    }

    static func testNavigationEngineReplacesRouteWithoutResettingTelemetry() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true

        let clock = TestClock()
        let engine = NavigationEngine(now: clock.now)
        engine.setBLEManager(manager)

        let originalCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        ]
        let originalRoute = TestRoute(
            instructions: "Continue on original route",
            coordinates: originalCoordinates
        )
        let start = testLocation(latitude: 37.0000, longitude: -122.0000)
        let progress = testLocation(latitude: 37.0002, longitude: -122.0000)
        let latest = testLocation(latitude: 37.0009, longitude: -121.9995)

        engine.startNavigation(with: originalRoute, initialLocation: start)
        clock.advance(by: 10)
        engine.processExternalLocation(progress)
        engine.processExternalLocation(latest)
        guard let telemetryBeforeReplacement = manager.sentGPSPositions.last else {
            assert(false, "navigation should send telemetry before rerouting")
            return
        }
        let distanceBeforeReplacement = readUInt32LE(telemetryBeforeReplacement, offset: 18)
        let elapsedBeforeReplacement = readUInt32LE(telemetryBeforeReplacement, offset: 22)
        assert(distanceBeforeReplacement > 0, "ride distance accumulates before rerouting")
        assertEqual(elapsedBeforeReplacement, 10, "ride elapsed time accumulates before rerouting")

        let rerouteSource = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9995)
        let firstManeuver = CLLocationCoordinate2D(latitude: 37.0006, longitude: -121.9995)
        let replacementEnd = CLLocationCoordinate2D(latitude: 37.0020, longitude: -121.9995)
        let replacementRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Turn left",
                    coordinates: [rerouteSource, firstManeuver]
                ),
                TestRouteStep(
                    instructions: "Continue",
                    coordinates: [firstManeuver, replacementEnd]
                )
            ],
            coordinates: [rerouteSource, firstManeuver, replacementEnd]
        )
        let geometryCountBeforeReplacement = manager.sentRouteGeometry.count

        clock.advance(by: 5)
        engine.replaceRoute(
            with: replacementRoute,
            currentLocation: latest
        )

        assertEqual(engine.currentInstruction, "Continue", "replacement skips an already-passed first maneuver")
        assertEqual(
            manager.sentPackets.last,
            "\(NavigationIconID.straight)|\(engine.distanceToManeuver)|Continue",
            "replacement maneuver is sent to the BLE device"
        )
        assert(
            manager.sentRouteGeometry.count > geometryCountBeforeReplacement,
            "replacement sends new route geometry"
        )
        guard let replacementGeometry = manager.sentRouteGeometry.last,
              let replacementStart = routeStartCoordinate(from: replacementGeometry),
              let telemetryAfterReplacement = manager.sentGPSPositions.last else {
            assert(false, "replacement should send geometry and telemetry")
            return
        }
        assertCoordinate(
            replacementStart,
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            "replacement geometry starts at the rider's latest route position"
        )
        assert(
            readUInt32LE(telemetryAfterReplacement, offset: 18) >= distanceBeforeReplacement,
            "route replacement preserves accumulated ride distance"
        )
        let elapsedAfterReplacement = readUInt32LE(telemetryAfterReplacement, offset: 22)
        assertEqual(elapsedAfterReplacement, 15, "route replacement preserves elapsed ride time")

        clock.advance(by: 1)
        engine.processExternalLocation(testLocation(latitude: 37.0010, longitude: -121.9995))
        guard let telemetryAfterMoreProgress = manager.sentGPSPositions.last else {
            assert(false, "navigation should continue sending telemetry after rerouting")
            return
        }
        assert(
            readUInt32LE(telemetryAfterMoreProgress, offset: 18) >= distanceBeforeReplacement,
            "ride distance remains nondecreasing after rerouting"
        )
        assert(
            readUInt32LE(telemetryAfterMoreProgress, offset: 22) >= elapsedAfterReplacement,
            "elapsed ride time remains nondecreasing after rerouting"
        )
    }

    static func routeStartCoordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard data.count >= 8 else { return nil }

        let latBits = UInt32(data[0]) |
            (UInt32(data[1]) << 8) |
            (UInt32(data[2]) << 16) |
            (UInt32(data[3]) << 24)
        let lonBits = UInt32(data[4]) |
            (UInt32(data[5]) << 8) |
            (UInt32(data[6]) << 16) |
            (UInt32(data[7]) << 24)
        let lat = Int32(bitPattern: latBits)
        let lon = Int32(bitPattern: lonBits)

        return CLLocationCoordinate2D(latitude: Double(lat) / 1_000_000,
                                      longitude: Double(lon) / 1_000_000)
    }
}
