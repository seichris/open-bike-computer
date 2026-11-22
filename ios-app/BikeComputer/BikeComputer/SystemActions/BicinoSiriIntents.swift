import AppIntents
import Foundation

/// Bridges Siri and Shortcuts actions to the app's Bluetooth link, route and
/// workout recording. The intents run in the app process, where the bike
/// computer connection and the ride live, and never open the app.
@available(iOS 17.0, *)
final class BicinoSiriActions: @unchecked Sendable {
    static let unavailable = BicinoSiriActions(
        activateScreen: { _ in .notConnected },
        findPlaces: { _ in .unavailable },
        runWorkoutCommand: { _, _ in .unavailable }
    )

    private let activateScreenHandler:
        @MainActor @Sendable (DeviceScreenActivationRequest) async -> DeviceScreenActivationOutcome
    private let findPlacesHandler:
        @MainActor @Sendable (RoutePlaceKind) async -> RoutePlaceSearchOutcome
    private let runWorkoutCommandHandler:
        @MainActor @Sendable (BicinoWorkoutCommand, UUID?) async -> BicinoWorkoutCommandOutcome

    init(
        activateScreen: @escaping @MainActor @Sendable (
            DeviceScreenActivationRequest
        ) async -> DeviceScreenActivationOutcome,
        findPlaces: @escaping @MainActor @Sendable (
            RoutePlaceKind
        ) async -> RoutePlaceSearchOutcome,
        runWorkoutCommand: @escaping @MainActor @Sendable (
            BicinoWorkoutCommand,
            UUID?
        ) async -> BicinoWorkoutCommandOutcome
    ) {
        activateScreenHandler = activateScreen
        findPlacesHandler = findPlaces
        runWorkoutCommandHandler = runWorkoutCommand
    }

    func activateScreen(_ request: DeviceScreenActivationRequest) async -> DeviceScreenActivationOutcome {
        await activateScreenHandler(request)
    }

    func findPlaces(_ kind: RoutePlaceKind) async -> RoutePlaceSearchOutcome {
        await findPlacesHandler(kind)
    }

    /// `confirmedSession` is the session the rider said yes to, for a
    /// command that asks first.
    func runWorkoutCommand(
        _ command: BicinoWorkoutCommand,
        confirmedSession: UUID? = nil
    ) async -> BicinoWorkoutCommandOutcome {
        await runWorkoutCommandHandler(command, confirmedSession)
    }

    func workoutReply(_ command: BicinoWorkoutCommand) async -> String {
        BicinoWorkoutReplyText.text(for: await runWorkoutCommand(command))
    }
}

@available(iOS 17.0, *)
nonisolated enum BicinoScreenChoice: String, AppEnum {
    case map, workout, navigation, elevation, battery

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bicino Screen"
    static let caseDisplayRepresentations: [BicinoScreenChoice: DisplayRepresentation] = [
        .map: DisplayRepresentation(title: "Map", synonyms: ["Maps", "Map view"]),
        .workout: DisplayRepresentation(title: "Workout", synonyms: ["Ride Stats", "Stats", "Ride"]),
        .navigation: DisplayRepresentation(title: "Navigation", synonyms: ["Directions", "Turn-by-turn"]),
        .elevation: DisplayRepresentation(title: "Elevation", synonyms: ["Climb", "Elevation profile"]),
        .battery: DisplayRepresentation(title: "Battery", synonyms: ["Battery status"]),
    ]

    /// In preference order. Map + Navigation also serves a request for a map
    /// or for guidance when the rider has only the combined screen.
    var screenTypes: [RideBLEScreenTypeV1] {
        switch self {
        case .map: return [.map, .mapPlusNavigation]
        case .workout: return [.rideStats]
        case .navigation: return [.navigation, .mapPlusNavigation]
        case .elevation: return [.elevation]
        case .battery: return [.batteryStatus]
        }
    }

    var spokenName: String {
        switch self {
        case .map: return "Map"
        case .workout: return "Workout"
        case .navigation: return "Navigation"
        case .elevation: return "Elevation"
        case .battery: return "Battery"
        }
    }
}

@available(iOS 17.0, *)
nonisolated extension RoutePlaceKind: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static let caseDisplayRepresentations: [RoutePlaceKind: DisplayRepresentation] = [
        .coffeeShop: DisplayRepresentation(title: "Coffee Shop", synonyms: ["Café", "Cafe", "Coffee"]),
        .restaurant: DisplayRepresentation(title: "Restaurant", synonyms: ["Place to eat"]),
        .bakery: DisplayRepresentation(title: "Bakery", synonyms: []),
        .supermarket: DisplayRepresentation(title: "Supermarket", synonyms: ["Grocery store", "Food market"]),
        .convenienceStore: DisplayRepresentation(title: "Convenience Store", synonyms: ["Corner shop"]),
        .bikeShop: DisplayRepresentation(title: "Bike Shop", synonyms: ["Bicycle shop", "Bike repair", "Bicycle repair"]),
        .toilet: DisplayRepresentation(title: "Toilet", synonyms: ["Restroom", "Bathroom", "Public toilet"]),
        .pharmacy: DisplayRepresentation(title: "Pharmacy", synonyms: ["Drugstore", "Chemist"]),
        .gasStation: DisplayRepresentation(title: "Gas Station", synonyms: ["Petrol station", "Service station"]),
        .hospital: DisplayRepresentation(title: "Hospital", synonyms: ["Emergency room"]),
    ]
}

@available(iOS 17.0, *)
struct OpenBicinoScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Bicino Screen"
    static let description = IntentDescription(
        "Shows a screen on the connected Bicino bike computer."
    )
    static let openAppWhenRun = false
    // Riders ask with the iPhone locked in a pocket or on the handlebar.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Screen")
    var screen: BicinoScreenChoice

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$screen) on Bicino")
    }

    init() {}

    init(screen: BicinoScreenChoice) {
        self.screen = screen
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await actions.activateScreen(.show(screen.screenTypes))
        let text = DeviceScreenActivationReplyText.text(for: outcome, requested: screen.spokenName)
        return .result(dialog: "\(text)")
    }
}

@available(iOS 17.0, *)
struct NextBicinoScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Bicino Screen"
    static let description = IntentDescription(
        "Shows the next screen on the connected Bicino, like its BOOT button."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await actions.activateScreen(.next)
        return .result(dialog: "\(DeviceScreenActivationReplyText.text(for: outcome, requested: nil))")
    }
}

@available(iOS 17.0, *)
struct PreviousBicinoScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Bicino Screen"
    static let description = IntentDescription(
        "Shows the previous screen on the connected Bicino, like its PWR button."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await actions.activateScreen(.previous)
        return .result(dialog: "\(DeviceScreenActivationReplyText.text(for: outcome, requested: nil))")
    }
}

@available(iOS 17.0, *)
struct FindPlaceOnRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a Place on My Route"
    static let description = IntentDescription(
        "Finds places such as coffee shops, bike shops or supermarkets ahead on the active route, or near you when you aren't navigating."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Place")
    var place: RoutePlaceKind

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    static var parameterSummary: some ParameterSummary {
        Summary("Find a \(\.$place) on my route")
    }

    init() {}

    init(place: RoutePlaceKind) {
        self.place = place
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await actions.findPlaces(place)
        return .result(dialog: "\(RoutePlaceSearchReply.text(for: outcome, kind: place))")
    }
}

@available(iOS 17.0, *)
struct StartBicinoWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Bicino Workout"
    static let description = IntentDescription(
        "Starts recording an outdoor cycling workout."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await actions.workoutReply(.start)
        return .result(dialog: "\(reply)")
    }
}

@available(iOS 17.0, *)
struct PauseBicinoWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Bicino Workout"
    static let description = IntentDescription("Pauses the ride Bicino is recording.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await actions.workoutReply(.pause)
        return .result(dialog: "\(reply)")
    }
}

@available(iOS 17.0, *)
struct ResumeBicinoWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Bicino Workout"
    static let description = IntentDescription("Resumes the paused ride.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await actions.workoutReply(.resume)
        return .result(dialog: "\(reply)")
    }
}

@available(iOS 17.0, *)
struct MarkBicinoSegmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Bicino Segment"
    static let description = IntentDescription(
        "Ends the current segment and starts the next one in the ride Bicino is recording."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await actions.workoutReply(.segment)
        return .result(dialog: "\(reply)")
    }
}

@available(iOS 17.0, *)
struct FinishBicinoWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Bicino Workout"
    static let description = IntentDescription(
        "Ends and saves the ride Bicino is recording, after you confirm."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @AppDependency(default: .unavailable)
    private var actions: BicinoSiriActions

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var outcome = await actions.runWorkoutCommand(.finish)
        if case .needsConfirmation(_, let sessionID) = outcome {
            // Declining throws, and Siri ends without changing the ride.
            try await confirmFinish(BicinoWorkoutReplyText.text(for: outcome))
            outcome = await actions.runWorkoutCommand(.finish, confirmedSession: sessionID)
        }
        return .result(dialog: "\(BicinoWorkoutReplyText.text(for: outcome))")
    }

    private func confirmFinish(_ question: String) async throws {
        if #available(iOS 18.0, *) {
            try await requestConfirmation(
                actionName: .custom(
                    acceptLabel: "Finish",
                    // "Stop" and "End" stay out: riders say them to back out.
                    acceptAlternatives: ["Yes", "Finish ride", "Save"],
                    denyLabel: "Keep Riding",
                    denyAlternatives: ["No", "Cancel", "Stop", "Keep going"]
                ),
                dialog: "\(question)"
            )
        } else {
            try await requestConfirmation()
        }
    }
}

/// Phrases must name the app, so Siri says "Bicino" ("Bicino Dev" for
/// Debug builds) in each.
@available(iOS 17.0, *)
struct BicinoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBicinoScreenIntent(),
            phrases: [
                "Open \(\.$screen) screen on \(.applicationName)",
                "Open the \(\.$screen) screen in \(.applicationName)",
                "Show \(\.$screen) on \(.applicationName)",
                "Switch \(.applicationName) to \(\.$screen)",
                "\(.applicationName) \(\.$screen) screen",
            ],
            shortTitle: "Open Screen",
            systemImageName: "rectangle.on.rectangle"
        )
        AppShortcut(
            intent: NextBicinoScreenIntent(),
            phrases: [
                "Next screen on \(.applicationName)",
                "\(.applicationName) next screen",
                "Show the next \(.applicationName) screen",
            ],
            shortTitle: "Next Screen",
            systemImageName: "arrow.right.square"
        )
        AppShortcut(
            intent: PreviousBicinoScreenIntent(),
            phrases: [
                "Previous screen on \(.applicationName)",
                "\(.applicationName) previous screen",
            ],
            shortTitle: "Previous Screen",
            systemImageName: "arrow.left.square"
        )
        AppShortcut(
            intent: FindPlaceOnRouteIntent(),
            phrases: [
                "Find a \(\.$place) on my route with \(.applicationName)",
                "Find a \(\.$place) on my route in \(.applicationName)",
                "\(.applicationName) find a \(\.$place)",
                "Where's the nearest \(\.$place) on \(.applicationName)",
            ],
            shortTitle: "Find on Route",
            systemImageName: "mappin.and.ellipse"
        )
        AppShortcut(
            intent: StartBicinoWorkoutIntent(),
            phrases: [
                "\(.applicationName) start workout",
                "\(.applicationName) start ride",
                "Start a workout with \(.applicationName)",
                "Start a ride with \(.applicationName)",
            ],
            shortTitle: "Start Workout",
            systemImageName: "figure.outdoor.cycle"
        )
        AppShortcut(
            intent: PauseBicinoWorkoutIntent(),
            phrases: [
                "\(.applicationName) pause workout",
                "\(.applicationName) pause ride",
                "Pause my ride on \(.applicationName)",
            ],
            shortTitle: "Pause Workout",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeBicinoWorkoutIntent(),
            phrases: [
                "\(.applicationName) resume workout",
                "\(.applicationName) resume ride",
                "Resume my ride on \(.applicationName)",
            ],
            shortTitle: "Resume Workout",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: MarkBicinoSegmentIntent(),
            phrases: [
                "\(.applicationName) segment",
                "\(.applicationName) mark segment",
                "\(.applicationName) new segment",
                "\(.applicationName) lap",
                "Mark a segment with \(.applicationName)",
            ],
            shortTitle: "Mark Segment",
            systemImageName: "flag.checkered"
        )
        AppShortcut(
            intent: FinishBicinoWorkoutIntent(),
            phrases: [
                "\(.applicationName) stop workout",
                "\(.applicationName) end workout",
                "\(.applicationName) finish workout",
                "\(.applicationName) stop ride",
                "\(.applicationName) end ride",
                "\(.applicationName) finish ride",
            ],
            shortTitle: "Finish Workout",
            systemImageName: "stop.circle"
        )
    }
}
