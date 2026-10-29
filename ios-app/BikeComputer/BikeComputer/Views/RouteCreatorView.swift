import CoreLocation
import MapKit
import SwiftUI
import UIKit

private struct RouteCreatorStopTarget: Hashable {
    let stopID: UUID
}

private enum RouteCreatorTravelMode: String, CaseIterable, Identifiable {
    case cycling
    case driving
    case walking

    var id: Self { self }

    var title: String {
        switch self {
        case .cycling: "Bike"
        case .driving: "Drive"
        case .walking: "Walk"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .cycling: RouteTransportTypes.cycling
        case .driving: .automobile
        case .walking: .walking
        }
    }
}

/// Settings > Saved Routes > Create a Route. The rider orders a start, any
/// stops and a destination; MapKit calculates one leg per pair and the
/// stitched route is saved through the shared phone-only save sheet. Direct
/// navigation search never presents this view.
struct RouteCreatorView: View {
    @ObservedObject var library: PhoneRouteLibrary
    @ObservedObject var destinationStore: SavedDestinationStore
    let currentLocation: CLLocation?
    let onSaved: (OfflineRouteSaveResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var planner = MultiStopRoutePlanner()
    @State private var draft: MultiStopRouteDraft
    @State private var travelMode = RouteCreatorTravelMode.cycling
    @State private var editMode: EditMode = .inactive
    @State private var path: [RouteCreatorStopTarget] = []
    @State private var savingPlan: MultiStopRoutePlan?
    @State private var completedSave: OfflineRouteSaveResult?

    init(
        library: PhoneRouteLibrary,
        destinationStore: SavedDestinationStore,
        currentLocation: CLLocation?,
        onSaved: @escaping (OfflineRouteSaveResult) -> Void
    ) {
        self.library = library
        self.destinationStore = destinationStore
        self.currentLocation = currentLocation
        self.onSaved = onSaved
        _draft = State(initialValue: MultiStopRouteDraft(
            start: currentLocation.flatMap { MultiStopRoutePlace.currentLocation($0) }
        ))
    }

    private var request: MultiStopRouteRequest? {
        draft.request(transportType: travelMode.transportType)
    }

    private var hasChosenStops: Bool {
        draft.stops.count > MultiStopRouteDraft.minimumStops ||
            draft.stops.dropFirst().contains { $0.place != nil }
    }

    /// Save is offered only for the plan of the stops shown right now.
    private var currentPlan: MultiStopRoutePlan? {
        guard let plan = planner.readyPlan, plan.request == request else { return nil }
        return plan
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RouteCreatorMapView(stops: mapStops, route: currentPlan?.route)
                    .frame(height: 220)
                    .accessibilityLabel("Route preview map")
                Divider()
                List {
                    stopsSection
                    travelModeSection
                    routeSection
                }
                .environment(\.editMode, $editMode)
            }
            .navigationTitle("Create Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        planner.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { savingPlan = currentPlan }
                        .disabled(currentPlan == nil)
                        .accessibilityIdentifier("saveCreatedRoute")
                }
            }
            .navigationDestination(for: RouteCreatorStopTarget.self) { target in
                RouteStopSearchView(
                    title: draft.role(of: target.stopID)?.title ?? "Stop",
                    currentLocation: currentLocation,
                    destinationStore: destinationStore
                ) { place in
                    draft.setPlace(place, forStopID: target.stopID)
                }
            }
        }
        .onAppear { planner.plan(request) }
        .onChange(of: request) { planner.plan($0) }
        .onDisappear { planner.cancel() }
        // Chosen stops are not discarded by an accidental swipe; Cancel still is.
        .interactiveDismissDisabled(hasChosenStops)
        .sheet(item: $savingPlan, onDismiss: finishSave) { plan in
            RouteSaveSheet(library: library, draft: plan.draft) { result in
                linkFavoriteDestination(of: plan, to: result)
                completedSave = result
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var stopsSection: some View {
        Section {
            ForEach(Array(draft.stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop, index: index)
                    .deleteDisabled(!draft.canRemoveStop)
            }
            .onMove { draft.moveStops(fromOffsets: $0, toOffset: $1) }
            .onDelete { draft.removeStops(atOffsets: $0) }

            Button {
                if let stopID = draft.addStop() {
                    path.append(RouteCreatorStopTarget(stopID: stopID))
                }
            } label: {
                Label("Add Stop", systemImage: "plus.circle.fill")
            }
            .disabled(!draft.canAddStop)
            .accessibilityIdentifier("addRouteStop")

            Button {
                draft.reverse()
            } label: {
                Label("Reverse Route", systemImage: "arrow.up.arrow.down")
            }
        } header: {
            HStack {
                Text("Stops")
                Spacer()
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                .font(.subheadline)
                .textCase(nil)
                .accessibilityLabel(editMode == .active ? "Done Reordering" : "Reorder or Remove Stops")
            }
        } footer: {
            Text("Stops are visited in order. Tap Edit to reorder or remove them, or swipe a stop to remove it. Up to \(MultiStopRouteDraft.maximumStops) stops.")
        }
    }

    private func stopRow(_ stop: MultiStopRouteStop, index: Int) -> some View {
        let role = draft.role(at: index)
        return NavigationLink(value: RouteCreatorStopTarget(stopID: stop.id)) {
            HStack(spacing: 12) {
                RouteCreatorStopBadge(role: role)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stop.place?.label ?? "Choose a place")
                        .foregroundStyle(stop.place == nil ? .secondary : .primary)
                        .lineLimit(2)
                    if let subtitle = stop.place?.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role.title), \(stop.place?.label ?? "not chosen")")
        .accessibilityHint("Choose a place for this stop")
        .accessibilityActions {
            if index > 0 {
                Button("Move Earlier") { draft.moveStop(id: stop.id, by: -1) }
            }
            if index < draft.stops.count - 1 {
                Button("Move Later") { draft.moveStop(id: stop.id, by: 1) }
            }
            if draft.canRemoveStop {
                Button("Remove") { draft.removeStop(id: stop.id) }
            }
        }
    }

    private var travelModeSection: some View {
        Section("Travel Mode") {
            Picker("Travel Mode", selection: $travelMode) {
                ForEach(RouteCreatorTravelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var routeSection: some View {
        Section {
            routeStatus
            if let plan = currentPlan {
                ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                    legRow(index: index, leg: leg, plan: plan)
                }
            }
        } header: {
            Text("Route")
        } footer: {
            Text("Calculated with Apple Maps. Save keeps the route and its instructions on this iPhone for offline navigation. Offline map tiles and Watch transfer are not included.")
        }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let issue = draft.issue {
            Label(draft.message(for: issue), systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else if let plan = currentPlan {
            VStack(alignment: .leading, spacing: 4) {
                Text(RouteCreatorFormat.details(
                    distanceMeters: plan.route.distanceMeters,
                    travelTime: plan.route.expectedTravelTimeSeconds
                ))
                .font(.headline)
                Text("\(plan.legs.count) \(plan.legs.count == 1 ? "leg" : "legs") · \(plan.route.steps.count) instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("createdRouteSummary")
        } else if planner.request == request, let failure = planner.failure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Try Again") { planner.retry() }
                    .accessibilityIdentifier("retryCreatedRoute")
            }
            .accessibilityIdentifier("createdRouteFailure")
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(progressText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressText: String {
        if planner.request == request,
           case .calculating(let completed, let total) = planner.state,
           total > 1 {
            return "Calculating leg \(min(completed + 1, total)) of \(total)…"
        }
        return "Calculating route…"
    }

    private func legRow(
        index: Int,
        leg: NavigationRouteV1,
        plan: MultiStopRoutePlan
    ) -> some View {
        let places = plan.request.places
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(places[index].label) → \(places[index + 1].label)")
                .lineLimit(2)
            Text(RouteCreatorFormat.details(
                distanceMeters: leg.distanceMeters,
                travelTime: leg.expectedTravelTimeSeconds
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var mapStops: [RouteCreatorMapStop] {
        draft.stops.enumerated().compactMap { index, stop in
            stop.place.map {
                RouteCreatorMapStop(
                    id: stop.id,
                    coordinate: $0.clCoordinate,
                    title: $0.label,
                    role: draft.role(at: index)
                )
            }
        }
    }

    /// Keeps the previous Create a Route behavior: a route ending at a
    /// favorite becomes that favorite's saved route.
    private func linkFavoriteDestination(
        of plan: MultiStopRoutePlan,
        to result: OfflineRouteSaveResult
    ) {
        guard case .saved(let destination)? = plan.request.places.last?.origin,
              destinationStore.isFavorite(destination) else { return }
        destinationStore.addFavorite(destination, savedRouteID: result.summary.id)
    }

    /// Runs after the save sheet is gone, so the parent can dismiss this
    /// creator without racing the nested sheet's own dismissal.
    private func finishSave() {
        guard let result = completedSave else { return }
        completedSave = nil
        planner.cancel()
        onSaved(result)
    }
}

private struct RouteCreatorStopBadge: View {
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

private enum RouteCreatorFormat {
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

/// Picks one stop: current location, a favorite or recent place, or MapKit
/// search through the same completer as destination search. A pick becomes a
/// stop only after it resolves to a coordinate.
private struct RouteStopSearchView: View {
    let title: String
    let currentLocation: CLLocation?
    @ObservedObject var destinationStore: SavedDestinationStore
    let onSelect: (MultiStopRoutePlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = AddressSearchCompleter()
    @StateObject private var resolver = RouteStopPlaceResolver()
    @State private var query = ""

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
        List {
            if let error = resolver.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if trimmedQuery.isEmpty {
                Section {
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
                    .disabled(currentLocationPlace == nil)
                }
                savedSection("Favorites", destinationStore.favoriteDestinations, icon: "star.fill")
                savedSection(
                    "Recent Searches",
                    destinationStore.nonFavoriteRecentDestinations,
                    icon: "clock.arrow.circlepath"
                )
            } else {
                Section {
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
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search for a place"
        )
        .onChange(of: query) { newValue in
            resolver.cancel()
            resolver.clearError()
            completer.search(query: newValue)
        }
        .onAppear {
            if let searchRegion { completer.updateRegion(searchRegion) }
        }
        .onDisappear {
            resolver.cancel()
            completer.search(query: "")
        }
    }

    @ViewBuilder
    private func savedSection(
        _ title: String,
        _ destinations: [SavedDestination],
        icon: String
    ) -> some View {
        if !destinations.isEmpty {
            Section(title) {
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
                }
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
        case .currentLocation:
            break
        case .search:
            destinationStore.addRecent(SavedDestination(
                name: place.label,
                coordinate: place.clCoordinate
            ))
        case .saved(let destination):
            destinationStore.addRecent(destination)
        }
        onSelect(place)
        dismiss()
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
        .contentShape(Rectangle())
    }
}

private struct RouteCreatorMapStop: Equatable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String
    let role: MultiStopRouteStopRole

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.role == rhs.role &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

private final class RouteCreatorStopAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let role: MultiStopRouteStopRole

    init(_ stop: RouteCreatorMapStop) {
        coordinate = stop.coordinate
        title = stop.title
        role = stop.role
    }
}

/// Display-only preview: stop pins in MapKit space and the stitched WGS-84
/// geometry converted once per plan, like a saved-route preview.
private struct RouteCreatorMapView: UIViewRepresentable {
    let stops: [RouteCreatorMapStop]
    let route: NavigationRouteV1?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(mapView, stops: stops, route: route)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let markerIdentifier = "routeCreatorStop"
        private var stops: [RouteCreatorMapStop] = []
        private var routeID: UUID?
        private var polyline: MKPolyline?

        func update(
            _ mapView: MKMapView,
            stops: [RouteCreatorMapStop],
            route: NavigationRouteV1?
        ) {
            var changed = false
            if stops != self.stops {
                mapView.removeAnnotations(mapView.annotations)
                mapView.addAnnotations(stops.map { RouteCreatorStopAnnotation($0) })
                self.stops = stops
                changed = true
            }
            if route?.id != routeID {
                if let polyline { mapView.removeOverlay(polyline) }
                polyline = route.flatMap { Self.polyline(for: $0) }
                if let polyline { mapView.addOverlay(polyline, level: .aboveRoads) }
                routeID = route?.id
                changed = true
            }
            if changed { fit(mapView) }
        }

        private func fit(_ mapView: MKMapView) {
            var rect = polyline?.boundingMapRect ?? .null
            for stop in stops {
                let point = MKMapPoint(stop.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            guard !rect.isNull else { return }
            let minimumSide = 2_000 * MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude)
            if rect.width < minimumSide || rect.height < minimumSide {
                rect = rect.insetBy(
                    dx: -max(minimumSide - rect.width, 0) / 2,
                    dy: -max(minimumSide - rect.height, 0) / 2
                )
            }
            mapView.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
                animated: mapView.window != nil
            )
        }

        private static func polyline(for route: NavigationRouteV1) -> MKPolyline? {
            let coordinates = route.points.map {
                SavedRouteMapPreviewFactory.displayCoordinate(CLLocationCoordinate2D(
                    latitude: $0.latitude,
                    longitude: $0.longitude
                ))
            }
            guard coordinates.count >= 2 else { return nil }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let stop = annotation as? RouteCreatorStopAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.markerIdentifier)
                as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: stop, reuseIdentifier: Self.markerIdentifier)
            view.annotation = stop
            view.canShowCallout = true
            view.displayPriority = .required
            switch stop.role {
            case .start:
                view.markerTintColor = .systemGreen
                view.glyphText = nil
                view.glyphImage = UIImage(systemName: "circle.fill")
            case .stop(let number):
                view.markerTintColor = .systemOrange
                view.glyphImage = nil
                view.glyphText = "\(number)"
            case .destination:
                view.markerTintColor = .systemRed
                view.glyphText = nil
                view.glyphImage = UIImage(systemName: "flag.checkered")
            }
            return view
        }
    }
}
