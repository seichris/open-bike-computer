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
    
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var showingSettings = false
    @State private var openOfflineMapsInSettings = false
    @State private var isSearchPanelExpanded = false
    @State private var dismissedOfflineMapOnboarding = false
    @State private var offlineMapSelectionSideLength: CGFloat?
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
            .sheet(isPresented: $showingSettings, onDismiss: {
                openOfflineMapsInSettings = false
            }) {
                SettingsView(
                    locationAuthorized: coordinator.isLocationAuthorized,
                    offlineMapManager: offlineMapManager,
                    initialOfflineMapsPresented: openOfflineMapsInSettings
                )
                    .environmentObject(coordinator.bleManager)
            }
        }
        .onChange(of: coordinator.selectedView) { newValue in
            coordinator.updateSelectedView(newValue)
        }
        .onChange(of: offlineMapManager.isMapAreaSelectionActive) { isActive in
            if isActive {
                showingSettings = false
                offlineMapSelectionSideLength = nil
                offlineMapSelectionCenterY = nil
            } else {
                offlineMapSelectionDragStartFrame = nil
            }
        }
    }

    private var shouldShowOfflineMapOnboarding: Bool {
        guard !dismissedOfflineMapOnboarding else { return false }
        guard !offlineMapManager.isMapAreaSelectionActive else { return false }
        guard !offlineMapManager.isBusy,
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

            Button(action: {
                openOfflineMapsInSettings = false
                showingSettings = true
            }) {
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
                    onStartNavigation: { source, destination, transport, isTestMode in
                        isSearchPanelExpanded = false
                        coordinator.startNavigation(from: source, to: destination, transportType: transport, isTestMode: isTestMode)
                    }
                )
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 12)
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
            offlineMapManager.currentJob != nil ||
            offlineMapManager.downloadedPackURL != nil ||
            offlineMapManager.errorMessage != nil
    }

    private var offlineMapStatusChip: some View {
        Button {
            openOfflineMapsInSettings = true
            showingSettings = true
        } label: {
            HStack(spacing: 10) {
                if offlineMapManager.isBusy {
                    ProgressView(value: offlineMapManager.downloadProgress > 0 ? offlineMapManager.downloadProgress : nil)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: offlineMapManager.downloadedPackURL == nil ? "map" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(offlineMapManager.downloadedPackURL == nil ? .accentColor : .green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(offlineMapStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Open Offline Maps")
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
        MapViewContainer(
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
            onDestinationSelected: coordinator.isNavigating ? nil : { coordinate, mapLocation in
                coordinator.handleDestinationSelection(coordinate: coordinate, mapLocation: mapLocation)
            }
        )
    }

    private func offlineMapSelectionFrame(in size: CGSize) -> CGRect {
        let sideLength = offlineMapSelectionSideLength ?? defaultOfflineMapSelectionSideLength(in: size)
        let centerY = offlineMapSelectionCenterY ?? size.height / 2
        return CGRect(
            x: (size.width - sideLength) / 2,
            y: centerY - sideLength / 2,
            width: sideLength,
            height: sideLength
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

        let minSideLength: CGFloat = 160
        let maxSideLength = min(UIScreen.main.bounds.width - 32, UIScreen.main.bounds.height - 180, 420)
        let rawSideLength: CGFloat
        let fixedEdge: CGFloat

        switch edge {
        case .top:
            fixedEdge = startFrame.maxY
            rawSideLength = startFrame.height - translation
            let sideLength = min(max(rawSideLength, minSideLength), maxSideLength)
            offlineMapSelectionSideLength = sideLength
            offlineMapSelectionCenterY = fixedEdge - sideLength / 2
        case .bottom:
            fixedEdge = startFrame.minY
            rawSideLength = startFrame.height + translation
            let sideLength = min(max(rawSideLength, minSideLength), maxSideLength)
            offlineMapSelectionSideLength = sideLength
            offlineMapSelectionCenterY = fixedEdge + sideLength / 2
        }
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
