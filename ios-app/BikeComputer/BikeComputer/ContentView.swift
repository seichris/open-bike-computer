//
//  ContentView.swift
//  BikeComputer
//
//  Main view for the Bike Computer app
//

import SwiftUI
import MapKit

struct ContentView: View {
    
    // MARK: - State
    
    @StateObject private var coordinator = BikeComputerCoordinator()
    @StateObject private var offlineMapManager = OfflineMapManager()
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var showingSettings = false
    @State private var isSearchPanelExpanded = false
    @State private var dismissedOfflineMapOnboarding = false
    @State private var offlineMapSelectionWidth: CGFloat?
    @State private var offlineMapSelectionHeight: CGFloat?
    @State private var offlineMapSelectionCenterY: CGFloat?
    @State private var offlineMapSelectionDragStartFrame: CGRect?
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let selectionFrame = offlineMapSelectionFrame(in: proxy.size)

                mapView(selectionFrame: offlineMapManager.isMapAreaSelectionActive ? selectionFrame : nil)
                    .ignoresSafeArea()

                if offlineMapManager.isMapAreaSelectionActive {
                    offlineMapSelectionOverlay(selectionFrame: selectionFrame)
                }

                VStack(spacing: 0) {
                    topOverlay

                    if coordinator.isNavigating {
                        navigationInstructionBanner
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    Spacer()

                    bottomOverlay(maxHeight: proxy.size.height * 0.68)
                }
                .ignoresSafeArea(.container, edges: .bottom)

                if coordinator.bleManager.supportsDeviceSounds &&
                    !offlineMapManager.isMapAreaSelectionActive &&
                    !shouldShowOfflineMapOnboarding {
                    DeviceSoundMapButton(bleManager: coordinator.bleManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 16)
                        .zIndex(9)
                }

                if shouldShowOfflineMapOnboarding {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()

                    OfflineMapOnboardingView(
                        manager: offlineMapManager,
                        bleManager: coordinator.bleManager,
                        location: coordinator.currentLocation,
                        isLocationAuthorized: coordinator.isLocationAuthorized,
                        onRequestLocation: { coordinator.requestLocationAuthorization() },
                        onChooseArea: { offlineMapManager.beginMapAreaSelection() },
                        onClose: { dismissedOfflineMapOnboarding = true }
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(20)
                }
            }
            .alert("Navigation Error", isPresented: $coordinator.alert.isShowing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.alert.message)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    locationAuthorized: coordinator.isLocationAuthorized,
                    currentLocation: coordinator.currentLocation,
                    offlineMapManager: offlineMapManager,
                    firmwareUpdateManager: coordinator.firmwareUpdateManager,
                    onStartTestNavigation: { destination in
                        coordinator.startNavigation(
                            from: .currentLocation,
                            to: .query(destination),
                            transportType: RouteTransportTypes.cycling,
                            isTestMode: true
                        )
                    }
                )
                    .environmentObject(coordinator.bleManager)
            }
        }
        .onChange(of: coordinator.selectedView) { newValue in
            coordinator.updateSelectedView(newValue)
        }
        .onAppear {
            offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
        }
        .onChange(of: scenePhase) { newValue in
            guard newValue == .active else { return }
            offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
        }
        .onChange(of: coordinator.bleManager.isConnected) { _ in
            schedulePendingMapInstallResume()
        }
        .onChange(of: coordinator.bleManager.isNavigationReady) { _ in
            schedulePendingMapInstallResume()
        }
        .onChange(of: offlineMapManager.isMapAreaSelectionActive) { isActive in
            if isActive {
                showingSettings = false
                offlineMapSelectionWidth = nil
                offlineMapSelectionHeight = nil
                offlineMapSelectionCenterY = nil
            } else {
                offlineMapSelectionDragStartFrame = nil
            }
        }
    }

    private func schedulePendingMapInstallResume() {
        guard offlineMapManager.hasDownloadedPendingDeviceInstall else { return }
        Task { @MainActor in
            while offlineMapManager.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            resumePendingMapInstallIfReady()
        }
    }

    private func resumePendingMapInstallIfReady() {
        guard OfflineMapAutomaticRecoveryTrigger.shouldResume(
            hasPendingInstall: offlineMapManager.hasDownloadedPendingDeviceInstall,
            isBusy: offlineMapManager.isBusy,
            isConnected: coordinator.bleManager.isConnected,
            isNavigationReady: coordinator.bleManager.isNavigationReady
        ) else { return }
        offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
    }

    private var shouldShowOfflineMapOnboarding: Bool {
        guard !dismissedOfflineMapOnboarding else { return false }
        guard !offlineMapManager.isMapAreaSelectionActive else { return false }
        guard !offlineMapManager.isBusy,
              !offlineMapManager.hasPendingMapJob,
              offlineMapManager.currentJob == nil,
              offlineMapManager.downloadedPackURL == nil,
              offlineMapManager.errorMessage == nil else { return false }
        if !coordinator.isLocationAuthorized {
            return true
        }
        return coordinator.bleManager.deviceHasSDCard == true &&
            coordinator.bleManager.deviceMapFoundForCurrentLocation == false
    }

    private var topOverlay: some View {
        HStack(alignment: .center, spacing: 12) {
            ConnectionStatusView(
                isConnected: coordinator.isConnected,
                onReconnect: { coordinator.reconnect() }
            )

            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .shadow(color: .white.opacity(0.8), radius: 2, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .zIndex(10)
    }

    @ViewBuilder
    private func bottomOverlay(maxHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            if coordinator.routeCalculation.isCalculating {
                CalculationStatusView(status: coordinator.routeCalculation.status)
                    .padding(.horizontal, 18)
            } else if coordinator.isNavigating {
                navigationControlPanel
            } else {
                if shouldShowOfflineMapStatusChip {
                    offlineMapStatusChip
                        .padding(.horizontal, 18)
                }

                RouteSearchPanel(
                    sourceAddress: $sourceAddress,
                    destinationAddress: $destinationAddress,
                    isExpanded: $isSearchPanelExpanded,
                    currentAddress: coordinator.currentAddress,
                    currentLocation: coordinator.currentLocation,
                    maxExpandedHeight: maxHeight,
                    onStartNavigation: { source, destination, transport in
                        isSearchPanelExpanded = false
                        coordinator.startNavigation(from: source, to: destination, transportType: transport)
                    }
                )
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 24)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isSearchPanelExpanded)
        .animation(.easeInOut(duration: 0.2), value: coordinator.routeCalculation.isCalculating)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isNavigating)
    }

    private var navigationControlPanel: some View {
        NavigationMetricsPanel(
            arrivalDate: coordinator.expectedArrivalDate,
            remainingTime: coordinator.routeRemainingTime,
            remainingDistance: coordinator.routeRemainingDistance,
            onStopNavigation: { coordinator.stopNavigation() }
        )
        .padding(.horizontal, 12)
    }

    private var navigationInstructionBanner: some View {
        NavigationInstructionBanner(
            iconID: coordinator.currentIconID,
            distanceToManeuver: coordinator.distanceToManeuver,
            instruction: coordinator.currentInstruction
        )
    }

    private var shouldShowOfflineMapStatusChip: Bool {
        offlineMapManager.isBusy ||
            offlineMapManager.hasPendingMapJob ||
            offlineMapManager.currentJob != nil ||
            offlineMapManager.downloadedPackURL != nil ||
            offlineMapManager.errorMessage != nil
    }

    private var offlineMapStatusChip: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 10) {
                if offlineMapManager.isBusy {
                    ProgressView(value: offlineMapManager.activityProgress)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: offlineMapManager.downloadedPackURL == nil ? "map" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(offlineMapManager.downloadedPackURL == nil ? .accentColor : .green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(offlineMapStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Open Map Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Offline map download status")
    }

    private var offlineMapStatusTitle: String {
        if let error = offlineMapManager.errorMessage, !error.isEmpty {
            return "Map download needs attention"
        }
        if offlineMapManager.downloadedPackURL != nil {
            return "Map pack ready to upload"
        }
        if !offlineMapManager.statusMessage.isEmpty {
            return offlineMapManager.statusMessage
        }
        return "Preparing offline map"
    }
    
    // MARK: - Map View
    
    private func mapView(selectionFrame: CGRect?) -> some View {
        let canSelectDestination = !coordinator.isNavigating && !offlineMapManager.isMapAreaSelectionActive

        return MapViewContainer(
            location: coordinator.currentLocation,
            route: coordinator.currentRoute,
            simulatedPosition: coordinator.simulatedPosition,
            isSimulationMode: coordinator.isSimulationMode,
            isNavigating: coordinator.isNavigating,
            offlineMapSelectionFrame: selectionFrame,
            onMapTapped: {
                if isSearchPanelExpanded {
                    isSearchPanelExpanded = false
                }
            },
            onOfflineMapSelectionBoundsChanged: { bounds in
                offlineMapManager.updateMapAreaSelection(bounds: bounds)
            },
            onDestinationSelected: canSelectDestination ? { coordinate, mapLocation in
                coordinator.handleDestinationSelection(coordinate: coordinate, mapLocation: mapLocation)
            } : nil
        )
    }

    private func offlineMapSelectionFrame(in size: CGSize) -> CGRect {
        let defaultLength = defaultOfflineMapSelectionSideLength(in: size)
        let width = offlineMapSelectionWidth ?? defaultLength
        let height = offlineMapSelectionHeight ?? defaultLength
        let centerY = offlineMapSelectionCenterY ?? size.height / 2
        return CGRect(
            x: (size.width - width) / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    private func defaultOfflineMapSelectionSideLength(in size: CGSize) -> CGFloat {
        min(max(size.width - 48, 180), min(360, size.height * 0.46))
    }

    private func offlineMapSelectionOverlay(selectionFrame: CGRect) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white, lineWidth: 2)
                )
                .frame(width: selectionFrame.width, height: selectionFrame.height)
                .position(x: selectionFrame.midX, y: selectionFrame.midY)
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
                .allowsHitTesting(false)

            offlineMapSelectionResizeHandle(edge: .top, selectionFrame: selectionFrame)
                .position(x: selectionFrame.midX, y: selectionFrame.minY)

            offlineMapSelectionResizeHandle(edge: .bottom, selectionFrame: selectionFrame)
                .position(x: selectionFrame.midX, y: selectionFrame.maxY)

            HStack(spacing: 12) {
                Button {
                    offlineMapManager.cancelMapAreaSelection()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    offlineMapManager.createJobFromSelectedMapArea()
                } label: {
                    Label("Download Area", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(offlineMapManager.selectedMapBounds == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 70)
        }
        .ignoresSafeArea()
        .zIndex(20)
    }

    private func offlineMapSelectionResizeHandle(
        edge: OfflineMapSelectionResizeEdge,
        selectionFrame: CGRect
    ) -> some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            )
            .frame(width: 92, height: 28)
            .overlay(
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        resizeOfflineMapSelection(
                            edge: edge,
                            translation: value.translation.height,
                            currentFrame: selectionFrame
                        )
                    }
                    .onEnded { _ in
                        offlineMapSelectionDragStartFrame = nil
                    }
            )
            .accessibilityLabel(edge == .top ? "Resize map area top edge" : "Resize map area bottom edge")
    }

    private func resizeOfflineMapSelection(
        edge: OfflineMapSelectionResizeEdge,
        translation: CGFloat,
        currentFrame: CGRect
    ) {
        let startFrame = offlineMapSelectionDragStartFrame ?? currentFrame
        if offlineMapSelectionDragStartFrame == nil {
            offlineMapSelectionDragStartFrame = startFrame
        }

        let minHeight: CGFloat = 160
        let maxHeight = min(UIScreen.main.bounds.height - 180, 640)
        let rawHeight: CGFloat
        let fixedEdge: CGFloat

        switch edge {
        case .top:
            fixedEdge = startFrame.maxY
            rawHeight = startFrame.height - translation
            let height = min(max(rawHeight, minHeight), maxHeight)
            offlineMapSelectionWidth = startFrame.width
            offlineMapSelectionHeight = height
            offlineMapSelectionCenterY = fixedEdge - height / 2
        case .bottom:
            fixedEdge = startFrame.minY
            rawHeight = startFrame.height + translation
            let height = min(max(rawHeight, minHeight), maxHeight)
            offlineMapSelectionWidth = startFrame.width
            offlineMapSelectionHeight = height
            offlineMapSelectionCenterY = fixedEdge + height / 2
        }
    }
}

private struct DeviceSoundMapButton: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        Button {
            bleManager.playSelectedDeviceSound()
        } label: {
            Image(systemName: bleManager.selectedDeviceSound.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!bleManager.isNavigationReady)
        .opacity(bleManager.isNavigationReady ? 1 : 0.5)
        .accessibilityLabel("Play \(bleManager.selectedDeviceSound.title)")
    }
}

private enum OfflineMapSelectionResizeEdge {
    case top
    case bottom
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
