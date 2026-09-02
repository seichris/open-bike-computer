import Foundation
import Combine

enum DeviceScreenConfigurationSyncState: Equatable {
    case loading
    case ready
    case saving
    case conflict
    case failed(String)
    case legacyUnsupported
}

struct DeviceScreenConfigurationAcknowledgement: Equatable {
    var requestID: UInt32
    var result: RideBLEScreenConfigurationResultV1
    var revision: UInt32
    var documentCRC: UInt32
}

enum DeviceScreenConfigurationFrameCodec {
    static let requestBytes = 8
    static let chunkHeaderBytes = 14
    static let acknowledgementBytes = 17
    static let maximumChunks = 160

    static func request(requestID: UInt32) -> Data? {
        guard requestID != 0 else { return nil }
        var data = Data(RideBLEGeneratedProtocolV1.screenConfigurationRequestMagic.utf8)
        data.appendUInt32LEForScreenConfiguration(requestID)
        return data
    }

    static func upload(
        requestID: UInt32,
        baseRevision: UInt32,
        document: Data,
        maximumPlaintextBytes: Int
    ) -> [Data]? {
        let payloadBytes = maximumPlaintextBytes - chunkHeaderBytes
        guard requestID != 0,
              !document.isEmpty,
              payloadBytes > 0 else { return nil }
        let count = (document.count + payloadBytes - 1) / payloadBytes
        guard count > 0, count <= maximumChunks, count <= Int(UInt8.max) else {
            return nil
        }
        return (0..<count).map { index in
            let lower = index * payloadBytes
            let upper = min(document.count, lower + payloadBytes)
            var frame = Data(RideBLEGeneratedProtocolV1.screenConfigurationUploadMagic.utf8)
            frame.appendUInt32LEForScreenConfiguration(requestID)
            frame.appendUInt32LEForScreenConfiguration(baseRevision)
            frame.append(UInt8(index))
            frame.append(UInt8(count))
            frame.append(document.subdata(in: lower..<upper))
            return frame
        }
    }

    static func acknowledgement(_ data: Data) -> DeviceScreenConfigurationAcknowledgement? {
        guard data.count == acknowledgementBytes,
              data.prefix(4) == Data(RideBLEGeneratedProtocolV1.screenConfigurationAcknowledgementMagic.utf8),
              let result = RideBLEScreenConfigurationResultV1(rawValue: data[8]) else {
            return nil
        }
        let requestID = data.readUInt32LEForScreenConfiguration(at: 4)
        guard requestID != 0 else { return nil }
        return DeviceScreenConfigurationAcknowledgement(
            requestID: requestID,
            result: result,
            revision: data.readUInt32LEForScreenConfiguration(at: 9),
            documentCRC: data.readUInt32LEForScreenConfiguration(at: 13)
        )
    }
}

private struct DeviceScreenConfigurationDownloadReassembler {
    private(set) var requestID: UInt32 = 0
    private(set) var revision: UInt32 = 0
    private var chunkCount: UInt8 = 0
    private var nextChunk: UInt8 = 0
    private var data = Data()
    private var lastChunkAt: TimeInterval = 0

    mutating func reset() {
        requestID = 0
        revision = 0
        chunkCount = 0
        nextChunk = 0
        data.removeAll(keepingCapacity: true)
        lastChunkAt = 0
    }

    mutating func consume(
        _ frame: Data,
        now: TimeInterval,
        maximumDocumentBytes: Int
    ) -> Data? {
        guard frame.count > DeviceScreenConfigurationFrameCodec.chunkHeaderBytes,
              frame.prefix(4) == Data(RideBLEGeneratedProtocolV1.screenConfigurationDownloadMagic.utf8) else {
            reset()
            return nil
        }
        let incomingRequest = frame.readUInt32LEForScreenConfiguration(at: 4)
        let incomingRevision = frame.readUInt32LEForScreenConfiguration(at: 8)
        let index = frame[12]
        let count = frame[13]
        guard incomingRequest != 0, incomingRevision != 0,
              count > 0,
              Int(count) <= DeviceScreenConfigurationFrameCodec.maximumChunks,
              index < count else {
            reset()
            return nil
        }
        if requestID == 0 {
            guard index == 0 else { return nil }
            requestID = incomingRequest
            revision = incomingRevision
            chunkCount = count
            nextChunk = 0
        }
        guard now - lastChunkAt <= 5 || nextChunk == 0,
              incomingRequest == requestID,
              incomingRevision == revision,
              count == chunkCount,
              index == nextChunk else {
            reset()
            return nil
        }
        let payload = frame.dropFirst(DeviceScreenConfigurationFrameCodec.chunkHeaderBytes)
        guard data.count + payload.count <= maximumDocumentBytes else {
            reset()
            return nil
        }
        data.append(contentsOf: payload)
        nextChunk += 1
        lastChunkAt = now
        guard nextChunk == chunkCount else { return nil }
        let completed = data
        reset()
        return completed
    }
}

@MainActor
final class DeviceScreenConfigurationController: ObservableObject {
    typealias SendFrames = (
        _ frames: [Data],
        _ sent: @escaping () -> Void,
        _ failed: @escaping () -> Void
    ) -> Bool

    @Published private(set) var state: DeviceScreenConfigurationSyncState = .legacyUnsupported
    @Published private(set) var capabilities: DeviceScreenConfigurationCapabilities?
    @Published private(set) var acknowledgedDocument: DeviceScreenConfigurationDocument?
    @Published private(set) var acknowledgedRevision: UInt32 = 0
    @Published var draft: DeviceScreenConfigurationDocument?

    private var connectedDeviceID: String?
    private var draftDeviceID: String?
    private var preserveDraftOnSnapshot = false
    private var connectionGeneration: UInt64 = 0
    private var maximumPlaintextWriteBytes = 0
    private var sendFrames: SendFrames?
    private var snapshotRequestID: UInt32?
    private var saveRequestID: UInt32?
    private var saveDocument: DeviceScreenConfigurationDocument?
    private var saveCRC: UInt32?
    private var saveBaseRevision: UInt32?
    private var requestTimeoutTask: Task<Void, Never>?
    private var download = DeviceScreenConfigurationDownloadReassembler()
    private var requestIDGenerator = DeviceScreenInstanceIDGenerator.secure
    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let requestTimeoutNanoseconds: UInt64

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        requestTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.defaults = defaults
        self.now = now
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    var canSave: Bool {
        guard state == .ready,
              let draft,
              let capabilities,
              connectedDeviceID != nil else { return false }
        return (try? DeviceScreenConfigurationCodec.encode(
            draft, capabilities: capabilities
        )) != nil && draft != acknowledgedDocument
    }

    var hasUnsavedChanges: Bool {
        draft != nil && draft != acknowledgedDocument
    }

    func connect(
        deviceID: String,
        generation: UInt64,
        capabilities: DeviceScreenConfigurationCapabilities,
        maximumPlaintextWriteBytes: Int,
        sendFrames: @escaping SendFrames
    ) {
        let cached = cachedDocument(deviceID: deviceID)
        let shouldPreserveDraft = draftDeviceID == deviceID &&
            draft != nil && draft != cached
        clearSession(preserveDraft: shouldPreserveDraft)
        preserveDraftOnSnapshot = shouldPreserveDraft
        guard maximumPlaintextWriteBytes >
                DeviceScreenConfigurationFrameCodec.chunkHeaderBytes else {
            self.capabilities = capabilities
            state = .failed("The negotiated Bluetooth packet size is too small for screen settings.")
            return
        }
        connectedDeviceID = deviceID
        connectionGeneration = generation
        self.capabilities = capabilities
        self.maximumPlaintextWriteBytes = maximumPlaintextWriteBytes
        self.sendFrames = sendFrames
        acknowledgedRevision = 0
        acknowledgedDocument = cached
        if !preserveDraftOnSnapshot {
            draft = acknowledgedDocument
            draftDeviceID = deviceID
        }
        download.reset()
        cancelRequestTimeout()
        snapshotRequestID = nil
        saveRequestID = nil
        saveDocument = nil
        saveCRC = nil
        saveBaseRevision = nil
        state = .loading
        requestSnapshot()
    }

    func markLegacyUnsupported() {
        clearSession(preserveDraft: false)
        capabilities = nil
        state = .legacyUnsupported
    }

    func disconnect(deviceID: String?, generation: UInt64) {
        guard deviceID == connectedDeviceID,
              generation == connectionGeneration else { return }
        clearSession(preserveDraft: true)
        state = .failed("Reconnect to save screen settings.")
    }

    func receive(_ payload: Data, deviceID: String, generation: UInt64) {
        guard deviceID == connectedDeviceID,
              generation == connectionGeneration,
              let capabilities else { return }
        if let acknowledgement =
            DeviceScreenConfigurationFrameCodec.acknowledgement(payload) {
            handle(acknowledgement)
            return
        }
        let expectedRequest = snapshotRequestID
        let revision = payload.count >= 12
            ? payload.readUInt32LEForScreenConfiguration(at: 8) : 0
        if let documentData = download.consume(
            payload,
            now: now(),
            maximumDocumentBytes: Int(capabilities.maximumDocumentBytes)
        ) {
            let requestID = payload.readUInt32LEForScreenConfiguration(at: 4)
            guard requestID == expectedRequest else { return }
            cancelRequestTimeout()
            do {
                let document = try DeviceScreenConfigurationCodec.decode(
                    documentData,
                    capabilities: capabilities
                )
                acknowledgedDocument = document
                acknowledgedRevision = revision
                snapshotRequestID = nil
                if state == .conflict {
                    return
                }
                if !preserveDraftOnSnapshot {
                    draft = document
                    draftDeviceID = deviceID
                }
                preserveDraftOnSnapshot = false
                state = .ready
            } catch {
                failSnapshot("The device returned invalid screen settings.")
            }
        }
    }

    func requestSnapshot() {
        guard let sendFrames else {
            state = .failed("Reconnect to load screen settings.")
            return
        }
        do {
            let requestID = try requestIDGenerator.generate(
                excluding: Set([snapshotRequestID, saveRequestID].compactMap { $0 })
            )
            guard let frame = DeviceScreenConfigurationFrameCodec.request(
                requestID: requestID
            ) else {
                state = .failed("Screen settings could not be requested.")
                return
            }
            cancelRequestTimeout()
            snapshotRequestID = requestID
            guard sendFrames([frame], { [weak self] in
                Task { @MainActor in
                    guard self?.snapshotRequestID == requestID else { return }
                    self?.scheduleRequestTimeout(
                        requestID: requestID,
                        saving: false
                    )
                }
            }, { [weak self] in
                Task { @MainActor in
                    guard self?.snapshotRequestID == requestID else { return }
                    self?.failSnapshot("Screen settings could not be requested.")
                }
            }) else {
                failSnapshot("Screen settings could not be requested.")
                return
            }
        } catch {
            state = .failed("A secure screen-settings request could not be created.")
        }
    }

    func save() {
        guard canSave,
              let draft,
              let capabilities,
              let sendFrames else { return }
        do {
            let encoded = try DeviceScreenConfigurationCodec.encode(
                draft, capabilities: capabilities
            )
            let requestID = try requestIDGenerator.generate(
                excluding: Set([snapshotRequestID, saveRequestID].compactMap { $0 })
            )
            guard let frames = DeviceScreenConfigurationFrameCodec.upload(
                requestID: requestID,
                baseRevision: acknowledgedRevision,
                document: encoded,
                maximumPlaintextBytes: maximumPlaintextWriteBytes
            ) else {
                state = .failed("The complete screen configuration could not be queued.")
                return
            }
            cancelRequestTimeout()
            saveRequestID = requestID
            saveDocument = draft
            saveCRC = DeviceScreenConfigurationCodec.documentCRC(encoded)
            saveBaseRevision = acknowledgedRevision
            state = .saving
            guard sendFrames(frames, { [weak self] in
                Task { @MainActor in
                    guard self?.saveRequestID == requestID else { return }
                    self?.scheduleRequestTimeout(
                        requestID: requestID,
                        saving: true
                    )
                }
            }, { [weak self] in
                Task { @MainActor in
                    guard self?.saveRequestID == requestID else { return }
                    self?.failSave("The Bluetooth write failed. Reload before retrying.")
                }
            }) else {
                failSave("The complete screen configuration could not be queued.")
                return
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func reloadDeviceSettings() {
        guard let acknowledgedDocument else { return }
        preserveDraftOnSnapshot = false
        draft = acknowledgedDocument
        draftDeviceID = connectedDeviceID
        state = .ready
    }

    func keepDraftAfterConflict() {
        guard state == .conflict, draft != nil else { return }
        preserveDraftOnSnapshot = true
        state = .ready
    }

    func retry() {
        state = .loading
        requestSnapshot()
    }

    func add(type: ConfiguredDeviceScreenType, after instanceID: UInt32?) throws {
        guard var draft, let capabilities else { return }
        guard capabilities.supports(type) else {
            throw DeviceScreenConfigurationValidationError.unsupportedType
        }
        guard draft.instances.count < Int(capabilities.maximumInstances) else {
            throw DeviceScreenConfigurationValidationError.invalidInstanceCount
        }
        _ = try draft.add(type: type, after: instanceID)
        self.draft = draft
    }

    func duplicate(instanceID: UInt32) throws {
        guard var draft, let capabilities else { return }
        guard draft.instances.count < Int(capabilities.maximumInstances) else {
            throw DeviceScreenConfigurationValidationError.invalidInstanceCount
        }
        guard
              let source = draft.instances.first(where: { $0.id == instanceID }),
              let sourceIndex = draft.instances.firstIndex(where: { $0.id == instanceID }) else {
            return
        }
        let newID = try DeviceScreenInstanceIDGenerator.secure.generate(
            excluding: Set(draft.instances.map(\.id))
        )
        var copy = source
        copy.id = newID
        copy.name = nextName(for: source.type, in: draft.instances)
        copy.enabled = true
        draft.instances.insert(copy, at: sourceIndex + 1)
        self.draft = draft
    }

    func remove(instanceID: UInt32) {
        guard var draft else { return }
        if draft.remove(instanceID: instanceID) { self.draft = draft }
    }

    func setEnabled(_ enabled: Bool, instanceID: UInt32) {
        guard var draft else { return }
        if draft.setEnabled(enabled, instanceID: instanceID) { self.draft = draft }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        guard var draft else { return }
        draft.move(fromOffsets: fromOffsets, toOffset: toOffset)
        self.draft = draft
    }

    func update(instance: DeviceScreenInstance) {
        guard var draft,
              let index = draft.instances.firstIndex(where: { $0.id == instance.id }) else {
            return
        }
        draft.instances[index] = instance
        draft.normalizeDefault()
        self.draft = draft
    }

    func setDefault(instanceID: UInt32) {
        guard var draft,
              draft.instances.contains(where: { $0.id == instanceID && $0.enabled }) else {
            return
        }
        draft.defaultInstanceID = instanceID
        self.draft = draft
    }

    func clearCache(deviceID: String) {
        defaults.removeObject(forKey: cacheKey(deviceID: deviceID))
    }

#if HOST_TESTING
    func setRequestIDGeneratorForTesting(_ generator: DeviceScreenInstanceIDGenerator) {
        requestIDGenerator = generator
    }

    func expirePendingRequestForTesting() {
        if let saveRequestID {
            handleRequestTimeout(requestID: saveRequestID, saving: true)
        } else if let snapshotRequestID {
            handleRequestTimeout(requestID: snapshotRequestID, saving: false)
        }
    }
#endif

    private func handle(_ acknowledgement: DeviceScreenConfigurationAcknowledgement) {
        guard acknowledgement.requestID == saveRequestID else { return }
        cancelRequestTimeout()
        switch acknowledgement.result {
        case .applied:
            guard let document = saveDocument,
                  acknowledgement.documentCRC == saveCRC,
                  let baseRevision = saveBaseRevision,
                  acknowledgement.revision == nextRevision(after: baseRevision),
                  let deviceID = connectedDeviceID else {
                failSave("The device acknowledgement did not match this save.")
                return
            }
            acknowledgedDocument = document
            acknowledgedRevision = acknowledgement.revision
            draft = document
            draftDeviceID = deviceID
            cache(document: document, revision: acknowledgement.revision, deviceID: deviceID)
            state = .ready
        case .conflict:
            state = .conflict
            preserveDraftOnSnapshot = true
            snapshotRequestID = nil
            requestSnapshot()
        case .busy:
            failSave("The device is busy. Reload and try again.")
        case .malformed:
            failSave("The device rejected invalid screen settings.")
        case .unsupported:
            failSave("The device does not support one of these screen settings.")
        case .persistenceFailed:
            failSave("The device could not save the screen settings.")
        case .unauthorized:
            failSave("Only the owner iPhone can change screen settings.")
        }
        saveRequestID = nil
        saveDocument = nil
        saveCRC = nil
        saveBaseRevision = nil
    }

    private func failSave(_ message: String) {
        cancelRequestTimeout()
        preserveDraftOnSnapshot = draft != nil
        saveRequestID = nil
        saveDocument = nil
        saveCRC = nil
        saveBaseRevision = nil
        state = .failed(message)
    }

    private func failSnapshot(_ message: String) {
        cancelRequestTimeout()
        snapshotRequestID = nil
        download.reset()
        state = .failed(message)
    }

    private func scheduleRequestTimeout(requestID: UInt32, saving: Bool) {
        requestTimeoutTask?.cancel()
        let delay = requestTimeoutNanoseconds
        requestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.handleRequestTimeout(requestID: requestID, saving: saving)
        }
    }

    private func handleRequestTimeout(requestID: UInt32, saving: Bool) {
        if saving {
            guard saveRequestID == requestID else { return }
            failSave("Timed out waiting for the Bike Computer to save screen settings.")
        } else {
            guard snapshotRequestID == requestID else { return }
            failSnapshot("Timed out waiting for screen settings from the Bike Computer.")
        }
    }

    private func cancelRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
    }

    private func clearSession(preserveDraft: Bool) {
        cancelRequestTimeout()
        connectedDeviceID = nil
        connectionGeneration = 0
        sendFrames = nil
        snapshotRequestID = nil
        saveRequestID = nil
        saveDocument = nil
        saveCRC = nil
        saveBaseRevision = nil
        download.reset()
        preserveDraftOnSnapshot = false
        if !preserveDraft {
            draft = nil
            draftDeviceID = nil
        }
    }

    private func nextName(
        for type: ConfiguredDeviceScreenType,
        in instances: [DeviceScreenInstance]
    ) -> String {
        let number = instances.filter { $0.type == type }.count + 1
        return number == 1 ? type.title : "\(type.title) \(number)"
    }

    private struct CachedEnvelope: Codable {
        var revision: UInt32
        var document: DeviceScreenConfigurationDocument
    }

    private func cache(
        document: DeviceScreenConfigurationDocument,
        revision: UInt32,
        deviceID: String
    ) {
        let envelope = CachedEnvelope(revision: revision, document: document)
        if let data = try? PropertyListEncoder().encode(envelope) {
            defaults.set(data, forKey: cacheKey(deviceID: deviceID))
        }
    }

    private func cachedDocument(deviceID: String) -> DeviceScreenConfigurationDocument? {
        guard let data = defaults.data(forKey: cacheKey(deviceID: deviceID)),
              let envelope = try? PropertyListDecoder().decode(
                CachedEnvelope.self, from: data
              ) else { return nil }
        return envelope.document
    }

    private func cacheKey(deviceID: String) -> String {
        "device-screen-configuration.\(Data(deviceID.utf8).base64EncodedString())"
    }

    private func nextRevision(after revision: UInt32) -> UInt32 {
        revision == UInt32.max ? 1 : revision + 1
    }
}

private extension Data {
    mutating func appendUInt32LEForScreenConfiguration(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func readUInt32LEForScreenConfiguration(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
