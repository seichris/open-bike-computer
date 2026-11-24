import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Create a Route in the main map's bottom panel. Stops are reordered with
/// their drag handles and removed with their clear button or from their pin;
/// touch and hold on the map adds a stop.
struct RouteCreatorPanel: View {
    @ObservedObject var session: RouteCreationSession
    @ObservedObject var destinationStore: SavedDestinationStore
    let currentLocation: CLLocation?
    @Binding var isExpanded: Bool
    let maxHeight: CGFloat
    let onSave: () -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var stopRowHeight: CGFloat = 52
    /// Everything in the expanded panel except the stops list.
    @ScaledMetric(relativeTo: .body) private var expandedChromeHeight: CGFloat = 330

    var body: some View {
        CappedHeightLayout(maxHeight: maxHeight) {
            panelContent
        }
        .mapOverlayGlassSurface(cornerRadius: 24)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isExpanded)
        .accessibilityIdentifier("routeCreatorPanel")
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            if let stopID = session.searchingStopID,
               let role = session.draft.role(of: stopID) {
                RouteStopSearchContent(
                    title: role.title,
                    currentLocation: currentLocation,
                    destinationStore: destinationStore,
                    onSelect: { session.choose($0) },
                    onCancel: { session.cancelSearch() }
                )
                .id(stopID)
            } else {
                grabber
                if isExpanded {
                    expandedContent
                } else {
                    collapsedContent
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Collapsed

    private var grabber: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide Stops" : "Show Stops")
    }

    private var collapsedContent: some View {
        HStack(spacing: 12) {
            Button {
                isExpanded = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routeTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the stops")
            saveButton
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stopsList
            // Large text scrolls the details instead of squeezing them.
            ViewThatFits(in: .vertical) {
                routeDetails
                ScrollView {
                    routeDetails
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var stopActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                addStopButton
                Spacer()
                reverseButton
            }
            VStack(alignment: .leading, spacing: 10) {
                addStopButton
                reverseButton
            }
        }
        .font(.subheadline)
    }

    private var addStopButton: some View {
        Button {
            session.addStopAndSearch()
        } label: {
            Label("Add Stop", systemImage: "plus.circle.fill")
        }
        .disabled(!session.draft.canAddStop)
        .accessibilityIdentifier("addRouteStop")
    }

    private var reverseButton: some View {
        Button {
            session.reverse()
        } label: {
            Label("Reverse Route", systemImage: "arrow.up.arrow.down")
        }
    }

    private var routeDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            stopActions
            if let notice = session.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Travel Mode", selection: $session.travelMode) {
                ForEach(RouteCreatorTravelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            routeStatus
            Text("Calculated with Apple Maps. Save keeps the route and its instructions on this iPhone for offline navigation. Offline map tiles and Watch transfer are not included.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        ZStack {
            // At accessibility sizes the buttons need the whole row.
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Create Route")
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                saveButton
                    .fontWeight(.semibold)
            }
        }
    }

    private var saveButton: some View {
        Button("Save", action: onSave)
            .disabled(session.currentPlan == nil)
            .accessibilityIdentifier("saveCreatedRoute")
    }

    private var stopsListHeight: CGFloat {
        let full = CGFloat(session.draft.stops.count) * stopRowHeight
        let available = max(maxHeight - expandedChromeHeight, stopRowHeight * 2)
        return min(full, available)
    }

    private var stopsListScrolls: Bool {
        CGFloat(session.draft.stops.count) * stopRowHeight > stopsListHeight + 1
    }

    /// A list kept in edit mode shows drag handles without an Edit button;
    /// rows remove themselves with their clear button instead of swipes.
    private var stopsList: some View {
        List {
            ForEach(Array(session.draft.stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop, index: index)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .deleteDisabled(true)
            }
            .onMove { session.moveStops(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(!stopsListScrolls)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, stopRowHeight)
        .frame(height: stopsListHeight)
    }

    private func stopRow(_ stop: MultiStopRouteStop, index: Int) -> some View {
        let role = session.draft.role(at: index)
        let canRemove = session.draft.canRemoveStop
        return HStack(spacing: 8) {
            Button {
                session.search(forStopID: stop.id)
            } label: {
                HStack(spacing: 12) {
                    RouteCreatorStopBadge(role: role)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(stop.place?.label ?? "Search or hold the map")
                            .foregroundStyle(stop.place == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(role.title), \(stop.place?.label ?? "not chosen")")
            .accessibilityHint("Choose a place for this stop")
            .accessibilityActions {
                if index > 0 {
                    Button("Move Earlier") { session.moveStop(id: stop.id, by: -1) }
                }
                if index < session.draft.stops.count - 1 {
                    Button("Move Later") { session.moveStop(id: stop.id, by: 1) }
                }
            }

            if stop.place != nil || canRemove {
                Button {
                    session.removeOrClear(stopID: stop.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(canRemove ? "Remove \(role.title)" : "Clear \(role.title)")
            }
        }
        .frame(minHeight: stopRowHeight)
    }

    // MARK: - Status

    @ViewBuilder
    private var routeStatus: some View {
        if let issue = session.draft.issue {
            Label(session.draft.message(for: issue), systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let plan = session.currentPlan {
            VStack(alignment: .leading, spacing: 4) {
                Text(RouteCreatorFormat.details(
                    distanceMeters: plan.route.distanceMeters,
                    travelTime: plan.route.expectedTravelTimeSeconds
                ))
                .font(.headline)
                Text("\(plan.legs.count) \(plan.legs.count == 1 ? "leg" : "legs") · \(plan.route.steps.count) instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice = plan.carDirectionsNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("createdRouteSummary")
        } else if let failure = session.currentFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                // Joining or size failures need different stops, not a retry.
                if failure.legIndex != nil {
                    Button("Try Again") { session.retry() }
                        .accessibilityIdentifier("retryCreatedRoute")
                }
            }
            .accessibilityIdentifier("createdRouteFailure")
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressText: String {
        if session.planner.request == session.request,
           case .calculating(let completed, let total) = session.planner.state,
           total > 1 {
            return "Calculating leg \(min(completed + 1, total)) of \(total)…"
        }
        return "Calculating route…"
    }

    private var routeTitle: String {
        let labels = session.draft.stops.compactMap(\.place?.label)
        guard labels.count == session.draft.stops.count else { return "Create Route" }
        return MultiStopRouteNaming.defaultName(stopLabels: labels)
    }

    private var statusLine: String {
        if let issue = session.draft.issue {
            return session.draft.message(for: issue)
        }
        if let plan = session.currentPlan {
            return RouteCreatorFormat.details(
                distanceMeters: plan.route.distanceMeters,
                travelTime: plan.route.expectedTravelTimeSeconds
            ) + " · " + session.travelMode.title
        }
        if let failure = session.currentFailure {
            return failure.message
        }
        return progressText
    }
}

extension RouteCreationSession {
    /// The stops and the planned route as the main map draws them.
    func mapInput(polylines: RouteCreationPolylineCache) -> MapRouteCreation? {
        guard isActive else { return nil }
        let stops = draft.stops.enumerated().compactMap { index, stop -> MapRouteCreation.Stop? in
            guard let place = stop.place else { return nil }
            let kind: MapRouteCreation.Stop.Kind
            switch draft.role(at: index) {
            case .start: kind = .start
            case .stop(let number): kind = .stop(number)
            case .destination: kind = .destination
            }
            return MapRouteCreation.Stop(
                id: stop.id,
                coordinate: place.clCoordinate,
                label: place.label,
                kind: kind
            )
        }
        let route = currentPlan?.route
        return MapRouteCreation(
            stops: stops,
            routeID: route?.id,
            polyline: route.flatMap { polylines.polyline(for: $0) }
        )
    }
}

/// Converts each planned route to display space once, not on every render.
@MainActor
final class RouteCreationPolylineCache {
    private var cached: (id: UUID, polyline: MKPolyline)?

    func polyline(for route: NavigationRouteV1) -> MKPolyline? {
        if let cached, cached.id == route.id { return cached.polyline }
        let coordinates = route.points.map {
            SavedRouteMapPreviewFactory.displayCoordinate(CLLocationCoordinate2D(
                latitude: $0.latitude,
                longitude: $0.longitude
            ))
        }
        guard coordinates.count >= 2 else { return nil }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        cached = (route.id, polyline)
        return polyline
    }
}

/// Names a dropped pin from Apple Maps reverse geocoding.
enum RouteDroppedPinNamer {
    @MainActor
    static func name(for coordinate: CLLocationCoordinate2D) async -> RouteDroppedPinName? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, *) {
            return await modernName(for: location)
        }
        return await legacyName(for: location)
    }

    @available(iOS 26.0, *)
    @MainActor
    private static func modernName(for location: CLLocation) async -> RouteDroppedPinName? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        let addresses = item.addressRepresentations
        let title = trimmed(item.name)
            ?? trimmed(addresses?.fullAddress(includingRegion: false, singleLine: true))
        guard let title else { return nil }
        let subtitle = trimmed(addresses?.cityWithContext)
        return RouteDroppedPinName(title: title, subtitle: subtitle == title ? nil : subtitle)
    }

    @available(iOS, introduced: 5.0, obsoleted: 26.0)
    @MainActor
    private static func legacyName(for location: CLLocation) async -> RouteDroppedPinName? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
              let title = trimmed(placemark.name) ?? trimmed(placemark.thoroughfare) else { return nil }
        let subtitle = [placemark.locality, placemark.administrativeArea]
            .compactMap(trimmed)
            .joined(separator: ", ")
        return RouteDroppedPinName(title: title, subtitle: subtitle.isEmpty ? nil : subtitle)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

struct RouteCreatorStopBadge: View {
    let role: MultiStopRouteStopRole

    var body: some View {
        Group {
            switch role {
            case .start:
                Image(systemName: "circle.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            case .stop(let number):
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.orange))
            case .destination:
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 28)
        .accessibilityHidden(true)
    }
}

enum RouteCreatorFormat {
    static func details(distanceMeters: Double, travelTime: Double?) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        let distance = formatter.string(from: Measurement(
            value: distanceMeters / 1_000,
            unit: UnitLength.kilometers
        ))
        guard let travelTime, travelTime.isFinite, travelTime > 0 else { return distance }
        let duration = DateComponentsFormatter()
        duration.unitsStyle = .abbreviated
        duration.allowedUnits = travelTime >= 3_600 ? [.hour, .minute] : [.minute]
        guard let time = duration.string(from: max(travelTime, 60)) else { return distance }
        return "\(distance) · \(time)"
    }
}

/// Picks one stop inside the panel: current location, a favorite or recent
/// place, or MapKit search through the same completer as destination search.
/// A pick becomes a stop only after it resolves to a coordinate.
private struct RouteStopSearchContent: View {
    let title: String
    let currentLocation: CLLocation?
    @ObservedObject var destinationStore: SavedDestinationStore
    let onSelect: (MultiStopRoutePlace) -> Void
    let onCancel: () -> Void

    @StateObject private var completer = AddressSearchCompleter()
    @StateObject private var resolver = RouteStopPlaceResolver()
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentLocationPlace: MultiStopRoutePlace? {
        currentLocation.flatMap { MultiStopRoutePlace.currentLocation($0) }
    }

    private var searchRegion: MKCoordinateRegion? {
        currentLocation.map {
            MKCoordinateRegion(
                center: $0.coordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for \(title)", text: $query)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("routeStopSearchField")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                Button("Cancel", role: .cancel, action: onCancel)
            }

            if let error = resolver.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            CappedHeightLayout(maxHeight: 300) {
                ViewThatFits(in: .vertical) {
                    results
                    ScrollView {
                        results
                    }
                }
            }

            Text("Or touch and hold the map.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onChange(of: query) { newValue in
            resolver.cancel()
            resolver.clearError()
            completer.search(query: newValue)
        }
        .onAppear {
            if let searchRegion { completer.updateRegion(searchRegion) }
            isSearchFocused = true
        }
        .onDisappear {
            resolver.cancel()
            completer.search(query: "")
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if trimmedQuery.isEmpty {
                Button {
                    if let place = currentLocationPlace { choose(place) }
                } label: {
                    RouteStopPlaceRow(
                        icon: "location.fill",
                        iconColor: .blue,
                        title: MultiStopRoutePlace.currentLocationLabel,
                        subtitle: currentLocationPlace == nil ? "Location unavailable" : nil,
                        isResolving: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(currentLocationPlace == nil)
                savedSection(
                    "Favorites",
                    destinationStore.favoriteDestinations,
                    icon: "star.fill"
                )
                savedSection(
                    "Recent Searches",
                    destinationStore.nonFavoriteRecentDestinations,
                    icon: "clock.arrow.circlepath"
                )
            } else {
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    Button {
                        resolve(suggestion)
                    } label: {
                        RouteStopPlaceRow(
                            icon: "mappin.circle.fill",
                            iconColor: .secondary,
                            title: suggestion.title,
                            subtitle: suggestion.subtitle.isEmpty ? nil : suggestion.subtitle,
                            isResolving: resolver.pendingID == Self.resolutionID(suggestion)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func savedSection(
        _ title: String,
        _ destinations: [SavedDestination],
        icon: String
    ) -> some View {
        if !destinations.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(destinations) { destination in
                Button {
                    chooseSaved(destination)
                } label: {
                    RouteStopPlaceRow(
                        icon: icon,
                        iconColor: icon == "star.fill" ? .yellow : .secondary,
                        title: destination.name,
                        subtitle: destination.coordinateSubtitle,
                        isResolving: resolver.pendingID == "saved:\(destination.id.uuidString)"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func resolutionID(_ suggestion: MKLocalSearchCompletion) -> String {
        "completion:\(suggestion.title)|\(suggestion.subtitle)"
    }

    private func resolve(_ suggestion: MKLocalSearchCompletion) {
        resolver.resolve(
            MKLocalSearch.Request(completion: suggestion),
            id: Self.resolutionID(suggestion),
            label: suggestion.title,
            subtitle: suggestion.subtitle,
            origin: .search,
            onResolved: choose
        )
    }

    private func chooseSaved(_ destination: SavedDestination) {
        if let place = MultiStopRoutePlace.saved(destination) {
            choose(place)
            return
        }
        // Older history kept only a name; resolve it like destination search.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination.name
        if let searchRegion { request.region = searchRegion }
        resolver.resolve(
            request,
            id: "saved:\(destination.id.uuidString)",
            label: destination.name,
            origin: .saved(destination),
            onResolved: choose
        )
    }

    private func choose(_ place: MultiStopRoutePlace) {
        switch place.origin {
        case .currentLocation, .droppedPin:
            break
        case .search:
            destinationStore.addRecent(SavedDestination(
                name: place.label,
                coordinate: place.clCoordinate
            ))
        case .saved(let destination):
            destinationStore.addRecent(destination)
        }
        isSearchFocused = false
        onSelect(place)
    }
}

/// Takes its content's natural height up to `maxHeight` and never more, so
/// a short panel stays short; taller content gets `maxHeight` to scroll in.
/// A plain `frame(maxHeight:)` would grow to any larger height it is offered.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let cap = min(maxHeight, proposal.height ?? .infinity)
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = min(natural.height, cap)
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: size.width, height: min(size.height, height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct RouteStopPlaceRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isResolving: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isResolving {
                ProgressView()
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
