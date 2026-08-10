import SwiftUI

struct NearbyBicinoSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var bleManager: BLEManager
    @ScaledMetric(relativeTo: .title) private var artworkSize: CGFloat = 210

    let candidate: DiscoveredBikeComputerDevice
    @State private var stage: NearbyBicinoSetupStage = .offer

    var body: some View {
        Group {
            switch stage {
            case .offer:
                offerView
                    .transition(reduceMotion ? .identity : .opacity)
            case .pairing:
                BikeComputerPairingFlow(candidate: candidate)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .onDisappear {
            bleManager.cancelPairing()
            bleManager.dismissNearbyBicinoCandidate(
                peripheralIdentifier: candidate.peripheralIdentifier
            )
        }
    }

    private var offerView: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Bicino")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Image("NearbyBicino")
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: min(artworkSize, 280),
                            maxHeight: min(artworkSize, 280)
                        )
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Device \(candidate.shortIdentifier)")
                            .font(.headline)
                            .accessibilityLabel(
                                "Bicino device \(candidate.shortIdentifier)"
                            )
                        Text("Connect this Bicino to your iPhone for maps, navigation, and ride data.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        if reduceMotion {
                            stage.advanceToPairing()
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                stage.advanceToPairing()
                            }
                        }
                    } label: {
                        Text("Connect")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint(
                        "Continues to naming and secure code confirmation"
                    )
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        bleManager.dismissNearbyBicinoCandidate(
                            peripheralIdentifier:
                                candidate.peripheralIdentifier
                        )
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

#if DEBUG
#Preview("Nearby Bicino") {
    NearbyBicinoSetupSheet(
        candidate: DiscoveredBikeComputerDevice(
            peripheralIdentifier: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            advertisedName: "Bicino",
            shortIdentifier: "158D",
            identitySuffix: "FA85158D",
            isClaimed: false,
            rssi: -48,
            lastSeenAt: Date()
        )
    )
    .environmentObject(BLEManager())
}

#Preview("Nearby Bicino - Accessibility") {
    NearbyBicinoSetupSheet(
        candidate: DiscoveredBikeComputerDevice(
            peripheralIdentifier: UUID(),
            advertisedName: "Bicino",
            shortIdentifier: "158D",
            identitySuffix: "FA85158D",
            isClaimed: false,
            rssi: -48,
            lastSeenAt: Date()
        )
    )
    .environmentObject(BLEManager())
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
