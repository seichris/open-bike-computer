import Foundation

@MainActor
final class FakeSpokenTransport: SpokenDirectionsTransportV1 {
    var isSpokenDirectionsReady = true
    var spokenDirectionsConnectionGeneration: UInt64 = 1
    struct Write {
        let type: RideBLEApplicationCommandTypeV1
        let initial: Data
        let prepare: () -> Data?
        let complete: (Bool) -> Void
    }
    var writes: [Write] = []
    func sendSpokenDirectionsCommand(commandType: RideBLEApplicationCommandTypeV1, payload: Data,
                                    preparePayload: @escaping () -> Data?, completion: @escaping (Bool) -> Void) -> Bool {
        writes.append(Write(type: commandType, initial: payload, prepare: preparePayload, complete: completion))
        return true
    }
}

@main
enum SpokenDirectionsTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
    static func sample(_ scheduler: inout SpokenCueSchedulerV1, _ distance: Double, _ tick: Double,
                       index: Int = 0, text: String = "Turn right onto Left Street", speed: Double = 5,
                       enabled: Bool = true, ready: Bool = true, paused: Bool = false,
                       accuracy: Double = 5, age: Double = 0, locale: String = "en-GB",
                       offRoute: Bool = false) -> SpokenCueDecisionV1? {
        let timestamp = Date(timeIntervalSince1970: 1000 + tick)
        let step = NavigationRouteStepV1(id: UInt32(index + 1), geometryStartIndex: 0,
                                        geometryEndIndex: 1, instruction: text, maneuver: .straight,
                                        distanceMeters: 1000)
        let snapshot = NavigationSnapshotV1(navigationGeneration: 1, routeID: UUID(), revision: 1,
            contentHash: nil, currentStepIndex: index, maneuver: .straight, instruction: text,
            distanceToManeuverMeters: distance, routeRemainingDistanceMeters: distance,
            expectedArrival: nil, offRouteDistanceMeters: offRoute ? 100 : nil, mode: .online,
            routeWindow: Data())
        let location = NavigationLocationSampleV1(coordinate: RouteCoordinateV1(latitude: 0, longitude: 0),
            horizontalAccuracyMeters: accuracy, courseDegrees: 0, speedMetersPerSecond: speed,
            altitudeMeters: 0, timestamp: timestamp)
        return scheduler.evaluate(snapshot: snapshot, step: step, locale: locale, location: location,
                                  now: timestamp.addingTimeInterval(age), uptime: tick,
                                  enabled: enabled, ready: ready, paused: paused)
    }
    static func fresh(restored: Bool = false) -> SpokenCueSchedulerV1 {
        var s = SpokenCueSchedulerV1(); s.start(token: 7, generation: 1, restored: restored); return s
    }
    @MainActor static func main() {
        let golden = hex(SpokenDirectionsGeneratedV1.cueHex)
        let cue = SpokenCueV1.decode(golden)!
        expect(cue.encoded() == golden, "cue golden roundtrip")
        expect(cue.token == 0x0102030405060708 && cue.generation == 0x11223344 &&
               cue.phase == .prepare && cue.maneuver == .right && cue.distanceBucket == 50,
               "cue independently specified fields")
        for size in 0..<golden.count { expect(SpokenCueV1.decode(golden.prefix(size)) == nil, "cue truncation") }
        for at in [0,4,5,6,7,36,37,38,39] {
            var bad = golden; bad[at] = 255
            expect(SpokenCueV1.decode(bad) == nil, "cue rejects malformed field \(at)")
        }
        let control = hex(SpokenDirectionsGeneratedV1.controlHex)
        expect(SpokenRouteControlV1.decode(control)?.encoded() == control, "control golden")
        for size in 0..<control.count { expect(SpokenRouteControlV1.decode(control.prefix(size)) == nil, "control truncation") }
        for at in [0,4,5,6,7,34,35] {
            var bad = control; bad[at] = 255
            expect(SpokenRouteControlV1.decode(bad) == nil, "control malformed")
        }
        expect(SpokenManeuverClassifier.classify("Turn left onto Right Road", locale: "en-US") == .left, "anchored left")
        expect(SpokenManeuverClassifier.classify("Continue onto Destination Road", locale: "en-GB") == .straight, "street not arrival")
        for text in ["Destination Road", "Left Road", "Turn onto Right Avenue", "A sharp right road", ""] {
            expect(SpokenManeuverClassifier.classify(text, locale: "en-GB") == .unknown, "unknown is not straight")
        }
        expect(SpokenManeuverClassifier.classify("Turn right", locale: "de-DE") == .unknown, "locale policy")

        var s = fresh()
        expect(sample(&s, 300, 0) == nil, "observe long step")
        expect(s.prepareBucket == 100 && s.actionDistance == 25, "lead must satisfy minimum gap")
        let prepare = sample(&s, 100, 1)!
        expect(prepare.cue.phase == .prepare && prepare.cue.distanceBucket == 100, "prepare crossing")
        expect(sample(&s, 99, 2) == nil, "no repeated prepare")
        expect(sample(&s, 25, 3)?.cue.phase == .action, "action before 20m advance")
        expect(sample(&s, 24, 4) == nil, "no repeated action")
        expect(sample(&s, 22, 5, index: 1) == nil, "short adjacent step is seeded")
        expect(sample(&s, 200, 6, index: 0) == nil, "old step cannot rearm")
        expect(prepare.payload(at: 0, token: 7, generation: 1, stepID: 1) == nil, "clock before enqueue")
        expect(prepare.payload(at: 6, token: 7, generation: 1, stepID: 1) == nil, "dispatch expiry")
        let delayed = prepare.payload(at: 2, token: 7, generation: 1, stepID: 1)!
        expect(SpokenCueV1.decode(delayed)?.startLifetimeMS == 4000, "remaining TTL at dispatch")
        expect(prepare.payload(at: 2, token: 8, generation: 1, stepID: 1) == nil, "old token")

        s = fresh(); _ = sample(&s, 300, 0)
        expect(sample(&s, 22, 1)?.cue.phase == .action, "skip prepare for action in same fix")
        s = fresh(); expect(sample(&s, 22, 0)?.cue.phase == .action, "new route near-start exception")
        s = fresh(restored: true); expect(sample(&s, 22, 0) == nil, "no restored near-start exception")
        s = fresh(restored: true); expect(sample(&s, 0, 0, text: "Arrive at destination") == nil, "no restored arrival replay")
        s = fresh(); _ = sample(&s, 300, 0); s.resynchronize()
        expect(sample(&s, 90, 1) == nil, "reconnect seeds missed prepare")
        expect(sample(&s, 80, 2) == nil, "no catch-up after reconnect")
        expect(sample(&s, 22, 3)?.cue.phase == .action, "future crossing after reconnect")
        s.stop(); expect(sample(&s, 100, 4) == nil, "stop invalidates lifecycle")

        for rejection in 0..<7 {
            s = fresh(); _ = sample(&s, 300, 0)
            let result = sample(&s, 100, 1, speed: rejection == 0 ? 0 : 5,
                enabled: rejection != 1, ready: rejection != 2, paused: rejection == 3,
                accuracy: rejection == 4 ? 100 : 5, age: rejection == 5 ? 6 : 0, offRoute: rejection == 6)
            expect(result == nil, "reject invalid observation \(rejection)")
            expect(sample(&s, 90, 2) == nil, "no stale catch-up after suppression")
        }
        s = fresh(); _ = sample(&s, 300, 0, speed: 15)
        expect(s.prepareBucket == 200 && s.actionDistance == 45, "fast speed band")
        expect(sample(&s, 200, 1, speed: 2)?.cue.distanceBucket == 200, "frozen bucket")
        expect(sample(&s, 45, 2, speed: 2)?.cue.phase == .action, "frozen action")
        s = fresh(); _ = sample(&s, 300, 0)
        expect(sample(&s, 0, 1, index: 1, text: "Arrive at destination")?.cue.phase == .arrival, "terminal arrival before engine stop")
        expect(sample(&s, 0, 2, index: 1, text: "Arrive at destination") == nil, "at most once arrival")
        s = fresh(); _ = sample(&s, 300, 0, text: "Destination Road")
        expect(sample(&s, 100, 1, text: "Destination Road") == nil, "unknown suppresses prepare")
        expect(sample(&s, 22, 2, text: "Destination Road")?.cue.maneuver == .continueRoute, "unknown nondirectional fallback")
        controllerTests()
        print("SpokenDirectionsTests passed")
    }

    @MainActor static func controllerTests() {
        var tick = 0.0
        let transport = FakeSpokenTransport()
        let controller = SpokenDirectionsControllerV1(uptime: { tick })
        controller.transport = transport
        func observe(_ distance: Double, index: Int = 0, text: String = "Turn left onto Right Road") {
            let timestamp = Date(timeIntervalSince1970: 1000 + tick)
            let step = NavigationRouteStepV1(id: UInt32(index + 1), geometryStartIndex: 0,
                geometryEndIndex: 1, instruction: text, maneuver: .straight, distanceMeters: 1000)
            let snapshot = NavigationSnapshotV1(navigationGeneration: 1, routeID: UUID(), revision: 1,
                contentHash: nil, currentStepIndex: index, maneuver: .straight, instruction: text,
                distanceToManeuverMeters: distance, routeRemainingDistanceMeters: distance,
                expectedArrival: nil, offRouteDistanceMeters: nil, mode: .online, routeWindow: Data())
            let location = NavigationLocationSampleV1(coordinate: RouteCoordinateV1(latitude: 0, longitude: 0),
                horizontalAccuracyMeters: 5, courseDegrees: 0, speedMetersPerSecond: 5,
                altitudeMeters: 0, timestamp: timestamp)
            controller.observe(snapshot: snapshot, step: step, locale: "en-GB", location: location,
                now: timestamp, enabled: true, paused: false, volume: 70)
        }
        controller.start(generation: 1)
        observe(300)
        expect(transport.writes.count == 1, "activate only")
        expect(SpokenRouteControlV1.decode(transport.writes[0].prepare()!)?.action == .activate, "activation wire")
        transport.writes[0].complete(true)
        tick = 1; observe(100)
        expect(transport.writes.count == 2, "progress must precede cue")
        tick = 2
        expect(SpokenRouteControlV1.decode(transport.writes[1].prepare()!)?.leaseMS == 4000, "lease not renewed by queue delay")
        transport.writes[1].complete(true)
        expect(transport.writes.count == 3 && transport.writes[2].type == .spokenCue, "cue after application ACK")
        expect(SpokenCueV1.decode(transport.writes[2].prepare()!)?.startLifetimeMS == 4000, "adapter dispatch remaining TTL")
        controller.stop()
        expect(transport.writes[2].prepare() == nil, "cancel fences queued and retried cue")
        expect(SpokenRouteControlV1.decode(transport.writes.last!.initial)?.action == .cancel, "cancel sent")
        transport.writes[2].complete(true) // old completion cannot revive work
        expect(transport.writes.count == 4, "late callback inert")

        controller.start(generation: 1)
        tick = 10; observe(300)
        transport.writes.last!.complete(true)
        tick = 11; observe(0, index: 1, text: "Arrive at destination")
        let progress = transport.writes.count - 1
        controller.stop(arrived: true)
        expect(transport.writes.count == progress + 1, "arrival stop waits for cue")
        expect(transport.writes[progress].prepare() != nil, "terminal grace preserves pending control")
        transport.writes[progress].complete(true)
        expect(SpokenCueV1.decode(transport.writes.last!.prepare()!)?.phase == .arrival, "arrival remains dispatchable")
        transport.writes.last!.complete(true)
        expect(SpokenRouteControlV1.decode(transport.writes.last!.initial)?.action == .arrived, "terminal control after cue ACK")

        controller.start(generation: 1)
        tick = 20; observe(300)
        let activation = transport.writes.count - 1
        controller.stop()
        expect(transport.writes[activation].prepare() == nil, "stop revokes pending activation")
        expect(SpokenRouteControlV1.decode(transport.writes.last!.initial)?.action == .cancel, "stop cancels activation with uncertain ACK")

        let suite = "spoken-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(SpokenDirectionsPreferencesV1.load(deviceID: "175", defaults: defaults) == .init(), "default off at 70 percent")
        SpokenDirectionsPreferencesV1(enabled: true, dynamicInstructions: true, volume: 42).save(deviceID: "175", defaults: defaults)
        expect(SpokenDirectionsPreferencesV1.load(deviceID: "175", defaults: defaults).volume == 42, "per-device preferences")
        expect(!SpokenDirectionsPreferencesV1.load(deviceID: "206", defaults: defaults).enabled, "preference cannot leak between boards")
    }
}
