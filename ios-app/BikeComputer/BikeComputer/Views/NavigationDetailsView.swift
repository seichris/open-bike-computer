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
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

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
            .padding(.bottom, 16)
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

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: NavigationIcon.icon(for: iconID))
                .font(.system(size: 58, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 70, height: 70)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(formattedDistance)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.78)

                Text(instruction)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.66))
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 46, height: 5)
                .padding(.bottom, 10)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var formattedDistance: String {
        NavigationFormatters.distance(distanceToManeuver)
    }
}

struct NavigationMetricsPanel: View {
    let arrivalDate: Date?
    let remainingTime: TimeInterval?
    let remainingDistance: CLLocationDistance?
    let onStopNavigation: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(Color.secondary.opacity(0.32))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            HStack(alignment: .center, spacing: 0) {
                NavigationMetricColumn(value: formattedArrival, label: "arrival")
                NavigationMetricColumn(value: formattedTime, label: timeUnit)
                NavigationMetricColumn(value: formattedDistance, label: distanceUnit)
            }
            .padding(.horizontal, 12)

            Button(action: onStopNavigation) {
                Text("End")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .accessibilityLabel("End navigation")
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
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
