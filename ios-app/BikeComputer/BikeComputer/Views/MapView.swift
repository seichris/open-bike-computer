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
    let onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        
        // Configure map appearance
        mapView.showsCompass = true
        mapView.showsScale = true
        
        // Add long press gesture recognizer
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)
        
        // Store the callback in coordinator
        context.coordinator.onDestinationSelected = onDestinationSelected
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Store reference to map view in coordinator
        context.coordinator.mapView = uiView
        
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
            // Disable user tracking when showing route
            uiView.userTrackingMode = .none
            
            // Remove old overlays
            uiView.removeOverlays(uiView.overlays)
            
            // Add new route overlay
            uiView.addOverlay(route.polyline, level: .aboveRoads)
            
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
        }
        
        // Update simulated position
        let existingSimAnnotations = uiView.annotations.filter { $0 is SimulatedPositionAnnotation }
        
        if isSimulationMode, let simPos = simulatedPosition {
            // Hide real user location
            if uiView.showsUserLocation {
                uiView.showsUserLocation = false
            }
            
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
            // Remove sim annotation if present
            if !existingSimAnnotations.isEmpty {
                uiView.removeAnnotations(existingSimAnnotations)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastRoute: MKRoute?
        var mapView: MKMapView?
        var onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
        var hasSetInitialRegion = false
        
        @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard gestureRecognizer.state == .began,
                  let mapView = mapView else { return }
            
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

