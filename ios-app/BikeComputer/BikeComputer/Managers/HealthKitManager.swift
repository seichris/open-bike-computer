//
//  HealthKitManager.swift
//  BikeComputer
//
//  HealthKit integration for workout tracking
//

import Foundation
import Combine

#if HEALTHKIT_ENABLED && canImport(HealthKit)
import HealthKit

class HealthKitManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isWorkoutActive = false
    @Published var workoutElapsedTime: TimeInterval = 0
    @Published var workoutStartTime: Date?
    @Published var heartRate: Double = 0
    @Published var currentSpeed: Double = 0 // m/s
    @Published var distanceTraveled: Double = 0 // meters

    private let healthStore = HKHealthStore()
    private var workoutTimer: Timer?
    
    weak var locationManager: CurrentLocationManager?
    
    // MARK: - Computed Properties (Optimization #1)
    
    /// Current speed in km/h
    var currentSpeedKmh: Double {
        currentSpeed * 3.6
    }
    
    /// Distance traveled in km
    var distanceKm: Double {
        distanceTraveled / 1000.0
    }
    
    /// Formatted time string for elapsed time
    var formattedElapsedTime: String {
        TimeFormatter.format(workoutElapsedTime)
    }
    
    /// Heart rate as integer, or nil if not available
    var heartRateInt: Int? {
        heartRate > 0 ? Int(heartRate) : nil
    }

    override init() {
        super.init()
        requestAuthorization()
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("HealthKit not available on this device")
            return
        }

        let typesToWrite: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        ]
        
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]

        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.isAuthorized = true
                    print("HealthKit authorization granted")
                } else {
                    self?.isAuthorized = false
                    if let error = error {
                        print("HealthKit authorization failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    func updateLocation(speed: Double, distance: Double) {
        DispatchQueue.main.async {
            self.currentSpeed = speed
            self.distanceTraveled = distance
        }
    }

    func startBikeWorkout() {
        // Optimization #13: Defensive authorization check
        guard isAuthorized && HKHealthStore.isHealthDataAvailable() else {
            print("HealthKit not authorized or not available")
            return
        }

        workoutStartTime = Date()
        isWorkoutActive = true
        distanceTraveled = 0
        heartRate = 0
        currentSpeed = 0
        locationManager?.resetDistance()
        locationManager?.updateLocationTracking() // Optimization #3: Enable location tracking
        startWorkoutTimer()
        print("📱 Bike workout started - will save to HealthKit when ended")
    }
    
    func endBikeWorkout() {
        guard let startTime = workoutStartTime else {
            cleanupWorkout()
            return
        }

        let endDate = Date()
        let duration = endDate.timeIntervalSince(startTime)
        
        // Create distance quantity if distance was tracked
        let distanceQuantity: HKQuantity? = distanceTraveled > 0 ? HKQuantity(unit: .meter(), doubleValue: distanceTraveled) : nil

        let workout = HKWorkout(
            activityType: .cycling,
            start: startTime,
            end: endDate,
            duration: duration,
            totalEnergyBurned: nil,
            totalDistance: distanceQuantity,
            device: HKDevice.local(),
            metadata: nil
        )

        healthStore.save(workout) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ Workout saved to HealthKit (Distance: \(String(format: "%.2f", (self?.distanceTraveled ?? 0) / 1000)) km)")
                } else if let error = error {
                    print("Failed to save: \(error.localizedDescription)")
                }
                self?.cleanupWorkout()
            }
        }
    }
    
    // MARK: - Combined Timer (Optimization #2 & #9)
    
    private var heartRatePollCounter = 0
    
    private func startWorkoutTimer() {
        heartRatePollCounter = 0
        
        // Single timer at 1-second interval for both elapsed time and heart rate
        workoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.workoutStartTime else {
                // Optimization #9: Invalidate timer if workout ended unexpectedly
                self?.stopWorkoutTimer()
                return
            }
            
            // Update elapsed time every second
            self.workoutElapsedTime = Date().timeIntervalSince(startTime)
            
            // Poll heart rate every 2 seconds (counter: 0, 2, 4, 6...)
            self.heartRatePollCounter += 1
            if self.heartRatePollCounter % 2 == 0 {
                self.fetchLatestHeartRate()
            }
        }
        
        // Fetch heart rate immediately on start
        fetchLatestHeartRate()
        print("Started workout timer (combined elapsed time & heart rate)")
    }
    
    private func fetchLatestHeartRate() {
        // Optimization #13: Guard against unauthorized access
        guard isAuthorized, HKHealthStore.isHealthDataAvailable() else { return }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        
        let now = Date()
        let tenSecondsAgo = now.addingTimeInterval(-10)
        let predicate = HKQuery.predicateForSamples(withStart: tenSecondsAgo, end: now, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: heartRateType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { [weak self] query, samples, error in
            if let samples = samples as? [HKQuantitySample], let sample = samples.first {
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                let bpm = sample.quantity.doubleValue(for: heartRateUnit)
                
                DispatchQueue.main.async {
                    self?.heartRate = bpm
                }
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Cleanup (Optimization #9)
    
    private func cleanupWorkout() {
        stopWorkoutTimer()
        
        // Reset all workout state
        isWorkoutActive = false
        workoutStartTime = nil
        workoutElapsedTime = 0
        heartRate = 0
        currentSpeed = 0
        distanceTraveled = 0
        heartRatePollCounter = 0
        
        locationManager?.updateLocationTracking() // Optimization #3: Update location tracking state
        
        print("Workout cleaned up")
    }
    
    private func stopWorkoutTimer() {
        workoutTimer?.invalidate()
        workoutTimer = nil
        print("Stopped workout timer")
    }
    
    deinit {
        // Ensure timers are cleaned up when object is deallocated
        stopWorkoutTimer()
    }
}

#else

/// Stub implementation used when HealthKit is not enabled for this build.
/// This keeps the rest of the app compiling/running without HealthKit entitlements.
class HealthKitManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isWorkoutActive = false
    @Published var workoutElapsedTime: TimeInterval = 0
    @Published var workoutStartTime: Date?
    @Published var heartRate: Double = 0
    @Published var currentSpeed: Double = 0 // m/s
    @Published var distanceTraveled: Double = 0 // meters

    weak var locationManager: CurrentLocationManager?

    // MARK: - Computed Properties

    var currentSpeedKmh: Double { currentSpeed * 3.6 }
    var distanceKm: Double { distanceTraveled / 1000.0 }
    var formattedElapsedTime: String { TimeFormatter.format(workoutElapsedTime) }
    var heartRateInt: Int? { heartRate > 0 ? Int(heartRate) : nil }

    override init() {
        super.init()
        isAuthorized = false
    }

    func requestAuthorization() {
        isAuthorized = false
    }

    func updateLocation(speed: Double, distance: Double) {
        DispatchQueue.main.async {
            self.currentSpeed = speed
            self.distanceTraveled = distance
        }
    }

    func startBikeWorkout() {
        // No-op in builds without HealthKit.
        isAuthorized = false
        isWorkoutActive = false
    }

    func endBikeWorkout() {
        isWorkoutActive = false
    }
}

#endif
