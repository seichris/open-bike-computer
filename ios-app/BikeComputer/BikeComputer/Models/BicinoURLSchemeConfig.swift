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

/// The QR code shown on a Bike Computer's pre-connection screen points at the
/// public app landing URL. Installed Bicino builds claim that URL as an
/// associated domain, so scanning the code can return to the app instead of
/// stopping at the App Store redirect.
nonisolated enum BicinoAppLinkPolicy {
    static let host = "bicino.com"
    static let appPath = "/app"

    static func isDeviceConnectionLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host else {
            return false
        }

        let path = url.path.hasSuffix("/") && url.path.count > 1
            ? String(url.path.dropLast())
            : url.path
        return path == appPath
    }
}

nonisolated enum BicinoAppLinkPresentationPolicy {
    static func shouldPresent(
        isApplicationActive: Bool,
        isOnboardingStatePrepared: Bool,
        hasVisibleOnboarding: Bool,
        hasPresentedSheet: Bool,
        hasActiveSheet: Bool,
        isSheetDismissalInFlight: Bool,
        hasQueuedSheet: Bool,
        hasSavedRouteMapPreview: Bool,
        isMapAreaSelectionActive: Bool
    ) -> Bool {
        isApplicationActive &&
            isOnboardingStatePrepared &&
            !hasVisibleOnboarding &&
            !hasPresentedSheet &&
            !hasActiveSheet &&
            !isSheetDismissalInFlight &&
            !hasQueuedSheet &&
            !hasSavedRouteMapPreview &&
            !isMapAreaSelectionActive
    }
}
