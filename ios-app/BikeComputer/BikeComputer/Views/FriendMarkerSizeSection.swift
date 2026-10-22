import SwiftUI

/// The one friend-marker size shared by every bike-computer map screen and the
/// iPhone map. Each map screen's settings show the same control and value.
struct FriendMarkerSizeSection: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        if bleManager.supportsFriendMarkerScale {
            Section {
                Picker("Friend Marker Size", selection: Binding(
                    get: { bleManager.friendMarkerScale },
                    set: { bleManager.setFriendMarkerScale($0) }
                )) {
                    ForEach(FriendMarkerScale.allCases) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
            } header: {
                Text("Friends")
            } footer: {
                Text("Scales friend pictures together with their distances and group counts on every Bicino map screen, including topographic maps. The iPhone map uses the same size.")
            }
        }
    }
}
