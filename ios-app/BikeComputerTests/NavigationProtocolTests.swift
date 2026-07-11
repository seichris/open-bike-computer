import Foundation
import CoreLocation
import CoreBluetooth
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
        appendUInt32LE(0, to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt16LE(UInt16(name.count), to: &zip)
        appendUInt16LE(0, to: &zip)
        zip.append(name)
        zip.append(body)
    }
    return zip
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
    static func main() {
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
        testOfflineMapCreateJobURLRequest()
        testOfflineMapManagerMigratesProductionConfig()
        testOfflineMapManagerRestoresLastTransferIdentity()
        testOfflineMapManagerReconcilesInterruptedActivation()
        testOfflineMapManagerReconcilesAcknowledgedFirstInstall()
        testOfflineMapPolygonClosesRing()
        testOfflineMapStoredZipReader()
        testCachedMapInstalledIdentityUsesManifestSession()
        testOfflineMapManifestDecoding()
        testMapTransferUploadURLEncodesPlusPathComponents()
        testMapTransferUploadResumeContract()
        testMapTransferActivationAcknowledgementSequence()
        testMapTransferSessionIdentityUsesManifestContent()
        testMapActivationReconciliationMatrix()
        testMapActivationConfirmationOrchestration()
        testMapTransferDeviceStatusDecodesActivationFailure()
        testFirmwareManifestDecodingAndHash()
        testFirmwareUpdateManagerRestoresPendingStatus()
        testFirmwareUpdateAvailabilitySemantics()
        testFirmwareDeviceClientSendsSignedBeginRequest()
        print("NavigationProtocolTests passed")
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
    }

    static func testOfflineMapCreateJobURLRequest() {
        let request = OfflineMapJobRequest.customBBox(
            OfflineMapBounds(minLon: 10, minLat: 20, maxLon: 11, maxLat: 21)
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
    }

    static func testOfflineMapManagerMigratesProductionConfig() {
        let suite = "offline-map-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assert(false, "test defaults should create")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io", forKey: "offlineMap.serverURL")
        defaults.set("", forKey: "offlineMap.apiToken")

        assertEqual(
            OfflineMapManager.resolvedServerURL(defaults: defaults),
            "https://maps.8o.vc",
            "legacy offline map server URL migrates to production domain"
        )
        assertEqual(
            OfflineMapManager.resolvedAPIToken(defaults: defaults),
            OfflineMapServiceConfig.apiToken,
            "empty stored map API token falls back to bundled build token"
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
        defaults.set(
            ["custom-map-shanghai.zip": "Shanghai"],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(defaults: defaults)
        assertEqual(manager.lastTransferMapId, "custom-map-shanghai", "last transfer map id survives app restart")
        assertEqual(manager.lastTransferOutcome, "unconfirmed", "last transfer outcome survives app restart")
        assertEqual(manager.lastTransferDescription, "Shanghai — unconfirmed", "last transfer identifies the selected saved map")
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
            manager.isCachedPackInstalled(
                url,
                activeMapId: "map-1",
                activeSessionId: ""
            ),
            "legacy firmware without active-session status falls back to map ID"
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
    }

    @MainActor
    static func testMapTransferUploadResumeContract() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-upload-resume-\(UUID().uuidString).zip")
        let manifest = Data("{\"schemaVersion\":1,\"mapId\":\"map-1\"}".utf8)
        let firstBlock = Data("first-block".utf8)
        let secondBlock = Data("second-block".utf8)
        let zip = makeStoredZip(entries: [
            ("manifest.json", manifest),
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
        runMainActorAsyncTest {
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
        runMainActorAsyncTest {
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
    static func testMapTransferActivationAcknowledgementSequence() {
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
        runMainActorAsyncTest {
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
            !MapActivationTransport.isAmbiguousResponseError(URLError(.cannotConnectToHost)),
            "a connection failure before delivery remains a hard error"
        )
    }

    @MainActor
    static func testMapActivationConfirmationOrchestration() {
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
        runMainActorAsyncTest {
            try await manager.confirmActivatedMap(
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
        runMainActorAsyncTest {
            try await manager.confirmActivatedMap(
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
        runMainActorAsyncTest {
            do {
                try await manager.confirmActivatedMap(
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
                assert(false, "retained activation should time out")
            } catch OfflineMapPlatformError.mapActivationTimedOut {
                // Expected.
            }
        }
        assert(statusRequests > 1, "timeout covers repeated pending polls")
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
    ) {
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                failure = error
            }
            finished = true
        }
        assert(waitForMainLoop(timeout: 3) { finished },
               "main-actor async test should finish")
        if let failure {
            assert(false, "main-actor async test failed: \(failure)")
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
        assertEqual(DeviceBLEProtocol.deviceCapabilitiesVersion, 3, "capability version requests extended map visibility")
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
        assertEqual(DeviceScreen.map.rawValue, 0, "Map screen protocol value stays stable")
        assertEqual(DeviceScreen.navigation.rawValue, 1, "Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.rideStats.rawValue, 2, "Ride Stats screen protocol value stays stable")
        assertEqual(DeviceScreen.mapPlusNavigation.rawValue, 3, "Map + Navigation screen protocol value stays stable")
        assertEqual(DeviceScreen.mapPlusNavigation.title, "Map + Navigation", "combined map/navigation screen keeps user-facing label")
        assertEqual(DeviceScreen.displayOrder[0], .mapPlusNavigation, "Map + Navigation is the first device screen in settings")
        assertEqual(DeviceScreen.displayOrder[1], .rideStats, "Ride Stats is the second device screen in settings")
        assertEqual(DeviceScreen.allScreensMask, 0x0F, "all supported device screens use the low four mask bits")
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

        let rideStatsOnly = DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.mapPlusNavigation.rawValue, mask: rideStatsOnly),
                    .rideStats,
                    "disabled default falls back to the first enabled non-map screen")

        let mapAndStats = DeviceScreen.map.bit | DeviceScreen.rideStats.bit
        assertEqual(DeviceScreen.fallbackDefault(for: DeviceScreen.navigation.rawValue, mask: mapAndStats),
                    .rideStats,
                    "disabled default follows the device screen display order")
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
        {"configured":true,"enabled":true,"port":8080,"baseUrl":"http://192.168.4.20:8080","sdPresent":true,"mapFound":false,"mapBlocks":0,"activeMapId":"kyoto-v1","activeSessionId":"kyoto-v1-session","activation":{"status":"activating","sequence":12,"sessionId":"tokyo-v2","mapId":"tokyo-v2"},"lastError":{"code":"previous","message":"previous upload failed"}}
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        assertEqual(manager.sentPackets.count, 1, "navigation readiness should resend the current snapshot")
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
