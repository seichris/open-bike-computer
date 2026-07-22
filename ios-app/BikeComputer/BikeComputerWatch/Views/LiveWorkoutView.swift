import SwiftUI

private enum WorkoutFinishPrompt {
    case options(sessionID: UUID)
    case discardConfirmation(sessionID: UUID)

    var showsOptions: Bool {
        if case .options = self { return true }
        return false
    }

    var showsDiscardConfirmation: Bool {
        if case .discardConfirmation = self { return true }
        return false
    }
}

struct LiveWorkoutView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @State private var finishPrompt: WorkoutFinishPrompt?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                stateHeader

                if let finishError = manager.finishRequestError {
                    VStack(spacing: 5) {
                        Label(
                            finishErrorMessage(finishError),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)

                        if finishError == .reconciliationFailed
                            || finishError == .saveFailed
                            || finishError == .identityMetadataFailed
                            || finishError == .terminalErrorPersistenceFailed {
                            Button(manager.isDiscarding ? "Retry Recovery" : "Retry Save") {
                                manager.retryFinalization()
                            }
                            .font(.caption2)
                        }
                    }
                }

                if manager.snapshot.errorCode == .anotherWorkoutActive {
                    Label(
                        WorkoutCrossAppTakeoverCopyV1.live(
                            disposition: manager.isDiscarding ? .discard : .save
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }

                Text(WorkoutValueFormatter.duration(manager.snapshot.elapsedTime?.value))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Elapsed time")

                LazyVGrid(columns: columns, spacing: 8) {
                    metric(
                        title: "Heart",
                        value: WorkoutValueFormatter.heartRate(
                            manager.snapshot.currentHeartRate?.value
                        ),
                        unit: heartRateUnit,
                        icon: "heart.fill",
                        color: .red
                    )
                    metric(
                        title: "Distance",
                        value: WorkoutValueFormatter.distance(
                            manager.snapshot.cyclingDistance?.value
                        ),
                        unit: WorkoutValueFormatter.distanceUnit(
                            manager.snapshot.cyclingDistance?.value
                        ),
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        color: .green
                    )
                    metric(
                        title: "Speed",
                        value: WorkoutValueFormatter.speed(
                            manager.snapshot.currentSpeed?.value
                        ),
                        unit: "KM/H",
                        icon: "speedometer",
                        color: .cyan
                    )
                    metric(
                        title: "Energy",
                        value: WorkoutValueFormatter.energy(
                            manager.snapshot.activeEnergy?.value
                        ),
                        unit: "KCAL",
                        icon: "flame.fill",
                        color: .orange
                    )
                    metric(
                        title: "Power",
                        value: WorkoutValueFormatter.whole(
                            manager.snapshot.cyclingPower?.value
                        ),
                        unit: "W",
                        icon: "bolt.fill",
                        color: .yellow
                    )
                    metric(
                        title: "Cadence",
                        value: WorkoutValueFormatter.whole(
                            manager.snapshot.cyclingCadence?.value
                        ),
                        unit: "RPM",
                        icon: "arrow.triangle.2.circlepath",
                        color: .mint
                    )
                }

                HStack(spacing: 8) {
                    Button {
                        if manager.state == .paused {
                            manager.resume()
                        } else {
                            manager.pause()
                        }
                    } label: {
                        Image(systemName: manager.state == .paused ? "play.fill" : "pause.fill")
                    }
                    .tint(manager.state == .paused ? .green : .orange)
                    .disabled(![.running, .paused].contains(manager.state))
                    .accessibilityLabel(manager.state == .paused ? "Resume ride" : "Pause ride")

                    Button(role: .destructive) {
                        if let sessionID = manager.activeSessionID {
                            finishPrompt = .options(sessionID: sessionID)
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(manager.state == .ending)
                    .accessibilityLabel("End ride")
                }
            }
            .padding(.horizontal, 6)
        }
        .confirmationDialog(
            "Finish this ride?",
            isPresented: finishOptionsPresented
        ) {
            if case .options(let sessionID) = finishPrompt {
                Button("End and Save") {
                    finishPrompt = nil
                    guard manager.activeSessionID == sessionID else { return }
                    manager.endAndSave()
                }
                Button("Discard Workout", role: .destructive) {
                    requestDiscardConfirmation(for: sessionID)
                }
                Button("Keep Riding", role: .cancel) {
                    finishPrompt = nil
                }
            }
        } message: {
            Text("Saving creates one workout in Health. Discarding saves nothing.")
        }
        .alert(
            WorkoutDiscardDisclosureV1.title,
            isPresented: discardConfirmationPresented
        ) {
            if case .discardConfirmation(let sessionID) = finishPrompt {
                Button(WorkoutDiscardDisclosureV1.cancelTitle, role: .cancel) {
                    WorkoutDiscardDisclosureV1.perform(
                        .cancel,
                        expectedSessionID: sessionID,
                        currentSessionID: manager.activeSessionID,
                        discard: manager.discard
                    )
                }
                Button(
                    WorkoutDiscardDisclosureV1.confirmTitle,
                    role: .destructive
                ) {
                    WorkoutDiscardDisclosureV1.perform(
                        .confirmDiscard,
                        expectedSessionID: sessionID,
                        currentSessionID: manager.activeSessionID,
                        discard: manager.discard
                    )
                }
            }
        } message: {
            Text(WorkoutDiscardDisclosureV1.message)
        }
        .onChange(of: manager.activeSessionID) {
            finishPrompt = nil
        }
    }

    private var finishOptionsPresented: Binding<Bool> {
        Binding(
            get: { finishPrompt?.showsOptions == true },
            set: { isPresented in
                if !isPresented, finishPrompt?.showsOptions == true {
                    finishPrompt = nil
                }
            }
        )
    }

    private var discardConfirmationPresented: Binding<Bool> {
        Binding(
            get: { finishPrompt?.showsDiscardConfirmation == true },
            set: { isPresented in
                if !isPresented,
                   finishPrompt?.showsDiscardConfirmation == true {
                    finishPrompt = nil
                }
            }
        )
    }

    private func requestDiscardConfirmation(for sessionID: UUID) {
        finishPrompt = nil
        DispatchQueue.main.async {
            guard manager.activeSessionID == sessionID else { return }
            finishPrompt = .discardConfirmation(sessionID: sessionID)
        }
    }

    private var stateHeader: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(stateLabel)
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout \(stateLabel)")
    }

    private func metric(
        title: String,
        value: String,
        unit: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit)")
    }

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var heartRateUnit: String {
        guard let zone = manager.snapshot.currentHeartRateZone,
              let count = manager.snapshot.heartRateZoneCount else {
            return "BPM"
        }
        return "BPM · Z\(zone)/\(count)"
    }

    private var stateLabel: String {
        switch manager.state {
        case .starting: "STARTING"
        case .running: "LIVE"
        case .paused: "PAUSED"
        case .ending: manager.isDiscarding ? "DISCARDING" : "SAVING"
        case .idle, .ended, .failed: "WORKOUT"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .paused: .orange
        case .ending: .blue
        case .starting: .yellow
        case .running: .green
        case .idle, .ended, .failed: .secondary
        }
    }

    private func finishErrorMessage(
        _ error: WatchWorkoutFinishRequestError
    ) -> String {
        switch error {
        case .persistenceFailed:
            "Couldn’t end the ride. It’s still active—try again."
        case .terminalErrorPersistenceFailed:
            "Couldn’t preserve why this ride ended. Retry recovery."
        case .saveFailed:
            "Couldn’t save the ride yet. Retry safely."
        case .reconciliationFailed:
            "Couldn’t verify whether this ride was saved. Retry safely."
        case .identityMetadataFailed:
            "Couldn’t finish the ride safely yet. Retry recovery."
        }
    }
}
