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
    private(set) var selectionCount = 0
    private(set) var deselectionCount = 0

    override func view(for annotation: MKAnnotation) -> MKAnnotationView? {
        let identifier = ObjectIdentifier(annotation as AnyObject)
        if let recordedView = recordedViews[identifier] {
            return recordedView
        }

        let annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
        if let destinationAnnotation = annotation as? DestinationAnnotation {
            annotationView.detailCalloutAccessoryView = DestinationCalloutLabel.make(
                address: destinationAnnotation.calloutAddress
            )
        }
        recordedViews[identifier] = annotationView
        return annotationView
    }

    override func selectAnnotation(_ annotation: MKAnnotation, animated: Bool) {
        selectionCount += 1
        view(for: annotation)?.setSelected(true, animated: false)
    }

    override func deselectAnnotation(_ annotation: MKAnnotation?, animated: Bool) {
        deselectionCount += 1
        if let annotation {
            view(for: annotation)?.setSelected(false, animated: false)
        }
    }
}

@main
struct DestinationCalloutLayoutTests {
    @MainActor
    static func main() async {
        testLabelExpansion()
        await testResolvedAddressCallbackAndRecentInsertion()
        await testFallbackAddress()
        await testStaleResolutionCancellation()

        print("DestinationCalloutLayoutTests passed")
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

        coordinator.onDestinationSelected = { destination, _ in
            callbackDestination = destination
            store.addRecent(destination)
        }
        coordinator.selectDestination(at: coordinate, on: mapView)

        guard let annotation = mapView.annotations.compactMap({ $0 as? DestinationAnnotation }).first,
              let annotationView = mapView.view(for: annotation),
              let addressLabel = annotationView.detailCalloutAccessoryView as? UILabel else {
            preconditionFailure("destination annotation and callout should be created")
        }
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
            calloutAccessoryControlTapped: UIButton(type: .detailDisclosure)
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
        let coordinator = MapViewContainer.Coordinator(addressResolver: { location in
            if location.coordinate.latitude == firstCoordinate.latitude {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return "Stale Address"
            }
            return "Current Address"
        })
        coordinator.onDestinationSelected = { _, _ in }

        coordinator.selectDestination(at: firstCoordinate, on: mapView)
        coordinator.selectDestination(at: secondCoordinate, on: mapView)
        await coordinator.waitForReverseGeocodingForTesting()

        let annotations = mapView.annotations.compactMap { $0 as? DestinationAnnotation }
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
