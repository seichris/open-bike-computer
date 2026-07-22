import Foundation

nonisolated enum WatchWorkoutLaunchRequest: Equatable, Sendable {
    case startOutdoorCycling

    static let startOutdoorCyclingURL: URL = {
        guard let url = URL(string: "bikecomputer://workout/start") else {
            preconditionFailure("The bundled workout launch URL must be valid")
        }
        return url
    }()

    init?(url: URL) {
        guard url.scheme?.lowercased() == "bikecomputer",
              url.host?.lowercased() == "workout",
              url.path == "/start" else {
            return nil
        }
        self = .startOutdoorCycling
    }
}
