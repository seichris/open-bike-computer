//
//  MapView.swift
//  BikeComputer
//
//  Map display components
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Destination Annotation

final class DestinationAnnotation: MKPointAnnotation {
    var destination: SavedDestination?
    var calloutAddress = ""
}

@MainActor
enum DestinationCalloutLabel {
    static let preferredWidth: CGFloat = 240

    static func make(address: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = preferredWidth
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        update(label, address: address)
        return label
    }

    static func update(_ label: UILabel, address: String) {
        label.text = address
        label.invalidateIntrinsicContentSize()
    }
}

// MARK: - Simulated Position Annotation

class SimulatedPositionAnnotation: MKPointAnnotation {}

// MARK: - Map View Container

@MainActor
protocol MapAppearanceConfigurationTarget: AnyObject {
    var preferredConfiguration: MKMapConfiguration { get set }
}

extension MKMapView: MapAppearanceConfigurationTarget {}

@MainActor
final class MapViewControlState: ObservableObject {
    static let pitchedThreshold: CLLocationDegrees = 5
    static let defaultPitchedAngle: CLLocationDegrees = 45

    @Published private(set) var mapView: MKMapView?
    @Published private(set) var isPitched = false

    static func isPitched(_ pitch: CLLocationDegrees) -> Bool {
        pitch > pitchedThreshold
    }

    static func targetPitch(
        isCurrentlyPitched: Bool
    ) -> CLLocationDegrees {
        isCurrentlyPitched ? 0 : defaultPitchedAngle
    }

    func connect(to mapView: MKMapView) {
        if self.mapView !== mapView {
            self.mapView = mapView
        }
        updatePitch(from: mapView)
    }

    func disconnect(from mapView: MKMapView) {
        guard self.mapView === mapView else { return }
        self.mapView = nil
        isPitched = false
    }

    func updatePitch(from mapView: MKMapView) {
        let newValue = Self.isPitched(mapView.camera.pitch)
        guard newValue != isPitched else { return }
        isPitched = newValue
    }

    func togglePitch() {
        guard let mapView else { return }

        let currentCamera = mapView.camera
        let camera = MKMapCamera(
            lookingAtCenter: currentCamera.centerCoordinate,
            fromDistance: currentCamera.centerCoordinateDistance,
            pitch: Self.targetPitch(isCurrentlyPitched: isPitched),
            heading: currentCamera.heading
        )
        mapView.setCamera(camera, animated: true)
    }
}

struct MapCompassControl: UIViewRepresentable {
    @ObservedObject var controlState: MapViewControlState

    func makeUIView(context: Context) -> MKCompassButton {
        let compass = MKCompassButton(mapView: controlState.mapView)
        compass.compassVisibility = .adaptive
        return compass
    }

    func updateUIView(_ compass: MKCompassButton, context: Context) {
        compass.mapView = controlState.mapView
        compass.compassVisibility = .adaptive
    }
}

struct MapRouteAlternative: Identifiable, Equatable {
    let id: UUID
    let route: MKRoute

    static func == (
        lhs: MapRouteAlternative,
        rhs: MapRouteAlternative
    ) -> Bool {
        lhs.id == rhs.id && lhs.route === rhs.route
    }
}

struct MapRouteSelectionCandidate {
    let id: UUID
    let points: [CGPoint]
}

enum MapRouteSelectionPolicy {
    static let hitTolerance: CGFloat = 24
    private static let overlapTolerance: CGFloat = 2

    static func routeID(
        nearestTo tapPoint: CGPoint,
        candidates: [MapRouteSelectionCandidate],
        preferredRouteID: UUID? = nil,
        tolerance: CGFloat = hitTolerance
    ) -> UUID? {
        guard tolerance >= 0 else { return nil }

        let matches = candidates.compactMap { candidate in
            minimumDistance(from: tapPoint, to: candidate.points).map {
                (id: candidate.id, distance: $0)
            }
        }.filter {
            $0.distance <= tolerance
        }
        guard let nearest = matches.min(by: {
            $0.distance < $1.distance
        }) else {
            return nil
        }

        if let preferredRouteID,
           let preferred = matches.first(where: {
               $0.id == preferredRouteID
           }), preferred.distance <= nearest.distance + overlapTolerance {
            return preferred.id
        }
        return nearest.id
    }

    private static func minimumDistance(
        from point: CGPoint,
        to polyline: [CGPoint]
    ) -> CGFloat? {
        guard let first = polyline.first else { return nil }
        guard polyline.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }

        return zip(polyline, polyline.dropFirst()).reduce(nil) {
            (nearest: CGFloat?, segment) in
            let distance = distance(
                from: point,
                toSegmentFrom: segment.0,
                to: segment.1
            )
            return min(nearest ?? distance, distance)
        }
    }

    private static func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = (
            (point.x - start.x) * deltaX +
                (point.y - start.y) * deltaY
        ) / lengthSquared
        let clampedProjection = min(max(projection, 0), 1)
        let nearestPoint = CGPoint(
            x: start.x + clampedProjection * deltaX,
            y: start.y + clampedProjection * deltaY
        )
        return hypot(
            point.x - nearestPoint.x,
            point.y - nearestPoint.y
        )
    }
}

struct MapViewContainer: UIViewRepresentable {
    let appearance: IPhoneMapAppearance
    let controlState: MapViewControlState
    let location: CLLocation?
    let route: MKRoute?
    let routeAlternatives: [MapRouteAlternative]
    let selectedRouteAlternativeID: UUID?
    let routePlanningBottomPadding: CGFloat
    let simulatedPosition: CLLocationCoordinate2D?
    let isSimulationMode: Bool
    let isNavigating: Bool
    let isUserLocationAuthorized: Bool
    let offlineMapSelectionFrame: CGRect?
    let onMapTapped: (() -> Void)?
    let onRouteAlternativeSelected: ((UUID) -> Void)?
    let onOfflineMapSelectionBoundsChanged: ((OfflineMapBounds) -> Void)?
    let onDestinationSelected: ((SavedDestination, CLLocation?) -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.isPitchEnabled = true
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            mapView.pitchButtonVisibility = .hidden
        }
        context.coordinator.applyAppearanceIfNeeded(
            appearance,
            to: mapView
        )
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = isUserLocationAuthorized
        mapView.userTrackingMode = isUserLocationAuthorized ? .follow : .none
        
        // Configure map appearance
        mapView.showsCompass = false
        mapView.showsScale = true
        context.coordinator.controlState = controlState
        context.coordinator.installTrackingControl(on: mapView)
        
        // Add long press gesture recognizer
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        
        // Store the callback in coordinator
        context.coordinator.onMapTapped = onMapTapped
        context.coordinator.onRouteAlternativeSelected =
            onRouteAlternativeSelected
        context.coordinator.onOfflineMapSelectionBoundsChanged = onOfflineMapSelectionBoundsChanged
        context.coordinator.onDestinationSelected = onDestinationSelected
        context.coordinator.isNavigating = isNavigating
        context.coordinator.isSimulationMode = isSimulationMode
        context.coordinator.isUserLocationAuthorized = isUserLocationAuthorized
        context.coordinator.simulatedPosition = simulatedPosition

        DispatchQueue.main.async {
            controlState.connect(to: mapView)
        }
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.applyAppearanceIfNeeded(
            appearance,
            to: uiView
        )
        let isOfflineMapSelectionActive = offlineMapSelectionFrame != nil
        let isFreePanActive = context.coordinator.isFreePanActive(
            mapView: uiView,
            isOfflineMapSelectionActive: isOfflineMapSelectionActive
        )

        // Store reference to map view in coordinator
        context.coordinator.mapView = uiView
        context.coordinator.controlState = controlState
        context.coordinator.onMapTapped = onMapTapped
        context.coordinator.onRouteAlternativeSelected =
            onRouteAlternativeSelected
        context.coordinator.offlineMapSelectionFrame = offlineMapSelectionFrame
        context.coordinator.onOfflineMapSelectionBoundsChanged = onOfflineMapSelectionBoundsChanged
        context.coordinator.onDestinationSelected = onDestinationSelected
        context.coordinator.isNavigating = isNavigating
        context.coordinator.isSimulationMode = isSimulationMode
        context.coordinator.isUserLocationAuthorized = isUserLocationAuthorized
        context.coordinator.simulatedPosition = simulatedPosition
        context.coordinator.updateControlVisibility(isNavigating: isNavigating)
        if controlState.mapView !== uiView {
            DispatchQueue.main.async {
                controlState.connect(to: uiView)
            }
        }
        context.coordinator.updateOfflineMapSelectionBounds()
        
        context.coordinator.updateInitialRegionIfNeeded(
            mapView: uiView,
            location: location,
            simulatedPosition: simulatedPosition,
            isSimulationMode: isSimulationMode,
            isFreePanActive: isFreePanActive
        )
        
        context.coordinator.updateRouteOverlays(
            on: uiView,
            route: route,
            alternatives: routeAlternatives,
            selectedAlternativeID: selectedRouteAlternativeID,
            routePlanningBottomPadding: routePlanningBottomPadding,
            location: location,
            simulatedPosition: simulatedPosition,
            isSimulationMode: isSimulationMode,
            isNavigating: isNavigating,
            isUserLocationAuthorized: isUserLocationAuthorized,
            isFreePanActive: isFreePanActive
        )
        
        // Update simulated position
        let existingSimAnnotations = uiView.annotations.filter { $0 is SimulatedPositionAnnotation }
        
        if isSimulationMode, let simPos = simulatedPosition {
            // Hide real user location
            if uiView.showsUserLocation {
                uiView.showsUserLocation = false
            }
            context.coordinator.updateSimulatedNavigationCamera(
                mapView: uiView,
                coordinate: simPos,
                isFreePanActive: isFreePanActive,
                animated: true
            )
            
            // Update or add annotation
            if let annotation = existingSimAnnotations.first as? SimulatedPositionAnnotation {
                // Animate coordinate change
                UIView.animate(withDuration: 1.0) {
                    annotation.coordinate = simPos
                }
            } else {
                let annotation = SimulatedPositionAnnotation()
                annotation.coordinate = simPos
                annotation.title = "Simulated Position"
                uiView.addAnnotation(annotation)
            }
        } else {
            if isUserLocationAuthorized {
                if !uiView.showsUserLocation {
                    uiView.showsUserLocation = true
                }
                context.coordinator.updateUserTrackingMode(
                    mapView: uiView,
                    isNavigating: isNavigating,
                    isOfflineMapSelectionActive: isOfflineMapSelectionActive,
                    preservesStoppedTracking: true
                )
            } else {
                if uiView.showsUserLocation {
                    uiView.showsUserLocation = false
                }
                if uiView.userTrackingMode != .none {
                    uiView.setUserTrackingMode(.none, animated: false)
                }
            }
            // Remove sim annotation if present
            if !existingSimAnnotations.isEmpty {
                uiView.removeAnnotations(existingSimAnnotations)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(
        _ uiView: MKMapView,
        coordinator: Coordinator
    ) {
        coordinator.controlState?.disconnect(from: uiView)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        typealias AddressResolver = @MainActor (CLLocation) async -> String?

        var lastRoute: MKRoute?
        var lastRouteAlternatives: [MapRouteAlternative] = []
        var selectedRouteAlternativeID: UUID?
        var mapView: MKMapView?
        weak var controlState: MapViewControlState?
        var onMapTapped: (() -> Void)?
        var onRouteAlternativeSelected: ((UUID) -> Void)?
        var offlineMapSelectionFrame: CGRect?
        var onOfflineMapSelectionBoundsChanged: ((OfflineMapBounds) -> Void)?
        var onDestinationSelected: ((SavedDestination, CLLocation?) -> Void)?
        var isNavigating = false
        var isSimulationMode = false
        var isUserLocationAuthorized = false
        var simulatedPosition: CLLocationCoordinate2D?
        var hasSetInitialRegion = false
        private(set) var lastAppliedAppearance: IPhoneMapAppearance?
        private var trackingButton: MKUserTrackingButton?
        private var lastNavigationCoordinate: CLLocationCoordinate2D?
        private var lastNavigationHeading: CLLocationDirection = 0
        private var routeAlternativeIDsByOverlay:
            [ObjectIdentifier: UUID] = [:]
        private var reverseGeocodingTask: Task<Void, Never>?
        private let addressResolver: AddressResolver?

        override convenience init() {
            self.init(addressResolver: nil)
        }

        init(addressResolver: AddressResolver?) {
            self.addressResolver = addressResolver
            super.init()
        }

        func applyAppearanceIfNeeded(
            _ appearance: IPhoneMapAppearance,
            to target: any MapAppearanceConfigurationTarget
        ) {
            guard appearance != lastAppliedAppearance else { return }

            target.preferredConfiguration = appearance.makeConfiguration()
            lastAppliedAppearance = appearance
        }

        func installTrackingControl(on mapView: MKMapView) {
            guard trackingButton == nil else { return }

            let tracking = MKUserTrackingButton(mapView: mapView)
            tracking.translatesAutoresizingMaskIntoConstraints = false
            mapView.addSubview(tracking)

            NSLayoutConstraint.activate([
                tracking.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -18),
                tracking.topAnchor.constraint(
                    equalTo: mapView.safeAreaLayoutGuide.topAnchor,
                    constant: 220
                )
            ])

            trackingButton = tracking
        }

        func updateControlVisibility(isNavigating: Bool) {
            trackingButton?.isHidden = !isNavigating
        }

        func updateUserTrackingMode(
            mapView: MKMapView,
            isNavigating: Bool,
            isOfflineMapSelectionActive: Bool,
            preservesStoppedTracking: Bool = false,
            animated: Bool = true
        ) {
            let isDestinationSelectionActive = mapView.selectedAnnotations.contains {
                $0 is DestinationAnnotation
            }
            let desiredTrackingBehavior = MapTrackingPolicy.desiredMode(
                isNavigating: isNavigating,
                isOfflineMapSelectionActive: isOfflineMapSelectionActive,
                isDestinationSelectionActive: isDestinationSelectionActive
            )

            let desiredTrackingMode: MKUserTrackingMode
            switch desiredTrackingBehavior {
            case .none:
                desiredTrackingMode = .none
            case .follow:
                desiredTrackingMode = .follow
            case .followWithHeading:
                desiredTrackingMode = .followWithHeading
            }

            let currentTrackingBehavior: MapTrackingBehavior
            switch mapView.userTrackingMode {
            case .none:
                currentTrackingBehavior = .none
            case .follow:
                currentTrackingBehavior = .follow
            case .followWithHeading:
                currentTrackingBehavior = .followWithHeading
            @unknown default:
                currentTrackingBehavior = .none
            }

            guard MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: currentTrackingBehavior,
                desiredMode: desiredTrackingBehavior,
                preservesStoppedTracking: preservesStoppedTracking
            ) else { return }

            mapView.setUserTrackingMode(desiredTrackingMode, animated: animated)
        }

        func isFreePanActive(
            mapView: MKMapView,
            isOfflineMapSelectionActive: Bool
        ) -> Bool {
            isOfflineMapSelectionActive || mapView.selectedAnnotations.contains {
                $0 is DestinationAnnotation
            }
        }

        func updateInitialRegionIfNeeded(
            mapView: MKMapView,
            location: CLLocation?,
            simulatedPosition: CLLocationCoordinate2D?,
            isSimulationMode: Bool,
            isFreePanActive: Bool
        ) {
            guard !isFreePanActive,
                  let location,
                  !hasSetInitialRegion,
                  lastRoute == nil else { return }

            var center = isSimulationMode ? (simulatedPosition ?? location.coordinate) : location.coordinate

            // Apple Maps displays mainland-China coordinates in GCJ-02. Simulated
            // route positions already use MapKit's coordinate space.
            if !isSimulationMode,
               CoordinateConverter.isInChina(lat: center.latitude, lon: center.longitude) {
                center = CoordinateConverter.wgs84ToGCJ02(coordinate: center)
            }

            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            mapView.setRegion(region, animated: false)
            hasSetInitialRegion = true
        }

        func finishNavigationTracking(
            mapView: MKMapView,
            isUserLocationAuthorized: Bool,
            isFreePanActive: Bool
        ) {
            mapView.showsUserLocation = isUserLocationAuthorized

            if isFreePanActive {
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
            } else {
                let desiredMode: MKUserTrackingMode = isUserLocationAuthorized ? .follow : .none
                if mapView.userTrackingMode != desiredMode {
                    mapView.setUserTrackingMode(desiredMode, animated: false)
                }
                hasSetInitialRegion = false
            }

            resetNavigationCamera()
        }

        func updateOfflineMapSelectionBounds() {
            guard let mapView,
                  let frame = offlineMapSelectionFrame,
                  frame.width > 0,
                  frame.height > 0 else {
                return
            }

            let topLeft = mapView.convert(CGPoint(x: frame.minX, y: frame.minY), toCoordinateFrom: mapView)
            let bottomRight = mapView.convert(CGPoint(x: frame.maxX, y: frame.maxY), toCoordinateFrom: mapView)
            let bounds = OfflineMapBounds(
                minLon: min(topLeft.longitude, bottomRight.longitude),
                minLat: min(topLeft.latitude, bottomRight.latitude),
                maxLon: max(topLeft.longitude, bottomRight.longitude),
                maxLat: max(topLeft.latitude, bottomRight.latitude)
            )

            DispatchQueue.main.async { [onOfflineMapSelectionBoundsChanged] in
                onOfflineMapSelectionBoundsChanged?(bounds)
            }
        }

        func updateRouteOverlays(
            on mapView: MKMapView,
            route: MKRoute?,
            alternatives: [MapRouteAlternative],
            selectedAlternativeID: UUID?,
            routePlanningBottomPadding: CGFloat,
            location: CLLocation?,
            simulatedPosition: CLLocationCoordinate2D?,
            isSimulationMode: Bool,
            isNavigating: Bool,
            isUserLocationAuthorized: Bool,
            isFreePanActive: Bool
        ) {
            let activeRouteMatches =
                (lastRoute == nil && route == nil) || lastRoute === route
            let routeContentChanged =
                !activeRouteMatches || lastRouteAlternatives != alternatives

            if !routeContentChanged {
                updateSelectedRouteAlternative(
                    selectedAlternativeID,
                    on: mapView
                )
                return
            }

            let hadRouteContent = lastRoute != nil ||
                !lastRouteAlternatives.isEmpty
            installRouteOverlays(
                route: route,
                alternatives: alternatives,
                selectedAlternativeID: selectedAlternativeID,
                on: mapView
            )

            if !alternatives.isEmpty {
                configureRouteAlternativesCamera(
                    mapView: mapView,
                    alternatives: alternatives,
                    bottomPadding: routePlanningBottomPadding,
                    isFreePanActive: isFreePanActive
                )
                removeSimulationAnnotations(from: mapView)
            } else if let route {
                configureRouteCamera(
                    mapView: mapView,
                    route: route,
                    location: location,
                    simulatedPosition: simulatedPosition,
                    isSimulationMode: isSimulationMode,
                    isNavigating: isNavigating,
                    isFreePanActive: isFreePanActive
                )
                removeSimulationAnnotations(from: mapView)
            } else if hadRouteContent {
                let destinationAnnotations = mapView.annotations.filter {
                    $0 is DestinationAnnotation
                }
                mapView.removeAnnotations(destinationAnnotations)
                removeSimulationAnnotations(from: mapView)
                finishNavigationTracking(
                    mapView: mapView,
                    isUserLocationAuthorized: isUserLocationAuthorized,
                    isFreePanActive: isFreePanActive
                )
            }
        }

        func installRouteOverlays(
            route: MKRoute?,
            alternatives: [MapRouteAlternative],
            selectedAlternativeID: UUID?,
            on mapView: MKMapView
        ) {
            mapView.removeOverlays(mapView.overlays)
            lastRoute = route
            lastRouteAlternatives = alternatives
            self.selectedRouteAlternativeID = selectedAlternativeID
            routeAlternativeIDsByOverlay.removeAll(keepingCapacity: true)

            guard !alternatives.isEmpty else {
                if let route {
                    mapView.addOverlay(route.polyline, level: .aboveRoads)
                }
                return
            }

            for alternative in alternatives {
                routeAlternativeIDsByOverlay[
                    ObjectIdentifier(alternative.route.polyline)
                ] = alternative.id
            }
            let orderedAlternatives = alternatives.filter {
                $0.id != selectedAlternativeID
            } + alternatives.filter {
                $0.id == selectedAlternativeID
            }
            mapView.addOverlays(
                orderedAlternatives.map(\.route.polyline),
                level: .aboveRoads
            )
        }

        func updateSelectedRouteAlternative(
            _ selectedAlternativeID: UUID?,
            on mapView: MKMapView
        ) {
            guard self.selectedRouteAlternativeID != selectedAlternativeID else {
                return
            }
            self.selectedRouteAlternativeID = selectedAlternativeID

            if let selectedAlternativeID,
               let selectedOverlay = mapView.overlays.first(where: {
                   routeAlternativeID(for: $0) == selectedAlternativeID
               }) {
                mapView.removeOverlay(selectedOverlay)
                mapView.addOverlay(selectedOverlay, level: .aboveRoads)
            }

            for overlay in mapView.overlays {
                guard let renderer = mapView.renderer(for: overlay)
                    as? MKPolylineRenderer else {
                    continue
                }
                applyRouteStyle(renderer, for: overlay)
                renderer.setNeedsDisplay()
            }
        }

        func routeAlternativeID(
            at tapPoint: CGPoint,
            on mapView: MKMapView
        ) -> UUID? {
            let candidates = lastRouteAlternatives.map { alternative in
                MapRouteSelectionCandidate(
                    id: alternative.id,
                    points: screenPoints(
                        for: alternative.route.polyline,
                        on: mapView
                    )
                )
            }
            return MapRouteSelectionPolicy.routeID(
                nearestTo: tapPoint,
                candidates: candidates,
                preferredRouteID: selectedRouteAlternativeID
            )
        }

        private func screenPoints(
            for polyline: MKPolyline,
            on mapView: MKMapView
        ) -> [CGPoint] {
            guard polyline.pointCount > 0 else { return [] }
            var coordinates = [CLLocationCoordinate2D](
                repeating: CLLocationCoordinate2D(),
                count: polyline.pointCount
            )
            polyline.getCoordinates(
                &coordinates,
                range: NSRange(location: 0, length: polyline.pointCount)
            )
            return coordinates.map {
                mapView.convert($0, toPointTo: mapView)
            }
        }

        private func routeAlternativeID(for overlay: MKOverlay) -> UUID? {
            guard let polyline = overlay as? MKPolyline else { return nil }
            return routeAlternativeIDsByOverlay[ObjectIdentifier(polyline)]
        }

        private func removeSimulationAnnotations(from mapView: MKMapView) {
            let annotations = mapView.annotations.filter {
                $0 is SimulatedPositionAnnotation
            }
            mapView.removeAnnotations(annotations)
        }

        private func configureRouteAlternativesCamera(
            mapView: MKMapView,
            alternatives: [MapRouteAlternative],
            bottomPadding: CGFloat,
            isFreePanActive: Bool
        ) {
            guard !isFreePanActive else {
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                return
            }
            guard let first = alternatives.first else { return }
            let boundingMapRect = alternatives.dropFirst().reduce(
                first.route.polyline.boundingMapRect
            ) { partialResult, alternative in
                partialResult.union(alternative.route.polyline.boundingMapRect)
            }
            mapView.setVisibleMapRect(
                boundingMapRect,
                edgePadding: UIEdgeInsets(
                    top: 140,
                    left: 48,
                    bottom: max(bottomPadding, 160),
                    right: 48
                ),
                animated: true
            )
        }

        func configureRouteCamera(
            mapView: MKMapView,
            route: MKRoute,
            location: CLLocation?,
            simulatedPosition: CLLocationCoordinate2D?,
            isSimulationMode: Bool,
            isNavigating: Bool,
            isFreePanActive: Bool
        ) {
            guard !isFreePanActive else {
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                return
            }

            guard isNavigating else {
                mapView.setVisibleMapRect(
                    route.polyline.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 140, left: 48, bottom: 160, right: 48),
                    animated: true
                )
                return
            }

            if isSimulationMode, let simulatedPosition {
                updateNavigationCamera(mapView: mapView, coordinate: simulatedPosition, animated: false)
            } else {
                mapView.setUserTrackingMode(.followWithHeading, animated: true)
            }
        }

        func updateSimulatedNavigationCamera(
            mapView: MKMapView,
            coordinate: CLLocationCoordinate2D,
            isFreePanActive: Bool,
            animated: Bool
        ) {
            guard !isFreePanActive else {
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                return
            }

            updateNavigationCamera(
                mapView: mapView,
                coordinate: coordinate,
                animated: animated
            )
        }

        func updateNavigationCamera(
            mapView: MKMapView,
            coordinate: CLLocationCoordinate2D,
            animated: Bool
        ) {
            if let previous = lastNavigationCoordinate {
                let distance = MKMapPoint(previous).distance(to: MKMapPoint(coordinate))
                if distance > 2 {
                    lastNavigationHeading = bearing(from: previous, to: coordinate)
                }
            }

            lastNavigationCoordinate = coordinate
            let camera = MKMapCamera(
                lookingAtCenter: coordinate,
                fromDistance: 520,
                pitch: 58,
                heading: lastNavigationHeading
            )
            mapView.setCamera(camera, animated: animated)
        }

        func resetNavigationCamera() {
            lastNavigationCoordinate = nil
            lastNavigationHeading = 0
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            controlState?.updatePitch(from: mapView)
            updateOfflineMapSelectionBounds()
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is DestinationAnnotation else { return }

            // MapKit reports the temporary deselection used to rebuild a
            // reverse-geocoded callout too. Defer until a synchronous reselect
            // has completed, then only resume tracking if free pan truly ended.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView,
                      !self.isFreePanActive(
                          mapView: mapView,
                          isOfflineMapSelectionActive: self.offlineMapSelectionFrame != nil
                      ) else { return }

                if self.isSimulationMode, let simulatedPosition = self.simulatedPosition {
                    self.updateNavigationCamera(
                        mapView: mapView,
                        coordinate: simulatedPosition,
                        animated: true
                    )
                } else if self.isUserLocationAuthorized {
                    self.updateUserTrackingMode(
                        mapView: mapView,
                        isNavigating: self.isNavigating,
                        isOfflineMapSelectionActive: false
                    )
                }
            }
        }

        @objc func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
            guard gestureRecognizer.state == .ended else { return }
            if let mapView,
               onRouteAlternativeSelected != nil,
               let routeID = routeAlternativeID(
                   at: gestureRecognizer.location(in: mapView),
                   on: mapView
               ) {
                onRouteAlternativeSelected?(routeID)
            }
            onMapTapped?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
        
        @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard gestureRecognizer.state == .began,
                  let mapView = mapView,
                  onDestinationSelected != nil else { return }
            
            // Disable user tracking mode to allow free map movement
            mapView.userTrackingMode = .none
            
            let touchPoint = gestureRecognizer.location(in: mapView)
            let coordinate = mapView.convert(touchPoint, toCoordinateFrom: mapView)

            selectDestination(at: coordinate, on: mapView)
        }

        func selectDestination(at coordinate: CLLocationCoordinate2D, on mapView: MKMapView) {
            reverseGeocodingTask?.cancel()
            reverseGeocodingTask = nil
            
            // Remove any existing destination annotations
            let existingAnnotations = mapView.annotations.filter { $0 is DestinationAnnotation }
            mapView.removeAnnotations(existingAnnotations)
            
            // Add new annotation
            let annotation = DestinationAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Navigate Here"
            annotation.calloutAddress = "Finding address…"
            annotation.destination = SavedDestination(
                name: coordinateFallbackName(coordinate),
                coordinate: coordinate
            )
            
            mapView.addAnnotation(annotation)
            
            // Show the callout
            mapView.selectAnnotation(annotation, animated: true)

            reverseGeocode(annotation, on: mapView)
        }

        private func reverseGeocode(_ annotation: DestinationAnnotation, on mapView: MKMapView) {
            reverseGeocodingTask = Task { @MainActor [weak self, weak annotation, weak mapView] in
                guard let self, let annotation else { return }
                let location = CLLocation(
                    latitude: annotation.coordinate.latitude,
                    longitude: annotation.coordinate.longitude
                )
                let resolvedAddress: String?
                if let addressResolver = self.addressResolver {
                    resolvedAddress = await addressResolver(location)
                } else if #available(iOS 26.0, *) {
                    resolvedAddress = await self.modernAddress(for: location)
                } else {
                    resolvedAddress = await self.legacyAddress(for: location)
                }

                guard !Task.isCancelled,
                      let mapView,
                      mapView.annotations.contains(where: { $0 === annotation }) else { return }

                let fallbackName = self.coordinateFallbackName(annotation.coordinate)
                let address = resolvedAddress ?? fallbackName
                annotation.destination = SavedDestination(name: address, coordinate: annotation.coordinate)
                self.updateDestinationCallout(annotation, address: address, on: mapView)
                self.reverseGeocodingTask = nil
            }
        }

        #if HOST_TESTING
        func waitForReverseGeocodingForTesting() async {
            let task = reverseGeocodingTask
            await task?.value
        }
        #endif

        @available(iOS 26.0, *)
        private func modernAddress(for location: CLLocation) async -> String? {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let mapItems = try? await request.mapItems else { return nil }
            return mapItems.first.flatMap(displayAddress(for:))
        }

        @available(iOS, introduced: 5.0, obsoleted: 26.0)
        private func legacyAddress(for location: CLLocation) async -> String? {
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
                return nil
            }

            let components: [String?] = [
                placemark.name,
                placemark.locality,
                placemark.administrativeArea,
                placemark.postalCode,
                placemark.country
            ]
            let normalizedComponents: [String] = components.compactMap { component -> String? in
                guard let component = component?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !component.isEmpty else { return nil }
                return component
            }
            let address = normalizedComponents.reduce(into: [String]()) { result, component in
                guard !result.contains(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else { return }
                result.append(component)
            }
            .joined(separator: ", ")
            return address.isEmpty ? nil : address
        }

        @available(iOS 26.0, *)
        private func displayAddress(for mapItem: MKMapItem) -> String? {
            if let fullAddress = mapItem.addressRepresentations?
                .fullAddress(includingRegion: true, singleLine: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !fullAddress.isEmpty {
                return fullAddress
            }

            let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }

        private func coordinateFallbackName(_ coordinate: CLLocationCoordinate2D) -> String {
            String(
                format: "Dropped Pin · %.5f, %.5f",
                locale: Locale(identifier: "en_US_POSIX"),
                coordinate.latitude,
                coordinate.longitude
            )
        }

        private func updateDestinationCallout(
            _ annotation: DestinationAnnotation,
            address: String,
            on mapView: MKMapView
        ) {
            annotation.calloutAddress = address
            guard let annotationView = mapView.view(for: annotation),
                  let addressLabel = annotationView.detailCalloutAccessoryView as? UILabel else { return }

            let calloutWasVisible = annotationView.isSelected
            DestinationCalloutLabel.update(addressLabel, address: address)

            // MapKit measures the standard callout when it first appears. The
            // placeholder is one line tall, so rebuild a visible callout after
            // reverse geocoding supplies a multiline address.
            if calloutWasVisible {
                mapView.deselectAnnotation(annotation, animated: false)
                mapView.selectAnnotation(annotation, animated: false)
            }
        }

        private func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
            let startLat = start.latitude * .pi / 180
            let startLon = start.longitude * .pi / 180
            let endLat = end.latitude * .pi / 180
            let endLon = end.longitude * .pi / 180
            let deltaLon = endLon - startLon
            let y = sin(deltaLon) * cos(endLat)
            let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(deltaLon)
            let degrees = atan2(y, x) * 180 / .pi
            return degrees >= 0 ? degrees : degrees + 360
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                applyRouteStyle(renderer, for: overlay)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func applyRouteStyle(
            _ renderer: MKPolylineRenderer,
            for overlay: MKOverlay
        ) {
            guard let alternativeID = routeAlternativeID(for: overlay) else {
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 6
                renderer.alpha = 1
                return
            }

            let isSelected = alternativeID == selectedRouteAlternativeID
            renderer.strokeColor = isSelected ? .systemBlue : .systemGray
            renderer.lineWidth = isSelected ? 8 : 5
            renderer.alpha = isSelected ? 1 : 0.72
        }
        

        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Use default view for user location
            if annotation is MKUserLocation {
                return nil
            }
            
            // Handle simulated position annotation
            if let _ = annotation as? SimulatedPositionAnnotation {
                let identifier = "SimulatedPositionPin"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = true
                    annotationView?.markerTintColor = .red
                    annotationView?.glyphImage = UIImage(systemName: "bicycle")
                } else {
                    annotationView?.annotation = annotation
                }
                return annotationView
            }
            
            // Handle destination annotation
            if let destinationAnnotation = annotation as? DestinationAnnotation {
                let identifier = "DestinationPin"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = true
                    
                    // Add a button to the callout
                    let button = UIButton(type: .detailDisclosure)
                    button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill"), for: .normal)
                    annotationView?.rightCalloutAccessoryView = button
                    
                    // Customize marker appearance
                    annotationView?.markerTintColor = .systemBlue
                    annotationView?.glyphImage = UIImage(systemName: "mappin.circle.fill")
                } else {
                    annotationView?.annotation = annotation
                }

                let addressLabel = DestinationCalloutLabel.make(address: destinationAnnotation.calloutAddress)
                annotationView?.detailCalloutAccessoryView = addressLabel
                
                return annotationView
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            // Handle the callout button tap
            if let destinationAnnotation = view.annotation as? DestinationAnnotation,
               let destination = destinationAnnotation.destination {
                reverseGeocodingTask?.cancel()
                reverseGeocodingTask = nil

                // Pass the map's user location as fallback
                onDestinationSelected?(destination, mapView.userLocation.location)
                
                // Remove the annotation after selection
                mapView.removeAnnotation(destinationAnnotation)
            }
        }
    }
}
