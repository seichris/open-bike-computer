import SwiftUI

struct NearbyBicinoSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var bleManager: BLEManager
    @ScaledMetric(relativeTo: .title) private var artworkSize: CGFloat = 180

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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        Text("Bicino")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)

                        Image("NearbyBicino")
                            .resizable()
                            .scaledToFit()
                            .frame(
                                maxWidth: min(artworkSize, 240),
                                maxHeight: min(artworkSize, 240)
                            )
                            .accessibilityHidden(true)

                        Text(
                            "Connect this Bicino to your iPhone to show maps, navigation and ride workout data."
                        )
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)

                connectButton
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
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

    private var connectButton: some View {
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
