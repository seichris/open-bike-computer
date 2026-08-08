import SwiftUI

struct WatchSettingsView: View {
    @ObservedObject var navigationSettings: WatchNavigationSettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Use Watch cellular connection",
                    isOn: Binding(
                        get: {
                            navigationSettings.useWatchCellularConnection
                        },
                        set: {
                            navigationSettings
                                .setUseWatchCellularConnection($0)
                        }
                    )
                )
            } header: {
                Text("Navigation")
            } footer: {
                Text(
                    "Allows online route calculation and rerouting from this Watch. watchOS may use cellular or Wi-Fi when available."
                )
            }

            Section("About") {
                LabeledContent("Version", value: versionDescription)
            }

            Link(destination: AppPrivacyPolicy.url) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            .listRowBackground(Color.clear)
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
        WatchSettingsView(
            navigationSettings: WatchNavigationSettingsStore()
        )
    }
}
