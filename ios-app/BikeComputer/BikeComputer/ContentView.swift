//
//  ContentView.swift
//  BikeComputer
//
//  Main view demonstrating NavigationEngine and BLEManager integration
//

import SwiftUI
import MapKit

struct ContentView: View {
    
    @StateObject private var bleManager = BLEManager()
    @StateObject private var navEngine = NavigationEngine()
    
    @State private var showingRouteInput = false
    @State private var sourceAddress = "San Francisco, CA"
    @State private var destinationAddress = "Berkeley, CA"
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                
                // Header
                Text("Bike Computer")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .padding(.top, 40)
                
                // BLE Connection Status
                connectionStatusView
                
                // Navigation Status
                if navEngine.isNavigating {
                    navigationStatusView
                } else {
                    placeholderView
                }
                
                Spacer()
                
                // Control Buttons
                VStack(spacing: 15) {
                    if !navEngine.isNavigating {
                        Button(action: {
                            showingRouteInput = true
                        }) {
                            Label("Start Navigation", systemImage: "location.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(bleManager.isConnected ? Color.blue : Color.gray)
                                .cornerRadius(12)
                        }
                        .disabled(!bleManager.isConnected)
                    } else {
                        Button(action: {
                            navEngine.stopNavigation()
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
                    
                    if !bleManager.isConnected {
                        Button(action: {
                            bleManager.startScanning()
                        }) {
                            Label(bleManager.isScanning ? "Scanning..." : "Reconnect", 
                                  systemImage: "antenna.radiowaves.left.and.right")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .disabled(bleManager.isScanning)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 40)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingRouteInput) {
                RouteInputView(
                    sourceAddress: $sourceAddress,
                    destinationAddress: $destinationAddress,
                    onStartNavigation: { source, destination in
                        calculateRoute(from: source, to: destination)
                    }
                )
            }
        }
        .onAppear {
            setupManagers()
        }
    }
    
    // MARK: - Connection Status View
    
    private var connectionStatusView: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bleManager.isConnected ? Color.green : Color.red)
                .frame(width: 16, height: 16)
                .shadow(color: bleManager.isConnected ? .green.opacity(0.5) : .red.opacity(0.5), 
                       radius: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
                
                if bleManager.isConnected {
                    Text(bleManager.peripheralName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if bleManager.signalStrength != 0 {
                        HStack(spacing: 4) {
                            Image(systemName: signalIcon(for: bleManager.signalStrength))
                                .font(.caption2)
                            Text("\(bleManager.signalStrength) dBm")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
    
    // MARK: - Navigation Status View
    
    private var navigationStatusView: some View {
        VStack(spacing: 20) {
            // Arrow Icon
            Image(systemName: arrowIcon(for: navEngine.currentIconID))
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            // Distance
            Text("\(navEngine.distanceToManeuver)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("meters")
                .font(.title3)
                .foregroundColor(.secondary)
            
            // Instruction
            Text(navEngine.currentInstruction)
                .font(.title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
    
    // MARK: - Placeholder View
    
    private var placeholderView: some View {
        VStack(spacing: 15) {
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Ready to Navigate")
                .font(.title2)
                .foregroundColor(.secondary)
            
            if bleManager.isConnected {
                Text("Tap 'Start Navigation' to begin")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Connect to bike computer first")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
        .frame(height: 300)
    }
    
    // MARK: - Helper Functions
    
    private func setupManagers() {
        navEngine.setBLEManager(bleManager)
        bleManager.startScanning()
        bleManager.startMonitoringRSSI()
    }
    
    private func calculateRoute(from source: String, to destination: String) {
        // Geocode addresses
        let geocoder = CLGeocoder()
        
        geocoder.geocodeAddressString(source) { sourcePlacemarks, error in
            guard let sourceLocation = sourcePlacemarks?.first?.location else { return }
            
            geocoder.geocodeAddressString(destination) { destPlacemarks, error in
                guard let destLocation = destPlacemarks?.first?.location else { return }
                
                // Create route request
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: sourceLocation.coordinate))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destLocation.coordinate))
                request.transportType = .automobile
                
                let directions = MKDirections(request: request)
                directions.calculate { response, error in
                    if let route = response?.routes.first {
                            // Use real navigation
                        // navEngine.startNavigation(with: route)
                            // Or use simulated navigation for testing
                        navEngine.startSimulatedNavigation(with: route)
                    } else if let error = error {
                        print("Error calculating route: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func signalIcon(for rssi: Int) -> String {
        if rssi > -50 {
            return "wifi"
        } else if rssi > -70 {
            return "wifi.slash"
        } else {
            return "wifi.exclamationmark"
        }
    }
    
    private func arrowIcon(for iconID: Int) -> String {
        switch iconID {
        case 1: return "arrow.turn.up.left"        // Slight left
        case 2: return "arrow.turn.up.left"        // Turn left
        case 3: return "arrow.turn.up.right"       // Slight right
        case 4: return "arrow.turn.up.right"       // Turn right
        case 5: return "arrow.uturn.left"          // U-turn
        case 6: return "arrow.merge"               // Merge
        case 7: return "arrow.triangle.2.circlepath" // Roundabout
        case 8: return "mappin.and.ellipse"        // Destination
        default: return "arrow.up"                 // Straight
        }
    }
}

// MARK: - Route Input Sheet

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    
    var onStartNavigation: (String, String) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Route Details")) {
                    TextField("From", text: $sourceAddress)
                        .textContentType(.fullStreetAddress)
                    
                    TextField("To", text: $destinationAddress)
                        .textContentType(.fullStreetAddress)
                }
                
                Section {
                    Button("Calculate Route") {
                        onStartNavigation(sourceAddress, destinationAddress)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(sourceAddress.isEmpty || destinationAddress.isEmpty)
                }
            }
            .navigationTitle("New Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
