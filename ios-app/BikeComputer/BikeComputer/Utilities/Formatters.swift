//
//  Formatters.swift
//  BikeComputer
//
//  Formatting utilities for time, speed, and distance
//

import Foundation

// MARK: - Time Formatter

struct TimeFormatter {
    static func format(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) / 60 % 60
        let seconds = Int(timeInterval) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Measurement Formatter

struct MeasurementFormatter {
    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.1f", metersPerSecond * 3.6)
    }
    
    static func distance(_ meters: Double) -> String {
        String(format: "%.2f", meters / 1000.0)
    }
}

