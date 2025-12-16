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
    
    @State private var showingRouteInput = false
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var transportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking
        }
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 15) {
                // BLE Connection Status
                ConnectionStatusView(
                    isConnected: coordinator.isConnected,
                    signalStrength: coordinator.signalStrength,
                    onReconnect: { coordinator.disconnect() }
                )
                
                // Main Content Views
                if coordinator.isNavigating {
                    // Swipeable view: map | navigation+workout
                    TabView(selection: $coordinator.selectedView) {
                        mapView
                            .tag(0)

                        CombinedNavigationWorkoutView(coordinator: coordinator)
                            .tag(1)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                    .frame(height: 550)
                } else if coordinator.routeCalculation.isCalculating {
                    CalculationStatusView(status: coordinator.routeCalculation.status)
                } else {
                    // Swipeable view: map | workout
                    TabView(selection: $coordinator.selectedView) {
                        mapView
                            .tag(0)

                        WorkoutOnlyView(coordinator: coordinator)
                            .tag(1)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                    .frame(height: 550)
                }
                
                // Bottom Controls
                VStack(spacing: 15) {
                    if !coordinator.isNavigating {
                        // Search bar for destination
                        Button(action: {
                            showingRouteInput = true
                        }) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                Text("Search for a destination")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                        }
                        .disabled(!coordinator.isConnected)
                        .opacity(coordinator.isConnected ? 1.0 : 0.5)
                    } else {
                        Button(action: {
                            coordinator.stopNavigation()
                        }) {
                            Label("Stop Navigation", systemImage: "stop.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 0)
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showingRouteInput) {
                RouteInputView(
                    sourceAddress: $sourceAddress,
                    destinationAddress: $destinationAddress,
                    currentAddress: coordinator.currentAddress,
                    onStartNavigation: { source, destination, transport in
                        transportType = transport
                        coordinator.startNavigation(from: source, to: destination, transportType: transport)
                    }
                )
            }
            .alert("Navigation Error", isPresented: $coordinator.alert.isShowing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.alert.message)
            }
        }
        .onChange(of: coordinator.selectedView) { newValue in
            // Notify coordinator of view change
            coordinator.updateSelectedView(newValue)
        }
    }
    
    // MARK: - Map View
    
    private var mapView: some View {
        MapViewContainer(
            location: coordinator.currentLocation,
            route: coordinator.currentRoute,
            onDestinationSelected: coordinator.isNavigating ? nil : { coordinate, mapLocation in
                coordinator.handleDestinationSelection(coordinate: coordinate, mapLocation: mapLocation)
            }
        )
        .cornerRadius(20)
        .padding(.horizontal, 30)
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

