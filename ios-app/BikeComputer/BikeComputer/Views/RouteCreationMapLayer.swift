import MapKit
import UIKit

/// Create a Route as the main map draws it: stop pins in MapKit's display
/// space and the planned route, converted once per plan. Render input only;
/// the map never edits stops or requests directions.
struct MapRouteCreation: Equatable {
    struct Stop: Equatable {
        enum Kind: Equatable {
            case start
            case stop(Int)
            case destination

            var title: String {
                switch self {
                case .start: "Start"
                case .stop(let number): "Stop \(number)"
                case .destination: "Destination"
                }
            }
        }

        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let label: String
        let kind: Kind

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.label == rhs.label && lhs.kind == rhs.kind &&
                lhs.coordinate.latitude == rhs.coordinate.latitude &&
                lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    let stops: [Stop]
    /// The planned route's identity; nil while no plan is ready.
    let routeID: UUID?
    let polyline: MKPolyline?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stops == rhs.stops && lhs.routeID == rhs.routeID && lhs.polyline === rhs.polyline
    }
}

final class RouteCreationStopAnnotation: NSObject, MKAnnotation {
    let stopID: UUID
    let kind: MapRouteCreation.Stop.Kind
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ stop: MapRouteCreation.Stop) {
        stopID = stop.id
        kind = stop.kind
        coordinate = stop.coordinate
        title = stop.kind.title
        subtitle = stop.label
    }

    fileprivate func matches(_ stop: MapRouteCreation.Stop) -> Bool {
        stopID == stop.id && kind == stop.kind && subtitle == stop.label &&
            coordinate.latitude == stop.coordinate.latitude &&
            coordinate.longitude == stop.coordinate.longitude
    }
}

/// Owns the Create a Route annotations and overlay on the shared main map.
/// It never removes another layer's content.
final class RouteCreationMapLayer {
    static let markerIdentifier = "RouteCreationStop"

    private(set) var displayed: MapRouteCreation?
    private(set) var polyline: MKPolyline?
    private var annotations: [RouteCreationStopAnnotation] = []
    private var fittedRouteID: UUID?
    /// A stop or route changed while the panel's layout was unsettled.
    private var pendingCameraCheck = false
    /// Below this, a fit would squeeze the route into a sliver of map.
    private let minimumVisibleSide: CGFloat = 160

    var isActive: Bool { displayed != nil }

    func owns(_ overlay: MKOverlay) -> Bool {
        guard let polyline else { return false }
        return overlay === polyline
    }

    /// Returns true when this call removed the layer's content.
    @discardableResult
    func update(
        _ creation: MapRouteCreation?,
        on mapView: MKMapView,
        bottomPadding: CGFloat?
    ) -> Bool {
        guard let creation else { return clear(from: mapView) }
        let previous = displayed
        displayed = creation
        if mapView.userTrackingMode != .none {
            mapView.setUserTrackingMode(.none, animated: false)
        }

        let stopsChanged = previous?.stops != creation.stops
        if stopsChanged {
            updateAnnotations(creation.stops, on: mapView)
        }
        if polyline !== creation.polyline {
            if let polyline { mapView.removeOverlay(polyline) }
            polyline = creation.polyline
            if let polyline = creation.polyline {
                mapView.addOverlay(polyline, level: .aboveRoads)
            }
        }

        let routeChanged = creation.routeID != nil && creation.routeID != fittedRouteID
        if routeChanged { fittedRouteID = creation.routeID }
        if stopsChanged || routeChanged { pendingCameraCheck = true }
        // A nil padding means the panel is searching or not laid out yet; a
        // tiny visible area means the keyboard is still leaving. Wait for both.
        guard pendingCameraCheck,
              let padding = edgePadding(on: mapView, bottomPadding: bottomPadding) else { return false }
        pendingCameraCheck = false
        // The camera moves only to bring a stop or the new route into view,
        // so pans, zooms and pins dropped on screen stay where the rider put them.
        if !isVisible(creation, on: mapView, padding: padding) {
            fit(creation, on: mapView, padding: padding)
        }
        return false
    }

    @discardableResult
    func clear(from mapView: MKMapView) -> Bool {
        let hadContent = displayed != nil || polyline != nil || !annotations.isEmpty
        if let polyline { mapView.removeOverlay(polyline) }
        mapView.removeAnnotations(annotations)
        polyline = nil
        annotations = []
        displayed = nil
        fittedRouteID = nil
        pendingCameraCheck = false
        return hadContent
    }

    func stopID(for annotation: MKAnnotation) -> UUID? {
        (annotation as? RouteCreationStopAnnotation)?.stopID
    }

    static func annotationView(
        for stop: RouteCreationStopAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: markerIdentifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: stop, reuseIdentifier: markerIdentifier)
        view.annotation = stop
        view.canShowCallout = true
        view.displayPriority = .required
        view.animatesWhenAdded = true
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "trash"), for: .normal)
        remove.tintColor = .systemRed
        remove.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        remove.accessibilityLabel = "Remove \(stop.kind.title)"
        view.rightCalloutAccessoryView = remove
        switch stop.kind {
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
        view.accessibilityLabel = "\(stop.kind.title), \(stop.subtitle ?? "")"
        return view
    }

    // MARK: - Private

    private func updateAnnotations(_ stops: [MapRouteCreation.Stop], on mapView: MKMapView) {
        var kept: [RouteCreationStopAnnotation] = []
        var removed: [RouteCreationStopAnnotation] = []
        for annotation in annotations {
            if stops.contains(where: annotation.matches) {
                kept.append(annotation)
            } else {
                removed.append(annotation)
            }
        }
        mapView.removeAnnotations(removed)
        let added = stops
            .filter { stop in !kept.contains { $0.matches(stop) } }
            .map { RouteCreationStopAnnotation($0) }
        mapView.addAnnotations(added)
        annotations = kept + added
    }

    /// The map left uncovered above the panel, or nil when it is unknown or
    /// too small to fit anything into.
    private func edgePadding(on mapView: MKMapView, bottomPadding: CGFloat?) -> UIEdgeInsets? {
        guard let bottom = bottomPadding, bottom.isFinite, bottom >= 0 else { return nil }
        let padding = UIEdgeInsets(top: 120, left: 40, bottom: bottom, right: 72)
        let visible = mapView.bounds.inset(by: padding)
        guard visible.width >= minimumVisibleSide, visible.height >= minimumVisibleSide else { return nil }
        return padding
    }

    private func isVisible(
        _ creation: MapRouteCreation,
        on mapView: MKMapView,
        padding: UIEdgeInsets
    ) -> Bool {
        let visible = mapView.bounds.inset(by: padding)
        guard !visible.isEmpty else { return true }
        let stopsVisible = creation.stops.allSatisfy {
            visible.contains(mapView.convert($0.coordinate, toPointTo: mapView))
        }
        guard stopsVisible, let polyline = creation.polyline else { return stopsVisible }
        let bounds = polyline.boundingMapRect
        let corners = [
            MKMapPoint(x: bounds.minX, y: bounds.minY),
            MKMapPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        return corners.allSatisfy {
            visible.contains(mapView.convert($0.coordinate, toPointTo: mapView))
        }
    }

    private func fit(_ creation: MapRouteCreation, on mapView: MKMapView, padding: UIEdgeInsets) {
        var rect = creation.polyline?.boundingMapRect ?? .null
        for stop in creation.stops {
            let point = MKMapPoint(stop.coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !rect.isNull,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) else { return }
        let minimumSide = 600 * MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude)
        if rect.width < minimumSide || rect.height < minimumSide {
            rect = rect.insetBy(
                dx: -max(minimumSide - rect.width, 0) / 2,
                dy: -max(minimumSide - rect.height, 0) / 2
            )
        }
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: mapView.window != nil)
    }
}
