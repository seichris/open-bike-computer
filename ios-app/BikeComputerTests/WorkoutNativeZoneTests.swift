#if NATIVE_WORKOUT_ZONE_HOST
import Foundation

@main
private enum WorkoutNativeZoneTests {
    static var checks = 0
    static let start = Date(timeIntervalSince1970: 1_000)
    static let now = start.addingTimeInterval(100)

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    static func configuration(
        _ count: Int = 5, metric: WorkoutNativeZoneMetricV1 = .heartRate,
        source: WorkoutNativeZoneSourceV1 = .system
    ) -> WorkoutNativeZoneConfigurationV1 {
        WorkoutNativeZoneConfigurationV1(
            metric: metric, source: source,
            ranges: (0..<count).map { index in
                WorkoutNativeZoneRangeV1(
                    minimum: index == 0 ? nil : Double(index * 100),
                    maximum: index == count - 1 ? nil : Double((index + 1) * 100)
                )
            }
        )
    }

    static func group(
        _ config: WorkoutNativeZoneConfigurationV1 = configuration(),
        current: UInt8? = nil, isFinal: Bool = false,
        durations: [Double]? = nil, at: Date = now
    ) -> WorkoutNativeZoneSnapshotV1 {
        WorkoutNativeZoneSnapshotV1(
            configuration: config,
            secondsByZone: durations ?? Array(repeating: 2, count: config.ranges.count),
            observedAt: at, currentZone: current,
            currentZoneSampleAt: current == nil ? nil : start.addingTimeInterval(1),
            isFinal: isFinal
        )
    }

    static func metric(_ value: Double = 150, at: Date = now,
                       unit: WorkoutMetricUnitV1 = .beatsPerMinute) -> WorkoutMetricV1 {
        WorkoutMetricV1(value: value, unit: unit, capturedAt: at, source: .healthKit)
    }

    static func envelope(_ native: WorkoutNativeZonesV1?, state: WorkoutSessionStateV1 = .running,
                         outcome: WorkoutTerminalOutcomeV1? = nil,
                         heartRate: WorkoutMetricV1? = metric()) -> WorkoutEnvelopeV1 {
        var mask: WorkoutAvailabilityMaskV1 = [.elapsedTime]
        if heartRate != nil { mask.insert(.currentHeartRate) }
        return WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: UUID(), sessionToken: 1,
            transportGenerationID: UUID(), sequence: 1, capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: state, startDate: start,
                elapsedTime: metric(100, unit: .seconds), currentHeartRate: heartRate,
                nativeZones: native, availability: mask, terminalOutcome: outcome
            )
        )
    }

    static func rejected(_ value: WorkoutEnvelopeV1) -> Bool {
        do { _ = try WorkoutContractCodec.encode(value); return false } catch { return true }
    }

    static func main() throws {
        for count in [3, 5, 6, 9] {
            let config = configuration(count)
            check(config.isValid, "accept \(count) zones")
            for index in 0..<count {
                let event = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: index, sampleAt: now)
                check(event?.currentZone == UInt8(index + 1), "zero-based conversion \(count):\(index)")
            }
            check(WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: -1, sampleAt: now) == nil, "negative index")
            check(WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: count, sampleAt: now) == nil, "overflow index")
            check(WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: Int.max, sampleAt: now) == nil, "integer overflow")
        }
        for count in [0, 1, 2, 10] { check(!configuration(count).isValid, "reject count \(count)") }
        for bad in [Double.nan, .infinity, -1] {
            let config = WorkoutNativeZoneConfigurationV1(metric: .heartRate, source: .system, ranges: [
                .init(minimum: nil, maximum: bad), .init(minimum: bad, maximum: 200), .init(minimum: 200, maximum: nil)
            ])
            check(!config.isValid, "bad threshold")
        }
        let gap = WorkoutNativeZoneConfigurationV1(metric: .heartRate, source: .system, ranges: [
            .init(minimum: nil, maximum: 100), .init(minimum: 101, maximum: 200), .init(minimum: 200, maximum: nil)
        ])
        check(!gap.isValid, "noncontiguous thresholds")
        let zeroLowerBound = WorkoutNativeZoneConfigurationV1(metric: .heartRate, source: .app, ranges: [
            .init(minimum: 0, maximum: 100), .init(minimum: 100, maximum: 200), .init(minimum: 200, maximum: nil)
        ])
        check(zeroLowerBound.isValid, "preserve an explicit zero lower bound")

        let overlap = WorkoutNativeZoneConfigurationV1(metric: .heartRate, source: .system, ranges: [
            .init(minimum: nil, maximum: 100), .init(minimum: 99, maximum: 200), .init(minimum: 200, maximum: nil)
        ])
        check(!overlap.isValid, "overlapping thresholds")
        check(!group(current: 0).isValid, "zero display ordinal")
        check(!group(current: 6).isValid, "out-of-range ordinal")
        check(!group(current: 1, isFinal: true).isValid, "final data has no live current zone")
        check(!group(durations: [1, 2]).isValid, "duration count")
        for bad in [Double.nan, .infinity, -1] {
            check(!group(durations: [bad, 0, 0, 0, 0]).isValid, "bad duration")
        }
        check(!group(durations: [.greatestFiniteMagnitude, .greatestFiniteMagnitude, 0, 0, 0]).isValid, "duration sum overflow")

        var live = WorkoutNativeZoneLiveState()
        let config = configuration()
        let event = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: 1, sampleAt: start.addingTimeInterval(1))!
        live.record(event, startDate: start, now: now)
        func current(_ sample: WorkoutMetricV1?, state: WorkoutSessionStateV1 = .running) -> UInt8? {
            live.applyingCurrentZone(to: group(), metric: sample, state: state, now: now).currentZone
        }
        check(current(metric()) == 2, "old transition plus fresh same-zone samples stays live")
        check(current(metric(100)) == 2, "shared lower boundary defers to native ordinal")
        check(current(metric(200)) == 2, "shared upper boundary defers to native ordinal")
        check(current(metric(201)) == nil, "raw sample contradicts retained transition")
        check(current(metric(99)) == nil, "raw sample below retained zone")
        check(current(nil) == nil, "missing sensor")
        check(current(metric(150, at: now.addingTimeInterval(-31))) == nil, "stale sensor")
        check(current(metric(150, at: now.addingTimeInterval(1))) == nil, "future sensor")
        check(current(metric(150, unit: .watts)) == nil, "wrong raw unit")
        for state in [WorkoutSessionStateV1.starting, .paused, .ending, .ended, .failed] {
            check(current(metric(), state: state) == nil, "no active highlight in \(state)")
        }
        let old = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: 0, sampleAt: start)!
        live.record(old, startDate: start, now: now)
        check(current(metric()) == 2, "out-of-order callback ignored")
        let duplicate = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: 0, sampleAt: event.sampleAt)!
        live.record(duplicate, startDate: start, now: now)
        check(current(metric()) == 2, "conflicting duplicate ignored")
        let future = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: 0, sampleAt: now.addingTimeInterval(1))!
        live.record(future, startDate: start, now: now)
        check(current(metric()) == 2, "future callback ignored")
        let differentConfig = group(configuration(6))
        check(live.applyingCurrentZone(to: differentConfig, metric: metric(), state: .running, now: now).currentZone == nil, "configuration cannot reinterpret old ordinal")
        let nilEvent = WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: nil, sampleAt: now)!
        live.record(nilEvent, startDate: start, now: now)
        check(current(metric()) == nil, "native nil current clears highlight")
        live.reset()
        check(current(metric()) == nil, "new session/recovery waits for native transition")

        let powerConfig = configuration(6, metric: .cyclingPower)
        let powerEvent = WorkoutNativeZoneEventV1.make(configuration: powerConfig, zeroBasedIndex: 0, sampleAt: start)!
        live.record(powerEvent, startDate: start, now: now)
        check(live.applyingCurrentZone(to: group(powerConfig), metric: metric(0, unit: .watts), state: .running, now: now).currentZone == 1, "zero watts is valid coasting")
        check(live.applyingCurrentZone(to: group(powerConfig), metric: metric(0, at: now.addingTimeInterval(-6), unit: .watts), state: .running, now: now).currentZone == nil, "power freshness is five seconds")
        live.record(WorkoutNativeZoneEventV1.make(configuration: config, zeroBasedIndex: 0, sampleAt: start)!, startDate: start, now: now)
        check(current(metric(0)) == nil, "zero BPM is unavailable")
        check(current(metric(.nan)) == nil, "nonfinite sample")

        let native = WorkoutNativeZonesV1(heartRate: group(current: 2), cyclingPower: group(powerConfig))
        let value = envelope(native)
        let roundTrip = try WorkoutContractCodec.decode(WorkoutContractCodec.encode(value))
        check(roundTrip == value, "native binary property-list round trip")
        check(rejected(envelope(native, heartRate: nil)), "current native zone requires raw metric")
        check(rejected(envelope(native, heartRate: metric(999))), "wire current zone must match raw sample")
        check(rejected(envelope(WorkoutNativeZonesV1(heartRate: group(durations: [100, 100, 100, 100, 100]), cyclingPower: nil))), "totals cannot exceed workout duration")
        check(rejected(envelope(WorkoutNativeZonesV1(heartRate: group(at: now.addingTimeInterval(1)), cyclingPower: nil))), "future observed time")
        check(rejected(envelope(WorkoutNativeZonesV1(heartRate: group(at: start.addingTimeInterval(-1)), cyclingPower: nil))), "pre-workout observed time")
        check(rejected(envelope(WorkoutNativeZonesV1(heartRate: group(powerConfig), cyclingPower: nil))), "metric slot mismatch")
        check(rejected(envelope(WorkoutNativeZonesV1(heartRate: nil, cyclingPower: nil))), "empty native payload")
        check(rejected(envelope(native, state: .ended, outcome: .saved)), "live totals cannot masquerade as saved totals")
        let final = WorkoutNativeZonesV1(heartRate: group(isFinal: true), cyclingPower: group(powerConfig, isFinal: true))
        check(!rejected(envelope(final, state: .ended, outcome: .saved)), "saved groups accepted")
        check(rejected(envelope(final)), "saved groups cannot enter live state")
        check(rejected(envelope(final, state: .ended, outcome: .discarded)), "discard cannot carry native history")
        let discard = WorkoutDiscardCompletionPolicy.terminalSnapshot(startDate: start, errorCode: nil)
        check(discard.nativeZones == nil, "discard sanitation")

        // Optional addition: old payloads decode without synthetic native zones;
        // old peer projection removes the new key instead of overwriting legacy zones.
        let oldValue = envelope(nil)
        let decodedOld = try WorkoutContractCodec.decode(WorkoutContractCodec.encode(oldValue))
        check(decodedOld.snapshot?.nativeZones == nil, "old snapshot decodes")
        let projected = try WorkoutContractCodec.decode(WorkoutContractCodec.encodeForPhone(value, peerVersion: nil))
        check(projected.snapshot?.nativeZones == nil, "unknown peer compatibility projection")
        let modern = try WorkoutContractCodec.decode(WorkoutContractCodec.encodeForPhone(value, peerVersion: .current))
        check(modern.snapshot?.nativeZones == native, "modern peer preserves native payload")

        let presentation = WorkoutMirrorPresentationV1(
            connectionState: .connected, snapshot: value.snapshot!, sessionID: value.sessionID,
            capturedAt: now, receivedAt: now, confirmedSessionState: .running,
            errorCode: nil, pendingControl: nil, finalSnapshot: nil, navigation: .empty
        )
        let merged = WorkoutIPhoneTelemetryMerge.presentation(presentation, phone: .empty, at: now)
        check(merged.snapshot.nativeZones == native, "phone fallback merge preserves native groups")
        for connection in [WorkoutMirrorConnectionStateV1.stale, .disconnected] {
            let delayed = WorkoutMirrorPresentationV1(
                connectionState: connection, snapshot: value.snapshot!, sessionID: value.sessionID,
                capturedAt: now, receivedAt: now, confirmedSessionState: .running,
                errorCode: nil, pendingControl: nil, finalSnapshot: nil, navigation: .empty
            )
            let result = WorkoutIPhoneTelemetryMerge.presentation(delayed, phone: .empty, at: now)
            check(result.connectionState == connection, "native groups cannot revive disconnected state")
        }
        func deviceFrames(native: WorkoutNativeZonesV1?) -> WorkoutDeviceFrames? {
            let snapshot = WorkoutSnapshotV1(
                state: .running, startDate: start,
                elapsedTime: metric(100, unit: .seconds), currentHeartRate: metric(),
                currentHeartRateZone: 4, heartRateZoneCount: 5, nativeZones: native,
                availability: [.elapsedTime, .currentHeartRate, .heartRateZone]
            )
            return WorkoutDeviceTelemetrySampleMapperV1.directWatchSample(
                snapshot: snapshot, sessionToken: 1, sessionID: value.sessionID
            ).flatMap { WorkoutDeviceFrameBuilder.frames(for: $0) }
        }
        let legacyFrames = deviceFrames(native: nil)
        let nativeFrames = deviceFrames(native: native)
        check(legacyFrames != nil, "legacy frame fixture exists")
        check(legacyFrames?.core == nativeFrames?.core &&
              legacyFrames?.extended == nativeFrames?.extended &&
              legacyFrames?.origin == nativeFrames?.origin &&
              legacyFrames?.originAvailable == nativeFrames?.originAvailable &&
              legacyFrames?.identity == nativeFrames?.identity,
              "native payload does not change any legacy BLE byte or identity")
        check(nativeFrames?.extended[12] == 4, "WEXT still carries legacy zone 4, not native zone 2")

        // Decoder retains safe provenance for a future HealthKit source case.
        let source = try PropertyListEncoder().encode(["source": "newSource"])
        struct SourceContainer: Decodable { let source: WorkoutNativeZoneSourceV1 }
        let decodedSource = try PropertyListDecoder().decode(SourceContainer.self, from: source)
        check(decodedSource.source == .unknown, "unknown source is not relabelled automatic")

        let durationGroup = WorkoutNativeZoneSnapshotV1(
            configuration: configuration(), secondsByZone: [10, 20, 30, 0, 0],
            observedAt: now, currentZone: 2, currentZoneSampleAt: now,
            isFinal: false
        )
        check(durationGroup.currentZoneDuration == 20, "native current time uses the reported zone total")
        check(durationGroup.clearingCurrentZone().currentZoneDuration == nil, "unavailable current zone has no current duration")
        let finalDurationGroup = WorkoutNativeZoneSnapshotV1(
            configuration: configuration(), secondsByZone: [10, 20, 30, 0, 0],
            observedAt: now, currentZone: nil, currentZoneSampleAt: nil, isFinal: true
        )
        check(finalDurationGroup.currentZoneDuration == nil, "a saved summary has no current-zone timer")

        try deviceWireTests()
        print("Native workout zone tests passed (\(checks) checks)")
    }
}
private extension WorkoutNativeZoneTests {
    struct WireFixtures: Decodable { let fixtures: [WireFixture] }
    struct WireFixture: Decodable {
        let metric: Int
        let count: Int
        let boundaries: [Double]
        let seconds: [Double]
        let hex: String
    }

    static func deviceWireTests() throws {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let fixtures = try JSONDecoder().decode(WireFixtures.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))).fixtures
        for fixture in fixtures {
            let kind: WorkoutNativeZoneMetricV1 = fixture.metric == 1 ? .heartRate : .cyclingPower
            let ranges = (0..<fixture.count).map { index in
                WorkoutNativeZoneRangeV1(minimum: index == 0 ? nil : fixture.boundaries[index - 1],
                    maximum: index == fixture.count - 1 ? nil : fixture.boundaries[index])
            }
            let configuration = WorkoutNativeZoneConfigurationV1(metric: kind, source: .user, ranges: ranges)
            let native = group(configuration, current: 2, durations: fixture.seconds)
            let raw = metric(75, at: now.addingTimeInterval(-1.25), unit: kind.unit)
            let snapshot = WorkoutSnapshotV1(state: .running, startDate: start,
                elapsedTime: metric(100, unit: .seconds),
                currentHeartRate: kind == .heartRate ? raw : nil,
                cyclingPower: kind == .cyclingPower ? raw : nil,
                nativeZones: .init(heartRate: kind == .heartRate ? native : nil,
                                  cyclingPower: kind == .cyclingPower ? native : nil),
                availability: [.elapsedTime, kind == .heartRate ? .currentHeartRate : .cyclingPower])
            let context = WorkoutZoneDeviceContextV1(snapshot: snapshot, sessionID: uuid,
                sessionToken: 0x1234, state: .running, isCurrent: true)
            let packets = WorkoutZoneDeviceCodecV1.packets(for: context, sequence: 42, pairGeneration: 1, at: now)
            let packet = packets[fixture.metric - 1]
            check(packet.map { String(format: "%02x", $0) }.joined() == fixture.hex,
                  "independent golden bytes metric \(fixture.metric), \(fixture.count) zones")
            check(WorkoutZoneDeviceCodecV1.hasValidShape(packet), "valid bounded packet shape")
            check(packet.count <= 132, "bounded BLE packet")
            let legacy = WorkoutDeviceFrameBuilder.frames(for:
                WorkoutDeviceTelemetrySampleMapperV1.directWatchSample(snapshot: snapshot,
                    sessionToken: 0x1234, sessionID: uuid)!)!
            let withoutZones = WorkoutDeviceFrameBuilder.transportFrames(for: legacy, generation: 1, includeOrigin: true)
            let withZones = WorkoutDeviceFrameBuilder.transportFrames(for: legacy, generation: 1,
                includeOrigin: true, zoneSequence: 42, at: now)
            check(withoutZones.count == 3 && withZones.count == 5, "capability selects 3 or 5 members")
            check(Array(withZones.prefix(3)) == withoutZones, "legacy prefix is byte-identical")
            check(Array(withZones.suffix(2)) == packets, "both relays reuse the canonical encoder")
            let noOrigin = WorkoutDeviceFrameBuilder.transportFrames(for: legacy, generation: 1,
                includeOrigin: false, zoneSequence: 42, at: now)
            check(noOrigin.count == 2, "never send sidecars without full workout identity")
            for current in [false, true] {
                let expired = WorkoutZoneDeviceCodecV1.packets(for: .init(snapshot: snapshot,
                    sessionID: uuid, sessionToken: 0x1234, state: .running, isCurrent: current),
                    sequence: 43, pairGeneration: 2, at: now.addingTimeInterval(31))[fixture.metric - 1]
                check(expired[6] == 0 && expired[10] == 255 && expired[11] == 255,
                      "old measurements cannot create a fresh highlight")
            }
            let dispatch = RideBLEZoneDispatch(frame: packet, enqueuedUptime: 100)
            let fresh = dispatch.payload(at: 101)
            check(Int(fresh[10]) + Int(fresh[11]) * 256 == 2250, "monotonic dispatch accounts for queued age")
            for uptime in [99.0, Double.nan, Double.infinity, 111.0] {
                let stale = dispatch.payload(at: uptime)
                check(stale[6] == 0 && stale[10] == 255 && stale[11] == 255,
                      "expired or invalid dispatch clears live highlight")
                check(stale.suffix(from: 32) == packet.suffix(from: 32), "expiry preserves immutable configuration and totals")
            }
            check(dispatch.payload(at: 100) == packet, "immutable retry source is not cumulatively aged")
        }

        func packets(_ snapshot: WorkoutSnapshotV1, current: Bool = true, sequence: UInt32 = 1) -> [Data] {
            WorkoutZoneDeviceCodecV1.packets(for: .init(snapshot: snapshot, sessionID: uuid,
                sessionToken: 0x1234, state: WorkoutDeviceSessionState(snapshot.state), isCurrent: current),
                sequence: sequence, pairGeneration: 1, at: now)
        }
        func fallback(state: WorkoutSessionStateV1 = .running, outcome: WorkoutTerminalOutcomeV1? = nil,
                      rate: Double = 150) -> WorkoutSnapshotV1 {
            WorkoutSnapshotV1(state: state, startDate: start, elapsedTime: metric(100, unit: .seconds),
                currentHeartRate: metric(rate), currentHeartRateZone: 3, heartRateZoneCount: 5,
                heartRateZoneDurations: .init(capturedAt: now, secondsByZone: [1, 2, 3, 4, 5], maximumHeartRateBPM: 190),
                availability: [.elapsedTime, .currentHeartRate, .heartRateZone], terminalOutcome: outcome)
        }
        let ios26 = packets(fallback())
        check(ios26[0][3] == 0 && ios26[0][5] == 5 && ios26[0][6] == 3, "iOS 26 explicit Bicino fallback")
        check(ios26[1][5] == 0 && ios26[1].count == 32, "iOS 26 does not invent native power zones")
        let boundaries = stride(from: 32, to: 64, by: 8).map { offset in
            Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(ios26[0][offset + $1]) << ($1 * 8) })
        }
        check(boundaries == [114, 133, 152, 171], "fallback preserves exact established thresholds")
        check(packets(fallback(rate: 0))[0][6] == 0, "zero BPM is unavailable")
        check(packets(fallback(), current: false).allSatisfy { $0[5] == 0 }, "disconnected replacement clears both metrics")
        check(packets(fallback(state: .paused))[0][6] == 0, "pause removes highlight but retains configuration")
        check(packets(fallback(state: .paused))[0][5] == 5, "paused definition retained")
        check(packets(fallback(state: .ending)).allSatisfy { $0[5] == 0 }, "ending cannot publish a final group")
        check(packets(fallback(state: .ended, outcome: .discarded)).allSatisfy { $0[5] == 0 }, "discard clears sidecars")
        check(packets(fallback(state: .ended)).allSatisfy { $0[5] == 0 }, "unconfirmed end cannot invent saved totals")
        check(packets(fallback(state: .ended, outcome: .saved))[0][4] & 1 == 1, "saved fallback is labelled final")
        check(packets(fallback(), sequence: 0).isEmpty, "sequence zero rejected")
        check(WorkoutZoneDeviceCodecV1.packets(for: nil, sequence: 1, at: now).isEmpty, "missing identity cannot send")
        check(!WorkoutZoneDeviceCodecV1.hasValidShape(Data()), "empty packet rejected")
        for index in [0, 1, 2, 3, 4, 5, 6] {
            var corrupt = ios26[0]; corrupt[index] = 255
            check(!WorkoutZoneDeviceCodecV1.hasValidShape(corrupt), "invalid header rejects \(index)")
        }
        for length in [0, 1, 16, 31, 33, ios26[0].count - 1] {
            check(!WorkoutZoneDeviceCodecV1.hasValidShape(Data(ios26[0].prefix(length))), "truncated length \(length)")
        }
    }
}

#endif
