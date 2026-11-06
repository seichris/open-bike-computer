//
//  CoordinateConverter.swift
//  BikeComputer
//
//  Coordinate converter for China mapping systems
//  GCJ-02 (Mars Coordinates) is used by Apple Maps in mainland China
//  WGS-84 is the standard GPS coordinate system
//

import Foundation
import CoreLocation

/// Converts between WGS-84 and Apple Maps coordinates, which are GCJ-02 only
/// inside `MainlandChinaRegion`; `GCJ02` holds the shared implementation.
nonisolated class CoordinateConverter {

    /// Check if a WGS-84 coordinate is within mainland China, where Apple Maps
    /// uses GCJ-02. Hong Kong, Macau and Taiwan are outside.
    static func isInChina(lat: Double, lon: Double) -> Bool {
        MainlandChinaRegion.contains(latitude: lat, longitude: lon)
    }

    /// Convert GCJ-02 to WGS-84 (only if in China)
    /// Use this to convert Apple Maps routes (GCJ-02) to WGS-84 for display on WGS-84 tiles
    /// Uses iterative method for accurate inverse conversion
    static func gcj02ToWGS84(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        let converted = GCJ02.wgs84(fromMapKit: lat, longitude: lon)
        return (converted.latitude, converted.longitude)
    }

    /// Convert CLLocationCoordinate2D from GCJ-02 to WGS-84
    static func gcj02ToWGS84(coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let converted = gcj02ToWGS84(lat: coordinate.latitude, lon: coordinate.longitude)
        return CLLocationCoordinate2D(latitude: converted.lat, longitude: converted.lon)
    }

    /// Convert WGS-84 to GCJ-02 (only if in China)
    /// Returns the original coordinates if outside China
    static func wgs84ToGCJ02(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        let converted = GCJ02.mapKit(fromWGS84: lat, longitude: lon)
        return (converted.latitude, converted.longitude)
    }

    /// Convert CLLocationCoordinate2D from WGS-84 to GCJ-02
    static func wgs84ToGCJ02(coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let converted = wgs84ToGCJ02(lat: coordinate.latitude, lon: coordinate.longitude)
        return CLLocationCoordinate2D(latitude: converted.lat, longitude: converted.lon)
    }

    /// Convert a GPS location into the coordinate space used by MapKit routes in mainland China.
    /// CoreLocation reports GPS coordinates, while Apple map routes/overlays in China align to GCJ-02.
    static func mapKitRouteLocation(fromGPSLocation location: CLLocation) -> CLLocation {
        guard isInChina(lat: location.coordinate.latitude, lon: location.coordinate.longitude) else {
            return location
        }

        let coordinate = wgs84ToGCJ02(coordinate: location.coordinate)
        return CLLocation(
            coordinate: coordinate,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: location.course,
            speed: location.speed,
            timestamp: location.timestamp
        )
    }
}
