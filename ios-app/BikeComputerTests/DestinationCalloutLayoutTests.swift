import UIKit
import MapKit

// MapView only needs the selection bounds shape in this focused Catalyst test.
struct OfflineMapBounds {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double
}

@MainActor
private final class RecordingMapView: MKMapView {
    private var recordedViews: [ObjectIdentifier: MKAnnotationView] = [:]
    var annotationViewProvider: ((MKAnnotation) -> MKAnnotationView?)?
    var convertedCoordinate: CLLocationCoordinate2D?
    private(set) var selectionCount = 0
    private(set) var deselectionCount = 0
    private(set) var cameraUpdateCount = 0
    private(set) var regionUpdateCount = 0
    private var recordedSelectedAnnotations: [MKAnnotation] = []
    private var recordedUserTrackingMode: MKUserTrackingMode = .none

    override var selectedAnnotations: [MKAnnotation] {
        get { recordedSelectedAnnotations }
        set { recordedSelectedAnnotations = newValue }
    }

    override var userTrackingMode: MKUserTrackingMode {
        get { recordedUserTrackingMode }
        set { recordedUserTrackingMode = newValue }
    }

    override func setUserTrackingMode(_ mode: MKUserTrackingMode, animated: Bool) {
        recordedUserTrackingMode = mode
    }

    override func setCamera(_ camera: MKMapCamera, animated: Bool) {
        cameraUpdateCount += 1
    }

    override func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        regionUpdateCount += 1
    }

    override func view(for annotation: MKAnnotation) -> MKAnnotationView? {
        let identifier = ObjectIdentifier(annotation as AnyObject)
        if let recordedView = recordedViews[identifier] {
            return recordedView
        }

        guard let annotationView = annotationViewProvider?(annotation) else { return nil }
        recordedViews[identifier] = annotationView
        return annotationView
    }

    override func convert(_ point: CGPoint, toCoordinateFrom view: UIView?) -> CLLocationCoordinate2D {
        convertedCoordinate ?? super.convert(point, toCoordinateFrom: view)
    }

    override func selectAnnotation(_ annotation: MKAnnotation, animated: Bool) {
        selectionCount += 1
        recordedSelectedAnnotations = [annotation]
        view(for: annotation)?.setSelected(true, animated: false)
    }

    override func deselectAnnotation(_ annotation: MKAnnotation?, animated: Bool) {
        deselectionCount += 1
        if let annotation {
            recordedSelectedAnnotations.removeAll { $0 === annotation }
            view(for: annotation)?.setSelected(false, animated: false)
        }
    }
}

@MainActor
private final class RecordingLongPressGestureRecognizer: UILongPressGestureRecognizer {
    private var recordedState: UIGestureRecognizer.State
    private let recordedLocation: CGPoint

    init(state: UIGestureRecognizer.State, location: CGPoint) {
        recordedState = state
        recordedLocation = location
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { recordedState }
        set { recordedState = newValue }
    }

    override func location(in view: UIView?) -> CGPoint {
        recordedLocation
    }
}

private final class RecordingRoute: MKRoute {}

@main
struct DestinationCalloutLayoutTests {
    @MainActor
    static func main() async {
        testLabelExpansion()
        await testDestinationSelectionTrackingIntegration()
        await testResolvedAddressCallbackAndRecentInsertion()
        await testFallbackAddress()
        await testStaleResolutionCancellation()

        print("DestinationCalloutLayoutTests passed")
    }

    @MainActor
    private static func testDestinationSelectionTrackingIntegration() async {
        let coordinate = CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980)
        let mapView = RecordingMapView()
        let coordinator = MapViewContainer.Coordinator(addressResolver: { _ in nil })
        coordinator.mapView = mapView
        coordinator.isUserLocationAuthorized = true
        mapView.convertedCoordinate = coordinate
        mapView.annotationViewProvider = { annotation in
            coordinator.mapView(mapView, viewFor: annotation)
        }
        coordinator.onDestinationSelected = { _, _ in }
        mapView.userTrackingMode = .follow

        let longPress = RecordingLongPressGestureRecognizer(
            state: .began,
            location: CGPoint(x: 100, y: 100)
        )
        coordinator.handleLongPress(longPress)

        guard let annotation = mapView.selectedAnnotations.first as? DestinationAnnotation else {
            preconditionFailure("a newly dropped destination should be selected")
        }
        precondition(
            mapView.userTrackingMode == .none,
            "long-press destination selection should disable tracking"
        )

        coordinator.updateUserTrackingMode(
            mapView: mapView,
            isNavigating: false,
            isOfflineMapSelectionActive: false,
            animated: false
        )
        precondition(
            mapView.userTrackingMode == .none,
            "a selected destination callout should preserve free panning"
        )

        let destinationFreePanActive = coordinator.isFreePanActive(
            mapView: mapView,
            isOfflineMapSelectionActive: false
        )
        let cameraUpdatesBeforeDestinationRoute = mapView.cameraUpdateCount
        let destinationRouteCoordinate = CLLocationCoordinate2D(latitude: 1.3525, longitude: 103.8202)
        coordinator.configureRouteCamera(
            mapView: mapView,
            route: RecordingRoute(),
            location: nil,
            simulatedPosition: destinationRouteCoordinate,
            isSimulationMode: true,
            isNavigating: true,
            isFreePanActive: destinationFreePanActive
        )
        coordinator.updateSimulatedNavigationCamera(
            mapView: mapView,
            coordinate: destinationRouteCoordinate,
            isFreePanActive: destinationFreePanActive,
            animated: false
        )
        precondition(
            destinationFreePanActive &&
                mapView.cameraUpdateCount == cameraUpdatesBeforeDestinationRoute,
            "route start and simulation ticks should preserve a selected destination callout"
        )

        guard let annotationView = mapView.view(for: annotation) else {
            preconditionFailure("the selected destination should have an annotation view")
        }
        coordinator.mapView(mapView, didDeselect: annotationView)
        await waitForMainQueue()
        precondition(
            mapView.userTrackingMode == .none,
            "a temporary callout refresh must not resume tracking after the pin is reselected"
        )

        mapView.deselectAnnotation(annotation, animated: false)
        coordinator.mapView(mapView, didDeselect: annotationView)
        await waitForMainQueue()

        precondition(
            !mapView.selectedAnnotations.contains { $0 is DestinationAnnotation },
            "dismissing the callout should end destination selection"
        )
        precondition(
            mapView.userTrackingMode == .follow,
            "the MapKit deselection callback should resume dot-mode follow"
        )

        coordinator.isNavigating = true
        mapView.userTrackingMode = .none
        coordinator.mapView(mapView, didDeselect: annotationView)
        await waitForMainQueue()
        precondition(
            mapView.userTrackingMode == .followWithHeading,
            "the MapKit deselection callback should resume navigation heading-follow"
        )

        coordinator.updateUserTrackingMode(
            mapView: mapView,
            isNavigating: true,
            isOfflineMapSelectionActive: true,
            animated: false
        )
        precondition(
            mapView.userTrackingMode == .none,
            "offline map selection should disable heading-follow during navigation"
        )

        let cameraUpdatesBeforeSelection = mapView.cameraUpdateCount
        let simulatedCoordinate = CLLocationCoordinate2D(latitude: 1.353, longitude: 103.82)
        coordinator.updateSimulatedNavigationCamera(
            mapView: mapView,
            coordinate: simulatedCoordinate,
            isFreePanActive: true,
            animated: false
        )
        precondition(
            mapView.cameraUpdateCount == cameraUpdatesBeforeSelection,
            "simulated navigation updates should not recenter an offline selection"
        )

        mapView.userTrackingMode = .followWithHeading
        coordinator.configureRouteCamera(
            mapView: mapView,
            route: RecordingRoute(),
            location: nil,
            simulatedPosition: simulatedCoordinate,
            isSimulationMode: false,
            isNavigating: true,
            isFreePanActive: true
        )
        precondition(
            mapView.cameraUpdateCount == cameraUpdatesBeforeSelection &&
                mapView.userTrackingMode == .none,
            "route replacement should not move a navigating offline selection"
        )

        coordinator.updateSimulatedNavigationCamera(
            mapView: mapView,
            coordinate: simulatedCoordinate,
            isFreePanActive: false,
            animated: false
        )
        precondition(
            mapView.cameraUpdateCount == cameraUpdatesBeforeSelection + 1,
            "simulated navigation camera updates should resume after selection"
        )

        coordinator.updateUserTrackingMode(
            mapView: mapView,
            isNavigating: true,
            isOfflineMapSelectionActive: false,
            animated: false
        )
        precondition(
            mapView.userTrackingMode == .followWithHeading,
            "real navigation heading-follow should resume after offline selection"
        )

        let liveLocation = CLLocation(latitude: 1.354, longitude: 103.821)
        coordinator.hasSetInitialRegion = false
        let regionUpdatesBeforeLateLocation = mapView.regionUpdateCount
        coordinator.updateInitialRegionIfNeeded(
            mapView: mapView,
            location: liveLocation,
            simulatedPosition: nil,
            isSimulationMode: false,
            isFreePanActive: true
        )
        precondition(
            mapView.regionUpdateCount == regionUpdatesBeforeLateLocation &&
                !coordinator.hasSetInitialRegion,
            "a late first location should not recenter an active free-pan selection"
        )

        coordinator.hasSetInitialRegion = true
        mapView.userTrackingMode = .followWithHeading
        coordinator.finishNavigationTracking(
            mapView: mapView,
            isUserLocationAuthorized: true,
            isFreePanActive: true
        )
        precondition(
            mapView.userTrackingMode == .none && coordinator.hasSetInitialRegion,
            "stopping navigation should preserve the selected map region"
        )

        coordinator.updateInitialRegionIfNeeded(
            mapView: mapView,
            location: liveLocation,
            simulatedPosition: nil,
            isSimulationMode: false,
            isFreePanActive: true
        )
        precondition(
            mapView.regionUpdateCount == regionUpdatesBeforeLateLocation,
            "the next GPS update should not recenter after navigation stops during selection"
        )

        coordinator.updateUserTrackingMode(
            mapView: mapView,
            isNavigating: false,
            isOfflineMapSelectionActive: false,
            animated: false
        )
        precondition(
            mapView.userTrackingMode == .follow,
            "dot-mode follow should resume when free-pan selection exits"
        )
    }

    @MainActor
    private static func waitForMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @MainActor
    private static func testLabelExpansion() {
        let label = DestinationCalloutLabel.make(address: "Finding address…")
        let pendingSize = measuredSize(of: label)

        DestinationCalloutLabel.update(
            label,
            address: "No. 557 Lingling Road, Xuhui District, Shanghai, China"
        )
        let resolvedSize = measuredSize(of: label)

        precondition(label.numberOfLines == 0, "destination address must allow multiple lines")
        precondition(
            label.lineBreakMode == .byWordWrapping,
            "destination address must wrap at word boundaries"
        )
        precondition(
            resolvedSize.height > pendingSize.height,
            "resolved destination address must expand beyond the placeholder height"
        )
    }

    @MainActor
    private static func testResolvedAddressCallbackAndRecentInsertion() async {
        let suiteName = "DestinationCalloutLayoutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("destination callout defaults should be available")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let address = "No. 557 Lingling Road, Xuhui District, Shanghai, China"
        let coordinate = CLLocationCoordinate2D(latitude: 31.18521, longitude: 121.44709)
        let mapView = RecordingMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = MapViewContainer.Coordinator(addressResolver: { _ in address })
        let store = SavedDestinationStore(defaults: defaults)
        var callbackDestination: SavedDestination?

        coordinator.mapView = mapView
        mapView.convertedCoordinate = coordinate
        mapView.annotationViewProvider = { annotation in
            coordinator.mapView(mapView, viewFor: annotation)
        }
        coordinator.onDestinationSelected = MapDestinationSelection.handler(store: store) { destination, _ in
            callbackDestination = destination
        }
        let longPress = RecordingLongPressGestureRecognizer(
            state: .began,
            location: CGPoint(x: 195, y: 422)
        )
        coordinator.handleLongPress(longPress)

        guard let annotation = mapView.annotations.compactMap({ $0 as? DestinationAnnotation }).first,
              let annotationView = mapView.view(for: annotation),
              let addressLabel = annotationView.detailCalloutAccessoryView as? UILabel,
              let navigateButton = annotationView.rightCalloutAccessoryView as? UIButton else {
            preconditionFailure("destination annotation and callout should be created")
        }
        precondition(
            navigateButton.image(for: .normal) != nil,
            "the shipped destination annotation view should expose Navigate Here"
        )
        let pendingSize = measuredSize(of: addressLabel)

        await coordinator.waitForReverseGeocodingForTesting()

        precondition(annotation.calloutAddress == address, "resolved address should update the annotation")
        precondition(annotation.destination?.name == address, "resolved address should update the route destination")
        precondition(addressLabel.text == address, "resolved address should update the visible callout label")
        precondition(
            measuredSize(of: addressLabel).height > pendingSize.height,
            "resolved callout should expand while selected"
        )
        precondition(mapView.selectionCount == 2, "visible callout should be selected again after resizing")
        precondition(mapView.deselectionCount == 1, "visible callout should be rebuilt after resizing")

        coordinator.mapView(
            mapView,
            annotationView: annotationView,
            calloutAccessoryControlTapped: navigateButton
        )

        guard let callbackDestination else {
            preconditionFailure("Navigate Here should deliver the resolved destination")
        }
        assertCoordinate(callbackDestination.coordinate, equals: coordinate, message: "callback keeps the exact pin coordinate")
        precondition(store.recentDestinations.count == 1, "Navigate Here callback should add one recent destination")
        assertCoordinate(
            store.recentDestinations[0].coordinate,
            equals: coordinate,
            message: "recent destination keeps the exact pin coordinate"
        )
        precondition(
            !mapView.annotations.contains(where: { $0 is DestinationAnnotation }),
            "selected destination annotation should be removed after navigation"
        )
    }

    @MainActor
    private static func testFallbackAddress() async {
        let coordinate = CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980)
        let mapView = RecordingMapView()
        let coordinator = MapViewContainer.Coordinator(addressResolver: { _ in nil })
        mapView.annotationViewProvider = { annotation in
            coordinator.mapView(mapView, viewFor: annotation)
        }
        coordinator.onDestinationSelected = { _, _ in }

        coordinator.selectDestination(at: coordinate, on: mapView)
        await coordinator.waitForReverseGeocodingForTesting()

        guard let annotation = mapView.annotations.compactMap({ $0 as? DestinationAnnotation }).first,
              let destination = annotation.destination else {
            preconditionFailure("fallback destination should remain available")
        }
        precondition(destination.name == "Dropped Pin · 1.35210, 103.81980", "failed geocoding should show coordinates")
        assertCoordinate(destination.coordinate, equals: coordinate, message: "fallback keeps the exact pin coordinate")
    }

    @MainActor
    private static func testStaleResolutionCancellation() async {
        let firstCoordinate = CLLocationCoordinate2D(latitude: 31.10000, longitude: 121.40000)
        let secondCoordinate = CLLocationCoordinate2D(latitude: 31.20000, longitude: 121.50000)
        let mapView = RecordingMapView()
        var firstResolverStarted = false
        var firstResolverFinished = false
        var firstResolverObservedCancellation = false
        let coordinator = MapViewContainer.Coordinator(addressResolver: { location in
            if location.coordinate.latitude == firstCoordinate.latitude {
                firstResolverStarted = true
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    firstResolverObservedCancellation = Task.isCancelled
                }
                firstResolverFinished = true
                return "Stale Address"
            }
            return "Current Address"
        })
        mapView.annotationViewProvider = { annotation in
            coordinator.mapView(mapView, viewFor: annotation)
        }
        coordinator.onDestinationSelected = { _, _ in }

        coordinator.selectDestination(at: firstCoordinate, on: mapView)
        while !firstResolverStarted {
            await Task.yield()
        }
        coordinator.selectDestination(at: secondCoordinate, on: mapView)
        await coordinator.waitForReverseGeocodingForTesting()
        while !firstResolverFinished {
            await Task.yield()
        }

        let annotations = mapView.annotations.compactMap { $0 as? DestinationAnnotation }
        precondition(firstResolverObservedCancellation, "a replaced pin should cancel its reverse-geocoding task")
        precondition(annotations.count == 1, "a newer long press should replace the previous pin")
        precondition(annotations[0].calloutAddress == "Current Address", "stale geocoding must not replace the current address")
        assertCoordinate(
            annotations[0].destination?.coordinate,
            equals: secondCoordinate,
            message: "stale geocoding must not replace the current pin"
        )
    }

    @MainActor
    private static func measuredSize(of label: UILabel) -> CGSize {
        label.systemLayoutSizeFitting(
            CGSize(
                width: DestinationCalloutLabel.preferredWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    private static func assertCoordinate(
        _ actual: CLLocationCoordinate2D?,
        equals expected: CLLocationCoordinate2D,
        message: String
    ) {
        guard let actual else { preconditionFailure("\(message): coordinate missing") }
        precondition(abs(actual.latitude - expected.latitude) < 0.000001, "\(message): latitude differs")
        precondition(abs(actual.longitude - expected.longitude) < 0.000001, "\(message): longitude differs")
    }
}
