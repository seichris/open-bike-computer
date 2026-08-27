import Foundation

nonisolated enum BicinoURLSchemeConfig {
    static let infoDictionaryKey = "BicinoURLScheme"
    static let development = "bikecomputer-dev"
    static let production = "bikecomputer"

    static let current = value(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    static func value(infoDictionary: [String: Any]) -> String {
        guard let raw = infoDictionary[infoDictionaryKey] as? String else {
            return ""
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [development, production].contains(value) ? value : ""
    }

    static func isConsistent(
        scheme: String,
        serviceURLString: String
    ) -> Bool {
        switch (scheme, serviceURLString) {
        case (development, OfflineMapServiceConfig.developmentServerURLString),
             (production, OfflineMapServiceConfig.productionServerURLString):
            true
        default:
            false
        }
    }
}
