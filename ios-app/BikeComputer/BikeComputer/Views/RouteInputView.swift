//
//  RouteInputView.swift
//  BikeComputer
//
//  Route input and destination search view
//

import SwiftUI
import MapKit
import Combine
import CoreLocation

// MARK: - Address Search Completer

class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    
    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        // Include both addresses and points of interest for street-level searches
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }
    
    func search(query: String) {
        completer.queryFragment = query
    }
    
    /// Update search region to prioritize results near user's location
    func updateRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Address search error: \(error.localizedDescription)")
    }
}

// MARK: - Route Input View

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    let currentAddress: String
    let currentLocation: CLLocation?  // User's exact GPS location for region-biased search
    
    var onStartNavigation: (RouteEndpoint, RouteEndpoint, MKDirectionsTransportType, Bool) -> Void
    
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @StateObject private var sourceCompleter = AddressSearchCompleter()
    
    @FocusState private var isDestinationFieldFocused: Bool
    @FocusState private var isSourceFieldFocused: Bool
    
    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var isEditingSource = false
    @State private var hasSelectedSource = false
    
    @State private var isTestMode = false
    @State private var selectedTransportType: MKDirectionsTransportType = RouteTransportTypes.cycling
    @State private var recentDestinationSearches: [String] = []

    private let recentDestinationSearchesKey = "routeInput.recentDestinationSearches"
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Fields
                VStack(spacing: 16) {
                    
                    // DESTINATION FIELD (Always visible)
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search for a destination", text: $destinationAddress)
                            .textContentType(.fullStreetAddress)
                            .focused($isDestinationFieldFocused)
                            .onChange(of: destinationAddress) { newValue in
                                if isSelectingFromSuggestion {
                                    isSelectingFromSuggestion = false
                                    return
                                }
                                
                                destinationCompleter.search(query: newValue)
                                if hasSelectedDestination {
                                    hasSelectedDestination = false
                                }
                            }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // SOURCE FIELD (Only shown after destination is selected)
                    if hasSelectedDestination {
                        if isEditingSource {
                            // EDIT MODE: Text Field
                            HStack(spacing: 12) {
                                Image(systemName: "location.fill")
                                    .foregroundColor(.blue)
                                
                                TextField("Search start location", text: $sourceAddress)
                                    .focused($isSourceFieldFocused)
                                    .onChange(of: sourceAddress) { newValue in
                                        if isSelectingFromSuggestion {
                                            isSelectingFromSuggestion = false
                                            return
                                        }
                                        sourceCompleter.search(query: newValue)
                                    }
                                
                                Button("Cancel") {
                                    isEditingSource = false
                                    isSourceFieldFocused = false
                                    // Revert to current address if user cancels and hasn't picked a valid one?
                                    // Actually, let's keep whatever is there, or revert if empty.
                                    if sourceAddress.isEmpty {
                                        sourceAddress = currentAddress
                                        hasSelectedSource = false
                                    }
                                }
                                .font(.caption)
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                            
                        } else {
                            // READ-ONLY MODE: Label (Tap to Edit)
                            Button(action: {
                                isEditingSource = true
                                // Default to current address text so they can edit it or see it
                                if sourceAddress.isEmpty || (!hasSelectedSource && sourceAddress != currentAddress) {
                                    sourceAddress = currentAddress
                                }
                                isSourceFieldFocused = true
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "location.fill")
                                        .foregroundColor(.blue)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hasSelectedSource ? "Start Location" : "Your Location")
                                            .foregroundColor(.primary)
                                            .font(.body)
                                        
                                        Text(hasSelectedSource ? sourceAddress : currentAddress)
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "pencil")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                            }
                        }
                    }
                }
                .padding()
                
                // Transport Type Selection (only shown after destination is selected)
                if hasSelectedDestination && !isEditingSource {
                    HStack(spacing: 12) {
                        TransportButton(
                            icon: "bicycle",
                            label: "Bike",
                            isSelected: selectedTransportType == RouteTransportTypes.cycling,
                            action: { selectedTransportType = RouteTransportTypes.cycling }
                        )

                        TransportButton(
                            icon: "car.fill",
                            label: "Drive",
                            isSelected: selectedTransportType == .automobile,
                            action: { selectedTransportType = .automobile }
                        )
                        
                        TransportButton(
                            icon: "figure.walk",
                            label: "Walk",
                            isSelected: selectedTransportType == .walking,
                            action: { selectedTransportType = .walking }
                        )
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    // Test Mode Toggle
                    Toggle(isOn: $isTestMode) {
                        HStack {
                            Image(systemName: "testtube.2")
                            .foregroundColor(.orange)
                            Text("Test Mode")
                            .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .tint(.orange)
                }
                
                // Suggestions List
                if isEditingSource {
                    // Show SOURCE suggestions
                    if !sourceCompleter.suggestions.isEmpty {
                        suggestionsList(for: sourceCompleter.suggestions) { suggestion in
                            let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                            isSelectingFromSuggestion = true
                            sourceAddress = fullAddress
                            hasSelectedSource = true
                            isEditingSource = false
                            isSourceFieldFocused = false
                        }
                    } else {
                        Spacer()
                    }
                    
                } else {
                    // Show DESTINATION suggestions (if searching)
                    if !hasSelectedDestination && !destinationCompleter.suggestions.isEmpty {
                        suggestionsList(for: destinationCompleter.suggestions) { suggestion in
                            let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                            isSelectingFromSuggestion = true
                            destinationAddress = fullAddress
                            hasSelectedDestination = true
                            isDestinationFieldFocused = false
                            saveRecentDestinationSearch(fullAddress)
                        }
                    } else if shouldShowRecentDestinationSearches {
                        recentDestinationList
                    } else {
                        Spacer()
                    }
                }
                
                // Go button (only shown after destination is selected & NOT editing)
                if hasSelectedDestination && !isEditingSource {
                    Button(action: {
                        let sourceEndpoint = RouteEndpointSelection.sourceEndpoint(
                            hasSelectedSource: hasSelectedSource,
                            sourceAddress: sourceAddress
                        )
                        saveRecentDestinationSearch(destinationAddress)
                        onStartNavigation(sourceEndpoint, .query(destinationAddress), selectedTransportType, isTestMode)
                        dismiss()
                    }) {
                        Text(isTestMode ? "Go (Test)" : "Go")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isTestMode ? Color.orange : Color.blue)
                            .cornerRadius(12)
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title2)
                    }
                }
            }
            .onAppear {
                // Auto-focus destination field when view appears
                isDestinationFieldFocused = true
                recentDestinationSearches = loadRecentDestinationSearches()
                
                // Set search region based on user's current location for better results
                if let location = currentLocation {
                    let region = MKCoordinateRegion(
                        center: location.coordinate,
                        latitudinalMeters: 50000,
                        longitudinalMeters: 50000
                    )
                    destinationCompleter.updateRegion(region)
                    sourceCompleter.updateRegion(region)
                }
            }
            .onDisappear {
                // Reset state when dismissed
                hasSelectedDestination = false
                destinationAddress = ""
                // Reset source state too? usually good idea.
                isEditingSource = false
                hasSelectedSource = false
            }
        }
    }
    
    private func suggestionsList(for suggestions: [MKLocalSearchCompletion], onSelect: @escaping (MKLocalSearchCompletion) -> Void) -> some View {
        List(suggestions, id: \.self) { suggestion in
            Button(action: {
                onSelect(suggestion)
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title)
                            .font(.body)
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }

    private var shouldShowRecentDestinationSearches: Bool {
        !hasSelectedDestination &&
        destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !recentDestinationSearches.isEmpty
    }

    private var recentDestinationList: some View {
        List {
            Section(header: Text("Recent Searches")) {
                ForEach(recentDestinationSearches, id: \.self) { search in
                    Button(action: {
                        isSelectingFromSuggestion = true
                        destinationAddress = search
                        hasSelectedDestination = true
                        isDestinationFieldFocused = false
                        saveRecentDestinationSearch(search)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.secondary)

                            Text(search)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(2)

                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func loadRecentDestinationSearches() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentDestinationSearchesKey) ?? []
    }

    private func saveRecentDestinationSearch(_ search: String) {
        let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var searches = loadRecentDestinationSearches()
        searches.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        searches.insert(normalized, at: 0)
        searches = Array(searches.prefix(5))
        UserDefaults.standard.set(searches, forKey: recentDestinationSearchesKey)
        recentDestinationSearches = searches
    }
}

// MARK: - Transport Button Component

struct TransportButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color(.systemGray6))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
    }
}
