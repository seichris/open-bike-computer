//
//  NavigationDetailsView.swift
//  BikeComputer
//
//  Navigation instruction display view
//

import SwiftUI
import CoreLocation

struct NavigationDetailsView: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let isCompact: Bool
    
    init(iconID: Int, distanceToManeuver: Int, instruction: String, isCompact: Bool = false) {
        self.iconID = iconID
        self.distanceToManeuver = distanceToManeuver
        self.instruction = instruction
        self.isCompact = isCompact
    }
    
    var body: some View {
        VStack(spacing: isCompact ? 15 : 20) {
            // Arrow Icon
            Image(systemName: NavigationIcon.icon(for: iconID))
                .font(.system(size: isCompact ? 60 : 80))
                .foregroundColor(.blue)
            
            // Distance
            Text("\(distanceToManeuver)")
                .font(.system(size: isCompact ? 56 : 72, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("meters")
                .font(isCompact ? .title3 : .title2)
                .foregroundColor(.secondary)
            
            // Instruction
            Text(instruction)
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .lineLimit(isCompact ? 2 : nil)
        }
    }
}

struct MapNavigationInstructionCard: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let onStopNavigation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 48, height: 48)

                    Image(systemName: NavigationIcon.icon(for: iconID))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDistance)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text(instruction)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: onStopNavigation) {
                    Text("End")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End navigation")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    private var formattedDistance: String {
        if distanceToManeuver >= 1000 {
            return String(format: "%.1f km", Double(distanceToManeuver) / 1000)
        }

        return "\(distanceToManeuver) m"
    }
}

struct NavigationInstructionBanner: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let isCompactHeight: Bool

    init(
        iconID: Int,
        distanceToManeuver: Int,
        instruction: String,
        isCompactHeight: Bool = false
    ) {
        self.iconID = iconID
        self.distanceToManeuver = distanceToManeuver
        self.instruction = instruction
        self.isCompactHeight = isCompactHeight
    }

    var body: some View {
        HStack(alignment: .center, spacing: isCompactHeight ? 10 : 18) {
            Image(systemName: NavigationIcon.icon(for: iconID))
                .font(.system(size: isCompactHeight ? 34 : 58, weight: .bold))
                .foregroundColor(.white)
                .frame(
                    width: isCompactHeight ? 42 : 70,
                    height: isCompactHeight ? 42 : 70
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: isCompactHeight ? 2 : 6) {
                Text(formattedDistance)
                    .font(.system(
                        size: isCompactHeight ? 24 : 38,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.78)

                Text(instruction)
                    .font(.system(
                        size: isCompactHeight ? 17 : 28,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineLimit(isCompactHeight ? 2 : nil)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, isCompactHeight ? 14 : 24)
        .padding(.vertical, isCompactHeight ? 8 : 18)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.66))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var formattedDistance: String {
        NavigationFormatters.distance(distanceToManeuver)
    }
}

struct RideMetricsPanel: View {
    @ObservedObject var workoutStore: WorkoutMetricsStore
    @ObservedObject var watchAvailability: WorkoutWatchAvailabilityMonitor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let isNavigating: Bool
    let isCompactHeight: Bool
    let arrivalDate: Date?
    let remainingTime: TimeInterval?
    let remainingDistance: CLLocationDistance?
    let onStopNavigation: () -> Void
    let onStartWorkout: () -> Void
    let onPauseWorkout: () -> Void
    let onResumeWorkout: () -> Void
    let onEndAndSaveWorkout: () -> Void
    let onDiscardWorkout: () -> Void

    var body: some View {
        Group {
            if isCompactHeight && dynamicTypeSize.isAccessibilitySize {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        metricContent
                            .padding(.vertical, 4)
                        controls
                            .padding(.top, 2)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                    .padding(.top, 8)
                }
            } else {
                VStack(spacing: isCompactHeight ? 8 : 12) {
                    if isCompactHeight {
                        ScrollView(.vertical, showsIndicators: true) {
                            metricContent
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 140)
                    } else {
                        metricContent
                    }

                    controls
                        .padding(.top, 2)
                        .padding(.horizontal, isCompactHeight ? 10 : 18)
                        .padding(.bottom, isCompactHeight ? 8 : 14)
                }
                .padding(.top, isCompactHeight ? 8 : 18)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isCompactHeight ? 215 : nil)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private var metricContent: some View {
        if workoutStore.presentation.isWorkoutActive {
            workoutStatusBanner
            workoutMetrics
        }

        if isNavigating {
            HStack(alignment: .center, spacing: 0) {
                NavigationMetricColumn(value: formattedArrival, label: "arrival")
                NavigationMetricColumn(value: formattedTime, label: timeUnit)
                NavigationMetricColumn(value: formattedDistance, label: distanceUnit)
            }
            .padding(.horizontal, 12)
        }
    }

    private var workoutMetrics: some View {
        let snapshot = workoutStore.presentation.snapshot
        let suppressInstantaneous = suppressInstantaneousMetrics
        return VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 0) {
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.whole(
                            suppressInstantaneous
                                ? nil
                                : snapshot.cyclingCadence?.value
                        ),
                        unit: "rpm"
                    ),
                    label: "cadence"
                )
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.whole(
                            suppressInstantaneous
                                ? nil
                                : snapshot.cyclingPower?.value
                        ),
                        unit: "W"
                    ),
                    label: "power"
                )
            }

            HStack(alignment: .center, spacing: 0) {
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.speed(
                            suppressInstantaneous
                                ? nil
                                : snapshot.currentSpeed?.value
                        ),
                        unit: "km/h"
                    ),
                    label: "speed"
                )
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.distance(snapshot.cyclingDistance?.value),
                        unit: WorkoutValueFormatter.distanceUnit(
                            snapshot.cyclingDistance?.value
                        ).lowercased()
                    ),
                    label: "distance"
                )
                RideMetricColumn(
                    value: valueWithUnit(
                        altitudeValue(
                            suppressInstantaneous
                                ? nil
                                : snapshot.location?.altitude
                        ),
                        unit: "m"
                    ),
                    label: "altitude"
                )
            }

            HStack(alignment: .center, spacing: 0) {
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.heartRate(
                            suppressInstantaneous
                                ? nil
                                : snapshot.currentHeartRate?.value
                        ),
                        unit: "bpm"
                    ),
                    label: "heart rate"
                )
                RideMetricColumn(
                    value: suppressInstantaneous
                        ? "--"
                        : heartRateZone(snapshot),
                    label: "heart zone"
                )
                RideMetricColumn(
                    value: valueWithUnit(
                        WorkoutValueFormatter.energy(snapshot.activeEnergy?.value),
                        unit: "kcal"
                    ),
                    label: "energy"
                )
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var workoutStatusBanner: some View {
        let presentation = workoutStore.presentation
        if presentation.connectionState == .launchingWatch {
            workoutStatus("Starting workout on Apple Watch", color: .orange)
        } else if presentation.connectionState == .awaitingFirstSnapshot {
            workoutStatus("Waiting for Watch metrics", color: .orange)
        } else if presentation.connectionState == .stale {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                workoutStatus(
                    delayedWorkoutStatus(at: context.date),
                    color: .orange
                )
            }
        } else if presentation.connectionState == .disconnected {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                workoutStatus(
                    disconnectedWorkoutStatus(at: context.date),
                    color: .red
                )
            }
        } else if presentation.errorCode != nil {
            workoutStatus("Workout needs attention", color: .orange)
        }
    }

    private func workoutStatus(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(color)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                navigationControl
                workoutControls
            }
        } else {
            HStack(spacing: 8) {
                navigationControl
                workoutControls
            }
        }
    }

    @ViewBuilder
    private var navigationControl: some View {
        if isNavigating {
            Button(action: onStopNavigation) {
                RideControlLabel("End", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("End navigation")
        }
    }

    @ViewBuilder
    private var workoutControls: some View {
        let presentation = workoutStore.presentation
        if presentation.isWorkoutActive {
            if presentation.sessionState == .paused {
                Button(action: onResumeWorkout) {
                    RideControlLabel(
                        "Resume workout",
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!canControlWorkout)
            } else {
                Button(action: onPauseWorkout) {
                    RideControlLabel(
                        "Pause workout",
                        systemImage: "pause.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(
                    presentation.sessionState != .running
                        || !canControlWorkout
                )
            }

            WorkoutFinishButton(
                store: workoutStore,
                onEndAndSave: onEndAndSaveWorkout,
                onDiscard: onDiscardWorkout
            ) {
                RideControlLabel(
                    "End workout",
                    systemImage: "stop.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(
                presentation.sessionState == .ending
                    || !canControlWorkout
            )
        } else if isNavigating && presentation.canStartNewWorkout {
            WorkoutStartButton(
                watchAvailability: watchAvailability,
                action: onStartWorkout
            ) {
                RideControlLabel(
                    "Start Workout",
                    systemImage: "figure.outdoor.cycle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityLabel("Start workout on Apple Watch")
        }
    }

    private var canControlWorkout: Bool {
        let presentation = workoutStore.presentation
        return presentation.sessionID != nil
            && presentation.pendingControl == nil
            && presentation.connectionState != .disconnected
    }

    private var suppressInstantaneousMetrics: Bool {
        let state = workoutStore.presentation.connectionState
        switch state {
        case .launchingWatch, .awaitingFirstSnapshot, .stale, .disconnected:
            return true
        case .unsupported, .idle, .connected, .ended, .failed:
            return false
        }
    }

    private func delayedWorkoutStatus(at date: Date) -> String {
        ageQualifiedStatus("Workout data delayed", at: date)
    }

    private func disconnectedWorkoutStatus(at date: Date) -> String {
        ageQualifiedStatus("Apple Watch disconnected", at: date)
    }

    private func ageQualifiedStatus(_ prefix: String, at date: Date) -> String {
        guard let age = workoutStore.presentation.captureAge(at: date) else {
            return prefix
        }
        return "\(prefix) · \(Int(age.rounded(.down)))s old"
    }

    private var formattedArrival: String {
        guard let arrivalDate else { return "--" }
        return NavigationFormatters.arrivalTime.string(from: arrivalDate)
    }

    private var formattedTime: String {
        guard let remainingTime else { return "--" }
        if remainingTime >= 60 * 60 {
            let hours = Int(remainingTime / 3600)
            let minutes = Int((remainingTime.truncatingRemainder(dividingBy: 3600)) / 60)
            return minutes > 0 ? "\(hours)h \(minutes)" : "\(hours)h"
        }
        return "\(max(Int(ceil(remainingTime / 60)), 1))"
    }

    private var timeUnit: String {
        guard let remainingTime, remainingTime >= 60 * 60 else { return "min" }
        return "time"
    }

    private var formattedDistance: String {
        guard let remainingDistance else { return "--" }
        if remainingDistance >= 1000 {
            return String(format: "%.1f", remainingDistance / 1000)
        }
        return "\(Int(max(remainingDistance.rounded(), 0)))"
    }

    private var distanceUnit: String {
        guard let remainingDistance, remainingDistance < 1000 else { return "km" }
        return "m"
    }

    private func heartRateZone(_ snapshot: WorkoutSnapshotV1) -> String {
        guard let zone = snapshot.currentHeartRateZone else { return "--" }
        return "Zone \(zone)"
    }

    private func altitudeValue(_ altitude: Double?) -> String {
        guard let altitude, altitude.isFinite else { return "--" }
        return String(format: "%.0f", altitude)
    }

    private func valueWithUnit(_ value: String, unit: String) -> String {
        value == "--" ? value : "\(value) \(unit)"
    }
}

private struct RideControlLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .frame(maxWidth: .infinity)
    }
}

private struct RideMetricColumn: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct NavigationMetricColumn: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private enum NavigationFormatters {
    static let arrivalTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func distance(_ meters: Int) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", Double(meters) / 1000)
        }

        return "\(max(meters, 0)) m"
    }
}

// MARK: - Navigation Icon Mapping

enum NavigationIcon {
    static func icon(for iconID: Int) -> String {
        switch iconID {
        case NavigationIconID.left: return "arrow.turn.up.left"
        case NavigationIconID.right: return "arrow.turn.up.right"
        case NavigationIconID.uTurn: return "arrow.uturn.left"
        case NavigationIconID.straight: return "arrow.up"
        default: return "arrow.up"
        }
    }
}
