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
        guard url.scheme?.lowercased() == Self.resolvedURLScheme(
            configuredScheme: urlScheme
        ),
              url.host?.lowercased() == "workout",
              url.path == "/start" else {
            return nil
        }
        self = .startOutdoorCycling
    }
}
