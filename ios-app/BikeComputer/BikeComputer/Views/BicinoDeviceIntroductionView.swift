import SwiftUI

struct BicinoDeviceIntroductionView: View {
    @ObservedObject var bleManager: BLEManager
    let onComplete: () -> Void
    let onChooseMapArea: () -> Void
    let onOpenDeviceSettings: () -> Void

    @State private var selectedPage = 0

    private var mapReadiness: BicinoDeviceMapReadiness {
        BicinoDeviceMapReadiness.resolve(
            hasSDCard: bleManager.deviceHasSDCard,
            activeMapID: bleManager.mapTransferActiveMapId,
            mapStateKnown: bleManager.deviceMapStateKnown,
            mapFoundForCurrentLocation:
                bleManager.deviceMapFoundForCurrentLocation
        )
    }

    private var previewFirmwareTarget: String {
        bleManager.firmwareTarget.isEmpty
            ? "WAVESHARE_AMOLED_175"
            : bleManager.firmwareTarget
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TabView(selection: $selectedPage) {
                    controlsPage.tag(0)
                    ridePage.tag(1)
                    mapsPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                actionArea
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Your Bicino is connected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", action: onComplete)
                }
            }
        }
        .accessibilityIdentifier("bicino-device-introduction")
    }

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("NearbyBicino")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 230)
                    .accessibilityLabel("Bicino bike computer")

                introductionTitle(
                    "Use the buttons",
                    subtitle: "Everything you need while riding is on the device."
                )

                instructionRow(
                    icon: "button.programmable",
                    title: "Left button",
                    detail: "Press it to move through your enabled screens."
                )
                instructionRow(
                    icon: "speaker.wave.2.fill",
                    title: "Right button",
                    detail: "It confirms pairing and can honk when that option is enabled in settings."
                )
                instructionRow(
                    icon: "power",
                    title: "Sleep and wake",
                    detail: "Bicino sleeps automatically after it is disconnected. Press the left button to wake it."
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var ridePage: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image("NearbyBicino")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 150, maxHeight: 180)
                        .accessibilityLabel("Navigation screen")

                    RideStatsDevicePreview(
                        layout: RideStatsLayout(),
                        firmwareTarget: previewFirmwareTarget
                    )
                    .frame(maxWidth: 150, maxHeight: 180)
                }

                introductionTitle(
                    "Ride with Bicino",
                    subtitle: "Choose the screen that matches the moment."
                )

                instructionRow(
                    icon: "arrow.triangle.turn.up.right.diamond.fill",
                    title: "Navigate",
                    detail: "See your map and turn instructions without reaching for your phone."
                )
                instructionRow(
                    icon: "figure.outdoor.cycle",
                    title: "Follow your workout",
                    detail: "View live ride stats during your workout."
                )
                instructionRow(
                    icon: "rectangle.3.group.fill",
                    title: "Make it yours",
                    detail: "Choose enabled screens and customize Ride Stats in My Bicino."
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var mapsPage: some View {
        ScrollView {
            VStack(spacing: 22) {
                mapStatusIcon
                    .font(.system(size: 70))
                    .foregroundStyle(mapStatusColor)
                    .padding(.top, 48)

                introductionTitle(mapStatusTitle, subtitle: mapStatusDetail)

                if mapReadiness == .needsSDCard {
                    Text("Bicino stores offline maps on a microSD card.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if mapReadiness == .needsMap {
                    Label(
                        "Choose an area on your iPhone, then keep Bicino connected while the map transfers.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if selectedPage < 2 {
            Button("Continue") {
                withAnimation { selectedPage += 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        } else {
            switch mapReadiness {
            case .needsMap:
                Button("Choose Map Area", action: onChooseMapArea)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            case .checking:
                Button("Check Again") {
                    _ = bleManager.requestMapTransferStatus()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            case .ready, .needsSDCard:
                Button("Done", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Button("Open Device Settings", action: onOpenDeviceSettings)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private func introductionTitle(
        _ title: String,
        subtitle: String
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func instructionRow(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mapStatusIcon: some View {
        switch mapReadiness {
        case .checking:
            ProgressView().controlSize(.large)
        case .ready:
            Image(systemName: "map.fill")
        case .needsMap:
            Image(systemName: "map")
        case .needsSDCard:
            Image(systemName: "sdcard")
        }
    }

    private var mapStatusColor: Color {
        switch mapReadiness {
        case .checking: return .secondary
        case .ready: return .green
        case .needsMap: return .accentColor
        case .needsSDCard: return .orange
        }
    }

    private var mapStatusTitle: String {
        switch mapReadiness {
        case .checking: return "Checking your map"
        case .ready: return "Your map is ready"
        case .needsMap: return "Download a map"
        case .needsSDCard: return "Insert a microSD card"
        }
    }

    private var mapStatusDetail: String {
        switch mapReadiness {
        case .checking:
            return "Bicino is checking whether the current area is available offline."
        case .ready:
            return "The current area is available on your Bicino."
        case .needsMap:
            return "Download the current area in the Bicino app before you ride."
        case .needsSDCard:
            return "Insert a microSD card before downloading an offline map."
        }
    }
}
