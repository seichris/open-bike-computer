// Only external boundaries/value producers are doubled. Lifecycle, stop,
// generation, queue admission/drain, app ACK coordination and persistence calls
// are executed by the production WatchDeviceLink source, not a mirrored model.
import Foundation

struct WatchControllerCredentialV1 {
    var deviceID = "00112233445566778899aabbccddeeff"
    var controllerID = Data([1])
}
final class WatchControllerCredentialStore {
    var values = [WatchControllerCredentialV1()]
    func allActiveCredentials() throws -> [WatchControllerCredentialV1] { values }
}
struct WatchSelectedBikeComputerV1: Codable, Equatable {
    static let applicationContextKey = "selected"
    let revision: Int
    let deviceID: String?
    static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    func selects(_ value: WatchControllerCredentialV1) -> Bool { deviceID == value.deviceID }
}
struct WatchScopedAuthenticationV1 {
    init(credential: WatchControllerCredentialV1, clientNonce: Data) throws {}
    let hello = "WATCH|test"
    func acceptServer(_ message: String) throws -> WatchScopedAuthenticationChallengeV1 { .init() }
    func finish(_ message: String, challenge: WatchScopedAuthenticationChallengeV1) throws -> WatchAuthenticatedBLESessionV1 { .init() }
}
struct WatchScopedAuthenticationChallengeV1 { let proofCommand = "WATCH_PROOF|test" }
final class WatchAuthenticatedBLESessionV1 {
    // Test fixture enters at the authenticated boundary; it does not validate AES.
    func frame(payload: Data, channel: WatchAuthenticatedBLEChannelV1) throws -> Data { payload }
    func notificationPayload(from raw: Data, channel: WatchAuthenticatedBLEChannelV1) -> Data? {
        guard raw.starts(with: [0x52, 0x32]) else { return nil }
        return Data(raw.dropFirst(2))
    }
}
struct RouteCoordinateV1 { let latitude: Double; let longitude: Double }
struct NavigationLocationSampleV1 {
    let coordinate: RouteCoordinateV1
    let horizontalAccuracyMeters: Double
    let courseDegrees: Double
    let speedMetersPerSecond: Double
    let altitudeMeters: Double
    let timestamp: Date
}
struct NavigationSnapshotV1 {
    var routeWindow = Data()
    var navigationGeneration = 1
    var routeID = "test-route"
    var revision = 1
    var currentStepIndex = 0
    var maneuver = 1
    var instruction = "test-maneuver"
    var offRouteDistanceMeters = 0.0
    var distanceToManeuverMeters = 0.0
}
enum WorkoutDeviceSessionState { case idle, running, ending, ended, failed }
struct WorkoutDeviceFrames {
    struct Identity { let state: WorkoutDeviceSessionState }
    let identity: Identity
}
struct WorkoutDeviceGPSUpdate {
    let latitude: Double; let longitude: Double; let horizontalAccuracyMeters: Double
    let courseDegrees: Double?; let speedMetersPerSecond: Double?; let altitudeMeters: Double?
    let capturedAt: Date; let distanceTraveledMeters: Double?; let elapsedSeconds: TimeInterval?
}
enum WorkoutDeviceFrameBuilder {
    static func transportFrames(for frames: WorkoutDeviceFrames, generation: UInt8, includeOrigin: Bool) -> [Data] {
        [Data("workout-\(frames.identity.state)-identity".utf8), Data("workout-\(frames.identity.state)-metrics".utf8)]
    }
}
enum WatchRidePacketEncoderV1 {
    static func maneuver(_ snapshot: NavigationSnapshotV1?) -> Data { Data((snapshot?.instruction ?? "idle").utf8) }
    static func gps(_ location: NavigationLocationSampleV1, snapshot: NavigationSnapshotV1?, distanceTraveledMeters: Double? = nil, elapsedSeconds: TimeInterval? = nil, includeRideDetectionQuality: Bool = false) -> Data { Data("gps-\(location.coordinate.latitude)".utf8) }
    static func refreshingQualityAge(in payload: Data, sampleTimestamp: Date) -> Data { payload }
}
struct RideAutomationFrame {
    enum Kind: UInt8 { case resynchronize, configuration, other }
    let kind: Kind = .resynchronize
    init?(_ data: Data) { guard data.count == 52 else { return nil } }
    func encoded() -> Data? { Data(repeating: 1, count: 52) }
}
protocol WatchNavigationDeviceLinking {}

// Primitive endian helpers for the extracted command/ACK serialization types.
extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    func uint32LE(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
}
