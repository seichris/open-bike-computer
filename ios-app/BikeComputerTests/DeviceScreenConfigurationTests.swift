import Foundation

private final class ScreenConfigurationRequestIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt32 = 1

    func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue += 1
        return value
    }
}

private func screenConfigurationDownloadFrames(
    requestID: UInt32,
    revision: UInt32,
    document: Data,
    payloadBytes: Int = 17
) -> [Data] {
    let count = (document.count + payloadBytes - 1) / payloadBytes
    return (0..<count).map { index in
        var frame = Data(
            RideBLEGeneratedProtocolV1.screenConfigurationDownloadMagic.utf8
        )
        appendUInt32LE(requestID, to: &frame)
        appendUInt32LE(revision, to: &frame)
        frame.append(UInt8(index))
        frame.append(UInt8(count))
        let lower = index * payloadBytes
        frame.append(document.subdata(
            in: lower..<min(document.count, lower + payloadBytes)
        ))
        return frame
    }
}

private func screenConfigurationAcknowledgement(
    requestID: UInt32,
    result: RideBLEScreenConfigurationResultV1,
    revision: UInt32,
    documentCRC: UInt32
) -> Data {
    var frame = Data(
        RideBLEGeneratedProtocolV1
            .screenConfigurationAcknowledgementMagic.utf8
    )
    appendUInt32LE(requestID, to: &frame)
    frame.append(result.rawValue)
    appendUInt32LE(revision, to: &frame)
    appendUInt32LE(documentCRC, to: &frame)
    return frame
}

func testDeviceScreenConfigurationCodecAndValidation() {
    assert(
        !DeviceScreenSettingsTransportPolicy.usesLegacySettings(
            supportsScreenConfiguration: true
        ),
        "negotiated screen documents suppress legacy profile and screen writes"
    )
    assert(
        DeviceScreenSettingsTransportPolicy.usesLegacySettings(
            supportsScreenConfiguration: false
        ),
        "older firmware continues receiving legacy screen settings"
    )
    let capabilityValue = Data([
        1, 16, 24, 7,
        0x1f, 0, 0, 0,
        0xff, 0xff, 0x01, 0,
        0x00, 0x10,
    ])
    assertEqual(
        DeviceScreenConfigurationCapabilities(tlvValue: capabilityValue),
        .v1,
        "screen capability TLV decodes exact limits and masks"
    )
    assert(
        DeviceScreenConfigurationCapabilities(
            tlvValue: capabilityValue.dropLast()
        ) == nil,
        "screen capability TLV rejects the wrong length"
    )
    let document = DeviceScreenConfigurationDocument.legacyDefault
    guard let encoded = try? DeviceScreenConfigurationCodec.encode(document),
          let decoded = try? DeviceScreenConfigurationCodec.decode(encoded) else {
        assert(false, "default screen configuration should encode and decode")
        return
    }
    assertEqual(decoded, document, "screen configuration binary round trip")
    assertEqual(
        DeviceScreenConfigurationCodec.documentCRC(encoded),
        zipCRC32(Data(encoded.dropLast(4))),
        "screen configuration exposes the document CRC"
    )

    var corrupted = encoded
    corrupted[8] ^= 1
    assert(
        (try? DeviceScreenConfigurationCodec.decode(corrupted)) == nil,
        "screen configuration rejects a CRC mismatch"
    )

    var duplicate = document
    duplicate.instances[1].id = duplicate.instances[0].id
    assert(
        (try? duplicate.validate()) == nil,
        "screen configuration rejects duplicate stable IDs"
    )
    var emptyLayout = document
    emptyLayout.instances[1].rideStatsLayout = RideStatsLayout(
        slots: Array(repeating: .empty, count: RideStatsLayout.slotCount)
    )
    assert(
        (try? emptyLayout.validate()) == nil,
        "Ride Stats requires one visible widget"
    )

    var minimal = DeviceScreenConfigurationDocument(
        defaultInstanceID: 0x0102_0304,
        instances: [
            .defaults(
                id: 0x0102_0304,
                type: .navigation,
                name: "Nav"
            )
        ]
    )
    let minimalGolden = Data([
        0x53, 0x43, 0x56, 0x31, 0x01, 0x01, 0x04, 0x03, 0x02,
        0x01, 0x04, 0x03, 0x02, 0x01, 0x01, 0x01, 0x03, 0x01,
        0x00, 0x4e, 0x61, 0x76, 0x01, 0xd1, 0xb4, 0x07, 0x6f,
    ])
    assertEqual(
        try? DeviceScreenConfigurationCodec.encode(minimal),
        minimalGolden,
        "Swift screen codec matches the cross-language golden vector"
    )
    let originalID = minimal.instances[0].id
    assert(!minimal.setEnabled(false, instanceID: originalID),
           "the only enabled screen cannot be hidden")
    let addedID = try? minimal.add(
        type: .navigation,
        after: originalID,
        generator: DeviceScreenInstanceIDGenerator { 0x1234 }
    )
    assertEqual(addedID, 0x8000_1234, "new screen IDs use the stable generated namespace")
    assertEqual(minimal.instances[1].name, "Navigation 2", "duplicates get distinct default names")
}

@MainActor
func testDeviceScreenConfigurationController() {
    let suite = "DeviceScreenConfigurationTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        assert(false, "screen configuration test defaults should open")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let source = ScreenConfigurationRequestIDSource()
    let controller = DeviceScreenConfigurationController(defaults: defaults)
    controller.setRequestIDGeneratorForTesting(
        DeviceScreenInstanceIDGenerator { source.next() }
    )
    var batches: [[Data]] = []
    controller.connect(
        deviceID: "device-a",
        generation: 10,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { frames, sent, _ in
            batches.append(frames)
            sent()
            return true
        }
    )
    assertEqual(controller.state, .loading, "controller requests a fresh device snapshot")
    guard let request = batches.first?.first else {
        assert(false, "controller should enqueue a snapshot request")
        return
    }
    let requestID = readUInt32LE(request, offset: 4)
    let document = DeviceScreenConfigurationDocument.legacyDefault
    let encoded = try! DeviceScreenConfigurationCodec.encode(document)
    for frame in screenConfigurationDownloadFrames(
        requestID: requestID,
        revision: 7,
        document: encoded
    ) {
        controller.receive(frame, deviceID: "wrong-device", generation: 10)
    }
    assertEqual(controller.state, .loading, "foreign device notifications are ignored")
    for frame in screenConfigurationDownloadFrames(
        requestID: requestID,
        revision: 7,
        document: encoded
    ) {
        controller.receive(frame, deviceID: "device-a", generation: 10)
    }
    assertEqual(controller.state, .ready, "a complete ordered snapshot becomes editable")
    assertEqual(controller.acknowledgedRevision, 7, "snapshot revision is retained")

    var edited = document.instances[0]
    edited.name = "Fast Map + Navigation"
    controller.update(instance: edited)
    assert(controller.canSave, "a valid changed draft can be saved")
    batches.removeAll()
    controller.save()
    assertEqual(controller.state, .saving, "save waits for a device acknowledgement")
    guard let upload = batches.first,
          let firstUpload = upload.first else {
        assert(false, "save should atomically enqueue upload chunks")
        return
    }
    let saveRequestID = readUInt32LE(firstUpload, offset: 4)
    let uploadedDocument = Data(upload.flatMap { $0.dropFirst(14) })
    controller.receive(
        screenConfigurationAcknowledgement(
            requestID: saveRequestID,
            result: .applied,
            revision: 8,
            documentCRC: DeviceScreenConfigurationCodec.documentCRC(
                uploadedDocument
            )!
        ),
        deviceID: "device-a",
        generation: 10
    )
    assertEqual(controller.state, .ready, "matching acknowledgement commits the draft")
    assertEqual(controller.acknowledgedRevision, 8, "acknowledgement advances the revision")
    assert(!controller.canSave, "an acknowledged draft is clean")

    edited.name = "Reconnect Draft"
    controller.update(instance: edited)
    controller.disconnect(deviceID: "device-a", generation: 10)
    batches.removeAll()
    controller.connect(
        deviceID: "device-a",
        generation: 11,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { frames, sent, _ in
            batches.append(frames)
            sent()
            return true
        }
    )
    let reconnectRequestID = readUInt32LE(batches[0][0], offset: 4)
    for frame in screenConfigurationDownloadFrames(
        requestID: reconnectRequestID,
        revision: 8,
        document: uploadedDocument
    ) {
        controller.receive(frame, deviceID: "device-a", generation: 11)
    }
    assertEqual(
        controller.draft?.instances[0].name,
        "Reconnect Draft",
        "a transient reconnect preserves unsaved edits for the same device"
    )

    batches.removeAll()
    controller.save()
    let conflictUpload = batches[0]
    let conflictRequestID = readUInt32LE(conflictUpload[0], offset: 4)
    controller.receive(
        screenConfigurationAcknowledgement(
            requestID: conflictRequestID,
            result: .conflict,
            revision: 8,
            documentCRC: 0
        ),
        deviceID: "device-a",
        generation: 11
    )
    assertEqual(controller.state, .conflict, "stale revision enters explicit conflict state")
    guard let conflictRead = batches.last?.first,
          conflictRead.prefix(4) == Data(
            RideBLEGeneratedProtocolV1.screenConfigurationRequestMagic.utf8
          ) else {
        assert(false, "conflict should immediately request the current device version")
        return
    }
    var remoteDocument = document
    remoteDocument.instances[0].name = "Device Remote"
    let remoteEncoded = try! DeviceScreenConfigurationCodec.encode(remoteDocument)
    let conflictReadID = readUInt32LE(conflictRead, offset: 4)
    for frame in screenConfigurationDownloadFrames(
        requestID: conflictReadID,
        revision: 9,
        document: remoteEncoded
    ) {
        controller.receive(frame, deviceID: "device-a", generation: 11)
    }
    assertEqual(controller.state, .conflict, "fresh device data waits for the user's conflict choice")
    assertEqual(controller.acknowledgedRevision, 9, "conflict reload advances the save base revision")
    assertEqual(controller.draft?.instances[0].name, "Reconnect Draft",
                "conflict reload does not silently replace local edits")
    controller.keepDraftAfterConflict()
    assertEqual(controller.state, .ready, "the user can keep the local draft after reload")
    assert(controller.canSave, "kept conflict edits can be retried against the new revision")

    batches.removeAll()
    controller.save()
    let rejectedSaveID = readUInt32LE(batches[0][0], offset: 4)
    controller.receive(
        screenConfigurationAcknowledgement(
            requestID: rejectedSaveID,
            result: .applied,
            revision: 10,
            documentCRC: 0
        ),
        deviceID: "device-a",
        generation: 11
    )
    assert(
        controller.state == .failed("The device acknowledgement did not match this save."),
        "an applied acknowledgement with the wrong CRC is rejected"
    )
    assert(controller.hasUnsavedChanges,
           "a rejected acknowledgement preserves the user's draft")
    batches.removeAll()
    controller.retry()
    let retryRequestID = readUInt32LE(batches[0][0], offset: 4)
    for frame in screenConfigurationDownloadFrames(
        requestID: retryRequestID,
        revision: 10,
        document: remoteEncoded
    ) {
        controller.receive(frame, deviceID: "device-a", generation: 11)
    }
    assertEqual(controller.state, .ready,
                "retry refreshes the authoritative revision")
    assertEqual(controller.acknowledgedRevision, 10,
                "retry uses the new device revision")
    assertEqual(controller.draft?.instances[0].name, "Reconnect Draft",
                "refresh after a failed write preserves local edits")

    let timeoutController = DeviceScreenConfigurationController(
        defaults: defaults,
        requestTimeoutNanoseconds: 60_000_000_000
    )
    timeoutController.setRequestIDGeneratorForTesting(
        DeviceScreenInstanceIDGenerator { source.next() }
    )
    timeoutController.connect(
        deviceID: "device-timeout",
        generation: 1,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { _, sent, _ in
            sent()
            return true
        }
    )
    timeoutController.expirePendingRequestForTesting()
    assert(
        timeoutController.state == .failed(
            "Timed out waiting for screen settings from the Bike Computer."
        ),
        "a snapshot timeout becomes a recoverable failure"
    )

    var cacheBatches: [[Data]] = []
    let cachedA = DeviceScreenConfigurationController(
        defaults: defaults,
        requestTimeoutNanoseconds: 60_000_000_000
    )
    cachedA.connect(
        deviceID: "device-a",
        generation: 1,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { frames, sent, _ in
            cacheBatches.append(frames)
            sent()
            return true
        }
    )
    assertEqual(
        cachedA.draft?.instances[0].name,
        "Fast Map + Navigation",
        "an acknowledged configuration is cached per bike computer"
    )
    cachedA.disconnect(deviceID: "device-a", generation: 1)

    let uncachedB = DeviceScreenConfigurationController(
        defaults: defaults,
        requestTimeoutNanoseconds: 60_000_000_000
    )
    uncachedB.connect(
        deviceID: "device-b",
        generation: 1,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { _, sent, _ in
            sent()
            return true
        }
    )
    assert(uncachedB.draft == nil,
           "screen configuration cache entries never cross device identities")
    uncachedB.disconnect(deviceID: "device-b", generation: 1)

    cachedA.clearCache(deviceID: "device-a")
    let clearedA = DeviceScreenConfigurationController(
        defaults: defaults,
        requestTimeoutNanoseconds: 60_000_000_000
    )
    clearedA.connect(
        deviceID: "device-a",
        generation: 2,
        capabilities: .v1,
        maximumPlaintextWriteBytes: 40,
        sendFrames: { _, sent, _ in
            sent()
            return true
        }
    )
    assert(clearedA.draft == nil, "forgetting a device clears its screen cache")
    clearedA.disconnect(deviceID: "device-a", generation: 2)
}
