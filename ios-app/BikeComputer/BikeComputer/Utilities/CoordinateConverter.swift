//
//  CoordinateConverter.swift
//  BikeComputer
//
//  Coordinate converter for China mapping systems
//  GCJ-02 (Mars Coordinates) is used by Apple Maps in China
//  WGS-84 is the standard GPS coordinate system
//

import Foundation
import CoreLocation

class CoordinateConverter {
    
    // Semi-major axis of Earth (meters)
    private static let a: Double = 6378245.0
    // Flattening
    private static let ee: Double = 0.00669342162296594323
    
    // China bounds (approximate)
    private static let chinaLatMin: Double = 0.8293
    private static let chinaLatMax: Double = 55.8271
    private static let chinaLonMin: Double = 72.004
    private static let chinaLonMax: Double = 137.8347
    
    /// Check if a coordinate is within mainland China
    static func isInChina(lat: Double, lon: Double) -> Bool {
        return lat >= chinaLatMin && lat <= chinaLatMax &&
               lon >= chinaLonMin && lon <= chinaLonMax
    }
    
    /// Convert GCJ-02 to WGS-84 (only if in China)
    /// Use this to convert Apple Maps routes (GCJ-02) to WGS-84 for display on WGS-84 tiles
    /// Uses iterative method for accurate inverse conversion
    static func gcj02ToWGS84(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        if !isInChina(lat: lat, lon: lon) {
            return (lat, lon)
        }
        
        // Iterative approach for more accurate inverse
        var wgsLat = lat
        var wgsLon = lon
        
        for _ in 0..<3 {
            let gcj = wgs84ToGCJ02(lat: wgsLat, lon: wgsLon)
            wgsLat += (lat - gcj.lat)
            wgsLon += (lon - gcj.lon)
        }
        
        // Apply manual calibration
        return applyCalibration(lat: wgsLat, lon: wgsLon)
    }
    
    /// Apply manual calibration nudge to WGS-84 coordinates
    /// Used to correct specific map tile offsets (e.g. ~50m offset in Shanghai)
    static func applyCalibration(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        // User reports result is ~50m too South-West ("low and left")
        // We add ~50m North (+Lat) and ~50m East (+Lon)
        // 1 deg Lat ~ 111km; 50m = 0.00045
        // 1 deg Lon ~ 96km (Shanghai); 50m = 0.00052
        return (lat + 0.00045, lon + 0.00052)
    }
    
    /// Convert CLLocationCoordinate2D from GCJ-02 to WGS-84
    static func gcj02ToWGS84(coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let converted = gcj02ToWGS84(lat: coordinate.latitude, lon: coordinate.longitude)
        return CLLocationCoordinate2D(latitude: converted.lat, longitude: converted.lon)
    }
    
    /// Convert WGS-84 to GCJ-02 (only if in China)
    /// Returns the original coordinates if outside China
    static func wgs84ToGCJ02(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        if !isInChina(lat: lat, lon: lon) {
            return (lat, lon)
        }
        
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        
        let mgLat = lat + dLat
        let mgLon = lon + dLon
        
        return (mgLat, mgLon)
    }
    
    /// Convert CLLocationCoordinate2D from WGS-84 to GCJ-02
    static func wgs84ToGCJ02(coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let converted = wgs84ToGCJ02(lat: coordinate.latitude, lon: coordinate.longitude)
        return CLLocationCoordinate2D(latitude: converted.lat, longitude: converted.lon)
    }
    
    // MARK: - Private Transform Functions
    
    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y
        ret += 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }
    
    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y
        ret += 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
