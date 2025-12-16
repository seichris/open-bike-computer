//
//  WorkoutMetricsView.swift
//  BikeComputer
//
//  Workout metrics display components
//

import SwiftUI

/// Compact workout metrics display (used during navigation)
struct CompactWorkoutMetricsView: View {
    let currentSpeedKmh: Double
    let distanceKm: Double
    let heartRate: Int?
    let formattedElapsedTime: String
    let isHealthKitAuthorized: Bool
    let onEndWorkout: () -> Void
    let onStartWorkout: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Workout Active")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Metrics Grid (2x2)
            HStack(spacing: 20) {
                // Speed
                MetricView(
                    icon: "gauge.high",
                    value: String(format: "%.1f", currentSpeedKmh),
                    unit: "km/h",
                    color: .blue
                )
                
                // Distance
                MetricView(
                    icon: "road.lanes",
                    value: String(format: "%.2f", distanceKm),
                    unit: "km",
                    color: .green
                )
            }
            
            HStack(spacing: 20) {
                // Heart Rate
                MetricView(
                    icon: "heart.fill",
                    value: heartRate.map { "\($0)" } ?? "--",
                    unit: "BPM",
                    color: .red
                )
                
                // Time
                MetricView(
                    icon: "timer",
                    value: formattedElapsedTime,
                    unit: "TIME",
                    color: .orange,
                    isMonospaced: true
                )
            }
            
            // End Workout Button (small version)
            Button(action: onEndWorkout) {
                Label("End Workout", systemImage: "stop.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .cornerRadius(10)
            }
        }
    }
}

/// Full workout display (not navigating)
struct FullWorkoutView: View {
    let currentSpeedKmh: Double
    let distanceKm: Double
    let heartRate: Int?
    let formattedElapsedTime: String
    let onEndWorkout: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            // Workout Icon
            Image(systemName: "bicycle")
                .font(.system(size: 50))
                .foregroundColor(.green)
            
            Text("Workout Active")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.green)
            
            // Large Metrics Grid
            VStack(spacing: 20) {
                HStack(spacing: 30) {
                    LargeMetricView(
                        icon: "gauge.high",
                        value: String(format: "%.1f", currentSpeedKmh),
                        unit: "km/h",
                        color: .blue
                    )
                    
                    LargeMetricView(
                        icon: "road.lanes",
                        value: String(format: "%.2f", distanceKm),
                        unit: "km",
                        color: .green
                    )
                }
                
                HStack(spacing: 30) {
                    LargeMetricView(
                        icon: "heart.fill",
                        value: heartRate.map { "\($0)" } ?? "--",
                        unit: "BPM",
                        color: .red
                    )
                    
                    LargeMetricView(
                        icon: "timer",
                        value: formattedElapsedTime,
                        unit: "TIME",
                        color: .orange,
                        isMonospaced: true
                    )
                }
            }
            
            // End Workout Button
            Button(action: onEndWorkout) {
                Label("End Bike Workout", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(15)
            }
        }
        .padding(.horizontal, 30)
    }
}

/// Start workout button view
struct StartWorkoutView: View {
    let isHealthKitAuthorized: Bool
    let onStartWorkout: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "bicycle")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Start Bike Workout")
                .font(.title2)
                .fontWeight(.semibold)
            
            Button(action: onStartWorkout) {
                Label("Start Bike Workout", systemImage: "play.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isHealthKitAuthorized ? Color.green : Color.gray)
                    .cornerRadius(15)
            }
            .disabled(!isHealthKitAuthorized)
            
            if !isHealthKitAuthorized {
                Text("HealthKit access required for workout tracking")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Metric Display Components

private struct MetricView: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color
    var isMonospaced: Bool = false
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: isMonospaced ? .monospaced : .rounded))
                .foregroundColor(.primary)
            Text(unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LargeMetricView: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color
    var isMonospaced: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: isMonospaced ? .monospaced : .rounded))
                .foregroundColor(.primary)
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

