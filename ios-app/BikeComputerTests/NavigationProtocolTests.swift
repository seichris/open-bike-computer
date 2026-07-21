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

func makePreviewReadableBikeMapStream(manifest: Data) -> Data {
    var stream = Data("BIKEMAP1".utf8)
    appendUInt16LE(1, to: &stream)
    appendUInt16LE(0, to: &stream)
    appendUInt32LE(UInt32(manifest.count), to: &stream)
    appendUInt16LE(5, to: &stream)
    appendUInt16LE(0, to: &stream)
    appendUInt32LE(1, to: &stream)
    for shift in stride(from: 0, through: 56, by: 8) {
        stream.append(UInt8((UInt64(1) >> UInt64(shift)) & 0xff))
    }
    stream.append(manifest)
    stream.append(Data(repeating: 0, count: 5))
    stream.append(0)
    return stream
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

func testLocation(
    latitude: CLLocationDegrees,
    longitude: CLLocationDegrees,
    horizontalAccuracy: CLLocationAccuracy = 5
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        altitude: 0,
        horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: 5,
        course: -1,
        speed: -1,
        timestamp: Date()
    )
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

@MainActor
final class TestNavigationDirectionsTask: NavigationDirectionsTask {
    let request: MKDirections.Request
    private(set) var isCancelled = false
    private var completion: (@MainActor (Result<[MKRoute], Error>) -> Void)?

    init(request: MKDirections.Request) {
        self.request = request
    }

    func calculate(
        completion: @escaping @MainActor (Result<[MKRoute], Error>) -> Void
    ) {
        self.completion = completion
    }

    func cancel() {
        isCancelled = true
    }

    func succeed(with routes: [MKRoute]) {
        completion?(.success(routes))
    }

    func fail(with error: Error) {
        completion?(.failure(error))
    }
}

@MainActor
final class TestNavigationDirectionsFactory {
    private(set) var tasks: [TestNavigationDirectionsTask] = []

    func makeTask(request: MKDirections.Request) -> any NavigationDirectionsTask {
        let task = TestNavigationDirectionsTask(request: request)
        tasks.append(task)
        return task
    }
}

enum TestNavigationDirectionsError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Directions unavailable"
    }
}

final class TestClock {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date {
        date
    }

    func advance(by interval: TimeInterval) {
        date = date.addingTimeInterval(interval)
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
    private let storedDistance: CLLocationDistance

    init(instructions: String, coordinates: [CLLocationCoordinate2D]) {
        self.storedInstructions = instructions
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        super.init()
    }

    override var instructions: String {
        storedInstructions
    }

    override var polyline: MKPolyline {
        storedPolyline
    }

    override var distance: CLLocationDistance {
        storedDistance
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

    init(steps: [TestRouteStep], coordinates: [CLLocationCoordinate2D]) {
        self.storedSteps = steps
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = steps.reduce(0) { $0 + $1.distance }
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
        testRouteDeviationDetection()
        testReplacementStepSelectionUsesUnambiguousGeometry()
        testCoordinatorReroutesAndAppliesLatestRoute()
        testWorkoutAndNavigationLifecyclesStayIndependent()
        testCoordinatorRejectsStaleRerouteLocations()
        testCoordinatorDetectsDeviationFromCurrentStep()
        testCoordinatorEnforcesRerouteCooldown()
        testCoordinatorCancelsStaleReroutes()
        testCoordinatorPreservesReroutingAfterFailedReplacement()
        testStepRemainingDistanceFollowsPolyline()
        testStepRemainingDistanceResolvesAmbiguousGeometry()
        testChinaRouteCoordinatesRoundTripWithoutCalibrationNudge()
        testNonChinaCoordinatesPassThroughUnchanged()
        testSourceEndpointSelection()
        testSavedDestinationStore()
        testDestinationPickerProtocol()
        testRouteInitialLocationUsesResolvedSource()
        testRouteTransportTypes()
        testMapTrackingPolicy()
        testDeviceGPSPacketBuilder()
        testNavigationPacketBuilder()
        testNavigationWriteQueue()
        testDeviceBLEProtocolConstants()
        testWorkoutDeviceFrameVectors()
        testWorkoutDeviceFrameSentinelsAndSaturation()
        testWorkoutDeviceTelemetryMapping()
        testWorkoutDeviceRelayScheduling()
        testWorkoutDeviceRelayPublicationIntegration()
        testWorkoutTelemetryBLETransport()
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
        testDeviceOwnershipProtocol()
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
        testNavigationSnapshotTransportDistanceBounds()
        testNavigationSendTrackerReadinessRetry()
        testNavigationEngineUsesStepPolylineDistance()
        testNavigationEngineDoesNotSkipNearbyCurvedEndpoint()
        testNavigationEngineSeedsCurvedProgressAfterStepTransition()
        testNavigationEngineReportsDistanceAfterPassingManeuver()
        testNavigationEngineUsesDegenerateStepFallback()
        testNavigationEngineKeepsProgressAtRouteCrossing()
        testNavigationEngineResendsWhenBLEBecomesReady()
        testNavigationEngineResendsRouteGeometryNearLastLocation()
        testNavigationEngineClearsRouteGeometryOnStop()
        testNavigationEngineClearsRouteGeometryWhenReadyAndIdle()
        testNavigationEngineRestoresPhysicalGPSAfterSimulation()
        testNavigationEngineKeepsPhysicalGPSAfterSimulationStepCompletion()
        testNavigationEngineOmitsRideTelemetryWhenIdle()
        testNavigationEngineIgnoresLiveLocationFarFromRouteStart()
        testNavigationEngineReplacesRouteWithoutResettingTelemetry()
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
        testOfflineMapOnboardingPolicy()
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
        testSavedMapDefaultNamePolicy()
        testOfflineMapManagerRepairsGeneratedPackDefaults()
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
        let refreshedCredential = OfflineMapInstallationCredential(
            clientInstallationId: credential.clientInstallationId,
            clientInstallationToken: "v1." + String(repeating: "B", count: 43)
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
                if request.url?.host == "legacy-maps.example.com" {
                    assertEqual(
                        request.value(forHTTPHeaderField: "Authorization"),
                        "Bearer custom-server-token",
                        "legacy custom-server registration keeps its scoped bearer"
                    )
                    return (404, Data())
                }
                assert(
                    request.value(forHTTPHeaderField: "Authorization") == nil,
                    "installation registration does not send a shared app secret"
                )
                if request.url?.query?.contains("clientInstallationId=") == true {
                    assertEqual(
                        request.value(forHTTPHeaderField: "X-Installation-Token"),
                        credential.clientInstallationToken,
                        "installation refresh authenticates the existing identity"
                    )
                    return (200, try! JSONEncoder().encode(refreshedCredential))
                }
                return (200, try! JSONEncoder().encode(credential))
            case "/v1/map-packs/map/artifacts/bike-map-stream-v1/download-url":
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Installation-Token"),
                    refreshedCredential.clientInstallationToken,
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
            clientInstallationId: "legacy-installation",
            session: session
        )
        do {
            assertEqual(
                try await unregisteredClient.registerInstallation(),
                credential,
                "server-issued installation credential decodes"
            )
            let legacyCustomClient = OfflineMapPlatformClient(
                baseURL: URL(string: "https://legacy-maps.example.com")!,
                legacyBearerToken: "custom-server-token",
                clientInstallationId: "legacy-installation",
                session: session
            )
            do {
                _ = try await legacyCustomClient.registerInstallation()
                assert(false, "legacy custom server should report its missing registration route")
            } catch let error as OfflineMapPlatformError {
                if case .serverStatus(let status, _) = error {
                    assertEqual(status, 404, "legacy custom registration preserves fallback status")
                } else {
                    assert(false, "legacy custom registration returns an HTTP status")
                }
            }
            let registeredClient = OfflineMapPlatformClient(
                baseURL: URL(string: "https://maps.example.com")!,
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
                try await registeredClient.registerInstallation(),
                refreshedCredential,
                "existing installation exchanges its old token without changing identity"
            )
            assert(
                registeredClient.canAdoptInstallationCredential(refreshedCredential),
                "same-identity refresh can replace the stored installation token"
            )
            let preRefreshServerCredential = OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_abcdef1234567890abcdef1234567890",
                clientInstallationToken: "v1." + String(repeating: "C", count: 43)
            )
            assert(
                !registeredClient.canAdoptInstallationCredential(preRefreshServerCredential),
                "staggered pre-refresh server cannot orphan a proven installation identity"
            )
            let refreshBackoffSuite = "offline-map-refresh-backoff-\(UUID().uuidString)"
            let refreshBackoffDefaults = UserDefaults(suiteName: refreshBackoffSuite)!
            defer {
                refreshBackoffDefaults.removePersistentDomain(forName: refreshBackoffSuite)
            }
            let backoffStart = Date(timeIntervalSince1970: 1_700_000_000)
            OfflineMapInstallationRefreshBackoff.deferRefresh(
                serverURLString: registeredClient.baseURL.absoluteString,
                defaults: refreshBackoffDefaults,
                now: backoffStart
            )
            assert(
                OfflineMapInstallationRefreshBackoff.shouldDefer(
                    serverURLString: registeredClient.baseURL.absoluteString,
                    defaults: refreshBackoffDefaults,
                    now: backoffStart.addingTimeInterval(24 * 60 * 60)
                ),
                "legacy refresh response suppresses repeated registration attempts"
            )
            assert(
                !OfflineMapInstallationRefreshBackoff.shouldDefer(
                    serverURLString: registeredClient.baseURL.absoluteString,
                    defaults: refreshBackoffDefaults,
                    now: backoffStart.addingTimeInterval(26 * 60 * 60)
                ),
                "refresh capability is probed again after the persisted backoff"
            )
            let refreshedClient = OfflineMapPlatformClient(
                baseURL: registeredClient.baseURL,
                clientInstallationId: refreshedCredential.clientInstallationId,
                clientInstallationToken: refreshedCredential.clientInstallationToken,
                mapStreamTrustCapabilities: registeredClient.mapStreamTrustCapabilities,
                mapStreamAppBuildIdentity: registeredClient.mapStreamAppBuildIdentity,
                session: session
            )
            assertEqual(
                try await refreshedClient.artifactDownloadURL(
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

    static func testRouteDeviationDetection() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0020, longitude: -122.0000)
        ]
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let onRoute = CLLocation(latitude: 37.0010, longitude: -122.0000)
        let offRoute = CLLocation(latitude: 37.0010, longitude: -122.0010)

        assert((RouteDeviation.distance(from: onRoute, to: polyline) ?? -1) < 1,
               "on-route location has near-zero deviation")
        assert((RouteDeviation.distance(from: offRoute, to: polyline) ?? 0) > 80,
               "off-route location reports distance to the nearest segment")

        var detector = RouteDeviationDetector()
        assertEqual(detector.distanceThreshold, 30, "default reroute distance threshold is 30 meters")
        assertEqual(detector.requiredConsecutiveSamples, 3, "default reroute streak requires three samples")
        assertEqual(detector.maxHorizontalAccuracy, 50, "default reroute accuracy ceiling is 50 meters")
        assert(!detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 10),
               "first off-route sample does not reroute")
        assert(!detector.shouldReroute(distanceToRoute: 20, horizontalAccuracy: 10),
               "an on-route sample interrupts the deviation streak")
        assertEqual(detector.consecutiveOffRouteSamples, 0,
                    "an on-route sample resets the deviation streak")
        assert(!detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 10),
               "the streak restarts after returning to the route")
        assert(!detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 10),
               "second off-route sample does not reroute")
        assert(detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 10),
               "third accurate off-route sample reroutes")
        assert(!detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 10),
               "a new deviation streak can start after rerouting")
        assert(!detector.shouldReroute(distanceToRoute: 40, horizontalAccuracy: 80),
               "poor GPS accuracy interrupts the deviation streak")
        assertEqual(detector.consecutiveOffRouteSamples, 0,
                    "poor GPS accuracy resets the deviation streak")
        assert(!detector.shouldReroute(distanceToRoute: 30, horizontalAccuracy: 5),
               "the exact base threshold does not trigger rerouting")
        assert(!detector.shouldReroute(distanceToRoute: 55, horizontalAccuracy: 30),
               "accuracy-adjusted threshold avoids marginal deviations")
        assertEqual(detector.consecutiveOffRouteSamples, 0,
                    "an on-route or uncertain sample resets the deviation streak")
    }

    static func testReplacementStepSelectionUsesUnambiguousGeometry() {
        let crossing = CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        let firstTurn = CLLocationCoordinate2D(latitude: 37.0020, longitude: -122.0000)
        let loopPoint = CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0010)
        let destination = CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990)
        let route = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Continue north",
                    coordinates: [crossing, firstTurn]
                ),
                TestRouteStep(
                    instructions: "Continue through crossing",
                    coordinates: [firstTurn, loopPoint, crossing, destination]
                )
            ],
            coordinates: [crossing, firstTurn, loopPoint, crossing, destination]
        )
        let crossingLocation = testLocation(
            latitude: crossing.latitude,
            longitude: crossing.longitude,
            horizontalAccuracy: 5
        )

        assertEqual(
            RouteStepSelection.closestNavigableStepIndex(
                to: crossingLocation,
                in: route
            ),
            0,
            "ambiguous replacement geometry cannot skip steps without movement evidence"
        )

        let parallelSource = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let parallelTurn = CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        let parallelDestination = CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.99995)
        let parallelRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Continue north",
                    coordinates: [parallelSource, parallelTurn]
                ),
                TestRouteStep(
                    instructions: "Return south",
                    coordinates: [parallelTurn, parallelDestination]
                )
            ],
            coordinates: [parallelSource, parallelTurn, parallelDestination]
        )
        let stationaryParallelLocation = testLocation(
            latitude: parallelSource.latitude,
            longitude: parallelSource.longitude,
            horizontalAccuracy: 20
        )
        assertEqual(
            RouteStepSelection.closestNavigableStepIndex(
                to: stationaryParallelLocation,
                in: parallelRoute
            ),
            0,
            "nearby parallel geometry cannot skip a maneuver without movement evidence"
        )

        let curvedSource = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9995)
        let curvedNorth = CLLocationCoordinate2D(latitude: 37.0009, longitude: -121.9995)
        let curvedEast = CLLocationCoordinate2D(latitude: 37.0009, longitude: -121.9992)
        let curvedManeuver = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9992)
        let curvedLatest = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9998)
        let curvedRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Turn left",
                    coordinates: [curvedSource, curvedNorth, curvedEast, curvedManeuver]
                ),
                TestRouteStep(
                    instructions: "Continue",
                    coordinates: [curvedManeuver, curvedSource, curvedLatest]
                )
            ],
            coordinates: [
                curvedSource,
                curvedNorth,
                curvedEast,
                curvedManeuver,
                curvedSource,
                curvedLatest
            ]
        )
        let curvedLatestLocation = testLocation(
            latitude: curvedLatest.latitude,
            longitude: curvedLatest.longitude
        )
        assertEqual(
            RouteStepSelection.closestNavigableStepIndex(
                to: curvedLatestLocation,
                in: curvedRoute
            ),
            1,
            "a clearly closer later step is selected without inferring progress from movement"
        )

        let accuracyBoundarySource = CLLocationCoordinate2D(
            latitude: 37.0000,
            longitude: -122.0000
        )
        let accuracyBoundaryTurn = CLLocationCoordinate2D(
            latitude: 37.0010,
            longitude: -122.0000
        )
        let accuracyBoundaryLatest = CLLocationCoordinate2D(
            latitude: 37.0020,
            longitude: -122.0000
        )
        let accuracyBoundaryDestination = CLLocationCoordinate2D(
            latitude: 37.0030,
            longitude: -122.0000
        )
        let accuracyBoundaryRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Turn left",
                    coordinates: [accuracyBoundarySource, accuracyBoundaryTurn]
                ),
                TestRouteStep(
                    instructions: "Continue",
                    coordinates: [accuracyBoundaryTurn, accuracyBoundaryDestination]
                )
            ],
            coordinates: [
                accuracyBoundarySource,
                accuracyBoundaryTurn,
                accuracyBoundaryDestination
            ]
        )
        let accuracyBoundaryLocation = testLocation(
            latitude: accuracyBoundaryLatest.latitude,
            longitude: accuracyBoundaryLatest.longitude,
            horizontalAccuracy: 50
        )
        assertEqual(
            RouteStepSelection.closestNavigableStepIndex(
                to: accuracyBoundaryLocation,
                in: accuracyBoundaryRoute
            ),
            1,
            "the 50-meter accuracy boundary still selects a later step when it is clearly closer"
        )
    }

    @MainActor
    static func testCoordinatorReroutesAndAppliesLatestRoute() {
        let suite = "CoordinatorRerouteTests.Apply.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false
        )

        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let destinationCoordinate = CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        let initialRoute = TestRoute(
            instructions: "Continue on original route",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )

        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        assertEqual(factory.tasks.count, 1, "initial navigation creates one directions request")
        factory.tasks[0].succeed(with: [initialRoute])
        assert(coordinator.isNavigating, "initial route starts navigation")
        assert(
            waitForMainLoop(timeout: 2) { !coordinator.routeCalculation.isCalculating },
            "initial route calculation should finish before reroute evaluation"
        )

        let offRouteLocation = testLocation(latitude: 37.0003, longitude: -121.9995)
        for sampleIndex in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
            if sampleIndex < 2 {
                assertEqual(
                    factory.tasks.count,
                    1,
                    "rerouting waits for three consecutive off-route fixes"
                )
            }
        }

        assertEqual(factory.tasks.count, 2, "three accepted off-route fixes create one reroute request")
        guard factory.tasks.count == 2,
              let rerouteSource = factory.tasks[1].request.source,
              let rerouteDestination = factory.tasks[1].request.destination else {
            assert(false, "reroute request should include source and destination")
            return
        }
        assertCoordinate(
            rerouteSource.placemark.coordinate,
            latitude: offRouteLocation.coordinate.latitude,
            longitude: offRouteLocation.coordinate.longitude,
            "reroute starts from the latest off-route fix"
        )
        assertCoordinate(
            rerouteDestination.placemark.coordinate,
            latitude: destinationCoordinate.latitude,
            longitude: destinationCoordinate.longitude,
            "reroute retains the original destination"
        )

        let curveNorth = CLLocationCoordinate2D(latitude: 37.0009, longitude: -121.9995)
        let curveEast = CLLocationCoordinate2D(latitude: 37.0009, longitude: -121.9992)
        let firstManeuver = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9992)
        let replacementEnd = CLLocationCoordinate2D(latitude: 37.0003, longitude: -121.9998)
        let replacementRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Turn left",
                    coordinates: [
                        offRouteLocation.coordinate,
                        curveNorth,
                        curveEast,
                        firstManeuver
                    ]
                ),
                TestRouteStep(
                    instructions: "Continue",
                    coordinates: [
                        firstManeuver,
                        offRouteLocation.coordinate,
                        replacementEnd
                    ]
                )
            ],
            coordinates: [
                offRouteLocation.coordinate,
                curveNorth,
                curveEast,
                firstManeuver,
                offRouteLocation.coordinate,
                replacementEnd
            ]
        )
        for coordinate in [curveNorth, curveEast, firstManeuver, replacementEnd] {
            coordinator.processNavigationLocationForTesting(testLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ))
        }
        factory.tasks[1].succeed(with: [replacementRoute])

        assert(coordinator.currentRoute === replacementRoute, "reroute response replaces the map route")
        assertEqual(
            coordinator.currentInstruction,
            "Continue",
            "accumulated curved movement advances past a maneuver near the request source"
        )

        let cooldownDeviation = testLocation(latitude: 37.0003, longitude: -121.9989)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(cooldownDeviation)
        }
        assertEqual(factory.tasks.count, 2, "cooldown suppresses an immediate repeated reroute")
    }

    @MainActor
    static func testWorkoutAndNavigationLifecyclesStayIndependent() {
        let suite = "CoordinatorWorkoutIndependence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSinceReferenceDate: 800_300_000)
        let store = WorkoutMetricsStore()
        store.attachMirroredSession(at: now)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 3,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now
                    )
                ),
            ],
            receivedAt: now
        )

        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            workoutMetricsStore: store,
            directionsFactory: factory.makeTask,
            startServices: false
        )
        let sourceCoordinate = CLLocationCoordinate2D(
            latitude: 37.0,
            longitude: -122.0
        )
        let destinationCoordinate = CLLocationCoordinate2D(
            latitude: 37.01,
            longitude: -122.0
        )
        let source = MKMapItem(
            placemark: MKPlacemark(coordinate: sourceCoordinate)
        )
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destinationCoordinate)
        )
        let route = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )

        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        factory.tasks[0].succeed(with: [route])
        assert(coordinator.isNavigating, "navigation should start beside a workout")
        assert(
            store.presentation.navigation.routeRemainingDistanceMeters != nil,
            "coordinator should publish navigation-only context to the workout store"
        )
        let firstFix = CLLocation(
            coordinate: sourceCoordinate,
            altitude: 12,
            horizontalAccuracy: 4,
            verticalAccuracy: 3,
            course: 0,
            speed: 6,
            timestamp: Date()
        )
        let secondFix = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 37.0001,
                longitude: -122.0
            ),
            altitude: 13,
            horizontalAccuracy: 4,
            verticalAccuracy: 3,
            course: 0,
            speed: 7,
            timestamp: Date()
        )
        coordinator.processNavigationLocationForTesting(firstFix)
        coordinator.processNavigationLocationForTesting(secondFix)
        assertEqual(
            store.presentation.snapshot.currentSpeed?.source,
            .iPhoneLocation,
            "coordinator should publish iPhone speed when Watch speed is unavailable"
        )
        assertEqual(
            store.presentation.snapshot.location?.latitude,
            secondFix.coordinate.latitude,
            "coordinator should publish the latest valid iPhone location fallback"
        )
        assert(
            (store.presentation.snapshot.cyclingDistance?.value ?? 0) > 0
                && store.presentation.snapshot.cyclingDistance?.source
                    == .iPhoneNavigation,
            "coordinator should publish workout-relative navigation distance"
        )
        coordinator.stopNavigation()
        assertEqual(
            store.presentation.sessionState,
            .running,
            "ending navigation must not end the Watch-owned workout"
        )
        assert(
            store.presentation.snapshot.cyclingDistance == nil
                && store.presentation.navigation == .empty,
            "ending navigation should clear only iPhone navigation fallbacks"
        )

        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        factory.tasks[1].succeed(with: [route])
        store.confirmSessionState(.ended, at: now.addingTimeInterval(60))
        assert(
            coordinator.isNavigating,
            "ending the workout must not stop navigation"
        )
    }

    @MainActor
    static func testCoordinatorRejectsStaleRerouteLocations() {
        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let destinationCoordinate = CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        let initialRoute = TestRoute(
            instructions: "Continue on original route",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )
        let rerouteTrigger = testLocation(latitude: 37.0003, longitude: -121.9995)

        let staleSuite = "CoordinatorRerouteTests.StaleLocation.\(UUID().uuidString)"
        let staleDefaults = UserDefaults(suiteName: staleSuite)!
        defer { staleDefaults.removePersistentDomain(forName: staleSuite) }
        let staleClock = TestClock()
        let staleFactory = TestNavigationDirectionsFactory()
        let staleCoordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: staleDefaults),
            directionsFactory: staleFactory.makeTask,
            startServices: false,
            now: staleClock.now
        )
        staleCoordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        staleFactory.tasks[0].succeed(with: [initialRoute])
        assert(
            waitForMainLoop(timeout: 2) { !staleCoordinator.routeCalculation.isCalculating },
            "stale-location test initial route calculation should finish"
        )
        for _ in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(rerouteTrigger)
        }
        assertEqual(staleFactory.tasks.count, 2, "stale-location test creates a reroute request")

        let returnedRoute = TestRoute(
            instructions: "Continue on returned route",
            coordinates: [
                rerouteTrigger.coordinate,
                CLLocationCoordinate2D(latitude: 37.0020, longitude: -121.9995)
            ]
        )
        let movedAway = testLocation(latitude: 37.0009, longitude: -121.9985)
        staleCoordinator.processNavigationLocationForTesting(movedAway)
        staleCoordinator.processNavigationLocationForTesting(testLocation(
            latitude: 37.0009,
            longitude: -121.9995,
            horizontalAccuracy: 80
        ))
        staleFactory.tasks[1].succeed(with: [returnedRoute])

        assert(
            staleCoordinator.currentRoute === initialRoute,
            "a response that misses the latest accurate fix is not applied"
        )
        for _ in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(movedAway)
        }
        assertEqual(
            staleFactory.tasks.count,
            2,
            "discarding a stale response still respects the reroute cooldown"
        )
        staleClock.advance(by: 15)
        for _ in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(movedAway)
        }
        assertEqual(staleFactory.tasks.count, 3, "stale rerouting resumes after 15 seconds")
        guard let retriedSource = staleFactory.tasks[2].request.source else {
            assert(false, "retried reroute should have a source")
            return
        }
        assertCoordinate(
            retriedSource.placemark.coordinate,
            latitude: movedAway.coordinate.latitude,
            longitude: movedAway.coordinate.longitude,
            "retried reroute starts from the new accurate fix"
        )

        let accuracySuite = "CoordinatorRerouteTests.PoorAccuracy.\(UUID().uuidString)"
        let accuracyDefaults = UserDefaults(suiteName: accuracySuite)!
        defer { accuracyDefaults.removePersistentDomain(forName: accuracySuite) }
        let accuracyFactory = TestNavigationDirectionsFactory()
        let accuracyCoordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: accuracyDefaults),
            directionsFactory: accuracyFactory.makeTask,
            startServices: false
        )
        accuracyCoordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        accuracyFactory.tasks[0].succeed(with: [initialRoute])
        assert(
            waitForMainLoop(timeout: 2) { !accuracyCoordinator.routeCalculation.isCalculating },
            "poor-accuracy test initial route calculation should finish"
        )
        for _ in 0..<3 {
            accuracyCoordinator.processNavigationLocationForTesting(rerouteTrigger)
        }
        assertEqual(accuracyFactory.tasks.count, 2, "poor-accuracy test creates a reroute request")

        let firstManeuver = CLLocationCoordinate2D(latitude: 37.0006, longitude: -121.9995)
        let replacementRoute = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Turn left",
                    coordinates: [rerouteTrigger.coordinate, firstManeuver]
                ),
                TestRouteStep(
                    instructions: "Continue",
                    coordinates: [
                        firstManeuver,
                        CLLocationCoordinate2D(latitude: 37.0020, longitude: -121.9995)
                    ]
                )
            ],
            coordinates: [
                rerouteTrigger.coordinate,
                firstManeuver,
                CLLocationCoordinate2D(latitude: 37.0020, longitude: -121.9995)
            ]
        )
        let latestAccurateFix = testLocation(latitude: 37.0009, longitude: -121.9995)
        accuracyCoordinator.processNavigationLocationForTesting(latestAccurateFix)
        let poorFix = testLocation(
            latitude: 37.0009,
            longitude: -121.9985,
            horizontalAccuracy: 80
        )
        accuracyCoordinator.processNavigationLocationForTesting(poorFix)
        accuracyFactory.tasks[1].succeed(with: [replacementRoute])

        assert(
            accuracyCoordinator.currentRoute === replacementRoute,
            "a poor latest fix does not prevent applying a route valid at the trigger fix"
        )
        assertEqual(
            accuracyCoordinator.currentInstruction,
            "Continue",
            "a poor fix cannot replace the latest eligible reroute position"
        )
    }

    @MainActor
    static func testCoordinatorDetectsDeviationFromCurrentStep() {
        let suite = "CoordinatorRerouteTests.CurrentStep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false
        )
        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let firstManeuver = CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        let destinationCoordinate = CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        let route = TestRoute(
            steps: [
                TestRouteStep(
                    instructions: "Continue north",
                    coordinates: [sourceCoordinate, firstManeuver]
                ),
                TestRouteStep(
                    instructions: "Turn right",
                    coordinates: [firstManeuver, destinationCoordinate]
                )
            ],
            coordinates: [sourceCoordinate, firstManeuver, destinationCoordinate]
        )
        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        factory.tasks[0].succeed(with: [route])
        assert(
            waitForMainLoop(timeout: 2) { !coordinator.routeCalculation.isCalculating },
            "current-step test initial route calculation should finish"
        )

        let skippedAhead = testLocation(latitude: 37.0010, longitude: -121.9995)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(skippedAhead)
        }
        assertEqual(
            factory.tasks.count,
            2,
            "a shortcut onto a later route segment reroutes when the current step was missed"
        )
    }

    @MainActor
    static func testCoordinatorEnforcesRerouteCooldown() {
        let suite = "CoordinatorRerouteTests.Cooldown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock()
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false,
            now: clock.now
        )
        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let destinationCoordinate = CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        let route = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )
        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        factory.tasks[0].succeed(with: [route])
        assert(
            waitForMainLoop(timeout: 2) { !coordinator.routeCalculation.isCalculating },
            "cooldown test initial route calculation should finish"
        )

        let offRouteLocation = testLocation(latitude: 37.0003, longitude: -121.9995)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(factory.tasks.count, 2, "cooldown test creates the first reroute")
        factory.tasks[1].fail(with: TestNavigationDirectionsError.unavailable)

        let replacementDestination = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: 37.0050, longitude: -121.9980)
            )
        )
        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(replacementDestination),
            transportType: .walking
        )
        assertEqual(factory.tasks.count, 3, "cooldown test creates a replacement route request")
        factory.tasks[2].succeed(with: [])
        assert(
            waitForMainLoop(timeout: 3) { !coordinator.routeCalculation.isCalculating },
            "failed replacement should finish before cooldown evaluation"
        )
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(
            factory.tasks.count,
            3,
            "a failed replacement attempt does not clear the active route's cooldown"
        )

        clock.advance(by: 14.999)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(factory.tasks.count, 3, "rerouting remains suppressed just before 15 seconds")

        clock.advance(by: 0.001)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(factory.tasks.count, 4, "rerouting resumes at the 15-second boundary")
        assertEqual(
            factory.tasks[3].request.transportType.rawValue,
            RouteTransportTypes.cycling.rawValue,
            "cooldown retry retains the active route's transport mode"
        )
    }

    @MainActor
    static func testCoordinatorCancelsStaleReroutes() {
        let stopSuite = "CoordinatorRerouteTests.Stop.\(UUID().uuidString)"
        let stopDefaults = UserDefaults(suiteName: stopSuite)!
        defer { stopDefaults.removePersistentDomain(forName: stopSuite) }

        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let destinationCoordinate = CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        let initialRoute = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )
        let staleRoute = TestRoute(
            instructions: "Stale reroute",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )
        let offRouteLocation = testLocation(latitude: 37.0003, longitude: -121.9995)

        let stopFactory = TestNavigationDirectionsFactory()
        let stopCoordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: stopDefaults),
            directionsFactory: stopFactory.makeTask,
            startServices: false
        )
        stopCoordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        stopFactory.tasks[0].succeed(with: [initialRoute])
        assert(
            waitForMainLoop(timeout: 2) { !stopCoordinator.routeCalculation.isCalculating },
            "stop test initial route calculation should finish"
        )
        for _ in 0..<3 {
            stopCoordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(stopFactory.tasks.count, 2, "stop test creates a reroute request")
        let stoppedReroute = stopFactory.tasks[1]

        stopCoordinator.stopNavigation()
        assert(stoppedReroute.isCancelled, "stopping navigation cancels the active reroute")
        stoppedReroute.succeed(with: [staleRoute])
        assert(!stopCoordinator.isNavigating, "a stale stopped reroute cannot restart navigation")
        assert(stopCoordinator.currentRoute == nil, "a stale stopped reroute cannot restore a route")

        let replaceSuite = "CoordinatorRerouteTests.Replace.\(UUID().uuidString)"
        let replaceDefaults = UserDefaults(suiteName: replaceSuite)!
        defer { replaceDefaults.removePersistentDomain(forName: replaceSuite) }
        let replaceFactory = TestNavigationDirectionsFactory()
        let replaceCoordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: replaceDefaults),
            directionsFactory: replaceFactory.makeTask,
            startServices: false
        )
        replaceCoordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling
        )
        replaceFactory.tasks[0].succeed(with: [initialRoute])
        assert(
            waitForMainLoop(timeout: 2) { !replaceCoordinator.routeCalculation.isCalculating },
            "replacement test initial route calculation should finish"
        )
        for _ in 0..<3 {
            replaceCoordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(replaceFactory.tasks.count, 2, "replacement test creates a reroute request")
        let replacedReroute = replaceFactory.tasks[1]

        let newDestinationCoordinate = CLLocationCoordinate2D(latitude: 37.0050, longitude: -121.9980)
        let newDestination = MKMapItem(placemark: MKPlacemark(coordinate: newDestinationCoordinate))
        replaceCoordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(newDestination),
            transportType: RouteTransportTypes.cycling
        )
        assert(replacedReroute.isCancelled, "selecting a new destination cancels the active reroute")
        assertEqual(replaceFactory.tasks.count, 3, "new destination creates its own route request")
        replacedReroute.succeed(with: [staleRoute])
        assert(
            replaceCoordinator.currentRoute === initialRoute,
            "a stale reroute cannot replace the route while a new destination is pending"
        )
    }

    @MainActor
    static func testCoordinatorPreservesReroutingAfterFailedReplacement() {
        let suite = "CoordinatorRerouteTests.FailedReplacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false
        )
        let sourceCoordinate = CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000)
        let originalDestinationCoordinate = CLLocationCoordinate2D(latitude: 37.0040, longitude: -122.0000)
        let replacementDestinationCoordinate = CLLocationCoordinate2D(latitude: 37.0050, longitude: -121.9980)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let originalDestination = MKMapItem(
            placemark: MKPlacemark(coordinate: originalDestinationCoordinate)
        )
        let replacementDestination = MKMapItem(
            placemark: MKPlacemark(coordinate: replacementDestinationCoordinate)
        )
        let initialRoute = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, originalDestinationCoordinate]
        )

        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(originalDestination),
            transportType: .automobile
        )
        assertEqual(
            factory.tasks[0].request.transportType.rawValue,
            MKDirectionsTransportType.automobile.rawValue,
            "initial route uses the selected transport mode"
        )
        factory.tasks[0].succeed(with: [initialRoute])
        assert(
            waitForMainLoop(timeout: 2) { !coordinator.routeCalculation.isCalculating },
            "failed replacement test initial route calculation should finish"
        )
        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(replacementDestination),
            transportType: .walking
        )
        assertEqual(factory.tasks.count, 2, "replacement destination creates a route request")
        assertEqual(
            factory.tasks[1].request.transportType.rawValue,
            MKDirectionsTransportType.walking.rawValue,
            "replacement attempt uses its requested transport mode"
        )

        let offRouteLocation = testLocation(latitude: 37.0003, longitude: -121.9995)
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(factory.tasks.count, 2, "rerouting pauses while a replacement route is calculating")

        factory.tasks[1].succeed(with: [])
        assert(
            waitForMainLoop(timeout: 3) { !coordinator.routeCalculation.isCalculating },
            "failed replacement route calculation should finish"
        )
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(offRouteLocation)
        }
        assertEqual(factory.tasks.count, 3, "rerouting resumes on the original route after replacement fails")
        guard factory.tasks.count == 3,
              let resumedDestination = factory.tasks[2].request.destination else {
            assert(false, "resumed reroute should retain a destination")
            return
        }
        assertCoordinate(
            resumedDestination.placemark.coordinate,
            latitude: originalDestinationCoordinate.latitude,
            longitude: originalDestinationCoordinate.longitude,
            "failed replacement keeps the original reroute destination"
        )
        assertEqual(
            factory.tasks[2].request.transportType.rawValue,
            MKDirectionsTransportType.automobile.rawValue,
            "failed replacement keeps the original route's transport mode"
        )
    }

    static func testStepRemainingDistanceFollowsPolyline() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9990)
        ]
        let step = TestRouteStep(instructions: "Turn right", coordinates: coordinates)
        let start = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
        let endpoint = CLLocation(latitude: coordinates[3].latitude, longitude: coordinates[3].longitude)

        guard let remainingDistance = RouteProgress.remainingDistance(from: start, in: step) else {
            assert(false, "step remaining distance should be available for valid geometry")
            return
        }

        assert(
            abs(remainingDistance - step.distance) < 2,
            "step remaining starts at the full polyline distance"
        )
        assert(
            remainingDistance > start.distance(from: endpoint) * 2.5,
            "curved step distance should not collapse to straight-line endpoint distance"
        )

        let firstCorner = CLLocation(latitude: coordinates[1].latitude, longitude: coordinates[1].longitude)
        let expectedAfterCorner = CLLocation(latitude: coordinates[1].latitude, longitude: coordinates[1].longitude)
            .distance(from: CLLocation(latitude: coordinates[2].latitude, longitude: coordinates[2].longitude))
            + CLLocation(latitude: coordinates[2].latitude, longitude: coordinates[2].longitude)
                .distance(from: endpoint)
        assert(
            abs((RouteProgress.remainingDistance(from: firstCorner, in: step) ?? -1) - expectedAfterCorner) < 2,
            "step remaining sums the route geometry after the nearest projection"
        )

        let offRouteNearCorner = CLLocation(latitude: 37.0010, longitude: -122.0005)
        assert(
            abs((RouteProgress.remainingDistance(from: offRouteNearCorner, in: step) ?? -1) - expectedAfterCorner) < 2,
            "step remaining projects nearby off-route locations onto the step geometry"
        )
    }

    static func testStepRemainingDistanceResolvesAmbiguousGeometry() {
        let crossingCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9990),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000)
        ]
        let crossingStep = TestRouteStep(instructions: "Continue", coordinates: crossingCoordinates)
        let crossing = CLLocation(latitude: 37.0005, longitude: -121.9995)
        let finalSegmentStart = CLLocation(
            latitude: crossingCoordinates[2].latitude,
            longitude: crossingCoordinates[2].longitude
        )
        let finalEndpoint = CLLocation(
            latitude: crossingCoordinates[3].latitude,
            longitude: crossingCoordinates[3].longitude
        )
        let preferredBeforeCrossing = finalSegmentStart.distance(from: finalEndpoint)
        let expectedAfterCrossing = crossing.distance(from: finalEndpoint)

        let ambiguousRemaining = RouteProgress.remainingDistance(from: crossing, in: crossingStep)
        let progressAwareRemaining = RouteProgress.remainingDistance(
            from: crossing,
            in: crossingStep,
            preferredRemainingDistance: preferredBeforeCrossing
        )
        assert(
            (ambiguousRemaining ?? 0) > expectedAfterCrossing * 3,
            "an unqualified crossing projection selects the earlier route occurrence"
        )
        assert(
            abs((progressAwareRemaining ?? -1) - expectedAfterCrossing) < 3,
            "prior progress keeps a crossing projection on the later route occurrence"
        )

        let parallelCoordinates = [
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -122.0000),
            CLLocationCoordinate2D(latitude: 37.0010, longitude: -121.9999),
            CLLocationCoordinate2D(latitude: 37.0000, longitude: -121.9999)
        ]
        let parallelStep = TestRouteStep(instructions: "Continue", coordinates: parallelCoordinates)
        let noisyFirstLegLocation = CLLocation(latitude: 37.0005, longitude: -121.99994)
        let nearestOnlyRemaining = RouteProgress.remainingDistance(
            from: noisyFirstLegLocation,
            in: parallelStep
        )
        let continuousRemaining = RouteProgress.remainingDistance(
            from: noisyFirstLegLocation,
            in: parallelStep,
            preferredRemainingDistance: parallelStep.distance
        )
        assert(
            (continuousRemaining ?? 0) > (nearestOnlyRemaining ?? 0) + 80,
            "prior progress prevents GPS noise from jumping to a close parallel return leg"
        )
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

    @MainActor
    static func testSavedDestinationStore() {
        let migrationSuiteName = "SavedDestinationStoreTests.Migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: migrationSuiteName) else {
            assert(false, "destination store test defaults should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: migrationSuiteName) }

        defaults.set([" Cafe ", "Park"], forKey: "routeInput.recentDestinationSearches")
        let store = SavedDestinationStore(defaults: defaults, recentLimit: 2)
        assertEqual(store.recentDestinations.map(\.name), ["Cafe", "Park"], "legacy recents migrate in order")

        let coordinate = CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
        let droppedPin = SavedDestination(name: "1 Example Road, Singapore", coordinate: coordinate)
        store.addRecent(droppedPin)
        assertEqual(store.recentDestinations.map(\.name), [droppedPin.name, "Cafe"], "map pin joins bounded recents")
        assertCoordinate(
            store.recentDestinations[0].coordinate!,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            "recent map pin retains its exact coordinate"
        )

        assert(store.toggleFavorite(droppedPin), "destination can be saved as a favorite")
        assert(store.isFavorite(droppedPin), "saved destination reports favorite state")
        assertEqual(store.nonFavoriteRecentDestinations.map(\.name), ["Cafe"], "favorites are not duplicated in recents UI")

        let restoredStore = SavedDestinationStore(defaults: defaults, recentLimit: 2)
        assertEqual(restoredStore.favoriteDestinations.map(\.name), [droppedPin.name], "favorites persist")
        assertCoordinate(
            restoredStore.recentDestinations[0].coordinate!,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            "recent map pin coordinate persists"
        )
        assertCoordinate(
            restoredStore.favoriteDestinations[0].coordinate!,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            "favorite retains its exact coordinate"
        )

        restoredStore.addRecent(SavedDestination(name: "Cafe"))
        restoredStore.addRecent(droppedPin)
        assertEqual(
            restoredStore.recentDestinations.map(\.name),
            [droppedPin.name, "Cafe"],
            "reusing a destination promotes it without creating a duplicate"
        )

        defaults.set(["Library", droppedPin.name], forKey: "routeInput.recentDestinationSearches")
        let upgradedStore = SavedDestinationStore(defaults: defaults, recentLimit: 2)
        assertEqual(
            upgradedStore.recentDestinations.map(\.name),
            ["Library", droppedPin.name],
            "a newer legacy write survives app downgrade and re-upgrade"
        )
        assertCoordinate(
            upgradedStore.recentDestinations[1].coordinate!,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            "legacy reconciliation preserves the stored exact coordinate"
        )

        assert(!upgradedStore.toggleFavorite(droppedPin), "favorite can be removed")
        let unfavoritedStore = SavedDestinationStore(defaults: defaults, recentLimit: 2)
        assert(!unfavoritedStore.isFavorite(droppedPin), "favorite removal persists")
        assertEqual(
            unfavoritedStore.nonFavoriteRecentDestinations.map(\.name),
            ["Library", droppedPin.name],
            "removed favorites reappear in recent destinations"
        )

        let identitySuiteName = "SavedDestinationStoreTests.Identity.\(UUID().uuidString)"
        guard let identityDefaults = UserDefaults(suiteName: identitySuiteName) else {
            assert(false, "destination identity test defaults should be available")
            return
        }
        defer { identityDefaults.removePersistentDomain(forName: identitySuiteName) }

        let firstEntrance = SavedDestination(
            name: "Central Plaza Entrance",
            coordinate: CLLocationCoordinate2D(latitude: 31.23040, longitude: 121.47370)
        )
        let secondEntrance = SavedDestination(
            name: "Central Plaza Entrance",
            coordinate: CLLocationCoordinate2D(latitude: 31.23140, longitude: 121.47470)
        )
        let identityStore = SavedDestinationStore(defaults: identityDefaults, recentLimit: 3)
        identityStore.addRecent(firstEntrance)
        identityStore.addRecent(secondEntrance)
        assertEqual(identityStore.recentDestinations.count, 2, "same-name exact pins coexist in recents")
        assertCoordinate(
            identityStore.recentDestinations[0].coordinate!,
            latitude: secondEntrance.coordinate!.latitude,
            longitude: secondEntrance.coordinate!.longitude,
            "newer same-name pin keeps its own coordinate"
        )
        assertCoordinate(
            identityStore.recentDestinations[1].coordinate!,
            latitude: firstEntrance.coordinate!.latitude,
            longitude: firstEntrance.coordinate!.longitude,
            "older same-name pin keeps its own coordinate"
        )

        assert(identityStore.toggleFavorite(firstEntrance), "first same-name pin can be favorited")
        assert(identityStore.toggleFavorite(secondEntrance), "second same-name pin can be favorited independently")
        assertEqual(identityStore.favoriteDestinations.count, 2, "same-name exact pins coexist in favorites")
        assert(!identityStore.toggleFavorite(secondEntrance), "second same-name favorite can be removed independently")
        assert(identityStore.isFavorite(firstEntrance), "removing one same-name favorite keeps the other")
        assert(!identityStore.isFavorite(secondEntrance), "removed same-name favorite stays removed")
        assertEqual(
            identityDefaults.stringArray(forKey: "routeInput.recentDestinationSearches"),
            [firstEntrance.name],
            "legacy history remains duplicate-free for app downgrades"
        )

        let restoredIdentityStore = SavedDestinationStore(defaults: identityDefaults, recentLimit: 3)
        assertEqual(
            restoredIdentityStore.recentDestinations.count,
            2,
            "same-name exact pins both persist in structured recents"
        )
        assertCoordinate(
            restoredIdentityStore.recentDestinations[0].coordinate!,
            latitude: secondEntrance.coordinate!.latitude,
            longitude: secondEntrance.coordinate!.longitude,
            "newer same-name pin coordinate persists"
        )
        assertCoordinate(
            restoredIdentityStore.recentDestinations[1].coordinate!,
            latitude: firstEntrance.coordinate!.latitude,
            longitude: firstEntrance.coordinate!.longitude,
            "older same-name pin coordinate persists"
        )
        assertEqual(
            restoredIdentityStore.nonFavoriteRecentDestinations.count,
            1,
            "only the unfavorited exact pin appears in recent destinations"
        )
        assertCoordinate(
            restoredIdentityStore.nonFavoriteRecentDestinations[0].coordinate!,
            latitude: secondEntrance.coordinate!.latitude,
            longitude: secondEntrance.coordinate!.longitude,
            "the correct same-name pin reappears in recents"
        )

        switch restoredIdentityStore.nonFavoriteRecentDestinations[0].routeEndpoint {
        case .mapItem(let item):
            assertCoordinate(
                item.location.coordinate,
                latitude: secondEntrance.coordinate!.latitude,
                longitude: secondEntrance.coordinate!.longitude,
                "same-name saved pin routes to its own exact coordinate"
            )
        default:
            assert(false, "same-name saved pin should produce a map item endpoint")
        }

        let queryDestination = SavedDestination(name: firstEntrance.name)
        restoredIdentityStore.addRecent(queryDestination)
        assertEqual(
            restoredIdentityStore.recentDestinations.count,
            3,
            "query-only and exact same-name destinations remain independent"
        )
        assert(restoredIdentityStore.isFavorite(firstEntrance), "query insertion keeps the exact favorite")
        assert(!restoredIdentityStore.isFavorite(queryDestination), "query-only destination is not conflated with exact favorite")
        assertEqual(
            restoredIdentityStore.nonFavoriteRecentDestinations.count,
            2,
            "query-only and unfavorited exact pins both remain visible"
        )
        assertEqual(
            firstEntrance.coordinateSubtitle,
            "31.23040, 121.47370",
            "exact pins expose a stable visible coordinate disambiguator"
        )
        assert(queryDestination.coordinateSubtitle == nil, "query-only destinations omit the coordinate subtitle")

        assert(restoredIdentityStore.toggleFavorite(queryDestination), "query-only favorite can coexist with exact favorite")
        assertEqual(restoredIdentityStore.favoriteDestinations.count, 2, "mixed-representation favorites coexist")
        assert(!restoredIdentityStore.toggleFavorite(queryDestination), "query-only favorite removes independently")
        assert(restoredIdentityStore.isFavorite(firstEntrance), "removing query-only favorite preserves exact favorite")

        switch droppedPin.routeEndpoint {
        case .mapItem(let item):
            assertCoordinate(item.location.coordinate,
                             latitude: coordinate.latitude,
                             longitude: coordinate.longitude,
                             "saved map pin routes by coordinate")
        default:
            assert(false, "saved map pin should produce a map item endpoint")
        }

        switch SavedDestination(name: "Marina Bay").routeEndpoint {
        case .query(let query):
            assertEqual(query, "Marina Bay", "searched destination routes by query")
        default:
            assert(false, "searched destination should produce a query endpoint")
        }
    }

    static func testDestinationPickerProtocol() {
        let longName = String(repeating: "骑", count: 40)
        let favoriteCoordinate = CLLocationCoordinate2D(
            latitude: 1.30001,
            longitude: 103.80001
        )
        var favorites = [
            SavedDestination(name: longName, coordinate: favoriteCoordinate)
        ]
        favorites.append(contentsOf: (1..<10).map {
            SavedDestination(name: "Favorite \($0)")
        })
        let build = DeviceDestinationCatalogBuilder.build(
            favorites: favorites,
            generation: 17
        )
        assertEqual(build.payload.version, 1, "destination catalog has an explicit schema version")
        assertEqual(build.payload.generation, 17, "destination catalog preserves its generation")
        assertEqual(build.payload.items.count, 3, "destination catalog is capped to three favorites")
        assertEqual(build.payload.items.map(\.kind),
                    Array(repeating: .favorite, count: 3),
                    "the device catalog contains favorites only")
        assertEqual(build.destinationsByToken.count, 3,
                    "every visible token maps back to an exact saved destination")
        assert(build.payload.items[0].label.utf8.count <= 64,
               "multibyte destination labels are truncated at a valid UTF-8 boundary")
        assert(!build.payload.items[0].label.isEmpty,
               "UTF-8 truncation retains a useful destination label")
        assertEqual(DeviceDestinationCatalogBuilder.utf8Prefix("A\0B", maxBytes: 64),
                    "AB", "destination labels remove embedded nulls")
        assertEqual(DeviceDestinationCatalogBuilder.utf8Prefix("A\nB", maxBytes: 64),
                    "A B", "destination labels normalize embedded controls")
        let controlOnlyBuild = DeviceDestinationCatalogBuilder.build(
            favorites: [
                SavedDestination(name: "\u{1}\u{2}"),
                SavedDestination(name: "Valid favorite")
            ],
            generation: 17
        )
        assertEqual(controlOnlyBuild.payload.items.map(\.label),
                    ["Valid favorite"],
                    "favorites whose sanitized label is empty are omitted")
        assertEqual(DeviceDestinationCatalogGeneration.initial(randomValue: 0), 1,
                    "catalog generation zero is normalized away")
        assertEqual(DeviceDestinationCatalogGeneration.initial(randomValue: 99), 99,
                    "catalog generation preserves a randomized non-zero seed")
        assertEqual(DeviceDestinationCatalogGeneration.next(after: 99), 100,
                    "catalog generation advances after publication")
        assertEqual(DeviceDestinationCatalogGeneration.next(after: UInt32.max), 1,
                    "catalog generation wraps without emitting zero")
        assert(DeviceDestinationCatalogSyncPolicy.shouldPublish(
            force: false,
            lastFingerprint: nil,
            nextFingerprint: ""
        ), "an initial empty catalog is still published")
        assert(!DeviceDestinationCatalogSyncPolicy.shouldPublish(
            force: false,
            lastFingerprint: "",
            nextFingerprint: ""
        ), "an unchanged published empty catalog is not repeated")
        assert(DeviceDestinationCatalogSyncPolicy.shouldPublish(
            force: true,
            lastFingerprint: "same",
            nextFingerprint: "same"
        ), "a reconnect retry can force an unchanged catalog")
        assert(DeviceDestinationRequestTiming.locationRefreshTimeout <
               DeviceDestinationRequestTiming.appRequestDeadline,
               "location refresh leaves time for route calculation")
        assert(DeviceDestinationRequestTiming.appRequestDeadline <
               DeviceDestinationRequestTiming.firmwareRequestTimeout,
               "iOS terminates before the firmware request timeout")
        assert(DeviceDestinationStatusRetryPolicy.shouldRetry(afterAttempt: 0),
               "the first acknowledged status failure is retried")
        assert(!DeviceDestinationStatusRetryPolicy.shouldRetry(
            afterAttempt: DeviceDestinationStatusRetryPolicy.maximumRetryCount
        ), "status retries remain bounded")

        let now = Date()
        let freshLocation = CLLocation(
            coordinate: favoriteCoordinate,
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: 25,
            course: -1,
            speed: -1,
            timestamp: now.addingTimeInterval(-5)
        )
        let staleLocation = CLLocation(
            coordinate: favoriteCoordinate,
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: 25,
            course: -1,
            speed: -1,
            timestamp: now.addingTimeInterval(
                -(DeviceDestinationLocationPolicy.maximumAge + 1)
            )
        )
        let inaccurateLocation = CLLocation(
            coordinate: favoriteCoordinate,
            altitude: 0,
            horizontalAccuracy:
                DeviceDestinationLocationPolicy.maximumHorizontalAccuracy + 1,
            verticalAccuracy: 25,
            course: -1,
            speed: -1,
            timestamp: now
        )
        assert(DeviceDestinationLocationPolicy.isUsable(freshLocation, now: now),
               "a recent accurate fix can start a device route")
        assert(!DeviceDestinationLocationPolicy.isUsable(staleLocation, now: now),
               "a stale cached fix cannot start a device route")
        assert(!DeviceDestinationLocationPolicy.isUsable(inaccurateLocation, now: now),
               "an inaccurate fix cannot start a device route")

        guard let frames = DeviceDestinationCatalogChunker.frames(
            payload: build.payload,
            transferID: 9,
            maximumWriteLength: 20
        ) else {
            assert(false, "destination catalog should fit the bounded chunk protocol")
            return
        }
        assert(frames.count > 1, "minimum-MTU destination catalogs are chunked")
        assert(frames.allSatisfy { $0.count <= 20 },
               "every destination chunk respects the negotiated write length")
        for (index, frame) in frames.enumerated() {
            assertEqual(String(data: frame.prefix(4), encoding: .utf8), "DLST",
                        "destination chunk uses DLST prefix")
            assertEqual(frame[4], 9, "destination chunks share a transfer ID")
            assertEqual(frame[5], UInt8(index), "destination chunks are indexed in order")
            assertEqual(frame[6], UInt8(frames.count), "destination chunks declare the full count")
        }
        let encodedCatalog = frames.reduce(into: Data()) {
            $0.append($1.dropFirst(7))
        }
        let decodedCatalog = try? JSONDecoder().decode(
            DeviceDestinationCatalogPayload.self,
            from: encodedCatalog
        )
        assertEqual(decodedCatalog, build.payload,
                    "reassembled destination chunks decode to the original catalog")
        assert(DeviceDestinationCatalogChunker.frames(
            payload: build.payload,
            transferID: 1,
            maximumWriteLength: 7
        ) == nil, "a transport too small for the chunk header is rejected")
        let oversizedPayload = DeviceDestinationCatalogPayload(
            version: 1,
            generation: 18,
            items: [DeviceDestinationCatalogItem(
                token: 1,
                kind: .favorite,
                label: String(repeating: "x", count: 5000)
            )]
        )
        assert(DeviceDestinationCatalogChunker.frames(
            payload: oversizedPayload,
            transferID: 1,
            maximumWriteLength: 64
        ) == nil, "the sender enforces the firmware reassembly byte limit")

        let escapeHeavyFavorites = (1...3).map { index in
            SavedDestination(
                name: String(repeating: "\"", count: 63) + String(index)
            )
        }
        let escapeHeavyBuild = DeviceDestinationCatalogBuilder.build(
            favorites: escapeHeavyFavorites,
            generation: UInt32.max
        )
        let escapeHeavyFrames = DeviceDestinationCatalogChunker.frames(
            payload: escapeHeavyBuild.payload,
            transferID: 2,
            maximumWriteLength: 20
        )
        assert((escapeHeavyFrames?.count ?? Int.max) <=
               DeviceBLEProtocol.fallbackWriteQueueCapacity,
               "the bounded queue fits any valid three-favorite catalog at minimum MTU")

        var requestData = Data(DeviceBLEProtocol.destinationRequestPrefix.utf8)
        appendUInt32LE(17, to: &requestData)
        appendUInt16LE(3, to: &requestData)
        assertEqual(DeviceDestinationRequest.parse(requestData),
                    DeviceDestinationRequest(generation: 17, token: 3),
                    "DREQ parses generation and token little-endian")
        assert(DeviceDestinationRequest.parse(requestData.dropLast()) == nil,
               "truncated DREQ packets are rejected")

        let status = DeviceDestinationStatusPacketBuilder.data(
            generation: 17,
            token: 3,
            status: .failed,
            message: String(repeating: "é", count: 50)
        )
        assertEqual(String(data: status.prefix(4), encoding: .utf8), "DNST",
                    "destination status uses DNST prefix")
        assertEqual(readUInt32LE(status, offset: 4), 17,
                    "destination status includes the catalog generation")
        assertEqual(readUInt16LE(status, offset: 8), 3,
                    "destination status includes the selected token")
        assertEqual(status[10], DeviceDestinationStatusCode.failed.rawValue,
                    "destination status includes the state code")
        assert(status.dropFirst(11).count <= 64,
               "destination status messages are bounded on UTF-8 boundaries")
        let minimumMTUStatus = DeviceDestinationStatusPacketBuilder.data(
            generation: 17,
            token: 3,
            status: .failed,
            message: String(repeating: "é", count: 50),
            maximumLength: 20
        )
        assert(minimumMTUStatus.count <= 20,
               "destination status respects the negotiated write limit")
        assert(String(data: minimumMTUStatus.dropFirst(11), encoding: .utf8) != nil,
               "write-limit truncation preserves valid UTF-8")

        let manager = BLEManager()
        let capabilities = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8) +
            Data([DeviceBLEProtocol.destinationPickerCapabilityMask])
        assert(manager.handleDeviceCapabilitiesNotification(capabilities),
               "destination picker capability response is consumed")
        assert(manager.supportsDestinationPicker,
               "capability bit 6 enables destination catalog synchronization")

        var receivedRequest: DeviceDestinationRequest?
        manager.onDestinationRequest = { receivedRequest = $0 }
        assert(manager.handleNavigationCharacteristicNotification(requestData),
               "DREQ notification is consumed before other control frames")
        assert(receivedRequest == nil,
               "DREQ is not dispatched before authentication completes")

        manager.isConnected = true
        manager.isNavigationReady = true
        assert(manager.handleNavigationCharacteristicNotification(requestData),
               "authenticated DREQ notification is consumed")
        assertEqual(receivedRequest,
                    DeviceDestinationRequest(generation: 17, token: 3),
                    "BLE manager forwards the exact authenticated device selection")

        var writes: [Data] = []
        let managerFrames = DeviceDestinationCatalogChunker.frames(
            payload: build.payload,
            transferID: 1,
            maximumWriteLength: 64
        )!
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { writes.append($0) }
        ))
        assert(manager.sendDestinationCatalog(build.payload),
               "BLE manager queues a complete fallback destination catalog")
        assert(waitForMainLoop(timeout: 3) { writes.count == managerFrames.count },
               "BLE manager drains every catalog frame")
        assert(writes.allSatisfy {
            String(data: $0.prefix(4), encoding: .utf8) == "DLST"
        }, "fallback catalog frames stay explicitly framed")

        let reconnectManager = BLEManager()
        reconnectManager.isConnected = true
        reconnectManager.isNavigationReady = true
        var reconnectWrites: [Data] = []
        reconnectManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 20,
            canSend: { true },
            write: { reconnectWrites.append($0) }
        ))
        assert(reconnectManager.sendDestinationStatus(
            generation: 17,
            token: 3,
            status: .calculating,
            message: "Starting navigation..."
        ), "a retained-catalog request can be answered before CAPS completes")
        assertEqual(String(data: reconnectWrites.first?.prefix(4) ?? Data(), encoding: .utf8),
                    "DNST", "the pre-capability reconnect reply uses DNST")

        let retryManager = BLEManager()
        retryManager.isConnected = true
        retryManager.isNavigationReady = true
        var retryTransportReady = true
        var statusRetryWrites: [Data] = []
        retryManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            expectsWriteResponse: true,
            canSend: { retryTransportReady },
            write: { data in
                statusRetryWrites.append(data)
                retryTransportReady = false
            }
        ))
        assert(retryManager.sendDestinationStatus(
            generation: 17,
            token: 3,
            status: .failed,
            message: "Could not start navigation"
        ), "an acknowledged destination status is initially queued")
        assertEqual(statusRetryWrites.count, 1,
                    "the first status attempt reaches the transport")
        let simulatedWriteError = NSError(
            domain: "DestinationStatusRetryTests",
            code: 1
        )
        retryTransportReady = true
        retryManager.completeNavigationWriteForTesting(error: simulatedWriteError)
        assert(waitForMainLoop(timeout: 3) { statusRetryWrites.count == 2 },
               "a delegate-equivalent write error retries the latest status")
        retryTransportReady = true
        retryManager.completeNavigationWriteForTesting(error: simulatedWriteError)
        assert(waitForMainLoop(timeout: 3) { statusRetryWrites.count == 3 },
               "a second acknowledged failure uses the final bounded retry")
        retryTransportReady = true
        retryManager.completeNavigationWriteForTesting(error: simulatedWriteError)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        assertEqual(statusRetryWrites.count, 3,
                    "status retry exhaustion does not loop indefinitely")
        assert(statusRetryWrites.dropFirst().allSatisfy {
            $0 == statusRetryWrites.first
        }, "status retries preserve the exact terminal response")
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

    static func testOfflineMapOnboardingPolicy() {
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: false,
                isLocationAuthorized: false,
                isNavigationReady: false,
                hasSDCard: nil,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.location),
            "first launch starts with location"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: false,
                isNavigationReady: false,
                hasSDCard: nil,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.device),
            "skipping location advances directly to device connection"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: false,
                isLocationAuthorized: true,
                isNavigationReady: false,
                hasSDCard: nil,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.device),
            "authorizing location advances directly to device connection"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: false,
                isNavigationReady: true,
                hasSDCard: nil,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.checkingDevice),
            "the modal remains visible while connected map status loads"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: false,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.download),
            "a connected device with no map advances to download even when location was skipped"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: false,
                activeMapId: "",
                confirmedDeviceMapMissing: false
            ),
            .step(.storageUnavailable),
            "missing storage keeps onboarding visible with recovery guidance"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "installed-map",
                confirmedDeviceMapMissing: false
            ),
            .completeFirstRun,
            "an installed map completes first-run onboarding"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                confirmedDeviceMapMissing: true
            ),
            .step(.download),
            "later confirmed map loss still offers download"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasAdvancedPastLocation: true,
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "installed-map",
                confirmedDeviceMapMissing: false
            ),
            .hidden,
            "completed onboarding stays hidden while maps are available"
        )

        assert(
            OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                mapFoundForCurrentLocation: false
            ),
            "a ready device with no installed map offers the download onboarding"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "custom-map-6354c43431",
                mapFoundForCurrentLocation: false
            ),
            "an installed map suppresses onboarding even outside its current coverage"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                mapFoundForCurrentLocation: nil
            ),
            "unknown device coverage does not show a premature download prompt"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                mapFoundForCurrentLocation: true
            ),
            "current map coverage suppresses onboarding"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: false,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                mapFoundForCurrentLocation: false
            ),
            "the device-specific prompt waits for location authorization"
        )
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
            sourceRegionName: String? = nil,
            artifacts: [OfflineMapArtifact]? = nil,
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
            if let sourceRegionName {
                payload["sourceRegion"] = [
                    "id": "geofabrik-asia-china",
                    "name": sourceRegionName,
                    "provider": "geofabrik",
                ]
            }
            if let artifacts {
                payload["artifacts"] = try! JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(artifacts)
                )
            }
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
            displayName: String = "Recovery Test",
            storedMapData: Data = Data([0x01]),
            hashedMapData: Data? = nil
        ) -> Data {
            let mapPath = "VECTMAP/0/0/0.pbf"
            let declaredData = hashedMapData ?? storedMapData
            let manifest = try! JSONSerialization.data(withJSONObject: [
                "mapId": mapId,
                "displayName": displayName,
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
            defaults: persistedDefaults
        )
        persistedDefaults.set("https://current-setting.example", forKey: "offlineMap.serverURL")
        persistedDefaults.set("legacy-shared-token", forKey: "offlineMap.apiToken")
        persistedDefaults.set("legacy-job-token", forKey: "offlineMap.activeJobAPIToken")
        var persistedDownloadCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/map-jobs/job-persisted" {
                return (
                    200,
                    jobData(
                        jobId: "job-persisted",
                        mapId: "map-persisted",
                        sourceRegionName: "China"
                    )
                )
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
                try packData(
                    mapId: "map-persisted",
                    displayName: "COVID-19 Rides"
                ).write(to: url)
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
        if let downloadedURL = persistedManager.downloadedPackURL {
            assertEqual(
                persistedManager.displayName(forCachedPack: downloadedURL),
                "COVID-19 Rides",
                "legacy ZIP download preserves an explicit manifest name over its source"
            )
        } else {
            assert(false, "persisted recovery should expose its downloaded ZIP")
        }
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
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer legacy-job-token"
            },
            "persisted custom-server recovery uses its migrated scoped bearer credential"
        )
        assert(
            persistedDefaults.object(forKey: "offlineMap.apiToken") == nil &&
                persistedDefaults.object(forKey: "offlineMap.activeJobAPIToken") == nil,
            "app launch removes previously persisted shared API credentials"
        )
        try! OfflineMapInstallationCredentialStore(defaults: persistedDefaults).save(
            OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
                clientInstallationToken: "v1." + String(repeating: "A", count: 43)
            ),
            serverURLString: "https://persisted.example"
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

        let signedFixtureURL = URL(
            fileURLWithPath: "backend/tests/fixtures/map_stream_v1_golden.txt"
        )
        let signedFixtureText = try! String(contentsOf: signedFixtureURL, encoding: .utf8)
        let signedFixture = Dictionary(
            uniqueKeysWithValues: signedFixtureText.split(separator: "\n").map { line in
                let parts = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                return (String(parts[0]), String(parts[1]))
            }
        )
        let signedStream = Data(hex: signedFixture["stream_hex"]!)!
        let signedPublicKey = Data(hex: signedFixture["public_key_x963_hex"]!)!
        let signedPublicKeyHash = FirmwareUpdateManager.sha256Hex(signedPublicKey)
        let signedArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "golden-map.bmap",
            objectKey: "maps/golden-map/bike-map-stream-v1/map-test-2026-01/" +
                "\(signedPublicKeyHash)/\(String(repeating: "1", count: 64))/" +
                "\(String(repeating: "2", count: 64))/" +
                "\(signedFixture["signed_manifest_receipt"]!).bmap",
            bytes: Int64(signedStream.count),
            sha256: FirmwareUpdateManager.sha256Hex(signedStream),
            manifestReceipt: signedFixture["manifest_receipt"],
            signedManifestReceipt: signedFixture["signed_manifest_receipt"],
            signatureKeyId: "map-test-2026-01",
            signatureKeySha256: signedPublicKeyHash,
            producerBuildSha256: String(repeating: "1", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "2", count: 64),
            requiredIosBuild: "100",
            requiredIosGitSha: String(repeating: "a", count: 40),
            requiredIosBuildSha256: String(repeating: "b", count: 64),
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil
        )
        let signedTrustStore = BikeMapStreamTrustStore(publicKeysByID: [
            "map-test-2026-01": signedPublicKey,
        ])

        func runSignedRecovery(
            jobID: String,
            userDefinedName: String?
        ) async {
            let suite = "offline-map-signed-recovery-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
                "offline-map-signed-recovery-cache-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: cache) }
            try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

            let serverURL = "https://signed-recovery.example"
            let credential = OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
                clientInstallationToken: "v1." + String(repeating: "A", count: 43)
            )
            let refreshedCredential = OfflineMapInstallationCredential(
                clientInstallationId: credential.clientInstallationId,
                clientInstallationToken: "v1." + String(repeating: "B", count: 43)
            )
            try! OfflineMapInstallationCredentialStore(defaults: defaults).save(
                credential,
                serverURLString: serverURL
            )
            defaults.set(serverURL, forKey: "offlineMap.serverURL")
            OfflineMapJobPersistence.save(
                jobId: jobID,
                serverURLString: serverURL,
                defaults: defaults
            )

            let legacyURL = cache.appendingPathComponent("golden-map.zip")
            if let userDefinedName {
                try! packData(mapId: "golden-map", displayName: "Golden Map")
                    .write(to: legacyURL)
                defaults.set(
                    [legacyURL.lastPathComponent: userDefinedName],
                    forKey: "offlineMap.packDisplayNames"
                )
                try! SavedMapArtifactMetadataStore.save(
                    SavedMapArtifactMetadata(
                        schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
                        mapID: "golden-map",
                        displayName: userDefinedName,
                        localArtifactFilename: legacyURL.lastPathComponent,
                        streamFormatVersion: nil,
                        jobID: "older-job",
                        serverURLString: serverURL,
                        clientInstallationID: credential.clientInstallationId,
                        primaryArtifact: nil,
                        legacyArtifact: nil,
                        lastTransferProtocol: nil,
                        lastTransferStreamFormat: nil,
                        lastTransferSessionID: nil,
                        lastBackgroundTaskID: nil,
                        lastDeviceSequence: nil,
                        lastDeviceState: nil,
                        lastDeviceStep: nil,
                        lastDeviceStepCount: nil,
                        lastDeviceProgress: nil,
                        expectedActiveMapID: "golden-map",
                        expectedActiveSessionID: nil,
                        lastTransferOutcome: nil,
                        userDefinedDisplayName: true
                    ),
                    for: legacyURL
                )
            }

            OfflineMapTestURLProtocol.configure { request in
                switch request.url?.path {
                case "/v1/installations":
                    assertEqual(
                        request.value(forHTTPHeaderField: "X-Installation-Token"),
                        credential.clientInstallationToken,
                        "recovery refreshes its persisted installation token"
                    )
                    return (200, try! JSONEncoder().encode(refreshedCredential))
                case "/v1/map-jobs/\(jobID)":
                    return (
                        200,
                        jobData(
                            jobId: jobID,
                            mapId: "golden-map",
                            sourceRegionName: "China",
                            artifacts: [signedArtifact]
                        )
                    )
                case "/v1/map-packs/golden-map/artifacts/bike-map-stream-v1/download-url":
                    var response = try! JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(signedArtifact)
                    ) as! [String: Any]
                    response["url"] = "/immutable/golden-map.bmap"
                    response["expiresAt"] = 2_000_000_000
                    response["expiresInSeconds"] = 900
                    return (200, try! JSONSerialization.data(withJSONObject: response))
                case "/v1/map-jobs":
                    return (200, try! JSONSerialization.data(withJSONObject: ["jobs": []]))
                case "/v1/map-jobs/\(jobID)/downloads",
                     "/v1/map-jobs/\(jobID)/display-name":
                    return (
                        200,
                        try! JSONSerialization.data(withJSONObject: [
                            "jobId": jobID,
                            "downloadCount": 1,
                        ])
                    )
                default:
                    return (404, Data())
                }
            }
            let manager = OfflineMapManager(
                defaults: defaults,
                mapPlatformSession: session,
                cacheDirectory: cache,
                mapStreamTrustStore: signedTrustStore,
                packDownload: { _, _, onProgress, _ in
                    onProgress(1)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("bmap")
                    try signedStream.write(to: url)
                    return url
                }
            )
            manager.resumePendingMapJobIfNeeded()
            let signedRecoveryCompleted = await waitForMapTaskCompletion(manager)
            assert(
                signedRecoveryCompleted,
                "signed BMAP recovery should complete"
            )
            assertEqual(
                OfflineMapInstallationCredentialStore(defaults: defaults).load(
                    serverURLString: serverURL
                ),
                refreshedCredential,
                "recovery persists the current installation token"
            )
            guard let downloadedURL = manager.downloadedPackURL else {
                assert(false, "signed BMAP recovery should publish its downloaded artifact")
                return
            }
            assertEqual(
                downloadedURL.pathExtension,
                "bmap",
                "signed recovery publishes the canonical BMAP extension"
            )
            let expectedName = userDefinedName ?? "Golden Map"
            assertEqual(
                manager.displayName(forCachedPack: downloadedURL),
                expectedName,
                userDefinedName == nil
                    ? "signed manifest displayName outranks the source-region fallback"
                    : "signed replacement preserves an explicit user name"
            )
            let downloadedMetadata = SavedMapArtifactMetadataStore.load(for: downloadedURL)
            assertEqual(
                downloadedMetadata?.displayName,
                expectedName,
                "signed recovery persists the resolved display name"
            )
            assertEqual(
                downloadedMetadata?.userDefinedDisplayName,
                userDefinedName != nil,
                "signed replacement preserves display-name provenance"
            )
            assertEqual(
                downloadedMetadata?.primaryArtifact,
                signedArtifact,
                "signed recovery persists the verified stream artifact"
            )
            assert(
                OfflineMapTestURLProtocol.requests().contains {
                    $0.url?.path ==
                        "/v1/map-packs/golden-map/artifacts/bike-map-stream-v1/download-url"
                },
                "signed recovery exercises the immutable artifact URL path"
            )
            if userDefinedName != nil {
                assert(
                    !FileManager.default.fileExists(atPath: legacyURL.path),
                    "signed replacement removes the obsolete ZIP"
                )
                assert(
                    SavedMapArtifactMetadataStore.load(for: legacyURL) == nil,
                    "signed replacement removes the obsolete ZIP metadata"
                )
                assert(
                    defaults.dictionary(forKey: "offlineMap.packDisplayNames")?[
                        legacyURL.lastPathComponent
                    ] == nil,
                    "signed replacement removes the obsolete ZIP display-name entry"
                )
            }
        }

        await runSignedRecovery(jobID: "job-signed-name", userDefinedName: nil)
        await runSignedRecovery(
            jobID: "job-signed-replacement",
            userDefinedName: "Weekend Ride"
        )

        let managedSuite = "offline-map-managed-token-route-\(UUID().uuidString)"
        let managedDefaults = UserDefaults(suiteName: managedSuite)!
        defer { managedDefaults.removePersistentDomain(forName: managedSuite) }
        let managedCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-managed-token-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedCache) }
        OfflineMapJobPersistence.save(
            jobId: "job-managed-token",
            serverURLString: "https://maps.8o.vc:443/",
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
        assert(managedCompleted, "managed-server recovery should complete without a bundled secret")
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == URL(string: OfflineMapServiceConfig.productionServerURLString)?.host &&
                    $0.value(forHTTPHeaderField: "Authorization") == nil
            },
            "managed-server recovery uses the production endpoint without global authorization"
        )
        assert(
            managedDefaults.object(forKey: "offlineMap.apiToken") == nil &&
                managedDefaults.object(forKey: "offlineMap.activeJobAPIToken") == nil,
            "managed-server recovery removes stale shared credentials"
        )
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host != "unrelated-custom.example"
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
        assert(rotatedCustomCompleted, "same-origin custom recovery should preserve its scoped token")
        assert(
            OfflineMapTestURLProtocol.requests().allSatisfy {
                $0.url?.host == "custom-rotation.example" &&
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-custom-token"
            },
            "same-origin custom recovery uses its migrated bearer credential"
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
        let originalDownloadRetryMetadata = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": SavedMapArtifactMetadata.currentSchemaVersion,
            "mapID": "map-download-retry",
            "displayName": "Shanghai Riverside",
            "localArtifactFilename": downloadRetryPack.lastPathComponent,
            "userDefinedDisplayName": true,
        ])
        try! originalDownloadRetryMetadata.write(
            to: SavedMapArtifactMetadataStore.metadataURL(for: downloadRetryPack)
        )
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
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: downloadRetryPack)?.displayName,
            "Shanghai Riverside",
            "same-map replacement persists the user rename in artifact metadata"
        )
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: downloadRetryPack)?.userDefinedDisplayName,
            true,
            "same-map replacement preserves explicit user-name provenance"
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

        let deferred401Suite = "offline-map-deferred-refresh-401-\(UUID().uuidString)"
        let deferred401Defaults = UserDefaults(suiteName: deferred401Suite)!
        defer { deferred401Defaults.removePersistentDomain(forName: deferred401Suite) }
        let deferred401Server = "https://deferred-refresh-401.example"
        let staleCredential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
            clientInstallationToken: "v1." + String(repeating: "A", count: 43)
        )
        let replacementCredential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_abcdef1234567890abcdef1234567890",
            clientInstallationToken: "v1." + String(repeating: "B", count: 43)
        )
        deferred401Defaults.set(deferred401Server, forKey: "offlineMap.serverURL")
        try! OfflineMapInstallationCredentialStore(defaults: deferred401Defaults).save(
            staleCredential,
            serverURLString: deferred401Server
        )
        OfflineMapInstallationRefreshBackoff.deferRefresh(
            serverURLString: deferred401Server,
            defaults: deferred401Defaults
        )
        var deferred401RegistrationCount = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/installations" {
                deferred401RegistrationCount += 1
                if request.url?.query != nil {
                    return (401, Data("retired installation token".utf8))
                }
                return (200, try! JSONEncoder().encode(replacementCredential))
            }
            if request.url?.path == "/v1/map-jobs" {
                if request.value(forHTTPHeaderField: "X-Installation-Token") ==
                    staleCredential.clientInstallationToken {
                    return (401, Data("retired installation token".utf8))
                }
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: ["jobs": []])
                )
            }
            return (404, Data())
        }
        let deferred401Manager = OfflineMapManager(
            defaults: deferred401Defaults,
            mapPlatformSession: session
        )
        deferred401Manager.resumePendingMapJobIfNeeded()
        let deferred401Deadline = Date().addingTimeInterval(3)
        var deferred401Completed = false
        while Date() < deferred401Deadline {
            let savedCredential = OfflineMapInstallationCredentialStore(
                defaults: deferred401Defaults
            ).load(serverURLString: deferred401Server)
            if savedCredential == replacementCredential && !deferred401Manager.isBusy {
                deferred401Completed = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(deferred401Completed, "deferred refresh recovers when its token is retired")
        assertEqual(
            deferred401RegistrationCount,
            2,
            "401 validation bypasses backoff, then issues one replacement credential"
        )
        assertEqual(
            OfflineMapInstallationCredentialStore(defaults: deferred401Defaults).load(
                serverURLString: deferred401Server
            ),
            replacementCredential,
            "401 during refresh backoff persists a usable replacement credential"
        )

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
            jobRequest: request
        ) else {
            assert(false, "create job URL request should build")
            return
        }
        assertEqual(urlRequest.url?.absoluteString, "https://maps.example.com/api/v1/map-jobs", "create job URL appends API path")
        assert(
            urlRequest.value(forHTTPHeaderField: "Authorization") == nil,
            "create job request contains no shared authorization token"
        )
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
        assert(request.value(forHTTPHeaderField: "Authorization") == nil,
               "list jobs request contains no shared authorization token")
        guard let jobRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            path: "/v1/map-jobs/job-12345678",
            method: "GET",
            clientInstallationId: "installation-test"
        ),
        let downloadRequest = try? OfflineMapPlatformClient.makeInstallationScopedURLRequest(
            baseURL: baseURL,
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
                clientInstallationId: "installation-test",
                jobId: "job-12345678",
                displayName: "Shanghai and Suzhou"
              ),
              let downloadReceiptRequest = try? OfflineMapPlatformClient.makeRecordDownloadURLRequest(
                baseURL: baseURL,
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
        assert(displayNameRequest.value(forHTTPHeaderField: "Authorization") == nil,
               "display name update contains no shared authorization token")
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
        assert(downloadReceiptRequest.value(forHTTPHeaderField: "Authorization") == nil,
               "download receipt contains no shared authorization token")
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
        OfflineMapSharedSecretMigration.removeLegacyValues(defaults: defaults)
        assert(
            defaults.object(forKey: "offlineMap.apiToken") == nil,
            "app launch removes the legacy shared map API token"
        )
    }

    static func testSavedMapDefaultNamePolicy() {
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "custom-map-4dc48b9bcb",
                sourceRegionName: "China",
                mapID: "custom-map-4dc48b9bcb"
            ),
            "China",
            "a generated artifact ID never outranks the Geofabrik area name"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "Shanghai Suzhou",
                sourceRegionName: "China",
                mapID: "shanghai-suzhou"
            ),
            "Shanghai Suzhou",
            "an explicit pack name still outranks the source area"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "COVID-19 Rides",
                sourceRegionName: "China",
                mapID: "covid-19-rides"
            ),
            "COVID-19 Rides",
            "explicit artifact punctuation and casing are preserved"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "gravel loop",
                sourceRegionName: "China",
                mapID: "gravel-loop"
            ),
            "gravel loop",
            "explicit lowercase artifact names are preserved"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.preferredSourceName("china-latest.osm.pbf"),
            "China",
            "legacy Geofabrik filenames become readable area names"
        )
        assert(
            !SavedMapDisplayNamePolicy.isGeneratedGenericName("custom-map-weekend"),
            "a user label sharing the old prefix is not mistaken for a generated ID"
        )
        assertEqual(
            SavedMapDisplayNamePolicy.resolve(
                artifactDisplayName: "custom-map-deadbeef00",
                sourceRegionName: nil,
                mapID: "custom-map-deadbeef00"
            ),
            "Offline Map",
            "generic IDs are never shown even when legacy metadata has no source"
        )
    }

    @MainActor
    static func testOfflineMapManagerRepairsGeneratedPackDefaults() {
        let suite = "offline-map-default-repair-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "default repair test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-default-repair-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let mapID = "custom-map-4dc48b9bcb"
        let packURL = cacheDirectory.appendingPathComponent("\(mapID).zip")
        let sourceName = "Shanghai and Suzhou"
        let manifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": mapID,
            "displayName": mapID,
            "bounds": [120.90, 30.70, 121.95, 31.55],
            "source": [
                "provider": "geofabrik",
                "region": "geofabrik-asia-china",
                "name": sourceName,
                "url": "https://download.geofabrik.de/asia/china-latest.osm.pbf",
            ],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", manifest),
            ("VECTMAP/\(mapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: packURL)

        let explicitMapID = "marina-bay-rides-deadbeef00"
        let explicitPackURL = cacheDirectory.appendingPathComponent("\(explicitMapID).zip")
        let explicitManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": explicitMapID,
            "displayName": "COVID-19 Rides",
            "bounds": [103.80, 1.25, 103.90, 1.35],
            "source": [
                "provider": "geofabrik",
                "region": "geofabrik-asia-malaysia-singapore-brunei",
                "name": "Malaysia, Singapore, and Brunei",
            ],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", explicitManifest),
            ("VECTMAP/\(explicitMapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: explicitPackURL)

        let prefixedUserMapID = "custom-map-aabbccddee"
        let prefixedUserPackURL = cacheDirectory
            .appendingPathComponent("\(prefixedUserMapID).zip")
        let prefixedUserManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": prefixedUserMapID,
            "displayName": prefixedUserMapID,
            "bounds": [120.90, 30.70, 121.95, 31.55],
            "source": ["name": "China"],
        ])
        try! makeStoredZip(entries: [
            ("manifest.json", prefixedUserManifest),
            ("VECTMAP/\(prefixedUserMapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
        ]).write(to: prefixedUserPackURL)

        let streamMapID = "custom-map-cafebabe00"
        let streamPackURL = cacheDirectory.appendingPathComponent("\(streamMapID).bmap")
        let streamManifest = try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "mapId": streamMapID,
            "displayName": streamMapID,
            "boundsE7": [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000],
            "source": ["name": "Yangtze Delta"],
        ])
        try! makePreviewReadableBikeMapStream(manifest: streamManifest)
            .write(to: streamPackURL)
        defaults.set(
            [
                packURL.lastPathComponent: mapID,
                prefixedUserPackURL.lastPathComponent: "custom-map-weekend",
            ],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )

        assertEqual(
            manager.displayName(forCachedPack: packURL),
            sourceName,
            "restart repairs an old generated label from manifest source.name"
        )
        assertEqual(
            manager.displayName(forCachedPack: explicitPackURL),
            "COVID-19 Rides",
            "an explicit ZIP manifest name outranks and preserves source metadata"
        )
        assertEqual(
            manager.displayName(forCachedPack: prefixedUserPackURL),
            "custom-map-weekend",
            "a legacy user label sharing the generated prefix is preserved"
        )
        assertEqual(
            defaults.dictionary(forKey: "offlineMap.packDisplayNames")?[
                prefixedUserPackURL.lastPathComponent
            ] as? String,
            "custom-map-weekend",
            "repair does not rewrite a legacy user label that only shares the prefix"
        )
        assertEqual(
            manager.displayName(forCachedPack: streamPackURL),
            "Yangtze Delta",
            "a BMAP manifest source.name is used through the manager display path"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: packURL)?.bounds,
            OfflineMapPreviewBounds(coordinates: [120.90, 30.70, 121.95, 31.55]),
            "a preview-less legacy artifact still exposes bounds for local rendering"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: packURL)?.imageData,
            nil,
            "the bounds fallback does not pretend a legacy artifact embedded an image"
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
                managerSource.contains("OfflineMapPackPreviewReader.content(for: packURL)") &&
                managerSource.contains("OfflineMapFallbackPreviewRenderer.image") &&
                !managerSource.contains("packURLs.forEach(cachePreviewIfAvailable)"),
            "saved-map previews load lazily and render bounds when an old pack has no image"
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
            "boundsE7": [1_037_500_000, 12_400_000, 1_039_300_000, 13_700_000],
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
        let stream = makePreviewReadableBikeMapStream(manifest: manifest)
        let streamURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-map-preview-\(UUID().uuidString).bmap")
        try? stream.write(to: streamURL)
        defer { try? FileManager.default.removeItem(at: streamURL) }
        assertEqual(
            OfflineMapPackPreviewReader.imageData(for: streamURL),
            preview,
            "cached signed streams expose their inline boundary preview"
        )
        assertEqual(
            OfflineMapPackPreviewReader.content(for: streamURL)?.bounds,
            OfflineMapPreviewBounds(coordinates: [103.75, 1.24, 103.93, 1.37]),
            "cached signed streams retain bounds for the local thumbnail fallback"
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

        var atomicQueue = NavigationWriteQueue(maxCount: 3)
        atomicQueue.enqueue(NavigationWrite(data: Data([1]), label: "existing"))
        assert(!atomicQueue.enqueueAtomically([
            NavigationWrite(data: Data([2]), label: "chunk-1"),
            NavigationWrite(data: Data([3]), label: "chunk-2"),
            NavigationWrite(data: Data([4]), label: "chunk-3")
        ]), "an oversized logical message is rejected atomically")
        assertEqual(atomicQueue.count, 1,
                    "atomic rejection leaves existing queue traffic unchanged")
        assert(atomicQueue.enqueueAtomically([
            NavigationWrite(data: Data([2]), label: "chunk-1"),
            NavigationWrite(data: Data([3]), label: "chunk-2")
        ]), "a complete logical message fits in the remaining capacity")
        assertEqual(atomicQueue.remainingCapacity, 0,
                    "remaining queue capacity accounts for atomic writes")

        var protectedBatchQueue = NavigationWriteQueue(maxCount: 3)
        assert(protectedBatchQueue.enqueueAtomically([
            NavigationWrite(data: Data([1]), label: "catalog-1"),
            NavigationWrite(data: Data([2]), label: "catalog-2"),
            NavigationWrite(data: Data([3]), label: "catalog-3")
        ]), "a complete logical message can fill the queue")
        var overflowWasDropped = false
        assert(protectedBatchQueue.enqueue(NavigationWrite(
            data: Data([4]),
            label: "later-write",
            onDrop: { overflowWasDropped = true }
        )), "queue pressure reports a dropped regular write")
        var protectedWrites: [Data] = []
        protectedBatchQueue.flush(canSend: { true }) { protectedWrites.append($0.data) }
        assert(overflowWasDropped,
               "a later regular write is dropped when only atomic chunks are pending")
        assertEqual(protectedWrites, [Data([1]), Data([2]), Data([3])],
                    "later queue pressure cannot fragment an accepted atomic message")

        var rejectedCoalescingDropCount = 0
        var fullProtectedCoalescingQueue = NavigationWriteQueue(maxCount: 2)
        assert(fullProtectedCoalescingQueue.enqueueAtomically([
            NavigationWrite(data: Data([1]), label: "atomic-1"),
            NavigationWrite(data: Data([2]), label: "atomic-2"),
        ]), "an atomic batch fills the queue for coalescing rejection coverage")
        assert(!fullProtectedCoalescingQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([3]),
                label: "rejected-telemetry",
                onDrop: { rejectedCoalescingDropCount += 1 },
                coalescingKey: "workout-core"
            ),
            prioritized: false
        ), "a coalesced write reports rejection behind a full protected batch")
        assertEqual(rejectedCoalescingDropCount, 0,
                    "a never-admitted write does not also fire its queued-drop callback")
        assertEqual(fullProtectedCoalescingQueue.count, 2,
                    "coalescing rejection preserves the full atomic batch")

        var prioritizedQueue = NavigationWriteQueue(maxCount: 3)
        var droppedRegularWrite = false
        prioritizedQueue.enqueue(NavigationWrite(
            data: Data([1]),
            label: "regular-1",
            onDrop: { droppedRegularWrite = true }
        ))
        prioritizedQueue.enqueue(NavigationWrite(data: Data([2]), label: "regular-2"))
        prioritizedQueue.enqueue(NavigationWrite(data: Data([3]), label: "regular-3"))
        assert(prioritizedQueue.enqueuePrioritizedAtomically([
            NavigationWrite(data: Data([9]), label: "destination-status")
        ]), "a destination status uses its dedicated lane at bulk capacity")
        assert(!droppedRegularWrite,
               "priority admission does not evict ordinary traffic")
        assertEqual(prioritizedQueue.count, 4,
                    "the bounded priority lane is separate from bulk capacity")
        var prioritizedWrites: [Data] = []
        prioritizedQueue.flush(canSend: { true }) {
            prioritizedWrites.append($0.data)
        }
        assertEqual(prioritizedWrites,
                    [Data([9]), Data([1]), Data([2]), Data([3])],
                    "destination status is sent before queued ordinary traffic")

        var catalogAndStatusQueue = NavigationWriteQueue(maxCount: 3)
        assert(catalogAndStatusQueue.enqueueAtomically([
            NavigationWrite(data: Data([4]), label: "catalog-1"),
            NavigationWrite(data: Data([5]), label: "catalog-2"),
            NavigationWrite(data: Data([6]), label: "catalog-3")
        ]), "catalog batch can fill bulk capacity before priority traffic")
        var supersededStatusWasDropped = false
        assert(catalogAndStatusQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([8]),
                label: "calculating-status",
                onDrop: { supersededStatusWasDropped = true }
            )
        ]), "first priority status is admitted despite a full catalog lane")
        assert(catalogAndStatusQueue.enqueuePrioritizedAtomically([
            NavigationWrite(data: Data([9]), label: "terminal-status")
        ]), "new terminal status replaces an older queued status")
        assert(supersededStatusWasDropped,
               "priority replacement reports the superseded status")
        var catalogAndStatusWrites: [Data] = []
        catalogAndStatusQueue.flush(canSend: { true }) {
            catalogAndStatusWrites.append($0.data)
        }
        assertEqual(catalogAndStatusWrites,
                    [Data([9]), Data([4]), Data([5]), Data([6])],
                    "priority replacement preserves the complete catalog batch")

        var mixedPriorityQueue = NavigationWriteQueue(
            maxCount: 3,
            priorityMaxCount: 2
        )
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([7]),
            label: "workout-core",
            coalescingKey: "workout-telemetry-core"
        ), prioritized: true), "workout core uses one priority slot")
        var replacedDestinationStatusWasDropped = false
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([8]),
            label: "calculating-status",
            onDrop: { replacedDestinationStatusWasDropped = true },
            coalescingKey: "destination-status"
        ), prioritized: true), "calculating status uses the other priority slot")
        assert(mixedPriorityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([9]),
            label: "terminal-status",
            coalescingKey: "destination-status"
        ), prioritized: true), "terminal status replaces only its predecessor")
        assert(replacedDestinationStatusWasDropped,
               "capacity-two replacement reports the superseded status")
        var mixedPriorityWrites: [Data] = []
        mixedPriorityQueue.flush(canSend: { true }) {
            mixedPriorityWrites.append($0.data)
        }
        assertEqual(mixedPriorityWrites, [Data([7]), Data([9])],
                    "unrelated workout priority survives latest-status replacement")

        var catalogWriteFailureWasReported = false
        var failureTrackingQueue = NavigationWriteQueue(maxCount: 1)
        assert(failureTrackingQueue.enqueueAtomically([
            NavigationWrite(
                data: Data([7]),
                label: "catalog",
                onWriteFailure: { catalogWriteFailureWasReported = true }
            )
        ]), "catalog failure callback is accepted with the atomic batch")
        failureTrackingQueue.flush(canSend: { true }) { write in
            write.onWriteFailure?()
        }
        assert(catalogWriteFailureWasReported,
               "atomic batch protection preserves the transport failure callback")
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
        assertEqual(DeviceBLEProtocol.destinationCatalogChunkPrefix, "DLST", "destination catalogs use DLST chunks")
        assertEqual(DeviceBLEProtocol.destinationRequestPrefix, "DREQ", "device destination requests use DREQ")
        assertEqual(DeviceBLEProtocol.destinationStatusPrefix, "DNST", "destination route statuses use DNST")
        assertEqual(DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask, 4, "PWR honk acknowledgement uses capability bit 2")
        assertEqual(DeviceBLEProtocol.independentMapProfilesCapabilityMask, 8, "independent map profiles use capability bit 3")
        assertEqual(DeviceBLEProtocol.extendedMapVisibilityCapabilityMask, 16, "extended map visibility uses capability bit 4")
        assertEqual(DeviceBLEProtocol.batteryStatusScreenCapabilityMask, 32, "Battery Status support uses capability bit 5")
        assertEqual(DeviceBLEProtocol.destinationPickerCapabilityMask, 64, "destination picker support uses capability bit 6")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCapabilityMask, 128, "workout telemetry uses capability bit 7")
        assertEqual(DeviceBLEProtocol.deviceCapabilitiesVersion, 6, "capability version advertises workout telemetry support")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCharacteristicUUIDString,
                    "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003",
                    "workout telemetry uses the dedicated 128-bit characteristic")
        assertEqual(DeviceBLEProtocol.workoutTelemetryFallbackPrefix, "WTLM",
                    "workout telemetry fallback remains explicitly framed")
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

    static func workoutDeviceSample(
        state: WorkoutDeviceSessionState = .running,
        sessionToken: UInt16 = 0x1234,
        hasLiveNumerics: Bool = true,
        isCurrentSnapshot: Bool? = nil,
        elapsedSeconds: Double? = 3_661,
        distanceMeters: Double? = 12_345,
        speedMetersPerSecond: Double? = 12.34,
        currentHeartRateBPM: Double? = 157,
        averageHeartRateBPM: Double? = 148,
        activeEnergyKilocalories: Double? = 456.7,
        cyclingPowerWatts: Double? = 321,
        cyclingCadenceRPM: Double? = 87.6,
        currentHeartRateZone: UInt8? = 4,
        altitudeMeters: Double? = -12,
        heartRateZoneCount: UInt8? = 5,
        sourceFlags: WorkoutDeviceSourceFlags = [
            .pairedSpeedSensor,
            .watchSpeed,
            .healthKitDistance,
            .watchAltitude,
            .liveHealthKitZone,
        ]
    ) -> WorkoutDeviceTelemetrySample {
        WorkoutDeviceTelemetrySample(
            state: state,
            sessionToken: sessionToken,
            hasLiveNumerics: hasLiveNumerics,
            isCurrentSnapshot: isCurrentSnapshot ?? hasLiveNumerics,
            elapsedSeconds: elapsedSeconds,
            distanceMeters: distanceMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            currentHeartRateBPM: currentHeartRateBPM,
            averageHeartRateBPM: averageHeartRateBPM,
            activeEnergyKilocalories: activeEnergyKilocalories,
            cyclingPowerWatts: cyclingPowerWatts,
            cyclingCadenceRPM: cyclingCadenceRPM,
            currentHeartRateZone: currentHeartRateZone,
            altitudeMeters: altitudeMeters,
            heartRateZoneCount: heartRateZoneCount,
            sourceFlags: sourceFlags
        )
    }

    static func testWorkoutDeviceFrameVectors() {
        guard let frames = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        ) else {
            assert(false, "valid workout telemetry produces frames")
            return
        }
        assertEqual(frames.core, Data([
            0x01, 0x02, 0x34, 0x12,
            0x4D, 0x0E, 0x00, 0x00,
            0x39, 0x30, 0x00, 0x00,
            0xD2, 0x04, 0x9D, 0x00,
        ]), "core workout frame matches the protocol byte vector")
        assertEqual(frames.extended, Data([
            0x02, 0x3F, 0x34, 0x12,
            0x94, 0x00, 0xD7, 0x11,
            0x41, 0x01, 0x6C, 0x03,
            0x04, 0xF4, 0xFF, 0x05,
        ]), "extended workout frame matches the protocol byte vector")
        assertEqual(frames.core.count, 16, "core workout frame is exactly 16 bytes")
        assertEqual(frames.extended.count, 16, "extended workout frame is exactly 16 bytes")

        let maskedFlags = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            sourceFlags: WorkoutDeviceSourceFlags(rawValue: 0xFF)
        ))
        assertEqual(maskedFlags?.extended[1], 0x3F,
                    "pair-generation bits are assigned only by the relay scheduler")

        assertEqual(WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .running,
            sessionToken: 0
        )), nil, "active workout frames reject token zero")
        assertEqual(WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .idle,
            sessionToken: 1
        )), nil, "idle workout frames require token zero")
        let idle = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .idle,
            sessionToken: 0,
            hasLiveNumerics: false
        ))
        assertEqual(idle?.core[1], WorkoutDeviceSessionState.idle.rawValue,
                    "idle frame explicitly clears device workout state")
        assertEqual(readUInt16LE(idle?.core ?? Data(repeating: 0, count: 16), offset: 2), 0,
                    "idle clear frame carries token zero")
    }

    static func testWorkoutDeviceFrameSentinelsAndSaturation() {
        let unavailable = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            elapsedSeconds: -.infinity,
            distanceMeters: -1,
            speedMetersPerSecond: .nan,
            currentHeartRateBPM: 0,
            averageHeartRateBPM: -.infinity,
            activeEnergyKilocalories: -0.1,
            cyclingPowerWatts: .nan,
            cyclingCadenceRPM: -1,
            currentHeartRateZone: 6,
            altitudeMeters: .infinity,
            heartRateZoneCount: 5
        ))!
        assertEqual(readUInt32LE(unavailable.core, offset: 4), UInt32.max,
                    "non-finite elapsed time is unavailable")
        assertEqual(readUInt32LE(unavailable.core, offset: 8), UInt32.max,
                    "negative distance is unavailable")
        assertEqual(readUInt16LE(unavailable.core, offset: 12), UInt16.max,
                    "non-finite speed is unavailable")
        assertEqual(readUInt16LE(unavailable.core, offset: 14), UInt16.max,
                    "zero heart rate is unavailable")
        for offset in [4, 6, 8, 10] {
            assertEqual(readUInt16LE(unavailable.extended, offset: offset), UInt16.max,
                        "invalid extended UInt16 metric uses the sentinel")
        }
        assertEqual(unavailable.extended[12], 0,
                    "invalid current zone stays unavailable")
        assertEqual(readUInt16LE(unavailable.extended, offset: 13), 0x8000,
                    "invalid altitude uses Int16.min sentinel")
        assertEqual(unavailable.extended[15], 0,
                    "invalid zone count stays unavailable")
        assertEqual(unavailable.extended[1], 0x20,
                    "a current snapshot remains distinguishable when every metric is unavailable")

        let saturated = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            elapsedSeconds: Double(UInt32.max) * 2,
            distanceMeters: Double(UInt32.max) * 2,
            speedMetersPerSecond: Double(UInt16.max),
            currentHeartRateBPM: Double(UInt16.max) * 2,
            averageHeartRateBPM: Double(UInt16.max) * 2,
            activeEnergyKilocalories: 6_553.5,
            cyclingPowerWatts: Double(UInt16.max) * 2,
            cyclingCadenceRPM: Double(UInt16.max),
            altitudeMeters: Double(Int16.min)
        ))!
        assertEqual(readUInt32LE(saturated.core, offset: 4), UInt32.max - 1,
                    "elapsed time saturates below its sentinel")
        assertEqual(readUInt32LE(saturated.core, offset: 8), UInt32.max - 1,
                    "distance saturates below its sentinel")
        assertEqual(readUInt16LE(saturated.core, offset: 12), UInt16.max - 1,
                    "speed saturates below its sentinel")
        assertEqual(readUInt16LE(saturated.core, offset: 14), UInt16.max - 1,
                    "current heart rate saturates below its sentinel")
        for offset in [4, 6, 8, 10] {
            assertEqual(readUInt16LE(saturated.extended, offset: offset), UInt16.max - 1,
                        "extended values saturate below their sentinel")
        }
        assertEqual(readUInt16LE(saturated.extended, offset: 13), 0x8001,
                    "valid low altitude saturates above Int16.min")

        let stale = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            hasLiveNumerics: false
        ))!
        assertEqual(stale.core[1], WorkoutDeviceSessionState.running.rawValue,
                    "stale frame preserves session state")
        assertEqual(readUInt16LE(stale.core, offset: 2), 0x1234,
                    "stale frame preserves session token")
        assertEqual(readUInt32LE(stale.core, offset: 4), UInt32.max,
                    "stale frame strips core numerics")
        assertEqual(stale.extended[1], 0,
                    "stale frame strips source flags and current-snapshot freshness")
        assertEqual(readUInt16LE(stale.extended, offset: 4), UInt16.max,
                    "stale frame strips extended numerics")
    }

    static func testWorkoutDeviceTelemetryMapping() {
        let date = Date(timeIntervalSince1970: 1_000)
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        func metric(
            _ value: Double,
            _ unit: WorkoutMetricUnitV1,
            source: WorkoutMetricSourceV1? = nil
        ) -> WorkoutMetricV1 {
            WorkoutMetricV1(
                value: value,
                unit: unit,
                capturedAt: date,
                source: source
            )
        }
        let watchLocation = WorkoutLocationV1(
            latitude: 1,
            longitude: 2,
            capturedAt: date,
            horizontalAccuracy: 3,
            altitude: 42,
            verticalAccuracy: 4,
            course: nil,
            speed: 8
        )
        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            currentHeartRate: metric(150, .beatsPerMinute, source: .healthKit),
            averageHeartRate: metric(140, .beatsPerMinute, source: .healthKit),
            activeEnergy: metric(20, .kilocalories, source: .healthKit),
            cyclingDistance: metric(100, .meters, source: .healthKit),
            currentSpeed: metric(8, .metersPerSecond, source: .pairedCyclingSensor),
            cyclingPower: metric(250, .watts, source: .pairedCyclingSensor),
            cyclingCadence: metric(90, .revolutionsPerMinute, source: .pairedCyclingSensor),
            currentHeartRateZone: 3,
            heartRateZoneCount: 5,
            location: watchLocation,
            availability: [
                .elapsedTime, .currentHeartRate, .averageHeartRate,
                .activeEnergy, .cyclingDistance, .currentSpeed,
                .cyclingPower, .cyclingCadence, .heartRateZone,
                .location, .altitude,
            ]
        )
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 1,
            capturedAt: date,
            snapshot: snapshot
        )
        func presentation(
            connectionState: WorkoutMirrorConnectionStateV1,
            snapshot presentedSnapshot: WorkoutSnapshotV1 = snapshot,
            confirmedState: WorkoutSessionStateV1? = nil,
            finalSnapshot: WorkoutSnapshotV1? = nil
        ) -> WorkoutMirrorPresentationV1 {
            WorkoutMirrorPresentationV1(
                connectionState: connectionState,
                snapshot: presentedSnapshot,
                sessionID: sessionID,
                capturedAt: date,
                receivedAt: date,
                confirmedSessionState: confirmedState,
                errorCode: nil,
                pendingControl: nil,
                finalSnapshot: finalSnapshot,
                navigation: .empty
            )
        }

        let live = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .connected),
            envelope: envelope
        )
        assertEqual(live?.state, .running,
                    "mapper preserves authoritative running state")
        assertEqual(live?.sessionToken, 77,
                    "mapper preserves the Watch session token")
        assert(live?.hasLiveNumerics == true,
               "connected coherent snapshots retain live numerics")
        assert(live?.sourceFlags.contains(.pairedSpeedSensor) == true,
               "mapper reports paired speed source")
        assert(live?.sourceFlags.contains(.healthKitDistance) == true,
               "mapper reports HealthKit distance source")
        assert(live?.sourceFlags.contains(.watchAltitude) == true,
               "mapper reports authoritative Watch altitude")
        assert(live?.sourceFlags.contains(.liveHealthKitZone) == true,
               "mapper reports live HealthKit zone availability")

        let stale = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .stale),
            envelope: envelope
        )
        assertEqual(stale?.state, .running,
                    "stale mapping preserves active session state")
        assert(stale?.hasLiveNumerics == false,
               "stale mapping strips live numerics")

        let stoppedAwaitingFinal = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .connected,
                confirmedState: .ending
            ),
            envelope: envelope
        )
        assertEqual(stoppedAwaitingFinal?.state, .ending,
                    "a connected stopped callback remains ending")
        assert(stoppedAwaitingFinal?.hasLiveNumerics == false,
               "connected ending cannot replay frozen running metrics")
        assert(stoppedAwaitingFinal?.isCurrentSnapshot == true,
               "connected ending remains a current awaiting-final update")

        let awaitingFinal = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .ended,
                confirmedState: .ended
            ),
            envelope: envelope
        )
        assertEqual(awaitingFinal?.state, .ending,
                    "native end without a final Watch snapshot stays ending")
        assert(awaitingFinal?.hasLiveNumerics == false,
               "awaiting-final state cannot heartbeat frozen health metrics")
        assert(awaitingFinal?.isCurrentSnapshot == true,
               "awaiting-final state remains a current mirrored snapshot")
        let awaitingFinalFrames = awaitingFinal.flatMap {
            WorkoutDeviceFrameBuilder.frames(for: $0)
        }
        assertEqual(
            awaitingFinalFrames?.extended[1],
            WorkoutDeviceSourceFlags.currentSnapshot.rawValue,
            "awaiting-final pair distinguishes current unavailable metrics"
        )

        let disconnectedEnding = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .disconnected,
                confirmedState: .ended
            ),
            envelope: envelope
        )
        assertEqual(disconnectedEnding?.state, .ending,
                    "disconnected finalization stays in ending state")
        assert(disconnectedEnding?.isCurrentSnapshot == false,
               "disconnected finalization is not marked current")
        let disconnectedEndingFrames = disconnectedEnding.flatMap {
            WorkoutDeviceFrameBuilder.frames(for: $0)
        }
        assertEqual(disconnectedEndingFrames?.extended[1], 0,
                    "disconnected ending pair carries no freshness bit")

        let endedSnapshot = WorkoutSnapshotV1(
            state: .ended,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            currentHeartRate: metric(150, .beatsPerMinute, source: .healthKit),
            availability: [.elapsedTime, .currentHeartRate],
            terminalOutcome: .saved
        )
        let endedEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 2,
            capturedAt: date,
            snapshot: endedSnapshot
        )
        let ended = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .ended,
                snapshot: endedSnapshot,
                finalSnapshot: endedSnapshot
            ),
            envelope: endedEnvelope
        )
        assertEqual(ended?.state, .ended,
                    "authoritative final Watch snapshot maps to ended")
        assert(ended?.hasLiveNumerics == true,
               "authoritative ended summary retains final numerics")

        let failedSnapshot = WorkoutSnapshotV1(
            state: .failed,
            errorCode: .sessionFailed
        )
        let failedEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 3,
            capturedAt: date,
            snapshot: failedSnapshot
        )
        let failed = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .failed,
                snapshot: failedSnapshot,
                confirmedState: .failed
            ),
            envelope: failedEnvelope
        )
        assertEqual(failed?.state, .failed,
                    "authoritative Watch failure maps to failed")
        assert(failed?.hasLiveNumerics == false,
               "failed sessions do not relay frozen live metrics")
        assert(failed?.isCurrentSnapshot == true,
               "an authoritative failed envelope remains current")
        assertEqual(
            failed.flatMap {
                WorkoutDeviceFrameBuilder.frames(for: $0)
            }?.extended[1],
            WorkoutDeviceSourceFlags.currentSnapshot.rawValue,
            "authoritative failure can cross a same-token collision boundary"
        )

        let phoneLocation = WorkoutLocationV1(
            latitude: 1,
            longitude: 2,
            capturedAt: date,
            horizontalAccuracy: 3,
            altitude: 99,
            verticalAccuracy: 4,
            course: nil,
            speed: 8
        )
        let rawWithoutLocation = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            availability: [.elapsedTime]
        )
        let mergedWithPhoneAltitude = WorkoutSnapshotV1(
            state: .running,
            startDate: date,
            elapsedTime: metric(10, .seconds),
            location: phoneLocation,
            availability: [.elapsedTime, .location, .altitude]
        )
        let rawEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 77,
            sequence: 4,
            capturedAt: date,
            snapshot: rawWithoutLocation
        )
        let phoneAltitude = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(
                connectionState: .connected,
                snapshot: mergedWithPhoneAltitude
            ),
            envelope: rawEnvelope
        )
        assertEqual(phoneAltitude?.altitudeMeters, 99,
                    "valid iPhone altitude remains a relay fallback")
        assert(phoneAltitude?.sourceFlags.contains(.watchAltitude) == false,
               "iPhone altitude is not mislabeled as Watch altitude")

        assertEqual(WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .connected),
            envelope: WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: UUID(),
                sessionToken: 77,
                sequence: 1,
                capturedAt: date,
                snapshot: snapshot
            )
        ), nil, "mapper rejects a mismatched session envelope")
    }

    static func testWorkoutDeviceRelayScheduling() {
        let start = Date(timeIntervalSince1970: 10_000)
        let initial = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample()
        )!
        let changed = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            speedMetersPerSecond: 13,
            activeEnergyKilocalories: 457
        ))!
        let paused = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .paused,
            speedMetersPerSecond: 0
        ))!
        let stale = WorkoutDeviceFrameBuilder.frames(for: workoutDeviceSample(
            state: .paused,
            hasLiveNumerics: false
        ))!
        let currentEnding = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample(
                state: .ending,
                hasLiveNumerics: false,
                isCurrentSnapshot: true
            )
        )!
        let disconnectedEnding = WorkoutDeviceFrameBuilder.frames(
            for: workoutDeviceSample(
                state: .ending,
                hasLiveNumerics: false,
                isCurrentSnapshot: false
            )
        )!

        var scheduler = WorkoutDeviceRelayScheduler()
        var schedule = scheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "authentication sends both latest workout frames")
        assert(schedule.transmissions.first?.prioritized == true,
               "initial core synchronization uses the priority lane")
        let initialPairGeneration = schedule.transmissions[0].data[1] >> 6
        assert(initialPairGeneration > 0,
               "new relay frames carry a non-zero pair generation")
        assertEqual(schedule.transmissions[1].data[1] >> 6,
                    initialPairGeneration,
                    "core and extended frames share one pair generation")
        assertEqual(schedule.transmissions[0].data[1] & 0x3F,
                    WorkoutDeviceSessionState.running.rawValue,
                    "pair generation leaves the core session state intact")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }

        schedule = scheduler.update(
            frames: changed,
            transportReady: true,
            at: start.addingTimeInterval(0.2)
        )
        assert(schedule.transmissions.isEmpty,
               "high-rate numeric changes coalesce for one second")
        assertEqual(schedule.nextEvaluationAt, start.addingTimeInterval(1),
                    "coalesced change schedules the next exact deadline")

        schedule = scheduler.update(
            frames: changed,
            transportReady: true,
            at: start.addingTimeInterval(1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "coalesced changed frames send when due")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1)
            )
        }

        schedule = scheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(1.1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "session-state transitions bypass metric coalescing")
        assert(schedule.transmissions[0].prioritized,
               "session-state core transition is prioritized")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1.1)
            )
        }

        schedule = scheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(1.2)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "fresh-to-stale transition sends sentinels immediately")
        for transmission in schedule.transmissions {
            scheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(1.2)
            )
        }

        _ = scheduler.update(
            frames: stale,
            transportReady: false,
            at: start.addingTimeInterval(2)
        )
        schedule = scheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(2.1)
        )
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended],
                    "reconnect resynchronizes both latest frames once")

        var heartbeatScheduler = WorkoutDeviceRelayScheduler()
        let heartbeatStart = heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        for transmission in heartbeatStart.transmissions {
            heartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        assert(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(4.9)
        ).transmissions.isEmpty, "extended heartbeat waits five seconds")
        let firstLiveHeartbeat = heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(5)
        )
        assertEqual(firstLiveHeartbeat.transmissions.map(\.kind), [.core, .extended],
                    "unchanged live frames heartbeat every five seconds")
        for transmission in firstLiveHeartbeat.transmissions {
            heartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(5)
            )
        }
        assert(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(9.9)
        ).transmissions.isEmpty, "the recurring heartbeat waits for its next interval")
        assertEqual(heartbeatScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(10)
        ).transmissions.map(\.kind), [.core, .extended],
        "live core and extended heartbeats recur beyond the first interval")

        var pausedHeartbeatScheduler = WorkoutDeviceRelayScheduler()
        let pausedHeartbeatStart = pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start
        )
        for transmission in pausedHeartbeatStart.transmissions {
            pausedHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let firstPausedHeartbeat = pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(5)
        )
        assertEqual(firstPausedHeartbeat.transmissions.map(\.kind), [.core, .extended],
                    "a healthy paused workout keeps core freshness alive")
        for transmission in firstPausedHeartbeat.transmissions {
            pausedHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start.addingTimeInterval(5)
            )
        }
        assertEqual(pausedHeartbeatScheduler.update(
            frames: paused,
            transportReady: true,
            at: start.addingTimeInterval(10)
        ).transmissions.map(\.kind), [.core, .extended],
        "paused core freshness continues across recurring heartbeat intervals")

        var staleHeartbeatScheduler = WorkoutDeviceRelayScheduler()
        let staleHeartbeatStart = staleHeartbeatScheduler.update(
            frames: stale,
            transportReady: true,
            at: start
        )
        for transmission in staleHeartbeatStart.transmissions {
            staleHeartbeatScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        assertEqual(staleHeartbeatScheduler.update(
            frames: stale,
            transportReady: true,
            at: start.addingTimeInterval(5)
        ).transmissions.map(\.kind), [.core, .extended],
        "stale heartbeats remain a complete transactional pair")

        var partialPairScheduler = WorkoutDeviceRelayScheduler()
        let partialPair = partialPairScheduler.update(
            frames: initial,
            transportReady: true,
            at: start
        )
        partialPairScheduler.didWrite(
            kind: .core,
            data: partialPair.transmissions[0].data,
            at: start
        )
        partialPairScheduler.didNotWrite(
            kind: .extended,
            data: partialPair.transmissions[1].data
        )
        let retriedPair = partialPairScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(0.1)
        )
        assertEqual(retriedPair.transmissions.map(\.kind), [.core, .extended],
                    "a partial pair retries both frames")
        assert(retriedPair.transmissions[0].data[1] >> 6 != initialPairGeneration,
               "a retried pair advances its correlation generation")

        var endingFreshnessScheduler = WorkoutDeviceRelayScheduler()
        let currentEndingPair = endingFreshnessScheduler.update(
            frames: currentEnding,
            transportReady: true,
            at: start
        )
        for transmission in currentEndingPair.transmissions {
            endingFreshnessScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let disconnectedEndingPair = endingFreshnessScheduler.update(
            frames: disconnectedEnding,
            transportReady: true,
            at: start.addingTimeInterval(0.1)
        )
        assertEqual(
            disconnectedEndingPair.transmissions.map(\.kind),
            [.core, .extended],
            "current-ending to disconnected-ending bypasses coalescing"
        )
        assert(disconnectedEndingPair.transmissions.first?.prioritized == true,
               "ending freshness loss uses the priority lane")
    }

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
            maximumWriteLength: 20,
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
               "one capability-enable event resynchronizes core and extended frames")
        assertEqual(workoutWrites().map { $0[4] }, [1, 2],
                    "publisher integration sends both fallback frame kinds")
        assertEqual(workoutWrites()[0][5] & 0x3F, WorkoutDeviceSessionState.running.rawValue,
                    "readiness publication relays the committed running state")

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
               "rapid disable/reenable still resynchronizes both latest frames")
        assertEqual(workoutWrites()[0][5] & 0x3F, WorkoutDeviceSessionState.paused.rawValue,
                    "reconnect resynchronization uses the latest committed state")
        withExtendedLifetime(relay) {}
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
        malformedKind[0] = 3
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
            expectsWriteResponse: true,
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
            "Connect Bike Computer",
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
            isDiscoveringDevices: false,
            pairingCompletedDuringPresentation: false
        ), "an interrupted owned discovery resumes after its sheet closes")
        assert(!BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: true,
            isDiscoveringDevices: false,
            pairingCompletedDuringPresentation: true
        ), "successful pairing does not restart Nearby discovery")
        assert(!BikeComputersMenuPolicy.shouldResumeOwnedDiscovery(
            ownsDiscoveryLifecycle: true,
            isBluetoothPoweredOn: false,
            isDiscoveringDevices: false,
            pairingCompletedDuringPresentation: false
        ), "discovery waits for Bluetooth to become available")
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
               "the matching-code action can submit once")
        assert(!lifecycle.beginConfirmation(for: otherPeripheralID),
               "a matching-code confirmation cannot be submitted twice")
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
            DeviceGPSPacketBuilder.invalidSpeedCmps,
            "restored idle GPS should omit ride speed"
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
            DeviceGPSPacketBuilder.invalidSpeedCmps,
            "completion restore should remain idle telemetry"
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
                    DeviceGPSPacketBuilder.invalidSpeedCmps,
                    "idle GPS sync should omit speed telemetry")
        assertEqual(readInt16LE(packet, offset: 16), 0, "idle GPS sync should omit altitude telemetry")
        assertEqual(readUInt32LE(packet, offset: 18), 0, "idle GPS sync should omit distance telemetry")
        assertEqual(readUInt32LE(packet, offset: 22), 0, "idle GPS sync should omit elapsed telemetry")
        assertEqual(readUInt32LE(packet, offset: 26),
                    DeviceGPSPacketBuilder.invalidRouteRemainingMeters,
                    "idle GPS sync should omit route remaining telemetry")
    }

    static func testMapTrackingPolicy() {
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
        let accepted = engine.processExternalLocation(unrelatedDeviceLocation)

        assert(!accepted, "far live GPS should not be accepted for rerouting")
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
            latitude: firstManeuver.latitude,
            longitude: firstManeuver.longitude,
            "replacement geometry starts near the rider's latest route position"
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
