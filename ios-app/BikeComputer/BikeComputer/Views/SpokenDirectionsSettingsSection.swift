import SwiftUI

/// Navigation voice prompts on iPhone; off until the rider turns them on.
struct SpokenDirectionsSettingsSection: View {
    @AppStorage(SpokenDirectionsPreference.enabledDefaultsKey)
    private var isEnabled = SpokenDirectionsPreference.defaultEnabled

    var body: some View {
        Section {
            Toggle("Spoken Directions", isOn: $isEnabled)
        } header: {
            Text("Navigation")
        } footer: {
            Text(
                "Reads turn-by-turn directions aloud on iPhone while "
                + "navigating, and lowers other audio while speaking."
            )
        }
    }
}
