import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

typealias WorkoutLiveActivityContext =
    ActivityViewContext<WorkoutLiveActivityAttributes>

struct WorkoutLiveActivityLockScreenView: View {
    let context: WorkoutLiveActivityContext

    private var state: WorkoutLiveActivityAttributes.ContentState {
        context.state.displayState(isSystemStale: context.isStale)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkoutLiveActivityStatusView(state: state)
                Spacer(minLength: 4)
                WorkoutLiveActivityElapsedView(
                    state: state,
                    font: .title2.bold().monospacedDigit()
                )
            }

            WorkoutLiveActivityMetricStrip(state: state)

            WorkoutLiveActivityControls(
                sessionID: context.attributes.sessionID,
                state: state
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: 160)
        .foregroundStyle(.white)
    }
}

struct WorkoutLiveActivityStatusView: View {
    let state: WorkoutLiveActivityAttributes.ContentState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            Circle()
                .fill(state.statusColor)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.statusTitle.uppercased())
                    .font(
                        compact
                            ? .caption2.bold()
                            : .caption.bold()
                    )
                    .lineLimit(1)
                if !compact, let detail = state.statusDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.statusAccessibilityLabel)
    }
}

struct WorkoutLiveActivityElapsedView: View {
    let state: WorkoutLiveActivityAttributes.ContentState
    let font: Font

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Group {
                if let timerAnchor = state.wallTimerAnchor,
                   state.phase == .running || state.phase == .paused {
                    Text(timerAnchor, style: .timer)
                } else if let elapsedWallSeconds = state.elapsedWallSeconds {
                    Text(
                        WorkoutLiveActivityFormatting.duration(
                            elapsedWallSeconds
                        )
                    )
                } else if let elapsedActiveSeconds =
                    state.elapsedActiveSeconds {
                    Text(
                        WorkoutLiveActivityFormatting.duration(
                            elapsedActiveSeconds
                        )
                    )
                } else {
                    Text("—")
                }
            }
            .font(font)
            if let elapsedActiveSeconds = state.elapsedActiveSeconds,
               state.elapsedWallSeconds != nil {
                Text(
                    "Moving \(WorkoutLiveActivityFormatting.duration(elapsedActiveSeconds))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityLabel(
            state.elapsedAccessibilityLabel
        )
    }
}

struct WorkoutLiveActivityMetricStrip: View {
    let state: WorkoutLiveActivityAttributes.ContentState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 14) {
            WorkoutLiveActivityMetric(
                value: WorkoutLiveActivityFormatting.speed(
                    state.currentSpeedKilometersPerHour
                ),
                unit: "KM/H",
                label: "Current speed",
                compact: compact
            )
            WorkoutLiveActivityMetric(
                value: WorkoutLiveActivityFormatting.distance(
                    state.cyclingDistanceMeters
                ),
                unit: WorkoutLiveActivityFormatting.distanceUnit(
                    state.cyclingDistanceMeters
                ),
                label: state.phase == .stale
                    || state.phase == .disconnected
                    ? "Last distance"
                    : "Distance",
                compact: compact
            )
            WorkoutLiveActivityMetric(
                value: WorkoutLiveActivityFormatting.heartRate(
                    state.currentHeartRateBPM
                ),
                valueSymbol: "heart.fill",
                accessibilityUnit: "beats per minute",
                label: "Heart rate",
                compact: compact
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WorkoutLiveActivityMetric: View {
    let value: String
    var unit: String? = nil
    var valueSymbol: String? = nil
    var accessibilityUnit: String? = nil
    let label: String
    let compact: Bool

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(
                        compact
                            ? .caption.bold().monospacedDigit()
                            : .title3.bold().monospacedDigit()
                    )
                    .minimumScaleFactor(0.65)
                if let unit {
                    Text(unit)
                        .font(.system(size: compact ? 7 : 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if let valueSymbol, value != "—" {
                    Image(systemName: valueSymbol)
                        .font(.system(size: compact ? 9 : 13, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
            }
            if !compact {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), \(value) \(accessibilityUnit ?? unit ?? "")"
        )
    }
}

struct WorkoutLiveActivityControls: View {
    let sessionID: UUID
    let state: WorkoutLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Button(
                intent: BikeComputerMarkSegmentIntent(sessionID: sessionID)
            ) {
                HStack(spacing: 6) {
                    if state.pendingAction == .segment {
                        Image(systemName: "hourglass")
                    } else {
                        WorkoutLiveActivitySegmentNumberBadge(
                            number: state.currentSegmentIndex
                        )
                    }
                    Text(state.segmentControlTitle)
                }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .invalidatableContent()
            }
            .disabled(!state.canMarkSegment)
            .accessibilityLabel(
                state.pendingAction == .segment
                    ? "Marking workout segment"
                    : "Mark workout segment"
            )
            .accessibilityValue(
                "Current segment \(state.currentSegmentIndex)"
            )

            if state.phase == .paused {
                Button(
                    intent: BikeComputerResumeWorkoutIntent(
                        sessionID: sessionID
                    )
                ) {
                    Label(
                        state.pauseControlTitle,
                        systemImage: state.pauseControlSystemImage
                    )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .invalidatableContent()
                }
                .disabled(!state.canResume)
            } else {
                Button(
                    intent: BikeComputerPauseWorkoutIntent(
                        sessionID: sessionID
                    )
                ) {
                    Label(
                        state.pauseControlTitle,
                        systemImage: state.pauseControlSystemImage
                    )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .invalidatableContent()
                }
                .disabled(!state.canPause)
            }
        }
        .font(.caption.bold())
        .labelStyle(.titleAndIcon)
        .buttonStyle(WorkoutLiveActivityButtonStyle())
        .opacity(state.controlsAreVisuallyAvailable ? 1 : 0.55)
    }
}

private struct WorkoutLiveActivitySegmentNumberBadge: View {
    let number: UInt32

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(lineWidth: 2)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(3)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct WorkoutLiveActivityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.24 : 0.14),
                in: RoundedRectangle(cornerRadius: 12)
            )
    }
}

extension WorkoutLiveActivityAttributes.ContentState {
    var timerAnchor: Date? {
        elapsedActiveSeconds.map {
            capturedAt.addingTimeInterval(-$0)
        }
    }

    var wallTimerAnchor: Date? {
        elapsedWallSeconds.map {
            capturedAt.addingTimeInterval(-$0)
        }
    }

    var elapsedAccessibilityLabel: String {
        let elapsed = elapsedWallSeconds.map {
            "Elapsed \(WorkoutLiveActivityFormatting.duration($0))"
        }
        let moving = elapsedActiveSeconds.map {
            "moving \(WorkoutLiveActivityFormatting.duration($0))"
        }
        return [elapsed, moving].compactMap { $0 }.joined(separator: ", ")
    }

    var statusColor: Color {
        switch phase {
        case .running:
            return .green
        case .paused:
            return .yellow
        case .stale, .disconnected:
            return .orange
        case .ending, .final:
            return .blue
        }
    }

    var statusTitle: String {
        switch phase {
        case .running:
            return "Riding"
        case .paused:
            return pauseOrigin == .automatic ? "Auto-Paused" : "Paused"
        case .stale:
            return "Delayed"
        case .disconnected:
            return "Watch disconnected"
        case .ending:
            return "Finishing"
        case .final:
            switch finalOutcome {
            case .saved:
                return "Ride saved"
            case .discarded:
                return "Ride discarded"
            case .none:
                return "Ride finished"
            }
        }
    }

    var statusDetail: String? {
        switch displayError {
        case .segmentRejected:
            return "Segment wasn’t marked"
        case .segmentUnconfirmed:
            return "Segment confirmation pending"
        case .controlsUnavailable:
            return "Ride continues on Apple Watch"
        case .finalSummaryUnavailable:
            return "Final summary unavailable"
        case .none:
            break
        }
        if let segment = WorkoutLiveActivityFormatting.segmentSummary(
            index: lastCompletedSegmentIndex,
            duration: lastCompletedSegmentDuration,
            distanceMeters: lastCompletedSegmentDistanceMeters
        ) {
            return segment
        }
        return "Segment \(currentSegmentIndex)"
    }

    var statusAccessibilityLabel: String {
        [statusTitle, statusDetail].compactMap { $0 }.joined(separator: ", ")
    }

    var minimalSymbolName: String {
        switch phase {
        case .paused:
            return "pause.circle.fill"
        case .stale, .disconnected:
            return "applewatch.slash"
        case .ending, .final:
            return "checkmark.circle.fill"
        case .running:
            return "figure.outdoor.cycle"
        }
    }

    var controlsAreVisuallyAvailable: Bool {
        canMarkSegment || canPause || canResume
    }
}
