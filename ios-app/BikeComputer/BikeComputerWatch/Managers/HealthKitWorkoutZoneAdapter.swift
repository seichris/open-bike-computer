#if BICINO_HEALTHKIT_WORKOUT_ZONES
import Foundation
import HealthKit

/// The only boundary that knows the OS 27 symbols. Older SDKs do not compile
/// this branch; older Watches do not execute it. See native-healthkit-zones.md.
@available(watchOS 27.0, *)
nonisolated enum HealthKitWorkoutZoneAdapter {
    static func configuration(
        _ native: HKWorkoutZoneConfiguration
    ) -> WorkoutNativeZoneConfigurationV1? {
        let metric: WorkoutNativeZoneMetricV1
        if native.quantityType == HKQuantityType(.heartRate) { metric = .heartRate }
        else if native.quantityType == HKQuantityType(.cyclingPower) { metric = .cyclingPower }
        else { return nil }
        let unit = unit(for: metric)
        guard (3...9).contains(native.zones.count) else { return nil }
        var ranges: [WorkoutNativeZoneRangeV1] = []
        for (index, zone) in native.zones.enumerated() {
            guard zone.index == index,
                  zone.minimum.map({ $0.is(compatibleWith: unit) }) ?? true,
                  zone.maximum.map({ $0.is(compatibleWith: unit) }) ?? true else { return nil }
            ranges.append(WorkoutNativeZoneRangeV1(
                minimum: zone.minimum?.doubleValue(for: unit),
                maximum: zone.maximum?.doubleValue(for: unit)
            ))
        }
        let source: WorkoutNativeZoneSourceV1
        switch native.source {
        case .system: source = .system
        case .user: source = .user
        case .app: source = .app
        @unknown default: source = .unknown
        }
        let value = WorkoutNativeZoneConfigurationV1(metric: metric, source: source, ranges: ranges)
        return value.isValid ? value : nil
    }

    static func group(
        _ native: HKWorkoutZoneGroup?, observedAt: Date, isFinal: Bool,
        maximumDuration: TimeInterval
    ) -> WorkoutNativeZoneSnapshotV1? {
        guard let native, let configuration = configuration(native.configuration),
              native.zoneDurations.count == configuration.ranges.count,
              maximumDuration.isFinite, maximumDuration >= 0 else { return nil }
        let unit = unit(for: configuration.metric)
        var durations: [TimeInterval] = []
        for (index, duration) in native.zoneDurations.enumerated() {
            let zone = duration.zone
            guard zone.index == index,
                  zone.minimum.map({ $0.is(compatibleWith: unit) }) ?? true,
                  zone.maximum.map({ $0.is(compatibleWith: unit) }) ?? true,
                  zone.minimum?.doubleValue(for: unit) == configuration.ranges[index].minimum,
                  zone.maximum?.doubleValue(for: unit) == configuration.ranges[index].maximum else { return nil }
            durations.append(duration.duration)
        }
        let value = WorkoutNativeZoneSnapshotV1(
            configuration: configuration, secondsByZone: durations, observedAt: observedAt,
            currentZone: nil, currentZoneSampleAt: nil, isFinal: isFinal
        )
        guard value.isValid, durations.reduce(0, +) <= maximumDuration + 1 else { return nil }
        return value
    }

    static func event(_ update: HKLiveWorkoutZoneUpdate) -> WorkoutNativeZoneEventV1? {
        guard let nativeGroup = update.zoneGroup,
              let configuration = configuration(nativeGroup.configuration),
              let sampleAt = update.lastSampleProcessedDate else { return nil }
        return WorkoutNativeZoneEventV1.make(
            configuration: configuration,
            zeroBasedIndex: update.currentZoneDuration?.zone.index,
            sampleAt: sampleAt
        )
    }

    static func saved(_ workout: HKWorkout) -> WorkoutNativeZonesV1? {
        let value = WorkoutNativeZonesV1(
            heartRate: group(workout.zoneGroupsByType?[HKQuantityType(.heartRate)],
                             observedAt: workout.endDate, isFinal: true, maximumDuration: workout.duration),
            cyclingPower: group(workout.zoneGroupsByType?[HKQuantityType(.cyclingPower)],
                                observedAt: workout.endDate, isFinal: true, maximumDuration: workout.duration)
        )
        return value.isValid ? value : nil
    }

    private static func unit(for metric: WorkoutNativeZoneMetricV1) -> HKUnit {
        metric == .heartRate ? .count().unitDivided(by: .minute()) : .watt()
    }
}
#endif
