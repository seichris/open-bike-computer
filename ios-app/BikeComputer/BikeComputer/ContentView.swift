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
    
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var showingSettings = false
    @State private var isSearchPanelExpanded = false
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mapView
                    .ignoresSafeArea()

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
            }
            .alert("Navigation Error", isPresented: $coordinator.alert.isShowing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.alert.message)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(coordinator.bleManager)
            }
        }
        .onChange(of: coordinator.selectedView) { newValue in
            coordinator.updateSelectedView(newValue)
        }
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
    
    // MARK: - Map View
    
    private var mapView: some View {
        MapViewContainer(
            location: coordinator.currentLocation,
            route: coordinator.currentRoute,
            simulatedPosition: coordinator.simulatedPosition,
            isSimulationMode: coordinator.isSimulationMode,
            isNavigating: coordinator.isNavigating,
            onMapTapped: {
                if isSearchPanelExpanded {
                    isSearchPanelExpanded = false
                }
            },
            onDestinationSelected: coordinator.isNavigating ? nil : { coordinate, mapLocation in
                coordinator.handleDestinationSelection(coordinate: coordinate, mapLocation: mapLocation)
            }
        )
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
