import Foundation

@MainActor
private final class ActivationFrameLog {
    var frames: [Data] = []
}

@MainActor
private final class ActivationOutcomeBox {
    var outcome: DeviceScreenActivationOutcome?
}

extension NavigationProtocolTests {
    /// SCSW/SCSR frames match the firmware host tests and docs/ble-protocol.md.
    @MainActor
    static func testDeviceScreenActivationFrames() {
        assertEqual(RideBLEGeneratedProtocolV1.extendedScreenActivationV1Feature, 1 << 6,
                    "extended bit 6 advertises screen activation")
        assertEqual(RideBLEGeneratedProtocolV1.extendedScreenActivationV1MinimumClientVersion, 36,
                    "screen activation requires the version 36 client")
        assertEqual(
            DeviceScreenActivationFrameCodec.request(requestID: 0x0102_0304, .show([.map, .mapPlusNavigation])),
            Data([0x53, 0x43, 0x53, 0x57, 4, 3, 2, 1, 0, 2, 0, 3]),
            "Show Types matches the shared golden frame"
        )
        assertEqual(DeviceScreenActivationFrameCodec.request(requestID: 9, .next),
                    Data("SCSW".utf8) + Data([9, 0, 0, 0, 1, 0]), "Next carries no types")
        assertEqual(DeviceScreenActivationFrameCodec.request(requestID: 9, .previous),
                    Data("SCSW".utf8) + Data([9, 0, 0, 0, 2, 0]), "Previous carries no types")
        assert(DeviceScreenActivationFrameCodec.request(requestID: 9, .show([])) == nil,
               "an empty preference list is not encoded")
        assert(DeviceScreenActivationFrameCodec.request(
            requestID: 9, .show([.map, .navigation, .rideStats, .elevation, .nearby])) == nil,
               "at most four preferred types are encoded")
        assert(DeviceScreenActivationFrameCodec.request(requestID: 0, .next) == nil,
               "request IDs are nonzero")

        let golden = Data([0x53, 0x43, 0x53, 0x52, 4, 3, 2, 1, 0, 0x0D, 0x0C, 0x0B, 0x0A, 2])
        let expected = DeviceScreenActivationReply(
            requestID: 0x0102_0304,
            result: .switched,
            activeInstanceID: 0x0A0B_0C0D,
            activeScreenType: .rideStats
        )
        assertEqual(DeviceScreenActivationFrameCodec.reply(golden), expected,
                    "Switched matches the shared golden reply")
        assertEqual(DeviceScreenActivationFrameCodec.reply((Data([0xAA]) + golden).dropFirst()), expected,
                    "a notification slice decodes like a zero-based frame")
        var noScreen = golden
        noScreen[13] = 0xFF
        assert(DeviceScreenActivationFrameCodec.reply(noScreen)?.activeScreenType == nil,
               "type 255 reports no visible screen")
        var unknownResult = golden
        unknownResult[8] = 6
        assert(DeviceScreenActivationFrameCodec.reply(unknownResult) == nil, "unknown results are rejected")
        var zeroRequest = golden
        zeroRequest.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        assert(DeviceScreenActivationFrameCodec.reply(zeroRequest) == nil, "request ID zero is rejected")
        assert(DeviceScreenActivationFrameCodec.reply(golden.dropLast()) == nil, "short replies are rejected")
        assert(!DeviceScreenActivationFrameCodec.isReply(Data("SCAK".utf8) + Data(repeating: 0, count: 13)),
               "document acknowledgements are not activation replies")

        assertEqual(DeviceScreenActivationReplyText.text(for: .replied(expected), requested: "Workout"),
                    "Showing Ride Stats on Bicino.", "a switch names the screen now visible")
        var already = expected
        already.result = .alreadyActive
        already.activeScreenType = .mapPlusNavigation
        assertEqual(DeviceScreenActivationReplyText.text(for: .replied(already), requested: "Map"),
                    "Bicino is already showing Map and Navigation.", "a combined screen satisfies Map")
        assertEqual(DeviceScreenActivationReplyText.text(for: .replied(already), requested: nil),
                    "Bicino has only one screen turned on.", "Next on a single screen explains why nothing moved")
        var missing = expected
        missing.result = .noMatchingScreen
        assertEqual(DeviceScreenActivationReplyText.text(for: .replied(missing), requested: "Elevation"),
                    "Bicino has no Elevation screen turned on. You can add one under Bicino Screens in Settings.",
                    "a missing screen points at the settings that add one")
        assertEqual(DeviceScreenActivationReplyText.text(for: .notConnected, requested: "Map"),
                    "Bicino isn't connected to this iPhone.", "no link is reported plainly")
        assertEqual(DeviceScreenActivationReplyText.text(for: .unsupported, requested: "Map"),
                    "This Bicino's firmware can't switch screens from Siri yet.",
                    "firmware without activation is named without promising an update")
    }

    /// One request at a time; replies, refusals, failures, disconnects,
    /// timeouts and superseding requests each end it exactly once. Waits spin
    /// the main run loop like the rest of this runner, which never suspends.
    @MainActor
    static func testDeviceScreenActivationClient() {
        func start(
            _ client: DeviceScreenActivationClient,
            _ request: DeviceScreenActivationRequest,
            log: ActivationFrameLog,
            queued: Bool = true,
            failWrite: Bool = false
        ) -> ActivationOutcomeBox {
            let box = ActivationOutcomeBox()
            Task { @MainActor in
                box.outcome = await client.activate(request) { frame, failed in
                    log.frames.append(frame)
                    if failWrite { failed() }
                    return queued
                }
            }
            return box
        }
        func finished(_ box: ActivationOutcomeBox) -> DeviceScreenActivationOutcome? {
            _ = waitForMainLoop(timeout: 2) { box.outcome != nil }
            return box.outcome
        }
        func reply(_ id: UInt32, result: UInt8) -> Data {
            func littleEndian(_ value: UInt32) -> [UInt8] {
                (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
            }
            return Data("SCSR".utf8) + littleEndian(id) + [result] + littleEndian(7) +
                [RideBLEScreenTypeV1.map.rawValue]
        }

        let client = DeviceScreenActivationClient(timeoutNanoseconds: 5_000_000_000)
        let log = ActivationFrameLog()
        let answered = start(client, .show([.map]), log: log)
        assert(waitForMainLoop(timeout: 2) { !log.frames.isEmpty }, "the request frame is queued")
        let requestID = log.frames[0].dropFirst(4).prefix(4).reversed()
            .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        assert(client.receive(reply(requestID &+ 1, result: 0)), "a stale reply is still consumed")
        assert(!client.receive(Data("SCDN".utf8) + Data(repeating: 1, count: 12)),
               "document traffic passes through to the configuration controller")
        assert(answered.outcome == nil, "a stale reply leaves the request pending")
        assert(client.receive(reply(requestID, result: 1)), "the matching reply is consumed")
        assertEqual(
            finished(answered),
            .replied(DeviceScreenActivationReply(
                requestID: requestID,
                result: .alreadyActive,
                activeInstanceID: 7,
                activeScreenType: .map
            )),
            "only the matching reply completes the request"
        )

        assertEqual(finished(start(client, .next, log: log, queued: false)), .notConnected,
                    "a frame that cannot be queued reports no connection")
        assertEqual(finished(start(client, .next, log: log, failWrite: true)), .noResponse,
                    "a failed write ends the request")

        let disconnected = start(client, .next, log: log)
        assert(waitForMainLoop(timeout: 2) { log.frames.count == 4 }, "the request to disconnect is queued")
        client.disconnect()
        assertEqual(finished(disconnected), .notConnected, "a disconnect ends a pending request")

        let first = start(client, .next, log: log)
        assert(waitForMainLoop(timeout: 2) { log.frames.count == 5 }, "the first request is queued")
        let second = start(client, .previous, log: log)
        assertEqual(finished(first), .noResponse, "a newer request supersedes an unanswered one")
        assert(waitForMainLoop(timeout: 2) { log.frames.count == 6 }, "the newer request is queued")
        client.disconnect()
        assertEqual(finished(second), .notConnected, "the newer request stays answerable")

        let quick = DeviceScreenActivationClient(timeoutNanoseconds: 20_000_000)
        assertEqual(finished(start(quick, .next, log: log)), .noResponse,
                    "an unanswered request times out")
    }

    /// Extended bit 6 counts only beside configurable screens (bit 26).
    @MainActor
    static func testScreenActivationCapability() {
        let manager = BLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let screens = RideBLEGeneratedProtocolV1.screenConfigurationV1Feature
        let header = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) + Data([
            1,
            UInt8(screens & 0xFF), UInt8((screens >> 8) & 0xFF),
            UInt8((screens >> 16) & 0xFF), UInt8((screens >> 24) & 0xFF),
        ])
        let screenLimits = Data([2, 14, 1, 16, 24, 7, 0x1F, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0x00, 0x10])
        let activation = Data([3, 4, 0x40, 0, 0, 0])
        assert(manager.handleDeviceCapabilitiesNotification(header + screenLimits + activation),
               "CAP2 with screen configuration and bit 6 is handled")
        assert(manager.supportsScreenConfiguration && manager.supportsScreenActivation,
               "bit 6 beside screen configuration enables activation")
        assert(manager.handleDeviceCapabilitiesNotification(header + screenLimits),
               "CAP2 without bit 6 is handled")
        assert(manager.supportsScreenConfiguration && !manager.supportsScreenActivation,
               "older firmware keeps configuration without activation")
        let plain = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) + Data([1, 0, 0, 0, 0])
        assert(manager.handleDeviceCapabilitiesNotification(plain + activation),
               "bit 6 without screen configuration is handled")
        assert(!manager.supportsScreenActivation, "bit 6 alone never enables activation")
    }
}
