//
//  ContentView.swift
//  BikeComputer
//
//  Main view demonstrating NavigationEngine and BLEManager integration
//

import SwiftUI
import MapKit
import Combine

struct ContentView: View {
    
    @StateObject private var bleManager = BLEManager()
    @StateObject private var navEngine = NavigationEngine()
    
    @State private var showingRouteInput = false
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var isCalculatingRoute = false
    @State private var calculationStatus = ""
    
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
                } else if isCalculatingRoute {
                    calculationStatusView
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
                    
                    if bleManager.isConnected {
                        Button(action: {
                            navEngine.sendTestNavigationData()
                        }) {
                            Label("Send Test Data", systemImage: "arrow.up.message.fill")
                                .font(.subheadline)
                                .foregroundColor(.green)
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
    
    // MARK: - Calculation Status View

    private var calculationStatusView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Calculating Route...")
                .font(.title2)
                .foregroundColor(.secondary)

            if !calculationStatus.isEmpty {
                Text(calculationStatus)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(height: 300)
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
        print("Starting route calculation from '\(source)' to '\(destination)'")

        isCalculatingRoute = true
        calculationStatus = "Searching for locations..."

        // Use MKLocalSearch for better results than geocoding
        let sourceSearchRequest = MKLocalSearch.Request()
        sourceSearchRequest.naturalLanguageQuery = source
        
        let sourceSearch = MKLocalSearch(request: sourceSearchRequest)
        sourceSearch.start { (response, error) in
            if let error = error {
                print("Error searching for source: \(error.localizedDescription)")
                self.calculationStatus = "Could not find starting location"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.isCalculatingRoute = false
                    self.calculationStatus = ""
                }
                return
            }
            
            guard let sourceItem = response?.mapItems.first else {
                print("No results for source location")
                self.calculationStatus = "Starting location not found"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.isCalculatingRoute = false
                    self.calculationStatus = ""
                }
                return
            }
            
            print("Source found: \(sourceItem.name ?? "Unknown") at \(sourceItem.placemark.coordinate.latitude), \(sourceItem.placemark.coordinate.longitude)")
            self.calculationStatus = "Finding destination..."
            
            let destinationSearchRequest = MKLocalSearch.Request()
            destinationSearchRequest.naturalLanguageQuery = destination
            
            let destinationSearch = MKLocalSearch(request: destinationSearchRequest)
            destinationSearch.start { (response, error) in
                if let error = error {
                    print("Error searching for destination: \(error.localizedDescription)")
                    self.calculationStatus = "Could not find destination"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.isCalculatingRoute = false
                        self.calculationStatus = ""
                    }
                    return
                }
                
                guard let destinationItem = response?.mapItems.first else {
                    print("No results for destination location")
                    self.calculationStatus = "Destination not found"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.isCalculatingRoute = false
                        self.calculationStatus = ""
                    }
                    return
                }
                
                print("Destination found: \(destinationItem.name ?? "Unknown") at \(destinationItem.placemark.coordinate.latitude), \(destinationItem.placemark.coordinate.longitude)")
                self.calculationStatus = "Calculating route..."
                
                // Now calculate the route
                let request = MKDirections.Request()
                request.source = sourceItem
                request.destination = destinationItem
                request.transportType = .automobile
                request.requestsAlternateRoutes = false
                
                let directions = MKDirections(request: request)
                directions.calculate { response, error in
                    if let error = error {
                        print("Error calculating route: \(error.localizedDescription)")
                        self.calculationStatus = "Route calculation failed"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self.isCalculatingRoute = false
                            self.calculationStatus = ""
                        }
                        return
                    }
                    
                    guard let route = response?.routes.first else {
                        print("No routes found")
                        self.calculationStatus = "No route available"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self.isCalculatingRoute = false
                            self.calculationStatus = ""
                        }
                        return
                    }
                    
                    print("Route calculated successfully!")
                    print("Distance: \(route.distance)m, ETA: \(route.expectedTravelTime)s")
                    print("Steps: \(route.steps.count)")
                    
                    for (index, step) in route.steps.enumerated() {
                        print("Step \(index): \(step.instructions) - \(step.distance)m")
                    }
                    
                    self.calculationStatus = "Starting navigation..."
                    
                    // Start simulated navigation with the real route
                    self.navEngine.startSimulatedNavigation(with: route)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.isCalculatingRoute = false
                        self.calculationStatus = ""
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

// MARK: - Route Input Sheet with Address Autocomplete

class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    
    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }
    
    func search(query: String) {
        completer.queryFragment = query
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Address search error: \(error.localizedDescription)")
    }
}

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    
    var onStartNavigation: (String, String) -> Void
    
    @StateObject private var sourceCompleter = AddressSearchCompleter()
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    
    @State private var isSourceFocused = false
    @State private var isDestinationFocused = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Input fields
                VStack(spacing: 16) {
                    // Source field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                        
                        TextField("Starting location", text: $sourceAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.fullStreetAddress)
                            .onChange(of: sourceAddress) { newValue in
                                sourceCompleter.search(query: newValue)
                                isSourceFocused = !newValue.isEmpty
                            }
                    }
                    
                    // Destination field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                        
                        TextField("Destination", text: $destinationAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.fullStreetAddress)
                            .onChange(of: destinationAddress) { newValue in
                                destinationCompleter.search(query: newValue)
                                isDestinationFocused = !newValue.isEmpty
                            }
                    }
                }
                .padding()
                
                // Suggestions
                if isSourceFocused && !sourceCompleter.suggestions.isEmpty {
                    suggestionsList(for: sourceCompleter.suggestions, isSource: true)
                } else if isDestinationFocused && !destinationCompleter.suggestions.isEmpty {
                    suggestionsList(for: destinationCompleter.suggestions, isSource: false)
                } else {
                    Spacer()
                }
                
                // Calculate button
                Button(action: {
                    onStartNavigation(sourceAddress, destinationAddress)
                    dismiss()
                }) {
                    Text("Calculate Route")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(sourceAddress.isEmpty || destinationAddress.isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(12)
                }
                .disabled(sourceAddress.isEmpty || destinationAddress.isEmpty)
                .padding()
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
    
    private func suggestionsList(for suggestions: [MKLocalSearchCompletion], isSource: Bool) -> some View {
        List(suggestions, id: \.self) { suggestion in
            Button(action: {
                let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                if isSource {
                    sourceAddress = fullAddress
                    isSourceFocused = false
                } else {
                    destinationAddress = fullAddress
                    isDestinationFocused = false
                }
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.body)
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
