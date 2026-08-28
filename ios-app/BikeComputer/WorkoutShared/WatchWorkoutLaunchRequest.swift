import Foundation

nonisolated enum WatchWorkoutLaunchRequest: Equatable, Sendable {
    case startOutdoorCycling

    static func resolvedURLScheme(configuredScheme: String?) -> String {
        let normalizedScheme = configuredScheme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedScheme, !normalizedScheme.isEmpty else {
            return "bikecomputer"
        }
        return normalizedScheme
    }

    private static let urlScheme: String = {
        let configuredScheme = Bundle.main.object(
            forInfoDictionaryKey: "BicinoURLScheme"
        ) as? String
        return resolvedURLScheme(configuredScheme: configuredScheme)
    }()

    static let startOutdoorCyclingURL: URL = {
        startOutdoorCyclingURL(urlScheme: urlScheme)
    }()

    static func startOutdoorCyclingURL(urlScheme: String) -> URL {
        let resolvedScheme = resolvedURLScheme(configuredScheme: urlScheme)
        guard let url = URL(string: "\(resolvedScheme)://workout/start") else {
            preconditionFailure("The bundled workout launch URL must be valid")
        }
        return url
    }

    init?(url: URL) {
        self.init(url: url, urlScheme: Self.urlScheme)
    }

    init?(url: URL, urlScheme: String) {
        let resolvedScheme = Self.resolvedURLScheme(
            configuredScheme: urlScheme
        )
        guard url.absoluteString == "\(resolvedScheme)://workout/start" else {
            return nil
        }
        self = .startOutdoorCycling
    }
}

nonisolated struct PendingWorkoutLaunchRequest: Equatable, Identifiable, Sendable {
    enum WorkoutType: Equatable, Sendable {
        case outdoorCycling
    }

    enum Source: Equatable, Sendable {
        case complicationURL
    }

    let id: UUID
    let workoutType: WorkoutType
    let source: Source
    let createdAt: Date
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        workoutType: WorkoutType,
        source: Source,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.workoutType = workoutType
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}
