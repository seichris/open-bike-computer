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

struct WorkoutRecorderChoices: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator

    var body: some View {
        // Keep the choices in place while the Watch wakes or sleeps.
        if coordinator.phoneSupported { startButton(.iphone) }
        if coordinator.watchAvailability.availability != .noPairedWatch,
           coordinator.watchAvailability.availability != .unsupported {
            startButton(.watch)
        }
    }

    private func startButton(_ owner: WorkoutRecordingOwner) -> some View {
        Button {
            _ = coordinator.requestStart(explicitOwner: owner)
        } label: {
            Label("Start on \(owner.displayName)",
                  systemImage: owner == .watch ? "applewatch" : "iphone")
        }
        .disabled(!coordinator.canOfferNewWorkout)
    }
}

struct WorkoutRecordingStatusView: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    @ObservedObject var store: WorkoutMetricsStore

    var body: some View {
        Group {
            if let record = coordinator.record,
               record.owner == .watch, record.phase == .unresolved,
               !coordinator.canContinueOnIPhone {
                UnconfirmedWatchWorkoutView(coordinator: coordinator, sessionID: record.sessionID)
                    .id(record.sessionID)
            } else {
                recordingStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recordingStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let record = coordinator.record {
                Label("Recorder: \(record.owner.displayName)",
                      systemImage: record.owner == .iphone ? "iphone" : "applewatch")
                    .font(.subheadline.weight(.semibold))
                if let continuation = record.continuation {
                    Text("Continued from Apple Watch at \(continuation.handoffAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.canContinueOnIPhone {
                WorkoutContinueOnIPhoneButton(coordinator: coordinator)
            }
            if coordinator.notice?.kind == .chooseRecorder {
                WorkoutRecorderChoices(coordinator: coordinator)
                    .buttonStyle(.bordered)
            } else if let notice = coordinator.notice {
                Text(notice.message).font(.subheadline)
            }
            WorkoutFitnessCheckView(coordinator: coordinator)
            if let message = store.recordingMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if !coordinator.recoveryComplete {
                Button("Retry Recovery") { coordinator.retryRecovery() }
                    .buttonStyle(.bordered)
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
    }
}

private struct UnconfirmedWatchWorkoutView: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    let sessionID: UUID
    @State private var showsConfirmation = false

    private var resolutionTitle: String {
        coordinator.phoneSupported ? "Start on iPhone" : "Clear Watch Attempt"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not connect to your watch", systemImage: "applewatch")
                .font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            .buttonStyle(.bordered)
        }
        .confirmationDialog(
            coordinator.phoneSupported ? "Start a separate iPhone workout?" : "Clear this Watch attempt?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(resolutionTitle) {
                coordinator.resolveUnconfirmedWatchWorkout(
                    sessionID: sessionID,
                    startOnIPhone: coordinator.phoneSupported
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any workout started on Apple Watch will stay separate.")
        }
    }

    @ViewBuilder private var actions: some View {
        Button {
            coordinator.retryWatchStart()
        } label: {
            Label("Retry on Watch", systemImage: "applewatch")
        }
        Button {
            showsConfirmation = true
        } label: {
            Label(resolutionTitle, systemImage: coordinator.phoneSupported ? "iphone" : "applewatch")
        }
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
/// stops responding. Nothing switches until the rider confirms. A control
/// row passes its own label so the button matches the row's other controls.
struct WorkoutContinueOnIPhoneButton<Label: View>: View {
    @ObservedObject var coordinator: WorkoutSessionCoordinator
    @ViewBuilder let label: () -> Label
    @State private var confirms = false

    var body: some View {
        Button { confirms = true } label: {
            label()
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

extension WorkoutContinueOnIPhoneButton where Label == SwiftUI.Label<Text, Image> {
    init(coordinator: WorkoutSessionCoordinator) {
        self.init(coordinator: coordinator) {
            SwiftUI.Label("Continue on iPhone", systemImage: "iphone")
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
