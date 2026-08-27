import Foundation
import CoreLocation
import CoreBluetooth
import CryptoKit
import MapKit
#if os(iOS)
import NetworkExtension
#endif

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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

actor CatalogCredentialBootstrapRecorder {
    private let gate = AsyncTestGate()
    private var count = 0
    private let credential: OfflineMapCatalogCredential

    init(credential: OfflineMapCatalogCredential) {
        self.credential = credential
    }

    func bootstrap(existingCredential _: String?) async -> OfflineMapCatalogCredential {
        count += 1
        await gate.wait()
        return credential
    }

    func invocationCount() -> Int { count }

    func release() async {
        await gate.open()
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

    static func bodyData(from request: URLRequest) -> Data {
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
final class TestDeviceDiagnosticsSessionController:
    DeviceDiagnosticsSessionControlling
{
    weak var diagnosticsRecorder: (any RideDiagnosticsEventSink)?
    let session: DeviceTransferSession
    let enterError: Error?
    private(set) var enterCount = 0
    private(set) var exitCount = 0

    init(session: DeviceTransferSession, enterError: Error? = nil) {
        self.session = session
        self.enterError = enterError
    }

    func enterDiagnostics(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        _ = bleManager
        enterCount += 1
        if let enterError {
            throw enterError
        }
        status("test diagnostics session ready")
        return session
    }

    func exitDiagnostics(bleManager: BLEManager) async throws {
        _ = bleManager
        exitCount += 1
    }
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

    override func sendRouteGeometry(_ data: Data) -> Bool {
        guard isConnected, isNavigationReady else {
            return false
        }

        sentRouteGeometry.append(data)
        return true
    }

    override func sendGPSPosition(
        lat: Double,
        lon: Double,
        heading: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        routeRemainingMeters: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        locationTimestamp: Date? = nil
    ) -> Bool {
        guard isConnected, isNavigationReady else {
            return false
        }

        sentGPSPositions.append(DeviceGPSPacketBuilder.data(
            lat: lat,
            lon: lon,
            heading: heading,
            speedMetersPerSecond: speedMetersPerSecond,
            altitudeMeters: altitudeMeters,
            distanceTraveledMeters: distanceTraveledMeters,
            elapsedSeconds: elapsedSeconds,
            routeRemainingMeters: routeRemainingMeters,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            locationTimestamp: locationTimestamp,
            includeRideDetectionQuality: supportsGPSPositionQualityV1
        ))
        return true
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

final class TestLocationManagerClient: LocationManagerClient {
    var authorizationStatus: CLAuthorizationStatus
    var authorizationLevel: LocationAuthorizationLevel
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    private(set) weak var delegate: CLLocationManagerDelegate?
    private(set) var backgroundTrackingEnabledHistory: [Bool] = []
    private(set) var rideDetectionTrackingEnabledHistory: [Bool] = []
    private(set) var requestLocationCallCount = 0
    private(set) var requestWhenInUseAuthorizationCallCount = 0
    private(set) var requestAlwaysAuthorizationCallCount = 0
    private(set) var startUpdatingLocationCallCount = 0
    private(set) var stopUpdatingLocationCallCount = 0

    init(authorizationLevel: LocationAuthorizationLevel) {
        self.authorizationLevel = authorizationLevel
        authorizationStatus = authorizationLevel == .always
            ? .authorizedAlways
            : .notDetermined
    }

    func setDelegate(_ delegate: CLLocationManagerDelegate?) {
        self.delegate = delegate
    }

    func configureForCycling() {}

    func setRideDetectionTrackingEnabled(_ enabled: Bool) {
        rideDetectionTrackingEnabledHistory.append(enabled)
    }

    func setBackgroundTrackingEnabled(_ enabled: Bool) {
        backgroundTrackingEnabledHistory.append(enabled)
    }

    func requestLocation() {
        requestLocationCallCount += 1
    }

    func requestWhenInUseAuthorization() {
        requestWhenInUseAuthorizationCallCount += 1
    }

    func requestAlwaysAuthorization() {
        requestAlwaysAuthorizationCallCount += 1
    }

    func startUpdatingLocation() {
        startUpdatingLocationCallCount += 1
    }

    func stopUpdatingLocation() {
        stopUpdatingLocationCallCount += 1
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
        testCoordinatorPreviewsAndSelectsAlternateRoutes()
        testCoordinatorReroutesAndAppliesLatestRoute()
        testWorkoutAndNavigationLifecyclesStayIndependent()
        testRideActivityRuntimeIntegration()
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
        testDeveloperLocationOverride()
        testLocationAuthorizationRemediationPolicy()
        testRideActivityPolicy()
        testRideDetectionLocationStatusResolver()
        testDeviceGPSPacketBuilder()
        testNavigationCourseResolver()
        testRouteGeometryMath()
        testRouteGeometryTransmissionPolicy()
        testNavigationEngineUsesRouteBearingForInvalidCourse()
        testShanghaiNormalAndTestNavigationShareWGSDeviceSpace()
        testRendererBenchmarkGPSOverrideSuppressesPhysicalFixes()
        testNavigationPacketBuilder()
        testNavigationWriteQueue()
        testGPSQueuePolicy()
        testRendererBenchmarkProtocol()
        testDeviceBLEProtocolConstants()
        testWorkoutDeviceFrameVectors()
        testWorkoutDeviceFrameSentinelsAndSaturation()
        testWorkoutDeviceTelemetryMapping()
        testWorkoutDeviceRelayScheduling()
        testWorkoutDeviceRelayPublicationIntegration()
        testWorkoutDeviceRelayRegularRetryIntegration()
        testWorkoutTelemetryBLETransport()
        testDevicePacketRouting()
        testDeviceTransferHandshakePolicy()
        testDeviceSoundProtocol()
        testDeviceCapabilitiesProtocol()
        testBatteryStatusScreenCapabilityNegotiation()
        testMapProfileCapabilityNegotiation()
        testDeviceCapabilitySynchronizesPowerButtonHonkOnce()
        testDeviceCapabilityRetryPolicy()
        testDeviceScreenValidation()
        testHardwareLabelPreference()
        testBLEPairingAuthenticator()
        testBLEScanLifecyclePolicy()
        testBLEManagerDiscoveryLifecycleTransitions()
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
        testBLEManagerCompletesRetransmittedChunkedMapTransferStatus()
        testBLEManagerParsesDeviceTransferStatus()
        testBLEManagerSendsBrightnessFallbackSetting()
        testBLEManagerResendsBrightnessAfterAuthentication()
        testBLEManagerGatesAutomaticDisplayOffForLegacyFirmware()
        testBLEManagerSendsAutomaticDisplayOffAfterCapabilityNegotiation()
        testBLEManagerSendsAutomaticDisplayOffSetting()
        testBLEManagerRetriesAutomaticDisplayOffAfterQueuePressure()
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
        testNavigationEngineDefersReconnectGPSUntilReadinessCommits()
        testNavigationEngineResendsGPSWhenQualityCapabilityArrives()
        testNavigationEngineResendsRouteGeometryNearLastLocation()
        testNavigationEngineClearsRouteGeometryOnStop()
        testNavigationEngineClearsRouteGeometryWhenReadyAndIdle()
        testNavigationEngineRefreshesElapsedWithoutLocationChange()
        testNavigationEngineClearsRideTelemetryOnStop()
        testNavigationEngineRestoresPhysicalGPSAfterSimulation()
        testNavigationEngineKeepsPhysicalGPSAfterSimulationStepCompletion()
        testNavigationEngineOmitsRideTelemetryWhenIdle()
        testNavigationEngineIgnoresLiveLocationFarFromRouteStart()
        testNavigationEngineReplacesRouteWithoutResettingTelemetry()
        testOfflineMapCustomBBoxRequest()
        testOfflineMapServiceConfigChannels()
        testOfflineMapCatalogConfigChannels()
        testOfflineMapCatalogTrustStoreChannels()
        testOfflineMapShareLinkValidation()
        testOfflineMapCatalogR2HostValidation()
        testOfflineMapCatalogCredentialNamespaces()
        testOfflineMapCatalogAliasAttachmentPolicy()
        testOfflineMapCatalogContentSafeReconciliation()
        testOfflineMapCatalogLocalArtifactIdentity()
        testOfflineMapCatalogAvailabilityPolicy()
        testSavedMapRemovalPolicy()
        await testOfflineMapCatalogCredentialBootstrapCoalescesConcurrentCallers()
        await testOfflineMapCatalogCredentialBootstrapFirstWriterWinsAcrossCoordinators()
        await testOfflineMapCatalogPendingAliasPersistenceAndConflictPolicy()
        await testOfflineMapCatalogInventorySyncSurvivesCatalogFailure()
        await testOfflineMapCatalogClaimRetainsRetryState()
        await testOfflineMapCatalogShareAndLinkContracts()
        await testOfflineMapCapabilitiesContract()
        await testOfflineMapClientRejectsUnsupportedRendererWithoutDowngrade()
        testStreetLabelMapContract()
        testBikeMapStreamGoldenVector()
        testBikeMapStreamArtifactValidation()
        testOfflineMapArtifactSelectionAndProtocolNegotiation()
        testSavedMapArtifactMetadataRoundTrip()
        testSavedMapRendererCompatibilityPolicy()
        testBackgroundMapUploadRestorationState()
        testBackgroundMapUploadArbitration()
        testBackgroundMapUploadSessionNamespace()
        testPausedMapUploadResumePolicy()
        testPausedMapUploadExactArtifactDeletion()
        testBackgroundMapUploadResponseBufferIsBounded()
        testMapStreamBackgroundUploadRequest()
        testDeviceTransferServerProbePolicy()
        await testDeviceTransferManagerWaitsForMapToken()
        await testDeviceTransferManagerWaitsForFreshDebugToken()
        await testDeviceTransferManagerKeepsConfirmedLANDebugSession()
        await testDeviceTransferManagerCompensatesCancelledDebugEntry()
        await testDeviceTransferManagerConfirmsDebugExit()
        await testDeviceTransferManagerUsesFreshDeviceSessionWithoutMapStatus()
        await testDeviceDiagnosticsTransferPolicy()
        await testDeviceDiagnosticsFailsFastOnFirmwareRejection()
        await testDeviceDiagnosticsRecordsEntryFailure()
        await testDeviceDiagnosticsDownloadEndToEnd()
        await testOfflineMapInstallationCredentialClient()
        testOfflineMapPreparationTimeEstimate()
        testOfflineMapJobProgressDecoding()
        testOfflineMapJobPhaseOnlyProgressDecoding()
        testOfflineMapJobProgressAbsentFallback()
        testOfflineMapProgressPresentation()
        testOfflineMapByteProgressPresentation()
        testOfflineMapOnboardingPolicy()
        testMapActivationProgressPresentation()
        testMapUploadProgressReconciliation()
        testOfflineMapDownloadingSectionPresentation()
        testOfflineMapActivityCounterOverlappingOperations()
        testSavedMapDeviceTransferPolicy()
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
        testOfflineMapJobFailureMessages()
        testOfflineMapCreateJobURLRequest()
        testOfflineMapListJobsURLRequest()
        testOfflineMapInventoryMutationURLRequests()
        testOfflineMapManagerMigratesProductionConfig()
        testSavedMapDefaultNamePolicy()
        testOfflineMapManagerRepairsGeneratedPackDefaults()
        testOfflineMapManagerRenamesCachedPack()
        testSavedMapRenameViewWiring()
        testSettingsSheetPresentationWiring()
        testStravaRouteCatalogUIWiring()
        testLandingMapConnectionStatusPositioning()
        testDeviceScreenUISettingsWiring()
        testSavedRouteNamingAndViewWiring()
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
        testSavedMapInventoryMergesOnlyExactDeviceContent()
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
        let fixtureURL = URL(fileURLWithPath: "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt")
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
        let fixtureURL = URL(fileURLWithPath: "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt")
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
            objectKey: String? = nil,
            includesRequiredAppIdentity: Bool = true
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
                requiredIosBuild: includesRequiredAppIdentity ? "100" : nil,
                requiredIosGitSha: includesRequiredAppIdentity
                    ? String(repeating: "a", count: 40)
                    : nil,
                requiredIosBuildSha256: includesRequiredAppIdentity
                    ? String(repeating: "b", count: 64)
                    : nil,
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

        let catalogReaderRequirements = OfflineMapReaderRequirements(
            schemaVersion: 1,
            streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
            manifestSchemaVersion: 1,
            renderer: "esp32-fmb",
            rendererFormatVersion: 1,
            requiredFeatures: []
        )
        let catalogArtifact = artifact(
            bytes: stream,
            includesRequiredAppIdentity: false
        )
        do {
            let verified = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: catalogArtifact,
                expectedMapID: "golden-map",
                trustStore: trustStore,
                readerRequirements: catalogReaderRequirements
            )
            assertEqual(
                verified.readerRequirements,
                catalogReaderRequirements,
                "catalog validation retains the reader contract verified against the signed manifest"
            )
            assert(
                verified.requiredIosBuild == nil &&
                    verified.requiredIosGitSHA == nil &&
                    verified.requiredIosBuildSHA256 == nil,
                "catalog validation does not invent immutable app-build requirements"
            )
        } catch {
            assert(false, "a capability-compatible catalog stream is accepted: \(error)")
        }
        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: catalogArtifact,
                expectedMapID: "golden-map",
                trustStore: trustStore
            )
            assert(false, "a build-unbound stream without reader requirements fails closed")
        } catch {
            guard case .invalidArtifactMetadata = error as? BikeMapStreamFormatError else {
                assert(false, "missing reader requirements produce a typed rejection: \(error)")
                return
            }
        }
        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: catalogArtifact,
                expectedMapID: "golden-map",
                trustStore: trustStore,
                readerRequirements: OfflineMapReaderRequirements(
                    schemaVersion: 2,
                    streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                    manifestSchemaVersion: 1,
                    renderer: "esp32-fmb",
                    rendererFormatVersion: 1,
                    requiredFeatures: []
                )
            )
            assert(false, "an unknown reader contract schema fails closed")
        } catch {
            guard case .invalidArtifactMetadata = error as? BikeMapStreamFormatError else {
                assert(false, "unknown reader requirements produce a typed rejection: \(error)")
                return
            }
        }
        do {
            _ = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: catalogArtifact,
                expectedMapID: "golden-map",
                trustStore: trustStore,
                readerRequirements: OfflineMapReaderRequirements(
                    schemaVersion: 1,
                    streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                    manifestSchemaVersion: 1,
                    renderer: "esp32-fmb",
                    rendererFormatVersion: 2,
                    requiredFeatures: ["street-labels"]
                )
            )
            assert(false, "reader requirements cannot contradict the signed manifest")
        } catch {
            guard case .invalidArtifactMetadata = error as? BikeMapStreamFormatError else {
                assert(false, "manifest/reader mismatch produces a typed rejection: \(error)")
                return
            }
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
                rendererFormatVersion: nil,
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
        let catalogReaderRequirements = OfflineMapReaderRequirements(
            schemaVersion: 1,
            streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
            manifestSchemaVersion: 1,
            renderer: "esp32-fmb",
            rendererFormatVersion: 1,
            requiredFeatures: []
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                readerRequirements: catalogReaderRequirements,
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .streamV2,
            "a verified catalog reader contract selects stream v2 without app-build binding"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "a build-unbound stream without a verified reader contract fails closed"
        )
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                readerRequirements: OfflineMapReaderRequirements(
                    schemaVersion: 2,
                    streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                    manifestSchemaVersion: 1,
                    renderer: "esp32-fmb",
                    rendererFormatVersion: 1,
                    requiredFeatures: []
                ),
                deviceStatus: v2Status
            ),
            .legacyArtifactRequired,
            "unknown catalog reader contracts fail closed during install selection"
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
        let streetLabelPredecessor = MapStreamAppArtifactCompatibilityPolicy
            .resumablePredecessorIdentities[1]
        assertEqual(
            MapInstallProtocolSelector.select(
                isBikeMapStream: true,
                signatureTrustCapability: "map-prod-1=" + String(repeating: "5", count: 64),
                requiredIosBuild: streetLabelPredecessor.build,
                requiredIosGitSha: streetLabelPredecessor.gitSha,
                requiredIosBuildSha256: streetLabelPredecessor.componentSha256,
                currentIosBuild: "7",
                currentIosGitSha: String(repeating: "d", count: 40),
                currentIosBuildSha256: String(repeating: "e", count: 64),
                compatibleArtifactAppIdentities:
                    MapStreamAppArtifactCompatibilityPolicy
                        .resumablePredecessorIdentities,
                deviceStatus: v2Status
            ),
            .streamV2,
            "the exact street-label artifact identity survives transport-only app repairs"
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
            requiredIosBuild: nil,
            requiredIosGitSha: nil,
            requiredIosBuildSha256: nil,
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
            rendererFormatVersion: 2,
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
            lastTransferOutcome: nil,
            readerRequirements: OfflineMapReaderRequirements(
                schemaVersion: 1,
                streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                manifestSchemaVersion: 1,
                renderer: "esp32-fmb",
                rendererFormatVersion: 2,
                requiredFeatures: ["street-labels"]
            )
        )
        try! SavedMapArtifactMetadataStore.save(metadata, for: artifactURL)
        assertEqual(
            SavedMapArtifactMetadataStore.load(for: artifactURL)?.readerRequirements,
            metadata.readerRequirements,
            "verified catalog reader requirements persist with the downloaded artifact"
        )
        assert(
            SavedMapArtifactMetadataStore.load(for: artifactURL)?
                .primaryArtifact?.requiredIosBuild == nil,
            "persisted catalog metadata keeps app-build requirements absent"
        )
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

    static func testBackgroundMapUploadSessionNamespace() {
        assert(
            BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: "LetItRide.BikeComputer"
            ) == "LetItRide.BikeComputer.map-transfer.background"
        )
        assert(
            BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: "LetItRide.BikeComputer.dev"
            ) == "LetItRide.BikeComputer.dev.map-transfer.background"
        )
        assert(
            BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: "example.custom.app"
            ) == "example.custom.app.map-transfer.background"
        )
        assert(
            BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: nil
            ) == "LetItRide.BikeComputer.map-transfer.background"
        )
        assert(
            BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: "  "
            ) == "LetItRide.BikeComputer.map-transfer.background"
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
                lastDeviceState: "idle",
                backgroundUploadSucceeded: true,
                statusMessage: "Map upload paused. Tap Upload to resume."
            ),
            "a completed stream upload waits for activation reconciliation instead of rewriting"
        )
        assert(
            PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "map-a",
                candidateMapID: "map-a",
                lastDeviceState: "paused",
                backgroundUploadSucceeded: true
            ),
            "an explicit device pause remains resumable after a completed transport"
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
        assert(
            !PausedMapUploadResumePolicy.isAvailable(
                lastTransferOutcome: "unconfirmed",
                lastTransferMapID: "shared-map-id",
                candidateMapID: "shared-map-id",
                lastTransferArtifactFilename: "catalog-2d.bmap",
                candidateArtifactFilename: "catalog-3d.bmap",
                lastDeviceState: "paused"
            ),
            "same-mapID rendering variants require the exact paused artifact filename"
        )
    }

    @MainActor
    static func testPausedMapUploadExactArtifactDeletion() {
        let suite = "PausedMapExactArtifact-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-map-exact-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let twoDEntryID = "map_v1_" + String(repeating: "d", count: 43)
        let threeDEntryID = "map_v1_" + String(repeating: "e", count: 43)
        let twoDURL = directory.appendingPathComponent(
            OfflineMapCatalogLocalArtifactPolicy.filename(
                mapEntryID: twoDEntryID,
                fileExtension: "bmap"
            )!
        )
        let threeDURL = directory.appendingPathComponent(
            OfflineMapCatalogLocalArtifactPolicy.filename(
                mapEntryID: threeDEntryID,
                fileExtension: "bmap"
            )!
        )
        try! Data([0x2d]).write(to: twoDURL)
        try! Data([0x3d]).write(to: threeDURL)

        func metadata(
            for url: URL,
            entryID: String,
            state: String?
        ) -> SavedMapArtifactMetadata {
            SavedMapArtifactMetadata(
                schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
                mapID: "shared-map-id",
                displayName: entryID == twoDEntryID ? "2D map" : "3D map",
                localArtifactFilename: url.lastPathComponent,
                streamFormatVersion: 1,
                rendererFormatVersion: entryID == twoDEntryID ? 2 : 3,
                jobID: nil,
                serverURLString: nil,
                clientInstallationID: nil,
                primaryArtifact: nil,
                legacyArtifact: nil,
                lastTransferProtocol: entryID == twoDEntryID ? 2 : nil,
                lastTransferStreamFormat: entryID == twoDEntryID ? 1 : nil,
                lastTransferSessionID: entryID == twoDEntryID ? "paused-session" : nil,
                lastBackgroundTaskID: nil,
                lastDeviceSequence: nil,
                lastDeviceState: state,
                lastDeviceStep: state == nil ? nil : 1,
                lastDeviceStepCount: state == nil ? nil : 3,
                lastDeviceProgress: state == nil ? nil : 40,
                expectedActiveMapID: entryID == twoDEntryID ? "shared-map-id" : nil,
                expectedActiveSessionID: entryID == twoDEntryID ? "paused-session" : nil,
                lastTransferOutcome: entryID == twoDEntryID ? "unconfirmed" : nil,
                catalogMapEntryID: entryID
            )
        }
        try! SavedMapArtifactMetadataStore.save(
            metadata(for: twoDURL, entryID: twoDEntryID, state: "paused"),
            for: twoDURL
        )
        try! SavedMapArtifactMetadataStore.save(
            metadata(for: threeDURL, entryID: threeDEntryID, state: nil),
            for: threeDURL
        )
        defaults.set("shared-map-id", forKey: "offlineMap.lastTransfer.mapId")
        defaults.set("paused-session", forKey: "offlineMap.lastTransfer.sessionId")
        defaults.set("unconfirmed", forKey: "offlineMap.lastTransfer.outcome")
        defaults.set(
            twoDURL.lastPathComponent,
            forKey: "offlineMap.lastTransfer.artifactFilename"
        )

        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: directory
        )
        assert(manager.isPausedMapUpload(twoDURL), "the exact 2D artifact is resumable")
        assert(
            !manager.isPausedMapUpload(threeDURL),
            "the same-mapID 3D sibling never inherits the paused resume action"
        )
        manager.deleteCachedPack(at: twoDURL)
        assert(
            !manager.hasPausedMapUpload,
            "deleting the exact paused artifact invalidates the resume state"
        )
        assertEqual(
            manager.lastTransferMapId,
            "",
            "deleting the exact paused artifact clears its legacy map identity"
        )
        assert(
            FileManager.default.fileExists(atPath: threeDURL.path),
            "deleting one rendering variant preserves the sibling artifact"
        )
        assert(
            !manager.isPausedMapUpload(threeDURL),
            "resume never falls back to the surviving same-mapID sibling"
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

    @MainActor
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

            let managedCredential = OfflineMapInstallationCredential(
                clientInstallationId:
                    "inst_v2_fedcba0987654321fedcba0987654321",
                clientInstallationToken:
                    "v1." + String(repeating: "D", count: 43)
            )
            try store.save(
                managedCredential,
                serverURLString:
                    OfflineMapServiceConfig.productionServerURLString
            )
            let serviceSession = BicinoServiceSession(
                defaults: defaults,
                urlSession: session
            )
            let authenticated = try await serviceSession.authenticatedRequest(
                path: "/v1/integrations/strava/connection",
                method: "GET"
            )
            assertEqual(
                authenticated.url?.host,
                "maps.8o.vc",
                "shared service authentication uses the build-owned managed host"
            )
            assert(
                authenticated.url?.query?.contains(
                    "clientInstallationId=\(managedCredential.clientInstallationId)"
                ) == true,
                "shared service authentication reuses the map installation identity"
            )
            assertEqual(
                authenticated.value(
                    forHTTPHeaderField: "X-Installation-Token"
                ),
                managedCredential.clientInstallationToken,
                "shared service authentication reuses the Keychain credential"
            )
            assert(
                BicinoServiceSession.validatedManagedServiceURL(
                    OfflineMapServiceConfig.developmentServerURLString
                ) != nil &&
                    BicinoServiceSession.validatedManagedServiceURL(
                        OfflineMapServiceConfig.productionServerURLString
                    ) != nil &&
                    BicinoServiceSession.validatedManagedServiceURL(
                        "https://maps.example.com"
                    ) == nil,
                "shared integration requests cannot cross to an arbitrary host"
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
    static func testCoordinatorPreviewsAndSelectsAlternateRoutes() {
        let suite = "CoordinatorAlternatives.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false
        )
        let sourceCoordinate = CLLocationCoordinate2D(
            latitude: 37.0,
            longitude: -122.0
        )
        let destinationCoordinate = CLLocationCoordinate2D(
            latitude: 37.004,
            longitude: -122.0
        )
        let source = MKMapItem(
            placemark: MKPlacemark(coordinate: sourceCoordinate)
        )
        source.name = "Start"
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destinationCoordinate)
        )
        destination.name = "Finish"
        let direct = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )
        let scenic = TestRoute(
            instructions: "Bear right",
            coordinates: [
                sourceCoordinate,
                CLLocationCoordinate2D(
                    latitude: 37.002,
                    longitude: -122.001
                ),
                destinationCoordinate
            ]
        )

        coordinator.planNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling,
            isTestMode: true
        )
        assertEqual(factory.tasks.count, 1, "route planning creates one request")
        assert(
            factory.tasks[0].request.requestsAlternateRoutes,
            "route planning explicitly requests alternate routes"
        )
        factory.tasks[0].succeed(with: [direct, scenic])
        assertEqual(
            coordinator.routeAlternatives.count,
            2,
            "all valid alternatives are presented before navigation"
        )
        assert(!coordinator.isNavigating, "route preview does not start navigation")
        assert(coordinator.routePreview === direct, "first alternative is previewed")
        assert(
            coordinator.selectedRouteAlternativeID == nil,
            "the rider must explicitly select an alternative"
        )

        let scenicID = coordinator.routeAlternatives[1].id
        coordinator.selectRouteAlternative(scenicID)
        assert(coordinator.routePreview === scenic, "selection updates map preview")
        coordinator.startSelectedRoute()
        assert(coordinator.currentRoute === scenic, "explicit start uses selected route")
        assert(coordinator.isNavigating, "explicit start begins navigation")
        assert(coordinator.routeAlternatives.isEmpty, "start clears pending alternatives")

        coordinator.stopNavigation()
        coordinator.startNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling,
            isTestMode: true
        )
        assertEqual(factory.tasks.count, 2, "legacy immediate start creates a request")
        assert(
            !factory.tasks[1].request.requestsAlternateRoutes,
            "immediate/device starts retain a single-route request"
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
    static func testRideActivityRuntimeIntegration() {
        let now = Date(timeIntervalSinceReferenceDate: 800_300_100)
        var currentDate = now
        var isApplicationActive = false
        let locationClient = TestLocationManagerClient(
            authorizationLevel: .whenInUse
        )
        let locationManager = CurrentLocationManager(
            locationManager: locationClient,
            applicationIsActive: { isApplicationActive }
        )
        let store = WorkoutMetricsStore(now: { currentDate })
        store.attachMirroredSession(at: now)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 4,
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

        locationManager.bindWorkoutMetricsStore(store)

        assertEqual(
            locationClient.startUpdatingLocationCallCount,
            0,
            "a background-launched workout must defer a When-In-Use location start"
        )
        assertEqual(
            locationClient.requestAlwaysAuthorizationCallCount,
            0,
            "Always authorization can only be requested after the app becomes active"
        )
        assert(
            locationClient.backgroundTrackingEnabledHistory.last == false,
            "When-In-Use permission must not configure background delivery"
        )

        isApplicationActive = true
        locationManager.applicationDidBecomeActive()

        assertEqual(
            locationClient.requestAlwaysAuthorizationCallCount,
            1,
            "foregrounding a background-launched workout should request Always authorization"
        )
        assertEqual(
            locationClient.startUpdatingLocationCallCount,
            1,
            "foregrounding should retry the deferred workout location start"
        )

        store.disconnect(error: .watchUnavailable)
        assertEqual(
            locationClient.stopUpdatingLocationCallCount,
            0,
            "a disconnected live workout should keep location active during the reconnection grace period"
        )
        assert(
            locationClient.backgroundTrackingEnabledHistory.last == false,
            "workout grace cannot exceed the current location authorization"
        )

        currentDate = now.addingTimeInterval(
            WorkoutServiceActivityTracker.reconnectionGracePeriod + 0.001
        )
        store.refreshFreshness(at: currentDate)
        assertEqual(
            locationClient.stopUpdatingLocationCallCount,
            1,
            "an unverified workout should release location after the bounded grace period"
        )
        assert(
            locationClient.backgroundTrackingEnabledHistory.last == false,
            "expired workout reconnection grace should release background tracking"
        )

        locationManager.setNavigating(true)
        assertEqual(
            locationClient.startUpdatingLocationCallCount,
            2,
            "navigation should remain able to start location after workout grace expires"
        )
        locationManager.setNavigating(false)
        assertEqual(
            locationClient.stopUpdatingLocationCallCount,
            2,
            "ending navigation should release its independent location claim"
        )

        let alwaysClient = TestLocationManagerClient(
            authorizationLevel: .always
        )
        let backgroundLocationManager = CurrentLocationManager(
            locationManager: alwaysClient,
            applicationIsActive: { false }
        )
        backgroundLocationManager.bindWorkoutMetricsStore(storeForActiveWorkout(
            at: now.addingTimeInterval(1)
        ))
        assertEqual(
            alwaysClient.startUpdatingLocationCallCount,
            1,
            "Always-authorized workout tracking may start during a background launch"
        )

        let headlessClient = TestLocationManagerClient(
            authorizationLevel: .always
        )
        var isHeadlessSceneActive = false
        let headlessLocationManager = CurrentLocationManager(
            locationManager: headlessClient,
            applicationIsActive: { isHeadlessSceneActive }
        )
        headlessLocationManager.setViewingMap(true)
        assertEqual(
            headlessClient.startUpdatingLocationCallCount,
            0,
            "a headless background launch must not treat the map as visible"
        )
        isHeadlessSceneActive = true
        headlessLocationManager.applicationDidBecomeActive()
        assertEqual(
            headlessClient.startUpdatingLocationCallCount,
            1,
            "an active visible map should start foreground location"
        )
        isHeadlessSceneActive = false
        headlessLocationManager.setViewingMap(false)
        assertEqual(
            headlessClient.stopUpdatingLocationCallCount,
            1,
            "backgrounding the visible map should release its location claim"
        )

        let detectionClient = TestLocationManagerClient(
            authorizationLevel: .always
        )
        let detectionLocationManager = CurrentLocationManager(
            locationManager: detectionClient,
            applicationIsActive: { false }
        )
        detectionLocationManager.setRideDetectionArmed(true)
        assertEqual(
            detectionClient.startUpdatingLocationCallCount,
            1,
            "armed ride detection starts Always-authorized background GPS"
        )
        assert(
            detectionClient.backgroundTrackingEnabledHistory.last == true,
            "armed ride detection enables background location delivery"
        )
        assert(
            detectionClient.rideDetectionTrackingEnabledHistory.last == true,
            "armed ride detection selects the continuous cycling GPS profile"
        )
        detectionLocationManager.setRideDetectionArmed(false)
        assertEqual(
            detectionClient.stopUpdatingLocationCallCount,
            1,
            "disarming ride detection releases its location demand"
        )
        assert(
            detectionClient.rideDetectionTrackingEnabledHistory.last == false,
            "disarming ride detection restores the ordinary distance filter"
        )

        var isForegroundDetectionActive = true
        let foregroundOnlyClient = TestLocationManagerClient(
            authorizationLevel: .whenInUse
        )
        let foregroundOnlyLocationManager = CurrentLocationManager(
            locationManager: foregroundOnlyClient,
            applicationIsActive: { isForegroundDetectionActive }
        )
        foregroundOnlyLocationManager.setRideDetectionArmed(true)
        assertEqual(
            foregroundOnlyClient.startUpdatingLocationCallCount,
            1,
            "When-In-Use detection may consume GPS while the app is active"
        )
        assert(
            foregroundOnlyClient.backgroundTrackingEnabledHistory.last == false,
            "When-In-Use authorization never enables background delivery"
        )
        isForegroundDetectionActive = false
        foregroundOnlyLocationManager.applicationStateDidChange()
        assertEqual(
            foregroundOnlyClient.stopUpdatingLocationCallCount,
            1,
            "When-In-Use detection stops immediately when the app backgrounds"
        )

        assert(!RideActivityPolicy.shouldReverseGeocodeLocation(
            isNavigating: false,
            isViewingMap: false,
            isWorkoutActive: false,
            isRefreshingDeviceDestinationLocation: false
        ), "headless detection does not reverse geocode raw GPS fixes")
        assert(RideActivityPolicy.shouldReverseGeocodeLocation(
            isNavigating: false,
            isViewingMap: true,
            isWorkoutActive: false,
            isRefreshingDeviceDestinationLocation: false
        ), "a visible map retains current-address reverse geocoding")

        let consentSuite =
            "RideDetectionLocationConsentTests.\(UUID().uuidString)"
        guard let consentDefaults = UserDefaults(suiteName: consentSuite) else {
            assertionFailure("could not create location consent defaults")
            return
        }
        consentDefaults.removePersistentDomain(forName: consentSuite)
        let consentStore = RideDetectionSettingsStore(
            defaults: consentDefaults
        )
        assert(!consentStore.hasAcknowledgedLocationUse,
               "ride detection background GPS requires explicit acknowledgement")
        consentStore.acknowledgeLocationUse()
        assert(RideDetectionSettingsStore(defaults: consentDefaults)
            .hasAcknowledgedLocationUse,
               "ride detection location acknowledgement persists")
        consentDefaults.removePersistentDomain(forName: consentSuite)

        var idleTimerValues: [Bool] = []
        RideIdleTimerController.update(
            isNavigating: false,
            isWorkoutActive: true,
            isApplicationActive: true,
            setIdleTimerDisabled: { idleTimerValues.append($0) }
        )
        RideIdleTimerController.update(
            isNavigating: false,
            isWorkoutActive: true,
            isApplicationActive: false,
            setIdleTimerDisabled: { idleTimerValues.append($0) }
        )
        RideIdleTimerController.update(
            isNavigating: true,
            isWorkoutActive: false,
            isApplicationActive: true,
            setIdleTimerDisabled: { idleTimerValues.append($0) }
        )
        assertEqual(
            idleTimerValues,
            [true, false, true],
            "the idle-timer adapter should apply workout, background, and navigation policy"
        )
    }

    @MainActor
    private static func storeForActiveWorkout(
        at date: Date
    ) -> WorkoutMetricsStore {
        let store = WorkoutMetricsStore(now: { date })
        store.attachMirroredSession(at: date)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 5,
                    sequence: 1,
                    capturedAt: date,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: date
                    )
                ),
            ],
            receivedAt: date
        )
        return store
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

        let workoutStartRequest = Data(
            DeviceBLEProtocol.workoutStartRequestPrefix.utf8
        )
        assert(DeviceWorkoutStartRequest.matches(workoutStartRequest),
               "WREQ matches the exact workout start request")
        assert(!DeviceWorkoutStartRequest.matches(workoutStartRequest + Data([0])),
               "extended WREQ packets are rejected")

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

        var workoutStartRequestCount = 0
        manager.onWorkoutStartRequest = { workoutStartRequestCount += 1 }
        assert(manager.handleNavigationCharacteristicNotification(workoutStartRequest),
               "authenticated WREQ notification is consumed")
        assertEqual(workoutStartRequestCount, 1,
                    "BLE manager forwards the authenticated workout start request")

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

        let concurrentManager = BLEManager()
        concurrentManager.isConnected = true
        concurrentManager.isNavigationReady = true
        var concurrentTransportReady = true
        var concurrentStatusWrites: [Data] = []
        var concurrentTransferWrites: [Data] = []
        concurrentManager.installNavigationWriteEndpoint(
            NavigationWriteEndpoint(
                maximumWriteLength: 64,
                expectsWriteResponse: true,
                canSend: { concurrentTransportReady },
                write: { data in
                    concurrentStatusWrites.append(data)
                    concurrentTransportReady = false
                }
            )
        )
        assert(concurrentManager.sendDestinationStatus(
            generation: 17,
            token: 3,
            status: .failed,
            message: "Could not start navigation"
        ), "acknowledged status starts the concurrent transport fixture")
        assert(concurrentManager.enqueueUnacknowledgedTransferWriteForTesting(
            Data(DeviceBLEProtocol.deviceTransferControlPrefix.utf8),
            write: { concurrentTransferWrites.append($0) }
        ), "unacknowledged transfer control is admitted during an acknowledged write")
        assertEqual(concurrentTransferWrites.count, 1,
                    "transfer control bypasses an unrelated response callback")
        concurrentTransportReady = true
        concurrentManager.completeNavigationWriteForTesting(
            error: simulatedWriteError
        )
        assert(waitForMainLoop(timeout: 3) {
            concurrentStatusWrites.count == 2
        }, "concurrent transfer control preserves the acknowledged write failure callback")
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
        assertEqual(readUInt16LE(data, offset: 8), 1, "GPS packet normalizes heading through wraparound")
        assertEqual(readUInt32LE(data, offset: 10), 1_234_567_890, "GPS packet stores Unix time")
        assertEqual(readUInt16LE(data, offset: 14), 555, "GPS packet stores speed in centimeters per second")
        assertEqual(readInt16LE(data, offset: 16), 42, "GPS packet stores altitude in meters")
        assertEqual(readUInt32LE(data, offset: 18), 1234, "GPS packet stores distance traveled in meters")
        assertEqual(readUInt32LE(data, offset: 22), 65, "GPS packet stores elapsed seconds")
        assertEqual(readUInt32LE(data, offset: 26), 9877, "GPS packet stores rounded route remaining meters")

        let invalidData = DeviceGPSPacketBuilder.data(lat: 0, lon: 0, unixTime: 0)
        assertEqual(readUInt16LE(invalidData, offset: 8), DeviceGPSPacketBuilder.invalidHeadingDegrees, "missing heading uses invalid sentinel")
        assertEqual(readUInt16LE(invalidData, offset: 14), DeviceGPSPacketBuilder.invalidSpeedCmps, "missing speed uses invalid sentinel")
        assertEqual(readUInt32LE(invalidData, offset: 26), DeviceGPSPacketBuilder.invalidRouteRemainingMeters, "missing route remaining uses invalid sentinel")

        let sampleTime = Date(timeIntervalSince1970: 1_000)
        let qualityData = DeviceGPSPacketBuilder.data(
            lat: 37.123456,
            lon: -122.654321,
            unixTime: 1_001,
            speedMetersPerSecond: 0,
            horizontalAccuracyMeters: 7.25,
            locationTimestamp: sampleTime,
            includeRideDetectionQuality: true,
            now: sampleTime.addingTimeInterval(1.234)
        )
        assertEqual(qualityData.count, 36,
                    "negotiated GPS quality packet has expected byte length")
        assertEqual(Int(qualityData[30]), 1,
                    "GPS quality packet identifies schema v1")
        assertEqual(Int(qualityData[31]), 3,
                    "valid GPS quality advertises fix and accuracy")
        assertEqual(readUInt16LE(qualityData, offset: 32), 73,
                    "GPS quality stores horizontal accuracy in decimeters")
        assertEqual(readUInt16LE(qualityData, offset: 34), 1234,
                    "GPS quality retains source sample age")

        let futureData = DeviceGPSPacketBuilder.data(
            lat: 1,
            lon: 2,
            horizontalAccuracyMeters: 5,
            locationTimestamp: sampleTime.addingTimeInterval(2),
            includeRideDetectionQuality: true,
            now: sampleTime
        )
        assertEqual(Int(futureData[31]), 2,
                    "materially future locations never claim a valid fix")
        assertEqual(readUInt16LE(futureData, offset: 34), UInt16.max,
                    "materially future locations use the unavailable age sentinel")

        let missingSpeedData = DeviceGPSPacketBuilder.data(
            lat: 1,
            lon: 2,
            horizontalAccuracyMeters: 5,
            locationTimestamp: sampleTime,
            includeRideDetectionQuality: true,
            now: sampleTime
        )
        assertEqual(Int(missingSpeedData[31]), 2,
                    "quality without measured speed never claims a detector-ready fix")

        let legacyHeading = DeviceGPSHeadingWirePolicy.heading(
            nil,
            supportsExplicitInvalidHeading: false
        )
        let modernHeading = DeviceGPSHeadingWirePolicy.heading(
            nil,
            supportsExplicitInvalidHeading: true
        )
        assertEqual(Int(legacyHeading ?? -1), 0,
                    "legacy firmware keeps the historical missing-course zero")
        assert(modernHeading == nil,
               "negotiated firmware receives the explicit invalid-heading sentinel")
    }

    static func testRideDetectionLocationStatusResolver() {
        let now = Date(timeIntervalSince1970: 2_000)
        let fresh = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 4,
            timestamp: now.addingTimeInterval(-1)
        )
        func status(
            authorization: LocationAuthorizationLevel = .always,
            accuracy: CLAccuracyAuthorization = .fullAccuracy,
            location: CLLocation? = fresh,
            ready: Bool = true
        ) -> RideDetectionLocationStatus {
            RideDetectionLocationStatusResolver.resolve(
                startMode: .ask,
                locationUseAcknowledged: true,
                isNavigationReady: ready,
                supportsRideAutomation: true,
                supportsGPSPositionQualityV1: true,
                authorizationLevel: authorization,
                accuracyAuthorization: accuracy,
                location: location,
                now: now
            )
        }
        assertEqual(status(ready: false), .waitingForCompatibleDevice,
                    "status reports a missing compatible device")
        assertEqual(status(authorization: .denied), .permissionNeeded,
                    "status reports denied location permission")
        assertEqual(status(authorization: .whenInUse), .foregroundOnly,
                    "status reports foreground-only authorization")
        assertEqual(status(accuracy: .reducedAccuracy), .waitingForPreciseLocation,
                    "status reports reduced accuracy")
        assertEqual(status(location: nil), .waitingForPreciseLocation,
                    "status reports a missing precise fix")
        let stale = CLLocation(
            coordinate: fresh.coordinate,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 4,
            timestamp: now.addingTimeInterval(-4)
        )
        assertEqual(status(location: stale), .stale,
                    "status reports a fix beyond the firmware freshness window")
        assertEqual(status(), .sending,
                    "status reports detector-ready GPS delivery")
    }

    static func testNavigationCourseResolver() {
        var resolver = NavigationCourseResolver()
        resolver.reset(epoch: 1)
        assertEqual(
            Int(resolver.resolve(
                measuredCourse: 361,
                routeBearing: 90,
                navigationActive: true
            ) ?? -1),
            1,
            "valid measured course is preferred and normalized"
        )
        assertEqual(
            Int(resolver.resolve(
                measuredCourse: -1,
                routeBearing: 92,
                navigationActive: true
            ) ?? -1),
            92,
            "invalid measured course falls back to route bearing"
        )
        assertEqual(
            Int(resolver.resolve(
                measuredCourse: nil,
                routeBearing: nil,
                navigationActive: true
            ) ?? -1),
            92,
            "active navigation remembers the last valid course"
        )
        resolver.reset(epoch: 2)
        assert(
            resolver.resolve(
                measuredCourse: -1,
                routeBearing: nil,
                navigationActive: true
            ) == nil,
            "a new navigation epoch cannot inherit a stale heading"
        )
        assert(
            resolver.resolve(
                measuredCourse: -1,
                routeBearing: 90,
                navigationActive: false
            ) == nil,
            "idle mode does not accidentally activate course-up from a route"
        )
    }

    static func testRouteGeometryMath() {
        let route = [
            CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
            CLLocationCoordinate2D(latitude: 37.0, longitude: -121.999),
            CLLocationCoordinate2D(latitude: 37.001, longitude: -121.999)
        ]
        let rider = CLLocationCoordinate2D(
            latitude: 37.0001,
            longitude: -121.9996
        )
        guard let projection = RouteGeometryMath.nearestProjection(
            to: rider,
            on: route
        ) else {
            assert(false, "route projection exists")
            return
        }
        assertEqual(projection.segmentIndex, 0, "nearest route segment is selected")
        assert(abs(projection.coordinate.latitude - 37.0) < 0.000001,
               "projection lies exactly on the route")
        let window = RouteGeometryMath.slidingWindow(
            riderCoordinate: rider,
            routePoints: route,
            maximumPointCount: 4
        )
        assertCoordinate(
            window[0],
            latitude: projection.coordinate.latitude,
            longitude: projection.coordinate.longitude,
            "route window begins at the exact route projection"
        )
        assert(window.count >= 2, "route window retains the projected route and future geometry")
        assert(
            CLLocation(latitude: window[0].latitude, longitude: window[0].longitude)
                .distance(from: CLLocation(latitude: rider.latitude, longitude: rider.longitude)) > 1,
            "retained route geometry does not contain a stale rider connector"
        )
        let bearing = RouteGeometryMath.bearingNear(rider, routePoints: route)
        assert(bearing != nil && abs((bearing ?? 0) - 90) < 1,
               "route bearing follows the nearest eastbound segment")

        var matcher = RouteProgressMatcher(
            lookBehindSegments: 1,
            lookAheadSegments: 3,
            reacquireDistanceMeters: 50
        )
        let crossingRoute = [
            CLLocationCoordinate2D(latitude: 31.2300, longitude: 121.4700),
            CLLocationCoordinate2D(latitude: 31.2300, longitude: 121.4710),
            CLLocationCoordinate2D(latitude: 31.2300, longitude: 121.4720),
            CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4720),
            CLLocationCoordinate2D(latitude: 31.2320, longitude: 121.4720),
            CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4710),
            CLLocationCoordinate2D(latitude: 31.2300, longitude: 121.4700),
            CLLocationCoordinate2D(latitude: 31.2290, longitude: 121.4710),
            CLLocationCoordinate2D(latitude: 31.2300, longitude: 121.4720)
        ]
        _ = matcher.projection(
            to: CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4710),
            on: crossingRoute
        )
        _ = matcher.projection(
            to: CLLocationCoordinate2D(latitude: 31.2305, longitude: 121.4705),
            on: crossingRoute
        )
        let crossing = matcher.projection(
            to: crossingRoute[0],
            on: crossingRoute
        )
        assert((crossing?.segmentIndex ?? -1) >= 4,
               "epoch-scoped matching does not jump back to the first branch at a crossing")

        matcher.reset()
        let resetProjection = matcher.projection(to: crossingRoute[0], on: crossingRoute)
        assertEqual(resetProjection?.segmentIndex ?? -1, 0,
                    "route replacement resets progress and permits global matching")

        let backtrackRoute = (0...11).map { index in
            CLLocationCoordinate2D(
                latitude: 31.2300,
                longitude: 121.4700 + Double(index) * 0.001
            )
        }
        var backtrackMatcher = RouteProgressMatcher(
            lookBehindSegments: 1,
            lookAheadSegments: 3,
            reacquireDistanceMeters: 50
        )
        let established = backtrackMatcher.projection(
            to: CLLocationCoordinate2D(
                latitude: 31.2300,
                longitude: 121.4785
            ),
            on: backtrackRoute
        )
        assertEqual(established?.segmentIndex ?? -1, 8,
                    "matcher establishes late-route forward progress")
        let backtracked = backtrackMatcher.projection(
            to: CLLocationCoordinate2D(
                latitude: 31.2300,
                longitude: 121.4725
            ),
            on: backtrackRoute
        )
        assertEqual(backtracked?.segmentIndex ?? -1, 2,
                    "a deliberate far backtrack escapes the bounded window and reacquires globally")
    }

    static func testRouteGeometryTransmissionPolicy() {
        assert(
            RouteGeometryTransmissionPolicy.shouldSend(
                currentSegmentIndex: 4,
                lastSentSegmentIndex: nil,
                maximumPointCount: 30
            ),
            "the first route window is always sent"
        )
        assert(
            !RouteGeometryTransmissionPolicy.shouldSend(
                currentSegmentIndex: 4,
                lastSentSegmentIndex: 4,
                maximumPointCount: 30
            ),
            "remaining on one segment does not churn route revisions"
        )
        assert(
            RouteGeometryTransmissionPolicy.shouldSend(
                currentSegmentIndex: 5,
                lastSentSegmentIndex: 4,
                maximumPointCount: 30
            ),
            "advancing one segment requests a fresh forward window"
        )
        assert(
            RouteGeometryTransmissionPolicy.shouldSend(
                currentSegmentIndex: 2,
                lastSentSegmentIndex: 24,
                maximumPointCount: 30
            ),
            "backtracking or a replacement route refreshes geometry"
        )
    }

    @MainActor
    static func testNavigationEngineUsesRouteBearingForInvalidCourse() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let route = TestRoute(
            instructions: "Continue",
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
                CLLocationCoordinate2D(latitude: 37.0, longitude: -121.99)
            ]
        )
        let engine = NavigationEngine()
        engine.setBLEManager(manager)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -121.999),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: 5,
            timestamp: Date()
        )
        engine.startNavigation(with: route, initialLocation: location)
        guard let packet = manager.sentGPSPositions.last else {
            assert(false, "navigation sends a GPS packet")
            return
        }
        let heading = readUInt16LE(packet, offset: 8)
        assert(heading >= 89 && heading <= 91,
               "invalid Core Location course uses route-segment bearing instead of north")

        guard let geometry = engine.extractSlidingWindowGeometry(currentLocation: location) else {
            assert(false, "navigation extracts route geometry")
            return
        }
        let expected = CoordinateConverter.gcj02ToWGS84(coordinate: location.coordinate)
        assert(abs(readInt32LE(geometry, offset: 0) -
                   Int32(expected.latitude * 1_000_000)) <= 1,
               "route geometry starts at the route projection latitude")
        assert(abs(readInt32LE(geometry, offset: 4) -
                   Int32(expected.longitude * 1_000_000)) <= 1,
               "route geometry starts at the route projection longitude")
        assertEqual(engine.routeCoordinateExtractionCount, 1,
                    "route coordinates are extracted once per navigation epoch")
        engine.stopNavigation()
    }

    @MainActor
    static func testShanghaiNormalAndTestNavigationShareWGSDeviceSpace() {
        let wgsStart = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let gcjStart = CoordinateConverter.wgs84ToGCJ02(coordinate: wgsStart)
        let gcjEnd = CLLocationCoordinate2D(
            latitude: gcjStart.latitude,
            longitude: gcjStart.longitude + 0.001
        )
        let route = TestRoute(
            instructions: "Continue east",
            coordinates: [gcjStart, gcjEnd]
        )

        func assertAligned(
            _ manager: TestBLEManager,
            expectedWGS: CLLocationCoordinate2D,
            mode: String
        ) {
            guard let gps = manager.sentGPSPositions.last,
                  let geometry = manager.sentRouteGeometry.last else {
                assert(false, "\(mode) navigation sends GPS and route geometry")
                return
            }
            let gpsCoordinate = CLLocationCoordinate2D(
                latitude: Double(readInt32LE(gps, offset: 0)) / 1_000_000,
                longitude: Double(readInt32LE(gps, offset: 4)) / 1_000_000
            )
            let routeCoordinate = CLLocationCoordinate2D(
                latitude: Double(readInt32LE(geometry, offset: 0)) / 1_000_000,
                longitude: Double(readInt32LE(geometry, offset: 4)) / 1_000_000
            )
            let expectedLocation = CLLocation(
                latitude: expectedWGS.latitude,
                longitude: expectedWGS.longitude
            )
            assert(
                CLLocation(latitude: gpsCoordinate.latitude, longitude: gpsCoordinate.longitude)
                    .distance(from: expectedLocation) < 2,
                "\(mode) GPS remains WGS-84 in Shanghai"
            )
            assert(
                CLLocation(latitude: routeCoordinate.latitude, longitude: routeCoordinate.longitude)
                    .distance(from: expectedLocation) < 3,
                "\(mode) MAPR geometry is converted from MapKit GCJ-02 into the same WGS-84 space"
            )
            let heading = readUInt16LE(gps, offset: 8)
            assert(heading >= 89 && heading <= 91,
                   "\(mode) navigation follows the eastbound route instead of north")
        }

        let normalManager = TestBLEManager()
        normalManager.isConnected = true
        normalManager.isNavigationReady = true
        let normalEngine = NavigationEngine()
        normalEngine.setBLEManager(normalManager)
        normalEngine.startNavigation(with: route)
        let liveWGS = CLLocation(
            coordinate: wgsStart,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: 5,
            timestamp: Date()
        )
        assert(normalEngine.processExternalLocation(liveWGS),
               "normal Shanghai WGS fix is accepted against the MapKit route")
        assertAligned(normalManager, expectedWGS: wgsStart, mode: "normal")
        assertEqual(normalEngine.routeCoordinateExtractionCount, 1,
                    "normal navigation caches the MKRoute polyline")
        normalEngine.stopNavigation()

        let testManager = TestBLEManager()
        testManager.isConnected = true
        testManager.isNavigationReady = true
        let testEngine = NavigationEngine()
        testEngine.setBLEManager(testManager)
        testEngine.startNavigation(with: route, isTestMode: true)
        testEngine.updateSimulationForTesting(timeInterval: 1)
        guard let simulatedGCJ = testEngine.simulatedPosition else {
            assert(false, "test navigation advances along the Shanghai route")
            testEngine.stopNavigation()
            return
        }
        assertAligned(
            testManager,
            expectedWGS: CoordinateConverter.gcj02ToWGS84(coordinate: simulatedGCJ),
            mode: "test"
        )
        assertEqual(testEngine.routeCoordinateExtractionCount, 1,
                    "test navigation uses the same cached MKRoute polyline")
        testEngine.stopNavigation()
    }

    @MainActor
    static func testRendererBenchmarkGPSOverrideSuppressesPhysicalFixes() {
        let manager = TestBLEManager()
        manager.isConnected = true
        manager.isNavigationReady = true
        let engine = NavigationEngine()
        engine.setBLEManager(manager)

        _ = engine.processExternalLocation(CLLocation(
            latitude: 31.2304,
            longitude: 121.4737
        ))
        assertEqual(manager.sentGPSPositions.count, 1,
                    "an idle physical fix normally reaches the device")

        guard let token = manager.beginDeviceGPSOverride() else {
            assert(false, "renderer replay acquires the device GPS override")
            return
        }
        assert(manager.beginDeviceGPSOverride() == nil,
               "device GPS override has one scoped owner")
        _ = engine.processExternalLocation(CLLocation(
            latitude: 31.2305,
            longitude: 121.4738
        ))
        assertEqual(manager.sentGPSPositions.count, 1,
                    "physical fixes do not interleave with renderer replay GPS")

        manager.endDeviceGPSOverride(UUID())
        _ = engine.processExternalLocation(CLLocation(
            latitude: 31.2306,
            longitude: 121.4739
        ))
        assertEqual(manager.sentGPSPositions.count, 1,
                    "a non-owner cannot release the GPS override")

        manager.endDeviceGPSOverride(token)
        assertEqual(manager.sentGPSPositions.count, 2,
                    "override cleanup immediately restores the latest physical GPS")
        _ = engine.processExternalLocation(CLLocation(
            latitude: 31.2307,
            longitude: 121.4740
        ))
        assertEqual(manager.sentGPSPositions.count, 3,
                    "physical GPS resumes after renderer replay cleanup")
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
        assertEqual(request.target?.rendererFormatVersion ?? 0, 3,
                    "custom cut-outs always request renderer target 3")

        let polygon = OfflineMapJobRequest.customPolygon(ring: [
            CLLocationCoordinate2D(latitude: 35.0, longitude: 136.0),
            CLLocationCoordinate2D(latitude: 35.01, longitude: 136.0),
            CLLocationCoordinate2D(latitude: 35.01, longitude: 136.01)
        ])
        assertEqual(polygon.target?.rendererFormatVersion ?? 0, 3,
                    "custom polygons always request renderer target 3")

        let corridor = OfflineMapJobRequest.routeCorridor(
            route: [
                CLLocationCoordinate2D(latitude: 35.0, longitude: 136.0),
                CLLocationCoordinate2D(latitude: 35.01, longitude: 136.01)
            ],
            widthMeters: 500
        )
        assertEqual(corridor.target?.rendererFormatVersion ?? 0, 3,
                    "route corridors always request renderer target 3")

        let identified = request.identified(
            clientInstallationId: "installation-test",
            clientRequestId: "request-test-123",
            installOnDevice: true
        )
        assertEqual(identified.clientInstallationId, "installation-test", "request includes installation identity")
        assertEqual(identified.clientRequestId, "request-test-123", "request includes idempotency identity")
        assertEqual(identified.installOnDevice, true, "request preserves install workflow intent")

        let deviceRequest = request.forDevice(
            firmwareVersion: "0.4.0"
        )
        let deviceRequestJSON = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(deviceRequest)
        ) as! [String: Any]
        let target = deviceRequestJSON["target"] as! [String: Any]
        let labels = deviceRequestJSON["labels"] as! [String: Any]
        assertEqual(target["renderer"] as? String, "esp32-fmb",
                    "device requests name the renderer explicitly")
        assertEqual(target["rendererFormatVersion"] as? Int, 3,
                    "device requests select renderer target 3")
        assertEqual(target["firmwareVersion"] as? String, "0.4.0",
                    "device requests carry the connected firmware version")
        assertEqual(labels["profileVersion"] as? Int, 1,
                    "3D requests carry label profile 1")
        assert((labels["preferredLanguages"] as? [String])?.count ?? 0 <= 3,
               "3D requests cap preferred languages")

        let noFirmware = request.forDevice(firmwareVersion: "")
        assertEqual(noFirmware.target?.rendererFormatVersion ?? 0, 3,
                    "3D requests remain target 3 without firmware metadata")
        assert(noFirmware.target?.firmwareVersion == nil,
               "empty firmware metadata is omitted")
    }

    static func testOfflineMapClientRejectsUnsupportedRendererWithoutDowngrade() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }
        let installationID = "inst_v2_" + String(repeating: "a", count: 32)
        let originalRequest = OfflineMapJobRequest
            .customBBox(
                OfflineMapBounds(minLon: 103.75, minLat: 1.24, maxLon: 103.93, maxLat: 1.37)
            )
            .forDevice(firmwareVersion: "0.5.0")
            .identified(
                clientInstallationId: installationID,
                clientRequestId: "request-target3-only",
                installOnDevice: true
            )
        let client = OfflineMapPlatformClient(
            baseURL: URL(string: "https://maps.example.com")!,
            clientInstallationId: installationID,
            clientInstallationToken: "v1." + String(repeating: "A", count: 43),
            session: session
        )

        func unsupportedResponse(
            requested: Int,
            supported: [Int]
        ) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "detail": [
                    "code": "unsupported_renderer_target",
                    "message": "renderer format \(requested) generation is not available for this installation",
                    "requestedRendererFormatVersion": requested,
                    "supportedRendererFormatVersions": supported,
                ]
            ])
        }

        var submittedFormats: [Int] = []
        var submittedRequestIDs: [String] = []
        var submittedLabelProfiles: [Int?] = []
        OfflineMapTestURLProtocol.configure { request in
            let body = try! JSONSerialization.jsonObject(
                with: OfflineMapTestURLProtocol.bodyData(from: request)
            ) as! [String: Any]
            submittedFormats.append(
                (body["target"] as! [String: Any])["rendererFormatVersion"] as! Int
            )
            submittedRequestIDs.append(body["clientRequestId"] as! String)
            submittedLabelProfiles.append(
                (body["labels"] as? [String: Any])?["profileVersion"] as? Int
            )
            return (400, unsupportedResponse(requested: 3, supported: [2, 1]))
        }
        do {
            _ = try await client.createJob(originalRequest)
            assert(false, "an unsupported 3D target must remain an error")
        } catch OfflineMapPlatformError.unsupportedRendererTarget(
            let requested,
            let supported,
            _
        ) {
            assertEqual(requested, 3, "the typed rejection reports target 3")
            assertEqual(supported, [2, 1], "the typed rejection preserves supported targets")
        } catch {
            assert(false, "unsupported renderer errors retain their typed form")
        }
        assertEqual(submittedFormats, [3], "target 3 is submitted exactly once")
        assertEqual(
            submittedRequestIDs,
            ["request-target3-only"],
            "the target-3 request preserves its idempotency identity"
        )
        assertEqual(
            submittedLabelProfiles.compactMap { $0 },
            [1],
            "the target-3 request carries the street-label profile"
        )

        var genericBadRequestCount = 0
        OfflineMapTestURLProtocol.configure { _ in
            genericBadRequestCount += 1
            return (400, Data(#"{"detail":"invalid map request"}"#.utf8))
        }
        do {
            _ = try await client.createJob(originalRequest)
            assert(false, "an unrelated HTTP 400 must remain an error")
        } catch OfflineMapPlatformError.serverStatus(let status, _) {
            assertEqual(status, 400, "generic bad requests retain their HTTP status")
        } catch {
            assert(false, "generic bad requests remain ordinary server errors")
        }
        assertEqual(
            genericBadRequestCount,
            1,
            "generic bad requests are submitted exactly once"
        )

        var rejectedRequestCount = 0
        OfflineMapTestURLProtocol.configure { _ in
            rejectedRequestCount += 1
            return (
                400,
                Data(#"{"detail":"target rendererFormatVersion must be 1 or 2"}"#.utf8)
            )
        }
        do {
            _ = try await client.createJob(originalRequest)
            assert(false, "the legacy 2D-only rejection must remain an error")
        } catch OfflineMapPlatformError.unsupportedRendererTarget(
            let requested,
            let supported,
            _
        ) {
            assertEqual(requested, 3, "the legacy rejection reports target 3")
            assertEqual(supported, [2, 1], "the legacy rejection reports its supported targets")
        } catch {
            assert(false, "the legacy rejection retains the typed renderer error")
        }
        assertEqual(rejectedRequestCount, 1, "the legacy rejection is not retried as target 2")
    }

    static func testOfflineMapServiceConfigChannels() {
        assertEqual(
            OfflineMapServiceConfig.serverURLString(
                infoDictionary: ["BicinoMapServiceHost": "maps-dev.8o.vc"]
            ),
            "https://maps-dev.8o.vc",
            "the Development configuration selects the isolated map service"
        )
        assertEqual(
            OfflineMapServiceConfig.serverURLString(
                infoDictionary: ["BicinoMapServiceHost": "maps.8o.vc"]
            ),
            "https://maps.8o.vc",
            "the Production configuration selects the production map service"
        )
        assertEqual(
            OfflineMapServiceConfig.serverURLString(
                infoDictionary: ["BicinoMapServiceHost": "attacker.example"]
            ),
            "https://invalid.invalid",
            "an unexpected managed host fails closed"
        )
    }

    static func testOfflineMapShareLinkValidation() {
        let token = String(repeating: "A", count: 43)
        assertEqual(
            OfflineMapShareLink.token(
                from: URL(string: "https://maps-share.8o.vc/s/\(token)")!,
                catalogHost: OfflineMapCatalogConfig.productionHost
            ),
            token,
            "production share links resolve an opaque token"
        )
        assertEqual(
            OfflineMapShareLink.token(
                from: URL(string: "https://maps-share.8o.vc/dev/s/\(token)")!,
                catalogHost: OfflineMapCatalogConfig.productionHost
            ),
            token,
            "development share links resolve the same opaque token"
        )
        assert(
            OfflineMapShareLink.token(
                from: URL(string: "https://attacker.example/s/\(token)")!,
                catalogHost: OfflineMapCatalogConfig.productionHost
            ) == nil,
            "share links reject substituted hosts"
        )
        assert(
            OfflineMapShareLink.token(
                from: URL(string: "https://maps-share.8o.vc/s/short?download=1")!,
                catalogHost: OfflineMapCatalogConfig.productionHost
            ) == nil,
            "share links reject malformed tokens and query parameters"
        )
        assertEqual(
            OfflineMapShareLink.token(
                from: URL(
                    string: "https://maps-share-staging.8o.vc/dev/s/\(token)"
                )!,
                catalogHost: OfflineMapCatalogConfig.developmentHost
            ),
            token,
            "development builds accept staging catalog share links"
        )
        assert(
            OfflineMapShareLink.token(
                from: URL(string: "https://maps-share.8o.vc/s/\(token)")!,
                catalogHost: OfflineMapCatalogConfig.developmentHost
            ) == nil,
            "development builds reject production-host share substitution"
        )
    }

    static func testOfflineMapCatalogConfigChannels() {
        assertEqual(
            OfflineMapCatalogConfig.catalogHost(infoDictionary: [
                OfflineMapCatalogConfig.catalogHostInfoKey:
                    " MAPS-SHARE-STAGING.8O.VC "
            ]),
            OfflineMapCatalogConfig.developmentHost,
            "an explicit validation-build override selects the staging catalog"
        )
        assertEqual(
            OfflineMapCatalogConfig.catalogHost(infoDictionary: [
                OfflineMapCatalogConfig.catalogHostInfoKey: "maps-share.8o.vc"
            ]),
            OfflineMapCatalogConfig.productionHost,
            "both shipped app configurations select the shared production catalog"
        )
        assert(
            OfflineMapCatalogConfig.catalogHost(infoDictionary: [
                OfflineMapCatalogConfig.catalogHostInfoKey: "attacker.example"
            ]) == nil,
            "catalog configuration rejects arbitrary hosts"
        )
    }

    static func testOfflineMapCatalogTrustStoreChannels() {
        let developmentKeyID = "map-dev-2026-08"
        let developmentPublicKey =
            "04a3b3bec1db96a28ca372e203af005936427e20ddba7dc7e955dfb42ec701e91" +
            "a99b1d9dc45dd3565aecf2f165cce3a5292c22066e5494fe002660bb08f0b1241"
        let configuredValues: [String: Any] = [
            OfflineMapCatalogConfig.developmentSigningKeyIDInfoKey:
                developmentKeyID,
            OfflineMapCatalogConfig.developmentSigningPublicKeyInfoKey:
                developmentPublicKey,
        ]
        let development = OfflineMapCatalogConfig.mapStreamTrustStore(
            infoDictionary: configuredValues.merging([
                OfflineMapServiceConfig.infoDictionaryHostKey:
                    "maps-dev.8o.vc"
            ]) { _, new in new }
        )
        assert(
            development.contains(keyID: developmentKeyID),
            "Bicino Dev trusts its commissioned development signer"
        )
        assert(
            development.contains(keyID: "map-prod-2026-07"),
            "Bicino Dev continues to trust production-promoted maps"
        )
        assert(
            development.contains(keyID: "map-prod-2026-08"),
            "Bicino Dev trusts the additive production signer rotation"
        )

        let production = OfflineMapCatalogConfig.mapStreamTrustStore(
            infoDictionary: configuredValues.merging([
                OfflineMapServiceConfig.infoDictionaryHostKey: "maps.8o.vc"
            ]) { _, new in new }
        )
        assert(
            !production.contains(keyID: developmentKeyID),
            "Bicino production ignores development signer configuration"
        )
        assert(
            production.contains(keyID: "map-prod-2026-07"),
            "Bicino production retains the previous production signer during rotation"
        )
        assert(
            production.contains(keyID: "map-prod-2026-08"),
            "Bicino production trusts the replacement production signer"
        )

        let malformed = OfflineMapCatalogConfig.mapStreamTrustStore(
            infoDictionary: [
                OfflineMapServiceConfig.infoDictionaryHostKey:
                    "maps-dev.8o.vc",
                OfflineMapCatalogConfig.developmentSigningKeyIDInfoKey:
                    developmentKeyID,
                OfflineMapCatalogConfig.developmentSigningPublicKeyInfoKey:
                    "04deadbeef",
            ]
        )
        assert(
            !malformed.contains(keyID: developmentKeyID),
            "a malformed development public key fails closed"
        )
    }

    static func testOfflineMapCatalogR2HostValidation() {
        let accountHost = String(repeating: "a", count: 32) +
            ".r2.cloudflarestorage.com"
        assertEqual(
            OfflineMapCatalogConfig.r2DownloadHost(infoDictionary: [
                OfflineMapCatalogConfig.r2DownloadHostInfoKey: accountHost.uppercased()
            ]),
            accountHost,
            "catalog downloads accept only the exact R2 S3 account host shape"
        )
        assert(
            OfflineMapCatalogConfig.r2DownloadHost(infoDictionary: [
                OfflineMapCatalogConfig.r2DownloadHostInfoKey:
                    "maps.example.com"
            ]) == nil,
            "catalog downloads reject arbitrary configured hosts"
        )
    }

    static func testOfflineMapCatalogAliasAttachmentPolicy() {
        let emoji40 = String(repeating: "\u{1F6B2}", count: 40)
        let emoji41 = String(repeating: "\u{1F6B2}", count: 41)
        let emoji60 = String(repeating: "\u{1F6B2}", count: 60)
        let emoji61 = String(repeating: "\u{1F6B2}", count: 61)
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias("  e\u{301}  "),
            "\u{E9}",
            "catalog aliases are NFC-normalized after whitespace trimming"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias("\u{FEFF}Ride name\u{FEFF}"),
            "Ride name",
            "catalog aliases mirror JavaScript trimming of byte-order marks"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias(emoji40),
            emoji40,
            "40 supplementary emoji count as 40 Unicode code points"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias(emoji41),
            emoji41,
            "41 supplementary emoji remain below both catalog limits"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias(emoji60),
            emoji60,
            "60 four-byte emoji exactly meet the UTF-8 byte limit"
        )
        assert(
            OfflineMapCatalogAliasPolicy.normalizedAlias(emoji61) == nil,
            "61 four-byte emoji exceed the UTF-8 byte limit"
        )
        assert(
            OfflineMapCatalogAliasPolicy.normalizedAlias(
                String(repeating: "a", count: 81)
            ) == nil,
            "catalog aliases reject more than 80 Unicode code points"
        )
        assert(
            OfflineMapCatalogAliasPolicy.normalizedAlias("\tTrimmed control") == nil &&
                OfflineMapCatalogAliasPolicy.normalizedAlias("embedded\u{7F}control") == nil,
            "general-category control scalars are rejected before trimming"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias("A\u{200D}B"),
            "A\u{200D}B",
            "format scalars are not misclassified as general-category controls"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.normalizedAlias("\u{200B}Ride name\u{200B}"),
            "\u{200B}Ride name\u{200B}",
            "catalog aliases preserve U+200B exactly like JavaScript trim"
        )
        assertEqual(
            OfflineMapCatalogAliasPolicy.aliasToApplyAfterAttachment(
                localDisplayName: "  Favorite climb  ",
                userDefinedDisplayName: true,
                attachedAlias: "Shanghai"
            ),
            "Favorite climb",
            "a local rename is applied immediately after first catalog attachment"
        )
        assert(
            OfflineMapCatalogAliasPolicy.aliasToApplyAfterAttachment(
                localDisplayName: "Shanghai",
                userDefinedDisplayName: true,
                attachedAlias: "Shanghai"
            ) == nil,
            "an attachment that already has the user alias needs no extra revision"
        )
        assert(
            OfflineMapCatalogAliasPolicy.aliasToApplyAfterAttachment(
                localDisplayName: "Generated map name",
                userDefinedDisplayName: false,
                attachedAlias: "Shanghai"
            ) == nil,
            "generated local names never overwrite the catalog alias"
        )
    }

    @MainActor
    static func testOfflineMapCatalogCredentialBootstrapCoalescesConcurrentCallers() async {
        let expected = OfflineMapCatalogCredential(
            libraryId: "library-coalesced",
            credential: "credential-coalesced"
        )
        let recorder = CatalogCredentialBootstrapRecorder(credential: expected)
        let coordinator = OfflineMapCatalogCredentialCoordinator()
        var savedCredentials: [OfflineMapCatalogCredential] = []
        var loadCount = 0

        func load() -> OfflineMapCatalogCredential? {
            loadCount += 1
            return savedCredentials.last
        }
        func save(_ credential: OfflineMapCatalogCredential) {
            savedCredentials.append(credential)
        }

        let first = Task { @MainActor in
            try! await coordinator.credential(
                loadExisting: load,
                bootstrap: recorder.bootstrap,
                persistAnonymousBootstrap: { credential in
                    save(credential)
                    return credential
                }
            )
        }
        let firstRequestDeadline = Date().addingTimeInterval(2)
        while await recorder.invocationCount() == 0 && Date() < firstRequestDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let second = Task { @MainActor in
            try! await coordinator.credential(
                loadExisting: load,
                bootstrap: recorder.bootstrap,
                persistAnonymousBootstrap: { credential in
                    save(credential)
                    return credential
                }
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        assertEqual(
            await recorder.invocationCount(),
            1,
            "a second caller joins the suspended first bootstrap"
        )
        await recorder.release()
        let firstCredential = await first.value
        let secondCredential = await second.value
        assertEqual(
            firstCredential,
            expected,
            "the first catalog caller receives the bootstrap credential"
        )
        assertEqual(
            secondCredential,
            expected,
            "the later catalog caller receives the same in-flight credential"
        )
        assertEqual(loadCount, 1, "coalescing reads existing credentials once")
        assertEqual(
            savedCredentials,
            [expected],
            "coalescing persists exactly one library identity regardless of completion order"
        )
    }

    @MainActor
    static func testOfflineMapCatalogCredentialBootstrapFirstWriterWinsAcrossCoordinators() async {
        let suite = "OfflineMapCatalogCredentialRace-\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: suite)!
        let secondDefaults = UserDefaults(suiteName: suite)!
        defer { firstDefaults.removePersistentDomain(forName: suite) }
        let firstStore = OfflineMapCatalogCredentialStore(
            defaults: firstDefaults,
            catalogHost: OfflineMapCatalogConfig.productionHost
        )
        let secondStore = OfflineMapCatalogCredentialStore(
            defaults: secondDefaults,
            catalogHost: OfflineMapCatalogConfig.productionHost
        )
        let firstCandidate = OfflineMapCatalogCredential(
            libraryId: "library-first-candidate",
            credential: "credential-first-candidate"
        )
        let secondCandidate = OfflineMapCatalogCredential(
            libraryId: "library-second-winner",
            credential: "credential-second-winner"
        )
        let firstRecorder = CatalogCredentialBootstrapRecorder(
            credential: firstCandidate
        )
        let secondRecorder = CatalogCredentialBootstrapRecorder(
            credential: secondCandidate
        )
        let firstCoordinator = OfflineMapCatalogCredentialCoordinator()
        let secondCoordinator = OfflineMapCatalogCredentialCoordinator()

        let first = Task { @MainActor in
            try! await firstCoordinator.credential(
                loadExisting: firstStore.load,
                bootstrap: firstRecorder.bootstrap,
                persistAnonymousBootstrap: firstStore.saveAnonymousBootstrapIfAbsent
            )
        }
        let second = Task { @MainActor in
            try! await secondCoordinator.credential(
                loadExisting: secondStore.load,
                bootstrap: secondRecorder.bootstrap,
                persistAnonymousBootstrap: secondStore.saveAnonymousBootstrapIfAbsent
            )
        }
        let bothStartedDeadline = Date().addingTimeInterval(2)
        while Date() < bothStartedDeadline {
            let firstCount = await firstRecorder.invocationCount()
            let secondCount = await secondRecorder.invocationCount()
            if firstCount > 0 && secondCount > 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertEqual(
            await firstRecorder.invocationCount(),
            1,
            "the first independent coordinator reaches anonymous bootstrap"
        )
        assertEqual(
            await secondRecorder.invocationCount(),
            1,
            "the second independent coordinator reads before either bootstrap persists"
        )

        await secondRecorder.release()
        let secondResult = await second.value
        await firstRecorder.release()
        let firstResult = await first.value
        assertEqual(
            firstResult,
            secondCandidate,
            "a later bootstrap response returns the credential already persisted by the winner"
        )
        assertEqual(
            secondResult,
            secondCandidate,
            "the first persistence winner returns its own credential"
        )
        assertEqual(
            firstStore.load(),
            secondCandidate,
            "the first writer remains the shared persisted library identity"
        )
        assertEqual(
            secondStore.load(),
            secondCandidate,
            "independent stores converge on the same library identity"
        )

        let linked = OfflineMapCatalogCredential(
            libraryId: "library-linked",
            credential: secondCandidate.credential
        )
        try! firstStore.save(linked)
        assertEqual(
            secondStore.load(),
            linked,
            "an intentional link-code claim can still replace the library association"
        )
    }

    @MainActor
    static func testOfflineMapCatalogPendingAliasPersistenceAndConflictPolicy() async {
        let snapshotPending = OfflineMapCatalogPendingAlias(
            mapEntryID: "map-snapshot",
            alias: "Before request",
            expectedRevision: 3,
            state: .pending
        )
        let recreatedPending = snapshotPending
        let snapshotToken = UUID()
        let recreatedToken = UUID()
        assertEqual(
            recreatedPending,
            snapshotPending,
            "the ABA regression uses structurally identical pending aliases"
        )
        assert(
            OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                currentToken: snapshotToken,
                requestStartToken: snapshotToken
            ),
            "an unchanged pending alias belongs to the authoritative request snapshot"
        )
        assert(
            !OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                currentToken: recreatedToken,
                requestStartToken: snapshotToken
            ),
            "an identical alias recreated during the request belongs to a newer snapshot"
        )
        assert(
            !OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                currentToken: recreatedToken,
                requestStartToken: nil
            ),
            "a pending alias created during the request is absent from its snapshot"
        )

        let suite = "OfflineMapPendingAlias-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }
        let mapEntryID = "map_v1_" + String(repeating: "p", count: 43)
        func map(alias: String, revision: Int) -> OfflineMapCatalogMap {
            OfflineMapCatalogMap(
                mapEntryId: mapEntryID,
                mapId: "same-region",
                alias: alias,
                aliasSource: revision == 7 ? "generated" : "user",
                aliasRevision: revision,
                canonicalName: "Same region",
                originChannel: "production",
                sourceRegionName: "Same region",
                bounds: [1, 2, 3, 4],
                renderer: "esp32-fmb",
                rendererFormatVersion: 2,
                features: ["street-labels"],
                deliveryState: "production",
                generatedAt: nil,
                addedAt: "2026-08-25T00:00:00.000Z",
                updatedAt: "2026-08-25T00:00:00.000Z",
                artifacts: []
            )
        }
        func mapsPage(_ map: OfflineMapCatalogMap) -> Data {
            let object = try! JSONSerialization.jsonObject(
                with: JSONEncoder().encode(map)
            )
            return try! JSONSerialization.data(withJSONObject: [
                "maps": [object],
                "nextCursor": NSNull(),
            ])
        }
        func waitUntil(
            _ condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        let originalMap = map(alias: "Server name", revision: 7)
        let client = try! OfflineMapCatalogClient(
            baseURL: URL(string: "https://maps-share.8o.vc")!,
            session: session
        )
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (
                    201,
                    Data(#"{"libraryId":"library-alias","credential":"credential-alias"}"#.utf8)
                )
            case ("PATCH", "/v1/library/maps/\(mapEntryID)"):
                let body = try! JSONSerialization.jsonObject(
                    with: OfflineMapTestURLProtocol.bodyData(from: request)
                ) as! [String: Any]
                assertEqual(body["alias"] as? String, "Weekend climb", "rename sends alias")
                assertEqual(body["expectedRevision"] as? Int, 7, "rename preserves CAS revision")
                return (503, Data(#"{"error":"temporarily unavailable"}"#.utf8))
            default:
                assert(false, "unexpected failed-alias request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        let manager = OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            catalogHost: OfflineMapCatalogConfig.productionHost,
            catalogClient: client
        )
        assertEqual(
            manager.renameCatalogMap(originalMap, to: "\tImpossible alias"),
            originalMap.alias,
            "an alias the server must reject never becomes optimistic local state"
        )
        assert(
            manager.catalogAliasStatus(for: mapEntryID) == nil &&
                OfflineMapTestURLProtocol.requests().isEmpty,
            "an impossible alias creates neither durable retry state nor a network request"
        )
        assertEqual(
            manager.renameCatalogMap(originalMap, to: "  Weekend climb  "),
            "Weekend climb",
            "a catalog-only rename is normalized before persistence"
        )
        let firstRenameReachedServer = await waitUntil {
            OfflineMapTestURLProtocol.requests().contains {
                $0.httpMethod == "PATCH"
            }
        }
        assert(
            firstRenameReachedServer,
            "the first catalog-only rename reaches the failing server"
        )
        assertEqual(
            manager.catalogAliasStatus(for: mapEntryID),
            "Name change pending; retries automatically",
            "an offline catalog-only rename exposes its retry state"
        )

        let retriedMap = map(alias: "Weekend climb", revision: 8)
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-alias","created":false}"#.utf8))
            case ("GET", "/v1/library/maps"):
                return (200, mapsPage(originalMap))
            case ("PATCH", "/v1/library/maps/\(mapEntryID)"):
                return (200, try! JSONEncoder().encode(retriedMap))
            default:
                assert(false, "unexpected alias-retry request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        let restoredManager = OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            catalogHost: OfflineMapCatalogConfig.productionHost,
            catalogClient: client
        )
        assertEqual(
            restoredManager.catalogAliasStatus(for: mapEntryID),
            "Name change pending; retries automatically",
            "the retryable alias survives app relaunch before refresh"
        )
        restoredManager.syncCatalogLibraryForTesting()
        let retryCompleted = await waitUntil {
            restoredManager.catalogMaps.first?.alias == "Weekend climb" &&
                restoredManager.catalogAliasStatus(for: mapEntryID) == nil
        }
        assert(
            retryCompleted,
            "a relaunched manager retries and clears the durable alias after success"
        )

        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-alias","created":false}"#.utf8))
            case ("PATCH", "/v1/library/maps/\(mapEntryID)"):
                return (503, Data(#"{"error":"temporarily unavailable"}"#.utf8))
            default:
                assert(false, "unexpected second failed-alias request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        _ = restoredManager.renameCatalogMap(retriedMap, to: "Offline favorite")
        let secondRenameReachedServer = await waitUntil {
            OfflineMapTestURLProtocol.requests().contains {
                $0.httpMethod == "PATCH"
            }
        }
        assert(
            secondRenameReachedServer,
            "the second offline rename is durably attempted"
        )

        let newerServerMap = map(alias: "Renamed on Bicino Dev", revision: 9)
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-alias","created":false}"#.utf8))
            case ("GET", "/v1/library/maps"):
                return (200, mapsPage(newerServerMap))
            case ("PATCH", "/v1/library/maps/\(mapEntryID)"):
                assert(false, "a stale pending alias must not overwrite revision 9")
                return (409, Data())
            default:
                assert(false, "unexpected alias-conflict request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        let conflictManager = OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            catalogHost: OfflineMapCatalogConfig.productionHost,
            catalogClient: client
        )
        conflictManager.syncCatalogLibraryForTesting()
        let conflictLoaded = await waitUntil {
            conflictManager.catalogMaps.first?.aliasRevision == 9
        }
        assert(
            conflictLoaded,
            "conflict refresh retains the newer authoritative revision"
        )
        assertEqual(
            conflictManager.catalogMaps.first?.alias,
            "Offline favorite",
            "the pending local name remains visible without mutating the server"
        )
        assertEqual(
            conflictManager.catalogAliasStatus(for: mapEntryID),
            "Name changed in another app; rename again to apply this name",
            "the stale alias becomes an explicit user-resolvable conflict"
        )
        assert(
            !OfflineMapTestURLProtocol.requests().contains { $0.httpMethod == "PATCH" },
            "conflict reconciliation does not issue a stale compare-and-swap"
        )

        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-alias","created":false}"#.utf8))
            case ("DELETE", "/v1/library/maps/\(mapEntryID)"):
                // Model a DELETE that committed remotely but whose successful
                // response was lost. The next complete list is authoritative.
                return (500, Data(#"{"error":"response lost"}"#.utf8))
            case ("GET", "/v1/library/maps"):
                return (200, Data(#"{"maps":[],"nextCursor":null}"#.utf8))
            case ("GET", "/v1/library/shares"):
                return (200, Data(#"{"shares":[],"nextCursor":null}"#.utf8))
            default:
                assert(false, "unexpected alias-detach request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        conflictManager.removeCatalogMapFromLibrary(newerServerMap)
        let deleteAttempted = await waitUntil {
            OfflineMapTestURLProtocol.requests().contains {
                $0.httpMethod == "DELETE" &&
                    $0.url?.path == "/v1/library/maps/\(mapEntryID)"
            }
        }
        assert(deleteAttempted, "the response-loss scenario attempts detach")
        conflictManager.syncCatalogLibraryForTesting()
        let detached = await waitUntil {
            conflictManager.catalogMaps.isEmpty &&
                conflictManager.catalogAliasStatus(for: mapEntryID) == nil
        }
        assert(
            detached,
            "an authoritative absent row clears pending alias after a lost DELETE response"
        )

        let reclaimedMap = map(alias: "Shared original", revision: 0)
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-alias","created":false}"#.utf8))
            case ("GET", "/v1/library/maps"):
                return (200, mapsPage(reclaimedMap))
            case ("PATCH", "/v1/library/maps/\(mapEntryID)"):
                assert(false, "a detached pending alias must not replay after reclaim")
                return (409, Data())
            default:
                assert(false, "unexpected alias-reclaim request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        let reclaimedManager = OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            catalogHost: OfflineMapCatalogConfig.productionHost,
            catalogClient: client
        )
        reclaimedManager.syncCatalogLibraryForTesting()
        let reclaimLoaded = await waitUntil {
            reclaimedManager.catalogMaps.first?.alias == "Shared original"
        }
        assert(
            reclaimLoaded && reclaimedManager.catalogAliasStatus(for: mapEntryID) == nil,
            "reclaim keeps the server alias without resurrecting detached pending state"
        )
        assert(
            !OfflineMapTestURLProtocol.requests().contains { $0.httpMethod == "PATCH" },
            "reclaim does not issue a stale alias update"
        )
    }

    static func testOfflineMapCatalogContentSafeReconciliation() {
        func artifact(id: String, sha256: String) -> OfflineMapCatalogArtifact {
            OfflineMapCatalogArtifact(
                artifactId: id,
                objectKey: "maps/test/\(id).zip",
                format: OfflineMapArtifact.storedZipFormat,
                mediaType: "application/zip",
                filename: "test.zip",
                bytes: 100,
                sha256: sha256,
                manifestReceipt: nil,
                signedManifestReceipt: nil,
                signatureKeyId: nil,
                signatureKeySha256: nil,
                producerBuildSha256: nil,
                producerImageDigest: nil,
                requiredIosBuild: nil,
                requiredIosGitSha: nil,
                requiredIosBuildSha256: nil,
                requiredFirmwareVersion: nil,
                requiredFirmwareBuild: nil,
                requiredFirmwareGitSha: nil,
                deliveryTier: "development"
            )
        }

        func map(
            entryID: String,
            rendererFormatVersion: Int,
            artifact: OfflineMapCatalogArtifact
        ) -> OfflineMapCatalogMap {
            OfflineMapCatalogMap(
                mapEntryId: entryID,
                mapId: "same-region",
                alias: rendererFormatVersion == 2 ? "2D map" : "3D map",
                aliasSource: "generated",
                aliasRevision: 1,
                canonicalName: "Same region",
                originChannel: "development",
                sourceRegionName: "Same region",
                bounds: [1, 2, 3, 4],
                renderer: "esp32-fmb",
                rendererFormatVersion: rendererFormatVersion,
                features: [],
                deliveryState: "development",
                generatedAt: nil,
                addedAt: "2026-08-25T00:00:00.000Z",
                updatedAt: "2026-08-25T00:00:00.000Z",
                artifacts: [artifact]
            )
        }

        let twoDSHA = String(repeating: "2", count: 64)
        let threeDSHA = String(repeating: "3", count: 64)
        let maps = [
            map(
                entryID: "map_v1_" + String(repeating: "a", count: 43),
                rendererFormatVersion: 2,
                artifact: artifact(id: "artifact-2d", sha256: twoDSHA)
            ),
            map(
                entryID: "map_v1_" + String(repeating: "b", count: 43),
                rendererFormatVersion: 3,
                artifact: artifact(id: "artifact-3d", sha256: threeDSHA)
            ),
        ]
        assert(
            OfflineMapCatalogReconciliationPolicy.matchingMapIndex(
                catalogMapEntryID: nil,
                localArtifactSHA256s: [],
                catalogMaps: maps
            ) == nil,
            "a legacy local map is never joined by non-unique mapId alone"
        )
        assertEqual(
            OfflineMapCatalogReconciliationPolicy.matchingMapIndex(
                catalogMapEntryID: nil,
                localArtifactSHA256s: [threeDSHA],
                catalogMaps: maps
            ),
            1,
            "an exact artifact hash safely binds the matching 3D catalog entry"
        )
        assertEqual(
            OfflineMapCatalogReconciliationPolicy.matchingMapIndex(
                catalogMapEntryID: maps[0].mapEntryId,
                localArtifactSHA256s: [],
                catalogMaps: maps
            ),
            0,
            "a persisted content-derived map entry ID remains authoritative"
        )
    }

    static func testOfflineMapCatalogLocalArtifactIdentity() {
        let twoDEntryID = "map_v1_" + String(repeating: "a", count: 43)
        let threeDEntryID = "map_v1_" + String(repeating: "b", count: 43)
        let twoDFilename = OfflineMapCatalogLocalArtifactPolicy.filename(
            mapEntryID: twoDEntryID,
            fileExtension: "bmap"
        )
        let threeDFilename = OfflineMapCatalogLocalArtifactPolicy.filename(
            mapEntryID: threeDEntryID,
            fileExtension: "bmap"
        )
        assertEqual(
            twoDFilename,
            "catalog-\(twoDEntryID).bmap",
            "catalog files use the content-derived entry identity"
        )
        assert(
            twoDFilename != threeDFilename,
            "2D and 3D entries sharing a legacy map ID retain distinct local files"
        )
        assert(
            OfflineMapCatalogLocalArtifactPolicy.filename(
                mapEntryID: "../../escape",
                fileExtension: "bmap"
            ) == nil,
            "catalog storage rejects unsafe entry IDs"
        )
    }

    static func testOfflineMapCatalogAvailabilityPolicy() {
        let capability = BikeMapStreamTrustStore.production.capabilityHeaderValue?
            .split(separator: ",").first?.split(separator: "=", maxSplits: 1)
        guard let capability, capability.count == 2 else {
            assert(false, "production map trust exposes a test capability")
            return
        }
        let keyID = String(capability[0])
        let keySHA256 = String(capability[1])
        let identity = MapStreamAppBuildIdentity(
            schemaVersion: 1,
            build: "100",
            gitSha: String(repeating: "a", count: 40),
            componentSha256: String(repeating: "b", count: 64)
        )

        func artifact(
            id: String,
            tier: String,
            requiredBuild: String?,
            sha256: String = String(repeating: "c", count: 64),
            includesReaderRequirements: Bool = true,
            readerSchemaVersion: Int = 1,
            streamFormat: String = OfflineMapArtifact.bikeMapStreamFormat,
            renderer: String = "esp32-fmb",
            rendererFormatVersion: Int = 3,
            requiredFeatures: [String] = ["3d-buildings", "street-labels"]
        ) -> OfflineMapCatalogArtifact {
            OfflineMapCatalogArtifact(
                artifactId: id,
                objectKey: "maps/test/\(id).bmap",
                format: OfflineMapArtifact.bikeMapStreamFormat,
                mediaType: "application/vnd.openbikecomputer.map-stream",
                filename: "test.bmap",
                bytes: 100,
                sha256: sha256,
                manifestReceipt: String(repeating: "d", count: 64),
                signedManifestReceipt: String(repeating: "e", count: 64),
                signatureKeyId: keyID,
                signatureKeySha256: keySHA256,
                producerBuildSha256: String(repeating: "f", count: 64),
                producerImageDigest: "sha256:" + String(repeating: "1", count: 64),
                requiredIosBuild: requiredBuild,
                requiredIosGitSha: requiredBuild == nil ? nil : identity.gitSha,
                requiredIosBuildSha256: requiredBuild == nil
                    ? nil
                    : identity.componentSha256,
                requiredFirmwareVersion: nil,
                requiredFirmwareBuild: nil,
                requiredFirmwareGitSha: nil,
                deliveryTier: tier,
                readerRequirements: includesReaderRequirements
                    ? OfflineMapReaderRequirements(
                        schemaVersion: readerSchemaVersion,
                        streamFormat: streamFormat,
                        manifestSchemaVersion: 1,
                        renderer: renderer,
                        rendererFormatVersion: rendererFormatVersion,
                        requiredFeatures: requiredFeatures
                    )
                    : nil
            )
        }

        func map(
            deliveryState: String,
            artifacts: [OfflineMapCatalogArtifact]
        ) -> OfflineMapCatalogMap {
            OfflineMapCatalogMap(
                mapEntryId: "map_v1_" + String(repeating: "m", count: 43),
                mapId: "same-region",
                alias: "Favorite climb",
                aliasSource: "user",
                aliasRevision: 2,
                canonicalName: "Same region",
                originChannel: "development",
                sourceRegionName: "Same region",
                bounds: [1, 2, 3, 4],
                renderer: "esp32-fmb",
                rendererFormatVersion: 3,
                features: ["street-labels", "3d-buildings"],
                deliveryState: deliveryState,
                generatedAt: nil,
                addedAt: "2026-08-25T00:00:00.000Z",
                updatedAt: "2026-08-25T00:00:00.000Z",
                artifacts: artifacts
            )
        }

        func map(
            deliveryState: String,
            artifact: OfflineMapCatalogArtifact
        ) -> OfflineMapCatalogMap {
            map(deliveryState: deliveryState, artifacts: [artifact])
        }

        let developmentMap = map(
            deliveryState: "development",
            artifact: artifact(id: "dev", tier: "development", requiredBuild: nil)
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: developmentMap,
                channel: "production",
                trustStore: .production
            ),
            .awaitingProductionPromotion,
            "production identifies a development-only map before download"
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: developmentMap,
                channel: "development",
                trustStore: .production
            ),
            .available,
            "development accepts a trusted development-tier artifact"
        )

        let productionMap = map(
            deliveryState: "production",
            artifact: artifact(id: "prod", tier: "production", requiredBuild: identity.build)
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: productionMap,
                channel: "production",
                trustStore: .production
            ),
            .available,
            "production exposes an exact compatible promoted artifact"
        )
        let developmentSHA256 = String(repeating: "2", count: 64)
        let productionSHA256 = String(repeating: "3", count: 64)
        let mixedTierMap = map(
            deliveryState: "production",
            artifacts: [
                artifact(
                    id: "mixed-dev",
                    tier: "development",
                    requiredBuild: nil,
                    sha256: developmentSHA256
                ),
                artifact(
                    id: "mixed-prod",
                    tier: "production",
                    requiredBuild: nil,
                    sha256: productionSHA256
                ),
            ]
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [developmentSHA256],
                map: mixedTierMap,
                channel: "production",
                trustStore: .production
            ),
            "production refreshes a cached development artifact for the same map entry"
        )
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [productionSHA256.uppercased()],
                map: mixedTierMap,
                channel: "production",
                trustStore: .production
            ),
            "production keeps a cached compatible production artifact"
        )
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [developmentSHA256],
                map: mixedTierMap,
                channel: "development",
                trustStore: .production
            ),
            "development keeps its preferred compatible development artifact"
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [productionSHA256],
                map: mixedTierMap,
                channel: "development",
                trustStore: .production
            ),
            "development refreshes a production fallback when a development artifact exists"
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [],
                map: mixedTierMap,
                channel: "production",
                trustStore: .production
            ),
            "a catalog-backed local file without verified artifact identity is refreshed"
        )
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [developmentSHA256],
                map: map(
                    deliveryState: "blocked",
                    artifacts: mixedTierMap.artifacts
                ),
                channel: "production",
                trustStore: .production
            ),
            "blocked maps never advertise a catalog artifact refresh"
        )
        let olderBuildMap = map(
            deliveryState: "production",
            artifact: artifact(id: "old", tier: "production", requiredBuild: "99")
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: olderBuildMap,
                channel: "production",
                trustStore: .production
            ),
            .available,
            "a newer app can read an older build's compatible map contract"
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: map(
                    deliveryState: "blocked",
                    artifact: productionMap.artifacts[0]
                ),
                channel: "production",
                trustStore: .production
            ),
            .unavailable,
            "blocked catalog entries never expose a download"
        )

        let rejectedRequirements = [
            artifact(
                id: "schema",
                tier: "production",
                requiredBuild: nil,
                readerSchemaVersion: 2
            ).readerRequirements!,
            artifact(
                id: "stream",
                tier: "production",
                requiredBuild: nil,
                streamFormat: "bike-map-stream-v2"
            ).readerRequirements!,
            artifact(
                id: "renderer",
                tier: "production",
                requiredBuild: nil,
                renderer: "future-renderer"
            ).readerRequirements!,
            artifact(
                id: "version",
                tier: "production",
                requiredBuild: nil,
                rendererFormatVersion: 99
            ).readerRequirements!,
            artifact(
                id: "feature",
                tier: "production",
                requiredBuild: nil,
                requiredFeatures: ["street-labels", "topography"]
            ).readerRequirements!,
        ]
        for requirements in rejectedRequirements {
            assert(
                !OfflineMapReaderCompatibilityPolicy.supports(requirements),
                "unknown reader schemas, formats, renderers, versions, and features fail closed"
            )
        }
        let missingRequirementsMap = map(
            deliveryState: "production",
            artifact: artifact(
                id: "missing-contract",
                tier: "production",
                requiredBuild: nil,
                includesReaderRequirements: false
            )
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: missingRequirementsMap,
                channel: "production",
                trustStore: .production
            ),
            .incompatible,
            "a bike map without reader requirements fails closed"
        )

        let preview = OfflineMapSharePreview(
            shareId: "share-preview",
            mapEntryId: developmentMap.mapEntryId,
            title: developmentMap.alias,
            bounds: developmentMap.bounds,
            renderer: developmentMap.renderer,
            rendererFormatVersion: developmentMap.rendererFormatVersion,
            features: developmentMap.features,
            approximateBytes: 100,
            deliveryState: "promotion_pending",
            expiresAt: nil
        )
        let previewAvailability = OfflineMapCatalogAvailabilityPolicy.availability(
            for: preview,
            channel: "production"
        )
        assertEqual(
            previewAvailability,
            .awaitingProductionPromotion,
            "share previews expose promotion state before claim"
        )
        assertEqual(
            previewAvailability.claimActionTitle,
            "Add to Library",
            "an unavailable share is not presented as an immediate download"
        )
    }

    static func testOfflineMapCatalogInventorySyncSurvivesCatalogFailure() async {
        enum CatalogFailure: Error { case unavailable }
        var generationSyncRan = false
        let credential = await OfflineMapCatalogInventorySyncPolicy
            .bestEffortCredential {
                throw CatalogFailure.unavailable
            }
        generationSyncRan = true
        assert(
            credential == nil,
            "catalog bootstrap failure degrades to an unattached inventory sync"
        )
        assert(
            generationSyncRan,
            "the generation-server inventory path continues after catalog failure"
        )
    }

    @MainActor
    static func testOfflineMapCatalogClaimRetainsRetryState() async {
        let suite = "OfflineMapCatalogClaimRetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }

        let capability = BikeMapStreamTrustStore.production.capabilityHeaderValue?
            .split(separator: ",").first?.split(separator: "=", maxSplits: 1)
        guard let capability, capability.count == 2 else {
            assert(false, "production map trust exposes a test capability")
            return
        }
        let identity = MapStreamAppBuildIdentity(
            schemaVersion: 1,
            build: "100",
            gitSha: String(repeating: "a", count: 40),
            componentSha256: String(repeating: "b", count: 64)
        )
        let mapEntryID = "map_v1_" + String(repeating: "r", count: 43)
        let token = String(repeating: "T", count: 43)
        let artifact = OfflineMapCatalogArtifact(
            artifactId: "artifact-retry",
            objectKey: "maps/test/retry.bmap",
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: "retry.bmap",
            bytes: 100,
            sha256: String(repeating: "c", count: 64),
            manifestReceipt: String(repeating: "d", count: 64),
            signedManifestReceipt: String(repeating: "e", count: 64),
            signatureKeyId: String(capability[0]),
            signatureKeySha256: String(capability[1]),
            producerBuildSha256: String(repeating: "f", count: 64),
            producerImageDigest: "sha256:" + String(repeating: "1", count: 64),
            requiredIosBuild: identity.build,
            requiredIosGitSha: identity.gitSha,
            requiredIosBuildSha256: identity.componentSha256,
            requiredFirmwareVersion: nil,
            requiredFirmwareBuild: nil,
            requiredFirmwareGitSha: nil,
            deliveryTier: "production",
            readerRequirements: OfflineMapReaderRequirements(
                schemaVersion: 1,
                streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                manifestSchemaVersion: 1,
                renderer: "esp32-fmb",
                rendererFormatVersion: 3,
                requiredFeatures: ["3d-buildings", "street-labels"]
            )
        )
        let map = OfflineMapCatalogMap(
            mapEntryId: mapEntryID,
            mapId: "retry-region",
            alias: "Retry map",
            aliasSource: "share",
            aliasRevision: 1,
            canonicalName: "Retry region",
            originChannel: "production",
            sourceRegionName: "Retry region",
            bounds: [1, 2, 3, 4],
            renderer: "esp32-fmb",
            rendererFormatVersion: 3,
            features: ["street-labels", "3d-buildings"],
            deliveryState: "production",
            generatedAt: nil,
            addedAt: "2026-08-25T00:00:00.000Z",
            updatedAt: "2026-08-25T00:00:00.000Z",
            artifacts: [artifact]
        )
        let preview = OfflineMapSharePreview(
            shareId: "share-retry",
            mapEntryId: mapEntryID,
            title: map.alias,
            bounds: map.bounds,
            renderer: map.renderer,
            rendererFormatVersion: map.rendererFormatVersion,
            features: map.features,
            approximateBytes: artifact.bytes,
            deliveryState: map.deliveryState,
            expiresAt: nil
        )
        let grant = OfflineMapCatalogDownloadGrant(
            downloadURL: URL(string: "https://maps-share.8o.vc/v1/downloads/retry")!,
            expiresAt: "2099-01-01T00:00:00.000Z",
            artifact: artifact
        )
        var grantRequestCount = 0
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/shares/\(token)"):
                return (200, try! JSONEncoder().encode(preview))
            case ("POST", "/v1/libraries/bootstrap"):
                return (
                    201,
                    Data(#"{"libraryId":"library-retry","credential":"credential-retry"}"#.utf8)
                )
            case ("POST", "/v1/shares/\(token)/claim"):
                return (200, try! JSONEncoder().encode(map))
            case ("POST", "/v1/library/maps/\(mapEntryID)/download-grants"):
                grantRequestCount += 1
                let body = try! JSONSerialization.jsonObject(
                    with: OfflineMapTestURLProtocol.bodyData(from: request)
                ) as! [String: Any]
                let capabilities = body["readerCapabilities"] as! [String: Any]
                let streams = capabilities["streamFormats"] as! [[String: Any]]
                let renderers = capabilities["renderers"] as! [[String: Any]]
                assertEqual(
                    capabilities["schemaVersion"] as? Int,
                    1,
                    "download grants advertise reader capability schema 1"
                )
                assertEqual(
                    streams.first?["format"] as? String,
                    OfflineMapArtifact.bikeMapStreamFormat,
                    "download grants advertise the exact stream container"
                )
                assertEqual(
                    streams.first?["manifestSchemaVersions"] as? [Int],
                    [1],
                    "download grants advertise discrete manifest schemas"
                )
                assertEqual(
                    renderers.first?["formatVersions"] as? [Int],
                    [1, 2, 3],
                    "download grants advertise discrete renderer versions"
                )
                return (200, try! JSONEncoder().encode(grant))
            default:
                assert(
                    false,
                    "unexpected claim retry request: \(request.httpMethod ?? "") \(request.url?.path ?? "")"
                )
                return (500, Data())
            }
        }
        let client = try! OfflineMapCatalogClient(
            baseURL: URL(string: "https://maps-share.8o.vc")!,
            session: session
        )
        let manager = OfflineMapManager(
            defaults: defaults,
            mapPlatformSession: session,
            mapStreamTrustStore: .production,
            catalogAppIdentity: identity,
            catalogHost: "maps-share.8o.vc",
            catalogClient: client,
            packDownload: { _, _, _, _ in
                throw URLError(.networkConnectionLost)
            }
        )
        manager.handleShareURL(
            URL(string: "https://maps-share.8o.vc/s/\(token)")!
        )
        let previewDeadline = Date().addingTimeInterval(2)
        while manager.pendingSharePreview == nil && Date() < previewDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let didLoadPreview = manager.pendingSharePreview != nil
        assert(
            didLoadPreview,
            "a valid share reaches the explicit claim confirmation"
        )
        manager.claimPendingShare()
        let didFinish = await waitForMapTaskCompletion(manager)
        assert(
            didFinish,
            "the failed post-claim download finishes without hanging"
        )
        assertEqual(
            grantRequestCount,
            1,
            "a compatible claimed map proceeds to the download grant"
        )
        let claimedMapRemains = manager.catalogMaps.contains {
            $0.mapEntryId == mapEntryID
        }
        assert(
            claimedMapRemains,
            "a claimed map remains in the in-session library when download fails"
        )
        let retryStateIsVisible = manager.pendingSharePreview == nil &&
            manager.errorMessage != nil
        assert(
            retryStateIsVisible,
            "the failed download leaves a visible retry row and an error state"
        )
    }

    static func testSavedMapRemovalPolicy() {
        assert(
            SavedMapRemovalPolicy.canRemoveFromMapLibrary(
                isOnIPhone: false,
                isActiveOnDevice: false,
                isAvailableInLibrary: true
            ),
            "a remote-only catalog row can be removed from the map library"
        )
        assert(
            !SavedMapRemovalPolicy.canRemoveFromMapLibrary(
                isOnIPhone: true,
                isActiveOnDevice: false,
                isAvailableInLibrary: true
            ),
            "a local map keeps cloud and iPhone removal as separate actions"
        )
        assert(
            SavedMapRemovalPolicy.canRemoveFromMapLibrary(
                isOnIPhone: false,
                isActiveOnDevice: true,
                isAvailableInLibrary: true
            ),
            "an installed map can release its cloud reference without deleting the device copy"
        )
        let localCopy = SavedMapRemovalPolicy.localDeletionMessage(
            displayName: "Favorite climb",
            libraryCopyRemains: true
        )
        assert(
            localCopy.contains("copy in your Map Library remains") &&
                localCopy.contains("Bike Computer remains"),
            "local deletion explains that cloud and device copies remain"
        )
        let libraryCopy = SavedMapRemovalPolicy.libraryRemovalMessage(
            displayName: "Favorite climb"
        )
        assert(
            libraryCopy.contains("downloaded to an iPhone") &&
                libraryCopy.contains("added by friends are unaffected"),
            "catalog removal explains that independent copies are unaffected"
        )
    }

    static func testOfflineMapCatalogShareAndLinkContracts() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }
        let credential = "library-secret"
        let shareID = "share_v1_" + String(repeating: "s", count: 24)
        let mapEntryID = "map_v1_" + String(repeating: "m", count: 43)
        let firstPageShares: [[String: Any]] = (0..<100).map { index in
            [
                "shareId": index == 0 ? shareID : "share-page-one-\(index)",
                "mapEntryId": mapEntryID,
                "title": index == 0 ? "Favorite climb" : "Shared map \(index)",
                "createdAt": "2026-08-25T00:00:00.000Z",
                "expiresAt": NSNull(),
                "revokedAt": NSNull(),
                "claimCount": index == 0 ? 2 : 0,
            ]
        }
        let finalPageShare: [String: Any] = [
            "shareId": "share-page-two-100",
            "mapEntryId": mapEntryID,
            "title": "Oldest shared map",
            "createdAt": "2026-08-24T00:00:00.000Z",
            "expiresAt": NSNull(),
            "revokedAt": NSNull(),
            "claimCount": 0,
        ]
        OfflineMapTestURLProtocol.configure { request in
            assertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(credential)",
                "catalog library mutations use the library credential"
            )
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/v1/library/maps/\(mapEntryID)"):
                return (204, Data())
            case ("GET", "/v1/library/shares"):
                let query = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                assertEqual(
                    query.first(where: { $0.name == "limit" })?.value,
                    "100",
                    "share management requests bounded pages"
                )
                let cursor = query.first(where: { $0.name == "cursor" })?.value
                if cursor == nil {
                    return (
                        200,
                        try! JSONSerialization.data(withJSONObject: [
                            "shares": firstPageShares,
                            "nextCursor": "share-cursor-100",
                        ])
                    )
                }
                assertEqual(
                    cursor,
                    "share-cursor-100",
                    "share management follows the server cursor"
                )
                return (
                    200,
                    try! JSONSerialization.data(withJSONObject: [
                        "shares": [finalPageShare],
                        "nextCursor": NSNull(),
                    ])
                )
            case ("DELETE", "/v1/library/shares/\(shareID)"):
                return (204, Data())
            case ("POST", "/v1/libraries/link-codes"):
                assertEqual(
                    String(decoding: OfflineMapTestURLProtocol.bodyData(from: request), as: UTF8.self),
                    "{}",
                    "link-code creation has an exact empty request body"
                )
                return (
                    201,
                    Data(
                        #"{"code":"ABCD-EFGH","expiresAt":"2099-01-01T00:00:00.000Z"}"#.utf8
                    )
                )
            case ("POST", "/v1/libraries/link-codes/ABCD-EFGH/claim"):
                return (
                    200,
                    Data(#"{"libraryId":"library-linked"}"#.utf8)
                )
            case ("POST", "/v1/libraries/bootstrap"):
                return (200, Data(#"{"libraryId":"library-linked"}"#.utf8))
            default:
                assert(false, "unexpected catalog request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, Data())
            }
        }
        let client = try! OfflineMapCatalogClient(
            baseURL: URL(string: "https://maps-share.8o.vc")!,
            session: session
        )
        try! await client.removeMapFromLibrary(
            mapEntryId: mapEntryID,
            credential: credential
        )
        try! await client.removeMapFromLibrary(
            mapEntryId: mapEntryID,
            credential: credential
        )
        let detachRequests = OfflineMapTestURLProtocol.requests().filter {
            $0.httpMethod == "DELETE" &&
                $0.url?.path == "/v1/library/maps/\(mapEntryID)"
        }
        assertEqual(
            detachRequests.count,
            2,
            "repeating an idempotent catalog detach accepts the same 204 contract"
        )
        let shares = try! await client.shares(credential: credential)
        assertEqual(shares.count, 101, "share management follows every bounded page")
        assert(shares[0].isActive, "an unrevoked non-expiring share is active")
        assertEqual(shares[0].claimCount, 2, "share claim counts remain visible")
        assertEqual(
            shares.last?.shareId,
            "share-page-two-100",
            "older active links remain visible and revocable"
        )
        let futureFractionalShare = OfflineMapCatalogShare(
            shareId: "fractional-future",
            mapEntryId: "map-fractional",
            title: "Fractional expiry",
            createdAt: "2026-08-25T00:00:00.000Z",
            expiresAt: "2099-01-01T00:00:00.000Z",
            revokedAt: nil,
            claimCount: 0
        )
        let futurePlainShare = OfflineMapCatalogShare(
            shareId: "plain-future",
            mapEntryId: "map-plain",
            title: "Plain expiry",
            createdAt: "2026-08-25T00:00:00Z",
            expiresAt: "2099-01-01T00:00:00Z",
            revokedAt: nil,
            claimCount: 0
        )
        assert(
            futureFractionalShare.isActive,
            "Cloudflare fractional-second expiry timestamps remain active"
        )
        assert(
            futurePlainShare.isActive,
            "plain ISO-8601 expiry timestamps remain active"
        )
        try! await client.revokeShare(
            shareId: shareID,
            credential: credential
        )
        let code = try! await client.createLinkCode(credential: credential)
        assertEqual(code.code, "ABCD-EFGH", "link-code creation returns the one-time code")
        let linked = try! await client.claimLinkCode(
            " abcd-efgh ",
            credential: credential
        )
        assertEqual(linked.libraryId, "library-linked", "claim switches to the source library")
        assertEqual(
            linked.credential,
            credential,
            "claim keeps the already-persisted bearer while the server reparents it"
        )
        let recovered = try! await client.bootstrap(existingCredential: credential)
        assertEqual(
            recovered,
            linked,
            "bootstrap recovers the linked library after an ambiguous claim response"
        )
    }

    static func testOfflineMapCatalogCredentialNamespaces() {
        let suite = "OfflineMapCatalogCredentialNamespaces-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let productionStore = OfflineMapCatalogCredentialStore(
            defaults: defaults,
            catalogHost: OfflineMapCatalogConfig.productionHost
        )
        let stagingStore = OfflineMapCatalogCredentialStore(
            defaults: defaults,
            catalogHost: OfflineMapCatalogConfig.developmentHost
        )
        let production = OfflineMapCatalogCredential(
            libraryId: "library-production",
            credential: "credential-production"
        )
        let staging = OfflineMapCatalogCredential(
            libraryId: "library-staging",
            credential: "credential-staging"
        )
        try! productionStore.save(production)
        assertEqual(
            productionStore.load(),
            production,
            "Bicino and Bicino Dev retain their shared production library credential"
        )
        assert(
            stagingStore.load() == nil,
            "a staging override never sends the production library credential"
        )
        try! stagingStore.save(staging)
        assertEqual(
            stagingStore.load(),
            staging,
            "staging validation keeps its own catalog library identity"
        )
        assertEqual(
            productionStore.load(),
            production,
            "staging validation cannot overwrite the shared production identity"
        )
    }

    static func testOfflineMapCapabilitiesContract() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }
        let installationID = "inst_v2_" + String(repeating: "b", count: 32)
        let token = "v1." + String(repeating: "B", count: 43)
        OfflineMapTestURLProtocol.configure { request in
            assertEqual(request.url?.path, "/v1/capabilities", "capabilities use the advertised endpoint")
            assertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "clientInstallationId" })?.value,
                installationID,
                "capabilities are installation scoped"
            )
            assertEqual(
                request.value(forHTTPHeaderField: "X-Installation-Token"),
                token,
                "capabilities require the installation credential"
            )
            return (200, Data(#"""
            {
                "schemaVersion":1,
                "deploymentChannel":"development",
                "policySha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "generationProfiles":[
                    {"id":"buildings-3d-v1","rendererFormatVersion":3,"features":["street-labels","3d-buildings"]},
                    {"id":"street-labels-v1","rendererFormatVersion":2,"features":["street-labels"]},
                    {"id":"legacy-vector-v1","rendererFormatVersion":1,"features":[]}
                ]
            }
            """#.utf8))
        }
        let client = OfflineMapPlatformClient(
            baseURL: URL(string: "https://maps-dev.example")!,
            clientInstallationId: installationID,
            clientInstallationToken: token,
            session: session
        )
        do {
            let capabilities = try await client.generationCapabilities()
            try capabilities.require(rendererFormatVersion: 3)
            assertEqual(
                capabilities.deploymentChannel,
                "development",
                "the client decodes the deployment channel"
            )
        } catch {
            assert(false, "development capabilities should admit renderer format 3")
        }

        let production = try! JSONDecoder().decode(
            OfflineMapGenerationCapabilities.self,
            from: Data(#"""
            {
                "schemaVersion":1,
                "deploymentChannel":"production",
                "policySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "generationProfiles":[
                    {"id":"street-labels-v1","rendererFormatVersion":2,"features":["street-labels"]},
                    {"id":"legacy-vector-v1","rendererFormatVersion":1,"features":[]}
                ]
            }
            """#.utf8)
        )
        do {
            try production.require(rendererFormatVersion: 3)
            assert(false, "production capabilities must reject a non-canary format 3 client")
        } catch OfflineMapPlatformError.unsupportedRendererTarget(
            let requested,
            let supported,
            _
        ) {
            assertEqual(requested, 3, "capability rejection reports the requested format")
            assertEqual(supported, [2, 1], "capability rejection reports server-advertised formats")
        } catch {
            assert(false, "unsupported capabilities retain the renderer error type")
        }

        let malformed3D = try! JSONDecoder().decode(
            OfflineMapGenerationCapabilities.self,
            from: Data(#"""
            {
                "schemaVersion":1,
                "deploymentChannel":"development",
                "policySha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "generationProfiles":[
                    {"id":"format-three-in-name-only","rendererFormatVersion":3,"features":["street-labels"]},
                    {"id":"street-labels-v1","rendererFormatVersion":2,"features":["street-labels"]},
                    {"id":"legacy-vector-v1","rendererFormatVersion":1,"features":[]}
                ]
            }
            """#.utf8)
        )
        do {
            try malformed3D.require(rendererFormatVersion: 3)
            assert(false, "format 3 must bind to the named 3D feature profile")
        } catch OfflineMapPlatformError.invalidResponse {
            // Expected: malformed capability documents fail closed.
        } catch {
            assert(false, "malformed capability profiles are invalid responses")
        }
    }

    static func testSavedMapRendererCompatibilityPolicy() {
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 1,
                supportsStreetLabels: false,
                supports3DBuildings: false
            ),
            "renderer target 1 remains compatible with legacy firmware"
        )
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 2,
                supportsStreetLabels: true,
                supports3DBuildings: false
            ),
            "renderer target 2 requires street-label support"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 2,
                supportsStreetLabels: false,
                supports3DBuildings: false
            ),
            "renderer target 2 is refused on legacy firmware"
        )
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 3,
                supportsStreetLabels: true,
                supports3DBuildings: true
            ),
            "renderer target 3 requires 3D-building support"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 3,
                supportsStreetLabels: true,
                supports3DBuildings: false
            ),
            "renderer target 3 is refused before transfer to label-only firmware"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 4,
                supportsStreetLabels: true,
                supports3DBuildings: true
            ),
            "unknown renderer targets fail closed"
        )
    }

    static func testStreetLabelMapContract() {
        let sha = String(repeating: "1", count: 64)
        let manifest = Data((
            "{\"files\":[" +
            "{\"bytes\":4,\"path\":\"VECTMAP/label-map/+0000+0000/0_0.fmb\",\"sha256\":\"\(sha)\"}," +
            "{\"bytes\":4,\"path\":\"VECTMAP/label-map/assets/street-labels.fma\",\"sha256\":\"\(sha)\"}]," +
            "\"mapId\":\"label-map\"," +
            "\"producer\":{\"buildSha256\":\"\(sha)\",\"imageDigest\":\"sha256:\(sha)\"}," +
            "\"schemaVersion\":1," +
            "\"target\":{\"formatVersion\":2,\"internationalFallback\":\"en\"," +
            "\"labelLanguages\":[\"zh-Hant\",\"en\"],\"labelProfileVersion\":1," +
            "\"renderer\":\"esp32-fmb\"}}"
        ).utf8)
        let header = BikeMapStreamFormat.Header(
            formatVersion: 1,
            flags: 0,
            manifestBytes: UInt32(manifest.count),
            signatureEnvelopeBytes: 80,
            fileCount: 2,
            payloadBytes: 8
        )
        do {
            let decoded = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                manifest,
                expectedMapID: "label-map",
                header: header
            )
            assertEqual(decoded.target.formatVersion, 2,
                        "target-2 manifest with exact FMA path is accepted")
        } catch {
            assert(false, "valid target-2 manifest is accepted: \(error)")
        }

        let buildingManifest = Data((
            "{\"buildings\":{" +
            "\"classDefaultHeightCount\":0,\"explicitHeightCount\":1," +
            "\"inheritedHeightCount\":0,\"levelsHeightCount\":0," +
            "\"localMedianHeightCount\":0,\"recordCount\":1}," +
            "\"files\":[" +
            "{\"bytes\":4,\"path\":\"VECTMAP/building-map/+0000+0000/0_0.fmb\",\"sha256\":\"\(sha)\"}," +
            "{\"bytes\":4,\"path\":\"VECTMAP/building-map/assets/street-labels.fma\",\"sha256\":\"\(sha)\"}]," +
            "\"mapId\":\"building-map\"," +
            "\"producer\":{\"buildSha256\":\"\(sha)\",\"imageDigest\":\"sha256:\(sha)\"}," +
            "\"schemaVersion\":1," +
            "\"target\":{\"buildingProfileVersion\":1,\"formatVersion\":3," +
            "\"internationalFallback\":\"en\",\"labelLanguages\":[\"en\"]," +
            "\"labelProfileVersion\":1,\"renderer\":\"esp32-fmb\"}}"
        ).utf8)
        do {
            let decoded = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                buildingManifest,
                expectedMapID: "building-map",
                header: BikeMapStreamFormat.Header(
                    formatVersion: 1,
                    flags: 0,
                    manifestBytes: UInt32(buildingManifest.count),
                    signatureEnvelopeBytes: 80,
                    fileCount: 2,
                    payloadBytes: 8
                )
            )
            assertEqual(decoded.target.formatVersion, 3,
                        "target-3 manifest with exact building summary is accepted")
        } catch {
            assert(false, "valid target-3 manifest is accepted: \(error)")
        }

        let nonCanonicalLanguage = Data(
            String(data: manifest, encoding: .utf8)!
                .replacingOccurrences(of: "zh-Hant", with: "ZH-hant").utf8
        )
        do {
            _ = try BikeMapStreamArtifactValidator.decodeAndValidateManifest(
                nonCanonicalLanguage,
                expectedMapID: "label-map",
                header: BikeMapStreamFormat.Header(
                    formatVersion: 1,
                    flags: 0,
                    manifestBytes: UInt32(nonCanonicalLanguage.count),
                    signatureEnvelopeBytes: 80,
                    fileCount: 2,
                    payloadBytes: 8
                )
            )
            assert(false, "non-canonical label languages are rejected")
        } catch {
            guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                assert(false, "invalid label language reports a manifest failure")
                return
            }
        }

        for (prefix, target, accepted, message) in [
            (Data([0x46, 0x4d, 0x42, 4]), 3, true, "target 3 accepts FMB v4"),
            (Data([0x46, 0x4d, 0x42, 3]), 3, false, "target 3 rejects FMB v3"),
            (Data([0x46, 0x4d, 0x42, 3]), 2, true, "target 2 accepts FMB v3"),
            (Data([0x46, 0x4d, 0x42, 2]), 2, false, "target 2 rejects FMB v2"),
            (Data([0x46, 0x4d, 0x42, 3]), 1, false, "target 1 rejects FMB v3"),
            (Data([0x46, 0x4d, 0x42, 2]), 1, true, "target 1 accepts FMB v2"),
        ] {
            do {
                try BikeMapStreamArtifactValidator.validateFileHeader(
                    prefix,
                    path: "VECTMAP/label-map/+0000+0000/0_0.fmb",
                    rendererFormatVersion: target
                )
                assert(accepted, message)
            } catch {
                assert(!accepted, message)
            }
        }
        do {
            try BikeMapStreamArtifactValidator.validateFileHeader(
                Data("BAD1".utf8),
                path: "VECTMAP/label-map/assets/street-labels.fma",
                rendererFormatVersion: 2
            )
            assert(false, "invalid FMA1 header is rejected")
        } catch {
            guard case .invalidManifest = error as? BikeMapStreamFormatError else {
                assert(false, "invalid FMA1 header reports a manifest failure")
                return
            }
        }
    }

    static func testOfflineMapOnboardingPolicy() {
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: false,
                confirmedDeviceMapMissing: false
            ),
            .step(.welcome),
            "first launch starts with the Bicino welcome"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                confirmedDeviceMapMissing: true
            ),
            .step(.download),
            "later confirmed map loss still offers download"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
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
        func decode(_ json: String) -> OfflineMapJob {
            do {
                return try JSONDecoder().decode(
                    OfflineMapJob.self,
                    from: Data(json.utf8)
                )
            } catch {
                fatalError("offline map estimate fixture failed: \(error)")
            }
        }
        let now = Date(timeIntervalSince1970: 1_786_330_000)
        let available = decode(
            """
            {
              "jobId": "estimate-available",
              "status": "converting_features",
              "createdAt": "2026-08-10T00:00:00Z",
              "preparationEstimate": {
                "schemaVersion": 1,
                "modelVersion": "map-preparation-v1",
                "revision": 4,
                "state": "available",
                "generatedAt": "2026-08-10T01:00:00Z",
                "attempt": 1,
                "basedOnPhase": "building_complexity",
                "confidence": "medium",
                "remaining": {"lowerSeconds": 1, "upperSeconds": 59},
                "basis": ["baseline_profile", "future_basis_is_tolerated"],
                "sampleCount": 24
              }
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: available,
                now: now
            ),
            OfflineMapPreparationEstimatePresentation(
                title: "Estimated Remaining",
                value: "Less than a minute"
            ),
            "valid server estimate replaces requested-area copy"
        )
        let oldBackend = decode(
            """
            {
              "jobId": "estimate-old-backend",
              "status": "queued",
              "createdAt": "2026-08-10T00:00:00Z",
              "geometry": {"mode":"bbox","bounds":[0,0,1,1],"areaKm2":1,"vertexCount":4,"routePointCount":0}
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: oldBackend,
                now: Date(timeIntervalSince1970: 1_786_330_020)
            )?.value,
            "Preparation time depends on map complexity",
            "old backend never falls back to requested-area numeric buckets"
        )
        let pendingRetry = decode(
            """
            {
              "jobId": "estimate-retry",
              "status": "queued",
              "createdAt": "2026-08-10T00:00:00Z",
              "preparationEstimate": {
                "schemaVersion": 1,
                "modelVersion": "map-preparation-v1",
                "revision": 5,
                "state": "pending",
                "generatedAt": "2026-08-10T01:00:00Z",
                "attempt": 2,
                "basedOnPhase": "retry"
              }
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: pendingRetry,
                now: now
            )?.value,
            "Re-estimating after retry…",
            "retry pending state has explicit copy"
        )
        let retryWithStaleAvailableEstimate = decode(
            """
            {
              "jobId": "estimate-retry-stale",
              "status": "queued",
              "attempts": 2,
              "createdAt": "2026-08-10T00:00:00Z",
              "preparationEstimate": {
                "schemaVersion": 1,
                "modelVersion": "map-preparation-v1",
                "revision": 4,
                "state": "available",
                "generatedAt": "2026-08-10T01:00:00Z",
                "attempt": 1,
                "basedOnPhase": "building_complexity",
                "confidence": "medium",
                "remaining": {"lowerSeconds": 60, "upperSeconds": 120},
                "basis": ["baseline_profile"],
                "sampleCount": 24
              }
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: retryWithStaleAvailableEstimate,
                now: now
            )?.value,
            "Re-estimating after retry…",
            "newly claimed retry suppresses the previous attempt's stale estimate"
        )
        let malformed = decode(
            """
            {
              "jobId": "estimate-malformed",
              "status": "converting_features",
              "createdAt": "2026-08-10T00:00:00Z",
              "preparationEstimate": {
                "schemaVersion": 1,
                "modelVersion": "map-preparation-v1",
                "revision": 1,
                "state": "available",
                "generatedAt": "2026-08-10T01:00:00Z",
                "attempt": 1,
                "basedOnPhase": "scope_plan",
                "confidence": "low",
                "remaining": {"lowerSeconds": 600, "upperSeconds": 60},
                "basis": ["baseline_profile"],
                "sampleCount": 0
              }
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: malformed,
                now: now
            )?.value,
            "Preparation time depends on map complexity",
            "malformed range does not break job decoding"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.description(
                for: OfflineMapPreparationEstimateRange(
                    lowerSeconds: 1,
                    upperSeconds: 61
                )
            ),
            "Up to 2 min remaining",
            "sub-minute lower bounds round outward"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.description(
                for: OfflineMapPreparationEstimateRange(
                    lowerSeconds: 61,
                    upperSeconds: 241
                )
            ),
            "About 1 min–5 min remaining",
            "minute ranges round outward"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.description(
                for: OfflineMapPreparationEstimateRange(
                    lowerSeconds: 3_601,
                    upperSeconds: 5_401
                )
            ),
            "About 1 hr–1 hr 45 min remaining",
            "hour ranges round outward in fifteen-minute increments"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.description(
                for: OfflineMapPreparationEstimateRange(
                    lowerSeconds: 604_800,
                    upperSeconds: 604_800
                )
            ),
            "About 7 days remaining",
            "seven-day public ceiling remains readable"
        )
    }

    static func testOfflineMapJobProgressDecoding() {
        let payload = Data(
            """
            {
              "jobId": "job-progress",
              "status": "converting_features",
              "buildingProgress": {
                "completedBlocks": 231,
                "totalBlocks": 266,
                "readyChunks": 7,
                "totalChunks": 8,
                "activeChunks": 1,
                "indeterminate": false
              },
              "progress": {
                "phase": "building_preprocessing",
                "unit": "calibration_cells",
                "completed": 2,
                "total": 5,
                "completedBlocks": 79,
                "totalBlocks": 100,
                "fraction": 0.4,
                "indeterminate": false
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
        assertEqual(progress.phase, "building_preprocessing", "map progress decodes phase")
        assertEqual(progress.unit, "calibration_cells", "map progress decodes unit")
        assertEqual(progress.percentage, 40, "map progress calculates phase percentage")
        assert(abs(progress.fraction - 0.79) < 0.000001, "map progress calculates fraction")
        assertEqual(progress.detail, "Preparing deterministic building heights", "map progress explains preprocessing")

        guard let buildingProgress = job.buildingProgress else {
            assert(false, "aggregate building progress should decode")
            return
        }
        assertEqual(buildingProgress.percentage, 87, "aggregate progress uses completed blocks")
        assert(abs((buildingProgress.fraction ?? 0) - (231.0 / 266.0)) < 0.000001, "aggregate progress calculates block fraction")
        assertEqual(
            buildingProgress.detail,
            "231 of 266 map blocks · 7 of 8 chunks ready · 1 active",
            "aggregate progress explains block and chunk completion"
        )
    }

    static func testOfflineMapJobPhaseOnlyProgressDecoding() {
        let payload = Data(
            """
            {
              "jobId": "phase-only-progress",
              "status": "converting_features",
              "progress": {
                "phase": "building_preprocessing",
                "unit": "building_part_association",
                "completed": 4772,
                "total": 4772,
                "fraction": 1.0,
                "indeterminate": false
              }
            }
            """.utf8
        )
        guard let job = try? JSONDecoder().decode(OfflineMapJob.self, from: payload),
              let progress = job.progress else {
            assert(false, "phase-only map progress should decode without block counts")
            return
        }

        assertEqual(progress.completedBlocks, 0, "missing completed block count defaults to zero")
        assertEqual(progress.totalBlocks, 0, "missing total block count defaults to zero")
        assertEqual(progress.phase, "building_preprocessing", "phase-only progress decodes phase")
        assertEqual(progress.unit, "building_part_association", "phase-only progress decodes unit")
        assertEqual(progress.percentage, 100, "phase-only progress uses completed units")
        assert(abs(progress.fraction) < 0.000001, "phase-only progress has no block fraction")
        assertEqual(progress.detail, "Preparing 3D buildings", "phase-only progress explains preprocessing")
    }

    static func testOfflineMapJobProgressAbsentFallback() {
        let payload = Data("{\"jobId\":\"legacy-job\",\"status\":\"converting_features\"}".utf8)
        guard let job = try? JSONDecoder().decode(OfflineMapJob.self, from: payload) else {
            assert(false, "legacy map job should decode without progress")
            return
        }
        assertEqual(job.progress, nil, "legacy server response keeps indeterminate progress fallback")
        assertEqual(job.buildingProgress, nil, "legacy server response keeps aggregate progress optional")
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

        guard let legacyRetry = offlineMapJob(
            jobId: "job-legacy-retry",
            status: "failed",
            errorCode: "map_build_failed",
            attempts: 1,
            maxAttempts: 3,
            createdAt: "2026-07-12T09:00:00Z",
            updatedAt: "2026-07-12T09:00:00Z",
            clientInstallationId: "installation-mine"
        ) else {
            assert(false, "legacy retry recovery fixture should decode")
            return
        }
        let legacySelection = OfflineMapJobRecoverySelector.select(
            jobs: [legacyRetry],
            clientInstallationId: "installation-mine",
            now: Date(timeIntervalSince1970: 1_783_846_805)
        )
        assertEqual(
            legacySelection?.jobId,
            "job-legacy-retry",
            "recovery discovers an old worker's transient failed-to-queued job"
        )
        let staleLegacySelection = OfflineMapJobRecoverySelector.select(
            jobs: [legacyRetry],
            clientInstallationId: "installation-mine",
            now: Date(timeIntervalSince1970: 1_783_846_840)
        )
        assertEqual(
            staleLegacySelection,
            nil,
            "recovery does not repeatedly adopt a permanent legacy-shaped failure"
        )

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
        let cacheWaitPayload = Data(
            """
            {"jobId":"cache-wait-job","status":"converting_features","progress":{"phase":"building_preprocessing","unit":"source_cache_wait","completedBlocks":0,"totalBlocks":10,"indeterminate":true}}
            """.utf8
        )
        let cacheWaitJob = try? JSONDecoder().decode(OfflineMapJob.self, from: cacheWaitPayload)

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
        assertEqual(
            OfflineMapProgressPresentation.value(job: cacheWaitJob, downloadProgress: 0),
            nil,
            "source cache waits remain indeterminate"
        )
        assertEqual(
            cacheWaitJob?.progress?.detail,
            "Waiting for the verified map source",
            "source cache waits have a distinct progress explanation"
        )
    }

    static func testOfflineMapByteProgressPresentation() {
        assertEqual(
            OfflineMapByteProgress(completedBytes: 25, totalBytes: 100).fraction,
            0.25,
            "map download fraction uses completed and total bytes"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 256, totalBytes: 1_024).percentage,
            25,
            "map download percentage is suitable for the settings UI"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 125, totalBytes: 100).percentage,
            100,
            "map download percentage clamps oversized progress"
        )
        assertEqual(
            OfflineMapByteProgress(completedBytes: 10, totalBytes: 0).percentage,
            0,
            "map download percentage handles a missing byte total safely"
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
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "paused persisted jobs keep the resume section reachable"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "idle map settings omit an empty downloading section"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: false,
                hasPendingJob: false,
                hasPendingActivation: true,
                isServerRecoveryCheckPending: false,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "device-owned activation keeps its status section visible"
        )
        assert(
            !OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "launch recovery checks stay hidden until a real map job is found"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: true,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "device activation remains visible during a server recovery check"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: false,
                hasDownloadedPack: false,
                errorMessage: "Map server unavailable"
            ),
            "launch recovery errors remain visible"
        )
        assert(
            OfflineMapDownloadingSectionPresentation.isVisible(
                isBusy: true,
                hasPendingJob: true,
                hasPendingActivation: false,
                isServerRecoveryCheckPending: true,
                hasCurrentJob: true,
                hasDownloadedPack: false,
                errorMessage: nil
            ),
            "a recovered map job remains visible"
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

    static func testSavedMapDeviceTransferPolicy() {
        assert(
            SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "server map processing does not block an independent saved-map transfer"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: true,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "a foreground device transfer blocks a second transfer"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: true,
                isPausedUpload: false,
                isNavigationReady: true
            ),
            "a background upload blocks a different saved map"
        )
        assert(
            SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: true,
                isPausedUpload: true,
                isNavigationReady: true
            ),
            "a paused upload remains resumable through background arbitration"
        )
        assert(
            !SavedMapDeviceTransferPolicy.canStart(
                isDeviceTransferBusy: false,
                hasActiveBackgroundUpload: false,
                isPausedUpload: false,
                isNavigationReady: false
            ),
            "BLE navigation readiness remains required"
        )
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
            fileURLWithPath: "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt"
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
                        rendererFormatVersion: nil,
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
        guard let failed = offlineMapJob(
            status: "failed",
            error: "selected building scope exceeds policy; jobId=failed-job",
            errorCode: "building_scope_exceeded"
        ),
              let running = offlineMapJob(status: "converting_features"),
              let exhausted = offlineMapJob(
                status: "failed",
                error: "worker failed; jobId=exhausted-job",
                errorCode: "map_build_failed"
              ),
              let cancelled = offlineMapJob(status: "cancelled"),
              let expired = offlineMapJob(status: "expired"),
              let legacyRetryFailure = offlineMapJob(
                status: "failed",
                error: "temporary worker failure; jobId=legacy-retry-job",
                errorCode: "map_build_failed",
                attempts: 1,
                maxAttempts: 3
              ),
              let queued = offlineMapJob(status: "queued", attempts: 1, maxAttempts: 3),
              let ready = offlineMapJob(status: "ready", mapId: "map-ready") else {
            assert(false, "terminal poller test jobs should decode")
            return
        }

        var legacyRetryFetchCount = 0
        let legacyRetryResult = try? await OfflineMapJobPoller.waitForReady(
            jobId: "legacy-retry-job",
            pollIntervalNanoseconds: 0,
            fetch: { _ in
                legacyRetryFetchCount += 1
                switch legacyRetryFetchCount {
                case 1...3: return legacyRetryFailure
                case 4: return queued
                default: return ready
                }
            },
            sleep: { _ in },
            onUpdate: { _ in },
            onRetry: {}
        )
        assertEqual(
            legacyRetryResult?.mapId,
            "map-ready",
            "poller tolerates the old worker's transient failed-to-queued transition"
        )
        assertEqual(
            legacyRetryFetchCount,
            5,
            "poller tolerates repeated legacy failures within the bounded grace window"
        )

        var inlineFailureFetchCount = 0
        var inlineFailureClock: TimeInterval = 0
        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "inline-failed-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in
                    inlineFailureFetchCount += 1
                    return legacyRetryFailure
                },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {},
                legacyFailedGraceSeconds: 1,
                monotonicNow: {
                    defer { inlineFailureClock += 2 }
                    return inlineFailureClock
                }
            )
            assert(false, "repeated legacy-shaped failure should be terminal")
        } catch OfflineMapPlatformError.mapJobFailed {
            assertEqual(
                inlineFailureFetchCount,
                2,
                "inline failure stops when the compatibility grace window ends"
            )
        } catch {
            assert(false, "repeated legacy-shaped failure should use platform error")
        }

        assert(exhausted.isTerminal, "a failed final attempt is terminal")

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
        } catch OfflineMapPlatformError.mapJobFailed(let code, let message) {
            assertEqual(code, "building_scope_exceeded", "terminal map job preserves typed server code")
            assert(message.contains("selected building scope"), "terminal map job preserves diagnostic detail")
            let displayMessage = OfflineMapPlatformError
                .mapJobFailed(code: code, message: message)
                .localizedDescription
            assert(
                displayMessage.contains("Choose a smaller area"),
                "building scope failure provides an actionable recovery"
            )
            assert(
                !displayMessage.contains("jobId="),
                "building scope failure hides internal diagnostics from the user"
            )
        } catch {
            assert(false, "terminal map job should use platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "exhausted-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in exhausted },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "exhausted map job should throw")
        } catch OfflineMapPlatformError.mapJobFailed(let code, _) {
            assertEqual(code, "map_build_failed", "exhausted map job preserves its stable code")
        } catch {
            assert(false, "exhausted map job should use platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "cancelled-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in cancelled },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "cancelled map job should throw")
        } catch OfflineMapPlatformError.mapJobCancelled {
            assert(
                OfflineMapPlatformError.mapJobCancelled.localizedDescription
                    .contains("was cancelled"),
                "cancelled map job explains what happened"
            )
        } catch {
            assert(false, "cancelled map job should use its typed platform error")
        }

        do {
            _ = try await OfflineMapJobPoller.waitForReady(
                jobId: "expired-job",
                pollIntervalNanoseconds: 0,
                fetch: { _ in expired },
                sleep: { _ in },
                onUpdate: { _ in },
                onRetry: {}
            )
            assert(false, "expired map job should throw")
        } catch OfflineMapPlatformError.mapJobExpired {
            assert(
                OfflineMapPlatformError.mapJobExpired.localizedDescription
                    .contains("Start a new download"),
                "expired map job provides the recovery action"
            )
        } catch {
            assert(false, "expired map job should use its typed platform error")
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

    static func testOfflineMapJobFailureMessages() {
        let internalDiagnostic = "internal details; jobId=failed-job; /private/server/path"
        let expectations: [(String?, String)] = [
            ("building_scope_exceeded", "Choose a smaller area"),
            ("building_source_snapshot_changed", "Retry the same area"),
            ("source_cache_unavailable", "temporarily unavailable"),
            ("building_relation_incomplete", "Adjust the selected area slightly"),
            ("building_calibration_unavailable", "3D building data could not be prepared"),
            ("building_scope_policy_invalid", "temporarily misconfigured"),
            ("map_build_failed", "after several attempts"),
            ("map_stream_format_invalid", "generated map data was invalid"),
            ("map_stream_build_failed", "could not be prepared"),
            ("map_stream_signing_failed", "secured for download"),
            ("artifact_storage_failed", "stored for download"),
            ("future_failure_code", "couldn't build this map"),
            (nil, "couldn't build this map"),
        ]

        for (code, recoveryText) in expectations {
            let codeLabel = code ?? "missing code"
            let displayMessage = OfflineMapPlatformError
                .mapJobFailed(code: code, message: internalDiagnostic)
                .localizedDescription
            assert(
                displayMessage.contains(recoveryText),
                "\(codeLabel) provides actionable recovery guidance"
            )
            assert(
                !displayMessage.contains("jobId=") &&
                    !displayMessage.contains("/private/server/path"),
                "\(codeLabel) hides internal diagnostics from the user"
            )
        }
    }

    static func offlineMapJob(
        jobId: String? = nil,
        status: String,
        mapId: String? = nil,
        error: String? = nil,
        errorCode: String? = nil,
        attempts: Int? = nil,
        maxAttempts: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        clientInstallationId: String? = nil,
        clientRequestId: String? = nil,
        installOnDevice: Bool? = nil
    ) -> OfflineMapJob? {
        var payload: [String: Any] = ["jobId": jobId ?? "job-\(status)", "status": status]
        if let mapId { payload["mapId"] = mapId }
        if let error { payload["error"] = error }
        if let errorCode { payload["errorCode"] = errorCode }
        if let attempts { payload["attempts"] = attempts }
        if let maxAttempts { payload["maxAttempts"] = maxAttempts }
        if let createdAt { payload["createdAt"] = createdAt }
        if let updatedAt { payload["updatedAt"] = updatedAt }
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
        guard let savedMapsSectionStart = source.range(
            of: "private struct SavedMapsSettingsSection"
        )?.lowerBound,
        let savedMapRowStart = source.range(
            of: "private struct SavedMapRow",
            range: savedMapsSectionStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "saved-map view source boundaries should be present")
            return
        }
        let settingsRootSource = String(source[..<savedMapsSectionStart])
        let savedMapsSectionSource = String(
            source[savedMapsSectionStart..<savedMapRowStart]
        )
        assert(
            settingsRootSource.contains(
                "item: settingsSheetPresentation,"
            ) &&
                settingsRootSource.contains(
                    "case .savedMapShare(let url):"
                ) &&
                settingsRootSource.contains(
                    "SavedMapShareSheet(url: url)"
                ) &&
                settingsRootSource.contains(
                    "presentCreatedShareIfNeeded"
                ) &&
                !savedMapsSectionSource.contains("createdShareURL") &&
                !savedMapsSectionSource.contains(".sheet("),
            "share-map presentation is item-driven from the stable Settings root"
        )
        assert(
            source.contains("Spacer()\n                    .contentShape(Rectangle())\n                    .onTapGesture {\n                        focusedPackFilename = nil\n                    }"),
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
            source.contains("if item.isActiveOnDevice {") &&
                source.contains("Image(systemName: \"checkmark.circle.fill\")") &&
                source.contains("? \"arrow.clockwise.circle\"") &&
                source.contains(": \"arrow.up.circle\"") &&
                !source.contains("IPhoneDownloadStatusIcon") &&
                !source.contains("Image(systemName: \"iphone\")") &&
                !source.contains("BikeComputerMapStatusIcon") &&
                !source.contains("Text(\"b\")"),
            "saved maps use the same active check and inactive upload icons regardless of origin"
        )
        assert(
            source.contains("Text(\"No offline maps yet\")"),
            "Saved Maps uses the agreed empty-state copy"
        )
        assert(
            source.contains("This map is not saved on this iPhone") &&
                source.contains("is active on the Bike Computer") &&
                source.contains("Transfer \\(displayName) to device"),
            "saved-map presence indicators expose accessible state labels"
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
            source.contains("manager.isAwaitingMapActivationConfirmation") &&
                source.contains("clock.arrow.circlepath") &&
                source.contains("Waiting for the Bike Computer to confirm") &&
                source.contains("bleManager.requestMapTransferStatus()"),
            "ambiguous activation waits for authenticated status instead of offering another upload"
        )
        assert(
            source.contains("isShowingDeleteConfirmation = true") &&
                source.contains("\"Delete Saved Map?\"") &&
                source.contains("Button(\"Delete\", role: .destructive)"),
            "deleting a saved map requires explicit confirmation"
        )
        assert(
            source.contains("if item.canRemoveFromMapLibrary") &&
                source.contains(
                    "Button(\"Remove from Map Library\", role: .destructive)"
                ) &&
                source.contains("manager.removeCatalogMapFromLibrary(map)"),
            "remote-only maps expose a clearly named confirmed library removal action"
        )
        assert(
            source.contains("catalogAvailability?.statusText") &&
                source.contains("catalogAvailability?.canDownload != true") &&
                source.contains("clock.badge.exclamationmark"),
            "catalog rows explain and disable downloads that are pending or incompatible"
        )
        assert(
            source.contains(
                "let catalogArtifactNeedsRefresh = manager.catalogArtifactNeedsRefresh(for: item)"
            ) &&
                source.contains("Label(\"Updated map available\"") &&
                source.contains(".accessibilityLabel(\"Update \\(displayName) on this iPhone\")") &&
                source.contains("manager.isDeviceTransferBusy ||") &&
                source.contains("manager.hasActiveBackgroundUpload ||") &&
                source.contains("isPausedUpload ||"),
            "a stale local catalog artifact offers a current verified download before transfer"
        )
        assert(
            source.contains("SavedMapDeviceTransferPolicy.canStart(") &&
                source.contains("isDeviceTransferBusy: manager.isDeviceTransferBusy") &&
                source.contains("manager.hasActiveBackgroundUpload") &&
                source.contains("if manager.isMapJobProcessing, manager.hasPendingMapJob"),
            "map controls separate server work from conflicting device transfers"
        )
        assert(
            source.contains("SavedMapThumbnail(") &&
                source.contains("let previewImage = manager.previewImage(for: item)") &&
                source.contains("manager.loadPreviewIfNeeded(for: item)") &&
                source.contains(".frame(width: 52, height: 36)"),
            "each saved map shows a fixed-size preview before its editable name"
        )
        assert(
            source.contains("presentedPreview = SavedMapPreviewPresentation(") &&
                source.contains(".sheet(item: $presentedPreview)") &&
                source.contains("SavedMapPreviewSheet(manager: manager, preview: preview)") &&
                source.contains(".accessibilityLabel(\"Show preview for \\(displayName)\")") &&
                source.contains("Button(\"Close\")"),
            "tapping an available saved-map thumbnail opens an accessible preview modal"
        )
        assert(
            source.contains("manager.detailPreviewImage(for: preview.item)") &&
                source.contains("Loading high-resolution preview") &&
                source.contains(".interpolation(.high)") &&
                source.contains(".task(id: preview.id)") &&
                source.contains(
                    "await manager.loadDetailPreviewIfNeeded(for: preview.item)"
                ),
            "the preview modal upgrades its thumbnail through cancellable Retina loading"
        )
        assert(
            source.contains("manager.savedMapListItems(") &&
                source.contains("activeDeviceMap: bleManager.activeDeviceMap") &&
                source.contains("manager.updateActiveDeviceMap(descriptor)"),
            "Saved Maps includes and tracks the connected Bike Computer inventory"
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
            managerSource.contains("size: CGSize(width: 400, height: 240)") &&
                managerSource.contains("scale: 3") &&
                managerSource.contains("detail-preview-v\\(cacheVersion).png") &&
                managerSource.contains("minimumLongestEdge: UInt32 = 600") &&
                managerSource.contains("SavedMapSnapshotPreviewStore.save(") &&
                managerSource.contains("SavedMapDetailPreviewStore.save("),
            "thumbnail and versioned Retina detail previews use independent cache policies"
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

    static func testSettingsSheetPresentationWiring() {
        let settingsURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        let routesURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift"
        )
        guard let settingsSource = try? String(
            contentsOf: settingsURL,
            encoding: .utf8
        ), let routesSource = try? String(
            contentsOf: routesURL,
            encoding: .utf8
        ) else {
            assert(
                false,
                "settings and saved-routes sources should be available to the integration test"
            )
            return
        }

        assert(
            settingsSource.contains(
                "private enum SettingsSheetDestination: Identifiable, Equatable"
            ) &&
                settingsSource.contains(
                    "@State private var presentedSheet: SettingsSheetDestination?"
                ) &&
                settingsSource.contains(
                    "item: settingsSheetPresentation,"
                ) &&
                settingsSource.contains(
                    "presentedSheet = .stravaRouteImport"
                ) &&
                settingsSource.contains("case .stravaRouteImport:") &&
                settingsSource.contains("StravaRouteImportView("),
            "Strava import is item-driven from the stable Settings root"
        )
        assert(
            routesSource.contains("let onImportFromStrava: () -> Void") &&
                routesSource.contains("onImportFromStrava()") &&
                !routesSource.contains("isImportingStrava") &&
                !routesSource.contains(".sheet("),
            "Saved Routes requests presentation without owning a transient sheet"
        )
    }

    static func testStravaRouteCatalogUIWiring() {
        let viewURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/StravaRouteImportView.swift"
        )
        let coordinatorURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Services/StravaIntegrationCoordinator.swift"
        )
        let clientURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Services/StravaIntegrationClient.swift"
        )
        guard let view = try? String(contentsOf: viewURL, encoding: .utf8),
              let coordinator = try? String(
                  contentsOf: coordinatorURL,
                  encoding: .utf8
              ),
              let client = try? String(contentsOf: clientURL, encoding: .utf8)
        else {
            assert(false, "Strava route catalog sources should be available")
            return
        }

        assert(
            view.contains("if coordinator.isRouteCatalogAuthorized {") &&
                view.contains(
                    "routeCatalogSection\n                    routeURLSection"
                ) &&
                view.contains("} else {\n                    connectSection") &&
                view.contains("coordinator.connect()") &&
                view.contains("Text(\"Connect with Strava\")"),
            "the disconnected sheet offers connection while catalog and URL import are authorization-gated"
        )
        assert(
            view.contains("ForEach(coordinator.athleteRoutes)") &&
                view.contains("Text(route.name)") &&
                view.contains("distanceText(route.distanceMeters)") &&
                view.contains("elevationText(route.elevationGainMeters)") &&
                view.contains("route.type.displayName") &&
                view.contains("coordinator.importRoute(route)") &&
                view.contains("Text(\"Import\")"),
            "authorized athlete routes show the required summary and import action"
        )
        assert(
            view.contains("case .idle, .loading:") &&
                view.contains("case .empty, .loaded:") &&
                view.contains("case .loadingMore(let loadedRouteCount):") &&
                view.contains("case .authorizationExpired:") &&
                view.contains("case .failed(let message):") &&
                view.contains("Button(\"Try Again\")"),
            "the route catalog presents loading, empty, pagination, expired, and retryable error states"
        )
        assert(
            coordinator.contains("while true {") &&
                coordinator.contains("client.athleteRoutes(page: page)") &&
                coordinator.contains("guard let nextPage = result.nextPage") &&
                coordinator.contains("page = nextPage") &&
                client.contains("/v1/integrations/strava/routes") &&
                client.contains("URLQueryItem(name: \"page\"") &&
                !view.contains("accessToken") &&
                !view.contains("refreshToken") &&
                !client.contains("accessToken") &&
                !client.contains("refreshToken"),
            "pagination stays behind the installation-authenticated client without exposing Strava tokens"
        )
    }

    static func testLandingMapConnectionStatusPositioning() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/ContentView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let overlayStart = source.range(
                  of: "private var topOverlay: some View"
              )?.lowerBound,
              let overlayEnd = source.range(
                  of: "private var mapAppearance: IPhoneMapAppearance",
                  range: overlayStart..<source.endIndex
              )?.lowerBound
        else {
            assert(false, "landing-map connection overlay source should be available")
            return
        }

        let overlaySource = String(source[overlayStart..<overlayEnd])
        assert(
            overlaySource.contains("ConnectionStatusView(") &&
                overlaySource.contains(".frame(maxWidth: .infinity, alignment: .center)") &&
                overlaySource.contains(".offset(y: -8)"),
            "the landing map raises the Bicino connection status without changing its layout space"
        )
    }

    static func testDeviceScreenUISettingsWiring() {
        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            assert(false, "settings view source should be available to the integration test")
            return
        }

        assert(
            !source.contains("UICustomizationSettingsView") &&
                !source.contains("UI Customization"),
            "Settings removes the standalone UI Customization destination"
        )

        guard let deviceSectionStart = source.range(
            of: "private struct DeviceScreensSettingsSection"
        )?.lowerBound,
        let overlaySectionStart = source.range(
            of: "private struct NavigationOverlaysSettingsSection",
            range: deviceSectionStart..<source.endIndex
        )?.lowerBound,
        let mapStyleStart = source.range(
            of: "private enum MapStyleScreen",
            range: overlaySectionStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "device-screen settings source boundaries should be present")
            return
        }
        let deviceSection = String(source[deviceSectionStart..<overlaySectionStart])
        let overlaySection = String(source[overlaySectionStart..<mapStyleStart])

        assert(
            deviceSection.contains("HStack(spacing: 4)") &&
                deviceSection.contains("Image(systemName: \"gearshape\")") &&
                deviceSection.contains(
                    "width: 44,\n" +
                        "                                    height: 44,\n" +
                        "                                    alignment: .leading"
                ) &&
                deviceSection.contains(".contentShape(Rectangle())") &&
                deviceSection.contains(".buttonStyle(.borderless)") &&
                deviceSection.contains(".labelsHidden()"),
            "map-screen rows keep a close-leading accessible gear and trailing toggle"
        )
        guard let rowText = deviceSection.range(
            of: "Text(screen.title)"
        ),
        let gearCondition = deviceSection.range(
            of: "if let styleScreen = mapStyleScreen(for: screen)",
            range: rowText.upperBound..<deviceSection.endIndex
        ),
        let gearDestination = deviceSection.range(
            of: "MapStyleSettingsView(",
            range: gearCondition.upperBound..<deviceSection.endIndex
        ),
        let destinationBinding = deviceSection.range(
            of: "screen: styleScreen",
            range: gearDestination.upperBound..<deviceSection.endIndex
        ),
        let gearImage = deviceSection.range(
            of: "Image(systemName: \"gearshape\")",
            range: destinationBinding.upperBound..<deviceSection.endIndex
        ),
        let trailingSpacer = deviceSection.range(
            of: "Spacer()",
            range: gearImage.upperBound..<deviceSection.endIndex
        ),
        let screenToggle = deviceSection.range(
            of: "Toggle(",
            range: trailingSpacer.upperBound..<deviceSection.endIndex
        ),
        let screenGetter = deviceSection.range(
            of: "bleManager.isDeviceScreenEnabled(screen)",
            range: screenToggle.upperBound..<deviceSection.endIndex
        ),
        let screenSetter = deviceSection.range(
            of: "bleManager.setDeviceScreen(",
            range: screenGetter.upperBound..<deviceSection.endIndex
        ),
        let setterScreen = deviceSection.range(
            of: "screen,",
            range: screenSetter.upperBound..<deviceSection.endIndex
        ),
        let setterValue = deviceSection.range(
            of: "enabled: $0",
            range: setterScreen.upperBound..<deviceSection.endIndex
        ),
        let lastScreenGuard = deviceSection.range(
            of: ".disabled(bleManager.isOnlyEnabledDeviceScreen(screen))",
            range: setterValue.upperBound..<deviceSection.endIndex
        ) else {
            assert(
                false,
                "each row should keep its routed gear, screen-specific toggle, and last-screen guard"
            )
            return
        }
        assert(
            rowText.lowerBound < gearCondition.lowerBound &&
                gearCondition.lowerBound < gearDestination.lowerBound &&
                gearDestination.lowerBound < destinationBinding.lowerBound &&
                destinationBinding.lowerBound < gearImage.lowerBound &&
                gearImage.lowerBound < trailingSpacer.lowerBound &&
                trailingSpacer.lowerBound < screenToggle.lowerBound &&
                screenToggle.lowerBound < screenGetter.lowerBound &&
                screenGetter.lowerBound < screenSetter.lowerBound &&
                screenSetter.lowerBound < setterScreen.lowerBound &&
                setterScreen.lowerBound < setterValue.lowerBound &&
                setterValue.lowerBound < lastScreenGuard.lowerBound,
            "each map gear sits beside its label before the trailing screen toggle"
        )
        assert(
            deviceSection.contains("case .map:\n            return .map") &&
                deviceSection.contains("case .mapPlusNavigation:") &&
                deviceSection.contains("? .mapPlusNavigation\n                : .map") &&
                deviceSection.contains(
                    "case .navigation, .rideStats, .batteryStatus:\n            return nil"
                ),
            "only Map rows receive gears and legacy firmware opens the shared map profile"
        )
        assert(
            deviceSection.contains(
                "This firmware uses one shared style for Map and Map + Navigation."
            ) &&
                deviceSection.contains(
                    "Shared Map Screens UI settings, affects Map and Map + Navigation"
                ),
            "legacy shared-profile behavior is visible and accurately announced"
        )

        guard let developerStart = source.range(
            of: "private struct DeveloperSettingsView"
        )?.lowerBound else {
            assert(false, "developer settings source boundary should be present")
            return
        }
        let developerSource = String(source[developerStart...])
        let rootSettingsSource = String(source[..<developerStart])
        guard let rootBodyStart = source.range(
            of: "var body: some View {"
        )?.lowerBound,
        let rootBodyEnd = source.range(
            of: "private var shouldPromoteBikeComputerSettings",
            range: rootBodyStart..<source.endIndex
        )?.lowerBound else {
            assert(false, "root settings body boundaries should be present")
            return
        }
        let rootBodySource = String(source[rootBodyStart..<rootBodyEnd])
        assert(
            !rootBodySource.contains("MapLibrarySettingsView") &&
                developerSource.contains(
                    "MapLibrarySettingsView(manager: offlineMapManager)"
                ) &&
                developerSource.contains(
                    "Label(\"Map Library\", systemImage: \"map.circle\")"
                ),
            "Map Library is available only from Developer Settings"
        )
        assert(
            developerSource.contains("Button(action: useProductionMapServer)") &&
                developerSource.contains(
                    "OfflineMapServiceConfig.productionServerURLString"
                ) &&
                developerSource.contains("Button(action: useDevelopmentMapServer)") &&
                developerSource.contains(
                    "OfflineMapServiceConfig.developmentServerURLString"
                ),
            "Developer Settings explicitly selects production or development maps"
        )
        assert(
            !rootSettingsSource.contains("title: \"App Version\"") &&
                developerSource.contains("Section(header: Text(\"App\"))") &&
                developerSource.contains("title: \"App Version\"") &&
                developerSource.contains("value: appVersionText"),
            "App Version appears only in Developer Settings"
        )
        assert(
            developerSource.contains(
                "NavigationOverlaysSettingsSection()\n        }\n        .navigationTitle(\"Developer Settings\")"
            ),
            "Navigation Overlays is the final Developer Settings form section"
        )
        assert(
            overlaySection.contains(
                "Toggle(\"Route Line\", isOn: $bleManager.showRouteOverlay)\n" +
                    "                .onChange(of: bleManager.showRouteOverlay) { _ in\n" +
                    "                    bleManager.sendVisibilityMask()"
            ) &&
                overlaySection.contains(
                    "Toggle(\"Current Position\", isOn: $bleManager.showCurrentPosition)\n" +
                        "                .onChange(of: bleManager.showCurrentPosition) { _ in\n" +
                        "                    bleManager.sendVisibilityMask()"
                ) &&
                overlaySection.components(
                    separatedBy: "bleManager.sendVisibilityMask()"
                ).count - 1 == 2 &&
                overlaySection.contains(
                    ".disabled(!bleManager.supportsDeviceSettings)"
                ),
            "Navigation Overlays retains both BLE callbacks and its capability guard"
        )
    }

    static func testSavedRouteNamingAndViewWiring() {
        let suite = "saved-route-name-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "route rename test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstRouteID = UUID()
        let secondRouteID = UUID()
        var names = SavedRouteDisplayNames(defaults: defaults)
        assertEqual(
            names.displayName(routeID: firstRouteID, defaultName: "Original"),
            "Original",
            "a route starts with its archive name"
        )
        assertEqual(
            names.rename(
                routeID: firstRouteID,
                defaultName: "Original",
                to: "  Riverside Ride  "
            ),
            "Riverside Ride",
            "route rename trims surrounding whitespace"
        )
        names.persist(to: defaults)
        var restoredNames = SavedRouteDisplayNames(defaults: defaults)
        assertEqual(
            restoredNames.displayName(
                routeID: firstRouteID,
                defaultName: "Original"
            ),
            "Riverside Ride",
            "route rename survives app restart"
        )
        assertEqual(
            restoredNames.rename(
                routeID: firstRouteID,
                defaultName: "Original",
                to: "  \n "
            ),
            "Riverside Ride",
            "blank route rename preserves the existing name"
        )
        _ = restoredNames.rename(
            routeID: secondRouteID,
            defaultName: "Second",
            to: "Second Ride"
        )
        assert(restoredNames.remove(routeID: secondRouteID),
               "deleting a route removes its local display name")
        assertEqual(
            restoredNames.displayName(
                routeID: secondRouteID,
                defaultName: "Second"
            ),
            "Second",
            "pruned routes fall back to their archive name"
        )

        var interaction = SavedRouteRenameInteraction()
        assertEqual(
            interaction.begin(routeID: firstRouteID, currentName: "Original"),
            nil,
            "starting a route rename has no previous draft"
        )
        interaction.updateDraft("Morning Ride")
        assertEqual(
            interaction.finishIfFocusMoved(to: firstRouteID),
            nil,
            "focus inside the active route field keeps editing"
        )
        assertEqual(
            interaction.finishIfFocusMoved(to: nil),
            SavedRouteRenameCommit(
                routeID: firstRouteID,
                proposedName: "Morning Ride"
            ),
            "moving focus commits the matching route rename"
        )

        let sourceURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift"
        )
        guard let source = try? String(
            contentsOf: sourceURL,
            encoding: .utf8
        ) else {
            assert(false, "Saved Routes source should be available")
            return
        }
        assert(
            source.contains("Text(\"Saved Routes\")") &&
                source.contains(
                    "Save GPX route files to your Apple watch for offline navigation"
                ),
            "Saved Routes uses the requested title and explanatory copy"
        )
        assert(
            source.contains("TextField(\n                \"Route name\"") &&
                source.contains("SavedRouteRenameInteraction()"),
            "saved route names are editable inline"
        )
        assert(
            source.contains("case .ready:") &&
                source.contains("Image(systemName: \"checkmark.circle.fill\")") &&
                !source.contains("Ready on Watch"),
            "Watch-ready routes use an inline green status icon without a second-row label"
        )
        assert(
            !source.contains("Powered by Strava") &&
                source.contains("Link(\"View on Strava\", destination: url)"),
            "saved Strava routes keep their source link without the Powered by Strava label"
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
                rendererFormatVersion: nil,
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

    @MainActor
    static func testSavedMapInventoryMergesOnlyExactDeviceContent() {
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saved-map-inventory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let manifestData = Data("""
        {"schemaVersion":1,"mapId":"map-1","displayName":"Phone Map"}
        """.utf8)
        let packURL = cacheDirectory.appendingPathComponent("map-1.zip")
        try? makeStoredZip(entries: [
            ("manifest.json", manifestData),
            ("VECTMAP/map-1/+0032+0008/123_456.fmb", Data("map-block".utf8)),
        ]).write(to: packURL)
        let suite = "saved-map-inventory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )
        let exactSession = MapTransferSessionIdentity.make(
            mapId: "map-1",
            manifestData: manifestData
        )
        let exactDevice = DeviceActiveMapDescriptor(
            mapID: "map-1",
            sessionID: exactSession,
            displayName: "Device Name",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!

        var items = manager.savedMapListItems(activeDeviceMap: exactDevice)
        assertEqual(items.count, 1, "the exact device and iPhone map collapse into one row")
        assert(items[0].isOnIPhone && items[0].isActiveOnDevice,
               "the merged row exposes both presence states")
        assertEqual(items[0].displayName, "Phone Map",
                    "a local saved name wins when exact content is merged")

        let regeneratedDevice = DeviceActiveMapDescriptor(
            mapID: "map-1",
            sessionID: "different-session",
            displayName: "Cloned SD Map",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!
        items = manager.savedMapListItems(activeDeviceMap: regeneratedDevice)
        assertEqual(items.count, 2,
                    "same map ID with different content stays as separate device and phone rows")
        assert(!items[0].isOnIPhone && items[0].isActiveOnDevice,
               "device-only content sorts first and is not claimed by the iPhone")
        assert(items[1].isOnIPhone && !items[1].isActiveOnDevice,
               "the local regenerated map remains uploadable")

        items = manager.savedMapListItems(activeDeviceMap: nil)
        assertEqual(items.count, 1, "disconnect removes live device-only inventory")
        assert(items[0].isOnIPhone && !items[0].isActiveOnDevice,
               "disconnect preserves the iPhone cache without stale device presence")

        manager.deleteCachedPack(at: packURL)
        items = manager.savedMapListItems(activeDeviceMap: exactDevice)
        assertEqual(items.count, 1,
                    "deleting the iPhone copy keeps the active device map visible")
        assert(!items[0].isOnIPhone && items[0].isActiveOnDevice,
               "local deletion converts a merged row into device-only inventory")
        assert(manager.savedMapListItems(activeDeviceMap: nil).isEmpty,
               "no local or connected-device map produces an empty inventory")

        let streamCacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "saved-stream-inventory-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: streamCacheDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: streamCacheDirectory) }
        let streamURL = streamCacheDirectory.appendingPathComponent("stream-map.bmap")
        try? Data([1, 2, 3, 4]).write(to: streamURL)
        let signedReceipt = String(repeating: "d", count: 64)
        let streamArtifact = OfflineMapArtifact(
            format: OfflineMapArtifact.bikeMapStreamFormat,
            mediaType: "application/vnd.openbikecomputer.map-stream",
            filename: streamURL.lastPathComponent,
            objectKey: "maps/stream-map.bmap",
            bytes: 4,
            sha256: String(repeating: "a", count: 64),
            manifestReceipt: String(repeating: "b", count: 64),
            signedManifestReceipt: signedReceipt
        )
        let streamMetadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: "stream-map",
            displayName: "Stream Map",
            localArtifactFilename: streamURL.lastPathComponent,
            streamFormatVersion: 1,
            rendererFormatVersion: 2,
            jobID: nil,
            serverURLString: nil,
            clientInstallationID: nil,
            primaryArtifact: streamArtifact,
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
            expectedActiveMapID: nil,
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil
        )
        try? SavedMapArtifactMetadataStore.save(streamMetadata, for: streamURL)
        let streamManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: streamCacheDirectory
        )
        let legacySession = "stream-map-legacy-session"
        let legacyDevice = DeviceActiveMapDescriptor(
            mapID: "stream-map",
            sessionID: legacySession
        )!
        assertEqual(
            streamManager.savedMapListItems(activeDeviceMap: legacyDevice).count,
            2,
            "a stream pack does not claim an unknown legacy fallback session"
        )
        streamManager.updateSavedMapTransferMetadata(
            mapID: "stream-map",
            protocolVersion: 1,
            streamFormatVersion: nil,
            sessionID: legacySession,
            outcome: "installed"
        )
        let refreshedItems = streamManager.savedMapListItems(
            activeDeviceMap: legacyDevice
        )
        assertEqual(refreshedItems.count, 1,
                    "recorded legacy transfer identity refreshes the live inventory")
        assert(refreshedItems[0].isOnIPhone && refreshedItems[0].isActiveOnDevice,
               "protocol-v1 fallback installation merges without an app relaunch")
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
            let activeSession = statusRequests == 1 ? "old-session" : "session-1"
            let body = Data("""
            {"activeMapId":"map-1","activeSessionId":"\(activeSession)","activeManifestReceipt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","activeMapDisplayName":"Singapore new","activeMapBoundsE7":[1038375134,12767316,1038683621,13075725],"activation":{"status":"\(state)","sequence":8,"sessionId":"session-1","mapId":"map-1","step":3,"steps":3,"progress":100}}
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
        assertEqual(bleManager.activeDeviceMap?.mapID, "map-1",
                    "authenticated HTTP status refreshes the active map row")
        assertEqual(bleManager.activeDeviceMap?.sessionID, "session-1",
                    "the active row keeps the exact installed stream session")
        assertEqual(bleManager.activeDeviceMap?.manifestReceipt,
                    String(repeating: "a", count: 64),
                    "the active row keeps the authenticated manifest receipt")
        assertEqual(bleManager.activeDeviceMap?.displayName, "Singapore new",
                    "the active row uses the device-confirmed map name")
        assertEqual(bleManager.mapTransferActivationStep, 3,
                    "HTTP reconciliation projects terminal activation progress")
        assertEqual(bleManager.mapTransferActivationProgress, 100,
                    "HTTP reconciliation projects terminal activation completion")

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
          "activeManifestReceipt": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "activeMapDisplayName": "Old Map",
          "activeMapBoundsE7": [1037500000, 12400000, 1039300000, 13700000],
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
        assertEqual(status.activeManifestReceipt, String(repeating: "a", count: 64),
                    "HTTP status exposes the active manifest receipt")
        assertEqual(status.activeMapDisplayName, "Old Map",
                    "HTTP status exposes the active display name")
        assertEqual(status.activeMapBoundsE7,
                    [1_037_500_000, 12_400_000, 1_039_300_000, 13_700_000],
                    "HTTP status exposes normalized preview bounds")

        let bleManager = BLEManager()
        bleManager.applyAuthenticatedMapTransferStatus(status)
        assertEqual(bleManager.activeDeviceMap?.mapID, "old-map",
                    "authenticated HTTP status updates the active-device model")
        assertEqual(bleManager.activeDeviceMap?.sessionID, "old-map-session",
                    "authenticated HTTP status preserves the active session")
        assertEqual(bleManager.mapTransferActivationStatus, "failed",
                    "authenticated HTTP status projects activation state")
        assertEqual(
            bleManager.mapTransferActivationError,
            "file_sha256: sha mismatch for VECTMAP/new-map/1.fmb",
            "authenticated HTTP status projects the device activation error"
        )
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
        assertEqual(queue.metrics.enqueuedFrames, 3,
                    "diagnostic metrics count accepted regular frames")
        assertEqual(queue.metrics.flushedFrames, 2,
                    "diagnostic metrics count flushed frames")
        assertEqual(queue.metrics.droppedFrames, 1,
                    "diagnostic metrics count capacity evictions")
        assertEqual(queue.metrics.currentDepth, 0,
                    "diagnostic metrics expose current queue depth")
        assertEqual(queue.metrics.maxDepth, 2,
                    "diagnostic metrics retain peak bounded depth")

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

        var protectedSettingQueue = NavigationWriteQueue(maxCount: 1)
        assert(protectedSettingQueue.enqueueAtomically([
            NavigationWrite(data: Data([5]), label: "protected-transfer")
        ]), "a protected transfer can occupy the bounded queue")
        assert(!protectedSettingQueue.enqueueCoalescing(
            NavigationWrite(
                data: Data([6]),
                label: "automatic-display-off",
                coalescingKey: DeviceBLEProtocol.automaticDisplayOffSettingCoalescingKey
            ),
            prioritized: false
        ), "automatic display-off rejects a full protected queue instead of reporting success")
        assertEqual(protectedSettingQueue.count, 1,
                    "a rejected automatic display-off write preserves the protected transfer")

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
                onDrop: { supersededStatusWasDropped = true },
                coalescingKey: "destination-status"
            )
        ]), "first priority status is admitted despite a full catalog lane")
        assert(catalogAndStatusQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([9]),
                label: "terminal-status",
                coalescingKey: "destination-status"
            )
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

        var metricsQueue = NavigationWriteQueue(maxCount: 1)
        assert(metricsQueue.enqueueCoalescing(NavigationWrite(
            data: Data([1]),
            label: "gps-1",
            writeClass: .gpsPosition,
            coalescingKey: "gps"
        ), prioritized: false), "first replaceable state is accepted")
        assert(metricsQueue.enqueueCoalescing(NavigationWrite(
            data: Data([2]),
            label: "gps-2",
            writeClass: .gpsPosition,
            coalescingKey: "gps"
        ), prioritized: false), "new state replaces the stale state")
        assert(!metricsQueue.enqueueAtomically([
            NavigationWrite(data: Data([3]), label: "oversized-1"),
            NavigationWrite(data: Data([4]), label: "oversized-2")
        ]), "oversized atomic diagnostics fixture is rejected")
        metricsQueue.flush(canSend: { false }) { _ in
            assert(false, "backpressured queue must not write")
        }
        metricsQueue.noteRetryScheduled()
        metricsQueue.flush(canSend: { true }) { _ in }
        metricsQueue.enqueue(NavigationWrite(data: Data([5]), label: "clear"))
        metricsQueue.removeAll()

        let queueMetrics = metricsQueue.snapshotMetricsAndReset()
        assertEqual(NavigationWriteQueueMetrics.schemaVersion, 2,
                    "queue metrics schema is explicitly versioned")
        assertEqual(queueMetrics.enqueuedFrames, 3,
                    "queue metrics distinguish accepted frames")
        assertEqual(queueMetrics.flushedFrames, 1,
                    "queue metrics count transport writes")
        assertEqual(queueMetrics.rejectedFrames, 2,
                    "queue metrics count rejected atomic frames")
        assertEqual(queueMetrics.coalescedFrames, 1,
                    "queue metrics count superseded replaceable state")
        assertEqual(queueMetrics.coalescedFrames(for: .gpsPosition), 1,
                    "queue metrics attribute coalescing to GPS state")
        assertEqual(queueMetrics.clearedFrames, 1,
                    "queue metrics count disconnect-style clearing")
        assertEqual(queueMetrics.retrySchedules, 1,
                    "queue metrics count retry scheduling")
        assertEqual(queueMetrics.backpressureStops, 1,
                    "queue metrics count transport backpressure")
        assertEqual(queueMetrics.currentDepth, 0,
                    "queue metrics depth returns to zero")
        assertEqual(metricsQueue.metrics.enqueuedFrames, 0,
                    "queue interval metrics reset after a snapshot")
        assertEqual(metricsQueue.metrics.maxDepth, 0,
                    "an empty queue starts the next interval at zero depth")

        var boundaryQueue = NavigationWriteQueue(maxCount: 3)
        boundaryQueue.enqueue(NavigationWrite(data: Data([6]), label: "pending-1"))
        boundaryQueue.enqueue(NavigationWrite(data: Data([7]), label: "pending-2"))
        let boundarySnapshot = boundaryQueue.snapshotMetricsAndReset()
        assertEqual(boundarySnapshot.enqueuedFrames, 2,
                    "the completed interval retains pre-boundary events")
        assertEqual(boundarySnapshot.currentDepth, 2,
                    "the completed interval reports pending queue depth")

        let nextBoundarySnapshot = boundaryQueue.snapshotMetricsAndReset()
        assertEqual(nextBoundarySnapshot.enqueuedFrames, 0,
                    "the next interval starts with cleared event counters")
        assertEqual(nextBoundarySnapshot.currentDepth, 2,
                    "the next interval retains pending queue depth")
        assertEqual(nextBoundarySnapshot.maxDepth, 2,
                    "the next interval starts at the existing queue depth")

        var boundaryWrites: [Data] = []
        boundaryQueue.flush(canSend: { _ in true }) { write in
            boundaryWrites.append(write.data)
        }
        assertEqual(boundaryWrites, [Data([6]), Data([7])],
                    "metrics snapshots do not mutate pending writes")
    }

    static func testGPSQueuePolicy() {
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 36,
            protectionOverhead: 22,
            withResponseMaximum: 58,
            withoutResponseMaximum: 58
        ), .nativeWithResponse,
                    "protected 36-byte GPS quality packets fit the acknowledged route")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .nativeWithResponse,
                    "map-driving GPS prefers acknowledged native delivery")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: false,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .nativeWithResponse,
                    "GPS remains acknowledged when that is the only native transport")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: false,
            hasNativeWriteWithoutResponse: false,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 512,
            withoutResponseMaximum: 512
        ), .navigationFallback,
                    "missing native GPS uses the reliable navigation endpoint")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 20,
            withoutResponseMaximum: 512
        ), .nativeWithoutResponse,
                    "GPS uses native write-without-response only when acknowledgment is unavailable")
        assertEqual(GPSPositionWriteRouting.route(
            hasNativeWriteWithResponse: true,
            hasNativeWriteWithoutResponse: true,
            payloadLength: 30,
            protectionOverhead: 22,
            withResponseMaximum: 20,
            withoutResponseMaximum: 20
        ), .navigationFallback,
                    "insufficient native MTU falls back without dropping current GPS")

        let channelManager = BLEManager()
        let writeSession = AuthenticatedBLEWriteSession(
            ownerKey: Data((0..<32).map(UInt8.init)),
            deviceID: "00112233445566778899aabbccddeeff",
            clientNonce: "102132435465768798a9babbdcddedef",
            serverNonce: "ffeeddccbbaa99887766554433221100"
        )
        let gpsPayload = DeviceGPSPacketBuilder.data(
            lat: 1.3,
            lon: 103.8,
            heading: 45
        )
        let protectedGPS = channelManager.devicePayloadForTesting(
            gpsPayload,
            for: DeviceBLEProtocol.gpsPositionCharacteristicUUID,
            authenticatedWriteSession: writeSession
        )
        let protectedNavigation = channelManager.devicePayloadForTesting(
            gpsPayload,
            for: DeviceBLEProtocol.navigationCharacteristicUUID,
            authenticatedWriteSession: writeSession
        )
        assertEqual(
            protectedGPS?.count,
            gpsPayload.count + AuthenticatedBLEWriteSession.frameOverhead,
            "native GPS capacity accounts for authenticated framing overhead"
        )
        assert(protectedGPS != protectedNavigation,
               "native GPS uses its characteristic-bound authenticated channel")

        var transportReady = false
        var queue = NavigationWriteQueue(maxCount: 4, priorityMaxCount: 2)
        func gpsWrite(_ value: UInt8) -> NavigationWrite {
            NavigationWrite(
                data: Data([value]),
                label: "gps-\(value)",
                transportCanSend: { transportReady },
                transportExpectsWriteResponse: false,
                writeClass: .gpsPosition,
                coalescingKey: DeviceBLEProtocol.gpsPositionCoalescingKey
            )
        }

        assert(queue.enqueueCoalescing(gpsWrite(1), prioritized: false),
               "first GPS state enters the regular lane")
        assert(queue.enqueueCoalescing(gpsWrite(2), prioritized: false),
               "second GPS state replaces the first pending state")
        assert(queue.enqueueAtomically([
            NavigationWrite(
                data: Data([40]),
                label: "route-1",
                writeClass: .route
            ),
            NavigationWrite(
                data: Data([41]),
                label: "route-2",
                writeClass: .route
            )
        ]), "protected route chunks are admitted atomically")
        assert(queue.enqueueCoalescing(NavigationWrite(
            data: Data([9]),
            label: "maneuver",
            transportCanSend: { true },
            transportExpectsWriteResponse: true,
            writeClass: .navigationSnapshot,
            coalescingKey: DeviceBLEProtocol.navigationSnapshotCoalescingKey
        ), prioritized: true), "complete maneuver state enters the priority lane")

        var sent: [Data] = []
        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }, maxWrites: 1) { sent.append($0.data) }
        assertEqual(sent, [Data([9])],
                    "maneuver state is delivered ahead of stalled GPS and route traffic")

        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }) { _ in
            assert(false, "write-without-response backpressure must stop GPS dequeue")
        }
        assert(queue.enqueueCoalescing(gpsWrite(3), prioritized: false),
               "latest GPS replaces the stalled pending value")
        assert(queue.enqueueCoalescing(gpsWrite(4), prioritized: false),
               "another GPS update still leaves only one pending position")

        transportReady = true
        queue.flush(canSend: { write in
            write.transportCanSend?() ?? true
        }) { sent.append($0.data) }
        assertEqual(sent, [Data([9]), Data([40]), Data([41]), Data([4])],
                    "recovery preserves the atomic route and sends only latest GPS state")
        assertEqual(queue.metrics.coalescedFrames(for: .gpsPosition), 3,
                    "GPS replacements are attributed separately in diagnostics")

        var priorityCapacityQueue = NavigationWriteQueue(
            maxCount: 1,
            priorityMaxCount: 6
        )
        assert(priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([20]),
                label: "workout-core",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
            ),
            NavigationWrite(
                data: Data([21]),
                label: "workout-extended",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
            )
        ]), "complete workout pair retains its existing priority transaction")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([22]),
            label: "destination-status",
            writeClass: .transfer,
            coalescingKey: "destination-status"
        ), prioritized: true), "destination status retains its priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([23]),
            label: "maneuver",
            writeClass: .navigationSnapshot,
            coalescingKey: DeviceBLEProtocol.navigationSnapshotCoalescingKey
        ), prioritized: true), "maneuver has a dedicated fourth priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([24]),
            label: "transfer-control",
            writeClass: .transfer,
            coalescingKey: "transfer.map.control"
        ), prioritized: true), "transfer control has a dedicated fifth priority slot")
        assert(priorityCapacityQueue.enqueueCoalescing(NavigationWrite(
            data: Data([25]),
            label: "transfer-status",
            writeClass: .transfer,
            coalescingKey: "transfer.device.status"
        ), prioritized: true), "transfer status has a dedicated sixth priority slot")
        assertEqual(priorityCapacityQueue.count, 6,
                    "workout, navigation, and transfer priority traffic coexist")
        assert(!priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([28]),
                label: "issue-marker",
                writeClass: .transfer
            )
        ]), "an unkeyed issue marker cannot evict active priority controls")
        assertEqual(priorityCapacityQueue.count, 6,
                    "a rejected marker preserves every active priority control")
        assert(priorityCapacityQueue.enqueuePrioritizedAtomically([
            NavigationWrite(
                data: Data([26]),
                label: "new-workout-core",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
            ),
            NavigationWrite(
                data: Data([27]),
                label: "new-workout-extended",
                writeClass: .workoutTelemetry,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
            )
        ]), "new workout pair replaces only its prior complete pair")
        var priorityCapacityWrites: [Data] = []
        priorityCapacityQueue.flush(canSend: { true }) {
            priorityCapacityWrites.append($0.data)
        }
        assertEqual(
            priorityCapacityWrites,
            [
                Data([22]), Data([23]), Data([24]), Data([25]),
                Data([26]), Data([27])
            ],
            "workout replacement preserves navigation and transfer priority state"
        )
        assertEqual(
            priorityCapacityQueue.metrics.coalescedFrames(
                for: .workoutTelemetry
            ),
            2,
            "atomic workout replacement is recorded as class coalescing"
        )

        var dropMetricsQueue = NavigationWriteQueue(maxCount: 1)
        dropMetricsQueue.enqueue(NavigationWrite(
            data: Data([30]),
            label: "old-gps",
            writeClass: .gpsPosition
        ))
        assert(dropMetricsQueue.enqueue(NavigationWrite(
            data: Data([31]),
            label: "new-setting",
            writeClass: .settingsControl
        )), "ordinary overflow evicts the oldest packet")
        assertEqual(dropMetricsQueue.metrics.droppedFrames(for: .gpsPosition), 1,
                    "drop metrics attribute capacity eviction to packet class")

        var uptime: TimeInterval = 10
        var ageQueue = NavigationWriteQueue(
            maxCount: 1,
            now: { uptime }
        )
        assert(ageQueue.enqueueCoalescing(gpsWrite(5), prioritized: false),
               "age fixture admits one pending GPS state")
        uptime = 10.25
        ageQueue.noteRetryScheduled()
        uptime = 10.5
        assert(ageQueue.enqueueCoalescing(gpsWrite(6), prioritized: false),
               "coalescing retains the active transport retry interval")
        uptime = 11
        assertEqual(ageQueue.metrics.oldestPendingAgeMs, 500,
                    "oldest age follows the newest pending GPS replacement")
        assertEqual(ageQueue.metrics.retryAgeMs, 750,
                    "retry age survives replacement while backpressure remains active")
    }

    static func testRendererBenchmarkProtocol() {
        let fixtureURL = URL(fileURLWithPath:
            "ios-app/BikeComputer/BikeComputer/Resources/renderer-benchmark-shanghai-v1.json"
        )
        guard let fixtureData = try? Data(contentsOf: fixtureURL),
              let fixture = try? RendererBenchmarkFixture.decode(fixtureData) else {
            assert(false, "checked-in renderer benchmark fixture decodes")
            return
        }
        assertEqual(fixture.id, "shanghai-center-renderer-v1",
                    "renderer benchmark keeps its pinned fixture identity")
        assertEqual(fixture.cadenceHz, 1,
                    "renderer benchmark fixture stays at exactly 1 Hz")
        assertEqual(fixture.points.count, 120,
                    "renderer benchmark fixture retains the full Shanghai loop")
        let shortFixture = Data(
            #"{"schema":1,"id":"short","cadenceHz":1,"nominalSpeedMetersPerSecond":4,"points":[{"latitude":31.2,"longitude":121.4},{"latitude":31.2001,"longitude":121.4001}]}"#.utf8
        )
        assert(
            (try? RendererBenchmarkFixture.decode(shortFixture)) == nil,
            "renderer replay rejects fixtures shorter than the declared 60-second window"
        )

        let fixtureHash = Data(SHA256.hash(data: fixtureData))
        assertEqual(
            fixtureHash.map { String(format: "%02x", $0) }.joined(),
            "d5171f6b30478a09948381bbdb86da33752bc646fa6077153f69a4bd840eb36e",
            "fixture edits require an explicit pinned-hash update"
        )
        guard let geometry = RendererBenchmarkRouteGeometry.data(
            fixture: fixture,
            sampleIndex: 119
        ) else {
            assert(false, "renderer benchmark geometry encodes across loop boundary")
            return
        }
        assertEqual(geometry.count, 164,
                    "40 renderer route points use the bounded wire payload")
        assertEqual(
            readInt32LE(geometry, offset: 0),
            Int32(fixture.points[119].latitude * 1_000_000),
            "renderer geometry starts at the selected fixture sample"
        )

        guard let marker = RendererBenchmarkMarkerPacket.data(
            fixtureSHA256: fixtureHash,
            sampleIndex: 119,
            sampleCount: fixture.points.count,
            loop: 0x1234_5678
        ) else {
            assert(false, "valid renderer benchmark marker encodes")
            return
        }
        assertEqual(marker.count, 44, "renderer marker has the firmware frame size")
        assertEqual(String(data: marker.prefix(4), encoding: .utf8), "RBM1",
                    "renderer marker prefix stays firmware-compatible")
        assertEqual(readUInt16LE(marker, offset: 36), 119,
                    "renderer marker carries its sample index")
        assertEqual(readUInt16LE(marker, offset: 38), 120,
                    "renderer marker carries fixture sample count")
        assertEqual(readUInt32LE(marker, offset: 40), 0x1234_5678,
                    "renderer marker carries replay loop")

        guard let window = RendererBenchmarkWindowPacket.data(
            profile: .medium,
            repeatNumber: 7,
            runNonce: 0x0102_0304_0506_0708,
            fixtureSHA256: fixtureHash,
            fixtureID: fixture.id
        ) else {
            assert(false, "valid ordinary renderer window encodes")
            return
        }
        assertEqual(String(data: window.prefix(4), encoding: .utf8), "RBW1",
                    "ordinary renderer window prefix stays firmware-compatible")
        assertEqual(window[4], 1, "ordinary renderer window carries schema 1")
        assertEqual(window[5], RendererBenchmarkProfile.medium.rawValue,
                    "ordinary renderer window carries the selected profile")
        assertEqual(readUInt16LE(window, offset: 6), 7,
                    "ordinary renderer window carries repeat number")
        assertEqual(Array(window[8..<16]),
                    [8, 7, 6, 5, 4, 3, 2, 1],
                    "ordinary renderer run nonce is little-endian")
        assertEqual(Int(window[48]), fixture.id.utf8.count,
                    "ordinary renderer window bounds its route identity")

        let body = Data(
            #"{"ok":true,"schema":1,"identity":{},"memory":{},"render":{}}"#.utf8
        )
        var reassembler = RendererDiagnosticsChunkReassembler()
        let chunks = stride(from: 0, to: body.count, by: 17).map {
            body.subdata(in: $0..<min($0 + 17, body.count))
        }
        var completedBody: Data?
        for index in chunks.indices.reversed() {
            var frame = Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
            frame.append(9)
            frame.append(UInt8(index))
            frame.append(UInt8(chunks.count))
            frame.append(chunks[index])
            if case let .complete(reassembled)? = reassembler.consume(frame) {
                completedBody = reassembled
            }
        }
        assertEqual(completedBody, body,
                    "out-of-order renderer chunks reassemble deterministically")
        assert(
            RendererDiagnosticsSnapshotEnvelope.normalizedJSONString(body) != nil,
            "shared renderer snapshot envelope validates"
        )
        var interruptedReassembler = RendererDiagnosticsChunkReassembler()
        var firstInterruptedChunk = Data(
            DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8
        )
        firstInterruptedChunk.append(contentsOf: [3, 0, 2])
        firstInterruptedChunk.append(contentsOf: body.prefix(10))
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .pending,
            "a partial renderer snapshot waits for its remaining chunks"
        )
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .rejected,
            "duplicate renderer chunks fail closed and clear partial state"
        )
        assertEqual(
            interruptedReassembler.consume(firstInterruptedChunk),
            .pending,
            "a fresh renderer transfer can start after duplicate rejection"
        )
        assertEqual(
            interruptedReassembler.consume(
                Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
            ),
            .rejected,
            "malformed renderer chunks clear partial state"
        )
        guard let ordinaryCapture = RendererOrdinaryDiagnosticsCapture.json(
            fixtureID: fixture.id,
            fixtureSHA256: fixtureHash,
            snapshots: [String(decoding: body, as: UTF8.self)],
            generatedAt: Date(timeIntervalSince1970: 0)
        ),
              let ordinaryObject = try? JSONSerialization.jsonObject(
                with: Data(ordinaryCapture.utf8)
              ) as? [String: Any],
              let ordinarySnapshots = ordinaryObject["snapshots"] as? [Any]
        else {
            assert(false, "ordinary diagnostics capture exports valid JSON")
            return
        }
        assertEqual(
            ordinaryObject["kind"] as? String,
            "ordinary-renderer-diagnostics",
            "ordinary capture is machine-identifiable"
        )
        assertEqual(ordinarySnapshots.count, 1,
                    "ordinary capture retains validated snapshots")

        let manager = BLEManager()
        var cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8)
        cap2.append(contentsOf: [1, 0, 0, 4, 0])
        assert(manager.handleDeviceCapabilitiesNotification(cap2),
               "renderer diagnostics CAP2 response is consumed")
        assert(manager.supportsRendererDiagnostics,
               "CAP2 bit 18 enables renderer diagnostics")
        manager.isConnected = true
        manager.isNavigationReady = true
        var writes: [Data] = []
        manager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 185,
            canSend: { true },
            write: { writes.append($0) }
        ))
        assert(manager.beginRendererBenchmarkWindow(
            profile: .medium,
            repeatNumber: 7,
            runNonce: 0x0102_0304_0506_0708,
            fixtureSHA256: fixtureHash,
            fixtureID: fixture.id
        ), "BLE manager queues an ordinary renderer benchmark window")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RBW1", "renderer window uses the authenticated navigation fallback")
        assert(manager.sendRendererBenchmarkMarker(
            fixtureSHA256: fixtureHash,
            sampleIndex: 1,
            sampleCount: fixture.points.count,
            loop: 2
        ), "BLE manager queues renderer benchmark markers")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RBM1", "renderer marker uses the authenticated navigation fallback")
        assert(manager.requestRendererDiagnosticsSnapshot(),
               "BLE manager queues an explicit metrics request")
        assertEqual(String(data: writes.last?.prefix(4) ?? Data(), encoding: .utf8),
                    "RDMS", "renderer metrics request uses the shared prefix")

        var direct = Data(DeviceBLEProtocol.rendererMetricsResponsePrefix.utf8)
        var partial = Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
        partial.append(contentsOf: [5, 0, 2])
        partial.append(contentsOf: body.prefix(10))
        assert(manager.handleRendererDiagnosticsNotification(partial),
               "BLE manager accepts a partial renderer snapshot")
        direct.append(body)
        assert(manager.handleRendererDiagnosticsNotification(direct),
               "BLE manager consumes direct renderer snapshots")
        assertEqual(manager.rendererDiagnosticsRevision, 1,
                    "valid renderer snapshots advance the observable revision")
        var staleRemainder = Data(
            DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8
        )
        staleRemainder.append(contentsOf: [5, 1, 2])
        staleRemainder.append(contentsOf: body.dropFirst(10))
        assert(manager.handleRendererDiagnosticsNotification(staleRemainder),
               "stale chunk remainder is consumed as a new incomplete stream")
        assertEqual(manager.rendererDiagnosticsRevision, 1,
                    "a newer direct snapshot invalidates older partial chunks")
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
        assertEqual(DeviceBLEProtocol.workoutStartRequestPrefix, "WREQ", "device workout starts use WREQ")
        assertEqual(DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask, 4, "PWR honk acknowledgement uses capability bit 2")
        assertEqual(DeviceBLEProtocol.independentMapProfilesCapabilityMask, 8, "independent map profiles use capability bit 3")
        assertEqual(DeviceBLEProtocol.extendedMapVisibilityCapabilityMask, 16, "extended map visibility uses capability bit 4")
        assertEqual(DeviceBLEProtocol.batteryStatusScreenCapabilityMask, 32, "Battery Status support uses capability bit 5")
        assertEqual(DeviceBLEProtocol.destinationPickerCapabilityMask, 64, "destination picker support uses capability bit 6")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCapabilityMask, 128, "workout telemetry uses capability bit 7")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask, 1, "bird's-eye Map + Navigation uses extended capability bit 0")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask, 2, "bird's-eye perspective uses extended capability bit 1")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask, 4, "stronger bird's-eye perspectives use extended capability bit 2")
        assertEqual(DeviceBLEProtocol.streetLabelsCapabilityMask, 1 << 8, "CAP2 bit 8 advertises street-label profiles")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationCapabilityMask, 1 << 9, "CAP2 bit 9 advertises bird's-eye Map + Navigation")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveCapabilityMask, 1 << 10, "CAP2 bit 10 advertises bird's-eye perspective")
        assertEqual(DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveCapabilityMask, 1 << 11, "CAP2 bit 11 advertises stronger bird's-eye perspectives")
        assertEqual(DeviceBLEProtocol.osm3DBuildingsCapabilityMask, 1 << 12, "CAP2 bit 12 advertises OSM 3D buildings")
        assertEqual(DeviceBLEProtocol.explicitInvalidGPSHeadingCapabilityMask, 1 << 13, "CAP2 bit 13 advertises explicit invalid GPS headings")
        assertEqual(DeviceBLEProtocol.scopedWatchControllerCapabilityMask, 1 << 14, "CAP2 bit 14 advertises scoped Watch control")
        assertEqual(DeviceBLEProtocol.rideAutomationCapabilityMask, 1 << 15, "CAP2 bit 15 advertises ride automation without colliding with Watch control")
        assertEqual(DeviceBLEProtocol.remoteDeviceDebugCapabilityMask, 1 << 16, "CAP2 bit 16 advertises remote device debugging without colliding with ride automation")
        assertEqual(DeviceBLEProtocol.gpsPositionQualityV1CapabilityMask, 1 << 17, "CAP2 bit 17 advertises GPS quality v1")
        assertEqual(DeviceBLEProtocol.rendererDiagnosticsCapabilityMask, 1 << 18, "CAP2 bit 18 advertises renderer diagnostics")
        assertEqual(DeviceBLEProtocol.automaticDisplayOffCapabilityMask, 1 << 19, "CAP2 bit 19 advertises automatic display-off")
        assertEqual(DeviceBLEProtocol.rideDiagnosticsCapabilityMask, 1 << 20, "CAP2 bit 20 advertises persistent ride diagnostics")
        assertEqual(DeviceBLEProtocol.detailedRideDiagnosticsCapabilityMask, 1 << 21, "CAP2 bit 21 advertises detailed ride diagnostics")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkWindowPrefix, "RBW1", "ordinary renderer windows stay firmware-compatible")
        assertEqual(DeviceBLEProtocol.deviceCapabilitiesVersion, 19, "capability version negotiates detailed ride diagnostics")
        assertEqual(DeviceBLEProtocol.rendererMetricsRequestPrefix, "RDMS", "renderer metrics requests use RDMS")
        assertEqual(DeviceBLEProtocol.rendererMetricsResponsePrefix, "RDMT", "renderer metrics responses use RDMT")
        assertEqual(DeviceBLEProtocol.rendererMetricsChunkPrefix, "RDMC", "renderer metrics chunks use RDMC")
        assertEqual(DeviceBLEProtocol.rendererBenchmarkMarkerPrefix, "RBM1", "renderer replay markers use RBM1")
        assertEqual(DeviceBLEProtocol.workoutTelemetryCharacteristicUUIDString,
                    "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003",
                    "workout telemetry uses the dedicated 128-bit characteristic")
        assertEqual(DeviceBLEProtocol.workoutTelemetryFallbackPrefix, "WTLM",
                    "workout telemetry fallback remains explicitly framed")
        assertEqual(DeviceBLEProtocol.serviceRoadsVisibilityMask, 0x400, "service roads use visibility bit 10")
        assertEqual(DeviceBLEProtocol.tracksVisibilityMask, 0x800, "tracks use visibility bit 11")
        assertEqual(DeviceBLEProtocol.extendedVisibilityMarker, 0x1000, "extended visibility uses marker bit 12")
        assertEqual(DeviceBLEProtocol.defaultStreetWidth, 4, "street width defaults to 4 px")
        assertEqual(DeviceBLEProtocol.absoluteStreetWidth(fromLegacyBoost: 0), 4, "legacy zero boost migrates to the default absolute width")
        assertEqual(DeviceBLEProtocol.absoluteStreetWidth(fromLegacyBoost: 4), 8, "legacy boosts migrate relative to the default width")
        assertEqual(DeviceBLEProtocol.legacyStreetWidthBoost(fromAbsoluteWidth: 1), -3, "one-pixel streets retain the legacy wire encoding")
        assertEqual(DeviceBLEProtocol.legacyStreetWidthBoost(fromAbsoluteWidth: 4), 0, "default street width uses a zero wire boost")
        assertEqual(DeviceBLEProtocol.brightnessSettingID, 12, "brightness uses firmware setting ID 12")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(-1), 5, "brightness clamps below the device range")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(65.4), 65, "brightness uses whole-number percent")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(101), 100, "brightness clamps above the device range")
        assertEqual(DeviceBLEProtocol.normalizedBrightnessPercent(.nan), 100, "invalid stored brightness restores the compatibility default")
        assertEqual(DeviceBLEProtocol.enabledScreensSettingID, 13, "enabled screens use firmware setting ID 13")
        assertEqual(DeviceBLEProtocol.defaultScreenSettingID, 14, "default screen uses firmware setting ID 14")
        assertEqual(DeviceBLEProtocol.disconnectedSleepTimeoutSettingID, 15, "disconnected sleep timeout uses firmware setting ID 15")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID, 16, "Map + Navigation polygon size uses setting ID 16")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID, 17, "Map + Navigation detail uses setting ID 17")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID, 18, "Map + Navigation route width uses setting ID 18")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID, 19, "Map + Navigation zoom uses setting ID 19")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID, 20, "Map + Navigation visibility uses setting ID 20")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID, 21, "Map + Navigation street width uses setting ID 21")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID, 22, "Map + Navigation marker scale uses setting ID 22")
        assertEqual(DeviceBLEProtocol.phoneBatteryLevelSettingID, 23, "phone battery level uses firmware setting ID 23")
        assertEqual(DeviceBLEProtocol.phoneBatteryChargingSettingID, 24, "phone charging state uses firmware setting ID 24")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationBirdsEyeViewSettingID, 25, "bird's-eye Map + Navigation uses setting ID 25")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID, 26, "bird's-eye perspective uses setting ID 26")
        assertEqual(DeviceBLEProtocol.mapLabelDensitySettingID, 27, "Map street-label density uses setting ID 27")
        assertEqual(DeviceBLEProtocol.mapLabelLanguageModeSettingID, 28, "Map street-label language uses setting ID 28")
        assertEqual(DeviceBLEProtocol.mapLabelTextSizeSettingID, 29, "Map street-label size uses setting ID 29")
        assertEqual(DeviceBLEProtocol.mapLabelOrientationSettingID, 30, "Map street-label orientation uses setting ID 30")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelDensitySettingID, 31, "Map + Navigation street-label density uses setting ID 31")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelLanguageModeSettingID, 32, "Map + Navigation street-label language uses setting ID 32")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelTextSizeSettingID, 33, "Map + Navigation street-label size uses setting ID 33")
        assertEqual(DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID, 34, "Map + Navigation street-label orientation uses setting ID 34")
        assertEqual(DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID, 35, "Map + Navigation 3D buildings use setting ID 35")
        assertEqual(DeviceBLEProtocol.automaticDisplayOffSettingID, 36, "automatic display-off uses firmware setting ID 36")
        assertEqual(DeviceBLEProtocol.defaultMapStreetLabelsEnabled, true, "Map street labels default to enabled")
        assertEqual(DeviceBLEProtocol.defaultMapPlusNavigationStreetLabelsEnabled, false, "Map + Navigation street labels default to disabled")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelDensity, 2, "street labels default to Balanced density")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelLanguageMode, 2, "street labels default to Local + Preferred language")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelTextSize, 0, "street labels default to the new Small tier")
        assertEqual(DeviceBLEProtocol.defaultStreetLabelOrientation, 1, "street labels default to Keep Upright")
        assertEqual(DeviceBLEProtocol.effectiveStreetLabelDensity(enabled: true, density: 2), 2, "enabled labels send their selected density")
        assertEqual(DeviceBLEProtocol.effectiveStreetLabelDensity(enabled: false, density: 2), 0, "disabled labels preserve density locally and send wire value zero")
        assertEqual(DeviceBLEProtocol.normalizedStreetLabelDensity(0), 2, "legacy Off density restores Balanced when labels are enabled")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: -1), .standard, "unknown bird's-eye perspectives use Standard")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 0), .gentle, "perspective zero is Gentle")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 2), .strong, "perspective two is Strong")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 3), .veryStrong, "perspective three is Very Strong")
        assertEqual(MapNavigationBirdsEyePerspective.normalized(rawValue: 4), .maximum, "perspective four is Maximum")
        assertEqual(MapNavigationBirdsEyePerspective.maximum.supportedValue(supportsStrongerPerspectives: false), .strong, "older firmware receives Strong instead of Maximum")
        assertEqual(MapNavigationBirdsEyePerspective.maximum.supportedValue(supportsStrongerPerspectives: true), .maximum, "new firmware retains Maximum")
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
            .liveHeartRateZone,
        ],
        pauseOrigin: WorkoutTransitionOrigin? = nil,
        wallElapsedSeconds: Double? = 4_000,
        sessionID: UUID? = UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        ),
        detectorProfileVersion: UInt16? = 1,
        lastTransitionOrigin: WorkoutTransitionOrigin? = .automatic
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
            sourceFlags: sourceFlags,
            pauseOrigin: pauseOrigin,
            wallElapsedSeconds: wallElapsedSeconds,
            sessionID: sessionID,
            detectorProfileVersion: detectorProfileVersion,
            lastTransitionOrigin: lastTransitionOrigin
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
        assertEqual(frames.origin, Data([
            0x03, 0x00, 0x34, 0x12,
            0xA0, 0x0F, 0x00, 0x00,
            0x00, 0x11, 0x22, 0x33,
            0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF,
            0x01, 0x00, 0x02, 0x00,
        ]), "origin workout frame matches the protocol byte vector")
        assertEqual(frames.core.count, 16, "core workout frame is exactly 16 bytes")
        assertEqual(frames.extended.count, 16, "extended workout frame is exactly 16 bytes")
        assertEqual(frames.origin.count, 28, "origin workout frame carries the full Watch session UUID")

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
        assert(idle?.originAvailable == false,
               "idle clear frames never publish a synthetic provenance identity")
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
        assert(live?.sourceFlags.contains(.liveHeartRateZone) == true,
               "mapper reports live heart-rate zone availability")

        let stale = WorkoutDeviceTelemetryMapper.sample(
            presentation: presentation(connectionState: .stale),
            envelope: envelope
        )
        assertEqual(stale?.state, .running,
                    "stale mapping preserves active session state")
        assert(stale?.hasLiveNumerics == false,
               "stale mapping strips live numerics")
        assert(stale?.sessionID == nil,
               "stale mapping strips origin identity with its Watch snapshot")
        assert(stale.flatMap { WorkoutDeviceFrameBuilder.frames(for: $0) }?
            .originAvailable == false,
               "stale relay frames cannot publish zero-identity provenance")

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
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
                    "authentication sends workout metrics and provenance")
        assert(schedule.transmissions.first?.prioritized == true,
               "initial core synchronization uses the priority lane")
        assert(schedule.transmissions.count == 3,
               "initial synchronization includes the complete metric pair and provenance")
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

        var legacyScheduler = WorkoutDeviceRelayScheduler()
        let legacyInitial = legacyScheduler.update(
            frames: initial,
            transportReady: true,
            originTransportReady: false,
            at: start
        )
        assertEqual(legacyInitial.transmissions.map(\.kind), [.core, .extended],
                    "legacy peers receive only the original frame pair")
        for transmission in legacyInitial.transmissions {
            legacyScheduler.didWrite(
                kind: transmission.kind,
                data: transmission.data,
                at: start
            )
        }
        let legacyIdle = legacyScheduler.update(
            frames: initial,
            transportReady: true,
            originTransportReady: false,
            at: start.addingTimeInterval(0.1)
        )
        assert(legacyIdle.transmissions.isEmpty,
               "unsupported provenance does not create phantom work")
        assertEqual(
            legacyIdle.nextEvaluationAt,
            start.addingTimeInterval(5),
            "legacy scheduling waits for the metric heartbeat"
        )

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
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
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
        assertEqual(schedule.transmissions.map(\.kind), [.core, .extended, .origin],
                    "reconnect resynchronizes metrics and provenance once")

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
        partialPairScheduler.didNotWrite(
            kind: .origin,
            data: partialPair.transmissions[2].data
        )
        let retriedPair = partialPairScheduler.update(
            frames: initial,
            transportReady: true,
            at: start.addingTimeInterval(0.1)
        )
        assertEqual(retriedPair.transmissions.map(\.kind), [.core, .extended, .origin],
                    "a partial publication retries metrics and provenance")
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
        assert(DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: 4),
               "transfer handshake refreshes status after one second")
        assert(!DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: 3),
               "transfer handshake does not flood status between refreshes")
        assert(DeviceTransferHandshakePolicy.shouldRequestLegacyMapEnter(attempt: 8),
               "legacy map entry is attempted after two seconds without DSTS")
        assert(!DeviceTransferHandshakePolicy.shouldRequestLegacyMapEnter(attempt: 7),
               "generic DTRN gets the full compatibility grace period")
        assert(!DeviceTransferHandshakePolicy.shouldRequestLegacyMapEnter(attempt: 9),
               "legacy map entry is sent only once")
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
        assert(DeviceNetworkJoinPolicy.reachabilityTimeout >= 30,
               "an accepted local-only accessory network gets a stable association window")
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

        let duplicateTLV = cap2WithConfig + Data([1, 3, 1, 0, 50])
        assert(manager.handleDeviceCapabilitiesNotification(duplicateTLV),
               "malformed CAP2 is consumed for retry")
        assert(!manager.hasReceivedDeviceCapabilities,
               "duplicate CAP2 TLVs are rejected")
        assert(!manager.supportsExplicitInvalidGPSHeading,
               "malformed capabilities clear explicit invalid-heading support")
        assert(!manager.supportsScopedWatchController,
               "malformed capabilities clear scoped Watch support")

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
                    [20, 16, 17, 18, 21, 22, 19, 8, 1, 2, 3, 9, 10, 7],
                    "new firmware receives the independent profile before legacy Map IDs")
        let independentDetail = independentPackets().first { $0[4] == 17 }
        assertEqual(readInt32LE(independentDetail!, offset: 5), 0,
                    "independent Map + Navigation detail remains distinct")

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
                    [20, 16, 17, 18, 21, 22, 19, 25, 8, 1, 2, 3, 9, 10, 7],
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
                    [20, 16, 17, 18, 21, 22, 19, 25, 26, 8, 1, 2, 3, 9, 10, 7],
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
            "Add a Bicino Bike Computer",
            "empty settings presents the bike-computer setup title"
        )
        assertEqual(
            BikeComputerSettingsPresentationPolicy.settingsLinkTitle(
                knownDeviceCount: 0
            ),
            "Connect a Bicino Bike Computer!",
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
        assert(watchdogManager.requestDeviceCapabilities(),
               "watchdog fixture sends one acknowledged write")
        assertEqual(watchdogWrites.count, 1,
                    "watchdog starts only after the write reaches its transport")
        assert(waitForMainLoop(timeout: 1) { watchdogRecoveries == 1 },
               "missing acknowledged completion triggers bounded recovery")
        assert(!watchdogManager.isNavigationReady,
               "stall recovery closes the unusable navigation session")

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
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        assert(manager.requestDeviceTransferMode(.firmware), "firmware transfer enter should queue when BLE is ready")
        assert(manager.requestDeviceTransferMode(.debug), "debug transfer enter should queue when BLE is ready")
        assert(manager.requestDeviceTransferStatus(), "device transfer status should queue when BLE is ready")
        assert(manager.requestDeviceTransferExit(), "device transfer exit should queue when BLE is ready")

        assertEqual(sentPackets.count, 4, "device transfer control should write four packets")
        assertEqual(String(data: sentPackets[0], encoding: .utf8), "DTRNenter|firmware", "firmware enter command uses DTRN frame")
        assertEqual(String(data: sentPackets[1], encoding: .utf8), "DTRNenter|debug", "debug enter command uses DTRN frame")
        assertEqual(String(data: sentPackets[2], encoding: .utf8), "DSTS", "status command uses DSTS frame")
        assertEqual(String(data: sentPackets[3], encoding: .utf8), "DTRNexit", "exit command uses DTRN frame")

        let credentials = RemoteDebugLANCredentials(
            ssid: "Home Wi-Fi",
            password: "local-password"
        )
        assert(credentials != nil, "valid LAN credentials are accepted")
        assert(manager.requestDeviceTransferMode(
            .debug,
            remoteDebugLANCredentials: credentials
        ), "LAN-first debug command should fit one authenticated BLE write")
        let lanPacket = sentPackets[4]
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
        let diagnosticsLANPacket = sentPackets[5]
        assert(
            diagnosticsLANPacket.starts(with: Data("DTRNenter|diagnostics|lan1|".utf8)),
            "LAN-first diagnostics uses its versioned binary envelope"
        )

        assert(manager.requestDeviceTransferMode(
            .debug,
            remoteDebugHotspotFallbackReason: .endpointUnreachable
        ), "endpoint-unreachable fallback command should fit one BLE write")
        assertEqual(
            String(data: sentPackets[6], encoding: .utf8),
            "DTRNenter|debug|h1|e",
            "endpoint fallback reason is persisted by firmware, not only iOS"
        )
        assert(manager.requestDeviceTransferMode(
            .diagnostics,
            remoteDebugHotspotFallbackReason: .endpointUnreachable
        ), "diagnostics endpoint fallback command should fit one BLE write")
        assertEqual(
            String(data: sentPackets[7], encoding: .utf8),
            "DTRNenter|diagnostics|h1|e",
            "diagnostics endpoint fallback requests a protected hotspot"
        )

        let session = DeviceTransferSession(
            mode: .debug,
            baseURL: URL(string: "http://192.168.4.1:8080")!,
            accessPointSSID: "BikeComputer-Transfer",
            accessPointPassphrase: "hotspot-secret",
            sessionToken: "fragment-secret",
            hotspotFallback: true,
            hotspotFallbackReason: "endpoint_unreachable"
        )
        assertEqual(
            RemoteDeviceDebugSessionPolicy.browserURL(for: session)?.absoluteString,
            "http://192.168.4.1:8080/device-debug/#fragment-secret",
            "browser URL keeps the debug token in the fragment"
        )
        let details = RemoteDeviceDebugSessionPolicy.sessionDetails(
            for: session,
            target: "WAVESHARE_AMOLED_175",
            deviceName: "Bicino"
        )
        assert(!details.contains("fragment-secret"),
               "copyable session details redact the transfer token")
        assert(!details.contains("hotspot-secret"),
               "copyable session details redact the hotspot password")
        assert(details.contains("Fallback reason: endpoint_unreachable"),
               "secret-free diagnostics retain the firmware fallback reason")

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
            sessionToken: "test-token"
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
            sessionToken: "unused-token"
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
            sessionToken: "test-token"
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
        let bleManager = BLEManager()
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
            write: { sentPackets.append($0) }
        ))
        let staleStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","sessionToken":"stale-token"}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(staleStatus.utf8)
        )
        let staleRevision = bleManager.deviceTransferStatusRevision

        let task = Task {
            try await DeviceTransferManager().enterRemoteDebug(
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
        let freshStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","sessionToken":"fresh-token"}
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
            assertEqual(session.sessionToken, "fresh-token",
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
               "failed local routes return in time for retry")
        assertEqual(
            configuration.timeoutIntervalForRequest,
            DeviceTransferServerProbePolicy.requestTimeout,
            "local device probe request timeout is bounded"
        )
        assertEqual(
            configuration.timeoutIntervalForResource,
            DeviceTransferServerProbePolicy.requestTimeout,
            "local device probe resource timeout is bounded"
        )
    }

    static func testDeviceTransferManagerKeepsConfirmedLANDebugSession() async {
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        _ = bleManager.handleDeviceCapabilitiesNotification(cap2)

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        let credentials = RemoteDebugLANCredentials(
            ssid: "Home Wi-Fi",
            password: "session-secret"
        )!
        var statuses: [String] = []
        let task = Task {
            try await DeviceTransferManager().enterRemoteDebug(
                bleManager: bleManager,
                lanCredentials: credentials,
                status: { statuses.append($0) }
            )
        }
        for _ in 0..<100 where sentPackets.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let lanStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"http://192.168.31.195:8080","networkTransport":"lan","networkSsid":"Home Wi-Fi","sessionToken":"lan-token"}
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
                        "http://192.168.31.195:8080",
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
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))
        let activeStatus = """
        {"configured":true,"enabled":true,"mode":"debug","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","sessionToken":"active-token"}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) +
                Data(activeStatus.utf8)
        )

        let task = Task {
            try await DeviceTransferManager().exitRemoteDebug(
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
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true
        let cap2 = Data(DeviceBLEProtocol.deviceCapabilitiesV2Prefix.utf8) +
            Data([1, 0, 0, 1, 0])
        _ = bleManager.handleDeviceCapabilitiesNotification(cap2)
        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let task = Task {
            try await DeviceTransferManager().enterRemoteDebug(
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

    static func testDeviceTransferManagerUsesFreshDeviceSessionWithoutMapStatus() async {
        let bleManager = BLEManager()
        bleManager.isConnected = true
        bleManager.isNavigationReady = true

        var sentPackets: [Data] = []
        bleManager.installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: 64,
            canSend: { true },
            write: { sentPackets.append($0) }
        ))

        let transferTask = Task {
            try await DeviceTransferManager().enterMapTransfer(
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
        let deviceStatus = """
        {"configured":true,"enabled":true,"port":8080,"mode":"map","baseUrl":"http://192.168.4.20:8080","apSsid":"BikeComputer-Transfer","sessionToken":"fresh-map-token","firmware":{"status":"idle","target":"","version":"","build":0,"updaterProtocol":1,"receivedBytes":0,"totalBytes":0}}
        """
        _ = bleManager.handleDeviceTransferStatusNotification(
            Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8) + Data(deviceStatus.utf8)
        )

        do {
            let session = try await transferTask.value
            assertEqual(session.mode, .map,
                        "fresh device status opens a map session")
            assertEqual(session.baseURL.absoluteString, "http://192.168.4.20:8080",
                        "device status owns the transfer server origin")
            assertEqual(session.sessionToken, "fresh-map-token",
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
        {"configured":true,"enabled":true,"port":8080,"baseUrl":"http://192.168.4.20:8080","sdPresent":true,"mapFound":false,"mapBlocks":0,"activeMapId":"kyoto-v1","activeSessionId":"kyoto-v1-session","activeManifestReceipt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","activeMapDisplayName":"Kyoto Hills","activeMapBoundsE7":[1356000000,349000000,1360000000,352000000],"activeRendererFormat":2,"labelProfileVersion":1,"labelLanguages":["ja","en"],"fontAssetHealthy":true,"activation":{"status":"activating","sequence":12,"sessionId":"tokyo-v2","mapId":"tokyo-v2","step":1,"steps":5,"progress":6},"lastError":{"code":"previous","message":"previous upload failed"}}
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
        {"configured":true,"enabled":true,"port":8080,"mode":"debug","baseUrl":"http://192.168.4.1:8080","apSsid":"BikeComputer-Transfer","apPassphrase":"session-wpa-key","networkTransport":"hotspot","networkSsid":"BikeComputer-Transfer","hotspotFallback":true,"hotspotFallbackReason":"endpoint_unreachable","sessionToken":"abc123","lastError":{"code":"transfer_busy","message":"another transfer mode is active"},"firmware":{"status":"receiving","target":"WAVESHARE_AMOLED_206","version":"0.2.2","build":86,"updaterProtocol":1,"receivedBytes":1024,"totalBytes":2048,"lastError":{"code":"previous","message":"previous update failed"}}}
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
        assertEqual(manager.deviceTransferLastErrorCode, "transfer_busy", "status parser exposes transfer error code")
        assertEqual(manager.deviceTransferLastErrorMessage, "another transfer mode is active", "status parser exposes transfer error message")
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
