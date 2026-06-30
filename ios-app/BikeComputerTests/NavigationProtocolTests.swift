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
        self.storedDistance = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
            .distance(from: CLLocation(latitude: coordinates[1].latitude, longitude: coordinates[1].longitude))
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
    static func main() {
        testIconMapping()
        testRouteEndpointExtraction()
        testSourceEndpointSelection()
        testRouteInitialLocationUsesResolvedSource()
        testRouteTransportTypes()
        testNavigationPacketBuilder()
        testNavigationWriteQueue()
        testBLEPairingAuthenticator()
        testBLEManagerRequiresNavigationReadinessForWrites()
        testBLEManagerSendsFallbackMapSettings()
        testBLEManagerPersistsNewMapSettings()
        testNavigationSendTrackerReadinessRetry()
        testNavigationEngineResendsWhenBLEBecomesReady()
        testNavigationEngineIgnoresLiveLocationFarFromRouteStart()
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
        assertEqual(String(data: packet.prefix(4), encoding: .utf8), "MSET", "fallback settings packet uses MSET prefix")
        assertEqual(packet[4], 8, "fallback settings packet includes setting id")
        let valueBytes = Array(packet[5..<9])
        let value = Int32(valueBytes[0])
            | (Int32(valueBytes[1]) << 8)
            | (Int32(valueBytes[2]) << 16)
            | (Int32(valueBytes[3]) << 24)
        assertEqual(value, 7, "fallback settings packet includes little-endian value")
    }

    static func testBLEManagerPersistsNewMapSettings() {
        let defaults = UserDefaults.standard
        let keys = ["mapSettings.mapRotationMode", "mapSettings.zoomLevel"]
        keys.forEach { defaults.removeObject(forKey: $0) }

        let manager = BLEManager()
        manager.mapRotationMode = 1
        manager.zoomLevel = 5
        manager.saveSettings()

        let reloaded = BLEManager()
        assertEqual(reloaded.mapRotationMode, 1, "map rotation mode should persist across BLEManager reloads")
        assertEqual(reloaded.zoomLevel, 5, "zoom level should persist across BLEManager reloads")

        keys.forEach { defaults.removeObject(forKey: $0) }
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
}
