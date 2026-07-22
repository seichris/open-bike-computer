import SwiftUI

struct WatchSettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: versionDescription)
            }
        }
        .navigationTitle("Settings")
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        return switch (version, build) {
        case let (.some(version), .some(build)):
            "\(version) (\(build))"
        case let (.some(version), .none):
            version
        case let (.none, .some(build)):
            build
        case (.none, .none):
            "Unknown"
        }
    }
}

#Preview {
    NavigationStack {
        WatchSettingsView()
    }
}
