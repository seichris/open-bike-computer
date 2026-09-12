import Foundation

@MainActor
private final class ScreenStateFixture {
    let defaults: UserDefaults
    let suite = "ScreenStateFixture.\(UUID().uuidString)"
    let controller: DeviceScreenConfigurationController
    var frames: [Data] = []
    var generation: UInt64 = 1

    init() {
        defaults = UserDefaults(suiteName: suite)!
        controller = DeviceScreenConfigurationController(defaults: defaults)
        connect()
        snapshot(.legacyDefault, revision: 1)
    }

    func close() {
        controller.disconnect(deviceID: "bike", generation: generation)
        defaults.removePersistentDomain(forName: suite)
    }

    func connect() {
        controller.connect(deviceID: "bike", generation: generation,
                           capabilities: .v1, maximumPlaintextWriteBytes: 512) {
            [weak self] frames, sent, _ in
            self?.frames = frames
            sent()
            return true
        }
    }

    func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map {
            UInt8(truncatingIfNeeded: value >> ($0 * 8))
        })
    }

    func snapshot(_ document: DeviceScreenConfigurationDocument, revision: UInt32) {
        var frame = Data("SCDN".utf8)
        frame.append(frames[0][4..<8])
        append(revision, to: &frame)
        frame.append(contentsOf: [0, 1])
        frame.append(try! DeviceScreenConfigurationCodec.encode(document))
        controller.receive(frame, deviceID: "bike", generation: generation)
    }

    func acknowledgement(_ result: RideBLEScreenConfigurationResultV1, revision: UInt32) {
        let document = Data(frames.flatMap { $0.dropFirst(14) })
        var frame = Data("SCAK".utf8)
        frame.append(frames[0][4..<8])
        frame.append(result.rawValue)
        append(revision, to: &frame)
        append(DeviceScreenConfigurationCodec.documentCRC(document) ?? 0, to: &frame)
        controller.receive(frame, deviceID: "bike", generation: generation)
    }

    func rename(_ name: String) {
        var instance = controller.draft!.instances[0]
        instance.name = name
        controller.update(instance: instance)
    }
}

@MainActor
func testScreenCleanReconnect() {
    let fixture = ScreenStateFixture()
    defer { fixture.close() }
    fixture.controller.disconnect(deviceID: "bike", generation: 1)
    fixture.generation = 2
    fixture.connect()
    var remote = DeviceScreenConfigurationDocument.legacyDefault
    remote.instances[0].name = "New device settings"
    fixture.snapshot(remote, revision: 2)
    assert(fixture.controller.draft == remote,
           "a clean device snapshot is not mistaken for unsaved edits on reconnect")
    assert(!fixture.controller.hasUnsavedChanges)
}

@MainActor
func testScreenEditsDuringReload() {
    let fixture = ScreenStateFixture()
    defer { fixture.close() }
    fixture.rename("Saved cache")
    fixture.controller.save()
    fixture.acknowledgement(.applied, revision: 2)
    fixture.controller.disconnect(deviceID: "bike", generation: 1)
    fixture.generation = 2
    fixture.connect()
    fixture.rename("Edited during reload")
    var remote = DeviceScreenConfigurationDocument.legacyDefault
    remote.instances[0].name = "Device latest"
    fixture.snapshot(remote, revision: 3)
    assert(fixture.controller.acknowledgedDocument == remote)
    assert(fixture.controller.draft?.instances[0].name == "Edited during reload",
           "a snapshot must retain edits made after its request")
    assert(fixture.controller.canSave)
}

@MainActor
func testScreenEditsDuringSave() {
    let fixture = ScreenStateFixture()
    defer { fixture.close() }
    fixture.rename("Submitted")
    fixture.controller.save()
    fixture.rename("Edited while saving")
    fixture.acknowledgement(.applied, revision: 2)
    assert(fixture.controller.acknowledgedDocument?.instances[0].name == "Submitted")
    assert(fixture.controller.draft?.instances[0].name == "Edited while saving",
           "an ACK must not discard edits made after submission")
    assert(fixture.controller.canSave)
}

@MainActor
func testScreenPendingConflictResolution() {
    let fixture = ScreenStateFixture()
    defer { fixture.close() }
    fixture.rename("Local edits")
    fixture.controller.save()
    fixture.acknowledgement(.conflict, revision: 2)
    fixture.controller.keepDraftAfterConflict()
    assert(fixture.controller.state == .conflict,
           "conflict choice waits until the authoritative revision has loaded")
    fixture.controller.reloadDeviceSettings()
    assert(fixture.controller.state == .conflict)
    var remote = DeviceScreenConfigurationDocument.legacyDefault
    remote.instances[0].name = "Remote edits"
    fixture.snapshot(remote, revision: 2)
    fixture.controller.reloadDeviceSettings()
    assert(fixture.controller.state == .ready)
    assert(fixture.controller.draft == remote)

    fixture.rename("Second save")
    fixture.controller.save()
    fixture.controller.reloadDeviceSettings()
    assert(fixture.controller.state == .saving,
           "Cancel Changes cannot reset a save still owned by the device")
    fixture.acknowledgement(.applied, revision: 3)
    assert(fixture.controller.state == .ready)
}
