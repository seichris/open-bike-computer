import Foundation

nonisolated enum WatchWorkoutLaunchRequest: Equatable, Sendable {
    case startOutdoorCycling

    private static let urlScheme: String = {
        guard let configuredScheme = Bundle.main.object(
            forInfoDictionaryKey: "BicinoURLScheme"
        ) as? String,
              !configuredScheme.isEmpty else {
            return "bikecomputer"
        }
        return configuredScheme.lowercased()
    }()

    static let startOutdoorCyclingURL: URL = {
        guard let url = URL(string: "\(urlScheme)://workout/start") else {
            preconditionFailure("The bundled workout launch URL must be valid")
        }
        return url
    }()

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme,
              url.host?.lowercased() == "workout",
              url.path == "/start" else {
            return nil
        }
        self = .startOutdoorCycling
    }
}
