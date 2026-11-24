import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        failures += 1
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message): expected \(expected), got \(actual)")
}

@MainActor
private final class RecordingSpeaker: SpokenDirectionsSpeaking {
    var spoken: [SpokenDirectionsAnnouncementV1] = []
    var stopCount = 0

    func speak(_ announcement: SpokenDirectionsAnnouncementV1) { spoken.append(announcement) }
    func stopSpeaking() { stopCount += 1 }
}

private struct Leg {
    let instruction: String
    let maneuver: ManeuverV1
    let meters: Double
}

private let cityLegs = [
    Leg(instruction: "Turn left onto Main Street", maneuver: .left, meters: 600),
    Leg(instruction: "Turn right onto Oak Avenue", maneuver: .right, meters: 400),
    Leg(instruction: "Arrive at the destination", maneuver: .arrive, meters: 300),
]

private func progress(
    routeID: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
    generation: UInt32 = 1,
    step: Int = 0,
    instruction: String = "Turn left onto Main Street",
    maneuver: ManeuverV1 = .left,
    distance: Double,
    speed: Double = 5,
    offRoute: Bool = false,
    savedRoute: Bool = false
) -> SpokenDirectionsEventV1 {
    .progress(SpokenDirectionsProgressV1(
        routeID: routeID,
        navigationGeneration: generation,
        stepIndex: step,
        instruction: instruction,
        maneuver: maneuver,
        distanceToManeuverMeters: distance,
        speedMetersPerSecond: speed,
        isOffRoute: offRoute,
        announcesOffRoute: savedRoute
    ))
}

private func spokenText(_ action: SpokenDirectionsActionV1?) -> String? {
    if case .speak(let announcement) = action { return announcement.text }
    return nil
}

/// Rides `legs` at a steady speed with one fix per second, advancing a
/// step 20 m before its maneuver like the navigation runtime, and returns
/// everything the planner said. `jitter` adds 12 m to every other fix.
private func ride(
    _ legs: [Leg],
    speed: Double,
    jitter: Bool = false,
    planner: inout SpokenDirectionsPlannerV1
) -> [SpokenDirectionsAnnouncementV1] {
    var said: [SpokenDirectionsAnnouncementV1] = []
    func record(_ action: SpokenDirectionsActionV1?) {
        if case .speak(let announcement) = action { said.append(announcement) }
    }
    let ends = legs.indices.map { index in legs[...index].reduce(0) { $0 + $1.meters } }
    let routeID = UUID()
    record(planner.handle(.started))
    var step = 0
    var tick = 0
    while true {
        let along = Double(tick) * speed
        while step < legs.count - 1, along >= ends[step] - 20 { step += 1 }
        let distance = max(ends[step] - along, 0)
        if step == legs.count - 1, distance < 20 {
            record(planner.handle(.arrived(instruction: legs[step].instruction)))
            record(planner.handle(.stopped))
            return said
        }
        let reported = jitter && tick % 2 == 1 ? distance + 12 : distance
        record(planner.handle(progress(
            routeID: routeID, step: step, instruction: legs[step].instruction,
            maneuver: legs[step].maneuver, distance: reported, speed: speed
        )))
        tick += 1
    }
}

@main
struct SpokenDirectionsTests {
    @MainActor
    static func main() {
        testOffByDefault()
        testSettingsScreenUsesTheSameDefault()
        testFooterMatchesBackgroundAudio()
        testTiming()
        testRideAnnouncesEachStepOnce()
        testJitterAndRepeatedFixesNeverRepeat()
        testFastRideSkipsTheEarlyAlertWhenTooClose()
        testRerouteAndRejoin()
        testOffRoute()
        testStopSilencesUnlessArrived()
        testControllerFollowsTheSetting()
        testQueuePolicy()
        testPhrasing()
        guard failures == 0 else {
            fputs("\(failures) spoken directions check(s) failed\n", stderr)
            exit(1)
        }
        print("Spoken directions tests passed")
    }

    @MainActor
    static func testOffByDefault() {
        let suite = "SpokenDirectionsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        expectEqual(
            SpokenDirectionsPreference.enabledDefaultsKey,
            "navigation.spokenDirections.enabled.v1",
            "the stored key never changes once shipped"
        )
        expectEqual(SpokenDirectionsPreference.defaultEnabled, false, "spoken directions ship off")
        expect(!SpokenDirectionsPreference.isEnabled(in: defaults), "a missing key reads as off")
        defaults.set(true, forKey: SpokenDirectionsPreference.enabledDefaultsKey)
        expect(SpokenDirectionsPreference.isEnabled(in: defaults), "the toggle turns them on")
        defaults.set(false, forKey: SpokenDirectionsPreference.enabledDefaultsKey)
        expect(!SpokenDirectionsPreference.isEnabled(in: defaults), "and off again")

        // A whole ride with the setting untouched says nothing.
        defaults.removeObject(forKey: SpokenDirectionsPreference.enabledDefaultsKey)
        let speaker = RecordingSpeaker()
        let controller = SpokenDirectionsController(
            speaker: speaker,
            usesMetricSystem: true,
            isEnabled: { SpokenDirectionsPreference.isEnabled(in: defaults) },
            observesPreferenceChanges: false
        )
        controller.handle(.started)
        for distance in stride(from: 600.0, through: 0, by: -5) {
            controller.handle(progress(distance: distance))
        }
        controller.handle(.rerouted)
        controller.handle(progress(routeID: UUID(), distance: 100))
        controller.handle(.arrived(instruction: "Arrive at the destination"))
        controller.handle(.stopped)
        expect(speaker.spoken.isEmpty, "nothing is spoken while off: \(speaker.spoken.map(\.text))")
        expectEqual(speaker.stopCount, 0, "and the audio session is never touched")
    }

    /// A build without background audio must not promise prompts with the
    /// screen locked.
    static func testFooterMatchesBackgroundAudio() {
        typealias Preference = SpokenDirectionsPreference
        expect(Preference.speaksInBackground(infoDictionary: [
            "UIBackgroundModes": ["audio", "location", "bluetooth-central"],
        ]), "background audio, as Debug and Release declare it")
        expect(!Preference.speaksInBackground(infoDictionary: [
            "UIBackgroundModes": ["location", "bluetooth-central"],
        ]), "a build with location and Bluetooth only")
        expect(!Preference.speaksInBackground(infoDictionary: nil), "no plist")
        expect(Preference.settingsFooter(speaksInBackground: false).contains("with Bicino open on screen"),
               "foreground-only builds say so")
        expect(!Preference.settingsFooter(speaksInBackground: true).contains("open on screen"),
               "background-capable builds do not")
        guard let section = try? String(
            contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/SpokenDirectionsSettingsSection.swift",
            encoding: .utf8
        ) else { return }
        expect(section.filter { !$0.isWhitespace }.contains(
            "speaksInBackground:SpokenDirectionsPreference.speaksInBackground()"
        ), "the footer reads this build's own background modes")
    }

    /// The settings view is app-only, so check its source: the toggle must
    /// read the same key and default as the controller.
    static func testSettingsScreenUsesTheSameDefault() {
        let views = "ios-app/BikeComputer/BikeComputer/Views"
        guard let section = try? String(
            contentsOfFile: "\(views)/SpokenDirectionsSettingsSection.swift", encoding: .utf8
        ) else {
            expect(false, "settings section source is readable from the repository root")
            return
        }
        let compact = section.filter { !$0.isWhitespace }
        expect(
            compact.contains(
                "@AppStorage(SpokenDirectionsPreference.enabledDefaultsKey)"
                + "privatevarisEnabled=SpokenDirectionsPreference.defaultEnabled"
            ),
            "the toggle uses the shared key and its off default"
        )
        let shown = (try? FileManager.default.contentsOfDirectory(atPath: views))?
            .filter { $0 != "SpokenDirectionsSettingsSection.swift" && $0.hasSuffix(".swift") }
            .contains { name in
                (try? String(contentsOfFile: "\(views)/\(name)", encoding: .utf8))?
                    .contains("SpokenDirectionsSettingsSection()") == true
            } ?? false
        expect(shown, "a settings screen shows the Spoken Directions toggle")
    }

    static func testTiming() {
        typealias Planner = SpokenDirectionsPlannerV1
        expectEqual(Planner.earlyAlertDistance(speedMetersPerSecond: -1), 150, "unknown speed: early")
        expectEqual(Planner.nowPromptDistance(speedMetersPerSecond: -1), 30, "unknown speed: now")
        expectEqual(Planner.earlyAlertDistance(speedMetersPerSecond: .nan), 150, "invalid speed: early")
        expectEqual(Planner.earlyAlertDistance(speedMetersPerSecond: 0.2), 150, "standing still uses the assumed speed")
        expectEqual(Planner.earlyAlertDistance(speedMetersPerSecond: 10), 300, "36 km/h: 30 s ahead")
        expectEqual(Planner.nowPromptDistance(speedMetersPerSecond: 10), 60, "36 km/h: 6 s ahead")
        expectEqual(Planner.earlyAlertDistance(speedMetersPerSecond: 25), 450, "fast descents are capped")
        expectEqual(Planner.nowPromptDistance(speedMetersPerSecond: 25), 80, "fast descents are capped")
        var previousEarly = 0.0
        for speed in stride(from: 0.0, through: 20, by: 0.5) {
            let early = Planner.earlyAlertDistance(speedMetersPerSecond: speed)
            let now = Planner.nowPromptDistance(speedMetersPerSecond: speed)
            expect(now > 20, "the now prompt fires before the runtime's 20 m step advance at \(speed) m/s")
            expect(early >= now * 2, "the early alert comes well before the now prompt at \(speed) m/s")
            if speed >= 3 { expect(early >= previousEarly, "faster riders are warned earlier at \(speed) m/s") }
            previousEarly = early
        }
    }

    static func testRideAnnouncesEachStepOnce() {
        var planner = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        let said = ride(cityLegs, speed: 5, planner: &planner)
        expectEqual(said.map(\.text), [
            "In 600 meters, turn left onto Main Street.",
            "In 150 meters, turn left onto Main Street.",
            "Turn left onto Main Street.",
            "In 150 meters, turn right onto Oak Avenue.",
            "Turn right onto Oak Avenue.",
            "Your destination is in 150 meters.",
            "You have arrived.",
        ], "a ride hears a preview, then an early alert and a now prompt per turn, then arrival")
        expectEqual(
            said.map(\.kind),
            [.preview, .early, .now, .early, .now, .early, .arrival],
            "announcement kinds"
        )

        var faster = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        let fast = ride(cityLegs, speed: 10, planner: &faster)
        expectEqual(fast.map(\.kind), [.preview, .early, .now, .early, .now, .early, .arrival],
                    "at 36 km/h the same announcements come earlier")
        expectEqual(fast[1].text, "In 300 meters, turn left onto Main Street.", "early alert at 30 s")
    }

    static func testJitterAndRepeatedFixesNeverRepeat() {
        var planner = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        let said = ride(cityLegs, speed: 5, jitter: true, planner: &planner)
        expectEqual(said.map(\.kind), [.preview, .early, .now, .early, .now, .early, .arrival],
                    "GPS jitter across a threshold never repeats an announcement")

        var single = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = single.handle(.started)
        var spoken: [String] = []
        for distance in [400.0, 400, 200, 150, 150, 160, 149, 151, 100, 30, 45, 29, 29, 25, 140, 300, 21] {
            if let text = spokenText(single.handle(progress(distance: distance))) { spoken.append(text) }
        }
        expectEqual(spoken, [
            "In 400 meters, turn left onto Main Street.",
            "In 150 meters, turn left onto Main Street.",
            "Turn left onto Main Street.",
        ], "each phase is said once and never after a later phase")
        expectEqual(single.spokenPhases.count, 1, "one step announced")
    }

    static func testFastRideSkipsTheEarlyAlertWhenTooClose() {
        var planner = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = planner.handle(.started)
        // A navigation that starts 40 m before a turn says only the turn.
        let first = planner.handle(progress(distance: 25))
        expectEqual(spokenText(first), "Turn left onto Main Street.", "close start goes straight to now")
        expect(planner.handle(progress(distance: 140)) == nil, "no early alert after the now prompt")
        // A short next step: its now prompt follows without an early alert.
        let next = planner.handle(progress(step: 1, instruction: "Turn right onto Oak Avenue",
                                           maneuver: .right, distance: 28))
        expectEqual(spokenText(next), "Turn right onto Oak Avenue.", "short step")
    }

    static func testRerouteAndRejoin() {
        let saved = UUID()
        var planner = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = planner.handle(.started)
        expectEqual(spokenText(planner.handle(progress(routeID: saved, distance: 500))),
                    "In 500 meters, turn left onto Main Street.", "start preview")

        expect(planner.handle(.rerouted) == nil, "a reroute waits for the new route's first fix")
        let detour = UUID()
        let rerouted = planner.handle(progress(routeID: detour, instruction: "Turn right onto Pine Road",
                                               maneuver: .right, distance: 800))
        expectEqual(spokenText(rerouted), "Rerouting. In 800 meters, turn right onto Pine Road.",
                    "the reroute names the new route's next maneuver")
        if case .speak(let announcement) = rerouted {
            expectEqual(announcement.kind, .reroute, "reroute kind")
            expect(announcement.isUrgent, "a reroute interrupts an older prompt")
        }
        expectEqual(spokenText(planner.handle(progress(routeID: detour, instruction: "Turn right onto Pine Road",
                                                       maneuver: .right, distance: 140))),
                    "In 150 meters, turn right onto Pine Road.", "the new route continues normally (rounded to 50 m)")

        _ = planner.handle(.rejoinedRoute)
        expectEqual(spokenText(planner.handle(progress(routeID: saved, distance: 140))),
                    "Back on route. In 150 meters, turn left onto Main Street.",
                    "back on the saved route, the not-yet-said early alert follows")
        _ = planner.handle(.rejoinedRoute)
        expectEqual(spokenText(planner.handle(progress(routeID: saved, distance: 120))),
                    "Back on route.", "an early alert already said for this step is not repeated")
        expectEqual(spokenText(planner.handle(progress(routeID: saved, distance: 28))),
                    "Turn left onto Main Street.", "the now prompt still comes")

        // A new generation of the same route (a restart) is a new set of steps.
        _ = planner.handle(.started)
        expectEqual(spokenText(planner.handle(progress(routeID: saved, generation: 2, distance: 120))),
                    "In 100 meters, turn left onto Main Street.", "a restarted route is announced again")
    }

    static func testOffRoute() {
        var online = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = online.handle(.started)
        _ = online.handle(progress(distance: 500))
        for distance in [120.0, 110, 25] {
            expect(online.handle(progress(distance: distance, offRoute: true)) == nil,
                   "online routes stay quiet off route; the reroute speaks")
        }

        var saved = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = saved.handle(.started)
        _ = saved.handle(progress(distance: 500, savedRoute: true))
        expectEqual(spokenText(saved.handle(progress(distance: 400, offRoute: true, savedRoute: true))),
                    "Off route. Return to the saved route.", "saved routes say so once")
        expect(saved.handle(progress(distance: 390, offRoute: true, savedRoute: true)) == nil,
               "the notice is not repeated on every fix")
        expect(saved.handle(progress(distance: 120, offRoute: true, savedRoute: true)) == nil,
               "no turn prompts while off route")
        expectEqual(spokenText(saved.handle(progress(distance: 120, savedRoute: true))),
                    "In 100 meters, turn left onto Main Street.", "back on route, prompts resume")
        expectEqual(spokenText(saved.handle(progress(distance: 110, offRoute: true, savedRoute: true))),
                    "Off route. Return to the saved route.", "leaving again is a new notice")
    }

    static func testStopSilencesUnlessArrived() {
        var planner = SpokenDirectionsPlannerV1(usesMetricSystem: true)
        _ = planner.handle(.started)
        _ = planner.handle(progress(distance: 500))
        expectEqual(planner.handle(.stopped), .silence, "ending navigation early stops speech")

        _ = planner.handle(.started)
        expectEqual(spokenText(planner.handle(.arrived(instruction: "The destination is on your left"))),
                    "You have arrived. The destination is on your left.", "arrival keeps the side")
        expect(planner.handle(.arrived(instruction: nil)) == nil, "arrival is said once")
        expect(planner.handle(progress(distance: 10)) == nil, "nothing after arrival")
        expect(planner.handle(.stopped) == nil, "the arrival message is allowed to finish")

        expectEqual(SpokenDirectionsPlannerV1.arrivalText(instruction: "You have arrived at your destination."),
                    "You have arrived.", "Valhalla's arrival text is not doubled")
        expectEqual(SpokenDirectionsPlannerV1.arrivalText(instruction: "Your destination is on the right."),
                    "You have arrived. Your destination is on the right.", "Valhalla side")
        expectEqual(SpokenDirectionsPlannerV1.arrivalText(instruction: nil), "You have arrived.", "no text")
    }

    @MainActor
    static func testControllerFollowsTheSetting() {
        var enabled = false
        let speaker = RecordingSpeaker()
        let controller = SpokenDirectionsController(
            speaker: speaker, usesMetricSystem: true,
            isEnabled: { enabled }, observesPreferenceChanges: false
        )
        controller.handle(.started)
        controller.handle(progress(distance: 500))
        expect(speaker.spoken.isEmpty, "off: silent")

        enabled = true
        controller.handle(progress(distance: 450))
        expectEqual(speaker.spoken.map(\.text), ["In 450 meters, turn left onto Main Street."],
                    "turning it on mid-ride announces the next maneuver")
        controller.handle(progress(distance: 140))
        expectEqual(speaker.spoken.count, 2, "then the early alert")

        enabled = false
        controller.preferenceChanged()
        expectEqual(speaker.stopCount, 1, "turning it off stops speech at once")
        controller.handle(progress(distance: 25))
        expectEqual(speaker.spoken.count, 2, "and nothing more is said")
        controller.preferenceChanged()
        expectEqual(speaker.stopCount, 1, "an unrelated defaults change does not stop again")

        enabled = true
        controller.handle(.stopped)
        expectEqual(speaker.stopCount, 2, "ending navigation silences the speaker")
    }

    static func testQueuePolicy() {
        func announcement(_ kind: SpokenDirectionsAnnouncementV1.Kind) -> SpokenDirectionsAnnouncementV1 {
            SpokenDirectionsAnnouncementV1(text: "x", kind: kind)
        }
        typealias Policy = SpokenDirectionsQueuePolicyV1
        expect(!Policy.shouldInterrupt(speaking: nil, with: announcement(.now)), "nothing to interrupt")
        expect(Policy.shouldInterrupt(speaking: .early, with: announcement(.now)), "now cuts an early alert")
        expect(Policy.shouldInterrupt(speaking: .preview, with: announcement(.reroute)), "reroute cuts a preview")
        expect(Policy.shouldInterrupt(speaking: .offRoute, with: announcement(.arrival)), "arrival cuts off-route")
        expect(!Policy.shouldInterrupt(speaking: .now, with: announcement(.now)),
               "two close turns are both heard in full")
        expect(!Policy.shouldInterrupt(speaking: .now, with: announcement(.early)), "an early alert waits")
        expect(!Policy.shouldInterrupt(speaking: .early, with: announcement(.early)), "early alerts queue")
    }

    static func testPhrasing() {
        typealias Phrase = SpokenDirectionsDistancePhrase
        expectEqual(Phrase.text(meters: 4, usesMetricSystem: true), "10 meters", "minimum")
        expectEqual(Phrase.text(meters: 44, usesMetricSystem: true), "40 meters", "tens below 100 m")
        expectEqual(Phrase.text(meters: 174, usesMetricSystem: true), "150 meters", "fifties below 1 km")
        expectEqual(Phrase.text(meters: 980, usesMetricSystem: true), "1 kilometer", "rounds up to 1 km")
        expectEqual(Phrase.text(meters: 1_234, usesMetricSystem: true), "1.2 kilometers", "one decimal")
        expectEqual(Phrase.text(meters: 12_600, usesMetricSystem: true), "13 kilometers", "whole above 10")
        expectEqual(Phrase.text(meters: 30, usesMetricSystem: false), "100 feet", "feet")
        expectEqual(Phrase.text(meters: 150, usesMetricSystem: false), "500 feet", "feet in fifties")
        expectEqual(Phrase.text(meters: 400, usesMetricSystem: false), "0.2 miles", "miles from 1,000 ft")
        expectEqual(Phrase.text(meters: 1_609.344, usesMetricSystem: false), "1 mile", "singular")

        var imperial = SpokenDirectionsPlannerV1(usesMetricSystem: false)
        _ = imperial.handle(.started)
        expectEqual(spokenText(imperial.handle(progress(distance: 140))),
                    "In 450 feet, turn left onto Main Street.", "imperial early alert")

        typealias Planner = SpokenDirectionsPlannerV1
        expectEqual(Planner.continuation("Turn left onto Main Street."), "turn left onto Main Street.",
                    "follows the distance")
        expectEqual(Planner.continuation("Bike east on Foo Street."), "bike east on Foo Street.", "Valhalla")
        expectEqual(Planner.continuation("US-101 North."), "US-101 North.", "road numbers keep their case")
        expectEqual(Planner.sentence("  Keep right  "), "Keep right.", "trimmed with a full stop")
        expectEqual(Planner.sentence(""), "Continue.", "empty provider text")
        expectEqual(Planner.sentence("Turn left!"), "Turn left!", "existing punctuation kept")
    }
}
