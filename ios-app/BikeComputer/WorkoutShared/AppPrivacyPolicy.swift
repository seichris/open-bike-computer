import Foundation

nonisolated enum AppPrivacyPolicy {
    static let urlString = "https://github.com/seichris/open-bike-computer/blob/main/ios-app/PRIVACY_POLICY.md"

    static var url: URL {
        guard let url = URL(string: urlString) else {
            preconditionFailure("The bundled privacy-policy URL must be valid")
        }
        return url
    }
}
