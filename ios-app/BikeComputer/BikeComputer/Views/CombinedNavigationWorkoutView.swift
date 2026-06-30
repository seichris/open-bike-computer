//
//  CombinedNavigationWorkoutView.swift
//  BikeComputer
//
//  Combined navigation and workout display
//

import SwiftUI

/// Combined view showing navigation + workout status
struct CombinedNavigationWorkoutView: View {
    @ObservedObject var coordinator: BikeComputerCoordinator
    
    var body: some View {
        VStack(spacing: 15) {
            // Navigation section (when navigating)
            if coordinator.isNavigating {
                NavigationDetailsView(
                    iconID: coordinator.currentIconID,
                    distanceToManeuver: coordinator.distanceToManeuver,
                    instruction: coordinator.currentInstruction,
                    isCompact: true
                )
            }
            
            if coordinator.isNavigating {
                Divider()
                    .padding(.vertical, 5)
            }
            
            // Workout section
            if coordinator.isWorkoutActive {
                CompactWorkoutMetricsView(
                    currentSpeedKmh: coordinator.currentSpeedKmh,
                    distanceKm: coordinator.distanceKm,
                    heartRate: coordinator.heartRate,
                    formattedElapsedTime: coordinator.formattedElapsedTime,
                    isHealthKitAuthorized: coordinator.isHealthKitAuthorized,
                    onEndWorkout: { coordinator.endWorkout() },
                    onStartWorkout: { coordinator.startWorkout() }
                )
            } else if coordinator.isNavigating {
                if coordinator.isHealthKitAvailable {
                    Button(action: {
                        coordinator.startWorkout()
                    }) {
                        Label("Start Workout", systemImage: "play.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(coordinator.isHealthKitAuthorized ? Color.green : Color.gray)
                            .cornerRadius(10)
                    }
                    .disabled(!coordinator.isHealthKitAuthorized)

                    if !coordinator.isHealthKitAuthorized {
                        Text("HealthKit access required")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Workout tracking unavailable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
}

/// Workout-only view (when not navigating)
struct WorkoutOnlyView: View {
    @ObservedObject var coordinator: BikeComputerCoordinator
    
    var body: some View {
        VStack(spacing: 30) {
            if coordinator.isWorkoutActive {
                FullWorkoutView(
                    currentSpeedKmh: coordinator.currentSpeedKmh,
                    distanceKm: coordinator.distanceKm,
                    heartRate: coordinator.heartRate,
                    formattedElapsedTime: coordinator.formattedElapsedTime,
                    onEndWorkout: { coordinator.endWorkout() }
                )
            } else {
                StartWorkoutView(
                    isHealthKitAvailable: coordinator.isHealthKitAvailable,
                    isHealthKitAuthorized: coordinator.isHealthKitAuthorized,
                    onStartWorkout: { coordinator.startWorkout() }
                )
            }
        }
        .padding(.horizontal, 30)
    }
}
