//
//  MapView.swift
//  BikeComputer
//
//  Map display components
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Destination Annotation

class DestinationAnnotation: MKPointAnnotation {
    var coordinate2D: CLLocationCoordinate2D {
        return coordinate
    }
}

// MARK: - Simulated Position Annotation

class SimulatedPositionAnnotation: MKPointAnnotation {}

// MARK: - Map View Container

struct MapViewContainer: UIViewRepresentable {
    let location: CLLocation?
    let route: MKRoute?
    let simulatedPosition: CLLocationCoordinate2D?
    let isSimulationMode: Bool
    let isNavigating: Bool
    let onMapTapped: (() -> Void)?
    let onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        
        // Configure map appearance
        mapView.showsCompass = false
        mapView.showsScale = true
        context.coordinator.installMapControls(on: mapView)
        
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
        context.coordinator.onDestinationSelected = onDestinationSelected
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Store reference to map view in coordinator
        context.coordinator.mapView = uiView
        context.coordinator.onMapTapped = onMapTapped
        context.coordinator.onDestinationSelected = onDestinationSelected
        context.coordinator.updateControlVisibility(isNavigating: isNavigating)
        
        // Only set initial region once if not already set
        if let location = location, 
           !context.coordinator.hasSetInitialRegion,
           context.coordinator.lastRoute == nil {
             // Use simulated position if available and in simulation mode
             var center = (isSimulationMode && simulatedPosition != nil) ? simulatedPosition! : location.coordinate
             
             // In China, Apple Maps uses GCJ-02 for its view region
             // Convert WGS-84 -> GCJ-02 so the map centers correctly on the visual location (blue dot)
             // Only convert for REAL GPS (which is WGS-84). Simulated position (from MKRoute) is already GCJ-02.
             if !isSimulationMode && CoordinateConverter.isInChina(lat: center.latitude, lon: center.longitude) {
                 let converted = CoordinateConverter.wgs84ToGCJ02(coordinate: center)
                 center = converted
             }
             
            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            uiView.setRegion(region, animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
        
        // Update route overlay
        if let route = route, context.coordinator.lastRoute !== route {
            // Remove old overlays
            uiView.removeOverlays(uiView.overlays)
            
            // Add new route overlay
            uiView.addOverlay(route.polyline, level: .aboveRoads)
            context.coordinator.configureRouteCamera(
                mapView: uiView,
                route: route,
                location: location,
                simulatedPosition: simulatedPosition,
                isSimulationMode: isSimulationMode,
                isNavigating: isNavigating
            )
            
            // Handle simulated position annotation
            // Remove existing one
            let existingSimAnnotations = uiView.annotations.filter { $0 is SimulatedPositionAnnotation }
            uiView.removeAnnotations(existingSimAnnotations)
            
            context.coordinator.lastRoute = route
        } else if route == nil && context.coordinator.lastRoute != nil {
            // Clear route when navigation stops
            uiView.removeOverlays(uiView.overlays)
            context.coordinator.lastRoute = nil
            
            // Remove any destination annotations
            let destinationAnnotations = uiView.annotations.filter { $0 is DestinationAnnotation }
            uiView.removeAnnotations(destinationAnnotations)
            
            // Remove simulation annotation
            let simAnnotations = uiView.annotations.filter { $0 is SimulatedPositionAnnotation }
            uiView.removeAnnotations(simAnnotations)
            
            // Re-enable user tracking when navigation stops
            uiView.userTrackingMode = .follow
            uiView.showsUserLocation = true 
            context.coordinator.hasSetInitialRegion = false
            context.coordinator.resetNavigationCamera()
        }
        
        // Update simulated position
        let existingSimAnnotations = uiView.annotations.filter { $0 is SimulatedPositionAnnotation }
        
        if isSimulationMode, let simPos = simulatedPosition {
            // Hide real user location
            if uiView.showsUserLocation {
                uiView.showsUserLocation = false
            }
            context.coordinator.updateNavigationCamera(
                mapView: uiView,
                coordinate: simPos,
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
            // Show real user location if not simulating
            if !uiView.showsUserLocation {
                uiView.showsUserLocation = true
            }
            if isNavigating && uiView.userTrackingMode != .followWithHeading {
                uiView.setUserTrackingMode(.followWithHeading, animated: true)
            } else if !isNavigating && uiView.userTrackingMode == .followWithHeading {
                uiView.setUserTrackingMode(.follow, animated: true)
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
    
    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var lastRoute: MKRoute?
        var mapView: MKMapView?
        var onMapTapped: (() -> Void)?
        var onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
        var hasSetInitialRegion = false
        private var compassButton: MKCompassButton?
        private var trackingButton: MKUserTrackingButton?
        private var lastNavigationCoordinate: CLLocationCoordinate2D?
        private var lastNavigationHeading: CLLocationDirection = 0

        func installMapControls(on mapView: MKMapView) {
            guard compassButton == nil else { return }

            let compass = MKCompassButton(mapView: mapView)
            compass.compassVisibility = .adaptive
            compass.translatesAutoresizingMaskIntoConstraints = false
            mapView.addSubview(compass)

            let tracking = MKUserTrackingButton(mapView: mapView)
            tracking.translatesAutoresizingMaskIntoConstraints = false
            mapView.addSubview(tracking)

            NSLayoutConstraint.activate([
                compass.leadingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.leadingAnchor, constant: 18),
                compass.topAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 220),

                tracking.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -18),
                tracking.topAnchor.constraint(equalTo: compass.topAnchor)
            ])

            compassButton = compass
            trackingButton = tracking
        }

        func updateControlVisibility(isNavigating: Bool) {
            compassButton?.compassVisibility = isNavigating ? .visible : .adaptive
            trackingButton?.isHidden = !isNavigating
        }

        func configureRouteCamera(
            mapView: MKMapView,
            route: MKRoute,
            location: CLLocation?,
            simulatedPosition: CLLocationCoordinate2D?,
            isSimulationMode: Bool,
            isNavigating: Bool
        ) {
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

        @objc func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
            guard gestureRecognizer.state == .ended else { return }
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
            
            // Remove any existing destination annotations
            let existingAnnotations = mapView.annotations.filter { $0 is DestinationAnnotation }
            mapView.removeAnnotations(existingAnnotations)
            
            // Add new annotation
            let annotation = DestinationAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Navigate Here?"
            annotation.subtitle = "Tap to start navigation"
            
            mapView.addAnnotation(annotation)
            
            // Show the callout
            mapView.selectAnnotation(annotation, animated: true)
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
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
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
            if annotation is DestinationAnnotation {
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
                
                return annotationView
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            // Handle the callout button tap
            if let destinationAnnotation = view.annotation as? DestinationAnnotation {
                // Pass the map's user location as fallback
                onDestinationSelected?(destinationAnnotation.coordinate, mapView.userLocation.location)
                
                // Remove the annotation after selection
                mapView.removeAnnotation(destinationAnnotation)
            }
        }
    }
}
