import AppIntents
import Foundation

@available(iOS 17.0, *)
final class WorkoutLiveActivityIntentDispatcher: @unchecked Sendable {
    static let unavailable = WorkoutLiveActivityIntentDispatcher {
        _, _ in false
    }

    private let handler:
        @MainActor @Sendable (WorkoutLiveActivityAction, UUID) async -> Bool

    init(
        handler: @escaping @MainActor @Sendable (
            WorkoutLiveActivityAction,
            UUID
        ) async -> Bool
    ) {
        self.handler = handler
    }

    func perform(
        _ action: WorkoutLiveActivityAction,
        sessionID: UUID
    ) async -> Bool {
        await handler(action, sessionID)
    }
}

@available(iOS 17.0, *)
private enum WorkoutLiveActivityIntentExecution {
    static func perform(
        _ action: WorkoutLiveActivityAction,
        sessionID: String,
        dispatcher: WorkoutLiveActivityIntentDispatcher
    ) async {
        guard let sessionID = UUID(uuidString: sessionID) else { return }
        _ = await dispatcher.perform(action, sessionID: sessionID)
    }
}

@available(iOS 17.0, *)
struct BikeComputerMarkSegmentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Workout Segment"
    static let description = IntentDescription(
        "Marks a segment in the active BikeComputer workout on Apple Watch."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Workout Session")
    var sessionID: String

    @AppDependency(default: .unavailable)
    private var dispatcher: WorkoutLiveActivityIntentDispatcher

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await WorkoutLiveActivityIntentExecution.perform(
            .segment,
            sessionID: sessionID,
            dispatcher: dispatcher
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct BikeComputerPauseWorkoutIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Workout"
    static let description = IntentDescription(
        "Pauses the active BikeComputer workout on Apple Watch."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Workout Session")
    var sessionID: String

    @AppDependency(default: .unavailable)
    private var dispatcher: WorkoutLiveActivityIntentDispatcher

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await WorkoutLiveActivityIntentExecution.perform(
            .pause,
            sessionID: sessionID,
            dispatcher: dispatcher
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct BikeComputerResumeWorkoutIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Workout"
    static let description = IntentDescription(
        "Resumes the paused BikeComputer workout on Apple Watch."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Workout Session")
    var sessionID: String

    @AppDependency(default: .unavailable)
    private var dispatcher: WorkoutLiveActivityIntentDispatcher

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await WorkoutLiveActivityIntentExecution.perform(
            .resume,
            sessionID: sessionID,
            dispatcher: dispatcher
        )
        return .result()
    }
}
