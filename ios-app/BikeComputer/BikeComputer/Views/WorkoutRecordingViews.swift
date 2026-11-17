import SwiftUI

private nonisolated struct WorkoutSessionCoordinatorKey: EnvironmentKey {
    static let defaultValue: WorkoutSessionCoordinator? = nil
}

extension EnvironmentValues {
    var workoutSessionCoordinator: WorkoutSessionCoordinator? {
        get { self[WorkoutSessionCoordinatorKey.self] }
        set { self[WorkoutSessionCoordinatorKey.self] = newValue }
    }
}

/// Explicit choices and recovery actions. A disconnected Watch is never treated
/// as an invitation to silently start recording on a second device.
struct WorkoutRecordingStatusView: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    @ObservedObject var store: WorkoutMetricsStore
    @State private var confirmsWatchIdle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = coordinator.record {
                Label("Recorder: \(record.owner.displayName)",
                      systemImage: record.owner == .iphone ? "iphone" : "applewatch")
                    .font(.subheadline.weight(.semibold))
                if record.phase != .finished {
                    Text("This recorder stays selected if devices disconnect or reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let continuation = record.continuation {
                    Text("Continued from Apple Watch at \(continuation.handoffAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.canContinueOnIPhone {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bicino isn’t receiving this ride from Apple Watch. Apple Watch stays the recorder and keeps the ride if it reconnects. To keep recording now, continue on iPhone.")
                        .font(.subheadline)
                    WorkoutContinueOnIPhoneButton(coordinator: coordinator)
                }
            }
            if let notice = coordinator.notice {
                Text(notice.message).font(.subheadline)
                if notice.kind == .chooseRecorder {
                    recorderChoices
                }
            }
            WorkoutFitnessCheckView(coordinator: coordinator)
            if let message = store.recordingMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if !coordinator.recoveryComplete {
                Button("Retry Recovery") { coordinator.retryRecovery() }
                    .buttonStyle(.bordered)
            } else if coordinator.record == nil, coordinator.notice?.kind != .chooseRecorder {
                Button("Choose Recorder") { coordinator.chooseRecorder() }
                    .buttonStyle(.bordered)
            }
            if let record = coordinator.record, record.owner == .watch,
               record.phase == .unresolved {
                Button("Retry on Apple Watch") { coordinator.retryWatchStart() }
                    .buttonStyle(.bordered)
                Button("I checked Watch — no workout is running") { confirmsWatchIdle = true }
                    .font(.footnote)
            }
            if let record = coordinator.record, record.owner == .iphone,
               record.phase != .finished {
                if let choice = record.finishChoice {
                    Button(choice == .save ? "Reconcile Save" : "Retry Discard") {
                        coordinator.retryFinish()
                    }
                    .buttonStyle(.bordered)
                } else if store.presentation.sessionState == .ending
                            || store.presentation.sessionState == .starting {
                    WorkoutFinishButton(store: store,
                        onEndAndSave: coordinator.endAndSave,
                        onDiscard: coordinator.discard) {
                        Label("Resolve Interrupted Workout", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog("Confirm Apple Watch is idle", isPresented: $confirmsWatchIdle) {
            Button("No Watch Workout Is Running") { coordinator.confirmNoWorkoutOnWatch() }
            Button("Keep Checking", role: .cancel) {}
        } message: {
            Text("Check Bicino on your Watch first. This clears only the iPhone's unresolved ownership record; it does not end or discard a Watch workout. A late Watch recording would remain a separate ride.")
        }
    }

    private var recorderChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coordinator.watchAvailability.availability != .unsupported {
                Button("Record with Apple Watch") { _ = coordinator.requestStart(explicitOwner: .watch) }
                    .buttonStyle(.bordered)
            }
            if coordinator.phoneSupported {
                Button("Record with iPhone") { _ = coordinator.requestStart(explicitOwner: .iphone) }
                    .buttonStyle(.borderedProminent)
                Text("iPhone GPS records route and distance. Heart rate requires a compatible external monitor; cadence and power are not collected in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("iPhone-only recording requires iOS 26 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!coordinator.recoveryComplete || coordinator.record != nil)
    }
}


struct WorkoutFitnessCheckView: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator

    var body: some View {
        if coordinator.canCheckFitness {
            VStack(alignment: .leading, spacing: 4) {
                Button("Check Fitness", action: coordinator.checkFitness)
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isCheckingFitnessOnRequest)
                if let message = coordinator.fitnessCheckMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The explicit rider choice to keep recording on iPhone after Apple Watch
/// stops responding. Nothing switches until the rider confirms.
struct WorkoutContinueOnIPhoneButton: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    @State private var confirms = false

    var body: some View {
        Button { confirms = true } label: {
            Label("Continue on iPhone", systemImage: "iphone")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!coordinator.canContinueOnIPhone)
        .confirmationDialog("Continue this ride on iPhone?", isPresented: $confirms,
                            titleVisibility: .visible) {
            Button("Continue on iPhone") { _ = coordinator.continueOnIPhone() }
            Button("Keep Apple Watch", role: .cancel) {}
        } message: {
            Text("iPhone starts recording now. What Apple Watch recorded stays in Fitness as its own workout, and Bicino shows both parts as one ride with the unrecorded gap between them. Bicino won’t switch back if Apple Watch reconnects.")
        }
    }
}

/// One ride, two recorders. Each part is its own Fitness workout. The gap
/// between them was not recorded: no distance is counted across it and the
/// parts are drawn apart, never joined by a line.
struct WorkoutRideContinuationSummaryView: View {
    let summary: WorkoutRideContinuationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Continued on iPhone", systemImage: "arrow.triangle.branch")
                .font(.subheadline.weight(.semibold))
            WorkoutRideContinuationTimeline(summary: summary)
            partRow("Apple Watch", systemImage: "applewatch", part: summary.watch,
                    detail: watchDetail)
            gapRow
            if let phone = summary.phone {
                partRow("iPhone", systemImage: "iphone", part: phone,
                        detail: Self.phoneDetail(phone))
            } else {
                Label("Starting iPhone recording…", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private static func phoneDetail(_ phone: WorkoutRideContinuationSummary.Part) -> String {
        switch phone.outcome {
        case .saved: return "Saved in Fitness as its own workout"
        case .discarded: return "Discarded. Apple Watch’s part is unaffected."
        case nil: return phone.endedAt == nil ? "Recording on iPhone" : "Ended"
        }
    }

    /// Claims a Fitness workout only once Apple Watch reported or Fitness
    /// showed it saved; a discard on Apple Watch is never described as kept.
    private var watchDetail: String {
        if summary.watchDiscarded {
            return "Discarded on Apple Watch, so it isn’t in Fitness. This ride keeps its last report from before the handoff."
        }
        switch (summary.watchSaved, summary.watchRecordedPastHandoff) {
        case (true, true):
            return "Apple Watch kept recording after the handoff. Its own Fitness workout keeps all of it; this ride counts it only up to its last data before the handoff."
        case (true, false):
            return "Saved in Fitness as its own workout"
        case (false, true):
            return "Apple Watch kept recording after the handoff. This ride counts it only up to its last data before the handoff. End that workout on Apple Watch to keep it in Fitness."
        case (false, false):
            return "Apple Watch saves its part when it can; the totals here are its last report."
        }
    }

    @ViewBuilder
    private var gapRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.orange)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let gap = summary.gap {
                    Text("Not recorded · \(WorkoutValueFormatter.duration(gap.duration))")
                        .font(.subheadline.weight(.semibold))
                    Text("\(Self.clock(gap.start))–\(Self.clock(gap.end)) · No distance or route across this gap")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Unrecorded gap")
                        .font(.subheadline.weight(.semibold))
                    Text("Its length appears once Apple Watch’s last data reaches iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func partRow(_ title: String, systemImage: String,
                         part: WorkoutRideContinuationSummary.Part,
                         detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(Self.range(part)).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WorkoutValueFormatter.duration(part.movingTime))
                    .font(.subheadline.monospacedDigit())
                Text("\(WorkoutValueFormatter.distance(part.distanceMeters)) \(WorkoutValueFormatter.distanceUnit(part.distanceMeters))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func range(_ part: WorkoutRideContinuationSummary.Part) -> String {
        if let end = part.endedAt { return "\(clock(part.startedAt))–\(clock(end))" }
        return "From \(clock(part.startedAt))"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Watch part and iPhone part as two separate bars. The unrecorded gap is an
/// open dashed span, so nothing visually connects the two recordings.
private struct WorkoutRideContinuationTimeline: View {
    let summary: WorkoutRideContinuationSummary

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let spans = spans(at: context.date)
            GeometryReader { geometry in
                let total = max(1, spans.watch + spans.gap + spans.phone)
                let usable = max(0, geometry.size.width - 8)
                HStack(spacing: 4) {
                    Capsule().fill(Color.green)
                        .frame(width: max(6, usable * spans.watch / total))
                    Capsule()
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: max(6, usable * spans.gap / total))
                    if summary.phone != nil {
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(6, usable * spans.phone / total))
                    }
                }
                .frame(height: 8)
            }
            .frame(height: 8)
        }
        .accessibilityHidden(true)
    }

    private func spans(at now: Date) -> (watch: Double, gap: Double, phone: Double) {
        let watchEnd = summary.watch.endedAt ?? summary.gap?.start ?? summary.handoffAt
        let watch = max(0, watchEnd.timeIntervalSince(summary.watch.startedAt))
        let gap = summary.gap?.duration ?? 0
        let phone = summary.phone.map {
            max(0, ($0.endedAt ?? now).timeIntervalSince($0.startedAt))
        } ?? 0
        return (watch, gap, phone)
    }
}
