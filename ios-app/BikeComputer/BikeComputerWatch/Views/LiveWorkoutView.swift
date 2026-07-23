import SwiftUI
import WatchKit

private enum WorkoutFinishPrompt {
    case options(sessionID: UUID)
    case discardConfirmation(sessionID: UUID)

    var showsOptions: Bool {
        if case .options = self { return true }
        return false
    }

}

struct LiveWorkoutView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @State private var finishPrompt: WorkoutFinishPrompt?
    @State private var segmentToast: WorkoutCompletedSegmentV1?
    @State private var observedSegmentIndex: UInt32?

    var body: some View {
        Group {
            if case .discardConfirmation(let sessionID) = finishPrompt {
                discardConfirmationView(sessionID: sessionID)
            } else {
                workoutContent
            }
        }
        .onChange(of: manager.activeSessionID) {
            finishPrompt = nil
            observedSegmentIndex = manager.snapshot
                .lastCompletedSegment?.index
            segmentToast = nil
        }
        .onAppear {
            observedSegmentIndex = manager.snapshot
                .lastCompletedSegment?.index
        }
        .onChange(of: manager.snapshot.lastCompletedSegment?.index) {
            let index = manager.snapshot.lastCompletedSegment?.index
            guard let index,
                  index != observedSegmentIndex,
                  manager.state.isActive,
                  let segment = manager.snapshot.lastCompletedSegment else {
                observedSegmentIndex = index
                return
            }
            observedSegmentIndex = index
            WKInterfaceDevice.current().play(.success)
            withAnimation {
                segmentToast = segment
            }
        }
        .overlay(alignment: .top) {
            if let segmentToast {
                segmentToastView(segmentToast)
                    .padding(.horizontal, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: segmentToast?.index) {
            guard let index = segmentToast?.index else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard segmentToast?.index == index else { return }
            withAnimation {
                segmentToast = nil
            }
        }
    }

    private var workoutContent: some View {
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
                            || finishError == .segmentConfirmationPending
                            || finishError == .terminalErrorPersistenceFailed {
                            Button(manager.isDiscarding ? "Retry Recovery" : "Retry Save") {
                                manager.retryFinalization()
                            }
                            .font(.caption2)
                        }
                        if finishError == .segmentConfirmationPending {
                            Button("Save Anyway") {
                                manager.saveWithoutUnconfirmedSegment()
                            }
                            .font(.caption2)
                        }
                    }
                }

                if let segmentError = manager.segmentError {
                    Label(
                        segmentErrorMessage(segmentError),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
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

                if let segment = manager.snapshot.lastCompletedSegment {
                    Label(
                        "Segment \(segment.index + 1)",
                        systemImage: "flag.checkered"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

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
                        manager.markSegment()
                    } label: {
                        if manager.isMarkingSegment {
                            ProgressView()
                        } else {
                            Image(systemName: "flag.checkered")
                        }
                    }
                    .tint(.blue)
                    .disabled(
                        manager.state != .running
                            || manager.isMarkingSegment
                            || manager.segmentError == .confirmationPending
                    )
                    .accessibilityLabel("Mark workout segment")

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
                    .disabled(
                        ![.running, .paused].contains(manager.state)
                    )
                    .accessibilityLabel(manager.state == .paused ? "Resume ride" : "Pause ride")

                    Button(role: .destructive) {
                        if let sessionID = manager.activeSessionID {
                            finishPrompt = .options(sessionID: sessionID)
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(
                        manager.state == .ending
                    )
                    .accessibilityLabel("End ride")
                }
            }
            .padding(.horizontal, 6)
        }
        .confirmationDialog(
            "Finish Ride?",
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
            Text("Saving creates a workout in your Fitness app.")
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

    private func discardConfirmationView(sessionID: UUID) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .font(.title2)
                .foregroundStyle(.red)

            Text(WorkoutDiscardDisclosureV1.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(WorkoutDiscardDisclosureV1.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(WorkoutDiscardDisclosureV1.confirmTitle, role: .destructive) {
                finishPrompt = nil
                guard manager.activeSessionID == sessionID else { return }
                manager.discard()
            }
            .tint(.red)

            Button(WorkoutDiscardDisclosureV1.cancelTitle, role: .cancel) {
                finishPrompt = nil
            }
        }
        .padding(.horizontal, 8)
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

    private func segmentToastView(
        _ segment: WorkoutCompletedSegmentV1
    ) -> some View {
        VStack(spacing: 2) {
            Label(
                "Segment \(segment.index)",
                systemImage: "flag.checkered"
            )
            .font(.caption.weight(.semibold))
            Text(segmentSummary(segment))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func segmentSummary(
        _ segment: WorkoutCompletedSegmentV1
    ) -> String {
        let duration = WorkoutValueFormatter.duration(segment.duration)
        guard let distance = segment.distanceMeters else {
            return duration
        }
        return "\(duration) · \(WorkoutValueFormatter.distance(distance)) \(WorkoutValueFormatter.distanceUnit(distance))"
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
        case .segmentConfirmationPending:
            "A segment is still pending. Retry, or save now without guaranteeing it."
        }
    }

    private func segmentErrorMessage(
        _ error: WatchWorkoutSegmentError
    ) -> String {
        switch error {
        case .unavailable:
            "Resume the ride before marking a segment."
        case .healthKitWriteFailed:
            "Couldn’t mark that segment. The ride is still running."
        case .confirmationPending:
            "Still confirming that segment. You can pause or end the ride."
        }
    }
}
