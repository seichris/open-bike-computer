import SwiftUI

struct WatchSettingsView: View {
    @ObservedObject var manager: WatchWorkoutManager

    var body: some View {
        Form {
            Section("Ride Detection") {
                if manager.rideDetectionSettingsConfirmed {
                    LabeledContent(
                        "Start",
                        value: startModeLabel
                    )
                    LabeledContent(
                        "Auto-Pause",
                        value: manager.rideDetectionSettings.autoPauseEnabled
                            ? "On"
                            : "Off"
                    )
                    LabeledContent(
                        "Start Alerts",
                        value: alertModeLabel
                    )
                } else {
                    Text("Connect to the bike computer to sync this policy.")
                        .foregroundStyle(.secondary)
                }
                Text("Change ride detection on iPhone or the bike computer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private var startModeLabel: String {
        switch manager.rideDetectionSettings.startMode {
        case .off: "Off"
        case .ask: "Ask"
        case .automatic: "Automatic"
        }
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

    private var alertModeLabel: String {
        switch manager.rideDetectionSettings.alertMode {
        case 0: "Sound + Haptic"
        case 1: "Haptic Only"
        default: "Visual Only"
        }
    }
}

#Preview {
    NavigationStack {
        WatchSettingsView(manager: WatchWorkoutManager())
    }
}
