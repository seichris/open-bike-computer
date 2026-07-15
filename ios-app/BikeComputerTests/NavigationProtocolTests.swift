import Foundation
import CoreLocation
import CoreBluetooth
import CryptoKit
import MapKit

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assert(actual == expected, "\(message): expected \(expected), got \(actual)")
}

func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readInt16LE(_ data: Data, offset: Int) -> Int16 {
    Int16(bitPattern: readUInt16LE(data, offset: offset))
}

func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
}

func readInt32LE(_ data: Data, offset: Int) -> Int32 {
    Int32(bitPattern: readUInt32LE(data, offset: offset))
}

func powerButtonHonkStatus(for packet: Data, applied: UInt8) -> Data {
    assert(packet.count == 11, "tracked PWR honk packets include a UInt32 request ID")
    var status = Data(DeviceBLEProtocol.powerButtonHonkStatusPrefix.utf8)
    status.append(packet.subdata(in: 4..<8))
    status.append(applied)
    status.append(packet.subdata(in: 8..<11))
    return status
}

func waitForMainLoop(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

func zipCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        var value = (crc ^ UInt32(byte)) & 0xff
        for _ in 0..<8 {
            value = value & 1 == 1
                ? (value >> 1) ^ 0xedb8_8320
                : value >> 1
        }
        crc = (crc >> 8) ^ value
    }
    return crc ^ UInt32.max
}

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

func makeStoredZip(entries: [(String, Data)]) -> Data {
    var zip = Data()
    for (path, body) in entries {
        let name = Data(path.utf8)
        appendUInt32LE(0x0403_4B50, to: &zip)
        appendUInt16LE(20, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt32LE(zipCRC32(body), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt16LE(UInt16(name.count), to: &zip)
        appendUInt16LE(0, to: &zip)
        zip.append(name)
        zip.append(body)
    }
    return zip
}

actor AsyncTestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

final class OfflineMapTestURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func configure(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        recordedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset() {
        lock.lock()
        handler = nil
        recordedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
func waitForMapTaskCompletion(
    _ manager: OfflineMapManager,
    timeout: TimeInterval = 3
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var observedBusy = false
    while Date() < deadline {
        observedBusy = observedBusy || manager.isBusy
        if !manager.isBusy &&
            (observedBusy || manager.currentJob != nil || manager.errorMessage != nil) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
func waitForMapBusyState(
    _ manager: OfflineMapManager,
    expected: Bool,
    timeout: TimeInterval = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if manager.isBusy == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return manager.isBusy == expected
}

func assertCoordinate(
    _ actual: CLLocationCoordinate2D,
    latitude expectedLatitude: CLLocationDegrees,
    longitude expectedLongitude: CLLocationDegrees,
    _ message: String
) {
    assert(abs(actual.latitude - expectedLatitude) < 0.000001, "\(message): latitude")
    assert(abs(actual.longitude - expectedLongitude) < 0.000001, "\(message): longitude")
}

final class TestBLEManager: BLEManager {
    var sentPackets: [String] = []
    var sentRouteGeometry: [Data] = []
    var sentGPSPositions: [Data] = []

    override func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Keep CoreBluetooth startup callbacks from changing test-controlled state.
    }

    override func sendNavigationData(_ data: String) -> Bool {
        guard isConnected, isNavigationReady else {
            return false
        }

        sentPackets.append(data)
        return true
    }

    override func sendRouteGeometry(_ data: Data) {
        guard isConnected, isNavigationReady else {
            return
        }

        sentRouteGeometry.append(data)
    }

    override func sendGPSPosition(
        lat: Double,
        lon: Double,
        heading: Double = 0,
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        routeRemainingMeters: Double? = nil
    ) {
        guard isConnected, isNavigationReady else {
            return
        }

        sentGPSPositions.append(DeviceGPSPacketBuilder.data(
            lat: lat,
            lon: lon,
            heading: heading,
            speedMetersPerSecond: speedMetersPerSecond,
            altitudeMeters: altitudeMeters,
            distanceTraveledMeters: distanceTraveledMeters,
            elapsedSeconds: elapsedSeconds,
            routeRemainingMeters: routeRemainingMeters
        ))
    }
}

final class FirmwareRequestCaptureProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw FirmwareUpdateError.serverError("missing test handler")
            }
            let (response, data) = try handler(request, Self.bodyData(from: request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class TestRouteStep: MKRoute.Step {
    private let storedInstructions: String
    private let storedPolyline: MKPolyline

    init(instructions: String, coordinates: [CLLocationCoordinate2D]) {
        self.storedInstructions = instructions
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        super.init()
    }

    override var instructions: String {
        storedInstructions
    }

    override var polyline: MKPolyline {
        storedPolyline
    }
}

final class TestRoute: MKRoute {
    private let storedSteps: [MKRoute.Step]
    private let storedPolyline: MKPolyline
    private let storedDistance: CLLocationDistance

    init(instructions: String, coordinates: [CLLocationCoordinate2D]) {
        self.storedSteps = [TestRouteStep(instructions: instructions, coordinates: coordinates)]
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        super.init()
    }

    override var steps: [MKRoute.Step] {
        storedSteps
    }

    override var polyline: MKPolyline {
        storedPolyline
    }

    override var distance: CLLocationDistance {
        storedDistance
    }
}

@main
struct NavigationProtocolTests {
    @MainActor
    static func main() async {
        testIconMapping()
        testRouteEndpointExtraction()
        testRouteRemainingDistance()
        testChinaRouteCoordinatesRoundTripWithoutCalibrationNudge()
        testNonChinaCoordinatesPassThroughUnchanged()
        testSourceEndpointSelection()
        testRouteInitialLocationUsesResolvedSource()
        testRouteTransportTypes()
        testDeviceGPSPacketBuilder()
        testNavigationPacketBuilder()
        testNavigationWriteQueue()
        testDeviceBLEProtocolConstants()
        testDevicePacketRouting()
        testDeviceSoundProtocol()
        testDeviceCapabilitiesProtocol()
        testBatteryStatusScreenCapabilityNegotiation()
        testMapProfileCapabilityNegotiation()
        testDeviceCapabilitySynchronizesPowerButtonHonkOnce()
        testDeviceCapabilityRetryPolicy()
        testDeviceScreenValidation()
        testHardwareLabelPreference()
        testBLEPairingAuthenticator()
        testBLEManagerRequiresNavigationReadinessForWrites()
        testBLEManagerSendsFallbackMapSettings()
        testBLEManagerSendsSeparateMapProfileSettings()
        testBLEManagerFoldsExtendedVisibilityForLegacyFirmware()
        testBLEManagerSendsDeviceSoundFallback()
        testBLEManagerSendsPowerButtonHonkFallback()
        testPowerButtonHonkTimeoutAndTransportFailures()
        testBLEManagerSendsDeviceCapabilityFallback()
        testBLEManagerSendsMapTransferControlFrames()
        testBLEManagerSendsDeviceTransferControlFrames()
        testBLEManagerParsesMapTransferStatus()
        testBLEManagerReassemblesChunkedMapTransferStatus()
        testBLEManagerParsesDeviceTransferStatus()
        testBLEManagerSendsBrightnessFallbackSetting()
        testBLEManagerSendsDisconnectedSleepTimeoutSetting()
        testBLEManagerSendsDeviceScreenSettings()
        testBLEManagerPersistsNewMapSettings()
        testBLEManagerPersistsDeviceSoundSettings()
        testNavigationSendTrackerReadinessRetry()
        testNavigationEngineResendsWhenBLEBecomesReady()
        testNavigationEngineResendsRouteGeometryNearLastLocation()
        testNavigationEngineClearsRouteGeometryOnStop()
        testNavigationEngineClearsRouteGeometryWhenReadyAndIdle()
        testNavigationEngineOmitsRideTelemetryWhenIdle()
        testNavigationEngineIgnoresLiveLocationFarFromRouteStart()
        testOfflineMapCustomBBoxRequest()
        testBikeMapStreamGoldenVector()
        testBikeMapStreamArtifactValidation()
        testOfflineMapArtifactSelectionAndProtocolNegotiation()
        testSavedMapArtifactMetadataRoundTrip()
        testBackgroundMapUploadRestorationState()
        testBackgroundMapUploadArbitration()
        testPausedMapUploadResumePolicy()
        testBackgroundMapUploadResponseBufferIsBounded()
        testMapStreamBackgroundUploadRequest()
        await testDeviceTransferManagerWaitsForMapToken()
        await testOfflineMapInstallationCredentialClient()
        testOfflineMapPreparationTimeEstimate()
        testOfflineMapJobProgressDecoding()
        testOfflineMapJobProgressAbsentFallback()
        testOfflineMapProgressPresentation()
        testMapActivationProgressPresentation()
        testMapUploadProgressReconciliation()
        testOfflineMapDownloadingSectionPresentation()
        testOfflineMapActivityCounterOverlappingOperations()
        testOfflineMapJobPersistence()
        testOfflineMapInstallationIdentity()
        testOfflineMapJobRecoverySelection()
        testOfflineMapDownloadResponseValidation()
        await testOfflineMapPackDownloaderRejectsHTTPError()
        testPendingOfflineMapJobBlocksEveryCreationIngress()
        await testOfflineMapJobCreatorReconcilesAmbiguousResponse()
        await testOfflineMapPollerOutlivesLegacyAttemptLimit()
        await testOfflineMapPollerRetriesTransientFailure()
        await testOfflineMapPollerStopsOnTerminalAndCancellation()
        testOfflineMapCreateJobURLRequest()
        testOfflineMapListJobsURLRequest()
        testOfflineMapInventoryMutationURLRequests()
        testOfflineMapManagerMigratesProductionConfig()
        testOfflineMapManagerRenamesCachedPack()
        testSavedMapRenameViewWiring()
        testOfflineMapManagerRestoresLastTransferIdentity()
        testOfflineMapManagerReconcilesInterruptedActivation()
        testOfflineMapManagerReconcilesAcknowledgedFirstInstall()
        testOfflineMapPolygonClosesRing()
        testOfflineMapStoredZipReader()
        testOfflineMapPackPreviewReader()
        testOfflineMapPreviewLoadRegistry()
        await testOfflineMapCompatibilityArchiveCancellation()
        await testOfflineMapArchiveValidationCancellation()
        testCachedMapInstalledIdentityUsesManifestSession()
        testOfflineMapManifestDecoding()
        testMapTransferUploadURLEncodesPlusPathComponents()
        testMapTransferOutcomePolicy()
        testCachedPackRecoveryDecision()
        await testMapTransferUploadResumeContract()
        await testMapTransferActivationAcknowledgementSequence()
        testMapTransferSessionIdentityUsesManifestContent()
        testMapActivationReconciliationMatrix()
        await testMapActivationConfirmationOrchestration()
        testMapTransferDeviceStatusDecodesActivationFailure()
        testFirmwareManifestDecodingAndHash()
        testFirmwareUpdateManagerRestoresPendingStatus()
        testFirmwareUpdateAvailabilitySemantics()
        testFirmwareDeviceClientSendsSignedBeginRequest()
        await testOfflineMapRecoveryRoutes()
        print("NavigationProtocolTests passed")
    }

    static func testBikeMapStreamGoldenVector() {
        let fixtureURL = URL(fileURLWithPath: "backend/tests/fixtures/map_stream_v1_golden.txt")
        guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
            assert(false, "map stream golden fixture is readable")
            return
        }
        let fixture = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })
        guard let header = Data(hex: fixture["header_hex"] ?? ""),
              let expectedManifest = Data(hex: fixture["manifest_hex"] ?? ""),
              let expectedEnvelope = Data(hex: fixture["signature_envelope_hex"] ?? ""),
              let expectedPayload = Data(hex: fixture["payload_hex"] ?? ""),
              let publicKey = Data(hex: fixture["public_key_x963_hex"] ?? ""),
              let stream = Data(hex: fixture["stream_hex"] ?? "") else {
            assert(false, "map stream golden fixture contains valid hex")
            return
        }
        guard let parsedHeader = try? BikeMapStreamFormat.parseHeader(stream.prefix(32)),
              let layout = try? BikeMapStreamFormat.layout(
                  header: parsedHeader,
                  contentBytes: UInt64(stream.count)
              ) else {
            assert(false, "map stream golden stream layout parses")
            return
        }
        let manifest = stream.subdata(in: layout.manifestOffset..<layout.signatureEnvelopeOffset)
        let envelopeData = stream.subdata(in: layout.signatureEnvelopeOffset..<layout.payloadOffset)
        let payload = stream.subdata(in: layout.payloadOffset..<layout.endOffset)
        guard let envelope = try? BikeMapStreamFormat.parseSignatureEnvelope(envelopeData) else {
            assert(false, "map stream golden header and envelope parse")
            return
        }
        assertEqual(stream.prefix(32), header, "map stream stream embeds the golden header")
        assertEqual(manifest, expectedManifest, "map stream stream embeds the golden manifest")
        assertEqual(envelopeData, expectedEnvelope, "map stream stream embeds the golden envelope")
        assertEqual(payload, expectedPayload, "map stream stream embeds payload in manifest order")
        let expectedPreview = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        assertEqual(
            OfflineMapPackPreviewReader.imageData(fromManifestData: manifest),
            expectedPreview,
            "the shared signed stream exposes its inline boundary preview"
        )
        assertEqual(parsedHeader.fileCount, 1, "map stream golden fixture file count")
        assertEqual(
            parsedHeader.payloadBytes,
            UInt64(expectedPayload.count),
            "map stream golden fixture payload bytes"
        )
        assertEqual(parsedHeader.totalBytes, UInt64(stream.count), "map stream golden fixture total bytes")
        assertEqual(envelope.keyID, "map-test-2026-01", "map stream golden fixture key id")
        assert(
            BikeMapStreamFormat.verifyP256Signature(
                manifest: manifest,
                envelope: envelope,
                publicKeyX963: publicKey
            ),
            "map stream golden signature verifies with CryptoKit"
        )
        assertEqual(
            BikeMapStreamFormat.manifestReceipt(manifest),
            fixture["manifest_receipt"],
            "map stream manifest receipt agrees with Python and C++"
        )
        assertEqual(
            BikeMapStreamFormat.signedManifestReceipt(manifest: manifest, envelope: envelopeData),
            fixture["signed_manifest_receipt"],
            "map stream signed manifest receipt agrees with Python and C++"
        )

        var tamperedManifest = manifest
        tamperedManifest[tamperedManifest.startIndex] ^= 1
        assert(
            !BikeMapStreamFormat.verifyP256Signature(
                manifest: tamperedManifest,
                envelope: envelope,
                publicKeyX963: publicKey
            ),
            "map stream manifest tampering fails CryptoKit verification"
        )
        var tamperedSignatureData = envelopeData
        tamperedSignatureData[tamperedSignatureData.index(before: tamperedSignatureData.endIndex)] ^= 1
        guard let tamperedEnvelope = try? BikeMapStreamFormat.parseSignatureEnvelope(tamperedSignatureData) else {
            assert(false, "tampered signature remains structurally parseable")
            return
        }
        assert(
            !BikeMapStreamFormat.verifyP256Signature(
                manifest: manifest,
                envelope: tamperedEnvelope,
                publicKeyX963: publicKey
            ),
            "map stream signature tampering fails CryptoKit verification"
        )

        var highSEnvelopeData = envelopeData
        let highS = Data(hex: "84bbcdefdaa6426471c25ac037769c84cebf6fdf76c1ebd87fe26f14e3b42870")!
        highSEnvelopeData.replaceSubrange(
            (highSEnvelopeData.count - 32)..<highSEnvelopeData.count,
            with: highS
        )
        do {
            _ = try BikeMapStreamFormat.parseSignatureEnvelope(highSEnvelopeData)
            assert(false, "malleable high-S signature is rejected")
        } catch {
            assertEqual(
                error as? BikeMapStreamFormatError,
                .nonCanonicalSignature,
                "high-S signature failure is typed"
            )
        }
        var highSRawSignature = envelope.rawSignature
        highSRawSignature.replaceSubrange(32..<64, with: highS)
        let manuallyConstructedHighSEnvelope = BikeMapStreamFormat.SignatureEnvelope(
            algorithmID: envelope.algorithmID,
            keyID: envelope.keyID,
            rawSignature: highSRawSignature
        )
        assert(
            !BikeMapStreamFormat.verifyP256Signature(
                manifest: manifest,
                envelope: manuallyConstructedHighSEnvelope,
                publicKeyX963: publicKey
            ),
            "signature verification independently rejects a constructed high-S envelope"
        )

        var paddedHeader = Data([0xFF])
        paddedHeader.append(header)
        var paddedEnvelope = Data([0xFF])
        paddedEnvelope.append(envelopeData)
        assertEqual(
            try? BikeMapStreamFormat.parseHeader(paddedHeader.dropFirst()),
            parsedHeader,
            "map stream header parsing is relative to a Data slice start index"
        )
        assertEqual(
            try? BikeMapStreamFormat.parseSignatureEnvelope(paddedEnvelope.dropFirst()),
            envelope,
            "map stream envelope parsing is relative to a Data slice start index"
        )
        do {
            _ = try BikeMapStreamFormat.layout(
                header: parsedHeader,
                contentBytes: UInt64(stream.count - 1)
            )
            assert(false, "truncated map stream is rejected")
        } catch {
            assertEqual(error as? BikeMapStreamFormatError, .invalidContentLength, "truncation failure is typed")
        }
        do {
            _ = try BikeMapStreamFormat.layout(
                header: parsedHeader,
                contentBytes: UInt64(stream.count + 1)
            )
            assert(false, "map stream trailing data is rejected")
        } catch {
            assertEqual(error as? BikeMapStreamFormatError, .invalidContentLength, "trailing-data failure is typed")
        }

        var invalidHeader = header
        invalidHeader[8] = 2
        do {
            _ = try BikeMapStreamFormat.parseHeader(invalidHeader)
            assert(false, "unsupported map stream version is rejected")
        } catch {
            assertEqual(error as? BikeMapStreamFormatError, .unsupportedVersion, "version failure is typed")
        }
    }

    static func testBikeMapStreamArtifactValidation() {
        let fixtureURL = URL(fileURLWithPath: "backend/tests/fixtures/map_stream_v1_golden.txt")
        guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
            assert(false, "map stream artifact fixture is readable")
            return
        }
        let fixture = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })
        guard let stream = Data(hex: fixture["stream_hex"] ?? ""),
              let manifest = Data(hex: fixture["manifest_hex"] ?? ""),
              let publicKey = Data(hex: fixture["public_key_x963_hex"] ?? ""),
              let header = try? BikeMapStreamFormat.parseHeader(stream.prefix(32)) else {
            assert(false, "map stream artifact fixture fields decode")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bike-map-stream-swift-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func artifact(
            bytes: Data,
            sha: String? = nil,
            objectKey: String? = nil
        ) -> OfflineMapArtifact {
            OfflineMapArtifact(
                format: OfflineMapArtifact.bikeMapStreamFormat,
                mediaType: "application/vnd.openbikecomputer.map-stream",
                filename: "golden-map.bmap",
                objectKey: objectKey ?? (
                    "maps/golden-map/bike-map-stream-v1/map-test-2026-01/" +
                        "\(sha256(publicKey))/\(String(repeating: "1", count: 64))/" +
                        "\(String(repeating: "2", count: 64))/" +
                        "\(fixture["signed_manifest_receipt"]!).bmap"
                ),
                bytes: Int64(bytes.count),
                sha256: sha ?? sha256(bytes),
                manifestReceipt: fixture["manifest_receipt"],
                signedManifestReceipt: fixture["signed_manifest_receipt"],
                signatureKeyId: "map-test-2026-01",
                signatureKeySha256: sha256(publicKey),
                producerBuildSha256: String(repeating: "1", count: 64),
                producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
                requiredIosBuild: "100",
                requiredIosGitSha: String(repeating: "a", count: 40),
                requiredIosBuildSha256: String(repeating: "b", count: 64),
                requiredFirmwareVersion: nil,
                requiredFirmwareBuild: nil,
                requiredFirmwareGitSha: nil
            )
        }
        let trustStore = BikeMapStreamTrustStore(publicKeysByID: [
            "map-test-2026-01": publicKey,
            "map-next-2026-02": publicKey,
        ])
        let streamURL = directory.appendingPathComponent("golden-map.bmap")
        try! stream.write(to: streamURL)
        do {
            let verified = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: artifact(bytes: stream),
                expectedMapID: "golden-map",
                trustStore: trustStore
            )
            assertEqual(verified.mapID, "golden-map", "stream validator returns authenticated map ID")
            assertEqual(verified.fileCount, 1, "stream validator returns authenticated file count")
            assertEqual(verified.payloadBytes, 8, "stream validator returns authenticated payload bytes")
            assertEqual(
                verified.signedManifestReceipt,
                fixture["signed_manifest_receipt"],
                "stream validator preserves stable session identity"
            )
        } catch {
            assert(false, "valid complete map stream is accepted: \(error)")
        }

        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: artifact(bytes: stream),
                expectedMapID: "golden-map",
                trustStore: .init(publicKeysByID: ["map-next-2026-02": publicKey])
            )
            assert(false, "unknown signing key is rejected")
        } catch {
            assertEqual(
                error as? BikeMapStreamFormatError,
                .unknownKeyID("map-test-2026-01"),
                "unknown signing key failure is typed"
            )
        }

        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: artifact(
                    bytes: stream,
                    objectKey: "other/maps/golden-map/bike-map-stream-v1/" +
                        "map-test-2026-01/\(sha256(publicKey))/" +
                        "\(String(repeating: "1", count: 40))/" +
                        "\(fixture["signed_manifest_receipt"]!).bmap"
                ),
                expectedMapID: "golden-map",
                trustStore: trustStore
            )
            assert(false, "stream object keys require the exact content-addressed namespace")
        } catch {
            guard case .invalidArtifactMetadata = error as? BikeMapStreamFormatError else {
                assert(false, "stream object-key mismatch failure is typed: \(error)")
                return
            }
        }

        var tamperedPayload = stream
        tamperedPayload[tamperedPayload.index(before: tamperedPayload.endIndex)] ^= 1
        let tamperedURL = directory.appendingPathComponent("tampered.bmap")
        try! tamperedPayload.write(to: tamperedURL)
        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: tamperedURL,
                artifact: artifact(bytes: tamperedPayload),
                expectedMapID: "golden-map",
                trustStore: trustStore
            )
            assert(false, "payload tampering is rejected")
        } catch {
            guard case .fileHashMismatch = error as? BikeMapStreamFormatError else {
                assert(false, "payload tampering reports a file hash mismatch: \(error)")
                return
            }
        }

        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: artifact(bytes: stream, sha: String(repeating: "0", count: 64)),
                expectedMapID: "golden-map",
                trustStore: trustStore
            )
            assert(false, "whole-artifact metadata mismatch is rejected")
        } catch {
            assertEqual(
                error as? BikeMapStreamFormatError,
                .artifactHashMismatch,
                "whole-artifact mismatch failure is typed"
            )
        }

        for (name, bytes) in [
            ("truncated", Data(stream.dropLast())),
            ("extended", stream + Data([0])),
        ] {
            let url = directory.appendingPathComponent("\(name).bmap")
            try! bytes.write(to: url)
            do {
                _ = try BikeMapStreamArtifactValidator.validate(
                    url: url,
                    artifact: artifact(bytes: bytes),
                    expectedMapID: "golden-map",
                    trustStore: trustStore
                )
                assert(false, "\(name) artifact is rejected")
            } catch {
                assertEqual(
                    error as? BikeMapStreamFormatError,
                    .invalidContentLength,
                    "\(name) artifact length failure is typed"
                )
            }
        }

        let manifestText = String(data: manifest, encoding: .utf8)!
        func manifestWithUnknownValue(_ value: String) -> Data {
            Data((manifestText.dropLast() + ",\"z\":\(value)}").utf8)
        }
        var nonCanonical = Data(" ".utf8)
        nonCanonical.append(manifest)
        let nonCanonicalHeader = BikeMapStreamFormat.Header(
            formatVersion: 1,
            flags: 0,
            manifestBytes: UInt32(nonCanonical.count),
            signatureEnvelopeBytes: header.signatureEnvelopeBytes,
            fileCount: 1,
            payloadBytes: 8
        )
        do {
            _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                nonCanonical,
                expectedMapID: "golden-map",
                header: nonCanonicalHeader
            )
            assert(false, "non-canonical manifest JSON is rejected")
        } catch {
            guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                assert(false, "non-canonical manifest failure is typed")
                return
            }
        }
        let nonShortestNumber = manifestWithUnknownValue("1.0")
        let nonShortestHeader = BikeMapStreamFormat.Header(
            formatVersion: 1,
            flags: 0,
            manifestBytes: UInt32(nonShortestNumber.count),
            signatureEnvelopeBytes: header.signatureEnvelopeBytes,
            fileCount: 1,
            payloadBytes: 8
        )
        do {
            _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                nonShortestNumber,
                expectedMapID: "golden-map",
                header: nonShortestHeader
            )
            assert(false, "non-shortest manifest number is rejected")
        } catch {
            guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                assert(false, "non-shortest number failure is typed")
                return
            }
        }

        for value in [
            "\"\\/\"", "\"\\u000A\"", "\"\\u000a\"", "1.00", "1E+16",
            "1e+01", "1.0e+16", "1.234567890123456789", "1e-05", "-0",
        ] {
            let candidate = manifestWithUnknownValue(value)
            let candidateHeader = BikeMapStreamFormat.Header(
                formatVersion: 1,
                flags: 0,
                manifestBytes: UInt32(candidate.count),
                signatureEnvelopeBytes: header.signatureEnvelopeBytes,
                fileCount: 1,
                payloadBytes: 8
            )
            do {
                _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                    candidate,
                    expectedMapID: "golden-map",
                    header: candidateHeader
                )
                assert(false, "non-canonical unknown JSON value \(value) is rejected")
            } catch {
                guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                    assert(false, "unknown JSON canonicalization failure is typed")
                    return
                }
            }
        }
        for value in ["-1", "\"\\u0000\""] {
            let candidate = manifestWithUnknownValue(value)
            let candidateHeader = BikeMapStreamFormat.Header(
                formatVersion: 1,
                flags: 0,
                manifestBytes: UInt32(candidate.count),
                signatureEnvelopeBytes: header.signatureEnvelopeBytes,
                fileCount: 1,
                payloadBytes: 8
            )
            do {
                _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                    candidate,
                    expectedMapID: "golden-map",
                    header: candidateHeader
                )
            } catch {
                assert(false, "canonical unknown JSON value \(value) is accepted: \(error)")
            }
        }

        let originalPath = "VECTMAP/golden-map/+0000+0000/0_0.fmb"
        let unsafeManifest = Data(manifestText.replacingOccurrences(
            of: originalPath,
            with: "VECTMAP/golden-map/../escape.fmb"
        ).utf8)
        let unsafeHeader = BikeMapStreamFormat.Header(
            formatVersion: 1,
            flags: 0,
            manifestBytes: UInt32(unsafeManifest.count),
            signatureEnvelopeBytes: header.signatureEnvelopeBytes,
            fileCount: 1,
            payloadBytes: 8
        )
        do {
            _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                unsafeManifest,
                expectedMapID: "golden-map",
                header: unsafeHeader
            )
            assert(false, "unsafe map stream path is rejected")
        } catch {
            guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                assert(false, "unsafe path manifest failure is typed")
                return
            }
        }

        let filesPrefix = "\"files\":["
        let filesStart = manifestText.range(of: filesPrefix)!.upperBound
        let filesEnd = manifestText.range(
            of: "],\"mapId\"",
            range: filesStart..<manifestText.endIndex
        )!.lowerBound
        let originalFileText = String(manifestText[filesStart..<filesEnd])
        func manifestReplacingFiles(_ files: String) -> Data {
            var value = manifestText
            value.replaceSubrange(filesStart..<filesEnd, with: files)
            return Data(value.utf8)
        }
        func assertInvalidManifest(
            _ data: Data,
            fileCount: UInt32,
            payloadBytes: UInt64,
            _ message: String
        ) {
            let candidateHeader = BikeMapStreamFormat.Header(
                formatVersion: 1,
                flags: 0,
                manifestBytes: UInt32(data.count),
                signatureEnvelopeBytes: header.signatureEnvelopeBytes,
                fileCount: fileCount,
                payloadBytes: payloadBytes
            )
            do {
                _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                    data,
                    expectedMapID: "golden-map",
                    header: candidateHeader
                )
                assert(false, message)
            } catch {
                guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                    assert(false, "\(message) reports a typed manifest failure")
                    return
                }
            }
        }
        assertInvalidManifest(
            manifestReplacingFiles("\(originalFileText),\(originalFileText)"),
            fileCount: 2,
            payloadBytes: 16,
            "duplicate manifest paths are rejected"
        )

        let secondFileText = originalFileText.replacingOccurrences(
            of: originalPath,
            with: "VECTMAP/golden-map/+0000+0000/1_0.fmb"
        )
        assertInvalidManifest(
            manifestReplacingFiles("\(secondFileText),\(originalFileText)"),
            fileCount: 2,
            payloadBytes: 16,
            "reordered manifest paths are rejected"
        )

        assertInvalidManifest(
            manifest,
            fileCount: 1,
            payloadBytes: 9,
            "manifest payload sum mismatch is rejected"
        )

        let oversizedFileText = originalFileText.replacingOccurrences(
            of: "\"bytes\":8",
            with: "\"bytes\":2097153"
        )
        assertInvalidManifest(
            manifestReplacingFiles(oversizedFileText),
            fileCount: 1,
            payloadBytes: UInt64(2 * 1024 * 1024 + 1),
            "per-file stream size limit is enforced"
        )
    }

    static func testOfflineMapArtifactSelectionAndProtocolNegotiation() {
        let stream = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map.bmap",
            objectKey: "maps/map.bmap",
            bytes: 123,
            sha256: String(repeating: "1", count: 64),
            manifestReceipt: String(repeating: "2", count: 64),
            signedManifestReceipt: String(repeating: "3", count: 64),
            signatureKeyId: "map-prod-1",
            signatureKeySha256: String(repeating: "5", count: 64),
            producerBuildSha256: String(repeating: "1", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
            requiredIosBuild: "100",
            requiredIosGitSha: String(repeating: "8", count: 40),
            requiredIosBuildSha256: String(repeating: "9", count: 64),
            requiredFirmwareVersion: "0.3.0",
            requiredFirmwareBuild: 42,
            requiredFirmwareGitSha: String(repeating: "7", count: 40)
        )
        let zip = OfflineMapArtifact(
            format: OfflineMapArtifact.storedZipFormat,
            mediaType: "application/zip",
            filename: "map.zip",
            objectKey: "maps/map.zip",
            bytes: 321,
            sha256: String(repeating: "4", count: 64),
            manifestReceipt: nil,
            signedManifestReceipt: nil,
            signatureKeyId: nil,
            signatureKeySha256: nil,
            producerBuildSha256: nil,
            requiredIosBuild: nil,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        func migrationMetadata(primary: OfflineMapArtifact) -> SavedMapArtifactMetadata {
            SavedMapArtifactMetadata(
                schemaVersion: 1,
                mapID: "map",
                displayName: nil,
                localArtifactFilename: "map.bmap",
                streamFormatVersion: 1,
                jobID: "job",
                serverURLString: "https://maps.example.com",
                clientInstallationID: "inst_v2_1234567890abcdef1234567890abcdef",
                primaryArtifact: primary,
                legacyArtifact: zip,
                lastTransferProtocol: nil,
                lastTransferStreamFormat: nil,
                lastTransferSessionID: nil,
                lastBackgroundTaskID: nil,
                lastDeviceSequence: nil,
                lastDeviceState: nil,
                lastDeviceStep: nil,
                lastDeviceStepCount: nil,
                lastDeviceProgress: nil,
                expectedActiveMapID: nil,
                expectedActiveSessionID: nil,
                lastTransferOutcome: nil
            )
        }
        let oldMetadataStream = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map.bmap",
            objectKey: "maps/map/bike-map-stream-v1/map-prod-1/receipt.bmap",
            bytes: 123,
            sha256: String(repeating: "1", count: 64),
            manifestReceipt: String(repeating: "2", count: 64),
            signedManifestReceipt: String(repeating: "3", count: 64),
            signatureKeyId: "map-prod-1",
            signatureKeySha256: nil,
            producerBuildSha256: nil,
            requiredIosBuild: nil,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        assert(
            SavedMapStreamMigrationFallback.shouldUseLegacyArtifact(
                for: migrationMetadata(primary: oldMetadataStream)
            ),
            "the exact pre-provenance saved metadata shape uses its retained ZIP"
        )
        assert(
            !SavedMapStreamMigrationFallback.shouldUseLegacyArtifact(
                for: migrationMetadata(primary: stream)
            ),
            "current signed metadata never converts integrity failures into ZIP fallback"
        )
        let partialMetadataStream = OfflineMapArtifact(
            format: oldMetadataStream.format,
            mediaType: oldMetadataStream.mediaType,
            filename: oldMetadataStream.filename,
            objectKey: oldMetadataStream.objectKey,
            bytes: oldMetadataStream.bytes,
            sha256: oldMetadataStream.sha256,
            manifestReceipt: oldMetadataStream.manifestReceipt,
            signedManifestReceipt: oldMetadataStream.signedManifestReceipt,
            signatureKeyId: oldMetadataStream.signatureKeyId,
            signatureKeySha256: String(repeating: "5", count: 64),
            producerBuildSha256: nil,
            requiredIosBuild: nil,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        assert(
            !SavedMapStreamMigrationFallback.shouldUseLegacyArtifact(
                for: migrationMetadata(primary: partialMetadataStream)
            ),
            "partially missing provenance remains a hard validation failure"
        )
        let validPublicKey = Data(hex:
            "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        )!
        let trusted = BikeMapStreamTrustStore(publicKeysByID: ["map-prod-1": validPublicKey])
        assertEqual(
            try? OfflineMapArtifactSelector.select(artifacts: [zip, stream], trustStore: trusted),
            .bikeMapStream(stream, legacy: zip),
            "trusted stream is the canonical download with a durable legacy companion"
        )
        assertEqual(
            try? OfflineMapArtifactSelector.select(
                artifacts: [zip, stream],
                trustStore: .init(publicKeysByID: [:])
            ),
            .legacyZip(zip),
            "rollout-disabled trust store explicitly keeps legacy ZIP"
        )
        assertEqual(
            try? OfflineMapArtifactSelector.select(
                artifacts: [zip, stream],
                trustStore: trusted,
                canDownloadStreamArtifact: false
            ),
            .legacyZip(zip),
            "legacy-owned jobs retain their tokenless ZIP recovery path"
        )
        do {
            _ = try OfflineMapArtifactSelector.select(
                artifacts: [zip, stream],
                trustStore: .init(publicKeysByID: ["map-prod-2": validPublicKey])
            )
            assert(false, "unknown production signing key does not silently use ZIP")
        } catch {
            assertEqual(
                error as? BikeMapStreamFormatError,
                .unknownKeyID("map-prod-1"),
                "unknown production key failure is typed"
            )
        }

        let v2Status = MapTransferDeviceStatus(
            enabled: true,
            activeMapId: nil,
            activeSessionId: nil,
            activation: nil,
            protocols: [1, 2],
            streamFormatVersions: [1],
            streamTrust: ["map-prod-1=" + String(repeating: "5", count: 64)],
            firmwareVersion: "0.3.0",
            firmwareBuild: 42,
            firmwareGitSha: String(repeating: "7", count: 40)
        )
        let v1Status = MapTransferDeviceStatus(
            enabled: true,
            activeMapId: nil,
            activeSessionId: nil,
            activation: nil,
            protocols: [1],
            streamFormatVersions: nil,
            streamTrust: nil,
            firmwareVersion: "0.2.0",
            firmwareBuild: 41,
            firmwareGitSha: String(repeating: "6", count: 40)
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: stream.requiredIosBuild,
                requiredIosGitSha: stream.requiredIosGitSha,
                requiredIosBuildSha256: stream.requiredIosBuildSha256,
                currentIosBuild: "100",
                currentIosGitSha: String(repeating: "8", count: 40),
                currentIosBuildSha256: String(repeating: "9", count: 64),
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .streamV2,
            "stream artifact selects v2 only when protocol and format match"
        )
        let wrongFirmwareStatus = MapTransferDeviceStatus(
            enabled: true,
            activeMapId: nil,
            activeSessionId: nil,
            activation: nil,
            protocols: [1, 2],
            streamFormatVersions: [1],
            streamTrust: ["map-prod-1=" + String(repeating: "5", count: 64)],
            firmwareVersion: "0.3.0",
            firmwareBuild: 43,
            firmwareGitSha: String(repeating: "7", count: 40)
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: stream.requiredIosBuild,
                requiredIosGitSha: stream.requiredIosGitSha,
                requiredIosBuildSha256: stream.requiredIosBuildSha256,
                currentIosBuild: "100",
                currentIosGitSha: String(repeating: "8", count: 40),
                currentIosBuildSha256: String(repeating: "9", count: 64),
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: wrongFirmwareStatus
            ),
            .legacyArtifactRequired,
            "a later firmware build cannot reuse a hardware approval for another binary"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: stream.requiredIosBuild,
                requiredIosGitSha: stream.requiredIosGitSha,
                requiredIosBuildSha256: stream.requiredIosBuildSha256,
                currentIosBuild: "101",
                currentIosGitSha: String(repeating: "8", count: 40),
                currentIosBuildSha256: String(repeating: "9", count: 64),
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "a later same-key app build cannot reuse an older hardware approval"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: stream.requiredIosBuild,
                requiredIosGitSha: stream.requiredIosGitSha,
                requiredIosBuildSha256: stream.requiredIosBuildSha256,
                currentIosBuild: "100",
                currentIosGitSha: String(repeating: "8", count: 40),
                currentIosBuildSha256: String(repeating: "a", count: 64),
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "a different app component cannot reuse the same bundle build approval"
        )
        let resumablePredecessor = MapStreamAppArtifactCompatibilityPolicy
            .resumablePredecessorIdentities[0]
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: resumablePredecessor.build,
                requiredIosGitSha: resumablePredecessor.gitSha,
                requiredIosBuildSha256: resumablePredecessor.componentSha256,
                currentIosBuild: "101",
                currentIosGitSha: String(repeating: "a", count: 40),
                currentIosBuildSha256: String(repeating: "b", count: 64),
                compatibleArtifactAppIdentities: [resumablePredecessor],
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .streamV2,
            "an exact reviewed predecessor artifact can resume after an app update"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: resumablePredecessor.build,
                requiredIosGitSha: resumablePredecessor.gitSha,
                requiredIosBuildSha256: String(repeating: "c", count: 64),
                currentIosBuild: "101",
                currentIosGitSha: String(repeating: "a", count: 40),
                currentIosBuildSha256: String(repeating: "b", count: 64),
                compatibleArtifactAppIdentities: [resumablePredecessor],
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "a one-field predecessor identity mutation remains fail closed"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: resumablePredecessor.build,
                requiredIosGitSha: resumablePredecessor.gitSha,
                requiredIosBuildSha256: resumablePredecessor.componentSha256,
                compatibleArtifactAppIdentities: [resumablePredecessor],
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "an unidentified current app cannot use a predecessor exception"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                deviceStatus: v1Status
            ),
            .legacyArtifactRequired,
            "stream artifact requires a durable legacy artifact on v1 firmware"
        )
        let wrongKeyStatus = MapTransferDeviceStatus(
            enabled: true,
            activeMapId: nil,
            activeSessionId: nil,
            activation: nil,
            protocols: [1, 2],
            streamFormatVersions: [1],
            streamTrust: ["map-prod-1=" + String(repeating: "6", count: 64)],
            firmwareVersion: "0.3.0",
            firmwareBuild: 42,
            firmwareGitSha: String(repeating: "7", count: 40)
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                deviceStatus: wrongKeyStatus
            ),
            .legacyArtifactRequired,
            "v2 requires the device to trust the artifact's exact public key material"
        )
        assertEqual(
            MapInstallProtocolSelector.select(isBikeMapStream: false, deviceStatus: v2Status),
            .archiveV1,
            "existing ZIP remains explicitly protocol v1"
        )
        assertEqual(
            ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: "session",
                activeSessionID: nil,
                activationStatus: "activating",
                activationSessionID: "session"
            ),
            .awaitDevice,
            "same-session activation is reconciled without a duplicate upload"
        )
        assertEqual(
            ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: "session",
                activeSessionID: nil,
                activationStatus: "paused",
                activationSessionID: "session"
            ),
            .upload,
            "a paused same-session stream remains resumable"
        )
        assertEqual(
            ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: "session",
                activeSessionID: "session",
                activationStatus: "idle",
                activationSessionID: nil
            ),
            .installed,
            "an exact active session never retransmits"
        )
    }

    @MainActor
    static func testSavedMapArtifactMetadataRoundTrip() {
        let suite = "SavedMapArtifactMetadataTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("map-id", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set(String(repeating: "c", count: 64), forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-map-metadata-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent("map-id.bmap")
        let originalBytes = Data([1, 2, 3, 4])
        try! originalBytes.write(to: artifactURL)
        let artifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map-id.bmap",
            objectKey: "maps/map-id.bmap",
            bytes: 4,
            sha256: String(repeating: "a", count: 64),
            manifestReceipt: String(repeating: "b", count: 64),
            signedManifestReceipt: String(repeating: "c", count: 64),
            signatureKeyId: "map-prod-1",
            signatureKeySha256: String(repeating: "5", count: 64),
            producerBuildSha256: String(repeating: "1", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
            requiredIosBuild: "100",
            requiredIosGitSha: String(repeating: "8", count: 40),
            requiredIosBuildSha256: String(repeating: "9", count: 64),
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        let metadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: "map-id",
            displayName: "China",
            localArtifactFilename: artifactURL.lastPathComponent,
            streamFormatVersion: 1,
            jobID: "job-id",
            serverURLString: "https://maps.example.com",
            clientInstallationID: "inst_v2_1234567890abcdef1234567890abcdef",
            primaryArtifact: artifact,
            legacyArtifact: nil,
            lastTransferProtocol: nil,
            lastTransferStreamFormat: nil,
            lastTransferSessionID: nil,
            lastBackgroundTaskID: nil,
            lastDeviceSequence: 7,
            lastDeviceState: "receiving",
            lastDeviceStep: 1,
            lastDeviceStepCount: 3,
            lastDeviceProgress: 42,
            expectedActiveMapID: "map-id",
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil
        )
        try! SavedMapArtifactMetadataStore.save(metadata, for: artifactURL)
        let manager = OfflineMapManager(defaults: defaults, cacheDirectory: directory)
        assertEqual(
            manager.activationProgress?.label,
            "Step 1/3 - 42%",
            "structured device progress survives app relaunch"
        )
        let backgroundDescriptor = BackgroundMapUploadDescriptor(
            mapID: "map-id",
            sessionID: String(repeating: "c", count: 64),
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactFilename: artifactURL.lastPathComponent
        )
        BackgroundMapUploadStateStore.markStarted(
            taskID: 99,
            descriptor: backgroundDescriptor,
            expectedBytes: 100,
            defaults: defaults
        )
        BackgroundMapUploadStateStore.markProgress(
            taskID: 99,
            completedBytes: 67,
            expectedBytes: 100,
            defaults: defaults
        )
        let restoredManager = OfflineMapManager(defaults: defaults, cacheDirectory: directory)
        assertEqual(
            restoredManager.activationProgress?.label,
            "Step 1/3 - 67%",
            "a relaunched manager adopts persisted background task progress"
        )
        assertEqual(
            restoredManager.statusMessage,
            "Map upload continues on device",
            "a restored in-flight task suppresses a duplicate upload prompt"
        )
        assertEqual(
            manager.renameCachedPack(at: artifactURL, to: " Shanghai "),
            "Shanghai",
            "saved map rename is trimmed"
        )
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: artifactURL)?.displayName,
            "Shanghai",
            "saved map rename updates artifact-aware metadata"
        )
        assertEqual(
            try? Data(contentsOf: artifactURL),
            originalBytes,
            "saved map rename never rewrites signed artifact bytes"
        )
    }

    static func testBackgroundMapUploadRestorationState() {
        let suite = "BackgroundMapUploadStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let descriptor = BackgroundMapUploadDescriptor(
            mapID: "map-id",
            sessionID: String(repeating: "d", count: 64),
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactFilename: "map-id.bmap"
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        BackgroundMapUploadStateStore.markStarted(
            taskID: 17,
            descriptor: descriptor,
            now: startedAt,
            defaults: defaults
        )
        assertEqual(
            BackgroundMapUploadStateStore.records(defaults: defaults),
            [BackgroundMapUploadRecord(
                taskID: 17,
                descriptor: descriptor,
                startedAt: startedAt,
                completedAt: nil,
                succeeded: nil,
                errorCode: nil,
                completedBytes: 0
            )],
            "background upload identity survives process state loss"
        )
        BackgroundMapUploadStateStore.markProgress(
            taskID: 17,
            completedBytes: 42,
            expectedBytes: 100,
            defaults: defaults
        )
        assertEqual(
            BackgroundMapUploadStateStore.latest(
                mapID: "map-id",
                sessionID: descriptor.sessionID,
                defaults: defaults
            )?.percentage,
            42,
            "restored background upload records retain determinate progress"
        )
        let completedAt = Date(timeIntervalSince1970: 200)
        BackgroundMapUploadStateStore.markCompleted(
            taskID: 17,
            succeeded: true,
            errorCode: nil,
            now: completedAt,
            defaults: defaults
        )
        let completed = BackgroundMapUploadStateStore.records(defaults: defaults).first
        assertEqual(completed?.completedAt, completedAt, "background completion is durable")
        assertEqual(completed?.succeeded, true, "background success is durable")

        let replacement = BackgroundMapUploadDescriptor(
            mapID: "other-map",
            sessionID: String(repeating: "e", count: 64),
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactFilename: "other-map.bmap"
        )
        BackgroundMapUploadStateStore.markStarted(
            taskID: 17,
            descriptor: replacement,
            defaults: defaults
        )
        assertEqual(
            BackgroundMapUploadStateStore.records(defaults: defaults).map(\.descriptor),
            [replacement],
            "a reused URL session task ID replaces stale cross-session state"
        )
    }

    static func testBackgroundMapUploadArbitration() {
        let current = BackgroundMapUploadDescriptor(
            mapID: "map-a",
            sessionID: "session-a",
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactFilename: "map-a.bmap",
            accessPointSSID: "BikeComputer-1234"
        )
        let other = BackgroundMapUploadDescriptor(
            mapID: "map-b",
            sessionID: "session-b",
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactFilename: "map-b.bmap",
            accessPointSSID: "BikeComputer-1234"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [],
                mapID: current.mapID,
                sessionID: current.sessionID
            ),
            .begin,
            "no restored upload leaves the device transfer channel available"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [current],
                mapID: current.mapID,
                sessionID: current.sessionID,
                resumeRequested: true
            ),
            .retireExisting,
            "an explicit resume retires only the matching restored upload"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [current],
                mapID: current.mapID,
                sessionID: current.sessionID
            ),
            .retainExisting,
            "the exact restored upload is reconciled instead of duplicated"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [current],
                mapID: other.mapID,
                sessionID: other.sessionID
            ),
            .blockForOther,
            "a restored upload globally reserves the single device transfer channel"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [current, other],
                mapID: current.mapID,
                sessionID: current.sessionID,
                resumeRequested: true
            ),
            .blockForOther,
            "resume never retires a cross-session collision"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [],
                hasUnidentifiedActiveUpload: true,
                mapID: current.mapID,
                sessionID: current.sessionID,
                resumeRequested: true
            ),
            .blockForOther,
            "resume never retires a descriptorless upload"
        )
        let legacy = BackgroundMapUploadDescriptor(
            mapID: "legacy-map",
            sessionID: "legacy-session",
            protocolVersion: 1,
            streamFormatVersion: nil,
            artifactFilename: "legacy-map.zip",
            accessPointSSID: "BikeComputer-1234"
        )
        assertEqual(
            BackgroundMapUploadArbitration.evaluate(
                active: [legacy],
                mapID: current.mapID,
                sessionID: current.sessionID
            ),
            .blockForOther,
            "an active legacy upload blocks a stream transfer"
        )
    }

    static func testPausedMapUploadResumePolicy() {
        assert(
            PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "paused"
            ),
            "a paused matching transfer exposes the resume action"
        )
        assert(
            PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "idle"
            ),
            "an interrupted transfer that returned to the active map can restart"
        )
        assert(
            PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "receiving",
                statusMessage: "Map upload paused. Tap Upload to resume."
            ),
            "a locally observed upload interruption exposes resume before BLE catches up"
        )
        assert(
            !PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "receiving"
            ),
            "a receiving transfer remains owned by its active background task"
        )
        assert(
            !PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-b",
                lastDeviceState: "paused"
            ),
            "a paused transfer never enables resume on another saved map"
        )
        assert(
            !PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "installed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "paused"
            ),
            "a terminal transfer does not expose a stale resume action"
        )
    }

    static func testBackgroundMapUploadResponseBufferIsBounded() {
        var buffer = BackgroundMapUploadResponseBuffer()
        assert(
            buffer.append(Data(repeating: 0x61, count: 4 * 1024)),
            "background upload accepts its complete bounded response"
        )
        assert(
            !buffer.append(Data([0x62])),
            "background upload rejects a response beyond its fixed budget"
        )
        assertEqual(
            buffer.data.count,
            4 * 1024,
            "rejected response bytes are not accumulated"
        )
    }

    static func testMapStreamBackgroundUploadRequest() {
        let request = MapTransferDeviceClient.streamUploadRequest(
            baseURL: URL(string: "http://192.168.4.1:8080")!,
            sessionId: "receipt+with/slash",
            sessionToken: "transfer-secret",
            contentLength: 123_456
        )
        assertEqual(request.httpMethod, "PUT", "stream background upload uses PUT")
        assertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/vnd.openbikecomputer.map-stream",
            "stream background upload uses the fixed media type"
        )
        assertEqual(
            request.value(forHTTPHeaderField: "Content-Length"),
            "123456",
            "stream background upload binds exact artifact length"
        )
        assertEqual(
            request.value(forHTTPHeaderField: "X-BikeComputer-Transfer-Token"),
            "transfer-secret",
            "stream background upload authenticates the device request"
        )
        assert(
            request.url?.absoluteString.contains("receipt%2Bwith%2Fslash/install-stream") == true,
            "stream background upload URL encodes session identity"
        )
        assert(
            request.value(forHTTPHeaderField: "X-Manifest-Receipt") == nil,
            "caller-controlled manifest headers are not part of the trust boundary"
        )
    }

    static func testOfflineMapInstallationCredentialClient() async {
        let suite = "OfflineMapInstallationCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
            clientInstallationToken: "v1." + String(repeating: "A", count: 43)
        )
        let store = OfflineMapInstallationCredentialStore(defaults: defaults)
        try! store.save(credential, serverURLString: "https://maps.example.com/")
        assertEqual(
            store.load(serverURLString: "https://MAPS.example.com"),
            credential,
            "installation credential is scoped to normalized server identity"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let artifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map.bmap",
            objectKey: "maps/map/map.bmap",
            bytes: 99,
            sha256: String(repeating: "1", count: 64),
            manifestReceipt: String(repeating: "2", count: 64),
            signedManifestReceipt: String(repeating: "3", count: 64),
            signatureKeyId: "map-prod-1",
            signatureKeySha256: String(repeating: "5", count: 64),
            producerBuildSha256: String(repeating: "1", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
            requiredIosBuild: "100",
            requiredIosGitSha: String(repeating: "8", count: 40),
            requiredIosBuildSha256: String(repeating: "9", count: 64),
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        OfflineMapTestURLProtocol.configure { request in
            switch request.url?.path {
            case "/v1/installations":
                assertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer api-secret",
                    "installation registration uses service authentication"
                )
                return (200, try! JSONEncoder().encode(credential))
            case "/v1/map-packs/map/artifacts/bike-map-stream-v1/download-url":
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Installation-Token"),
                    credential.clientInstallationToken,
                    "artifact URL refresh uses the installation token"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Map-Stream-Trust"),
                    "map-prod-1=" + String(repeating: "5", count: 64),
                    "artifact URL refresh advertises exact client trust material"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Map-Stream-App-Build"),
                    "100",
                    "artifact URL refresh binds the exact app build"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Map-Stream-App-Git-Sha"),
                    String(repeating: "8", count: 40),
                    "artifact URL refresh binds the exact app source"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Map-Stream-App-Build-Sha256"),
                    String(repeating: "9", count: 64),
                    "artifact URL refresh binds the generated app component"
                )
                assert(
                    request.url?.query?.contains(
                        "clientInstallationId=\(credential.clientInstallationId)"
                    ) == true,
                    "artifact URL refresh is installation scoped"
                )
                assert(
                    request.url?.query?.contains("signedManifestReceipt=\(String(repeating: "3", count: 64))") == true,
                    "artifact URL refresh is immutable-receipt scoped"
                )
                let response: [String: Any] = [
                    "format": artifact.format,
                    "mediaType": artifact.mediaType,
                    "filename": artifact.filename,
                    "objectKey": artifact.objectKey,
                    "bytes": artifact.bytes,
                    "sha256": artifact.sha256,
                    "manifestReceipt": artifact.manifestReceipt!,
                    "signedManifestReceipt": artifact.signedManifestReceipt!,
                    "signatureKeyId": artifact.signatureKeyId!,
                    "signatureKeySha256": artifact.signatureKeySha256!,
                    "producerBuildSha256": artifact.producerBuildSha256!,
                    "producerImageDigest": artifact.producerImageDigest!,
                    "requiredIosBuild": artifact.requiredIosBuild!,
                    "requiredIosGitSha": artifact.requiredIosGitSha!,
                    "requiredIosBuildSha256": artifact.requiredIosBuildSha256!,
                    "url": "/immutable/map.bmap",
                    "expiresAt": 123,
                    "expiresInSeconds": 900,
                ]
                return (200, try! JSONSerialization.data(withJSONObject: response))
            default:
                return (404, Data())
            }
        }
        defer { OfflineMapTestURLProtocol.reset() }
        let unregisteredClient = OfflineMapPlatformClient(
            baseURL: URL(string: "https://maps.example.com")!,
            apiToken: "api-secret",
            clientInstallationId: "legacy-installation",
            session: session
        )
        do {
            assertEqual(
                try await unregisteredClient.registerInstallation(),
                credential,
                "server-issued installation credential decodes"
            )
            let registeredClient = OfflineMapPlatformClient(
                baseURL: URL(string: "https://maps.example.com")!,
                apiToken: "api-secret",
                clientInstallationId: credential.clientInstallationId,
                clientInstallationToken: credential.clientInstallationToken,
                mapStreamTrustCapabilities: "map-prod-1=" + String(repeating: "5", count: 64),
                mapStreamAppBuildIdentity: MapStreamAppBuildIdentity(
                    schemaVersion: 1,
                    build: "100",
                    gitSha: String(repeating: "8", count: 40),
                    componentSha256: String(repeating: "9", count: 64)
                ),
                session: session
            )
            assertEqual(
                try await registeredClient.artifactDownloadURL(
                    mapId: "map",
                    jobId: "job-id",
                    artifact: artifact
                ).absoluteString,
                "https://maps.example.com/immutable/map.bmap",
                "artifact URL refresh returns an absolute immutable URL"
            )
        } catch {
            assert(false, "installation credential client contract succeeds: \(error)")
        }
    }

    static func testIconMapping() {
        assertEqual(NavigationInstructionMapper.iconID(for: "Continue straight"), NavigationIconID.straight, "straight maps to straight")
        assertEqual(NavigationInstructionMapper.iconID(for: "Turn left onto Main"), NavigationIconID.left, "left maps to left")
        assertEqual(NavigationInstructionMapper.iconID(for: "Slight right onto Oak"), NavigationIconID.right, "right maps to right")
        assertEqual(NavigationInstructionMapper.iconID(for: "Make U-turn"), NavigationIconID.uTurn, "u-turn maps to u-turn")
        assertEqual(NavigationInstructionMapper.iconID(for: "Make uturn when possible"), NavigationIconID.uTurn, "uturn maps to u-turn")
        assertEqual(NavigationInstructionMapper.iconID(for: "Arrive at destination"), NavigationIconID.straight, "destination falls back to straight")
    }

    static func testRouteEndpointExtraction() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4740),
            CLLocationCoordinate2D(latitude: 31.2320, longitude: 121.4750)
        ]
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)

        guard let endpoint = RoutePolylineEndpoint.location(for: polyline) else {
            assert(false, "polyline endpoint should exist")
            return
        }

        assertCoordinate(endpoint.coordinate, latitude: 31.2320, longitude: 121.4750, "polyline endpoint uses final coordinate")

        let emptyPolyline = MKPolyline()
        assert(RoutePolylineEndpoint.location(for: emptyPolyline) == nil, "empty polyline has no endpoint")
    }

    static func testRouteRemainingDistance() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0020, longitude: -122.0000)
        ]
        let route = TestRoute(instructions: "Continue", coordinates: coordinates)
        let totalDistance = route.distance

        let start = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
        let halfway = CLLocation(latitude: 37.0010, longitude: -122.0000)
        let finish = CLLocation(latitude: coordinates[2].latitude, longitude: coordinates[2].longitude)

        assert(abs((RouteProgress.remainingDistance(from: start, in: route) ?? -1) - totalDistance) < 1, "route remaining starts at full route distance")
        assert(abs((RouteProgress.remainingDistance(from: halfway, in: route) ?? -1) - totalDistance / 2) < 2, "route remaining tracks progress along route")
        assert(abs(RouteProgress.remainingDistance(from: finish, in: route) ?? -1) < 1, "route remaining reaches zero at route end")

        let offRouteNearHalfway = CLLocation(latitude: 37.0010, longitude: -122.0005)
        assert(abs((RouteProgress.remainingDistance(from: offRouteNearHalfway, in: route) ?? -1) - totalDistance / 2) < 2, "route remaining projects nearby locations onto closest segment")
    }

    static func testChinaRouteCoordinatesRoundTripWithoutCalibrationNudge() {
        let wgs = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let gcj = CoordinateConverter.wgs84ToGCJ02(coordinate: wgs)
        let converted = CoordinateConverter.gcj02ToWGS84(coordinate: gcj)

        assert(
            CLLocation(latitude: converted.latitude, longitude: converted.longitude)
                .distance(from: CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)) < 2,
            "GCJ route inverse should return WGS without a fixed calibration offset"
        )
    }

    static func testNonChinaCoordinatesPassThroughUnchanged() {
        let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        assertCoordinate(CoordinateConverter.wgs84ToGCJ02(coordinate: coordinate),
                         latitude: coordinate.latitude,
                         longitude: coordinate.longitude,
                         "non-China WGS->GCJ should pass through")
        assertCoordinate(CoordinateConverter.gcj02ToWGS84(coordinate: coordinate),
                         latitude: coordinate.latitude,
                         longitude: coordinate.longitude,
                         "non-China GCJ->WGS should pass through")
    }

    static func testSourceEndpointSelection() {
        switch RouteEndpointSelection.sourceEndpoint(hasSelectedSource: false, sourceAddress: "Ignored") {
        case .currentLocation:
            break
        default:
            assert(false, "default source should use current location")
        }

        switch RouteEndpointSelection.sourceEndpoint(hasSelectedSource: true, sourceAddress: "People's Square") {
        case .query(let query):
            assertEqual(query, "People's Square", "selected source should use query")
        default:
            assert(false, "selected source should use query endpoint")
        }
    }

    static func testRouteInitialLocationUsesResolvedSource() {
        let location = RouteInitialLocation.location(for: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737))

        assertCoordinate(location.coordinate, latitude: 31.2304, longitude: 121.4737, "initial navigation location uses resolved route source")
    }

    static func testRouteTransportTypes() {
        assertEqual(RouteTransportTypes.cycling.rawValue, 8, "cycling transport uses MapKit raw option")
    }

    static func testDeviceGPSPacketBuilder() {
        let data = DeviceGPSPacketBuilder.data(
            lat: 37.123456,
            lon: -122.654321,
            heading: 361,
            unixTime: 1_234_567_890,
            speedMetersPerSecond: 5.55,
            altitudeMeters: 42.4,
            distanceTraveledMeters: 1234.4,
            elapsedSeconds: 65.2,
            routeRemainingMeters: 9876.5
        )

        assertEqual(data.count, 30, "extended GPS packet has expected byte length")
        assertEqual(readInt32LE(data, offset: 0), 37_123_456, "GPS packet stores latitude microdegrees")
        assertEqual(readInt32LE(data, offset: 4), -122_654_321, "GPS packet stores longitude microdegrees")
        assertEqual(readUInt16LE(data, offset: 8), 359, "GPS packet clamps heading")
        assertEqual(readUInt32LE(data, offset: 10), 1_234_567_890, "GPS packet stores Unix time")
        assertEqual(readUInt16LE(data, offset: 14), 555, "GPS packet stores speed in centimeters per second")
        assertEqual(readInt16LE(data, offset: 16), 42, "GPS packet stores altitude in meters")
        assertEqual(readUInt32LE(data, offset: 18), 1234, "GPS packet stores distance traveled in meters")
        assertEqual(readUInt32LE(data, offset: 22), 65, "GPS packet stores elapsed seconds")
        assertEqual(readUInt32LE(data, offset: 26), 9877, "GPS packet stores rounded route remaining meters")

        let invalidData = DeviceGPSPacketBuilder.data(lat: 0, lon: 0, unixTime: 0)
        assertEqual(readUInt16LE(invalidData, offset: 14), DeviceGPSPacketBuilder.invalidSpeedCmps, "missing speed uses invalid sentinel")
        assertEqual(readUInt32LE(invalidData, offset: 26), DeviceGPSPacketBuilder.invalidRouteRemainingMeters, "missing route remaining uses invalid sentinel")
    }

    static func testOfflineMapCustomBBoxRequest() {
        let bounds = OfflineMapBounds(
            center: CLLocationCoordinate2D(latitude: 35.0, longitude: 136.0),
            sideLengthKm: 22.264
        )
        let request = OfflineMapJobRequest.customBBox(bounds)
        assertEqual(request.mode, "custom_bbox", "custom cut-out uses backend bbox mode")
        assert(request.bbox != nil, "custom cut-out includes bbox")
        assert(abs((request.bbox?[1] ?? 0) - 34.9) < 0.001, "bbox min latitude uses requested size")
        assert(abs((request.bbox?[3] ?? 0) - 35.1) < 0.001, "bbox max latitude uses requested size")

        let identified = request.identified(
            clientInstallationId: "installation-test",
            clientRequestId: "request-test-123",
            installOnDevice: true
        )
        assertEqual(identified.clientInstallationId, "installation-test", "request includes installation identity")
        assertEqual(identified.clientRequestId, "request-test-123", "request includes idempotency identity")
        assertEqual(identified.installOnDevice, true, "request preserves install workflow intent")
    }

    static func testOfflineMapPreparationTimeEstimate() {
        assertEqual(
            OfflineMapPreparationTimeEstimate.description(for: 1),
            "Usually under a minute",
            "small map preparation estimate"
        )
        assertEqual(
            OfflineMapPreparationTimeEstimate.description(for: 785),
            "Usually a few minutes",
            "city map preparation estimate"
        )
        assertEqual(
            OfflineMapPreparationTimeEstimate.description(for: 14_252),
            "May take 15–90 minutes",
            "large map preparation estimate"
        )
        assertEqual(
            OfflineMapPreparationTimeEstimate.description(for: 37_019),
            "May take several hours",
            "very large map preparation estimate"
        )
    }

    static func testOfflineMapJobProgressDecoding() {
        let payload = Data(
            """
            {
              "jobId": "job-progress",
              "status": "converting_features",
              "progress": {
                "completedBlocks": 79,
                "totalBlocks": 100,
                "fraction": 0.79
              }
            }
            """.utf8
        )
        guard let job = try? JSONDecoder().decode(OfflineMapJob.self, from: payload),
              let progress = job.progress else {
            assert(false, "map job progress should decode")
            return
        }

        assertEqual(progress.completedBlocks, 79, "map progress decodes completed blocks")
        assertEqual(progress.totalBlocks, 100, "map progress decodes total blocks")
        assertEqual(progress.percentage, 79, "map progress calculates percentage")
        assert(abs(progress.fraction - 0.79) < 0.000001, "map progress calculates fraction")
    }

    static func testOfflineMapJobProgressAbsentFallback() {
        let payload = Data("{\"jobId\":\"legacy-job\",\"status\":\"converting_features\"}".utf8)
        guard let job = try? JSONDecoder().decode(OfflineMapJob.self, from: payload) else {
            assert(false, "legacy map job should decode without progress")
            return
        }
        assertEqual(job.progress, nil, "legacy server response keeps indeterminate progress fallback")
    }

    static func testOfflineMapJobPersistence() {
        let suite = "offline-map-job-persistence-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "job persistence test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        OfflineMapJobPersistence.save(
            jobId: "job-resume",
            installOnDevice: true,
            serverURLString: "https://maps.example.com",
            apiTokenString: "job-token",
            defaults: defaults
        )
        OfflineMapJobPersistence.markPackDownloaded(
            jobId: "job-resume",
            mapId: "map-resume",
            defaults: defaults
        )
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            "job-resume",
            "active map job survives app relaunch"
        )
        assert(
            OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults),
            "onboarding map job preserves install intent"
        )
        assertEqual(
            OfflineMapJobPersistence.serverURLString(defaults: defaults),
            "https://maps.example.com",
            "pending job preserves its originating server"
        )
        assertEqual(
            OfflineMapJobPersistence.downloadedJobId(defaults: defaults),
            "job-resume",
            "downloaded pack state survives transfer interruption"
        )
        assertEqual(
            OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
            "map-resume",
            "downloaded pack identity survives app relaunch without server access"
        )
        assertEqual(
            OfflineMapJobPersistence.apiTokenString(defaults: defaults),
            "job-token",
            "pending job preserves its originating server credential"
        )
        OfflineMapJobPersistence.clear(defaults: defaults)
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            nil,
            "completed map job clears persisted recovery state"
        )
        assert(
            !OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults),
            "completed map job clears install intent"
        )
        assertEqual(
            OfflineMapJobPersistence.serverURLString(defaults: defaults),
            nil,
            "completed map job clears its originating server"
        )
        assertEqual(
            OfflineMapJobPersistence.downloadedJobId(defaults: defaults),
            nil,
            "completed map job clears downloaded recovery state"
        )
        assertEqual(
            OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
            nil,
            "completed map job clears downloaded map identity"
        )
        assertEqual(
            OfflineMapJobPersistence.apiTokenString(defaults: defaults),
            nil,
            "completed map job clears its originating credential"
        )
        OfflineMapRecoveryHistory.markHandled(jobId: "job-resume", defaults: defaults)
        OfflineMapRecoveryHistory.markHandled(jobId: "job-other", defaults: defaults)
        assertEqual(
            OfflineMapRecoveryHistory.handledJobIds(defaults: defaults),
            ["job-resume", "job-other"],
            "handled server jobs remain excluded from automatic redownload"
        )
        OfflineMapRecoveryHistory.forgetNextDiscovery(
            serverURLString: "https://maps-a.example:443/",
            defaults: defaults
        )
        assert(
            OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: "https://maps-a.example",
                defaults: defaults
            ),
            "forgetting discovery survives relaunch and default-port normalization"
        )
        assert(
            !OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: "https://maps-b.example",
                defaults: defaults
            ),
            "forgetting one server does not suppress another server"
        )
        assert(
            OfflineMapRecoveryHistory.consumeForgottenDiscovery(
                serverURLString: "https://maps-a.example",
                jobIds: ["job-existing-at-forget"],
                defaults: defaults
            ),
            "next successful discovery consumes the durable forget marker"
        )
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: defaults)
                .contains("job-existing-at-forget"),
            "forget snapshot durably excludes the server jobs it observed"
        )
        assert(
            !OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: "https://maps-a.example",
                defaults: defaults
            ),
            "consuming a forgotten snapshot is one-shot"
        )
        OfflineMapRecoveryHistory.forgetNextDiscovery(
            serverURLString: "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io/",
            defaults: defaults
        )
        assert(
            OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: OfflineMapServiceConfig.productionServerURLString,
                defaults: defaults
            ),
            "managed endpoint migration preserves the forgotten snapshot marker"
        )
        _ = OfflineMapRecoveryHistory.consumeForgottenDiscovery(
            serverURLString: OfflineMapServiceConfig.productionServerURLString,
            jobIds: [],
            defaults: defaults
        )
    }

    static func testOfflineMapInstallationIdentity() {
        let suite = "offline-map-installation-identity-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "installation identity test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bad", forKey: "offlineMap.clientInstallationId")

        let first = OfflineMapInstallationIdentity.resolve(defaults: defaults)
        let second = OfflineMapInstallationIdentity.resolve(defaults: defaults)

        assert(first != "bad", "invalid installation identity is replaced")
        assertEqual(second, first, "installation identity survives app relaunch")
    }

    static func testOfflineMapJobRecoverySelection() {
        let jobs = [
            offlineMapJob(
                jobId: "job-other",
                status: "converting_features",
                createdAt: "2026-07-12T01:00:00Z",
                clientInstallationId: "installation-other"
            ),
            offlineMapJob(
                jobId: "job-cached-old",
                status: "ready",
                mapId: "map-same-area",
                createdAt: "2026-07-12T02:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-running",
                status: "converting_features",
                createdAt: "2026-07-12T03:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-regenerated",
                status: "ready",
                mapId: "map-same-area",
                createdAt: "2026-07-12T04:00:00Z",
                clientInstallationId: "installation-mine",
                installOnDevice: true
            ),
            offlineMapJob(
                jobId: "job-failed",
                status: "failed",
                createdAt: "2026-07-12T05:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-expired",
                status: "expired",
                createdAt: "2026-07-12T06:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-cancelled",
                status: "cancelled",
                createdAt: "2026-07-12T07:00:00Z",
                clientInstallationId: "installation-mine"
            ),
            offlineMapJob(
                jobId: "job-ready-without-map",
                status: "ready",
                createdAt: "2026-07-12T08:00:00Z",
                clientInstallationId: "installation-mine"
            ),
        ].compactMap { $0 }

        let selected = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine"
        )

        assertEqual(selected?.jobId, "job-regenerated", "recovery selects the regenerated same-area job")
        assertEqual(selected?.mapId, "map-same-area", "same stable map ID does not suppress a new job")
        assertEqual(selected?.installOnDevice, true, "recovery restores install workflow intent")

        let afterHandling = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine",
            excludedJobIds: ["job-regenerated"]
        )
        assertEqual(
            afterHandling?.status,
            "converting_features",
            "recovery does not redownload a handled ready job"
        )
        assertEqual(afterHandling?.jobId, "job-running", "handled exclusion removes only that job")

        let none = OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: "installation-mine",
            excludedJobIds: ["job-regenerated", "job-running", "job-cached-old"]
        )
        assertEqual(none, nil, "terminal and ready-without-map jobs are not recoverable")

    }

    static func testOfflineMapDownloadResponseValidation() {
        let success = HTTPURLResponse(
            url: URL(string: "https://maps.example/download")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        do {
            try OfflineMapDownloadResponseValidator.validate(
                response: success,
                errorBody: "unused"
            )
        } catch {
            assert(false, "successful map download response should validate")
        }

        let forbidden = HTTPURLResponse(
            url: URL(string: "https://maps.example/download")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )
        do {
            try OfflineMapDownloadResponseValidator.validate(
                response: forbidden,
                errorBody: "download URL expired"
            )
            assert(false, "HTTP error body must not be cached as a map pack")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(let status, let body) = error else {
                assert(false, "HTTP error should retain its server status")
                return
            }
            assertEqual(status, 403, "download validation preserves HTTP status")
            assertEqual(body, "download URL expired", "download validation preserves error body")
        } catch {
            assert(false, "HTTP error should use OfflineMapPlatformError")
        }
    }

    @MainActor
    static func testOfflineMapPackDownloaderRejectsHTTPError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        OfflineMapTestURLProtocol.configure { _ in
            (403, Data("download URL expired".utf8))
        }
        defer { OfflineMapTestURLProtocol.reset() }

        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/expired.zip")!,
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "real downloader must reject an HTTP error body")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(let status, let body) = error else {
                assert(false, "real downloader should surface the HTTP status")
                return
            }
            assertEqual(status, 403, "real downloader preserves HTTP failure status")
            assert(
                body.contains("download URL expired"),
                "real downloader preserves the server error body"
            )
        } catch {
            assert(false, "real downloader should use OfflineMapPlatformError")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (403, Data(repeating: 0x41, count: 32 * 1024))
        }
        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/large-error.zip")!,
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "large HTTP error bodies must not be cached as maps")
        } catch let error as OfflineMapPlatformError {
            guard case .serverStatus(_, let body) = error else {
                assert(false, "large HTTP error should retain its status")
                return
            }
            assert(
                body.utf8.count <= 4 * 1024 + 3,
                "map download diagnostics retain only a bounded error prefix"
            )
        } catch {
            assert(false, "large HTTP error should use OfflineMapPlatformError")
        }

        OfflineMapTestURLProtocol.configure { _ in
            (200, Data(repeating: 0x42, count: 5))
        }
        do {
            _ = try await OfflineMapPackDownloader.download(
                from: URL(string: "https://maps.example/oversized.bmap")!,
                constraints: OfflineMapDownloadConstraints(
                    exactBytes: 4,
                    maximumBytes: BikeMapStreamFormat.maximumArtifactBytes
                ),
                onProgress: { _ in },
                onByteProgress: { _ in },
                configuration: configuration
            )
            assert(false, "a map artifact cannot exceed its declared byte count")
        } catch let error as BikeMapStreamFormatError {
            guard case .invalidArtifactMetadata = error else {
                assert(false, "oversized map download reports metadata mismatch")
                return
            }
        } catch {
            assert(false, "oversized map download reports a typed format error")
        }
    }

    static func testOfflineMapProgressPresentation() {
        let legacy = offlineMapJob(status: "converting_features")
        let progressPayload = Data(
            """
            {"jobId":"progress-job","status":"converting_features","progress":{"completedBlocks":4,"totalBlocks":10}}
            """.utf8
        )
        let progressJob = try? JSONDecoder().decode(OfflineMapJob.self, from: progressPayload)

        assertEqual(
            OfflineMapProgressPresentation.value(job: legacy, downloadProgress: 0),
            nil,
            "older servers keep the indeterminate progress view"
        )
        assertEqual(
            OfflineMapProgressPresentation.value(job: progressJob, downloadProgress: 0),
            0.4,
            "generation block progress drives the determinate progress view"
        )
        assertEqual(
            OfflineMapProgressPresentation.value(job: progressJob, downloadProgress: 0.75),
            0.4,
            "generation progress takes precedence while conversion is active"
        )
    }

    static func testMapActivationProgressPresentation() {
        let progress = MapActivationProgressPresentation.make(
            status: "activating",
            step: 1,
            stepCount: 5,
            percentage: 6
        )
        assertEqual(progress?.label, "Step 1/5 - 6%", "activation progress includes the total step count")
        assertEqual(progress?.fraction, 0.06, "activation percentage drives the progress bar")
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "receiving",
                step: 1,
                stepCount: 3,
                percentage: 50
            )?.label,
            "Step 1/3 - 50%",
            "stream reception uses the dynamic three-step presentation"
        )
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "finalizing",
                step: 2,
                stepCount: 3,
                percentage: 1
            )?.label,
            "Step 2/3 - 1%",
            "device-owned finalization remains visible after upload"
        )
        assertEqual(
            MapActivationProgressPresentation.make(
                status: "installed",
                step: 4,
                stepCount: 5,
                percentage: 100
            ),
            nil,
            "completed activation hides the in-progress presentation"
        )
    }

    static func testMapUploadProgressReconciliation() {
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: 10,
                durableDevicePercentage: 32
            ),
            32,
            "a retry does not display less than the durable device checkpoint"
        )
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: 40,
                durableDevicePercentage: 32
            ),
            40,
            "retry transport progress takes over after reaching the checkpoint"
        )
        assertEqual(
            MapUploadProgressReconciler.percentage(
                retryTransportPercentage: nil,
                durableDevicePercentage: 32
            ),
            32,
            "restoration can present a device checkpoint without a live task"
        )
    }

    static func testOfflineMapDownloadingSectionPresentation() {
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: true,
                hasPendingActivation: false,
                errorMessage: nil
            ),
            "paused persisted jobs keep the resume section reachable"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: false,
                errorMessage: nil
            ),
            "idle map settings omit an empty downloading section"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: true,
                errorMessage: nil
            ),
            "device-owned activation keeps its status section visible"
        )
        assert(
            OfflineMapAutomaticRecoveryTrigger.shouldResume(
                hasPendingInstall: true,
                isBusy: false,
                isConnected: true,
                isNavigationReady: true
            ),
            "pending device install resumes when BLE becomes ready"
        )
        assert(
            !OfflineMapAutomaticRecoveryTrigger.shouldResume(
                hasPendingInstall: true,
                isBusy: false,
                isConnected: true,
                isNavigationReady: false
            ),
            "pending device install waits for navigation readiness"
        )
    }

    static func testOfflineMapActivityCounterOverlappingOperations() {
        var counter = OfflineMapActivityCounter()
        counter.begin()
        counter.begin()
        counter.end()
        assert(
            counter.isBusy,
            "finishing a cancelled older operation keeps a newer map operation busy"
        )
        counter.end()
        assert(!counter.isBusy, "busy state clears after the final operation finishes")
    }

    @MainActor
    static func testPendingOfflineMapJobBlocksEveryCreationIngress() {
        let suite = "offline-map-pending-ingress-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "pending job ingress test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        OfflineMapJobPersistence.save(jobId: "job-existing", defaults: defaults)
        let manager = OfflineMapManager(defaults: defaults)

        manager.beginMapAreaSelection()
        manager.createCustomCutoutJob()
        manager.createJobFromSelectedMapArea()
        manager.installCurrentLocationMap(
            location: CLLocation(latitude: 31.2304, longitude: 121.4737),
            bleManager: BLEManager()
        )

        assert(
            !manager.isMapAreaSelectionActive,
            "pending job blocks the area-selection creation ingress"
        )
        assert(
            !manager.isBusy,
            "pending job blocks all creation tasks before network work starts"
        )
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            "job-existing",
            "all creation ingresses preserve the paused job recovery ID"
        )

        manager.forgetPendingMapJob()
        manager.beginMapAreaSelection()
        assertEqual(
            OfflineMapJobPersistence.activeJobId(defaults: defaults),
            nil,
            "forgetting an unrecoverable job clears its durable lock"
        )
        assert(
            manager.isMapAreaSelectionActive,
            "forgetting an unrecoverable job restores new-map creation"
        )
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: defaults).contains("job-existing"),
            "forgotten server job stays excluded from future discovery"
        )
    }

    @MainActor
    static func testOfflineMapJobCreatorReconcilesAmbiguousResponse() async {
        let request = OfflineMapJobRequest
            .customBBox(OfflineMapBounds(minLon: 10, minLat: 20, maxLon: 11, maxLat: 21))
            .identified(
                clientInstallationId: "installation-test",
                clientRequestId: "request-test-123",
                installOnDevice: false
            )
        guard let committed = offlineMapJob(
            jobId: "job-committed",
            status: "queued",
            clientInstallationId: "installation-test",
            clientRequestId: "request-test-123"
        ) else {
            assert(false, "committed job fixture should decode")
            return
        }
        var createRequestIds: [String?] = []
        var listCount = 0
        let recovered = try? await OfflineMapJobCreator.create(
            request: request,
            create: { attempt in
                createRequestIds.append(attempt.clientRequestId)
                throw URLError(.networkConnectionLost)
            },
            list: {
                listCount += 1
                return [committed]
            },
            sleep: { _ in
                assert(false, "committed ambiguous response should reconcile before retry sleep")
            },
            onRetry: {}
        )

        assertEqual(recovered?.jobId, "job-committed", "ambiguous POST response reconciles by request ID")
        assertEqual(createRequestIds, ["request-test-123"], "reconciliation preserves the submitted request ID")
        assertEqual(listCount, 1, "ambiguous create checks durable server jobs")

        var retryRequestIds: [String?] = []
        let retried = try? await OfflineMapJobCreator.create(
            request: request,
            create: { attempt in
                retryRequestIds.append(attempt.clientRequestId)
                if retryRequestIds.count == 1 {
                    throw URLError(.timedOut)
                }
                return committed
            },
            list: { [] },
            sleep: { _ in },
            onRetry: {}
        )
        assertEqual(retried?.jobId, "job-committed", "ambiguous create retries when reconciliation is empty")
        assertEqual(
            retryRequestIds,
            ["request-test-123", "request-test-123"],
            "every transport retry reuses the idempotency token"
        )
    }

    @MainActor
    static func testOfflineMapRecoveryRoutes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }

        func jobData(
            jobId: String,
            mapId: String,
            installationId: String? = nil,
            installOnDevice: Bool? = nil,
            createdAt: String = "2026-07-12T04:00:00Z"
        ) -> Data {
            var payload: [String: Any] = [
                "jobId": jobId,
                "status": "ready",
                "mapId": mapId,
                "createdAt": createdAt,
            ]
            if let installationId { payload["clientInstallationId"] = installationId }
            if let installOnDevice { payload["installOnDevice"] = installOnDevice }
            return try! JSONSerialization.data(withJSONObject: payload)
        }

        func downloadURLData(mapId: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "mapId": mapId,
                "url": "/downloads/\(mapId).zip",
                "expiresAt": 2_000_000_000,
                "expiresInSeconds": 900,
            ])
        }

        func packData(
            mapId: String,
            storedMapData: Data = Data([0x01]),
            hashedMapData: Data? = nil
        ) -> Data {
            let mapPath = "VECTMAP/0/0/0.pbf"
            let declaredData = hashedMapData ?? storedMapData
            let manifest = try! JSONSerialization.data(withJSONObject: [
                "mapId": mapId,
                "displayName": "Recovery Test",
                "files": [[
                    "path": mapPath,
                    "bytes": declaredData.count,
                    "sha256": FirmwareUpdateManager.sha256Hex(declaredData),
                ]],
            ])
            return makeStoredZip(entries: [
                ("manifest.json", manifest),
                (mapPath, storedMapData),
            ])
        }

        let corruptCacheSuite = "offline-map-corrupt-cache-route-\(UUID().uuidString)"
        let corruptCacheDefaults = UserDefaults(suiteName: corruptCacheSuite)!
        defer { corruptCacheDefaults.removePersistentDomain(forName: corruptCacheSuite) }
        let corruptCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-corrupt-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: corruptCache) }
        try! FileManager.default.createDirectory(at: corruptCache, withIntermediateDirectories: true)
        let corruptCachedPack = corruptCache.appendingPathComponent("map-corrupt-cache.zip")
        try! packData(
            mapId: "map-corrupt-cache",
            storedMapData: Data([0x02]),
            hashedMapData: Data([0x01])
        ).write(to: corruptCachedPack)
        let corruptCacheManager = OfflineMapManager(
            defaults: corruptCacheDefaults,
            mapPlatformSession: session,
            cacheDirectory: corruptCache
        )
        corruptCacheManager.transferCachedPack(at: corruptCachedPack, bleManager: BLEManager())
        let corruptCacheDeadline = Date().addingTimeInterval(3)
        while corruptCacheManager.errorMessage == nil && Date() < corruptCacheDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            corruptCacheManager.errorMessage?.contains("hash mismatch") == true,
            "cached packs are hash-validated before device transfer"
        )

        let persistedSuite = "offline-map-persisted-route-\(UUID().uuidString)"
        let persistedDefaults = UserDefaults(suiteName: persistedSuite)!
        defer { persistedDefaults.removePersistentDomain(forName: persistedSuite) }
        persistedDefaults.set("https://persisted.example", forKey: "offlineMap.serverURL")
        let persistedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistedCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted",
            installOnDevice: true,
            serverURLString: "https://persisted.example",
            apiTokenString: "persisted-token",
            defaults: persistedDefaults
        )
        persistedDefaults.set("https://current-setting.example", forKey: "offlineMap.serverURL")
        persistedDefaults.set("current-token", forKey: "offlineMap.apiToken")
        var persistedDownloadCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-persisted" {
                return (200, jobData(jobId: "job-persisted", mapId: "map-persisted"))
            }
            if request.url?.path == "/v1/map-packs/map-persisted/download-url" {
                return (200, downloadURLData(mapId: "map-persisted"))
            }
            return (404, Data())
        }
        let persistedManager = OfflineMapManager(
            defaults: persistedDefaults,
            mapPlatformSession: session,
            cacheDirectory: persistedCache,
            packDownload: { _, _, onProgress, _ in
                persistedDownloadCount += 1
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-persisted").write(to: url)
                return url
            }
        )
        let disconnectedBLE = BLEManager()
        persistedManager.resumePendingMapJobIfNeeded(bleManager: disconnectedBLE)
        let firstPersistedPassCompleted = await waitForMapTaskCompletion(persistedManager)
        assert(firstPersistedPassCompleted, "persisted recovery should finish its first pass")
        assert(persistedManager.hasPendingMapJob, "disconnected device preserves pending install intent")
        assert(
            persistedManager.hasDownloadedPendingDeviceInstall,
            "downloaded deferred install becomes eligible for BLE-ready auto-resume"
        )
        assertEqual(
            OfflineMapJobPersistence.downloadedJobId(defaults: persistedDefaults),
            "job-persisted",
            "downloaded persisted job is reusable for a later install"
        )
        assert(
            OfflineMapTestURLProtocol.requests().contains { $0.url?.host == "persisted.example" },
            "persisted recovery uses its originating server"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer persisted-token"
            },
            "persisted recovery uses its originating server credential"
        )
        let relaunchedPersistedManager = OfflineMapManager(
            defaults: persistedDefaults,
            mapPlatformSession: session,
            cacheDirectory: persistedCache,
            packDownload: { _, _, _, _ in
                persistedDownloadCount += 1
                throw URLError(.cannotConnectToHost)
            }
        )
        OfflineMapTestURLProtocol.configure { _ in
            throw URLError(.cannotConnectToHost)
        }
        relaunchedPersistedManager.resumePendingMapJobIfNeeded(bleManager: disconnectedBLE)
        let localRestoreDeadline = Date().addingTimeInterval(3)
        while relaunchedPersistedManager.downloadedPackURL == nil &&
                Date() < localRestoreDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            relaunchedPersistedManager.downloadedPackURL != nil,
            "app relaunch restores the deferred local pack without the map server"
        )
        assertEqual(
            OfflineMapTestURLProtocol.requests().count,
            0,
            "deferred local install does not poll the map server"
        )
        assertEqual(persistedDownloadCount, 1, "deferred device install reuses the downloaded pack")
        if let url = relaunchedPersistedManager.downloadedPackURL {
            relaunchedPersistedManager.deleteCachedPack(at: url)
        }
        relaunchedPersistedManager.forgetPendingMapJob()

        let managedSuite = "offline-map-managed-token-route-\(UUID().uuidString)"
        let managedDefaults = UserDefaults(suiteName: managedSuite)!
        defer { managedDefaults.removePersistentDomain(forName: managedSuite) }
        let managedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-managed-token-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-managed-token",
            serverURLString: "https://maps.8o.vc:443/",
            apiTokenString: "stale-bundled-token",
            defaults: managedDefaults
        )
        managedDefaults.set("https://unrelated-custom.example", forKey: "offlineMap.serverURL")
        managedDefaults.set("unrelated-custom-token", forKey: "offlineMap.apiToken")
        let managedManager = OfflineMapManager(
            defaults: managedDefaults,
            mapPlatformSession: session,
            cacheDirectory: managedCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-managed-token").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-managed-token" {
                return (200, jobData(jobId: "job-managed-token", mapId: "map-managed-token"))
            }
            if request.url?.path == "/v1/map-packs/map-managed-token/download-url" {
                return (200, downloadURLData(mapId: "map-managed-token"))
            }
            return (404, Data())
        }
        managedManager.resumePendingMapJobIfNeeded()
        let managedCompleted = await waitForMapTaskCompletion(managedManager)
        assert(managedCompleted, "managed-server recovery should complete after token rotation")
        let expectedManagedAuthorization = OfflineMapServiceConfig.apiToken.isEmpty ?
            nil : "Bearer \(OfflineMapServiceConfig.apiToken)"
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == URL(string: OfflineMapServiceConfig.productionServerURLString)?.host &&
                    $0.value(forHTTPHeaderField: "Authorization") == expectedManagedAuthorization
            },
            "managed-server recovery uses the updated bundled endpoint and credential"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") != "Bearer stale-bundled-token"
            },
            "managed-server recovery never reuses a stale bundled credential"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host != "unrelated-custom.example" &&
                    $0.value(forHTTPHeaderField: "Authorization") != "Bearer unrelated-custom-token"
            },
            "managed recovery ignores unrelated current custom settings"
        )
        if let url = managedManager.downloadedPackURL {
            managedManager.deleteCachedPack(at: url)
        }

        let rotatedCustomSuite = "offline-map-rotated-custom-token-\(UUID().uuidString)"
        let rotatedCustomDefaults = UserDefaults(suiteName: rotatedCustomSuite)!
        defer { rotatedCustomDefaults.removePersistentDomain(forName: rotatedCustomSuite) }
        let rotatedCustomCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-rotated-custom-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rotatedCustomCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-rotated-custom-token",
            serverURLString: "https://custom-rotation.example:443/",
            apiTokenString: "old-custom-token",
            defaults: rotatedCustomDefaults
        )
        rotatedCustomDefaults.set("https://custom-rotation.example", forKey: "offlineMap.serverURL")
        rotatedCustomDefaults.set("new-custom-token", forKey: "offlineMap.apiToken")
        let rotatedCustomManager = OfflineMapManager(
            defaults: rotatedCustomDefaults,
            mapPlatformSession: session,
            cacheDirectory: rotatedCustomCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-rotated-custom-token").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-rotated-custom-token" {
                return (200, jobData(jobId: "job-rotated-custom-token", mapId: "map-rotated-custom-token"))
            }
            if request.url?.path == "/v1/map-packs/map-rotated-custom-token/download-url" {
                return (200, downloadURLData(mapId: "map-rotated-custom-token"))
            }
            return (404, Data())
        }
        rotatedCustomManager.resumePendingMapJobIfNeeded()
        let rotatedCustomCompleted = await waitForMapTaskCompletion(rotatedCustomManager)
        assert(rotatedCustomCompleted, "same-origin custom recovery should complete after token rotation")
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == "custom-rotation.example" &&
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-custom-token"
            },
            "same-origin custom recovery uses the current rotated credential"
        )
        if let url = rotatedCustomManager.downloadedPackURL {
            rotatedCustomManager.deleteCachedPack(at: url)
        }

        let discoverySuite = "offline-map-discovery-route-\(UUID().uuidString)"
        let discoveryDefaults = UserDefaults(suiteName: discoverySuite)!
        defer { discoveryDefaults.removePersistentDomain(forName: discoverySuite) }
        discoveryDefaults.set("https://discovery.example", forKey: "offlineMap.serverURL")
        let discoveryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-discovery-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: discoveryCache) }
        let discoveryManager = OfflineMapManager(
            defaults: discoveryDefaults,
            mapPlatformSession: session,
            cacheDirectory: discoveryCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-discovered").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let job = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-discovered",
                        mapId: "map-discovered",
                        installationId: discoveryManager.clientInstallationId,
                        installOnDevice: false
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [job]]))
            }
            if request.url?.path == "/v1/map-jobs/job-discovered" {
                return (
                    200,
                    jobData(
                        jobId: "job-discovered",
                        mapId: "map-discovered",
                        installationId: discoveryManager.clientInstallationId,
                        installOnDevice: false
                    )
                )
            }
            if request.url?.path == "/v1/map-packs/map-discovered/download-url" {
                return (200, downloadURLData(mapId: "map-discovered"))
            }
            return (404, Data())
        }
        discoveryManager.resumePendingMapJobIfNeeded()
        let discoveryCompleted = await waitForMapTaskCompletion(discoveryManager)
        assert(discoveryCompleted, "launch discovery should complete")
        assert(!discoveryManager.hasPendingMapJob, "download-only discovery clears durable pending state")
        assert(
            OfflineMapRecoveryHistory.handledJobIds(defaults: discoveryDefaults).contains("job-discovered"),
            "launch discovery marks the exact recovered job handled"
        )
        if let url = discoveryManager.downloadedPackURL {
            discoveryManager.deleteCachedPack(at: url)
        }

        let downloadRetrySuite = "offline-map-download-retry-\(UUID().uuidString)"
        let downloadRetryDefaults = UserDefaults(suiteName: downloadRetrySuite)!
        defer { downloadRetryDefaults.removePersistentDomain(forName: downloadRetrySuite) }
        downloadRetryDefaults.set("https://download-retry.example", forKey: "offlineMap.serverURL")
        downloadRetryDefaults.set(
            ["map-download-retry.zip": "Shanghai Riverside"],
            forKey: "offlineMap.packDisplayNames"
        )
        OfflineMapJobPersistence.save(
            jobId: "job-download-retry",
            serverURLString: "https://download-retry.example",
            defaults: downloadRetryDefaults
        )
        let downloadRetryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-download-retry-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: downloadRetryCache) }
        try! FileManager.default.createDirectory(
            at: downloadRetryCache,
            withIntermediateDirectories: true
        )
        let downloadRetryPack = downloadRetryCache.appendingPathComponent("map-download-retry.zip")
        let originalDownloadRetryPackData = packData(mapId: "map-download-retry")
        try! originalDownloadRetryPackData.write(to: downloadRetryPack)
        var downloadURLIssueCount = 0
        var packDownloadAttemptCount = 0
        var rejectedTemporaryURLs: [URL] = []
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-download-retry" {
                return (200, jobData(jobId: "job-download-retry", mapId: "map-download-retry"))
            }
            if request.url?.path == "/v1/map-packs/map-download-retry/download-url" {
                downloadURLIssueCount += 1
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: [
                        "mapId": "map-download-retry",
                        "url": "/downloads/map-download-retry-\(downloadURLIssueCount).zip",
                        "expiresAt": 2_000_000_000,
                        "expiresInSeconds": 900,
                    ])
                )
            }
            return (404, Data())
        }
        let downloadRetryManager = OfflineMapManager(
            defaults: downloadRetryDefaults,
            mapPlatformSession: session,
            cacheDirectory: downloadRetryCache,
            packDownload: { _, _, onProgress, _ in
                packDownloadAttemptCount += 1
                if packDownloadAttemptCount <= 2 {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("zip")
                    if packDownloadAttemptCount == 1 {
                        try packData(mapId: "map-from-wrong-job").write(to: url)
                    } else {
                        try packData(
                            mapId: "map-download-retry",
                            storedMapData: Data([0x02]),
                            hashedMapData: Data([0x01])
                        ).write(to: url)
                    }
                    rejectedTemporaryURLs.append(url)
                    return url
                }
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-download-retry").write(to: url)
                return url
            }
        )
        downloadRetryManager.resumePendingMapJobIfNeeded()
        let firstDownloadAttemptCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(firstDownloadAttemptCompleted, "failed download attempt should stop cleanly")
        assert(downloadRetryManager.hasPendingMapJob, "failed download remains recoverable")
        assertEqual(downloadRetryManager.downloadURL, nil, "failed signed URL is discarded")
        assert(
            rejectedTemporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "mismatched downloaded archive is removed"
        )
        assertEqual(
            try? Data(contentsOf: downloadRetryPack),
            originalDownloadRetryPackData,
            "wrong-map replacement preserves the existing cached map"
        )

        downloadRetryManager.resumePendingMapJobIfNeeded()
        let corruptAttemptDeadline = Date().addingTimeInterval(3)
        while downloadURLIssueCount < 2 && Date() < corruptAttemptDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let corruptDownloadAttemptCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(corruptDownloadAttemptCompleted, "corrupt download attempt should stop cleanly")
        assert(downloadRetryManager.hasPendingMapJob, "corrupt download remains recoverable")
        assertEqual(downloadRetryManager.downloadURL, nil, "corrupt download URL is discarded")
        assert(
            rejectedTemporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "hash-mismatched archive is removed"
        )
        assertEqual(
            try? Data(contentsOf: downloadRetryPack),
            originalDownloadRetryPackData,
            "corrupt replacement preserves the existing cached map"
        )

        downloadRetryManager.resumePendingMapJobIfNeeded()
        let retryDeadline = Date().addingTimeInterval(3)
        while downloadURLIssueCount < 3 && Date() < retryDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let retriedDownloadCompleted = await waitForMapTaskCompletion(downloadRetryManager)
        assert(retriedDownloadCompleted, "download retry should complete")
        assertEqual(downloadURLIssueCount, 3, "each download retry obtains a fresh exact-job URL")
        assertEqual(packDownloadAttemptCount, 3, "download retry performs a clean third transfer")
        assert(!downloadRetryManager.hasPendingMapJob, "successful download retry clears recovery state")
        assertEqual(
            downloadRetryManager.displayName(forCachedPack: downloadRetryPack),
            "Shanghai Riverside",
            "same-map replacement preserves the user rename"
        )
        downloadRetryManager.deleteCachedPack(at: downloadRetryPack)

        let retrySuite = "offline-map-discovery-retry-\(UUID().uuidString)"
        let retryDefaults = UserDefaults(suiteName: retrySuite)!
        defer { retryDefaults.removePersistentDomain(forName: retrySuite) }
        retryDefaults.set("https://retry.example", forKey: "offlineMap.serverURL")
        let retryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-retry-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: retryCache) }
        let retryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache
        )
        OfflineMapTestURLProtocol.configure { _ in
            throw URLError(.notConnectedToInternet)
        }
        retryManager.resumePendingMapJobIfNeeded()
        let retryStarted = await waitForMapBusyState(retryManager, expected: true)
        assert(retryStarted, "transient launch discovery enters a retryable busy state")
        assert(retryManager.hasPendingMapJob, "transient launch discovery exposes pause and resume")
        retryManager.pausePendingMapJob()
        let retryPaused = await waitForMapBusyState(retryManager, expected: false)
        assert(retryPaused, "server recovery retry can be paused")
        assert(retryManager.hasPendingMapJob, "paused discovery remains resumable")
        retryManager.forgetPendingMapJob()
        assert(!retryManager.hasPendingMapJob, "paused discovery can be explicitly forgotten")
        let relaunchedRetryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let oldJob = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-forgotten-before-discovery",
                        mapId: "map-forgotten-before-discovery",
                        installationId: relaunchedRetryManager.clientInstallationId,
                        createdAt: "1970-01-01T00:00:00Z"
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [oldJob]]))
            }
            return (404, Data())
        }
        relaunchedRetryManager.resumePendingMapJobIfNeeded()
        let forgottenDeadline = Date().addingTimeInterval(3)
        while relaunchedRetryManager.hasPendingMapJob && Date() < forgottenDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(
            !relaunchedRetryManager.hasPendingMapJob,
            "forgotten discovery cutoff survives relaunch"
        )
        assertEqual(
            relaunchedRetryManager.currentJob,
            nil,
            "durable forget does not rediscover server jobs that already existed"
        )
        assert(!relaunchedRetryManager.isBusy, "durable forget leaves the app ready for a new map")
        assert(
            !OfflineMapRecoveryHistory.shouldForgetNextDiscovery(
                serverURLString: "https://retry.example",
                defaults: retryDefaults
            ),
            "successful discovery consumes the forget marker"
        )

        let futureDiscoveryManager = OfflineMapManager(
            defaults: retryDefaults,
            mapPlatformSession: session,
            cacheDirectory: retryCache,
            packDownload: { _, _, onProgress, _ in
                onProgress(1)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try packData(mapId: "map-created-after-forget").write(to: url)
                return url
            }
        )
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs" {
                let futureJob = try! JSONSerialization.jsonObject(
                    with: jobData(
                        jobId: "job-created-after-forget",
                        mapId: "map-created-after-forget",
                        installationId: futureDiscoveryManager.clientInstallationId,
                        createdAt: "2099-01-01T00:00:00Z"
                    )
                )
                return (200, try! JSONSerialization.data(withJSONObject: ["jobs": [futureJob]]))
            }
            if request.url?.path == "/v1/map-jobs/job-created-after-forget" {
                return (200, jobData(jobId: "job-created-after-forget", mapId: "map-created-after-forget"))
            }
            if request.url?.path == "/v1/map-packs/map-created-after-forget/download-url" {
                return (200, downloadURLData(mapId: "map-created-after-forget"))
            }
            return (404, Data())
        }
        futureDiscoveryManager.resumePendingMapJobIfNeeded()
        let futureDiscoveryCompleted = await waitForMapTaskCompletion(futureDiscoveryManager)
        assert(futureDiscoveryCompleted, "later same-server discovery should complete")
        assert(
            futureDiscoveryManager.downloadedPackURL != nil,
            "one-shot forget does not suppress a map created later"
        )
        if let url = futureDiscoveryManager.downloadedPackURL {
            futureDiscoveryManager.deleteCachedPack(at: url)
        }

        let launch401Suite = "offline-map-launch-401-\(UUID().uuidString)"
        let launch401Defaults = UserDefaults(suiteName: launch401Suite)!
        defer { launch401Defaults.removePersistentDomain(forName: launch401Suite) }
        launch401Defaults.set("https://launch-401.example", forKey: "offlineMap.serverURL")
        let launch401Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-launch-401-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: launch401Cache) }
        let launch401Manager = OfflineMapManager(
            defaults: launch401Defaults,
            mapPlatformSession: session,
            cacheDirectory: launch401Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (401, Data("unauthorized".utf8)) }
        launch401Manager.resumePendingMapJobIfNeeded()
        let launch401Completed = await waitForMapTaskCompletion(launch401Manager)
        assert(launch401Completed, "nonretryable launch discovery should stop")
        assert(launch401Manager.errorMessage?.contains("401") == true, "launch 401 is visible")
        assert(launch401Manager.hasPendingMapJob, "launch 401 remains explicitly dismissible")
        launch401Manager.forgetPendingMapJob()
        assert(!launch401Manager.hasPendingMapJob, "launch 401 escape hatch clears recovery state")

        let persisted401Suite = "offline-map-persisted-401-\(UUID().uuidString)"
        let persisted401Defaults = UserDefaults(suiteName: persisted401Suite)!
        defer { persisted401Defaults.removePersistentDomain(forName: persisted401Suite) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted-401",
            serverURLString: "https://persisted-401.example",
            defaults: persisted401Defaults
        )
        let persisted401Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-401-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persisted401Cache) }
        let persisted401Manager = OfflineMapManager(
            defaults: persisted401Defaults,
            mapPlatformSession: session,
            cacheDirectory: persisted401Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (401, Data("unauthorized".utf8)) }
        persisted401Manager.resumePendingMapJobIfNeeded()
        let persisted401Completed = await waitForMapTaskCompletion(persisted401Manager)
        assert(persisted401Completed, "persisted 401 should stop without spinning")
        assert(persisted401Manager.hasPendingMapJob, "persisted 401 retains the recoverable job ID")
        persisted401Manager.forgetPendingMapJob()
        assert(!persisted401Manager.hasPendingMapJob, "persisted 401 can be forgotten")

        let persisted404Suite = "offline-map-persisted-404-\(UUID().uuidString)"
        let persisted404Defaults = UserDefaults(suiteName: persisted404Suite)!
        defer { persisted404Defaults.removePersistentDomain(forName: persisted404Suite) }
        OfflineMapJobPersistence.save(
            jobId: "job-persisted-404",
            serverURLString: "https://persisted-404.example",
            defaults: persisted404Defaults
        )
        let persisted404Cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-persisted-404-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persisted404Cache) }
        let persisted404Manager = OfflineMapManager(
            defaults: persisted404Defaults,
            mapPlatformSession: session,
            cacheDirectory: persisted404Cache
        )
        OfflineMapTestURLProtocol.configure { _ in (404, Data("missing".utf8)) }
        persisted404Manager.resumePendingMapJobIfNeeded()
        let persisted404Completed = await waitForMapTaskCompletion(persisted404Manager)
        assert(persisted404Completed, "persisted 404 should stop")
        assert(!persisted404Manager.hasPendingMapJob, "persisted 404 clears stale durable state")
        assert(persisted404Manager.errorMessage?.contains("404") == true, "persisted 404 is visible")
    }

    @MainActor
    static func testOfflineMapPollerOutlivesLegacyAttemptLimit() async {
        guard let running = offlineMapJob(status: "converting_features"),
              let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "poller test jobs should decode")
            return
        }
        var fetchCount = 0
        let result = try? await OfflineMapJobPoller.waitForReady(
            jobId: "long-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                fetchCount += 1
                return fetchCount <= 1_801 ? running : ready
            },
            sleep: { _ in },
            onUpdate: { _ in },
            onRetry: {}
        )

        assertEqual(fetchCount, 1_802, "poller continues beyond the former 1,800-attempt limit")
        assertEqual(result?.mapId, "map-ready", "poller returns the eventual ready map")
    }

    @MainActor
    static func testOfflineMapPollerRetriesTransientFailure() async {
        guard let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "retry test job should decode")
            return
        }
        var fetchCount = 0
        var retryCount = 0
        var delays: [UInt64] = []
        let result = try? await OfflineMapJobPoller.waitForReady(
            jobId: "retry-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                fetchCount += 1
                if fetchCount == 1 {
                    throw URLError(.timedOut)
                }
                return ready
            },
            sleep: { delays.append($0) },
            onUpdate: { _ in },
            onRetry: { retryCount += 1 }
        )

        assertEqual(result?.mapId, "map-ready", "transient polling failure recovers")
        assertEqual(retryCount, 1, "transient polling failure reports reconnecting state")
        assertEqual(delays, [2_000_000_000], "first retry uses bounded backoff")
        assert(!OfflineMapPollingRetryPolicy.shouldRetry(
            OfflineMapPlatformError.serverStatus(401, "unauthorized")
        ), "authentication failures remain terminal")
    }

    @MainActor
    static func testOfflineMapPollerStopsOnTerminalAndCancellation() async {
        guard let failed = offlineMapJob(status: "failed", error: "conversion failed"),
              let running = offlineMapJob(status: "converting_features") else {
            assert(false, "terminal poller test jobs should decode")
            return
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "failed-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in failed },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "terminal map job should throw")
        } catch OfflineMapPlatformError.serverStatus(let status, let body) {
            assertEqual(status, 409, "terminal map job uses conflict status")
            assert(body.contains("conversion failed"), "terminal map job preserves server error")
        } catch {
            assert(false, "terminal map job should use platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "cancel-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in running },
                sleep: { _ in throw CancellationError() },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "cancelled polling should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled polling should preserve CancellationError")
        }
    }

    static func offlineMapJob(
        jobId: String? = nil,
        status: String,
        mapId: String? = nil,
        error: String? = nil,
        createdAt: String? = nil,
        clientInstallationId: String? = nil,
        clientRequestId: String? = nil,
        installOnDevice: Bool? = nil
    ) -> OfflineMapJob? {
        var payload: [String: Any] = ["jobId": jobId ?? "job-\(status)", "status": status]
        if let mapId { payload["mapId"] = mapId }
        if let error { payload["error"] = error }
        if let createdAt { payload["createdAt"] = createdAt }
        if let clientInstallationId { payload["clientInstallationId"] = clientInstallationId }
        if let clientRequestId { payload["clientRequestId"] = clientRequestId }
        if let installOnDevice { payload["installOnDevice"] = installOnDevice }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(OfflineMapJob.self, from: data)
    }

    static func testOfflineMapCreateJobURLRequest() {
        let request = OfflineMapJobRequest
            .customBBox(
                OfflineMapBounds(minLon: 10, minLat: 20, maxLon: 11, maxLat: 21)
            )
            .identified(
                clientInstallationId: "installation-test",
                clientRequestId: "request-test-123",
                installOnDevice: false
            )
        guard let url = URL(string: "https://maps.example.com/api") else {
            assert(false, "base URL should parse")
            return
        }
        guard let urlRequest = try? OfflineMapPlatformClient.makeCreateJobURLRequest(
            baseURL: url,
            apiToken: "secret",
            jobRequest: request
        ) else {
            assert(false, "create job URL request should build")
            return
        }
        assertEqual(urlRequest.url?.absoluteString, "https://maps.example.com/api/v1/map-jobs", "create job URL appends API path")
        assertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret", "create job request includes bearer token")
        let body = String(data: urlRequest.httpBody ?? Data(), encoding: .utf8) ?? ""
        assert(body.contains("\"mode\":\"custom_bbox\""), "create job body includes mode")
        assert(body.contains("\"bbox\":[10,20,11,21]"), "create job body includes bbox")
        assert(body.contains("\"clientInstallationId\":\"installation-test\""), "create job body includes installation identity")
        assert(body.contains("\"clientRequestId\":\"request-test-123\""), "create job body includes request identity")
        assert(body.contains("\"installOnDevice\":false"), "create job body includes workflow intent")
    }

    static func testOfflineMapListJobsURLRequest() {
        guard let baseURL = URL(string: "https://maps.example.com/api"),
              let request = try? OfflineMapPlatformClient.makeListJobsURLRequest(
                baseURL: baseURL,
                apiToken: "secret",
                clientInstallationId: "installation-test"
              ) else {
            assert(false, "list jobs URL request should build")
            return
        }

        assertEqual(
            request.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs?clientInstallationId=installation-test",
            "list jobs request filters by installation identity"
        )
        assertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret",
            "list jobs request includes bearer token"
        )
        guard let jobRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: "secret",
            path: "/v1/map-jobs/job-12345678",
            method: "GET",
            clientInstallationId: "installation-test"
        ),
        let downloadRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: "secret",
            path: "/v1/map-packs/map-12345678/download-url",
            method: "POST",
            clientInstallationId: "installation-test",
            additionalQueryItems: [
                URLQueryItem(name: "jobId", value: "job-12345678")
            ]
        ) else {
            assert(false, "installation-scoped requests should build")
            return
        }
        assertEqual(
            jobRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678?clientInstallationId=installation-test",
            "job polling is scoped to the installation"
        )
        assertEqual(downloadRequest.httpMethod, "POST", "download URL keeps its POST method")
        assert(
            downloadRequest.url?.query?.contains("clientInstallationId=installation-test") == true,
            "download URL lookup is scoped to the installation"
        )
        assert(
            downloadRequest.url?.query?.contains("jobId=job-12345678") == true,
            "download URL lookup stays bound to the recovered job"
        )
    }

    static func testOfflineMapInventoryMutationURLRequests() {
        guard let baseURL = URL(string: "https://maps.example.com/api"),
              let displayNameRequest = try? OfflineMapPlatformClient.makeUpdateDisplayNameURLRequest(
                baseURL: baseURL,
                apiToken: "secret",
                clientInstallationId: "installation-test",
                jobId: "job-12345678",
                displayName: "Shanghai and Suzhou"
              ),
              let downloadReceiptRequest = try? OfflineMapPlatformClient.makeRecordDownloadURLRequest(
                baseURL: baseURL,
                apiToken: "secret",
                clientInstallationId: "installation-test",
                jobId: "job-12345678",
                receipt: OfflineMapDownloadReceiptRequest(
                    receiptId: "receipt-12345678",
                    artifactFormat: "bike-map-stream-v1",
                    sha256: "0123456789abcdef",
                    bytes: 1_234_567
                )
              ) else {
            assert(false, "inventory mutation URL requests should build")
            return
        }

        assertEqual(displayNameRequest.httpMethod, "PATCH", "display name update uses PATCH")
        assertEqual(
            displayNameRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678/display-name?clientInstallationId=installation-test",
            "display name update is scoped to the installation"
        )
        assertEqual(
            displayNameRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret",
            "display name update includes bearer token"
        )
        assertEqual(
            displayNameRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json",
            "display name update sends JSON"
        )
        let displayNameBody = (try? JSONSerialization.jsonObject(
            with: displayNameRequest.httpBody ?? Data()
        )) as? [String: Any]
        assertEqual(
            displayNameBody?["displayName"] as? String,
            "Shanghai and Suzhou",
            "display name update encodes the user label"
        )

        assertEqual(downloadReceiptRequest.httpMethod, "POST", "download receipt uses POST")
        assertEqual(
            downloadReceiptRequest.url?.absoluteString,
            "https://maps.example.com/api/v1/map-jobs/job-12345678/downloads?clientInstallationId=installation-test",
            "download receipt is scoped to the installation"
        )
        assertEqual(
            downloadReceiptRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret",
            "download receipt includes bearer token"
        )
        assertEqual(
            downloadReceiptRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json",
            "download receipt sends JSON"
        )
        let receiptBody = (try? JSONSerialization.jsonObject(
            with: downloadReceiptRequest.httpBody ?? Data()
        )) as? [String: Any]
        assertEqual(receiptBody?["receiptId"] as? String, "receipt-12345678", "receipt ID is encoded")
        assertEqual(receiptBody?["artifactFormat"] as? String, "bike-map-stream-v1", "artifact format is encoded")
        assertEqual(receiptBody?["sha256"] as? String, "0123456789abcdef", "artifact digest is encoded")
        assertEqual(receiptBody?["bytes"] as? Int, 1_234_567, "artifact size is encoded")
    }

    static func testOfflineMapManagerMigratesProductionConfig() {
        let suite = "offline-map-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io", forKey: "offlineMap.serverURL")
        defaults.set("stale-bundled-token", forKey: "offlineMap.apiToken")

        assertEqual(
            OfflineMapManager.resolvedServerURL(defaults: defaults),
            "https://maps.8o.vc",
            "legacy offline map server URL migrates to production domain"
        )
        assertEqual(
            OfflineMapManager.resolvedAPIToken(
                defaults: defaults,
                bundledToken: "new-bundled-token"
            ),
            "new-bundled-token",
            "new bundled map API token replaces a stale token after app update"
        )

        defaults.set("https://custom-map-server.example", forKey: "offlineMap.serverURL")
        defaults.set("custom-server-token", forKey: "offlineMap.apiToken")
        assertEqual(
            OfflineMapManager.resolvedAPIToken(
                defaults: defaults,
                bundledToken: "new-bundled-token"
            ),
            "custom-server-token",
            "custom server keeps its deliberate custom credential"
        )
    }

    @MainActor
    static func testOfflineMapManagerRenamesCachedPack() {
        let suite = "offline-map-rename-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "rename test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let packURL = cacheDirectory.appendingPathComponent("custom-map-shanghai.zip")

        let manager = OfflineMapManager(defaults: defaults, cacheDirectory: cacheDirectory)
        var renameInteraction = SavedMapRenameInteraction()
        assertEqual(
            renameInteraction.begin(
                filename: packURL.lastPathComponent,
                currentName: "Shanghai"
            ),
            nil,
            "starting a rename has no previous draft to commit"
        )
        renameInteraction.updateDraft("  Shanghai Riverside  ")
        assertEqual(
            renameInteraction.finishIfFocusMoved(to: packURL.lastPathComponent),
            nil,
            "tapping within the active name field keeps editing"
        )
        guard let tapAwayCommit = renameInteraction.finishIfFocusMoved(to: nil) else {
            assert(false, "tapping elsewhere should produce a rename commit")
            return
        }
        assertEqual(
            tapAwayCommit.filename,
            packURL.lastPathComponent,
            "tap-away commit retains the edited map identity"
        )
        assertEqual(
            manager.renameCachedPack(at: packURL, to: tapAwayCommit.proposedName),
            "Shanghai Riverside",
            "tap-away commit trims surrounding whitespace"
        )
        assertEqual(
            manager.displayName(forCachedPack: packURL),
            "Shanghai Riverside",
            "renamed map is shown immediately"
        )

        let restoredManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )
        assertEqual(
            restoredManager.displayName(forCachedPack: packURL),
            "Shanghai Riverside",
            "renamed map survives app restart"
        )
        assertEqual(
            restoredManager.renameCachedPack(at: packURL, to: "   \n "),
            "Shanghai Riverside",
            "blank rename preserves the existing name"
        )
    }

    static func testSavedMapRenameViewWiring() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            assert(false, "settings view source should be available to the integration test")
            return
        }
        assert(
            source.contains("focusedPackFilename: $focusedSavedMapFilename"),
            "settings form passes its focus binding into Saved Maps"
        )
        assert(
            source.contains("Spacer()\n                .contentShape(Rectangle())\n                .onTapGesture {\n                    focusedPackFilename = nil\n                }"),
            "tapping outside the saved-map name clears focus without covering form controls"
        )
        assert(
            source.contains("manager.beginMapAreaSelection()\n                if manager.isMapAreaSelectionActive {\n                    dismiss()\n                }"),
            "Download a new Map starts selection and explicitly dismisses Settings"
        )
        assert(
            source.contains(".onChange(of: focusedPackFilename) { newValue in\n            scheduleRenameCommitIfNeeded(focusedFilename: newValue)\n        }"),
            "Saved Maps commits a rename when form focus moves away"
        )
        assert(
            !source.contains("title: \"Installed on Device\"") &&
                !source.contains("title: \"Last Transfer\""),
            "Saved Maps omits redundant device and transfer summary rows"
        )
        assert(
            source.contains("if isInstalled {") &&
                source.contains("Image(systemName: \"checkmark.circle.fill\")") &&
                source.contains("\"arrow.clockwise.circle\"") &&
                source.contains("\"arrow.up.circle\""),
            "each saved map shows installed status, resume, or upload as exclusive actions"
        )
        assert(
            source.contains("manager.resumePausedMapUpload(bleManager: bleManager)") &&
                source.contains("Map upload paused. Tap to resume."),
            "the paused status row resumes the matching map transfer"
        )
        assert(
            source.contains(".alert(\"Already on Device\""),
            "tapping installed status explains that the map is already on the device"
        )
        assert(
            source.contains("manager.hasActiveBackgroundUpload"),
            "a restored upload disables conflicting saved-map upload and delete actions"
        )
        assert(
            source.contains("SavedMapThumbnail(") &&
                source.contains("manager.previewImage(forCachedPack: packURL)") &&
                source.contains("manager.loadPreviewIfNeeded(forCachedPack: packURL)") &&
                source.contains(".frame(width: 52, height: 36)"),
            "each saved map shows a fixed-size preview before its editable name"
        )
        let managerSourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift"
        )
        guard let managerSource = try? String(contentsOf: managerSourceURL, encoding: .utf8) else {
            assert(false, "offline map manager source should be available to the integration test")
            return
        }
        assert(
            managerSource.contains("Task.detached(priority: .utility)") &&
                !managerSource.contains("packURLs.forEach(cachePreviewIfAvailable)"),
            "saved-map previews load lazily without scanning cached archives on the main actor"
        )
        assert(
            managerSource.contains(
                "refreshCachedPacks()\n#if canImport(UIKit)\n        loadPreviewIfNeeded(forCachedPack: destination)"
            ),
            "replacing a pack at the same URL explicitly reloads its invalidated preview"
        )
        assert(
            managerSource.contains("OfflineMapPackCompatibilityArchive.make(") &&
                managerSource.contains(
                    "archiveURL: compatibilityArchiveURL ?? packURL"
                ) &&
                managerSource.contains("useForegroundTransfer = true") &&
                managerSource.contains("allowLocalStorageFailure:") &&
                managerSource.contains("catch is CancellationError") &&
                managerSource.contains("OfflineMapPackCompatibilityArchive.remove("),
            "preview ZIPs retain resumable background upload through a sanitized archive"
        )
    }

    @MainActor
    static func testOfflineMapManagerRestoresLastTransferIdentity() {
        let suite = "offline-map-transfer-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("custom-map-shanghai", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("shanghai-session", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set(
            ["custom-map-shanghai.zip": "Shanghai"],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(defaults: defaults)
        assertEqual(manager.lastTransferMapId, "custom-map-shanghai", "last transfer map id survives app restart")
        assertEqual(manager.lastTransferOutcome, "unconfirmed", "last transfer outcome survives app restart")
        assertEqual(manager.lastTransferDescription, "Shanghai — unconfirmed", "last transfer identifies the selected saved map")
        assert(manager.hasPendingDeviceActivation,
               "unconfirmed activation keeps its status visible after app restart")

        let bleManager = BLEManager()
        bleManager.mapTransferActiveMapId = "old-map"
        bleManager.mapTransferActiveSessionId = "old-session"
        bleManager.mapTransferActivationStatus = "idle"
        manager.reconcileLastTransfer(bleManager: bleManager)
        assertEqual(
            manager.statusMessage,
            "Activation paused. Tap Upload to resume.",
            "an idle rebooted device does not claim activation is still running"
        )
    }

    @MainActor
    static func testOfflineMapManagerReconcilesInterruptedActivation() {
        let suite = "offline-map-reconcile-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("activating", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("map-1-manifest", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set("map-1", forKey: "offlineMap.lastTransfer.previousMapId")
        defaults.set(4, forKey: "offlineMap.lastTransfer.previousSequence")

        let manager = OfflineMapManager(defaults: defaults)
        assertEqual(manager.lastTransferOutcome, "unconfirmed", "interrupted activation restores as unconfirmed")

        let bleManager = BLEManager()
        bleManager.mapTransferActiveMapId = "map-1"
        bleManager.mapTransferActiveSessionId = "map-1-manifest"
        bleManager.mapTransferActivationStatus = "idle"
        manager.reconcileLastTransfer(bleManager: bleManager)

        assertEqual(manager.lastTransferOutcome, "installed", "durable exact-session status reconciles after device restart")
        assert(!manager.hasPendingDeviceActivation,
               "installed reconciliation clears pending activation status")
    }

    @MainActor
    static func testOfflineMapManagerReconcilesAcknowledgedFirstInstall() {
        let suite = "offline-map-first-install-reconcile-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("map-1", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set("map-1-manifest", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set(9, forKey: "offlineMap.lastTransfer.acceptedSequence")

        let manager = OfflineMapManager(defaults: defaults)
        let bleManager = BLEManager()
        bleManager.mapTransferActiveMapId = "map-1"
        bleManager.mapTransferActiveSessionId = "map-1-manifest"
        bleManager.mapTransferActivationStatus = "installed"
        bleManager.mapTransferActivationSequence = 9
        bleManager.mapTransferActivationSessionId = "map-1-manifest"
        bleManager.mapTransferActivationMapId = "map-1"
        manager.reconcileLastTransfer(bleManager: bleManager)

        assertEqual(manager.lastTransferOutcome, "installed",
                    "persisted activation acknowledgement reconciles after app restart")
    }

    static func testOfflineMapPolygonClosesRing() {
        let request = OfflineMapJobRequest.customPolygon(ring: [
            CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 1, longitude: 3),
            CLLocationCoordinate2D(latitude: 2, longitude: 3),
            CLLocationCoordinate2D(latitude: 2, longitude: 2)
        ])
        guard case .polygon(let rings)? = request.geometry?.coordinates else {
            assert(false, "custom polygon should encode polygon coordinates")
            return
        }
        assertEqual(rings[0].first, rings[0].last, "custom polygon closes outer ring")
    }

    static func testOfflineMapStoredZipReader() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-test-\(UUID().uuidString).zip")
        let manifest = Data("{\"schemaVersion\":1}".utf8)
        let block = Data("map-block".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("ATTRIBUTION.txt", Data("OpenStreetMap".utf8)),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", block)
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "stored zip archive should parse")
            return
        }

        assertEqual(archive.mapFileEntries.count, 1, "zip reader exposes VECTMAP file entries")
        assertEqual(archive.manifestEntry?.path, "manifest.json", "zip reader exposes manifest entry")
        assertEqual(try? archive.data(for: archive.mapFileEntries[0]), block, "zip reader reads entry data")
        assert(
            !MapArchiveUploadStrategy.requiresCompatibilityArchive(for: archive),
            "legacy ZIPs without preview entries retain background archive transfer"
        )

        let duplicateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-duplicate-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: duplicateURL) }
        let duplicatePath = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        let duplicateManifest = try! JSONSerialization.data(withJSONObject: [
            "mapId": "map-1",
            "files": [[
                "path": duplicatePath,
                "bytes": block.count,
                "sha256": FirmwareUpdateManager.sha256Hex(block),
            ]],
        ])
        let duplicateZip = makeStoredZip(entries: [
            ("manifest.json", duplicateManifest),
            (duplicatePath, block),
            (duplicatePath, block),
        ])
        try? duplicateZip.write(to: duplicateURL)
        do {
            let duplicateArchive = try OfflineMapPackArchive(url: duplicateURL)
            try duplicateArchive.validate(expectedMapId: "map-1")
            assert(false, "duplicate map entries should be rejected")
        } catch OfflineMapPlatformError.invalidPack {
            // Expected.
        } catch {
            assert(false, "duplicate map entries should produce invalidPack")
        }
    }

    static func testOfflineMapPackPreviewReader() {
        let preview = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let previewMetadata: [String: Any] = [
            "type": "boundary-png",
            "path": "preview.png",
            "width": 1,
            "height": 1,
            "background": "transparent",
            "dataBase64": preview.base64EncodedString(),
        ]
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": "map-1",
            "preview": previewMetadata,
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-preview-\(UUID().uuidString).zip")
        try? makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("ATTRIBUTION.txt", Data("OpenStreetMap contributors".utf8)),
            ("LICENSES/OpenStreetMap-ODbL.txt", Data("ODbL".utf8)),
            ("preview.png", preview),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: url),
            preview,
            "stored map packs expose their boundary preview"
        )
        guard let previewArchive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "preview ZIP should parse for transfer strategy")
            return
        }
        assert(
            MapArchiveUploadStrategy.requiresCompatibilityArchive(for: previewArchive),
            "preview ZIPs require a device-compatible upload archive"
        )
        let compatibilityURL = try! OfflineMapPackCompatibilityArchive.make(
            from: previewArchive
        )
        defer { OfflineMapPackCompatibilityArchive.remove(compatibilityURL) }
        let compatibilityArchive = try! OfflineMapPackArchive(url: compatibilityURL)
        let orphanURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bike-map-device-\(UUID().uuidString).zip")
        try! Data("orphan".utf8).write(to: orphanURL)
        OfflineMapPackCompatibilityArchive.removeOrphans()
        assert(
            FileManager.default.fileExists(atPath: compatibilityURL.path),
            "orphan cleanup protects a compatibility archive in active preparation"
        )
        assert(
            !FileManager.default.fileExists(atPath: orphanURL.path),
            "orphan cleanup removes a compatibility archive left by a prior process"
        )
        assert(
            !compatibilityArchive.entries.contains(where: { $0.path == "preview.png" }),
            "device compatibility archive omits the local-only preview"
        )
        assert(
            compatibilityArchive.entries.contains(where: {
                $0.path == "ATTRIBUTION.txt"
            }) && compatibilityArchive.entries.contains(where: {
                $0.path == "LICENSES/OpenStreetMap-ODbL.txt"
            }),
            "device compatibility archive preserves attribution and license files"
        )
        assert(
            !MapArchiveUploadStrategy.requiresCompatibilityArchive(
                for: compatibilityArchive
            ),
            "sanitized ZIP remains on the resumable background upload path"
        )
        assertEqual(
            try? compatibilityArchive.data(for: compatibilityArchive.manifestEntry!),
            manifest,
            "device compatibility archive preserves the manifest"
        )
        assertEqual(
            try? compatibilityArchive.data(for: compatibilityArchive.mapFileEntries[0]),
            Data("map-block".utf8),
            "device compatibility archive preserves map payloads"
        )
        let compatibilityData = try! Data(contentsOf: compatibilityURL)
        let endRecordOffset = compatibilityData.count - 22
        assertEqual(
            readUInt32LE(compatibilityData, offset: endRecordOffset),
            0x0605_4B50,
            "device compatibility archive writes a ZIP end record"
        )
        assertEqual(
            readUInt16LE(compatibilityData, offset: endRecordOffset + 10),
            UInt16(compatibilityArchive.entries.count),
            "device compatibility archive indexes every retained entry"
        )
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", compatibilityURL.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try! unzip.run()
        unzip.waitUntilExit()
        assertEqual(
            unzip.terminationStatus,
            0,
            "device compatibility archive is structurally valid ZIP"
        )
        assertEqual(
            OfflineMapPackPreviewReader.imageData(fromManifestData: manifest),
            preview,
            "stream manifests expose their inline signed boundary preview"
        )
        var stream = Data("BIKEMAP1".utf8)
        func appendUInt16LE(_ value: UInt16) {
            stream.append(UInt8(value & 0xff))
            stream.append(UInt8(value >> 8))
        }
        func appendUInt32LE(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                stream.append(UInt8((value >> UInt32(shift)) & 0xff))
            }
        }
        func appendUInt64LE(_ value: UInt64) {
            for shift in stride(from: 0, through: 56, by: 8) {
                stream.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }
        appendUInt16LE(1)
        appendUInt16LE(0)
        appendUInt32LE(UInt32(manifest.count))
        appendUInt16LE(5)
        appendUInt16LE(0)
        appendUInt32LE(1)
        appendUInt64LE(1)
        stream.append(manifest)
        stream.append(Data(repeating: 0, count: 5))
        stream.append(0)
        let streamURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-preview-\(UUID().uuidString).bmap")
        try? stream.write(to: streamURL)
        defer { try? FileManager.default.removeItem(at: streamURL) }
        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: streamURL),
            preview,
            "cached signed streams expose their inline boundary preview"
        )

        var corruptPreview = previewMetadata
        corruptPreview["width"] = "wide"
        let corruptManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": "map-1",
            "preview": corruptPreview,
        ])
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-corrupt-preview-\(UUID().uuidString).zip")
        try? makeStoredZip(entries: [
            ("manifest.json", corruptManifest),
            ("preview.png", Data("not-a-png".utf8)),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        guard let archive = try? OfflineMapPackArchive(url: corruptURL),
              let decodedManifest = try? archive.manifest() else {
            assert(false, "a corrupt optional preview must not invalidate the map archive")
            return
        }
        assertEqual(decodedManifest.preview, nil, "malformed preview metadata is ignored")
        assertEqual(archive.mapFileEntries.count, 1, "map transfer entries remain available")
        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: corruptURL),
            nil,
            "corrupt previews fall back without throwing"
        )
    }

    @MainActor
    static func testOfflineMapPreviewLoadRegistry() {
        let registry = OfflineMapPreviewLoadRegistry()
        let key = "/maps/shanghai.zip"
        let stale = registry.begin(for: key)
        registry.invalidate(key)
        let current = registry.begin(for: key)

        assert(
            !registry.finishIfCurrent(stale, for: key),
            "a stale preview completion cannot retire its replacement load"
        )
        assert(
            registry.finishIfCurrent(current, for: key),
            "the replacement preview load remains current and publishable"
        )
        let invalidated = registry.begin(for: key)
        registry.removeAll()
        assert(
            !registry.finishIfCurrent(invalidated, for: key),
            "cache reset invalidates every outstanding preview load"
        )
    }

    static func testOfflineMapCompatibilityArchiveCancellation() async {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-compat-cancel-\(UUID().uuidString).zip")
        let mapPath = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        try? makeStoredZip(entries: [
            ("manifest.json", Data("{\"mapId\":\"map-1\"}".utf8)),
            ("preview.png", Data("preview".utf8)),
            (mapPath, Data(repeating: 0x5a, count: 2 * 1_048_576)),
        ]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let archive = try? OfflineMapPackArchive(url: sourceURL) else {
            assert(false, "compatibility cancellation archive should parse")
            return
        }
        func temporaryCompatibilityPaths() -> Set<String> {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            return Set(files.filter {
                $0.lastPathComponent.hasPrefix("bike-map-device-") &&
                    $0.pathExtension.lowercased() == "zip"
            }.map { $0.standardizedFileURL.path })
        }

        let pathsBefore = temporaryCompatibilityPaths()
        let gate = AsyncTestGate()
        let preparation = Task.detached {
            await gate.wait()
            return try OfflineMapPackCompatibilityArchive.make(from: archive)
        }
        preparation.cancel()
        await gate.open()
        do {
            let unexpectedURL = try await preparation.value
            OfflineMapPackCompatibilityArchive.remove(unexpectedURL)
            assert(false, "cancelled compatibility preparation should not publish a ZIP")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled compatibility preparation should throw CancellationError")
        }
        assertEqual(
            temporaryCompatibilityPaths(),
            pathsBefore,
            "cancelled compatibility preparation removes its registered partial ZIP"
        )
    }

    static func testOfflineMapArchiveValidationCancellation() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-cancel-test-\(UUID().uuidString).zip")
        let path = "VECTMAP/map-1/+0032+0008/123_456.fmb"
        let block = Data(repeating: 0x5a, count: 2 * 1_048_576)
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "mapId": "map-1",
            "files": [[
                "path": path,
                "bytes": block.count,
                "sha256": FirmwareUpdateManager.sha256Hex(block),
            ]],
        ])
        try? makeStoredZip(entries: [
            ("manifest.json", manifest),
            (path, block),
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "cancellation test archive should parse")
            return
        }
        let validation = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            try archive.validate(expectedMapId: "map-1")
        }
        validation.cancel()
        do {
            try await validation.value
            assert(false, "cancelled archive validation should not publish a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            assert(false, "cancelled archive validation should throw CancellationError")
        }
    }

    @MainActor
    static func testCachedMapInstalledIdentityUsesManifestSession() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-1.zip")
        let newManifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\",\"revision\":2}".utf8)
        let oldManifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\",\"revision\":1}".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", newManifest),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8))
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let suite = "cached-map-identity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = OfflineMapManager(defaults: defaults)
        let oldSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: oldManifest
        )
        let newSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: newManifest
        )

        assert(
            !manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: oldSession
            ),
            "a regenerated same-ID cached pack is not marked installed for the old session"
        )
        assert(
            manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: newSession
            ),
            "the exact cached manifest session is marked installed"
        )
        assert(
            !manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: ""
            ),
            "legacy firmware cannot hide upload for a regenerated same-area pack"
        )

        let streamURL = url.deletingPathExtension().appendingPathExtension("bmap")
        try? Data([0x01]).write(to: streamURL)
        defer {
            try? FileManager.default.removeItem(at: streamURL)
            try? SavedMapArtifactMetadataStore.delete(for: streamURL)
        }
        let signedReceipt = String(repeating: "a", count: 64)
        let legacyFallbackSession = "map-1-legacy-session"
        let streamArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "map-1.bmap",
            objectKey: "maps/map-1/bike-map-stream-v1/key/\(signedReceipt).bmap",
            bytes: 1,
            sha256: String(repeating: "b", count: 64),
            manifestReceipt: String(repeating: "c", count: 64),
            signedManifestReceipt: signedReceipt,
            signatureKeyId: "key",
            signatureKeySha256: String(repeating: "d", count: 64),
            producerBuildSha256: String(repeating: "1", count: 64),
            requiredIosBuild: nil,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        try? SavedMapArtifactMetadataStore.save(
            SavedMapArtifactMetadata(
                schemaVersion: 1,
                mapID: "map-1",
                displayName: "Map 1",
                localArtifactFilename: streamURL.lastPathComponent,
                streamFormatVersion: 1,
                jobID: "job-1",
                serverURLString: "https://maps.example",
                clientInstallationID: "installation",
                primaryArtifact: streamArtifact,
                legacyArtifact: nil,
                lastTransferProtocol: 1,
                lastTransferStreamFormat: nil,
                lastTransferSessionID: legacyFallbackSession,
                lastBackgroundTaskID: nil,
                lastDeviceSequence: nil,
                lastDeviceState: "installed",
                lastDeviceStep: 3,
                lastDeviceStepCount: 3,
                lastDeviceProgress: 100,
                expectedActiveMapID: "map-1",
                expectedActiveSessionID: legacyFallbackSession,
                lastTransferOutcome: "installed"
            ),
            for: streamURL
        )
        assert(
            manager.isCachedPackInstalled(
                streamURL,
                activeMapId: "map-1",
                activeSessionId: legacyFallbackSession
            ),
            "a canonical stream map installed through v1 recognizes its legacy session"
        )
        assert(
            manager.isCachedPackInstalled(
                streamURL,
                activeMapId: "map-1",
                activeSessionId: signedReceipt
            ),
            "the same canonical stream map still recognizes a later v2 install"
        )
    }

    static func testOfflineMapManifestDecoding() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-map-manifest-test-\(UUID().uuidString).zip")
        let manifest = Data("""
        {
          "schemaVersion": 1,
          "displayName": "custom-map",
          "source": {
            "region": "geofabrik-asia-malaysia-singapore-brunei",
            "url": "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf"
          }
        }
        """.utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8))
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let archive = try? OfflineMapPackArchive(url: url),
              let decoded = try? archive.manifest() else {
            assert(false, "stored zip manifest should decode")
            return
        }

        assertEqual(decoded.displayName, "custom-map", "manifest exposes display name")
        assertEqual(decoded.source?.region, "geofabrik-asia-malaysia-singapore-brunei", "manifest exposes source region")
        assertEqual(decoded.source?.url, "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf", "manifest exposes source URL")
    }

    static func testMapTransferUploadURLEncodesPlusPathComponents() {
        let baseURL = URL(string: "http://192.168.4.20:8080")!
        let url = MapTransferDeviceClient.uploadURL(
            baseURL: baseURL,
            sessionId: "session-1",
            relativePath: "VECTMAP/map-1/+0032+0008/123_456.fmb"
        )

        assertEqual(
            url.absoluteString,
            "http://192.168.4.20:8080/map-transfer/sessions/session-1/VECTMAP/map-1/%2B0032%2B0008/123_456.fmb",
            "upload URL percent-encodes plus signs so firmware does not decode them as spaces"
        )
        let archiveRequest = MapTransferDeviceClient.archiveUploadRequest(
            baseURL: baseURL,
            sessionId: "session-1",
            sessionToken: "transfer-secret"
        )
        assertEqual(
            archiveRequest.url?.absoluteString,
            "http://192.168.4.20:8080/map-transfer/sessions/session-1/pack.zip",
            "background map transfer uploads one archive to the session endpoint"
        )
        assertEqual(archiveRequest.httpMethod, "PUT", "archive transfer uses PUT")
        assertEqual(
            archiveRequest.value(forHTTPHeaderField: "X-BikeComputer-Transfer-Token"),
            "transfer-secret",
            "archive transfer carries the BLE-issued session token"
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(400, "unknown path")
            ),
            "older firmware falls back to foreground per-file transfer"
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(413, "archive too large")
            ),
            "oversized archives fall back to the supported per-file protocol"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: OfflineMapPlatformError.serverStatus(500, "write failed")
            ),
            "device failures are not disguised as compatibility fallback"
        )
        let outOfSpace = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )
        assert(
            MapArchiveUploadFallback.shouldUseForeground(
                for: outOfSpace,
                allowLocalStorageFailure: true
            ),
            "compatibility staging falls back when local storage is exhausted"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: outOfSpace
            ),
            "ordinary archive failures do not broaden the compatibility fallback"
        )
        assert(
            !MapArchiveUploadFallback.shouldUseForeground(
                for: CancellationError(),
                allowLocalStorageFailure: true
            ),
            "cancellation never becomes an implicit foreground transfer"
        )
    }

    static func testMapTransferOutcomePolicy() {
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: CancellationError(),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "cancelling after activation starts remains reconcilable"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: CancellationError(),
                activationMayBeInFlight: false
            ),
            "failed",
            "cancelling before activation does not claim a device-side attempt"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: URLError(.networkConnectionLost),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "an interrupted stream remains resumable and reconcilable"
        )
        assertEqual(
            MapTransferOutcomePolicy.outcome(
                after: OfflineMapPlatformError.serverStatus(408, "stream_paused"),
                activationMayBeInFlight: true
            ),
            "unconfirmed",
            "device checkpoint timeout remains resumable"
        )
    }

    static func testCachedPackRecoveryDecision() {
        assertEqual(
            CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new",
                activeSessionId: "session-new",
                activationStatus: "idle",
                activationSessionId: ""
            ),
            .installed,
            "exact active session completes recovered installation"
        )
        assertEqual(
            CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new",
                activeSessionId: "session-old",
                activationStatus: "activating",
                activationSessionId: "session-new"
            ),
            .pending,
            "matching device activation blocks a redundant archive upload"
        )
        assertEqual(
            CachedPackRecoveryDecision.evaluate(
                expectedSessionId: "session-new",
                activeSessionId: "session-old",
                activationStatus: "failed",
                activationSessionId: "session-new"
            ),
            .absent,
            "failed activation remains eligible for an explicit retry"
        )
    }

    @MainActor
    static func testMapTransferUploadResumeContract() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-upload-resume-\(UUID().uuidString).zip")
        let manifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\"}".utf8)
        let firstBlock = Data("first-block".utf8)
        let secondBlock = Data("second-block".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("preview.png", Data("preview-only-local".utf8)),
            ("VECTMAP/map-1/+0032+0008/001_001.fmb", firstBlock),
            ("VECTMAP/map-1/+0032+0008/002_002.fmb", secondBlock)
        ])
        try? zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let archive = try? OfflineMapPackArchive(url: url) else {
            assert(false, "resume test archive should parse")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        var headPaths: [String] = []
        var manifestHeadAttempts = 0
        var putBodies: [String: Data] = [:]
        FirmwareRequestCaptureProtocol.handler = { request, body in
            let path = request.url!.path
            let method = request.httpMethod ?? ""
            let status: Int
            var headers: [String: String] = [:]
            if method == "HEAD" {
                headPaths.append(path)
                if path.hasSuffix("manifest.json") {
                    manifestHeadAttempts += 1
                    if manifestHeadAttempts == 1 {
                        throw URLError(.timedOut)
                    } else if manifestHeadAttempts == 2 {
                        status = 503
                    } else {
                        status = 200
                        headers["Content-Length"] = String(manifest.count)
                    }
                } else if path.hasSuffix("001_001.fmb") {
                    status = 200
                    headers["Content-Length"] = String(firstBlock.count)
                } else {
                    status = 404
                }
            } else if method == "PUT" {
                status = 200
                putBodies[path] = body
            } else {
                status = 405
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                Data()
            )
        }

        var progress: [(String, Bool)] = []
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session,
            recoveryRetryNanoseconds: 1_000_000
        )
        await runMainActorAsyncTest {
            try await client.upload(
                archive: archive,
                sessionId: "session-1"
            ) { _, _, path, didUpload in
                progress.append((path, didUpload))
            }
        }

        assertEqual(manifestHeadAttempts, 3,
                    "resume waits through timeout and busy recovery responses")
        assertEqual(headPaths.count, 5, "resume checks every declared upload entry")
        assert(
            !headPaths.contains(where: { $0.hasSuffix("preview.png") }),
            "foreground compatibility transfer never stages preview.png on older firmware"
        )
        assertEqual(progress.map { $0.1 }, [false, false, true],
                    "verified entries are skipped while a missing receipt is reuploaded")
        assertEqual(putBodies.count, 1, "resume uploads only the unverified file")
        let uploaded = putBodies.first
        assert(uploaded?.key.hasSuffix("002_002.fmb") == true,
               "resume retries the file whose HEAD check returned missing")
        assertEqual(uploaded?.value, secondBlock,
                    "resume PUT sends the exact archive entry bytes")

        var blindTimeoutAttempts = 0
        FirmwareRequestCaptureProtocol.handler = { _, _ in
            blindTimeoutAttempts += 1
            throw URLError(.timedOut)
        }
        await runMainActorAsyncTest {
            do {
                try await client.upload(
                    archive: archive,
                    sessionId: "session-1"
                ) { _, _, _, _ in }
                assert(false, "an ordinary Wi-Fi outage should not enter the long recovery wait")
            } catch let error as URLError {
                assertEqual(error.code, .timedOut,
                            "blind manifest timeout surfaces the transport error")
            }
        }
        assertEqual(blindTimeoutAttempts, 3,
                    "blind recovery retries are bounded without an explicit device signal")
    }

    @MainActor
    static func testMapTransferActivationAcknowledgementSequence() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 202, httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data("{\"ok\":true,\"sessionId\":\"session-1\",\"sequence\":9}".utf8)
            )
        }
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session
        )
        var acceptedSequence: UInt32?
        await runMainActorAsyncTest {
            acceptedSequence = try await client.activate(sessionId: "session-1")
        }
        assertEqual(acceptedSequence, 9,
                    "activation acknowledgement exposes the queued attempt sequence")
    }

    static func testMapTransferSessionIdentityUsesManifestContent() {
        let first = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-one".utf8)
        )
        let firstRetry = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-one".utf8)
        )
        let regenerated = MapTransferSessionIdentity.make(
            mapId: "custom-map-shanghai",
            manifestData: Data("manifest-two".utf8)
        )

        assertEqual(first, firstRetry, "the same pack resumes the same staged session")
        assert(first != regenerated, "regenerated same-ID packs use distinct staged sessions")
        assert(first.count <= 80, "content-derived session id fits the firmware contract")
    }

    static func testMapActivationReconciliationMatrix() {
        func evaluate(previousMapId: String? = "map-1",
                      previousSessionId: String? = "session-1",
                      previousSequence: UInt32? = 7,
                      acceptedSequence: UInt32? = nil,
                      observedCurrentAttempt: Bool = false,
                      activeMapId: String? = "map-1",
                      activeSessionId: String? = nil,
                      activationStatus: String? = "installed",
                      activationSequence: UInt32? = 7,
                      activationSessionId: String? = "session-1",
                      activationMapId: String? = "map-1",
                      activationError: String? = nil) -> MapActivationEvaluation {
            MapActivationReconciler.evaluate(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: previousMapId,
                previousSessionId: previousSessionId,
                previousSequence: previousSequence,
                acceptedSequence: acceptedSequence,
                observedCurrentAttempt: observedCurrentAttempt,
                activeMapId: activeMapId,
                activeSessionId: activeSessionId,
                activationStatus: activationStatus,
                activationSequence: activationSequence,
                activationSessionId: activationSessionId,
                activationMapId: activationMapId,
                activationError: activationError
            )
        }

        assertEqual(
            evaluate().decision,
            .pending("installed"),
            "same-ID reinstall rejects a retained installed activation"
        )
        assertEqual(
            evaluate(activationSequence: 8).decision,
            .installed,
            "a newer activation sequence proves same-ID installation"
        )
        assertEqual(
            evaluate(
                previousSequence: nil,
                acceptedSequence: 8,
                activationSequence: 8
            ).decision,
            .installed,
            "the acknowledged activation sequence proves a fast same-session completion"
        )
        assertEqual(
            evaluate(
                previousSessionId: "old-session",
                previousSequence: nil,
                activeSessionId: "session-1"
            ).decision,
            .installed,
            "an exact active-session transition proves a fast same-ID installation"
        )
        assertEqual(
            evaluate(
                previousMapId: nil,
                previousSessionId: nil,
                previousSequence: nil,
                activeSessionId: "session-1"
            ).decision,
            .installed,
            "an exact active session proves a fast first installation"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .installed,
            "the durable active session proves an exact same-ID pack after restart"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "activating"
            ).decision,
            .pending("activating"),
            "an old exact-session root does not complete an in-progress same-session repair"
        )
        assertEqual(
            evaluate(
                activeSessionId: "session-1",
                activationStatus: "failed"
            ).decision,
            .pending("failed"),
            "an unobserved matching failure is not hidden by an old exact-session root"
        )
        assertEqual(
            evaluate(activeSessionId: "session-1").decision,
            .pending("installed"),
            "a cached terminal state cannot complete a same-session retry"
        )
        assertEqual(
            evaluate(
                previousMapId: "old-map",
                activeMapId: "map-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .installed,
            "a changed active map proves installation on legacy firmware"
        )
        assertEqual(
            evaluate(
                activationStatus: "failed",
                activationSequence: 8,
                activationError: "file_sha256"
            ).decision,
            .failed("file_sha256"),
            "matching failed activation surfaces the device error"
        )
        assertEqual(
            evaluate(
                activationSequence: 8,
                activationMapId: "wrong-map"
            ).decision,
            .failed("device activated wrong-map instead of map-1"),
            "matching session rejects a different activated map"
        )
        let inProgress = evaluate(
            activeMapId: nil,
            activationStatus: "activating",
            activationSequence: nil
        )
        assert(inProgress.observedCurrentAttempt, "observing activating proves a response-lost request reached legacy firmware")
        assertEqual(
            evaluate(
                observedCurrentAttempt: inProgress.observedCurrentAttempt,
                activationSequence: nil
            ).decision,
            .installed,
            "legacy firmware installs after an observed activating transition"
        )
        assertEqual(
            evaluate(
                previousMapId: nil,
                activeMapId: "map-1",
                activationStatus: "idle",
                activationSessionId: nil,
                activationMapId: nil
            ).decision,
            .pending("active map is map-1; waiting for current activation"),
            "an unknown baseline is not proof that a same-ID activation ran"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.timedOut)),
            "activation request timeout enters reconciliation"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.networkConnectionLost)),
            "lost activation response enters reconciliation"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.cannotConnectToHost)),
            "automatic activation may close device HTTP before the redundant POST connects"
        )
        assert(
            MapActivationTransport.isAmbiguousResponseError(URLError(.notConnectedToInternet)),
            "accessory AP shutdown proceeds to BLE activation reconciliation"
        )
    }

    @MainActor
    static func testMapActivationConfirmationOrchestration() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }
        let defaults = UserDefaults(suiteName: "map-confirmation-\(UUID().uuidString)")!
        let manager = OfflineMapManager(defaults: defaults)
        let bleManager = BLEManager()
        let client = MapTransferDeviceClient(
            baseURL: URL(string: "http://192.168.4.20:8080")!,
            session: session
        )

        var statusRequests = 0
        FirmwareRequestCaptureProtocol.handler = { _, _ in
            statusRequests += 1
            throw URLError(.timedOut)
        }
        bleManager.mapTransferActiveMapId = "map-1"
        bleManager.mapTransferActivationStatus = "installed"
        bleManager.mapTransferActivationSequence = 8
        bleManager.mapTransferActivationSessionId = "session-1"
        var confirmation: MapActivationConfirmationResult?
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "old-session",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.2,
                pollIntervalNanoseconds: 1_000_000
            )
        }
        assertEqual(confirmation, .installed, "BLE fallback confirms installation")
        assertEqual(statusRequests, 1, "HTTP status failure falls back to BLE")

        statusRequests = 0
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            statusRequests += 1
            let state = statusRequests == 1 ? "activating" : "installed"
            let body = Data("""
            {"activeMapId":"map-1","activation":{"status":"\(state)","sequence":8,"sessionId":"session-1","mapId":"map-1"}}
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        confirmation = nil
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "old-session",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.2,
                pollIntervalNanoseconds: 1_000_000
            )
        }
        assertEqual(confirmation, .installed, "HTTP polling confirms installation")
        assertEqual(statusRequests, 2,
                    "confirmation polls from activating through installed")

        statusRequests = 0
        FirmwareRequestCaptureProtocol.handler = { request, _ in
            statusRequests += 1
            let body = Data("""
            {"activeMapId":"map-1","activation":{"status":"installed","sequence":7,"sessionId":"session-1","mapId":"map-1"}}
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        confirmation = nil
        await runMainActorAsyncTest {
            confirmation = try await manager.confirmActivatedMap(
                expectedMapId: "map-1",
                sessionId: "session-1",
                previousMapId: "map-1",
                previousSessionId: "session-1",
                previousSequence: 7,
                acceptedSequence: nil,
                client: client,
                bleManager: bleManager,
                timeout: 0.02,
                pollIntervalNanoseconds: 1_000_000
            )
        }
        guard let confirmation,
              case .continuesOnDevice = confirmation else {
            assert(false, "retained activation should continue on device without an error")
            return
        }
        assertEqual(manager.statusMessage.hasPrefix("activating map-1"), true,
                    "pending confirmation retains activation status")
        assert(statusRequests > 1, "confirmation limit covers repeated pending polls")
    }

    static func testMapTransferDeviceStatusDecodesActivationFailure() {
        let body = Data("""
        {
          "enabled": true,
          "activeMapId": "old-map",
          "activeSessionId": "old-map-session",
          "activation": {
            "status": "failed",
            "sequence": 9,
            "sessionId": "new-map",
            "mapId": "new-map",
            "error": {
              "code": "file_sha256",
              "message": "sha mismatch for VECTMAP/new-map/1.fmb"
            }
          }
        }
        """.utf8)

        guard let status = try? JSONDecoder().decode(MapTransferDeviceStatus.self, from: body) else {
            assert(false, "device transfer status should decode activation failure")
            return
        }

        assertEqual(status.enabled, true, "status exposes transfer mode")
        assertEqual(status.activeMapId, "old-map", "status exposes active map id")
        assertEqual(status.activation?.status, "failed", "status exposes activation state")
        assertEqual(status.activation?.sequence, 9, "status exposes activation sequence")
        assertEqual(status.activation?.error?.code, "file_sha256", "status exposes activation error code")
        assertEqual(status.activation?.error?.message, "sha mismatch for VECTMAP/new-map/1.fmb", "status exposes activation error message")
        assertEqual(status.activeSessionId, "old-map-session", "status exposes durable active session identity")
    }

    static func testFirmwareManifestDecodingAndHash() {
        let body = Data("""
        {
          "schemaVersion": 1,
          "target": "WAVESHARE_AMOLED_175",
          "version": "0.4.0",
          "build": 87,
          "gitSha": "abcdef123456",
          "size": 3,
          "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "url": "https://github.com/seichris/open-bike-computer/releases/download/v0.4.0/WAVESHARE_AMOLED_175.bin",
          "minUpdaterProtocol": 1,
          "signature": "MEUCIQCoFhwd6SnmvltHkUu5jfNQce/pPk87c84AcHt2u9DmDQIgfwklONo1MEyfgfX0VhlTDyi/B+dGZdsvckb/rFEGOM8="
        }
        """.utf8)

        guard let manifest = try? JSONDecoder().decode(FirmwareReleaseManifest.self, from: body) else {
            assert(false, "firmware manifest should decode")
            return
        }

        assertEqual(manifest.target, "WAVESHARE_AMOLED_175", "manifest exposes target")
        assertEqual(manifest.build, 87, "manifest exposes build")
        assert(manifest.isSupportedByApp, "manifest updater protocol is supported")
        assertEqual(FirmwareUpdateManager.sha256Hex(Data("abc".utf8)), manifest.sha256, "firmware hash verification uses SHA-256 hex")
        assert(
            FirmwareManifestSignatureVerifier.verify(
                manifest,
                publicKeyBase64: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
            ),
            "firmware manifest signature verifies over canonical release metadata"
        )

        let tampered = FirmwareReleaseManifest(
            schemaVersion: manifest.schemaVersion,
            target: manifest.target,
            version: manifest.version,
            build: manifest.build + 1,
            gitSha: manifest.gitSha,
            size: manifest.size,
            sha256: manifest.sha256,
            url: manifest.url,
            minUpdaterProtocol: manifest.minUpdaterProtocol,
            signature: manifest.signature
        )
        assert(
            !FirmwareManifestSignatureVerifier.verify(
                tampered,
                publicKeyBase64: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
            ),
            "firmware manifest signature rejects tampered metadata"
        )
    }

    @MainActor
    static func testFirmwareUpdateManagerRestoresPendingStatus() {
        let suiteName = "FirmwareUpdateManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assert(false, "test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pending = PendingFirmwareUpdate(
            target: "WAVESHARE_AMOLED_175",
            version: "0.4.0",
            build: 87,
            gitSha: "abcdef123456",
            startedAt: Date(timeIntervalSince1970: 10),
            status: "device rebooting"
        )
        let data = try? JSONEncoder().encode(pending)
        defaults.set(data, forKey: "firmware.pendingUpdate")

        let manager = FirmwareUpdateManager(defaults: defaults)
        assertEqual(manager.statusMessage,
                    "device rebooting",
                    "firmware manager restores pending reboot status after app relaunch")
    }

    @MainActor
    static func testFirmwareUpdateAvailabilitySemantics() {
        let suiteName = "FirmwareUpdateAvailabilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assert(false, "test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = FirmwareUpdateManager(defaults: defaults)
        let bleManager = BLEManager()
        bleManager.firmwareTarget = "WAVESHARE_AMOLED_206"
        bleManager.firmwareVersion = "0.2.4"
        bleManager.firmwareBuild = 88
        bleManager.firmwareGitSha = "abcdef123456"

        let current = FirmwareReleaseManifest(
            schemaVersion: 1,
            target: "WAVESHARE_AMOLED_206",
            version: "0.2.4",
            build: 88,
            gitSha: "abcdef123456",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            url: URL(string: "https://github.com/seichris/open-bike-computer/releases/download/v0.2.4/WAVESHARE_AMOLED_206.bin")!,
            minUpdaterProtocol: 1,
            signature: "signature"
        )
        manager.allowDeveloperDowngrade = true
        assert(!manager.isUpdateAllowed(current, bleManager: bleManager),
               "exactly installed firmware should not be installable as an update even with developer downgrade enabled")
        assert(!manager.isNewerUpdateAvailable(current, bleManager: bleManager),
               "exactly installed firmware should not show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: current, bleManager: bleManager),
                    "firmware is current",
                    "exactly installed firmware reports current")

        let newer = FirmwareReleaseManifest(
            schemaVersion: current.schemaVersion,
            target: current.target,
            version: "0.2.5",
            build: 89,
            gitSha: "bbbbbb123456",
            size: current.size,
            sha256: current.sha256,
            url: current.url,
            minUpdaterProtocol: current.minUpdaterProtocol,
            signature: current.signature
        )
        assert(manager.isUpdateAllowed(newer, bleManager: bleManager),
               "newer build should be installable")
        assert(manager.isNewerUpdateAvailable(newer, bleManager: bleManager),
               "newer build should show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: newer, bleManager: bleManager),
                    "firmware update available",
                    "newer build reports update available")

        let older = FirmwareReleaseManifest(
            schemaVersion: current.schemaVersion,
            target: current.target,
            version: "0.2.3",
            build: 87,
            gitSha: "aaaaaa123456",
            size: current.size,
            sha256: current.sha256,
            url: current.url,
            minUpdaterProtocol: current.minUpdaterProtocol,
            signature: current.signature
        )
        assert(manager.isUpdateAllowed(older, bleManager: bleManager),
               "older build remains installable behind developer downgrade")
        assert(!manager.isNewerUpdateAvailable(older, bleManager: bleManager),
               "developer downgrade should not show in the main update prompt")
        assertEqual(manager.availabilityMessage(for: older, bleManager: bleManager),
                    "developer firmware install available",
                    "developer downgrade is not labeled as a normal update")
    }

    static func testFirmwareDeviceClientSendsSignedBeginRequest() {
        let manifest = FirmwareReleaseManifest(
            schemaVersion: 1,
            target: "WAVESHARE_AMOLED_175",
            version: "0.4.0",
            build: 87,
            gitSha: "abcdef123456",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            url: URL(string: "https://github.com/seichris/open-bike-computer/releases/download/v0.4.0/WAVESHARE_AMOLED_175.bin")!,
            minUpdaterProtocol: 1,
            signature: "MEUCIQCoFhwd6SnmvltHkUu5jfNQce/pPk87c84AcHt2u9DmDQIgfwklONo1MEyfgfX0VhlTDyi/B+dGZdsvckb/rFEGOM8="
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareRequestCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            FirmwareRequestCaptureProtocol.handler = nil
        }

        FirmwareRequestCaptureProtocol.handler = { request, body in
            assertEqual(request.httpMethod, "POST", "begin request uses POST")
            assertEqual(request.url?.path, "/firmware-update/begin", "begin request uses firmware path")
            assertEqual(request.value(forHTTPHeaderField: "X-BikeComputer-Transfer-Token"), "token-123", "begin request includes transfer token")
            assertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "begin request declares JSON")
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                assert(false, "begin request body should be JSON")
                throw FirmwareUpdateError.invalidManifest
            }
            assertEqual(object["target"] as? String, manifest.target, "begin request sends target")
            assertEqual(object["gitSha"] as? String, manifest.gitSha, "begin request sends git SHA")
            assertEqual(object["manifestSignature"] as? String, manifest.signature, "begin request sends manifest signature")
            assertEqual(object["releaseUrl"] as? String, manifest.url.absoluteString, "begin request sends release URL")
            assertEqual(object["allowDowngrade"] as? Bool, true, "begin request sends developer downgrade flag")

            let data = Data("""
            {
              "status": "receiving",
              "target": "WAVESHARE_AMOLED_175",
              "runningVersion": "0.2.2",
              "runningBuild": 86,
              "runningPartition": "ota_0",
              "inactivePartition": "ota_1",
              "otaState": "valid",
              "maxImageBytes": 3145728,
              "receivedBytes": 0,
              "totalBytes": 3,
              "sha256": null,
              "lastError": null
            }
            """.utf8)
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (response, data)
        }

        runAsyncTest {
            let client = FirmwareUpdateDeviceClient(
                baseURL: URL(string: "http://192.168.4.1:8080")!,
                sessionToken: "token-123",
                session: session
            )
            let status = try await client.begin(manifest: manifest, allowDowngrade: true)
            assertEqual(status.status, "receiving", "begin response decodes firmware status")
            assertEqual(status.totalBytes, 3, "begin response decodes expected byte count")
        }
    }

    static func runAsyncTest(_ operation: @escaping () async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        Task {
            do {
                try await operation()
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            assert(false, "async test failed: \(failure)")
        }
    }

    @MainActor
    static func runMainActorAsyncTest(
        _ operation: @MainActor @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            assert(false, "main-actor async test failed: \(error)")
        }
    }

    static func testNavigationPacketBuilder() {
        let shortPacket = "2|150|Turn left"
        guard let shortData = NavigationPacketBuilder.data(from: shortPacket, maxLength: NavigationPacketBuilder.protocolMaxBytes) else {
            assert(false, "short packet should encode")
            return
        }
        assertEqual(String(data: shortData, encoding: .utf8), shortPacket, "short packet passes unchanged")

        let longInstruction = String(repeating: "直行", count: 80)
        guard let data = NavigationPacketBuilder.data(
            from: "1|4294967295|\(longInstruction)",
            maxLength: NavigationPacketBuilder.protocolMaxBytes
        ) else {
            assert(false, "long UTF-8 packet should truncate")
            return
        }

        assert(data.count <= NavigationPacketBuilder.protocolMaxBytes, "truncated packet respects byte limit")
        let packet = String(data: data, encoding: .utf8)
        assert(packet?.hasPrefix("1|4294967295|") == true, "truncated packet keeps prefix")
        assert(packet?.contains("\u{FFFD}") == false, "truncated packet remains valid UTF-8")
        let instruction = packet?.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).last
        assert(instruction?.data(using: .utf8)?.count ?? Int.max <= NavigationPacketBuilder.instructionMaxBytes, "instruction respects firmware byte limit")

        assert(NavigationPacketBuilder.data(from: "not-a-packet", maxLength: 8) == nil, "malformed packets fail when truncation is needed")
        assert(NavigationPacketBuilder.data(from: "1|4294967295|Turn", maxLength: 4) == nil, "oversized prefix fails")
        let fallbackData = NavigationPacketBuilder.data(from: "1|100|", maxLength: NavigationPacketBuilder.protocolMaxBytes)
        assertEqual(String(data: fallbackData ?? Data(), encoding: .utf8), "1|100|Continue", "empty instruction falls back to continue")
    }

    static func testNavigationWriteQueue() {
        var queue = NavigationWriteQueue(maxCount: 2)
        queue.enqueue(NavigationWrite(data: Data([1]), label: "first"))
        queue.enqueue(NavigationWrite(data: Data([2]), label: "second"))
        assertEqual(queue.count, 2, "queue stores pending writes")

        let didDrop = queue.enqueue(NavigationWrite(data: Data([3]), label: "third"))
        assert(didDrop, "queue reports overflow")
        assertEqual(queue.count, 2, "queue caps pending writes")

        var sent: [Data] = []
        var labels: [String] = []
        queue.flush(canSend: { sent.count < 1 }) {
            sent.append($0.data)
            labels.append($0.label)
        }
        assertEqual(sent, [Data([2])], "queue drops oldest packet first")
        assertEqual(labels, ["second"], "queue preserves write metadata")
        assertEqual(queue.count, 1, "queue retains unsent packet under backpressure")

        queue.flush(canSend: { true }) {
            sent.append($0.data)
            labels.append($0.label)
        }
        assertEqual(sent, [Data([2]), Data([3])], "queue flushes remaining packet")
        assertEqual(labels, ["second", "third"], "queue flushes write metadata in order")
        assertEqual(queue.count, 0, "queue is empty after flush")

        var pacedQueue = NavigationWriteQueue(maxCount: 3)
        pacedQueue.enqueue(NavigationWrite(data: Data([1]), label: "first"))
        pacedQueue.enqueue(NavigationWrite(data: Data([2]), label: "second"))
        var pacedWrites: [Data] = []
        pacedQueue.flush(canSend: { true }, maxWrites: 1) {
            pacedWrites.append($0.data)
        }
        assertEqual(pacedWrites, [Data([1])],
                    "paced flush sends only the configured batch size")
        assertEqual(pacedQueue.count, 1,
                    "paced flush retains later writes for the next transport tick")

        var reconnectQueue = NavigationWriteQueue(
            maxCount: DeviceBLEProtocol.fallbackWriteQueueCapacity
        )
        for index in 0..<30 {
            assert(!reconnectQueue.enqueue(NavigationWrite(
                data: Data([UInt8(index)]),
                label: "reconnect-\(index)"
            )), "bounded automatic reconnect traffic must not evict persisted settings")
        }
        var reconnectWrites: [NavigationWrite] = []
        reconnectQueue.flush(canSend: { true }) { reconnectWrites.append($0) }
        assertEqual(reconnectWrites.count, 30,
                    "fallback queue retains the complete automatic reconnect burst")
        assertEqual(reconnectWrites.first?.label, "reconnect-0",
                    "fallback queue preserves the oldest reconnect setting")

        var didNotifyDrop = false
        var trackedQueue = NavigationWriteQueue(maxCount: 1)
        trackedQueue.enqueue(NavigationWrite(
            data: Data([1]),
            label: "tracked",
            onDrop: { didNotifyDrop = true }
        ))
        assert(trackedQueue.enqueue(NavigationWrite(data: Data([2]), label: "replacement")),
               "overflow reports that the oldest write was dropped")
        assert(didNotifyDrop, "tracked writes are notified when queue overflow evicts them")

        var targetedWrites: [Data] = []
        var fallbackWrites: [Data] = []
        let targetedWrite = NavigationWrite(
            data: Data([3]),
            label: "targeted",
            transportWrite: { targetedWrites.append($0) }
        )
        targetedWrite.perform { fallbackWrites.append($0) }
        assertEqual(targetedWrites, [Data([3])],
                    "targeted writes use their native characteristic transport")
        assertEqual(fallbackWrites.count, 0,
                    "targeted writes do not leak onto the fallback characteristic")
    }

    static func testDeviceBLEProtocolConstants() {
        assertEqual(DeviceBLEProtocol.serviceUUIDString, "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800", "service UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.navigationCharacteristicUUIDString, "2A6E", "navigation characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.routeGeometryCharacteristicUUIDString, "2A6F", "route characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.gpsPositionCharacteristicUUIDString, "2A72", "GPS characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.settingsCharacteristicUUIDString, "2A73", "settings characteristic UUID must stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.routeGeometryFallbackPrefix, "MAPR", "route fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.gpsPositionFallbackPrefix, "GPSP", "GPS fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.settingsFallbackPrefix, "MSET", "settings fallback remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.mapTransferControlPrefix, "MTRN", "map transfer control remains framed over navigation writes")
        assertEqual(DeviceBLEProtocol.mapTransferStatusPrefix, "MSTS", "map transfer status remains framed over navigation notifications")
        assertEqual(DeviceBLEProtocol.mapTransferStatusChunkPrefix, "MSTC", "chunked map transfer status remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceTransferControlPrefix, "DTRN", "generic transfer control remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceTransferStatusPrefix, "DSTS", "generic transfer status remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.soundPlayPrefix, "SNDP", "sound playback remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.powerButtonHonkPrefix, "SNDH", "PWR honk configuration remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.powerButtonHonkStatusPrefix, "SNHA", "PWR honk acknowledgement remains firmware-compatible")
        assertEqual(DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask, 4, "PWR honk acknowledgement uses capability bit 2")
        assertEqual(DeviceBLEProtocol.independentMapProfilesCapabilityMask, 8, "independent map profiles use capability bit 3")
        assertEqual(DeviceBLEProtocol.extendedMapVisibilityCapabilityMask, 16, "extended map visibility uses capability bit 4")
        assertEqual(DeviceBLEProtocol.batteryStatusScreenCapabilityMask, 32, "Battery Status support uses capability bit 5")
        assertEqual(DeviceBLEProtocol.deviceCapabilitiesVersion, 4, "capability version advertises Battery Status screen support")
        assertEqual(DeviceBLEProtocol.serviceRoadsVisibilityMask, 0x400, "service roads use visibility bit 10")
        assertEqual(DeviceBLEProtocol.tracksVisibilityMask, 0x800, "tracks use visibility bit 11")
        assertEqual(DeviceBLEProtocol.extendedVisibilityMarker, 0x1000, "extended visibility uses marker bit 12")
        assertEqual(DeviceBLEProtocol.brightnessSettingID, 12, "brightness uses firmware setting ID 12")
        assertEqual(DeviceBLEProtocol.enabledScreensSettingID, 13, "enabled screens use firmware setting ID 13")
        assertEqual(DeviceBLEProtocol.defaultScreenSettingID, 14, "default screen uses firmware setting ID 14")
        assertEqual(DeviceBLEProtocol.disconnectedSleepTimeoutSettingID, 15, "disconnected sleep timeout uses firmware setting ID 15")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID, 16, "Map + Navigation polygon size uses setting ID 16")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID, 17, "Map + Navigation detail uses setting ID 17")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID, 18, "Map + Navigation route width uses setting ID 18")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID, 19, "Map + Navigation zoom uses setting ID 19")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID, 20, "Map + Navigation visibility uses setting ID 20")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationStreetLineWidthBoostSettingID, 21, "Map + Navigation street width uses setting ID 21")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID, 22, "Map + Navigation marker scale uses setting ID 22")
        assertEqual(DeviceBLEProtocol.phoneBatteryLevelSettingID, 23, "phone battery level uses firmware setting ID 23")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingSettingID, 24, "phone charging state uses firmware setting ID 24")
        assertEqual(DeviceBLEProtocol.currentScreenMaskMarker, 1 << 30, "current screen masks use bit 30 as a compatibility marker")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: -1), nil, "unavailable iPhone battery levels stay unknown")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 0), 0, "empty iPhone battery maps to zero percent")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 0.735), 74, "iPhone battery levels round to whole percentages")
        assertEqual(DeviceBLEProtocol.phoneBatteryPercentage(from: 1), 100, "full iPhone battery maps to 100 percent")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingValue(isCharging: false), 0, "unplugged iPhones send not charging")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingValue(isCharging: true), 1, "charging iPhones send charging")
        assertEqual(DeviceScreen.map.rawValue, 0, "Map screen protocol value stays stable")
        assertEqual(DeviceScreen.navigation.rawValue, 1, "Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.rideStats.rawValue, 2, "Ride Stats screen protocol value stays stable")
        assertEqual(DeviceScreen.mapPlusNavigation.rawValue, 3, "Map + Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.batteryStatus.rawValue, 4, "Battery Status screen uses protocol value 4")
        assertEqual(DeviceScreen.mapPlusNavigation.title, "Map + Navigation", "combined map/navigation screen keeps user-facing label")
        assertEqual(DeviceScreen.batteryStatus.title, "Battery Status", "battery screen has a user-facing label")
        assertEqual(DeviceScreen.displayOrder,
                    [.mapPlusNavigation, .rideStats, .map, .navigation, .batteryStatus],
                    "Battery Status is the last device screen in settings and cycling order")
        assertEqual(DeviceScreen.allScreensMask, 0x1F, "all supported device screens use the low five mask bits")
        assertEqual(DeviceScreen.legacyScreensMask, 0x0F, "legacy firmware receives only the original four screen bits")
        assertEqual(DisconnectedSleepTimeout.oneMinute.settingValue, 60, "one-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.twoMinutes.settingValue, 120, "two-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.fiveMinutes.settingValue, 300, "five-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.tenMinutes.settingValue, 600, "ten-minute sleep timeout sends seconds")
        assertEqual(DisconnectedSleepTimeout.never.settingValue, 0, "never sleep sends zero seconds")
        assertEqual(DisconnectedSleepTimeout.normalized(rawValue: 999), .twoMinutes, "unknown sleep timeout falls back to two minutes")
    }

    static func testDeviceScreenValidation() {
        assertEqual(DeviceScreen.normalizedMask(0), DeviceScreen.allScreensMask, "zero screen mask falls back to all screens")
        assertEqual(DeviceScreen.normalizedMask(0xFF), DeviceScreen.allScreensMask, "unknown screen mask bits are ignored")
        assertEqual(DeviceScreen.normalizedMask(DeviceScreen.batteryStatus.bit,
                                                supportedMask: DeviceScreen.legacyScreensMask),
                    DeviceScreen.legacyScreensMask,
                    "a Battery-only mask falls back to all screens supported by legacy firmware")

        let rideStatsOnly = DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.mapPlusNavigation.rawValue, mask: rideStatsOnly),
                    .rideStats,
                    "disabled default falls back to the first enabled non-map screen")

        let mapAndStats = DeviceScreen.map.bit | DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.navigation.rawValue, mask: mapAndStats),
                    .rideStats,
                    "disabled default follows the device screen display order")

        let batteryAndStats = DeviceScreen.batteryStatus.bit | DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.map.rawValue, mask: batteryAndStats),
                    .rideStats,
                    "Battery Status remains last in fallback order")
        assertEqual(DeviceScreen.fallbackDefault(
            for: DeviceScreen.batteryStatus.rawValue,
            mask: DeviceScreen.allScreensMask,
            supportedMask: DeviceScreen.legacyScreensMask
        ), .mapPlusNavigation,
        "legacy firmware never receives Battery Status as its default")
    }

    static func testDeviceSoundProtocol() {
        assertEqual(DeviceSound.allCases.map(\.rawValue), [1, 2, 3, 5], "sound IDs match firmware assets")
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
        assert(!manager.hasReceivedDeviceCapabilities, "malformed CAPS does not complete negotiation")

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
                    Int32(DeviceScreen.allScreensMask) |
                        DeviceBLEProtocol.currentScreenMaskMarker,
                    "current firmware receives a marked five-screen mask")
        assertEqual(currentSettings[DeviceBLEProtocol.defaultScreenSettingID],
                    Int32(DeviceScreen.batteryStatus.rawValue),
                    "current firmware may use Battery Status as its default")

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
                    [20, 16, 17, 18, 21, 22, 19, 8, 1, 2, 3, 9, 10, 7],
                    "new firmware receives the independent profile before legacy Map IDs")
        let independentDetail = independentPackets().first { $0[4] == 17 }
        assertEqual(readInt32LE(independentDetail!, offset: 5), 0,
                    "independent Map + Navigation detail remains distinct")

        let (legacyManager, legacyPackets) = configuredManager()
        let baselineCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) + Data([0])
        assert(legacyManager.handleDeviceCapabilitiesNotification(baselineCapabilities),
               "baseline capability response should be consumed")
        assertEqual(legacyPackets().map { $0[4] }, [8, 1, 2, 3, 9, 10, 7],
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
        assertEqual(latePackets().map { $0[4] }, [8, 1, 2, 3, 9, 10, 7],
                    "timeout fallback sends only the legacy shared profile")
        let lateExtendedFlags = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask |
                  DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(lateManager.handleDeviceCapabilitiesNotification(lateExtendedFlags),
               "late independent profile response should still be consumed")
        assertEqual(Array(latePackets().map { $0[4] }.suffix(14)),
                    [20, 16, 17, 18, 21, 22, 19, 8, 1, 2, 3, 9, 10, 7],
                    "late extended response resends both profiles with new semantics")
        let resentMapVisibility = latePackets().last { $0[4] == 8 }
        assert(readInt32LE(resentMapVisibility!, offset: 5) &
               DeviceBLEProtocol.extendedVisibilityMarker != 0,
               "late extended response repairs the folded Map visibility mask")
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        assertEqual(sentPackets.count, 2,
                    "failed PWR honk acknowledgement retries the configuration")

        let successStatus = powerButtonHonkStatus(for: sentPackets[0], applied: 1)
        assert(manager.handlePowerButtonHonkStatusNotification(successStatus),
               "successful PWR honk acknowledgement should be consumed")
        assert(manager.handlePowerButtonHonkStatusNotification(failedStatus),
               "stale PWR honk acknowledgement should still be consumed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            assertEqual(sentPackets.count, expectedSendCount,
                        "failed acknowledgement advances the bounded retry sequence")
        }
        assert(manager.handlePowerButtonHonkStatusNotification(terminalFailedStatus),
               "terminal failed PWR honk acknowledgement should be consumed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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

        transportReady = true
        assert(waitForMainLoop(timeout: 2) { sentPackets.count == 1 },
               "queued PWR configuration is eventually handed to the transport")
        let recoveredAfterBackpressure = powerButtonHonkStatus(
            for: sentPackets[0],
            applied: 1
        )
        assert(manager.handlePowerButtonHonkStatusNotification(recoveredAfterBackpressure),
               "queued PWR configuration can be acknowledged after transport recovery")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
            maximumWriteLength: 64,
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
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(manager.requestDeviceTransferMode(.firmware), "firmware transfer enter should queue when BLE is ready")
        assert(manager.requestDeviceTransferStatus(), "device transfer status should queue when BLE is ready")
        assert(manager.requestDeviceTransferExit(), "device transfer exit should queue when BLE is ready")

        assertEqual(sentPackets.count, 3, "device transfer control should write three packets")
        assertEqual(String(data: sentPackets[0], encoding: .utf8), "DTRNenter|firmware", "firmware enter command uses DTRN frame")
        assertEqual(String(data: sentPackets[1], encoding: .utf8), "DSTS", "status command uses DSTS frame")
        assertEqual(String(data: sentPackets[2], encoding: .utf8), "DTRNexit", "exit command uses DTRN frame")
    }

    static func testDeviceTransferManagerWaitsForMapToken() async {
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let staleDeviceStatus = """
        {"configured":true,"enabled":true,"port":8080,"mode":"map","baseUrl":"http://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","sessionToken":"stale-map-token","firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(staleDeviceStatus.utf8)
        )
        let staleRevision = bleManager.deviceTransferStatusRevision

        let transferTask = Task {
            try await DeviceTransferManager().enterMapTransfer(
                bleManager: bleManager,
                status: { _ in }
            )
        }

        for _ in 0..<100 where sentPackets.count < 3 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        assertEqual(sentPackets.count, 3,
                    "map transfer handshake requests map and credential status")
        if sentPackets.count == 3 {
            assertEqual(String(data: sentPackets[0], encoding: .utf8), "MTRNenter",
                        "map transfer handshake enables map mode")
            assertEqual(String(data: sentPackets[1], encoding: .utf8), "MSTS",
                        "map transfer handshake requests map status")
            assertEqual(String(data: sentPackets[2], encoding: .utf8), "DSTS",
                        "map transfer handshake requests its HTTP credential")
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
        let deviceStatus = """
        {"configured":true,"enabled":true,"port":8080,"mode":"map","baseUrl":"http://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","sessionToken":"fresh-map-token","firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
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
            assertEqual(session.baseURL.absoluteString, "http://192.168.4.20:8080",
                        "map transfer handshake binds matching status origins")
            assertEqual(session.sessionToken, "fresh-map-token",
                        "map transfer handshake waits for the fresh token")
        } catch {
            assert(false, "map transfer handshake should succeed: \(error)")
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
        {"configured":true,"enabled":true,"port":8080,"baseUrl":"http://192.168.4.20:8080","sdPresent":true,"mapFound":false,"mapBlocks":0,"activeMapId":"kyoto-v1","activeSessionId":"kyoto-v1-session","activation":{"status":"activating","sequence":12,"sessionId":"tokyo-v2","mapId":"tokyo-v2","step":1,"steps":5,"progress":6},"lastError":{"code":"previous","message":"previous upload failed"}}
        """
        let packet = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + Data(json.utf8)

        assert(manager.handleMapTransferStatusNotification(packet), "MSTS notification should be consumed")
        assert(manager.mapTransferModeEnabled, "status parser exposes enabled transfer mode")
        assertEqual(manager.mapTransferBaseURL?.absoluteString, "http://192.168.4.20:8080", "status parser exposes base URL")
        assertEqual(manager.mapTransferActiveMapId, "kyoto-v1", "status parser exposes active map id")
        assertEqual(manager.mapTransferActiveSessionId, "kyoto-v1-session", "status parser exposes active session id")
        assertEqual(manager.mapTransferActivationStatus, "activating", "status parser exposes activation state")
        assertEqual(manager.mapTransferActivationSequence, 12, "status parser exposes activation sequence")
        assertEqual(manager.mapTransferActivationSessionId, "tokyo-v2", "status parser exposes activation session")
        assertEqual(manager.mapTransferActivationMapId, "tokyo-v2", "status parser exposes activating map id")
        assertEqual(manager.mapTransferActivationStep, 1, "status parser exposes activation step")
        assertEqual(manager.mapTransferActivationStepCount, 5, "status parser exposes activation step count")
        assertEqual(manager.mapTransferActivationProgress, 6, "status parser exposes activation percentage")
        assertEqual(manager.deviceHasSDCard, true, "status parser exposes physical SD state")
        assertEqual(manager.deviceMapFoundForCurrentLocation, false, "status parser exposes current map coverage")
        assertEqual(manager.deviceMapBlockCount, 0, "status parser exposes current map block count")
        assertEqual(manager.mapTransferLastError, "previous: previous upload failed", "status parser exposes last transfer error")
    }

    static func testBLEManagerReassemblesChunkedMapTransferStatus() {
        let manager = BLEManager()
        let body = Data("""
        {"enabled":true,"baseUrl":"http://192.168.4.20:8080","activeMapId":"custom-map","activeSessionId":"custom-map-session","activation":{"status":"installed","sequence":9,"sessionId":"custom-map-session"}}
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
        assertEqual(manager.mapTransferActivationStatus, "installed",
                    "chunk reassembly exposes activation state")
        assertEqual(manager.mapTransferActivationSequence, 9,
                    "chunk reassembly exposes activation sequence")
    }

    static func testBLEManagerParsesDeviceTransferStatus() {
        let manager = BLEManager()
        let json = """
        {"configured":true,"enabled":true,"port":8080,"mode":"firmware","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","sessionToken":"abc123","firmware":{"status":"receiving","target":"WAVESHARE_AMOLED_206","version":"0.2.2","build":86,"updaterProtocol":1,"receivedBytes":1024,"totalBytes":2048,"lastError":{"code":"previous","message":"previous update failed"}}}
        """
        let packet = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(json.utf8)

        assert(manager.handleDeviceTransferStatusNotification(packet), "DSTS notification should be consumed")
        assertEqual(manager.deviceTransferMode, "firmware", "status parser exposes transfer mode")
        assertEqual(manager.deviceTransferBaseURL?.absoluteString, "http://192.168.4.1:8080", "status parser exposes base URL")
        assertEqual(manager.deviceTransferAccessPointSSID, "BikeComputer-Transfer", "status parser exposes SSID")
        assertEqual(manager.deviceTransferSessionToken, "abc123", "status parser exposes session token")
        assertEqual(manager.firmwareTarget, "WAVESHARE_AMOLED_206", "status parser exposes firmware target")
        assertEqual(manager.firmwareVersion, "0.2.2", "status parser exposes firmware version")
        assertEqual(manager.firmwareBuild, 86, "status parser exposes firmware build")
        assertEqual(manager.firmwareUpdateStatus, "receiving", "status parser exposes firmware update status")
        assertEqual(manager.firmwareUpdateReceivedBytes, 1024, "status parser exposes received bytes")
        assertEqual(manager.firmwareUpdateTotalBytes, 2048, "status parser exposes total bytes")
        assertEqual(manager.firmwareUpdateLastError, "previous: previous update failed", "status parser exposes firmware error")

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
            "mapSettings.streetLineWidthBoost",
            "mapSettings.positionMarkerScale",
            "mapSettings.mapRotationMode",
            "mapSettings.zoomLevel",
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
            "mapPlusNavigationSettings.streetLineWidthBoost",
            "mapPlusNavigationSettings.positionMarkerScale",
            "mapPlusNavigationSettings.zoomLevel",
            "mapPlusNavigationSettings.showBuildings",
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
            "deviceSettings.enabledScreensMask",
            "deviceSettings.defaultScreen",
            "deviceSettings.defaultScreen.mapPlusNavigationDefault.v1",
            "deviceSettings.enabledScreensMask.batteryStatus.v1",
            "deviceSettings.disconnectedSleepTimeoutSeconds"
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }

        let freshManager = BLEManager()
        assertEqual(freshManager.defaultDeviceScreen, .mapPlusNavigation, "fresh installs default to Map + Navigation")
        assertEqual(freshManager.mapPlusNavigationDetailLevel, 0,
                    "fresh Map + Navigation profiles default to low detail")
        assert(!freshManager.mapPlusNavigationShowBuildings,
               "fresh Map + Navigation profiles hide buildings")
        assert(freshManager.mapPlusNavigationShowGreenSpace,
               "fresh Map + Navigation profiles keep green space visible")
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

        defaults.set(0x0F, forKey: "deviceSettings.enabledScreensMask")
        defaults.removeObject(forKey: "deviceSettings.enabledScreensMask.batteryStatus.v1")
        let batteryScreenMigratedManager = BLEManager()
        assert(batteryScreenMigratedManager.isDeviceScreenEnabled(.batteryStatus),
               "existing four-screen installs enable Battery Status once")

        freshManager.isConnected = true
        freshManager.isNavigationReady = true
        var freshProfilePackets: [Data] = []
        freshManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { freshProfilePackets.append($0) }
        ))
        let independentCapabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.independentMapProfilesCapabilityMask |
                  DeviceBLEProtocol.extendedMapVisibilityCapabilityMask])
        assert(freshManager.handleDeviceCapabilitiesNotification(independentCapabilities),
               "fresh profiles negotiate independent map settings")
        let freshVisibilityPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID
        }
        let freshDetailPacket = freshProfilePackets.first {
            $0.count == 9 && $0[4] == DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID
        }
        assert(freshVisibilityPacket != nil,
               "fresh Map + Navigation visibility is sent after capability negotiation")
        assert(freshDetailPacket != nil,
               "fresh Map + Navigation detail is sent after capability negotiation")
        assertEqual(readInt32LE(freshVisibilityPacket!, offset: 5), 0x103A,
                    "fresh Map + Navigation sends only green space, major roads, local roads, and water")
        assertEqual(readInt32LE(freshDetailPacket!, offset: 5), 0,
                    "fresh Map + Navigation sends low detail")

        defaults.set(DeviceScreen.map.rawValue, forKey: "deviceSettings.defaultScreen")
        defaults.removeObject(forKey: "deviceSettings.defaultScreen.mapPlusNavigationDefault.v1")
        let migratedManager = BLEManager()
        assertEqual(migratedManager.defaultDeviceScreen, .mapPlusNavigation, "old Map defaults migrate to Map + Navigation")

        defaults.set(1, forKey: "mapSettings.detailLevel")
        defaults.set(4, forKey: "mapSettings.zoomLevel")
        defaults.set(false, forKey: "mapSettings.showBuildings")
        defaults.set(false, forKey: "mapSettings.showPaths")
        defaults.set(false, forKey: "mapSettings.showLocalStreets")
        defaults.removeObject(forKey: "mapSettings.showTracks")
        defaults.removeObject(forKey: "mapSettings.showServiceRoads")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.showTracks")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.showServiceRoads")
        defaults.removeObject(forKey: "mapPlusNavigationSettings.migrated.v1")
        let migratedProfileManager = BLEManager()
        assertEqual(migratedProfileManager.mapPlusNavigationDetailLevel, 1,
                    "existing shared detail migrates into Map + Navigation")
        assertEqual(migratedProfileManager.mapPlusNavigationZoomLevel, 4,
                    "existing shared zoom migrates into Map + Navigation")
        assert(!migratedProfileManager.mapPlusNavigationShowBuildings,
               "existing shared visibility migrates into Map + Navigation")
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
        assertEqual(reloaded.enabledDeviceScreensMask,
                    DeviceScreen.navigation.bit | DeviceScreen.mapPlusNavigation.bit,
                    "enabled device screens should persist across BLEManager reloads")
        assertEqual(reloaded.defaultDeviceScreen, .mapPlusNavigation, "default device screen should persist across BLEManager reloads")
        assertEqual(reloaded.disconnectedSleepTimeout, .tenMinutes, "disconnected sleep timeout should persist across BLEManager reloads")

        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    static func testBLEManagerPersistsDeviceSoundSettings() {
        let defaults = UserDefaults.standard
        let soundKey = "deviceSettings.selectedSound"
        let volumeKey = "deviceSettings.soundVolumePercent"
        let powerButtonHonkKey = "deviceSettings.powerButtonHonkEnabled"
        defaults.removeObject(forKey: soundKey)
        defaults.removeObject(forKey: volumeKey)
        defaults.removeObject(forKey: powerButtonHonkKey)

        let freshManager = BLEManager()
        assertEqual(freshManager.selectedDeviceSound, .plasticBicycleHorn, "fresh installs use the bicycle horn")
        assertEqual(freshManager.deviceSoundVolumePercent, 70, "fresh installs use 70 percent sound volume")
        assert(!freshManager.isPowerButtonHonkEnabled, "fresh installs leave PWR honk disabled")

        freshManager.selectedDeviceSound = .rotatingBicycleBell
        freshManager.deviceSoundVolumePercent = 65
        freshManager.isPowerButtonHonkEnabled = true
        freshManager.saveSettings()

        let reloaded = BLEManager()
        assertEqual(reloaded.selectedDeviceSound, .rotatingBicycleBell, "selected sound persists")
        assertEqual(reloaded.deviceSoundVolumePercent, 65, "sound volume persists")
        assert(reloaded.isPowerButtonHonkEnabled, "PWR honk enabled state persists")

        defaults.set(4, forKey: soundKey)
        defaults.set(Double.nan, forKey: volumeKey)
        let invalidValues = BLEManager()
        assertEqual(invalidValues.selectedDeviceSound, .plasticBicycleHorn, "unknown sound IDs fall back safely")
        assertEqual(invalidValues.deviceSoundVolumePercent, 70, "non-finite persisted volume falls back safely")

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

        assertEqual(manager.sentGPSPositions.count, 1, "idle GPS sync should still send position/time")
        let packet = manager.sentGPSPositions[0]
        assertEqual(readUInt16LE(packet, offset: 14),
                    DeviceGPSPacketBuilder.invalidSpeedCmps,
                    "idle GPS sync should omit speed telemetry")
        assertEqual(readInt16LE(packet, offset: 16), 0, "idle GPS sync should omit altitude telemetry")
        assertEqual(readUInt32LE(packet, offset: 18), 0, "idle GPS sync should omit distance telemetry")
        assertEqual(readUInt32LE(packet, offset: 22), 0, "idle GPS sync should omit elapsed telemetry")
        assertEqual(readUInt32LE(packet, offset: 26),
                    DeviceGPSPacketBuilder.invalidRouteRemainingMeters,
                    "idle GPS sync should omit route remaining telemetry")
    }

    static func testNavigationEngineIgnoresLiveLocationFarFromRouteStart() {
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
        engine.processExternalLocation(unrelatedDeviceLocation)

        assertEqual(manager.sentPackets.count, 1, "far live GPS should not overwrite a route started from another source")
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
