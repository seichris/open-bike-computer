import Foundation

/// Spoken turn-by-turn directions on iPhone. Riders turn them on in
/// settings; until then the key is absent and nothing is spoken.
nonisolated enum SpokenDirectionsPreference {
    static let enabledDefaultsKey = "navigation.spokenDirections.enabled.v1"
    static let defaultEnabled = false

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? defaultEnabled
    }
}

/// What the navigation engine reports for spoken directions.
nonisolated enum SpokenDirectionsEventV1: Equatable {
    /// A navigation session began; earlier announcements no longer apply.
    case started
    /// Guidance toward the next maneuver after one location fix.
    case progress(SpokenDirectionsProgressV1)
    /// Another route replaced the one being followed: a reroute or a detour.
    case rerouted
    /// A detour ended back on the saved route.
    case rejoinedRoute
    /// The rider reached the destination. `instruction` is the provider's
    /// arrival text, which may say on which side the destination is.
    case arrived(instruction: String?)
    /// Navigation ended.
    case stopped
}

/// One fix's guidance. The instruction is the provider's full text (Apple
/// Maps or Valhalla), not the shortened text shown on the bike computer.
nonisolated struct SpokenDirectionsProgressV1: Equatable {
    let routeID: UUID
    let navigationGeneration: UInt32
    let stepIndex: Int
    let instruction: String
    let maneuver: ManeuverV1
    let distanceToManeuverMeters: Double
    /// Core Location speed; negative when unknown.
    let speedMetersPerSecond: Double
    let isOffRoute: Bool
    /// Saved routes show "Off route" instead of rerouting; say so once.
    let announcesOffRoute: Bool
}

nonisolated struct SpokenDirectionsAnnouncementV1: Equatable {
    enum Kind: Equatable {
        /// The next maneuver, said once when a route starts.
        case preview
        /// The early alert, with the distance to the maneuver.
        case early
        /// The short prompt just before the maneuver.
        case now
        case reroute
        case rejoin
        case offRoute
        case arrival
    }

    let text: String
    let kind: Kind

    /// Urgent announcements cut off a less urgent one being spoken.
    var isUrgent: Bool {
        switch kind {
        case .now, .reroute, .rejoin, .arrival:
            true
        case .preview, .early, .offRoute:
            false
        }
    }
}

nonisolated enum SpokenDirectionsActionV1: Equatable {
    case speak(SpokenDirectionsAnnouncementV1)
    /// Stop speaking now: navigation ended before arrival.
    case silence
}

/// An urgent announcement interrupts a non-urgent one; everything else
/// waits its turn, so two close maneuvers are both heard in full.
nonisolated enum SpokenDirectionsQueuePolicyV1 {
    static func shouldInterrupt(
        speaking current: SpokenDirectionsAnnouncementV1.Kind?,
        with incoming: SpokenDirectionsAnnouncementV1
    ) -> Bool {
        guard let current else { return false }
        return incoming.isUrgent &&
            !SpokenDirectionsAnnouncementV1(text: "", kind: current).isUrgent
    }
}

/// Decides what to say for each navigation event. Each step gets at most
/// one preview, one early alert and one "now" prompt, in that order; a
/// phase is never said again once it, or a later phase, was reached.
nonisolated struct SpokenDirectionsPlannerV1 {
    enum Phase: Int, Comparable {
        case preview
        case early
        case now

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct StepKey: Hashable {
        let routeID: UUID
        let navigationGeneration: UInt32
        let stepIndex: Int
    }

    /// Used while Core Location has no speed: about 18 km/h.
    static let assumedSpeedMetersPerSecond = 5.0
    /// Early alert about 30 s ahead, between 150 m and 450 m.
    static let earlyAlertLeadSeconds = 30.0
    static let earlyAlertDistanceRange = 150.0...450.0
    /// "Now" prompt about 6 s ahead, between 30 m and 80 m. The navigation
    /// runtime moves to the next step 20 m before a maneuver, so the
    /// prompt always fires first.
    static let nowPromptLeadSeconds = 6.0
    static let nowPromptDistanceRange = 30.0...80.0

    let usesMetricSystem: Bool
    private(set) var spokenPhases: [StepKey: Phase] = [:]
    private var needsPreview = true
    private var pendingPrefix: (text: String, kind: SpokenDirectionsAnnouncementV1.Kind)?
    private var offRouteAnnounced = false
    private var hasArrived = false

    init(usesMetricSystem: Bool) {
        self.usesMetricSystem = usesMetricSystem
    }

    static func effectiveSpeed(_ speedMetersPerSecond: Double) -> Double {
        guard speedMetersPerSecond.isFinite, speedMetersPerSecond >= 0.5 else {
            return assumedSpeedMetersPerSecond
        }
        return min(max(speedMetersPerSecond, 3), 15)
    }

    static func earlyAlertDistance(speedMetersPerSecond: Double) -> Double {
        let distance = effectiveSpeed(speedMetersPerSecond) * earlyAlertLeadSeconds
        return min(max(distance, earlyAlertDistanceRange.lowerBound), earlyAlertDistanceRange.upperBound)
    }

    static func nowPromptDistance(speedMetersPerSecond: Double) -> Double {
        let distance = effectiveSpeed(speedMetersPerSecond) * nowPromptLeadSeconds
        return min(max(distance, nowPromptDistanceRange.lowerBound), nowPromptDistanceRange.upperBound)
    }

    mutating func reset() {
        spokenPhases = [:]
        needsPreview = true
        pendingPrefix = nil
        offRouteAnnounced = false
        hasArrived = false
    }

    mutating func handle(_ event: SpokenDirectionsEventV1) -> SpokenDirectionsActionV1? {
        switch event {
        case .started:
            reset()
            return nil
        case .rerouted:
            guard !hasArrived else { return nil }
            pendingPrefix = ("Rerouting.", .reroute)
            needsPreview = true
            offRouteAnnounced = false
            return nil
        case .rejoinedRoute:
            guard !hasArrived else { return nil }
            pendingPrefix = ("Back on route.", .rejoin)
            needsPreview = true
            offRouteAnnounced = false
            return nil
        case .progress(let progress):
            return handle(progress)
        case .arrived(let instruction):
            guard !hasArrived else { return nil }
            hasArrived = true
            pendingPrefix = nil
            return .speak(SpokenDirectionsAnnouncementV1(
                text: Self.arrivalText(instruction: instruction),
                kind: .arrival
            ))
        case .stopped:
            // Arrival stops navigation right after it is announced; let it
            // finish. A rider ending navigation early wants silence.
            let arrived = hasArrived
            reset()
            return arrived ? nil : .silence
        }
    }

    private mutating func handle(_ progress: SpokenDirectionsProgressV1) -> SpokenDirectionsActionV1? {
        guard !hasArrived,
              progress.distanceToManeuverMeters.isFinite,
              progress.distanceToManeuverMeters >= 0 else { return nil }
        if progress.isOffRoute {
            // Online routes reroute instead; saved routes ask to go back.
            guard progress.announcesOffRoute, !offRouteAnnounced else { return nil }
            offRouteAnnounced = true
            return .speak(SpokenDirectionsAnnouncementV1(
                text: "Off route. Return to the saved route.",
                kind: .offRoute
            ))
        }
        offRouteAnnounced = false

        let key = StepKey(
            routeID: progress.routeID,
            navigationGeneration: progress.navigationGeneration,
            stepIndex: progress.stepIndex
        )
        let distance = progress.distanceToManeuverMeters
        let phase: Phase?
        if distance <= Self.nowPromptDistance(speedMetersPerSecond: progress.speedMetersPerSecond) {
            phase = .now
        } else if distance <= Self.earlyAlertDistance(speedMetersPerSecond: progress.speedMetersPerSecond) {
            phase = .early
        } else {
            phase = needsPreview ? .preview : nil
        }
        needsPreview = false
        let prefix = pendingPrefix
        pendingPrefix = nil

        var body: String?
        var kind: SpokenDirectionsAnnouncementV1.Kind?
        if let phase, spokenPhases[key].map({ $0 < phase }) ?? true {
            spokenPhases[key] = phase
            body = text(for: phase, progress: progress)
            kind = Self.kind(for: phase)
        }
        if let prefix {
            // Back on a route whose next maneuver was already announced:
            // say only that guidance resumed, never the same step again.
            let text = [prefix.text, body].compactMap { $0 }.joined(separator: " ")
            return .speak(SpokenDirectionsAnnouncementV1(text: text, kind: prefix.kind))
        }
        guard let body, let kind else { return nil }
        return .speak(SpokenDirectionsAnnouncementV1(text: body, kind: kind))
    }

    private static func kind(for phase: Phase) -> SpokenDirectionsAnnouncementV1.Kind {
        switch phase {
        case .preview: .preview
        case .early: .early
        case .now: .now
        }
    }

    /// nil when the phase says nothing: arrival is announced on `.arrived`.
    private func text(for phase: Phase, progress: SpokenDirectionsProgressV1) -> String? {
        let instruction = Self.sentence(progress.instruction)
        let distance = SpokenDirectionsDistancePhrase.text(
            meters: progress.distanceToManeuverMeters,
            usesMetricSystem: usesMetricSystem
        )
        if progress.maneuver == .arrive {
            return phase == .now ? nil : "Your destination is in \(distance)."
        }
        switch phase {
        case .preview, .early:
            return "In \(distance), \(Self.continuation(instruction))"
        case .now:
            return instruction
        }
    }

    static func arrivalText(instruction: String?) -> String {
        guard let instruction else { return "You have arrived." }
        let lowercased = instruction.lowercased()
        let namesSide = lowercased.contains("left") || lowercased.contains("right")
        return namesSide ? "You have arrived. \(sentence(instruction))" : "You have arrived."
    }

    /// Trimmed, non-empty and ending with punctuation.
    static func sentence(_ instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Continue." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// "Turn left onto Main Street." → "turn left onto Main Street." so it
    /// can follow "In 200 meters,". Words like "US-101" keep their case.
    static func continuation(_ sentence: String) -> String {
        guard let first = sentence.first, first.isUppercase else { return sentence }
        let firstWord = sentence.prefix { !$0.isWhitespace }
        guard firstWord.dropFirst().allSatisfy({ !$0.isUppercase && !$0.isNumber }) else {
            return sentence
        }
        return first.lowercased() + sentence.dropFirst()
    }
}

/// Rounded distances read aloud: metres/kilometres or feet/miles.
nonisolated enum SpokenDirectionsDistancePhrase {
    static func text(meters: Double, usesMetricSystem: Bool) -> String {
        let meters = max(meters, 0)
        return usesMetricSystem ? metric(meters) : imperial(meters)
    }

    private static func metric(_ meters: Double) -> String {
        let step = meters < 100 ? 10.0 : 50.0
        let rounded = max((meters / step).rounded() * step, 10)
        if rounded < 1_000 {
            return "\(Int(rounded)) meters"
        }
        return count(meters / 1_000, unit: "kilometer")
    }

    private static func imperial(_ meters: Double) -> String {
        let feet = meters / 0.3048
        let rounded = max((feet / 50).rounded() * 50, 50)
        if rounded < 1_000 {
            return "\(Int(rounded)) feet"
        }
        return count(meters / 1_609.344, unit: "mile")
    }

    /// One decimal below 10 ("1.5 kilometers", "0.2 miles"), whole above.
    private static func count(_ value: Double, unit: String) -> String {
        let rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        let number = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(number) \(unit)\(rounded == 1 ? "" : "s")"
    }
}
