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

// MARK: - Route Search Panel

private enum RouteSearchPanelField: Hashable {
    case destination
    case source
}

struct RouteSearchPanel: View {
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    @Binding var isExpanded: Bool

    @ObservedObject var destinationStore: SavedDestinationStore

    let currentAddress: String
    let currentLocation: CLLocation?
    let maxExpandedHeight: CGFloat
    var onStartNavigation: (RouteEndpoint, RouteEndpoint, MKDirectionsTransportType) -> Void

    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @StateObject private var sourceCompleter = AddressSearchCompleter()

    @FocusState private var focusedField: RouteSearchPanelField?

    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var isEditingSource = false
    @State private var hasSelectedSource = false
    @State private var selectedTransportType: MKDirectionsTransportType = RouteTransportTypes.cycling
    @State private var selectedDestination: SavedDestination?

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                collapsedSearchButton
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .frame(maxHeight: isExpanded ? maxExpandedHeight : nil, alignment: .bottom)
        .onAppear {
            updateSearchRegions()
        }
        .onChange(of: currentLocation) { _ in
            updateSearchRegions()
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                DispatchQueue.main.async {
                    focusedField = .destination
                }
            } else {
                focusedField = nil
                resetTransientState()
            }
        }
    }

    private var collapsedSearchButton: some View {
        Button(action: expandForDestinationSearch) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                Text(destinationAddress.isEmpty ? "Search for a destination" : destinationAddress)
                    .foregroundColor(destinationAddress.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search for a destination")
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            destinationSearchField

            if hasSelectedDestination {
                sourcePicker
                transportControls
                favoriteButton
            }

            searchResults

            if hasSelectedDestination && !isEditingSource {
                goButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var destinationSearchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search for a destination", text: $destinationAddress)
                .textContentType(.fullStreetAddress)
                .focused($focusedField, equals: .destination)
                .onTapGesture {
                    expandForDestinationSearch()
                }
                .onChange(of: destinationAddress) { newValue in
                    if isSelectingFromSuggestion {
                        isSelectingFromSuggestion = false
                        return
                    }

                    destinationCompleter.search(query: newValue)
                    selectedDestination = nil
                    if hasSelectedDestination {
                        hasSelectedDestination = false
                    }
                }

            if !destinationAddress.isEmpty {
                Button(action: clearDestination) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var sourcePicker: some View {
        if isEditingSource {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .foregroundColor(.blue)

                TextField("Search start location", text: $sourceAddress)
                    .focused($focusedField, equals: .source)
                    .onChange(of: sourceAddress) { newValue in
                        if isSelectingFromSuggestion {
                            isSelectingFromSuggestion = false
                            return
                        }
                        sourceCompleter.search(query: newValue)
                    }

                Button("Cancel") {
                    isEditingSource = false
                    focusedField = nil
                    if sourceAddress.isEmpty {
                        sourceAddress = currentAddress
                        hasSelectedSource = false
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Button(action: {
                isEditingSource = true
                if sourceAddress.isEmpty || (!hasSelectedSource && sourceAddress != currentAddress) {
                    sourceAddress = currentAddress
                }
                focusedField = .source
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
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
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
    }

    @ViewBuilder
    private var searchResults: some View {
        if isEditingSource {
            if !sourceCompleter.suggestions.isEmpty {
                suggestionsScroll(for: sourceCompleter.suggestions) { suggestion in
                    let fullAddress = formattedAddress(for: suggestion)
                    isSelectingFromSuggestion = true
                    sourceAddress = fullAddress
                    hasSelectedSource = true
                    isEditingSource = false
                    focusedField = nil
                }
            } else {
                Spacer(minLength: 0)
            }
        } else if !hasSelectedDestination && !destinationCompleter.suggestions.isEmpty {
            suggestionsScroll(for: destinationCompleter.suggestions) { suggestion in
                let fullAddress = formattedAddress(for: suggestion)
                selectDestination(SavedDestination(name: fullAddress))
            }
        } else if shouldShowSavedDestinations {
            savedDestinationsScroll
        } else {
            Spacer(minLength: 0)
        }
    }

    private var savedDestinationsScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !destinationStore.favoriteDestinations.isEmpty {
                    savedDestinationSectionHeader("Favorites")

                    ForEach(destinationStore.favoriteDestinations) { destination in
                        savedDestinationButton(destination, icon: "star.fill")
                    }
                }

                if !destinationStore.nonFavoriteRecentDestinations.isEmpty {
                    savedDestinationSectionHeader("Recent Searches")

                    ForEach(destinationStore.nonFavoriteRecentDestinations) { destination in
                        savedDestinationButton(destination, icon: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func savedDestinationSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func savedDestinationButton(_ destination: SavedDestination, icon: String) -> some View {
        Button(action: { selectDestination(destination) }) {
            SavedDestinationRow(destination: destination, icon: icon)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)

        Divider()
    }

    private var favoriteButton: some View {
        Button(action: toggleSelectedDestinationFavorite) {
            HStack(spacing: 10) {
                Image(systemName: isSelectedDestinationFavorite ? "star.fill" : "star")
                    .foregroundColor(isSelectedDestinationFavorite ? .yellow : .secondary)

                Text(isSelectedDestinationFavorite ? "Saved to Favorites" : "Save to Favorites")
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelectedDestinationFavorite ? "Remove from favorites" : "Save to favorites")
    }

    private var goButton: some View {
        Button(action: {
            let sourceEndpoint = RouteEndpointSelection.sourceEndpoint(
                hasSelectedSource: hasSelectedSource,
                sourceAddress: sourceAddress
            )
            guard let destination = activeDestination else { return }
            destinationStore.addRecent(destination)
            onStartNavigation(sourceEndpoint, destination.routeEndpoint, selectedTransportType)
        }) {
            Text("Go")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func suggestionsScroll(
        for suggestions: [MKLocalSearchCompletion],
        onSelect: @escaping (MKLocalSearchCompletion) -> Void
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(action: {
                        onSelect(suggestion)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.title)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    Divider()
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private var shouldShowSavedDestinations: Bool {
        !hasSelectedDestination &&
        destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!destinationStore.favoriteDestinations.isEmpty || !destinationStore.recentDestinations.isEmpty)
    }

    private func expandForDestinationSearch() {
        isExpanded = true
        focusedField = .destination
    }

    private func clearDestination() {
        destinationAddress = ""
        destinationCompleter.search(query: "")
        hasSelectedDestination = false
        selectedDestination = nil
        focusedField = .destination
    }

    private func formattedAddress(for suggestion: MKLocalSearchCompletion) -> String {
        suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
    }

    private func updateSearchRegions() {
        guard let location = currentLocation else { return }

        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 50000,
            longitudinalMeters: 50000
        )
        destinationCompleter.updateRegion(region)
        sourceCompleter.updateRegion(region)
    }

    private func resetTransientState() {
        isEditingSource = false
        hasSelectedSource = false
        hasSelectedDestination = false
        selectedDestination = nil
        destinationAddress = ""
        sourceAddress = ""
    }

    private var activeDestination: SavedDestination? {
        let name = destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if let selectedDestination,
           selectedDestination.name.caseInsensitiveCompare(name) == .orderedSame {
            return selectedDestination
        }
        return SavedDestination(name: name)
    }

    private var isSelectedDestinationFavorite: Bool {
        guard let destination = activeDestination else { return false }
        return destinationStore.isFavorite(destination)
    }

    private func selectDestination(_ destination: SavedDestination) {
        isSelectingFromSuggestion = true
        selectedDestination = destination
        destinationAddress = destination.name
        hasSelectedDestination = true
        focusedField = nil
        destinationStore.addRecent(destination)
    }

    private func toggleSelectedDestinationFavorite() {
        guard let destination = activeDestination else { return }
        destinationStore.toggleFavorite(destination)
    }
}

// MARK: - Route Input View

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    let currentAddress: String
    let currentLocation: CLLocation?  // User's exact GPS location for region-biased search

    @ObservedObject var destinationStore: SavedDestinationStore
    
    var onStartNavigation: (RouteEndpoint, RouteEndpoint, MKDirectionsTransportType) -> Void
    
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @StateObject private var sourceCompleter = AddressSearchCompleter()
    
    @FocusState private var isDestinationFieldFocused: Bool
    @FocusState private var isSourceFieldFocused: Bool
    
    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var isEditingSource = false
    @State private var hasSelectedSource = false
    
    @State private var selectedTransportType: MKDirectionsTransportType = RouteTransportTypes.cycling
    @State private var selectedDestination: SavedDestination?
    
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
                                selectedDestination = nil
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

                    favoriteButton
                        .padding(.horizontal)
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
                            let fullAddress = formattedAddress(for: suggestion)
                            selectDestination(SavedDestination(name: fullAddress))
                        }
                    } else if shouldShowSavedDestinations {
                        savedDestinationList
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
                        guard let destination = activeDestination else { return }
                        destinationStore.addRecent(destination)
                        onStartNavigation(sourceEndpoint, destination.routeEndpoint, selectedTransportType)
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
                selectedDestination = nil
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

    private var shouldShowSavedDestinations: Bool {
        !hasSelectedDestination &&
        destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!destinationStore.favoriteDestinations.isEmpty || !destinationStore.recentDestinations.isEmpty)
    }

    private var savedDestinationList: some View {
        List {
            if !destinationStore.favoriteDestinations.isEmpty {
                Section(header: Text("Favorites")) {
                    ForEach(destinationStore.favoriteDestinations) { destination in
                        Button(action: { selectDestination(destination) }) {
                            SavedDestinationRow(destination: destination, icon: "star.fill")
                        }
                    }
                }
            }

            if !destinationStore.nonFavoriteRecentDestinations.isEmpty {
                Section(header: Text("Recent Searches")) {
                    ForEach(destinationStore.nonFavoriteRecentDestinations) { destination in
                        Button(action: { selectDestination(destination) }) {
                            SavedDestinationRow(destination: destination, icon: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var favoriteButton: some View {
        Button(action: toggleSelectedDestinationFavorite) {
            HStack(spacing: 10) {
                Image(systemName: isSelectedDestinationFavorite ? "star.fill" : "star")
                    .foregroundColor(isSelectedDestinationFavorite ? .yellow : .secondary)

                Text(isSelectedDestinationFavorite ? "Saved to Favorites" : "Save to Favorites")
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelectedDestinationFavorite ? "Remove from favorites" : "Save to favorites")
    }

    private var activeDestination: SavedDestination? {
        let name = destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if let selectedDestination,
           selectedDestination.name.caseInsensitiveCompare(name) == .orderedSame {
            return selectedDestination
        }
        return SavedDestination(name: name)
    }

    private var isSelectedDestinationFavorite: Bool {
        guard let destination = activeDestination else { return false }
        return destinationStore.isFavorite(destination)
    }

    private func formattedAddress(for suggestion: MKLocalSearchCompletion) -> String {
        suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
    }

    private func selectDestination(_ destination: SavedDestination) {
        isSelectingFromSuggestion = true
        selectedDestination = destination
        destinationAddress = destination.name
        hasSelectedDestination = true
        isDestinationFieldFocused = false
        destinationStore.addRecent(destination)
    }

    private func toggleSelectedDestinationFavorite() {
        guard let destination = activeDestination else { return }
        destinationStore.toggleFavorite(destination)
    }
}

private struct SavedDestinationRow: View {
    let destination: SavedDestination
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(icon == "star.fill" ? .yellow : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let coordinateSubtitle = destination.coordinateSubtitle {
                    Text(coordinateSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
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
