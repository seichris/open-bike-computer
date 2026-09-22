import Foundation

nonisolated enum BicinoDeviceMapReadiness: Equatable {
    case checking
    case ready
    case needsMap
    case needsSDCard

    static func resolve(
        hasSDCard: Bool?,
        activeMapID: String,
        mapStateKnown: Bool,
        mapFoundForCurrentLocation: Bool?
    ) -> BicinoDeviceMapReadiness {
        guard let hasSDCard else { return .checking }
        guard hasSDCard else { return .needsSDCard }
        guard !activeMapID.isEmpty else { return .needsMap }
        guard mapStateKnown,
              let mapFoundForCurrentLocation else {
            return .checking
        }
        return mapFoundForCurrentLocation ? .ready : .needsMap
    }
}

nonisolated enum BicinoDeviceIntroductionHistory {
    private static func token(for deviceID: String) -> String {
        Data(deviceID.utf8).base64EncodedString()
    }

    static func contains(deviceID: String, storedTokens: String) -> Bool {
        Set(storedTokens.split(separator: "\n").map(String.init))
            .contains(token(for: deviceID))
    }

    static func adding(deviceID: String, to storedTokens: String) -> String {
        var tokens = Set(storedTokens.split(separator: "\n").map(String.init))
        tokens.insert(token(for: deviceID))
        return tokens.sorted().joined(separator: "\n")
    }
}
