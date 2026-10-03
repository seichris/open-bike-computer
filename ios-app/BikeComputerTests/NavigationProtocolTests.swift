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
    private struct InterruptedResponse {
        let path: String
        let prefix: Data
        let expectedBytes: Int
    }
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var interruptedResponse: InterruptedResponse?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func configure(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        interruptedResponse = nil
        recordedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func interruptResponse(path: String, prefix: Data, expectedBytes: Int) {
        lock.lock()
        interruptedResponse = InterruptedResponse(
            path: path, prefix: prefix, expectedBytes: expectedBytes
        )
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        interruptedResponse = nil
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
        let interruption = Self.interruptedResponse
        Self.lock.unlock()
        if let interruption, request.url?.path == interruption.path {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/x-ndjson",
                    "Content-Length": String(interruption.expectedBytes),
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: interruption.prefix)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
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
final class TestOfflineMapAppAttestService: OfflineMapAppAttestServicing {
    let keyID: String
    let keyIDs: [String]
    let attestationObject: Data
    let assertionObject: Data
    var nextAttestationError: Error?
    var nextAssertionError: Error?
    private(set) var generatedKeyCount = 0
    private(set) var attestationHashes: [Data] = []
    private(set) var assertionHashes: [Data] = []

    init(
        keyID: String,
        attestationObject: Data = Data("test-attestation".utf8),
        assertionObject: Data = Data("test-assertion".utf8)
    ) {
        self.keyID = keyID
        self.keyIDs = [keyID]
        self.attestationObject = attestationObject
        self.assertionObject = assertionObject
    }

    init(
        keyIDs: [String],
        attestationObject: Data = Data("test-attestation".utf8),
        assertionObject: Data = Data("test-assertion".utf8)
    ) {
        precondition(!keyIDs.isEmpty)
        keyID = keyIDs[0]
        self.keyIDs = keyIDs
        self.attestationObject = attestationObject
        self.assertionObject = assertionObject
    }

    var isSupported: Bool { true }

    func generateKey() async throws -> String {
        generatedKeyCount += 1
        return keyIDs[min(generatedKeyCount - 1, keyIDs.count - 1)]
    }

    func attestKey(_: String, clientDataHash: Data) async throws -> Data {
        attestationHashes.append(clientDataHash)
        if let error = nextAttestationError {
            nextAttestationError = nil
            throw error
        }
        return attestationObject
    }

    func generateAssertion(
        _: String,
        clientDataHash: Data
    ) async throws -> Data {
        assertionHashes.append(clientDataHash)
        if let error = nextAssertionError {
            nextAssertionError = nil
            throw error
        }
        return assertionObject
    }
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
    var acceptsRouteGeometry = true
    var routeGeometryAttempts = 0
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

        routeGeometryAttempts += 1
        guard acceptsRouteGeometry else { return false }
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
    private let storedExpectedTravelTime: TimeInterval

    init(
        instructions: String,
        coordinates: [CLLocationCoordinate2D],
        expectedTravelTime: TimeInterval = 0
    ) {
        self.storedSteps = [TestRouteStep(instructions: instructions, coordinates: coordinates)]
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        self.storedExpectedTravelTime = expectedTravelTime
        super.init()
    }

    init(
        steps: [TestRouteStep],
        coordinates: [CLLocationCoordinate2D],
        expectedTravelTime: TimeInterval = 0
    ) {
        self.storedSteps = steps
        self.storedPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.storedDistance = steps.reduce(0) { $0 + $1.distance }
        self.storedExpectedTravelTime = expectedTravelTime
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

    override var expectedTravelTime: TimeInterval {
        storedExpectedTravelTime
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
@MainActor
struct NavigationProtocolTests {
    static func freshNavigationFix(_ location: CLLocation, at date: Date = Date()) -> CLLocation {
        CLLocation(coordinate: location.coordinate, altitude: location.altitude,
                   horizontalAccuracy: location.horizontalAccuracy,
                   verticalAccuracy: location.verticalAccuracy, course: location.course,
                   speed: location.speed, timestamp: date)
    }

    static func main() async {
        testIconMapping()
        testRouteEndpointExtraction()
        testRouteRemainingDistance()
        testRouteDeviationDetection()
        testReplacementStepSelectionUsesUnambiguousGeometry()
        testCoordinatorPreviewsAndSelectsAlternateRoutes()
        testCoordinatorRequiresSelectionForSingleRoute()
        testCoordinatorReroutesAndAppliesLatestRoute()
        testCoordinatorReroutesWhenProgressRejectsFarLocation()
        testWorkoutAndNavigationLifecyclesStayIndependent()
        testRideActivityRuntimeIntegration()
        testPhoneWorkoutLocationContinuation()
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
        testBicinoAppLinkPolicy()
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
        testSecureRendererBenchmarkProtocol()
        testRendererCrossRunRetainedMemoryPolicy()
        testDeviceNetworkJoinTimeoutPolicy()
        testSecureRendererBenchmarkReadiness()
        testRendererBenchmarkAtomicDelivery()
        testATTWriteSubmissionEvidence()
        testRouteSnapshotManagerAdmission()
        testNavigationDrainIncludesAcknowledgement()
        testDeviceBLEProtocolConstants()
        testWorkoutDeviceFrameVectors()
        testWorkoutDeviceFrameSentinelsAndSaturation()
        testWorkoutDeviceTelemetryMapping()
        testWorkoutDeviceRelayScheduling()
        testWorkoutDeviceRelayPublicationIntegration()
        testWorkoutDeviceRelayMotionDeduplicationIntegration()
        testWorkoutDeviceRelayRegularRetryIntegration()
        testWorkoutTelemetryBLETransport()
        testQueuedMotionUsesDispatchAge()
        testDevicePacketRouting()
        testDeviceTransferHandshakePolicy()
        testDeviceSoundProtocol()
        testDeviceCapabilitiesProtocol()
        testWatchTransportDiagnosticFieldPolicy()
        testBatteryStatusScreenCapabilityNegotiation()
        testMapProfileCapabilityNegotiation()
        testDeviceCapabilitySynchronizesPowerButtonHonkOnce()
        testDeviceCapabilityRetryPolicy()
        testDeviceScreenValidation()
        testDeviceScreenConfigurationCodecAndValidation()
        testDeviceScreenConfigurationController()
        testScreenCleanReconnect()
        testScreenEditsDuringReload()
        testScreenEditsDuringSave()
        testScreenAutosaveCoalescesAndCoversMapProfiles()
        testScreenPendingConflictResolution()
        testHardwareLabelPreference()
        testBLEPairingAuthenticator()
        testBLEScanLifecyclePolicy()
        testBLEManagerDiscoveryLifecycleTransitions()
        testDeviceOwnershipProtocol()
        testBLEManagerRequiresNavigationReadinessForWrites()
        testRideApplicationAcknowledgementWaitsForATTCallback()
        testBLEManagerSendsFallbackMapSettings()
        testBLEManagerSendsSeparateMapProfileSettings()
        testBLEManagerGatesTopographicContourVisibility()
        testBLEManagerFoldsExtendedVisibilityForLegacyFirmware()
        testBLEManagerSendsDeviceSoundFallback()
        testBLEManagerSendsPowerButtonHonkFallback()
        testPowerButtonHonkTimeoutAndTransportFailures()
        testBLEManagerSendsDeviceCapabilityFallback()
        testBLEManagerSendsMapTransferControlFrames()
        testBLEManagerSendsDeviceTransferControlFrames()
        testBLEManagerSuppressesOptionalWritesDuringFirmwareMaintenance()
        testBLEManagerSuppressesOrdinaryWritesWhileMaintenanceReconnectIsExpected()
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
        testBLEManagerSendsDisplayInactivityTimeouts()
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
        testNavigationEngineRetriesRejectedRouteGeometryOnSameSegment()
        testNavigationEngineClearsRouteGeometryOnStop()
        testNavigationEngineClearsRouteGeometryWhenReadyAndIdle()
        testGPSStartupRetriesUseLatestGeneration()
        testNavigationEngineRefreshesElapsedWithoutLocationChange()
        testNavigationEngineClearsRideTelemetryOnStop()
        testNavigationEngineRestoresPhysicalGPSAfterSimulation()
        testNavigationEngineKeepsPhysicalGPSAfterSimulationStepCompletion()
        testNavigationEngineOmitsRideTelemetryWhenIdle()
        testNavigationEngineIgnoresFarLocationForRouteProgress()
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
        await testDeviceTransferReadinessWindow()
        await testDeviceTransferManagerWaitsForMapToken()
        await testDeviceTransferManagerWaitsForFreshDebugToken()
        await testDeviceTransferManagerKeepsConfirmedLANDebugSession()
        await testDeviceTransferManagerCompensatesCancelledDebugEntry()
        await testDeviceTransferManagerConfirmsDebugExit()
        await testDeviceTransferManagerUsesFreshDeviceSessionWithoutMapStatus()
        await testFirmwareTransferSurvivesNetworkStartupReconnect()
        await testFirmwareTransferSurfacesFreshRejectionAndExits()
        await testFirmwareTransferCancellationExits()
        await testFirmwareMaintenancePreparationFlow()
        await testDeviceDiagnosticsTransferPolicy()
        await testDeviceDiagnosticsInterruptedChunk()
        await testDeviceDiagnosticsFailsFastOnFirmwareRejection()
        await testDeviceDiagnosticsRecordsEntryFailure()
        await testDeviceDiagnosticsDownloadEndToEnd()
        await testOfflineMapInstallationCredentialClient()
        testOfflineMapAppAttestGoldenVector()
        await testManagedOfflineMapAppAttestContract()
        await testManagedAppAttestKeyRotation()
        await testManagedAppAttestMissingServerBindingRecovery()
        await testManagedInitialAppAttestConsumedChallengeRetry()
        await testManagedAppAttestCrashBeforeCredentialPersistence()
        await testManagedInstallationMigration()
        testOfflineMapPreparationTimeEstimate()
        testOfflineMapJobProgressDecoding()
        testOfflineMapQueuePositionPresentation()
        testOfflineMapJobPhaseOnlyProgressDecoding()
        testOfflineMapJobProgressAbsentFallback()
        testOfflineMapProgressPresentation()
        testOfflineMapByteProgressPresentation()
        testOfflineMapOnboardingPolicy()
        testBicinoDeviceIntroductionPolicies()
        testProvisionalActiveMapVisibility()
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
        await testDurableMapDownloads()
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
        testSavedMapReplacementCrashRecovery()
        testOfflineMapManagerRepairsGeneratedPackDefaults()
        testOfflineMapManagerRenamesCachedPack()
        testSavedMapRenameViewWiring()
        testSettingsSheetPresentationWiring()
        testStravaRouteCatalogUIWiring()
        testLandingMapConnectionStatusPositioning()
        testDeviceScreenUISettingsWiring()
        testSavedRouteNamingAndViewWiring()
        testTopographicMapChoicesAreIndependent()
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
        testFirmwareStorageMigrationFlow()
        testFirmwareUpdateAvailabilitySemantics()
        testFirmwareDeviceClientSendsSignedBeginRequest()
        testFirmwareDownloadBounds()
        testFirmwareSourceIdentityMigration()
        testFirmwareOperationReceiptReconciliation()
        await testFirmwarePendingIdentityReconciliation()
        await testOfflineMapRecoveryRoutes()
        print("NavigationProtocolTests passed")
    }

    static func testWatchTransportDiagnosticFieldPolicy() {
        let watchTransportFields: Set<String> = [
            "attemptId", "connectionGeneration", "controllerRole",
            "highWater", "highWaterBytes", "latencyMs", "origin", "outcome", "phase",
            "queueBytes", "queueDepth", "reason", "rejectedCount", "replacedCount",
            "watchSequence", "watchUptimeMs",
        ]
        assert(
            watchTransportFields.isSubset(
                of: RideDiagnosticsFieldPolicy.allowedKeys
            ),
            "every Watch transport diagnostic field is admitted by the privacy policy"
        )
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
        let catalogReaderRequirements = OfflineMapReaderRequirements(
            schemaVersion: 1,
            streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
            manifestSchemaVersion: 1,
            renderer: "esp32-fmb",
            rendererFormatVersion: 1,
            requiredFeatures: []
        )
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
            assertEqual(
                verified.readerRequirements,
                nil,
                "an app-bound stream keeps exact identity without an explicit migration policy"
            )
        } catch {
            assert(false, "valid complete map stream is accepted: \(error)")
        }
        do {
            let verified = try BikeMapStreamArtifactValidator.validate(
                url: streamURL,
                artifact: artifact(bytes: stream),
                expectedMapID: "golden-map",
                trustStore: trustStore,
                deriveReaderRequirementsFromSignedManifest: true
            )
            assertEqual(
                verified.readerRequirements,
                catalogReaderRequirements,
                "an opted-in app-bound stream derives compatibility from its signed manifest"
            )
        } catch {
            assert(false, "a valid stream supports an explicit compatibility migration: \(error)")
        }

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
        assert(
            SavedMapReaderRequirementsMigrationPolicy
                .shouldDeriveFromSignedManifest(
                    generationServerURLString:
                        OfflineMapServiceConfig.developmentServerURLString,
                    isDevelopmentBuild: true
                ),
            "development builds migrate streams generated by the development service"
        )
        assert(
            !SavedMapReaderRequirementsMigrationPolicy
                .shouldDeriveFromSignedManifest(
                    generationServerURLString:
                        OfflineMapServiceConfig.productionServerURLString,
                    isDevelopmentBuild: true
                ),
            "development builds retain production rollout app bindings"
        )
        assert(
            !SavedMapReaderRequirementsMigrationPolicy
                .shouldDeriveFromSignedManifest(
                    generationServerURLString:
                        OfflineMapServiceConfig.developmentServerURLString,
                    isDevelopmentBuild: false
                ),
            "release builds retain exact app rollout bindings"
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
                requiredIosBuild: stream.requiredIosBuild,
                requiredIosGitSha: stream.requiredIosGitSha,
                requiredIosBuildSha256: stream.requiredIosBuildSha256,
                currentIosBuild: "101",
                currentIosGitSha: String(repeating: "8", count: 40),
                currentIosBuildSha256: String(repeating: "9", count: 64),
                readerRequirements: catalogReaderRequirements,
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: v2Status
            ),
            .streamV2,
            "a signed reader contract supersedes stale app audit identity"
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
        assertEqual(
            MapInstallProtocolSelector.evaluate(
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
            ).rejection,
            .readerRequirementsUnsupported,
            "selector diagnostics classify unsupported reader requirements"
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
            MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                readerRequirements: catalogReaderRequirements,
                requiredFirmwareVersion: stream.requiredFirmwareVersion,
                requiredFirmwareBuild: stream.requiredFirmwareBuild,
                requiredFirmwareGitSha: stream.requiredFirmwareGitSha,
                deviceStatus: wrongFirmwareStatus
            ).rejection,
            .firmwareIdentityMismatch,
            "selector diagnostics classify an exact firmware mismatch"
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
            MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
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
            ).rejection,
            .appIdentityMismatch,
            "selector diagnostics classify an exact app mismatch"
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
        assertEqual(
            MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                deviceStatus: v1Status
            ).rejection,
            .deviceProtocolUnsupported,
            "selector diagnostics classify a device protocol mismatch"
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
            MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability:
                    "map-prod-1=" + String(repeating: "5", count: 64),
                deviceStatus: wrongKeyStatus
            ).rejection,
            .signingKeyNotTrusted,
            "selector diagnostics classify an exact signing-key mismatch"
        )
        assertEqual(
            MapInstallProtocolSelector.select(isBikeMapStream: false, deviceStatus: v2Status),
            .legacyArtifactRequired,
            "unsigned ZIP archives are never selected for device installation"
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
            .awaitDevice,
            "an exact pointer without a terminal result waits without retransmitting"
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
        let legacyJSON = Data("""
        {"mapID":"map-id","sessionID":"legacy","protocolVersion":2,"artifactFilename":"map.bmap"}
        """.utf8)
        let legacyDescriptor = try! JSONDecoder().decode(BackgroundMapUploadDescriptor.self, from: legacyJSON)
        assert(!legacyDescriptor.hasDurableIdentity, "legacy tasks decode but cannot acquire a new device identity")
        let durableDescriptor = BackgroundMapUploadDescriptor(
            mapID: "map-id", sessionID: descriptor.sessionID, protocolVersion: 2, streamFormatVersion: 1,
            artifactFilename: "map-id.bmap", deviceID: String(repeating: "a", count: 32), operationID: UUID(),
            uploadAttemptID: UUID(), appNamespace: "test.dev", connectionEpoch: 7,
            operationAdmissionRevision: 42, operationAdmissionEpoch: String(repeating: "b", count: 32)
        )
        assert(durableDescriptor.hasDurableIdentity, "new descriptor has exact device and attempt identity")
        assertEqual(try! JSONDecoder().decode(BackgroundMapUploadDescriptor.self, from: JSONEncoder().encode(durableDescriptor)),
                    durableDescriptor, "durable descriptor and original admission survive OS task restoration")
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
                lastDeviceState: "idle",
                backgroundUploadSucceeded: true,
                observedIdleOnAnotherMap: true,
                statusMessage: "Activation paused. Tap Upload to resume."
            ),
            "a fresh idle status on another map permits retry after a completed upload"
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

    @MainActor
    static func testManagedInstallationMigration() async {
        let suite = "Migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel(); OfflineMapTestURLProtocol.reset() }
        let origin = OfflineMapServiceConfig.productionServerURLString
        let keyID = Data(repeating: 0x63, count: 32).base64EncodedString()
        let old = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_1234567890abcdef1234567890abcdef",
            clientInstallationToken: "v1." + String(repeating: "A", count: 43)
        )
        let migrated = OfflineMapInstallationCredential(
            clientInstallationId: old.clientInstallationId,
            clientInstallationToken: old.clientInstallationToken,
            appAttestKeyId: keyID
        )
        let store = OfflineMapInstallationCredentialStore(defaults: defaults)
        let service = BicinoServiceSession(defaults: defaults, urlSession: urlSession,
            appAttestService: TestOfflineMapAppAttestService(keyID: keyID), appAttestAppBuild: "123")
        var committed = false
        var enrollments = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/installations/app-attest/challenges" {
                let challenge = OfflineMapAppAttestChallenge(
                    challengeId: String(repeating: "a", count: 32),
                    challenge: Data(repeating: 1, count: 32).base64EncodedString()
                        .replacingOccurrences(of: "=", with: ""),
                    purpose: "attestation", expiresAt: Int64(Date().timeIntervalSince1970) + 300, keyId: nil)
                return (200, try! JSONEncoder().encode(challenge))
            }
            assertEqual(request.value(forHTTPHeaderField: "X-Installation-Token"), old.clientInstallationToken,
                "migration and refresh prove possession of the old token")
            if OfflineMapTestURLProtocol.bodyData(from: request).isEmpty {
                assertEqual(request.value(forHTTPHeaderField: "X-Bicino-App-Attest"), "required",
                    "managed refresh explicitly selects the attested migration contract")
            }
            assert(request.url!.query!.contains(old.clientInstallationId), "migration keeps the old identity")
            if !OfflineMapTestURLProtocol.bodyData(from: request).isEmpty {
                enrollments += 1
                committed = true
                return (503, Data("lost enrollment response".utf8))
            }
            if committed { return (200, try! JSONEncoder().encode(migrated)) }
            return (401, Data(#"{"detail":{"code":"installation_attestation_required"}}"#.utf8))
        }
        do {
            try store.save(old, serverURLString: origin)
            let client = try service.makeOfflineMapClient(serverURLString: origin)
            do {
                _ = try await service.ensureRegisteredInstallation(client: client)
                assert(false, "lost response must fail without deleting credentials")
            } catch {}
            assertEqual(store.load(serverURLString: origin), old, "failed migration preserves old credentials")
            let recovered = try await service.ensureRegisteredInstallation(client: client)
            assertEqual(recovered.clientInstallationId, old.clientInstallationId, "refresh recovers the same owner")
            assertEqual(store.load(serverURLString: origin), migrated, "refresh commits the recovered key")
            assertEqual(enrollments, 1, "lost response does not trigger another enrollment")
            for status in [401, 503] {
                try store.save(old, serverURLString: origin)
                OfflineMapTestURLProtocol.configure { _ in
                    (status, Data(#"{"detail":"invalid installation credential"}"#.utf8))
                }
                do {
                    _ = try await service.ensureRegisteredInstallation(client: client, honorRefreshBackoff: false)
                    assert(false, "unrelated authentication/server errors must fail closed")
                } catch {}
                assertEqual(store.load(serverURLString: origin), old, "server errors never erase the owner credential")
            }
            let foreign = OfflineMapInstallationCredential(
                clientInstallationId: "inst_v2_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                clientInstallationToken: old.clientInstallationToken, appAttestKeyId: keyID)
            OfflineMapTestURLProtocol.configure { _ in (200, try! JSONEncoder().encode(foreign)) }
            do {
                _ = try await service.ensureRegisteredInstallation(client: client, honorRefreshBackoff: false)
                assert(false, "refresh must reject a different installation identity")
            } catch {}
            assertEqual(store.load(serverURLString: origin), old, "foreign refresh cannot replace the owner credential")
        } catch { assert(false, "migration recovery succeeds: \(error)") }
    }

    @MainActor
    static func testManagedAppAttestKeyRotation() async {
        let suite = "AppAttestRotation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OfflineMapTestURLProtocol.reset() }
        let baseURL = URL(string: OfflineMapServiceConfig.productionServerURLString)!
        let oldKeyID = Data(repeating: 0x31, count: 32).base64EncodedString()
        let newKeyID = Data(repeating: 0x32, count: 32).base64EncodedString()
        let credential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_abcdefabcdefabcdefabcdefabcdefab",
            clientInstallationToken: "v1." + String(repeating: "R", count: 43),
            appAttestKeyId: oldKeyID
        )
        let rotated = OfflineMapInstallationCredential(
            clientInstallationId: credential.clientInstallationId,
            clientInstallationToken: credential.clientInstallationToken,
            appAttestKeyId: newKeyID
        )
        let service = TestOfflineMapAppAttestService(keyIDs: [newKeyID])
        let keyStore = OfflineMapAppAttestKeyStore(defaults: defaults)
        let credentialStore = OfflineMapInstallationCredentialStore(defaults: defaults)
        let managed = ManagedOfflineMapAppAttestClient(
            defaults: defaults, session: session, service: service, appBuild: "123"
        )
        let assertionChallenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "d", count: 32),
            challenge: Data(repeating: 4, count: 32).base64EncodedString()
                .replacingOccurrences(of: "=", with: ""),
            purpose: "map-create",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: oldKeyID
        )
        let rotationChallenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "e", count: 32),
            challenge: Data(repeating: 5, count: 32).base64EncodedString()
                .replacingOccurrences(of: "=", with: ""),
            purpose: "attestation",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: oldKeyID
        )
        let jobRequest = OfflineMapJobRequest.customBBox(
            OfflineMapBounds(
                minLon: 103.75, minLat: 1.24,
                maxLon: 103.93, maxLat: 1.37
            )
        ).identified(
            clientInstallationId: credential.clientInstallationId,
            clientRequestId: "request-key-rotation",
            installOnDevice: true
        )
        do {
            try keyStore.saveActive(oldKeyID, serverURLString: baseURL.absoluteString)
            try credentialStore.save(credential, serverURLString: baseURL.absoluteString)
            OfflineMapTestURLProtocol.configure { request in
                assertEqual(request.url?.path,
                    "/v1/installations/app-attest/challenges",
                    "assertion failures only request a map-create challenge")
                return (200, try! JSONEncoder().encode(assertionChallenge))
            }
            let unsigned = try OfflineMapPlatformClient.makeCreateJobURLRequest(
                baseURL: baseURL, jobRequest: jobRequest
            )
            service.nextAssertionError = URLError(.timedOut)
            do {
                _ = try await managed.authorizeMapCreate(
                    request: unsigned, jobRequest: jobRequest,
                    credential: credential, baseURL: baseURL
                )
                assert(false, "transient assertion failure is surfaced")
            } catch {}
            assertEqual(try managed.reconcile(
                serverKeyID: oldKeyID,
                serverURLString: baseURL.absoluteString
            ), .usable, "transient assertion failure keeps the active key")

            service.nextAssertionError = ManagedAppAttestError.keyUnavailable
            do {
                _ = try await managed.authorizeMapCreate(
                    request: unsigned, jobRequest: jobRequest,
                    credential: credential, baseURL: baseURL
                )
                assert(false, "invalid local key is surfaced")
            } catch let error as ManagedAppAttestError {
                assertEqual(error, .keyUnavailable, "invalid local key is classified")
            }
            assertEqual(try managed.reconcile(
                serverKeyID: oldKeyID,
                serverURLString: baseURL.absoluteString
            ), .rotationRequired, "only confirmed local key loss enables rotation")

            var rotationChallengeRequests = 0
            OfflineMapTestURLProtocol.configure { request in
                if request.url?.path == "/v1/installations/app-attest/challenges" {
                    rotationChallengeRequests += 1
                    let body = try! JSONSerialization.jsonObject(
                        with: OfflineMapTestURLProtocol.bodyData(from: request)
                    ) as! [String: Any]
                    assertEqual(body["purpose"] as? String, "attestation",
                        "recovery requests a fresh attestation challenge")
                    assertEqual(body["clientInstallationId"] as? String,
                        credential.clientInstallationId,
                        "rotation challenge is scoped to the stable owner")
                    assertEqual(request.value(forHTTPHeaderField: "X-Installation-Token"),
                        credential.clientInstallationToken,
                        "rotation challenge proves the existing owner token")
                    return (200, try! JSONEncoder().encode(rotationChallenge))
                }
                let body = OfflineMapTestURLProtocol.bodyData(from: request)
                if body.isEmpty { return (200, try! JSONEncoder().encode(credential)) }
                let document = try! JSONSerialization.jsonObject(with: body)
                    as! [String: Any]
                let attestation = document["appAttest"] as! [String: Any]
                assertEqual(attestation["previousKeyId"] as? String, oldKeyID,
                    "rotation compare-and-swaps the server's current key")
                assertEqual(attestation["keyId"] as? String, newKeyID,
                    "rotation submits the freshly generated key")
                return (200, try! JSONEncoder().encode(rotated))
            }
            let serviceSession = BicinoServiceSession(
                defaults: defaults, urlSession: session,
                appAttestService: service, appAttestAppBuild: "123"
            )
            let client = try serviceSession.makeOfflineMapClient(
                serverURLString: baseURL.absoluteString
            )
            service.nextAttestationError = URLError(.cannotConnectToHost)
            do {
                _ = try await serviceSession.ensureRegisteredInstallation(
                    client: client, honorRefreshBackoff: false
                )
                assert(false, "transient Apple attestation failure is surfaced")
            } catch {}
            let recovered = try await serviceSession.ensureRegisteredInstallation(
                client: client, honorRefreshBackoff: false
            )
            assertEqual(recovered.clientInstallationId, credential.clientInstallationId,
                "key rotation preserves the installation owner")
            assertEqual(recovered.clientAppAttestKeyId, newKeyID,
                "key rotation adopts the replacement key")
            assertEqual(service.generatedKeyCount, 1,
                "Apple retry reuses the same pending replacement key")
            assertEqual(rotationChallengeRequests, 1,
                "Apple retry reuses the same challenge and client-data hash")
            assertEqual(credentialStore.load(serverURLString: baseURL.absoluteString), rotated,
                "the stable owner credential records the replacement key")
        } catch {
            assert(false, "managed App Attest key rotation succeeds: \(error)")
        }
    }

    @MainActor
    static func testManagedAppAttestMissingServerBindingRecovery() async {
        let suite = "AppAttestMissingBinding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OfflineMapTestURLProtocol.reset() }
        let origin = OfflineMapServiceConfig.productionServerURLString
        let oldKeyID = Data(repeating: 0x51, count: 32).base64EncodedString()
        let newKeyID = Data(repeating: 0x52, count: 32).base64EncodedString()
        let old = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_11223344556677889900aabbccddeeff",
            clientInstallationToken: "v1." + String(repeating: "M", count: 43),
            appAttestKeyId: oldKeyID
        )
        let rebound = OfflineMapInstallationCredential(
            clientInstallationId: old.clientInstallationId,
            clientInstallationToken: old.clientInstallationToken,
            appAttestKeyId: newKeyID
        )
        let challenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "b", count: 32),
            challenge: Data(repeating: 7, count: 32).base64EncodedString()
                .replacingOccurrences(of: "=", with: ""),
            purpose: "attestation",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: nil
        )
        let keyStore = OfflineMapAppAttestKeyStore(defaults: defaults)
        let credentialStore = OfflineMapInstallationCredentialStore(defaults: defaults)
        var refreshRequests = 0
        var challengeRequests = 0
        var enrollmentRequests = 0
        do {
            try keyStore.saveActive(oldKeyID, serverURLString: origin)
            try credentialStore.save(old, serverURLString: origin)
            OfflineMapTestURLProtocol.configure { request in
                if request.url?.path == "/v1/installations/app-attest/challenges" {
                    challengeRequests += 1
                    assertEqual(
                        request.value(forHTTPHeaderField: "X-Installation-Token"),
                        old.clientInstallationToken,
                        "missing-binding recovery authenticates the scoped challenge"
                    )
                    let body = try! JSONSerialization.jsonObject(
                        with: OfflineMapTestURLProtocol.bodyData(from: request)
                    ) as! [String: Any]
                    assertEqual(
                        body["clientInstallationId"] as? String,
                        old.clientInstallationId,
                        "missing-binding recovery scopes the challenge to the owner"
                    )
                    return (200, try! JSONEncoder().encode(challenge))
                }
                let body = OfflineMapTestURLProtocol.bodyData(from: request)
                if body.isEmpty {
                    refreshRequests += 1
                    return (
                        401,
                        Data(#"{"detail":{"code":"installation_attestation_required"}}"#.utf8)
                    )
                }
                enrollmentRequests += 1
                let document = try! JSONSerialization.jsonObject(with: body)
                    as! [String: Any]
                let attestation = document["appAttest"] as! [String: Any]
                assert(
                    attestation["previousKeyId"] == nil,
                    "a missing server binding is not represented as key replacement"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Installation-Token"),
                    old.clientInstallationToken,
                    "re-enrollment preserves and proves the stable owner token"
                )
                return (200, try! JSONEncoder().encode(rebound))
            }
            let serviceSession = BicinoServiceSession(
                defaults: defaults,
                urlSession: session,
                appAttestService: TestOfflineMapAppAttestService(keyID: newKeyID),
                appAttestAppBuild: "123"
            )
            let client = try serviceSession.makeOfflineMapClient(
                serverURLString: origin
            )
            let recovered = try await serviceSession.ensureRegisteredInstallation(
                client: client,
                honorRefreshBackoff: false
            )
            assertEqual(recovered.clientInstallationId, old.clientInstallationId,
                "server-binding recovery keeps existing map ownership")
            assertEqual(recovered.clientAppAttestKeyId, newKeyID,
                "server-binding recovery adopts the freshly attested key")
            assertEqual(refreshRequests, 1,
                "server-binding recovery begins with one authenticated refresh")
            assertEqual(challengeRequests, 1,
                "server-binding recovery uses one scoped challenge")
            assertEqual(enrollmentRequests, 1,
                "server-binding recovery performs one re-enrollment")
            assertEqual(credentialStore.load(serverURLString: origin), rebound,
                "server-binding recovery durably keeps the owner credential")
            assertEqual(keyStore.load(serverURLString: origin), newKeyID,
                "server-binding recovery promotes the replacement local key")
        } catch {
            assert(false, "missing App Attest server binding recovers: \(error)")
        }
    }

    @MainActor
    static func testManagedInitialAppAttestConsumedChallengeRetry() async {
        let suite = "AppAttestInitialRetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OfflineMapTestURLProtocol.reset() }
        let baseURL = URL(string: OfflineMapServiceConfig.productionServerURLString)!
        let firstKeyID = Data(repeating: 0x61, count: 32).base64EncodedString()
        let secondKeyID = Data(repeating: 0x62, count: 32).base64EncodedString()
        let credential = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_ffeeddccbbaa00998877665544332211",
            clientInstallationToken: "v1." + String(repeating: "N", count: 43),
            appAttestKeyId: secondKeyID
        )
        let challenges = [
            OfflineMapAppAttestChallenge(
                challengeId: String(repeating: "c", count: 32),
                challenge: Data(repeating: 8, count: 32).base64EncodedString()
                    .replacingOccurrences(of: "=", with: ""),
                purpose: "attestation",
                expiresAt: Int64(Date().timeIntervalSince1970) + 300,
                keyId: nil
            ),
            OfflineMapAppAttestChallenge(
                challengeId: String(repeating: "d", count: 32),
                challenge: Data(repeating: 9, count: 32).base64EncodedString()
                    .replacingOccurrences(of: "=", with: ""),
                purpose: "attestation",
                expiresAt: Int64(Date().timeIntervalSince1970) + 300,
                keyId: nil
            ),
        ]
        let appAttestService = TestOfflineMapAppAttestService(
            keyIDs: [firstKeyID, secondKeyID]
        )
        let managed = ManagedOfflineMapAppAttestClient(
            defaults: defaults,
            session: session,
            service: appAttestService,
            appBuild: "123"
        )
        var challengeRequests = 0
        var enrollmentRequests = 0
        OfflineMapTestURLProtocol.configure { request in
            if request.url?.path == "/v1/installations/app-attest/challenges" {
                let challenge = challenges[challengeRequests]
                challengeRequests += 1
                return (200, try! JSONEncoder().encode(challenge))
            }
            enrollmentRequests += 1
            if enrollmentRequests == 1 {
                throw URLError(.networkConnectionLost)
            }
            if enrollmentRequests == 2 {
                return (
                    401,
                    Data(#"{"detail":{"code":"app_attest_invalid_challenge","message":"consumed"}}"#.utf8)
                )
            }
            return (200, try! JSONEncoder().encode(credential))
        }
        do {
            do {
                _ = try await managed.enroll(baseURL: baseURL)
                assert(false, "the lost initial enrollment response is surfaced")
            } catch {}
            let recovered = try await managed.enroll(baseURL: baseURL)
            try managed.finalizeEnrollment(
                recovered,
                serverURLString: baseURL.absoluteString
            )
            assertEqual(recovered, credential,
                "a consumed initial challenge is replaced immediately")
            assertEqual(challengeRequests, 2,
                "initial enrollment retries with exactly one fresh challenge")
            assertEqual(enrollmentRequests, 3,
                "the pending replay is followed by exactly one fresh enrollment")
            assertEqual(appAttestService.generatedKeyCount, 2,
                "a consumed unowned attempt receives one fresh App Attest key")
            let keyStore = OfflineMapAppAttestKeyStore(defaults: defaults)
            assertEqual(keyStore.load(serverURLString: baseURL.absoluteString),
                secondKeyID, "the retried initial enrollment promotes its usable key")
            assert(keyStore.pending(serverURLString: baseURL.absoluteString) == nil,
                "the retried initial enrollment clears pending state after promotion")
        } catch {
            assert(false, "consumed initial App Attest challenge recovers: \(error)")
        }
    }

    @MainActor
    static func testManagedAppAttestCrashBeforeCredentialPersistence() async {
        let suite = "AppAttestCrashRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); OfflineMapTestURLProtocol.reset() }
        let origin = OfflineMapServiceConfig.productionServerURLString
        let oldKeyID = Data(repeating: 0x41, count: 32).base64EncodedString()
        let newKeyID = Data(repeating: 0x42, count: 32).base64EncodedString()
        let old = OfflineMapInstallationCredential(
            clientInstallationId: "inst_v2_0123456789abcdef0123456789abcdef",
            clientInstallationToken: "v1." + String(repeating: "C", count: 43),
            appAttestKeyId: oldKeyID
        )
        let rotated = OfflineMapInstallationCredential(
            clientInstallationId: old.clientInstallationId,
            clientInstallationToken: old.clientInstallationToken,
            appAttestKeyId: newKeyID
        )
        let keyStore = OfflineMapAppAttestKeyStore(defaults: defaults)
        let credentialStore = OfflineMapInstallationCredentialStore(defaults: defaults)
        do {
            try keyStore.saveActive(oldKeyID, serverURLString: origin)
            keyStore.markRotationRequired(serverURLString: origin)
            try keyStore.savePending(
                OfflineMapPendingAppAttestEnrollment(
                    keyID: newKeyID,
                    previousKeyID: oldKeyID,
                    clientInstallationID: old.clientInstallationId,
                    challenge: OfflineMapAppAttestChallenge(
                        challengeId: String(repeating: "f", count: 32),
                        challenge: Data(repeating: 6, count: 32)
                            .base64EncodedString()
                            .replacingOccurrences(of: "=", with: ""),
                        purpose: "attestation",
                        expiresAt: Int64(Date().timeIntervalSince1970) + 300,
                        keyId: oldKeyID
                    ),
                    attestationObject: Data("attestation".utf8).base64EncodedString()
                ),
                serverURLString: origin
            )
            try credentialStore.save(old, serverURLString: origin)
            OfflineMapTestURLProtocol.configure { request in
                assertEqual(request.url?.path, "/v1/installations",
                    "crash recovery performs an authenticated refresh")
                assert(OfflineMapTestURLProtocol.bodyData(from: request).isEmpty,
                    "crash recovery does not authorize another rotation")
                assertEqual(request.value(forHTTPHeaderField: "X-Installation-Token"),
                    old.clientInstallationToken,
                    "crash recovery proves the stable owner token")
                return (200, try! JSONEncoder().encode(rotated))
            }
            let serviceSession = BicinoServiceSession(
                defaults: defaults,
                urlSession: session,
                appAttestService: TestOfflineMapAppAttestService(keyID: newKeyID),
                appAttestAppBuild: "123"
            )
            let client = try serviceSession.makeOfflineMapClient(
                serverURLString: origin
            )
            let recovered = try await serviceSession.ensureRegisteredInstallation(
                client: client,
                honorRefreshBackoff: false
            )
            assertEqual(recovered.clientAppAttestKeyId, newKeyID,
                "refresh adopts the backend-committed pending key")
            assertEqual(credentialStore.load(serverURLString: origin), rotated,
                "new credential becomes durable before pending state is cleared")
            assertEqual(keyStore.load(serverURLString: origin), newKeyID,
                "pending key is promoted after credential persistence")
            assert(keyStore.pending(serverURLString: origin) == nil,
                "pending state clears only after crash recovery completes")
            let verifier = ManagedOfflineMapAppAttestClient(
                defaults: defaults,
                session: session,
                service: TestOfflineMapAppAttestService(keyID: newKeyID),
                appBuild: "123"
            )
            assertEqual(try verifier.reconcile(
                serverKeyID: newKeyID,
                serverURLString: origin
            ), .usable, "completed promotion cannot rotate the healthy new key again")
        } catch {
            assert(false, "crash-window key rotation recovery succeeds: \(error)")
        }
    }

    @MainActor
    static func testManagedOfflineMapAppAttestContract() async {
        let suite = "OfflineMapAppAttestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflineMapTestURLProtocol.reset()
        }

        let baseURL = URL(string: "https://maps.example.com")!
        let rawAttestationChallenge = Data((0..<32).map(UInt8.init))
        let rawAssertionChallenge = Data((32..<64).map(UInt8.init))
        let rawAssertionRetryChallenge = Data((64..<96).map(UInt8.init))
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let attestationChallenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "a", count: 32),
            challenge: base64URL(rawAttestationChallenge),
            purpose: "attestation",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: nil
        )
        let keyID = Data(repeating: 0x42, count: 32).base64EncodedString()
        let assertionChallenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "b", count: 32),
            challenge: base64URL(rawAssertionChallenge),
            purpose: "map-create",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: keyID
        )
        let assertionRetryChallenge = OfflineMapAppAttestChallenge(
            challengeId: String(repeating: "c", count: 32),
            challenge: base64URL(rawAssertionRetryChallenge),
            purpose: "map-create",
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            keyId: keyID
        )
        let credential = OfflineMapInstallationCredential(
            clientInstallationId:
                "inst_v2_1234567890abcdef1234567890abcdef",
            clientInstallationToken:
                "v1." + String(repeating: "A", count: 43),
            appAttestKeyId: keyID
        )
        let appAttestService = TestOfflineMapAppAttestService(keyID: keyID)
        let managedClient = ManagedOfflineMapAppAttestClient(
            defaults: defaults,
            session: session,
            service: appAttestService,
            appBuild: "123"
        )
        var challengeCount = 0
        var mapCreateCount = 0
        OfflineMapTestURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/installations/app-attest/challenges"):
                challengeCount += 1
                let body = try! JSONSerialization.jsonObject(
                    with: OfflineMapTestURLProtocol.bodyData(from: request)
                ) as! [String: Any]
                if challengeCount == 1 {
                    assertEqual(
                        body["purpose"] as? String,
                        "attestation",
                        "initial registration requests an attestation challenge"
                    )
                    assert(
                        request.value(forHTTPHeaderField: "X-Installation-Token") == nil,
                        "initial attestation challenge is not authenticated by an unproven identity"
                    )
                    return (
                        200,
                        try! JSONEncoder().encode(attestationChallenge)
                    )
                }
                assertEqual(
                    body["purpose"] as? String,
                    "map-create",
                    "map creation requests a single-use assertion challenge"
                )
                assertEqual(
                    body["clientInstallationId"] as? String,
                    credential.clientInstallationId,
                    "assertion challenge is scoped to the attested installation"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-Installation-Token"),
                    credential.clientInstallationToken,
                    "assertion challenge uses the installation credential"
                )
                let challenge = challengeCount == 2
                    ? assertionChallenge
                    : assertionRetryChallenge
                return (200, try! JSONEncoder().encode(challenge))
            case ("POST", "/v1/installations"):
                let body = try! JSONSerialization.jsonObject(
                    with: OfflineMapTestURLProtocol.bodyData(from: request)
                ) as! [String: Any]
                let attestation = body["appAttest"] as! [String: Any]
                assertEqual(
                    attestation["challengeId"] as? String,
                    attestationChallenge.challengeId,
                    "registration binds the server-issued challenge"
                )
                assertEqual(
                    attestation["keyId"] as? String,
                    keyID,
                    "registration submits the generated App Attest key"
                )
                assertEqual(
                    attestation["attestationObject"] as? String,
                    appAttestService.attestationObject.base64EncodedString(),
                    "registration submits Apple's opaque attestation object"
                )
                assertEqual(
                    attestation["appBuild"] as? String,
                    "123",
                    "registration binds the installed app build"
                )
                return (201, try! JSONEncoder().encode(credential))
            case ("POST", "/v1/map-jobs"):
                mapCreateCount += 1
                let expectedChallenge = mapCreateCount == 1
                    ? assertionChallenge
                    : assertionRetryChallenge
                assertEqual(
                    request.value(forHTTPHeaderField:
                        "X-App-Attest-Challenge-Id"),
                    expectedChallenge.challengeId,
                    "map creation carries the assertion challenge identity"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-App-Attest-Key-Id"),
                    keyID,
                    "map creation carries the enrolled App Attest key"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-App-Attest-Assertion"),
                    appAttestService.assertionObject.base64EncodedString(),
                    "map creation carries the generated assertion"
                )
                assertEqual(
                    request.value(forHTTPHeaderField: "X-App-Attest-App-Build"),
                    "123",
                    "map creation binds the same app build"
                )
                if mapCreateCount == 1 {
                    return (
                        401,
                        Data(
                            #"{"detail":{"code":"app_attest_counter_replay","message":"App Attest assertion was replayed"}}"#.utf8
                        )
                    )
                }
                return (201, Data(#"{"jobId":"job-attested","status":"queued"}"#.utf8))
            default:
                assert(false, "unexpected App Attest request \(request.url?.path ?? "")")
                return (500, Data())
            }
        }

        do {
            let enrolled = try await managedClient.enroll(baseURL: baseURL)
            assertEqual(enrolled, credential, "App Attest enrollment returns its bound identity")
            try managedClient.finalizeEnrollment(
                enrolled,
                serverURLString: baseURL.absoluteString
            )
            assert(
                managedClient.hasKey(keyID, serverURLString: baseURL.absoluteString),
                "the device-only key identifier is retained for later assertions"
            )
            assertEqual(
                appAttestService.attestationHashes,
                [Data(SHA256.hash(data: rawAttestationChallenge))],
                "Apple attestation hashes the exact server challenge"
            )

            let jobRequest = OfflineMapJobRequest.customBBox(
                OfflineMapBounds(
                    minLon: 103.75,
                    minLat: 1.24,
                    maxLon: 103.93,
                    maxLat: 1.37
                )
            ).identified(
                clientInstallationId: credential.clientInstallationId,
                clientRequestId: "request-app-attest-123",
                installOnDevice: true
            )
            let client = OfflineMapPlatformClient(
                baseURL: baseURL,
                clientInstallationId: credential.clientInstallationId,
                clientInstallationToken: credential.clientInstallationToken,
                clientAppAttestKeyId: keyID,
                mapStreamTrustCapabilities: nil,
                mapStreamAppBuildIdentity: nil,
                managedAppAttestClient: managedClient,
                session: session
            )
            let job = try await client.createJob(jobRequest)
            assertEqual(job.jobId, "job-attested", "attested map creation decodes normally")

            let unsignedRequest = try OfflineMapPlatformClient
                .makeCreateJobURLRequest(
                    baseURL: baseURL,
                    jobRequest: jobRequest
                )
            let expectedClientData = try OfflineMapAppAttestClientData.mapCreate(
                challenge: assertionChallenge,
                clientInstallationID: credential.clientInstallationId,
                appBuild: "123",
                request: unsignedRequest,
                jobRequest: jobRequest
            )
            let expectedRetryClientData = try OfflineMapAppAttestClientData.mapCreate(
                challenge: assertionRetryChallenge,
                clientInstallationID: credential.clientInstallationId,
                appBuild: "123",
                request: unsignedRequest,
                jobRequest: jobRequest
            )
            assertEqual(
                appAttestService.assertionHashes,
                [
                    Data(SHA256.hash(data: expectedClientData)),
                    Data(SHA256.hash(data: expectedRetryClientData)),
                ],
                "the assertion binds the request and a replay rejection gets one fresh challenge"
            )
        } catch {
            assert(false, "managed App Attest client contract succeeds: \(error)")
        }
    }

    static func testOfflineMapAppAttestGoldenVector() {
        let fixtureURL = URL(
            fileURLWithPath:
                "map-platform/backend/tests/fixtures/app_attest_map_create_v1.json"
        )
        guard let fixtureData = try? Data(contentsOf: fixtureURL),
              let fixture = try? JSONSerialization.jsonObject(
                  with: fixtureData
              ) as? [String: String],
              let challengeID = fixture["challengeId"],
              let challenge = fixture["challenge"],
              let installationID = fixture["clientInstallationId"],
              let appBuild = fixture["appBuild"],
              let requestBody = fixture["requestBody"]?.data(using: .utf8),
              let expectedClientData = fixture["expectedClientData"],
              let expectedHash = fixture["expectedClientDataSha256"] else {
            assert(false, "App Attest golden vector is readable")
            return
        }
        let challengeDocument = OfflineMapAppAttestChallenge(
            challengeId: challengeID,
            challenge: challenge,
            purpose: "map-create",
            expiresAt: 1_800_000_000,
            keyId: nil
        )
        let jobRequest = OfflineMapJobRequest(
            mode: "custom_bbox",
            bbox: [103.75, 1.24, 103.93, 1.37],
            geometry: nil,
            route: nil,
            corridorWidthM: nil,
            clientInstallationId: installationID,
            clientRequestId: "request-golden-123",
            installOnDevice: nil,
            target: .init(
                renderer: "esp32-fmb",
                rendererFormatVersion: 3,
                firmwareVersion: nil
            ),
            labels: .init(
                profileVersion: 1,
                preferredLanguages: [],
                internationalFallback: "en"
            )
        )
        var request = URLRequest(
            url: URL(string: "https://maps.example.com/v1/map-jobs")!
        )
        request.httpBody = requestBody
        do {
            let clientData = try OfflineMapAppAttestClientData.mapCreate(
                challenge: challengeDocument,
                clientInstallationID: installationID,
                appBuild: appBuild,
                request: request,
                jobRequest: jobRequest
            )
            assertEqual(
                String(data: clientData, encoding: .utf8),
                expectedClientData,
                "Swift and backend canonical App Attest client data match"
            )
            let clientDataHash = SHA256.hash(data: clientData)
                .map { String(format: "%02x", $0) }
                .joined()
            assertEqual(
                clientDataHash,
                expectedHash,
                "Swift and backend App Attest client-data hashes match"
            )
        } catch {
            assert(false, "App Attest golden vector validates: \(error)")
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
            coordinates: [sourceCoordinate, destinationCoordinate],
            expectedTravelTime: 300
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
            ],
            expectedTravelTime: 120
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
        assert(
            coordinator.routeAlternatives[0].route === scenic,
            "fastest alternative is listed first"
        )
        assert(coordinator.routePreview === scenic, "fastest alternative is previewed")
        assert(
            coordinator.selectedRouteAlternativeID == nil,
            "the rider must explicitly select an alternative"
        )

        let scenicID = coordinator.routeAlternatives[0].id
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
    static func testCoordinatorRequiresSelectionForSingleRoute() {
        let suite = "CoordinatorSingleRoute.\(UUID().uuidString)"
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
        let route = TestRoute(
            instructions: "Continue",
            coordinates: [sourceCoordinate, destinationCoordinate]
        )

        coordinator.planNavigation(
            from: .mapItem(source),
            to: .mapItem(destination),
            transportType: RouteTransportTypes.cycling,
            isTestMode: true
        )
        assertEqual(factory.tasks.count, 1, "single-route planning creates one request")
        assert(
            factory.tasks[0].request.requestsAlternateRoutes,
            "single-route planning still asks MapKit for alternatives"
        )
        factory.tasks[0].succeed(with: [route])

        assert(!coordinator.isNavigating, "one returned route waits for user confirmation")
        assertEqual(coordinator.routeAlternatives.count, 1, "single-route planning still shows the picker")
        assert(
            coordinator.selectedRouteAlternativeID == nil,
            "single-route planning requires an explicit selection"
        )
        coordinator.selectRouteAlternative(coordinator.routeAlternatives[0].id)
        coordinator.startSelectedRoute()
        assert(coordinator.isNavigating, "the explicitly selected route starts")
        assert(coordinator.currentRoute === route, "the selected route becomes active")
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
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation))
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
            coordinator.processNavigationLocationForTesting(freshNavigationFix(cooldownDeviation))
        }
        assertEqual(factory.tasks.count, 2, "cooldown suppresses an immediate repeated reroute")
    }

    @MainActor
    static func testCoordinatorReroutesWhenProgressRejectsFarLocation() {
        let suite = "CoordinatorRerouteTests.FarStart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let factory = TestNavigationDirectionsFactory()
        let coordinator = BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(defaults: defaults),
            directionsFactory: factory.makeTask,
            startServices: false
        )

        let sourceCoordinate = CLLocationCoordinate2D(
            latitude: 37.0000,
            longitude: -122.0000
        )
        let destinationCoordinate = CLLocationCoordinate2D(
            latitude: 37.0100,
            longitude: -122.0000
        )
        let source = MKMapItem(
            placemark: MKPlacemark(coordinate: sourceCoordinate)
        )
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destinationCoordinate)
        )
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
        assert(
            waitForMainLoop(timeout: 2) {
                !coordinator.routeCalculation.isCalculating
            },
            "initial route calculation should finish before far-location reroute evaluation"
        )

        let farOffRouteLocation = testLocation(
            latitude: 37.0040,
            longitude: -121.9950,
            horizontalAccuracy: 5
        )
        let routeStart = CLLocation(
            latitude: sourceCoordinate.latitude,
            longitude: sourceCoordinate.longitude
        )
        assert(
            farOffRouteLocation.distance(from: routeStart) > 150,
            "the regression location must remain outside the progress-acceptance gate"
        )

        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(farOffRouteLocation)
        }
        assertEqual(factory.tasks.count, 1, "repeated cached fix is only one observation")
        for age in [60.0, -60.0, 1.0] {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(
                farOffRouteLocation, at: farOffRouteLocation.timestamp.addingTimeInterval(-age)))
        }
        assertEqual(factory.tasks.count, 1, "stale, future and out-of-order fixes cannot trigger rerouting")

        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(farOffRouteLocation))
        }

        assertEqual(
            factory.tasks.count,
            2,
            "accurate off-route fixes reroute even when route progress rejects the location"
        )
        guard let rerouteSource = factory.tasks[1].request.source else {
            assert(false, "far-location reroute should include a source")
            return
        }
        assertCoordinate(
            rerouteSource.placemark.coordinate,
            latitude: farOffRouteLocation.coordinate.latitude,
            longitude: farOffRouteLocation.coordinate.longitude,
            "far-location reroute starts from the current GPS fix"
        )
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
    static func testPhoneWorkoutLocationContinuation() {
        var foreground = true
        let client = TestLocationManagerClient(authorizationLevel: .whenInUse)
        let manager = CurrentLocationManager(locationManager: client,
            applicationIsActive: { foreground })
        manager.setWorkoutActive(true, phoneOwned: true)
        assertEqual(client.startUpdatingLocationCallCount, 1,
                    "Phone ride starts When-In-Use GPS in foreground")
        assert(client.backgroundTrackingEnabledHistory.last == true,
               "Phone ride enables visible background location delivery")
        foreground = false
        manager.applicationStateDidChange()
        assertEqual(client.stopUpdatingLocationCallCount, 0,
                    "Locking phone retains the existing workout GPS stream")
        manager.setWorkoutActive(false)
        assertEqual(client.stopUpdatingLocationCallCount, 1,
                    "Finished phone ride releases its GPS demand")
        let coldClient = TestLocationManagerClient(authorizationLevel: .whenInUse)
        let coldManager = CurrentLocationManager(locationManager: coldClient,
            applicationIsActive: { false })
        coldManager.setWorkoutActive(true, phoneOwned: true)
        assertEqual(coldClient.startUpdatingLocationCallCount, 0,
                    "Cold background recovery does not pretend When-In-Use is Always")
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

        var isUnconfiguredDetectionActive = true
        let unconfiguredDetectionClient = TestLocationManagerClient(
            authorizationLevel: .denied
        )
        let unconfiguredDetectionLocationManager = CurrentLocationManager(
            locationManager: unconfiguredDetectionClient,
            applicationIsActive: { isUnconfiguredDetectionActive }
        )
        unconfiguredDetectionLocationManager.setRideDetectionArmed(true)
        assertEqual(
            unconfiguredDetectionClient.requestWhenInUseAuthorizationCallCount,
            1,
            "enabling ride detection requests native location permission automatically"
        )
        assertEqual(
            unconfiguredDetectionClient.startUpdatingLocationCallCount,
            0,
            "ride detection waits for the user's native location decision"
        )
        isUnconfiguredDetectionActive = false
        unconfiguredDetectionLocationManager.applicationStateDidChange()
        assertEqual(
            unconfiguredDetectionClient.requestWhenInUseAuthorizationCallCount,
            1,
            "location permission is not repeatedly requested after arming"
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

        let defaultSettingsSuite =
            "RideDetectionDefaultSettingsTests.\(UUID().uuidString)"
        guard let defaultSettingsDefaults =
            UserDefaults(suiteName: defaultSettingsSuite) else {
            assertionFailure("could not create ride detection defaults")
            return
        }
        defaultSettingsDefaults.removePersistentDomain(forName: defaultSettingsSuite)
        let defaultSettingsStore = RideDetectionSettingsStore(
            defaults: defaultSettingsDefaults
        )
        assert(defaultSettingsStore.settings.startMode == .ask,
               "ride detection defaults to Ask to Start")
        assert(defaultSettingsStore.settings.autoPauseEnabled,
               "ride detection defaults to Auto-Pause enabled")
        defaultSettingsDefaults.removePersistentDomain(forName: defaultSettingsSuite)

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
    static func storeForActiveWorkout(
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
        for sampleIndex in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(freshNavigationFix(rerouteTrigger, at: staleClock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
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
        staleCoordinator.processNavigationLocationForTesting(freshNavigationFix(
            movedAway, at: staleClock.now().addingTimeInterval(0.01)))
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
        for sampleIndex in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(freshNavigationFix(movedAway, at: staleClock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
        }
        assertEqual(
            staleFactory.tasks.count,
            2,
            "discarding a stale response still respects the reroute cooldown"
        )
        staleClock.advance(by: 15)
        for sampleIndex in 0..<3 {
            staleCoordinator.processNavigationLocationForTesting(freshNavigationFix(movedAway, at: staleClock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
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
            accuracyCoordinator.processNavigationLocationForTesting(freshNavigationFix(rerouteTrigger))
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
            coordinator.processNavigationLocationForTesting(freshNavigationFix(skippedAhead))
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
        for sampleIndex in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation, at: clock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
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
        for sampleIndex in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation, at: clock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
        }
        assertEqual(
            factory.tasks.count,
            3,
            "a failed replacement attempt does not clear the active route's cooldown"
        )

        clock.advance(by: 14.999)
        for sampleIndex in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation, at: clock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
        }
        assertEqual(factory.tasks.count, 3, "rerouting remains suppressed just before 15 seconds")

        clock.advance(by: 0.001)
        for sampleIndex in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation, at: clock.now().addingTimeInterval(Double(sampleIndex) * 0.000001)))
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
            stopCoordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation))
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
            replaceCoordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation))
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
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation))
        }
        assertEqual(factory.tasks.count, 2, "rerouting pauses while a replacement route is calculating")

        factory.tasks[1].succeed(with: [])
        assert(
            waitForMainLoop(timeout: 3) { !coordinator.routeCalculation.isCalculating },
            "failed replacement route calculation should finish"
        )
        for _ in 0..<3 {
            coordinator.processNavigationLocationForTesting(freshNavigationFix(offRouteLocation))
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
        let savedRouteID = UUID()
        assert(
            restoredStore.addFavorite(
                droppedPin,
                savedRouteID: savedRouteID
            )?.savedRouteID == savedRouteID,
            "favorite can be linked to its chosen saved route"
        )
        let linkedStore = SavedDestinationStore(
            defaults: defaults,
            recentLimit: 2
        )
        assertEqual(
            linkedStore.favorite(savedRouteID: savedRouteID)?.name,
            droppedPin.name,
            "favorite route link persists and resolves after restart"
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
        assertEqual(concurrentTransferWrites.count, 0,
                    "the unified writer holds transfer control behind an unidentified response callback")
        concurrentTransportReady = true
        concurrentManager.completeNavigationWriteForTesting(
            error: simulatedWriteError
        )
        assert(waitForMainLoop(timeout: 1) {
            concurrentTransferWrites.count == 1
        }, "the unified writer releases transfer control after the matching callback")
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
            artifactFormat: String = OfflineMapArtifact.bikeMapStreamFormat,
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
                format: artifactFormat,
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
        assert(!SavedMapListScope.savedMaps.includes(developmentMap, channel: "production"),
               "regular Saved Maps hides development-only library entries")
        assert(SavedMapListScope.developerMaps.includes(developmentMap, channel: "production"),
               "Developer Settings retains development-only library entries")
        assert(SavedMapListScope.savedMaps.includes(developmentMap, channel: "development"),
               "Bicino Dev keeps development maps in its normal saved list")
        assert(!SavedMapListScope.developerMaps.includes(developmentMap, channel: "development"),
               "Bicino Dev does not duplicate its saved maps in the production-only developer list")
        assert(SavedMapListScope.savedMaps.includes(nil, channel: "production"),
               "legacy phone and device maps without catalog metadata remain visible")
        assert(!SavedMapListScope.developerMaps.includes(nil, channel: "production"),
               "unknown legacy provenance is not classified as development")
        for state in ["promotion_pending", "blocked", "tombstoned"] {
            let unpublished = map(deliveryState: state, artifacts: developmentMap.artifacts)
            assert(!SavedMapListScope.savedMaps.includes(unpublished, channel: "production"),
                   "unpublished development maps stay out of the regular list")
            assert(SavedMapListScope.developerMaps.includes(unpublished, channel: "production"),
                   "unpublished development maps remain inspectable in Developer Settings")
        }
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
        assert(SavedMapListScope.savedMaps.includes(productionMap, channel: "production"),
               "promoted maps remain visible regardless of their development origin")
        assert(!SavedMapListScope.developerMaps.includes(productionMap, channel: "production"),
               "promotion moves a map out of the developer-only list")
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
        let zip = artifact(
            id: "prod-zip", tier: "production", requiredBuild: nil,
            sha256: String(repeating: "4", count: 64),
            artifactFormat: OfflineMapArtifact.storedZipFormat
        )
        let stream = artifact(
            id: "prod-stream", tier: "production", requiredBuild: nil,
            sha256: productionSHA256
        )
        let freshMap = map(deliveryState: "production", artifacts: [zip, stream])
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [zip.sha256],
                localPrimaryArtifact: zip.platformArtifact,
                map: freshMap, channel: "production", trustStore: .production
            ),
            "a freshly downloaded production ZIP is current despite a different BMAP hash"
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [zip.sha256],
                localPrimaryArtifact: zip.platformArtifact,
                map: map(deliveryState: "production", artifacts: [stream]),
                channel: "production", trustStore: .production
            ),
            "an unknown or superseded ZIP still needs a verified current download"
        )
        let devZip = artifact(
            id: "dev-zip", tier: "development", requiredBuild: nil,
            sha256: zip.sha256, artifactFormat: OfflineMapArtifact.storedZipFormat
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [devZip.sha256],
                localPrimaryArtifact: devZip.platformArtifact,
                map: map(deliveryState: "production", artifacts: [devZip, stream]),
                channel: "production", trustStore: .production
            ),
            "a development ZIP does not bypass production-tier refresh"
        )
        let oldStream = artifact(
            id: "old-stream", tier: "production", requiredBuild: nil,
            sha256: String(repeating: "5", count: 64)
        )
        assert(
            OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [oldStream.sha256, zip.sha256],
                localPrimaryArtifact: oldStream.platformArtifact,
                map: freshMap, channel: "production", trustStore: .production
            ),
            "a current fallback ZIP cannot hide a stale primary BMAP"
        )
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
            artifact: artifact,
            companion: nil
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
                    [1, 2, 3, 4],
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
                supports3DBuildings: false,
                supportsTopographicContours: false
            ),
            "renderer target 1 remains compatible with legacy firmware"
        )
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 2,
                supportsStreetLabels: true,
                supports3DBuildings: false,
                supportsTopographicContours: false
            ),
            "renderer target 2 requires street-label support"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 2,
                supportsStreetLabels: false,
                supports3DBuildings: false,
                supportsTopographicContours: false
            ),
            "renderer target 2 is refused on legacy firmware"
        )
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 3,
                supportsStreetLabels: true,
                supports3DBuildings: true,
                supportsTopographicContours: false
            ),
            "renderer target 3 requires 3D-building support"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 3,
                supportsStreetLabels: true,
                supports3DBuildings: false,
                supportsTopographicContours: false
            ),
            "renderer target 3 is refused before transfer to label-only firmware"
        )
        assert(
            SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 4,
                supportsStreetLabels: true,
                supports3DBuildings: true,
                supportsTopographicContours: true
            ),
            "renderer target 4 requires the complete contour capability stack"
        )
        assert(
            !SavedMapRendererCompatibilityPolicy.isCompatible(
                rendererFormatVersion: 4,
                supportsStreetLabels: true,
                supports3DBuildings: true,
                supportsTopographicContours: false
            ),
            "renderer target 4 is refused before transfer without contour support"
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
                hasCompletedLocationStep: false,
                needsLocationAuthorization: true,
                confirmedDeviceMapMissing: false
            ),
            .step(.welcome),
            "first launch starts with the Bicino welcome"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasCompletedLocationStep: false,
                needsLocationAuthorization: true,
                confirmedDeviceMapMissing: false
            ),
            .step(.location),
            "first launch explains location before requesting native access"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasCompletedLocationStep: false,
                needsLocationAuthorization: true,
                confirmedDeviceMapMissing: true
            ),
            .step(.location),
            "first-run location consent precedes device map setup"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasCompletedLocationStep: false,
                needsLocationAuthorization: false,
                confirmedDeviceMapMissing: false
            ),
            .hidden,
            "existing location access skips the first-run permission step"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasCompletedLocationStep: true,
                needsLocationAuthorization: false,
                confirmedDeviceMapMissing: true
            ),
            .step(.download),
            "later confirmed map loss still offers download"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.presentation(
                hasCompletedFirstRun: true,
                hasCompletedLocationStep: true,
                needsLocationAuthorization: false,
                confirmedDeviceMapMissing: false
            ),
            .hidden,
            "completed onboarding stays hidden while maps are available"
        )

        assertEqual(
            OfflineMapOnboardingPolicy.visibleStep(
                presentation: .step(.welcome),
                isStatePrepared: true,
                isDismissed: false,
                isMapAreaSelectionActive: false,
                isOfflineMapOperationBlocking: true
            ),
            .welcome,
            "first-run welcome is independent from offline map startup state"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.visibleStep(
                presentation: .step(.location),
                isStatePrepared: true,
                isDismissed: false,
                isMapAreaSelectionActive: false,
                isOfflineMapOperationBlocking: true
            ),
            .location,
            "first-run location consent is independent from map operations"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.visibleStep(
                presentation: .step(.download),
                isStatePrepared: true,
                isDismissed: false,
                isMapAreaSelectionActive: false,
                isOfflineMapOperationBlocking: true
            ),
            nil,
            "map download onboarding still waits for map operations"
        )
        assertEqual(
            OfflineMapOnboardingPolicy.visibleStep(
                presentation: .step(.welcome),
                isStatePrepared: true,
                isDismissed: true,
                isMapAreaSelectionActive: false,
                isOfflineMapOperationBlocking: false
            ),
            nil,
            "dismissed onboarding remains hidden"
        )

        assert(
            OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "",
                mapStateKnown: false,
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
                mapStateKnown: false,
                mapFoundForCurrentLocation: false
            ),
            "an installed map waits for an authoritative renderer result"
        )
        assert(
            OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "custom-map-6354c43431",
                mapStateKnown: true,
                mapFoundForCurrentLocation: false
            ),
            "a known out-of-coverage map offers the download onboarding"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "custom-map-6354c43431",
                mapStateKnown: true,
                mapFoundForCurrentLocation: nil
            ),
            "unknown device coverage does not show a premature download prompt"
        )
        assert(
            !OfflineMapOnboardingPolicy.shouldOfferDownload(
                isLocationAuthorized: true,
                isNavigationReady: true,
                hasSDCard: true,
                activeMapId: "custom-map-6354c43431",
                mapStateKnown: true,
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
                mapStateKnown: true,
                mapFoundForCurrentLocation: false
            ),
            "the device-specific prompt waits for location authorization"
        )
    }

    static func testBicinoDeviceIntroductionPolicies() {
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: nil,
                activeMapID: "",
                mapStateKnown: false,
                mapFoundForCurrentLocation: nil
            ),
            .checking,
            "the guide waits for the first device status"
        )
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: false,
                activeMapID: "",
                mapStateKnown: false,
                mapFoundForCurrentLocation: false
            ),
            .needsSDCard,
            "the guide distinguishes missing storage from missing coverage"
        )
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: true,
                activeMapID: "",
                mapStateKnown: false,
                mapFoundForCurrentLocation: false
            ),
            .needsMap,
            "the absence of an active map is immediately actionable"
        )
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: true,
                activeMapID: "installed-map",
                mapStateKnown: false,
                mapFoundForCurrentLocation: false
            ),
            .checking,
            "installed maps wait for authoritative renderer coverage"
        )
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: true,
                activeMapID: "installed-map",
                mapStateKnown: true,
                mapFoundForCurrentLocation: false
            ),
            .needsMap,
            "known out-of-coverage maps offer setup"
        )
        assertEqual(
            BicinoDeviceMapReadiness.resolve(
                hasSDCard: true,
                activeMapID: "installed-map",
                mapStateKnown: true,
                mapFoundForCurrentLocation: true
            ),
            .ready,
            "known coverage completes map setup"
        )

        let firstDevice = "0123456789abcdef"
        let secondDevice = "fedcba9876543210"
        let stored = BicinoDeviceIntroductionHistory.adding(
            deviceID: firstDevice,
            to: ""
        )
        assert(
            BicinoDeviceIntroductionHistory.contains(
                deviceID: firstDevice,
                storedTokens: stored
            ),
            "completed introductions persist by stable device identity"
        )
        assert(
            !BicinoDeviceIntroductionHistory.contains(
                deviceID: secondDevice,
                storedTokens: stored
            ),
            "another Bicino still receives its first-connection guide"
        )
        assertEqual(
            BicinoDeviceIntroductionHistory.adding(
                deviceID: firstDevice,
                to: stored
            ),
            stored,
            "recording the same device is idempotent"
        )
    }

    static func testBicinoAppLinkPolicy() {
        assert(
            BicinoAppLinkPolicy.isDeviceConnectionLink(
                URL(string: "https://bicino.com/app")!
            ),
            "the pre-connection QR destination is a Bicino connection link"
        )
        assert(
            BicinoAppLinkPolicy.isDeviceConnectionLink(
                URL(string: "https://bicino.com/app/?source=qr")!
            ),
            "the connection link tolerates a trailing slash and query items"
        )
        for invalidURL in [
            "http://bicino.com/app",
            "https://www.bicino.com/app",
            "https://bicino.com/",
            "https://bicino.com/app/extra",
            "bikecomputer://connect"
        ] {
            assert(
                !BicinoAppLinkPolicy.isDeviceConnectionLink(
                    URL(string: invalidURL)!
                ),
                "only the canonical HTTPS Bicino app path is handled"
            )
        }

        assert(
            BicinoAppLinkPresentationPolicy.shouldPresent(
                isApplicationActive: true,
                isOnboardingStatePrepared: true,
                hasVisibleOnboarding: false,
                hasPresentedSheet: false,
                hasActiveSheet: false,
                isSheetDismissalInFlight: false,
                hasQueuedSheet: false,
                hasSavedRouteMapPreview: false,
                isMapAreaSelectionActive: false
            ),
            "a ready app presents the add-device sheet for the connection link"
        )
        let blockingStates: [(String, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            ("inactive app", false, true, false, false, false, false, false, false),
            ("unprepared onboarding state", true, false, false, false, false, false, false, false),
            ("visible welcome", true, true, true, false, false, false, false, false),
            ("presented sheet", true, true, false, true, false, false, false, false),
            ("active sheet", true, true, false, false, true, false, false, false),
            ("sheet dismissal", true, true, false, false, false, true, false, false),
            ("queued sheet", true, true, false, false, false, false, true, false),
            ("saved route preview", true, true, false, false, false, false, false, true),
            ("map area selection", true, true, false, false, false, false, false, false)
        ]
        for state in blockingStates {
            assert(
                !BicinoAppLinkPresentationPolicy.shouldPresent(
                    isApplicationActive: state.1,
                    isOnboardingStatePrepared: state.2,
                    hasVisibleOnboarding: state.3,
                    hasPresentedSheet: state.4,
                    hasActiveSheet: state.5,
                    isSheetDismissalInFlight: state.6,
                    hasQueuedSheet: state.7,
                    hasSavedRouteMapPreview: state.8,
                    isMapAreaSelectionActive: state.0 == "map area selection"
                ),
                "the connection link is ignored while \(state.0)"
            )
        }
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
            "Up to 1 hr 45 min remaining",
            "the checked-in bootstrap gives old backends a conservative time"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.availablePresentation(
                for: oldBackend
            ),
            nil,
            "the server-only presentation remains unavailable without an estimate"
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.availablePresentation(
                for: available
            ),
            OfflineMapPreparationEstimatePresentation(
                title: "Estimated Remaining",
                value: "Less than a minute"
            ),
            "the main settings row shows a validated server estimate"
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
            "Up to 1 hr 45 min remaining",
            "a retry uses the bootstrap until its server estimate arrives"
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
            "Up to 1 hr 45 min remaining",
            "a newly claimed retry replaces the stale estimate with the bootstrap"
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
            "Up to 1 hr 45 min remaining",
            "a malformed server range falls back to the conservative bootstrap"
        )
        let encoding = decode(
            """
            {
              "jobId": "estimate-encoding-bootstrap",
              "status": "converting_features",
              "progress": {"phase": "block_encoding"}
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: encoding,
                now: now
            )?.value,
            "Up to 15 min remaining",
            "the bootstrap narrows after preprocessing reaches block encoding"
        )
        let packaging = decode(
            """
            {
              "jobId": "estimate-packaging-bootstrap",
              "status": "packaging"
            }
            """
        )
        assertEqual(
            OfflineMapPreparationEstimatePresentation.presentation(
                for: packaging,
                now: now
            )?.value,
            "Up to 2 min remaining",
            "the bootstrap narrows for final packaging"
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

    static func testOfflineMapQueuePositionPresentation() {
        func decode(_ status: String, position: Int?) -> OfflineMapJob {
            var payload: [String: Any] = ["jobId": "queue-test", "status": status]
            if let position { payload["queuePosition"] = position }
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return try! JSONDecoder().decode(OfflineMapJob.self, from: data)
        }

        assertEqual(
            decode("queued", position: 2).queueDescription,
            "Estimated queue position: 2",
            "queue position is presented as an estimate"
        )
        assertEqual(
            decode("queued", position: nil).queueDescription,
            "Waiting in map queue",
            "older servers still show the waiting state"
        )
        assertEqual(
            decode("converting_features", position: 1).queueDescription,
            "Estimated queue position: 1",
            "yielded work can rejoin the waiting queue"
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

}
