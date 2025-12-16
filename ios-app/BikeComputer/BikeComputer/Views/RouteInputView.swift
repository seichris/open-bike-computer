//
//  RouteInputView.swift
//  BikeComputer
//
//  Route input and destination search view
//

import SwiftUI
import MapKit
import Combine

// MARK: - Address Search Completer

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

// MARK: - Route Input View

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    let currentAddress: String
    
    var onStartNavigation: (String, String, MKDirectionsTransportType) -> Void
    
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @FocusState private var isDestinationFieldFocused: Bool
    
    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var selectedTransportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking  // Fall back to walking for pre-iOS 18
        }
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Destination Search Field (always visible)
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search for a destination", text: $destinationAddress)
                            .textContentType(.fullStreetAddress)
                            .focused($isDestinationFieldFocused)
                            .onChange(of: destinationAddress) { newValue in
                                // Skip processing if we're programmatically selecting from suggestions
                                if isSelectingFromSuggestion {
                                    isSelectingFromSuggestion = false
                                    return
                                }
                                
                                destinationCompleter.search(query: newValue)
                                // Reset selection state when user starts typing again
                                if hasSelectedDestination {
                                    hasSelectedDestination = false
                                }
                            }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // From field (only shown after destination is selected)
                    if hasSelectedDestination {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.blue)
                            
                            Text(currentAddress)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                }
                .padding()
                
                // Transport Type Selection (only shown after destination is selected)
                if hasSelectedDestination {
                    HStack(spacing: 12) {
                        if #available(iOS 18.0, *) {
                            TransportButton(
                                icon: "bicycle",
                                label: "Bike",
                                isSelected: selectedTransportType == .cycling,
                                action: { selectedTransportType = .cycling }
                            )
                        }
                        
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
                }
                
                // Suggestions (shown while typing destination)
                if !hasSelectedDestination && !destinationCompleter.suggestions.isEmpty {
                    suggestionsList(for: destinationCompleter.suggestions)
                } else {
                    Spacer()
                }
                
                // Go button (only shown after destination is selected)
                if hasSelectedDestination {
                    Button(action: {
                        onStartNavigation(currentAddress, destinationAddress, selectedTransportType)
                        dismiss()
                    }) {
                        Text("Go")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
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
            }
            .onDisappear {
                // Reset state when dismissed
                hasSelectedDestination = false
                destinationAddress = ""
            }
        }
    }
    
    private func suggestionsList(for suggestions: [MKLocalSearchCompletion]) -> some View {
        List(suggestions, id: \.self) { suggestion in
            Button(action: {
                let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                isSelectingFromSuggestion = true
                destinationAddress = fullAddress
                hasSelectedDestination = true
                isDestinationFieldFocused = false
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

